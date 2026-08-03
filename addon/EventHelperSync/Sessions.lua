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
local function instanceFor(rows, startedAt)
    for _, row in ipairs(rows) do
        if row.instance and row.instance ~= "" then
            -- Der "-25 Player"-Anhang ist Raidgrösse, kein Ortsname. Ausserhalb
            -- einer Instanz schreibt RCLootcouncil nur den Kontinent mit einem
            -- Bindestrich dahinter ("Eastern Kingdoms-") — der muss auch weg.
            local name = row.instance:gsub("%-%d+ Player$", ""):gsub("%-%s*$", "")
            if name ~= "" then return name end
        end
    end
    return EHS:ZoneAt(startedAt)
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
        }
    end
    return out
end
