--[[
Vergaben zu Raid-Abenden bündeln.

Warum überhaupt Sessions und nicht eine flache Liste: Der EventHelper ordnet
jeden Upload einem Raid-Helper-Event zu. Käme alles als ein Klumpen an, müsste
eine Woche Raids in ein einziges Event — mit Sessions bekommt jeder Raid-Abend
seine eigene Zuordnung.

Die Bündelung passiert rein über die Zeitstempel: alles, was weniger als
`sessionGapHours` auseinanderliegt, ist derselbe Abend. Das hat den Vorteil,
dass es auch rückwirkend funktioniert — für Loot, der längst in den Historien
steht, bevor dieses Addon installiert wurde.

Die sessionId muss über wiederholte Exporte stabil bleiben, sonst legt der
Server bei jedem Upload eine neue Inbox-Karte an. Sie leitet sich deshalb aus
dem FRÜHESTEN Zeitstempel der Session ab: später dazukommende Items verschieben
ihn nicht, und genau so wächst ein laufender Raid.
]]

local EHS = EventHelperSync

--- "Coilfang: Serpentshrine Cavern-25 Player" -> "coilfang-serpentshrine-cavern"
-- Nur für die sessionId; der Anzeigename bleibt unangetastet.
local function slug(name)
    local out = tostring(name or ""):lower()
    out = out:gsub("%-%d+ player", "")
    out = out:gsub("[^%w]+", "-")
    out = out:gsub("^%-+", ""):gsub("%-+$", "")
    return out
end

--- Der Instanzname für eine Session.
-- Erste Wahl ist das, was RCLootcouncil an die Zeile geschrieben hat; kommt der
-- Loot nur aus Gargul (kein Instanz-Feld), greift die eigene Zonen-Zeitleiste.
--- "Coilfang: Serpentshrine Cavern-25 Player" -> "Coilfang: Serpentshrine Cavern"
-- Der "-25 Player"-Anhang ist Raidgrösse, kein Ortsname. Ausserhalb einer
-- Instanz schreibt RCLootcouncil nur den Kontinent mit einem Bindestrich
-- dahinter ("Eastern Kingdoms-") — der muss auch weg.
local function cleanInstance(raw)
    return (tostring(raw or ""):gsub("%-%d+ Player$", ""):gsub("%-%s*$", ""))
end

-- Ab welchem Anteil eine zweite Instanz mit in den Namen kommt. Ein Abend, der
-- zu einem Drittel in Tempest Keep stattfand, heisst "SSC + TK" und nicht nur
-- "SSC".
local SECOND_INSTANCE_SHARE = 0.25

--- Der Name für einen Raid-Abend.
--
-- Gezählt wird, welche Instanz die Items tatsächlich nennen, und die häufigste
-- gewinnt — nicht die erste. Das ist kein Schönheitsfehler: Gruul und
-- Magtheridon laufen als kurzer Zusatz neben dem Hauptraid, und die erste Zeile
-- des Abends war deshalb regelmässig ein Zwei-Item-Anhängsel, das dem ganzen
-- Abend seinen Namen gab.
--
-- Kommt gar keine Instanz vor (reiner Gargul-Abend), greift die eigene
-- Zonen-Zeitleiste; und wenn auch die nichts weiss, bleibt der Name leer — der
-- Server leitet ihn dann aus den Item-IDs ab.
local function instanceFor(rows, startedAt)
    local counts, order = {}, {}
    local known = 0
    for _, row in ipairs(rows) do
        local name = cleanInstance(row.instance)
        if name ~= "" then
            if not counts[name] then
                counts[name] = 0
                order[#order + 1] = name
            end
            counts[name] = counts[name] + 1
            known = known + 1
        end
    end

    if known == 0 then return EHS:ZoneAt(startedAt) end

    -- Nach Häufigkeit, bei Gleichstand nach erstem Auftreten (stabil).
    table.sort(order, function(a, b)
        if counts[a] ~= counts[b] then return counts[a] > counts[b] end
        return a < b
    end)

    local name = order[1]
    local second = order[2]
    if second and (counts[second] / known) >= SECOND_INSTANCE_SHARE then
        name = name .. " + " .. second
    end
    return name
end

--- Die Kennzahlen, die die Übersicht anzeigt.
--
-- Hier berechnet und nicht im Fenster: die Übersicht frischt im Takt auf, und
-- die Zahlen sollen nicht bei jedem Durchlauf neu über alle Items laufen.
--
-- `pending` ist die eigentlich interessante: wie viel dieses Abends noch nicht
-- auf der Platte liegt. Ein Abend ohne offene Items braucht keinen Reload.
local function statsFor(items, lastFlush)
    local players, playerCount = {}, 0
    local bosses, bossCount = {}, 0
    local rclc, gargul, pending, offspec = 0, 0, 0, 0
    local firstUnsaved

    for _, row in ipairs(items) do
        if row.player and not players[row.player] then
            players[row.player] = true
            playerCount = playerCount + 1
        end
        if row.boss and row.boss ~= "" and not bosses[row.boss] then
            bosses[row.boss] = true
            bossCount = bossCount + 1
        end
        if row.source == "gargul" then gargul = gargul + 1 else rclc = rclc + 1 end
        if row.offspec then offspec = offspec + 1 end
        if row.awardedAt > lastFlush then
            pending = pending + 1
            if not firstUnsaved or row.awardedAt < firstUnsaved then firstUnsaved = row.awardedAt end
        end
    end

    return {
        players = playerCount,
        bosses = bossCount,
        rclc = rclc,
        gargul = gargul,
        offspec = offspec,
        pending = pending,
        firstUnsaved = firstUnsaved,
    }
end

--- Alle gesammelten Zeilen als Sessions, älteste zuerst.
function EHS:BuildSessions()
    local rows = self:CollectRows()
    if #rows == 0 then return {} end

    local gap = (self.db.settings.sessionGapHours or 6) * 60 * 60
    local sessions = {}
    local current = nil

    for _, row in ipairs(rows) do
        if not current or (row.awardedAt - current.lastAt) > gap then
            current = { items = {}, startedAt = row.awardedAt, lastAt = row.awardedAt }
            sessions[#sessions + 1] = current
        end
        current.items[#current.items + 1] = row
        current.lastAt = row.awardedAt
    end

    local lastFlush = self.db.lastFlushedAt or 0
    local out = {}
    for _, session in ipairs(sessions) do
        local instance = instanceFor(session.items, session.startedAt)
        out[#out + 1] = {
            -- Stabil, solange die früheste Vergabe des Abends dieselbe bleibt.
            sessionId = ("eh-%d-%s"):format(session.startedAt, slug(instance) ~= "" and slug(instance) or "raid"),
            startedAt = session.startedAt,
            endedAt = session.lastAt,
            instance = instance,
            items = session.items,
            stats = statsFor(session.items, lastFlush),
        }
    end
    return out
end
