--[[
`/ehs diag` — sagt an jeder Stufe, was das Addon sieht.

Der Anlass: "er findet nichts zum Hochladen" kann sechs verschiedene Ursachen
haben, und von aussen sind sie nicht zu unterscheiden. Zwischen "das Loot-Addon
ist gar nicht geladen", "seine Historie ist an einer anderen Stelle als
erwartet", "der Loot ist älter als der eingestellte Zeitraum" und "der Abend ist
abgewählt" liegen völlig verschiedene Abhilfen.

Diese Datei rät nicht, sondern zählt: pro Quelle, wie viele Einträge da sind,
wie alt der älteste und der jüngste ist, wie viele davon in den Zeitraum fallen
und was am Ende im Export landet. Jede Zeile beantwortet eine Frage, die sonst
nur durch Nachfragen zu klären wäre.

Alles in pcall gekapselt: ein Diagnosewerkzeug, das selbst mit einem Fehler
abbricht, ist keins.
]]

local EHS = EventHelperSync

local function ok(text) return "|cff44dd44" .. text .. "|r" end
local function bad(text) return "|cffdd4444" .. text .. "|r" end
local function warn(text) return "|cffffd200" .. text .. "|r" end

local function when(at)
    if not at or at == 0 then return "—" end
    return date("%d.%m.%Y %H:%M", at)
end

--- Einträge in einer beliebig geformten Tabelle zählen (pairs, nicht ipairs).
local function count(t)
    if type(t) ~= "table" then return 0 end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

--- Was RCLootcouncil hergibt, Schritt für Schritt.
local function diagRclc()
    EHS:Print("|cffffffffRCLootcouncil|r")

    local lib = LibStub and LibStub("AceAddon-3.0", true)
    EHS:Print("  LibStub/Ace:      " .. (lib and ok("da") or bad("fehlt")))

    local rclc = lib and lib:GetAddon("RCLootCouncil", true)
    EHS:Print("  Addon geladen:    " .. (rclc and ok("ja") or bad("nein")))

    local db, quelle
    if rclc and rclc.GetHistoryDB then
        local good, result = pcall(rclc.GetHistoryDB, rclc)
        if good and type(result) == "table" then
            db, quelle = result, "GetHistoryDB()"
        else
            EHS:Print("  GetHistoryDB:     " .. bad(tostring(result)))
        end
    end

    if not db then
        local raw = _G.RCLootCouncilLootDB
        EHS:Print("  RCLootCouncilLootDB: " .. (type(raw) == "table" and ok("da") or bad("fehlt")))
        if type(raw) == "table" and type(raw.factionrealm) == "table" then
            local faction = UnitFactionGroup("player") or ""
            local key = faction .. " - " .. (GetRealmName() or "")
            EHS:Print("  gesuchter Schlüssel: |cffffffff" .. key .. "|r")
            -- Die tatsächlich vorhandenen Schlüssel mit ausgeben: stimmt der
            -- erwartete nicht, sieht man hier sofort, wie er wirklich heisst.
            for realKey in pairs(raw.factionrealm) do
                EHS:Print("    vorhanden:      |cffffffff" .. tostring(realKey) .. "|r"
                    .. (realKey == key and ok("  <- passt") or warn("  <- passt nicht")))
            end
            db, quelle = raw.factionrealm[key], "rohe SavedVariable"
        end
    end

    if type(db) ~= "table" then
        EHS:Print("  Historie:         " .. bad("nicht erreichbar"))
        return
    end

    local spieler, eintraege, aeltester, juengster = 0, 0, nil, nil
    for _, liste in pairs(db) do
        if type(liste) == "table" then
            spieler = spieler + 1
            for _, entry in pairs(liste) do
                if type(entry) == "table" then
                    eintraege = eintraege + 1
                    local at = tonumber(tostring(entry.id or ""):match("^(%d+)")) or 0
                    if at > 0 then
                        if not aeltester or at < aeltester then aeltester = at end
                        if not juengster or at > juengster then juengster = at end
                    end
                end
            end
        end
    end
    EHS:Print("  Quelle:           " .. quelle)
    EHS:Print("  Spieler/Einträge: " .. spieler .. " / " .. (eintraege > 0 and ok(eintraege) or bad(eintraege)))
    EHS:Print("  ältester/jüngster: " .. when(aeltester) .. "  bis  " .. when(juengster))
end

--- Dasselbe für Gargul.
local function diagGargul()
    EHS:Print("|cffffffffGargul|r")

    local db = _G.GargulDB
    EHS:Print("  GargulDB:         " .. (type(db) == "table" and ok("da") or bad("fehlt")))
    if type(db) ~= "table" then return end

    -- Welche Tabellen Gargul führt: liegt die Historie woanders, steht sie hier.
    local namen = {}
    for k, v in pairs(db) do
        if type(v) == "table" then namen[#namen + 1] = k .. "(" .. count(v) .. ")" end
    end
    table.sort(namen)
    EHS:Print("  Tabellen:         " .. table.concat(namen, ", "))

    local history = db.AwardHistory
    EHS:Print("  AwardHistory:     " .. (type(history) == "table" and ok("da") or bad("fehlt")))
    if type(history) ~= "table" then return end

    local eintraege, mitZeit, aeltester, juengster = 0, 0, nil, nil
    for _, entry in pairs(history) do
        if type(entry) == "table" then
            eintraege = eintraege + 1
            local at = tonumber(entry.timestamp) or 0
            if at > 0 then
                mitZeit = mitZeit + 1
                if not aeltester or at < aeltester then aeltester = at end
                if not juengster or at > juengster then juengster = at end
            end
        end
    end
    EHS:Print("  Einträge:         " .. (eintraege > 0 and ok(eintraege) or bad(eintraege))
        .. "  davon mit Zeitstempel: " .. mitZeit)
    EHS:Print("  ältester/jüngster: " .. when(aeltester) .. "  bis  " .. when(juengster))
end

--- Was davon durch den Zeitraum kommt und was am Ende exportiert wird.
local function diagPipeline()
    local tage = EHS.db.settings.lookbackDays or 21
    local grenze = time() - (tage * 24 * 60 * 60)
    EHS:Print("|cffffffffZeitraum|r")
    EHS:Print("  eingestellt:      " .. tage .. " Tage, also alles ab " .. when(grenze))

    local rows = EHS:CollectRows()
    EHS:Print("  im Zeitraum:      " .. (#rows > 0 and ok(#rows .. " Vergabe(n)") or bad("0 Vergaben")))
    if #rows > 0 then
        EHS:Print("  davon RCLC/Gargul: " .. (function()
            local a, b = 0, 0
            for _, r in ipairs(rows) do
                if r.source == "rclc" then a = a + 1 else b = b + 1 end
            end
            return a .. " / " .. b
        end)())
        EHS:Print("  erste/letzte:     " .. when(rows[1].awardedAt) .. "  bis  " .. when(rows[#rows].awardedAt))
    end

    local sessions = EHS:BuildSessions()
    EHS:Print("|cffffffffRaid-Abende|r")
    EHS:Print("  gebildet:         " .. #sessions)

    local abgewaehlt = 0
    for _, s in ipairs(sessions) do
        local aus = EHS:IsExcluded(s.sessionId)
        if aus then abgewaehlt = abgewaehlt + 1 end
        EHS:Print(("  %s %s — %s, %d Item(s)"):format(
            aus and bad("[abgewählt]") or ok("[dabei]"),
            date("%d.%m.%Y", s.startedAt),
            s.instance ~= "" and s.instance or "unbekannte Instanz",
            #s.items))
    end
    if abgewaehlt > 0 then
        EHS:Print("  " .. warn(abgewaehlt .. " Abend(e) abgewählt — die werden nicht hochgeladen."))
    end

    local envelope = EHS:BuildEnvelope(sessions)
    local items = 0
    for _, s in ipairs(envelope.sessions) do items = items + #s.items end
    EHS:Print("|cffffffffExport|r")
    EHS:Print("  landet in der Datei: " .. (items > 0
        and ok(#envelope.sessions .. " Session(s), " .. items .. " Item(s)")
        or bad("nichts")))
    EHS:Print("  zuletzt gespeichert: " .. when(EHS.db.lastFlushedAt))
    EHS:Print("  Datei liegt unter: |cffffffffWTF\\Account\\<Account>\\SavedVariables\\EventHelperSync.lua|r")
end

function EHS:Diagnose()
    self:Print("|cffffd200--- Diagnose ---|r  (Addon " .. tostring(self.version) .. ")")
    for _, step in ipairs({ diagRclc, diagGargul, diagPipeline }) do
        local good, err = pcall(step)
        if not good then self:Print(bad("Fehler in der Diagnose: " .. tostring(err))) end
    end
    self:Print("|cffffd200--- Ende ---|r")
end
