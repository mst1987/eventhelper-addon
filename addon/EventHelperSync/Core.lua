--[[
EventHelper Sync — Kern.

Das Addon selbst kann nichts hochladen: WoWs Lua-Sandbox hat keinen Netzwerk-
und keinen Dateizugriff ausserhalb der eigenen SavedVariables. Es tut deshalb
genau das, was im Spiel möglich ist, und zwar vollständig:

  1. den vergebenen Loot aus RCLootcouncil UND Gargul einsammeln (Collect.lua),
  2. ihn zu Raid-Sessions bündeln und mit der Instanz beschriften, in der er
     gefallen ist (Sessions.lua / Zones.lua),
  3. das Ergebnis nach EventHelperSyncDB.export schreiben (Export.lua).

Von dort holt es das Sync-Tool ab und lädt es zum EventHelper hoch. Ohne
Sync-Tool geht es auch von Hand: `/ehs export` zeigt dasselbe als JSON in einer
Kopierbox (UI.lua), das im Admin-Menü unter Historie & Loot -> Import eingefügt
werden kann.

WICHTIG zum Zeitpunkt: SavedVariables schreibt der Client nur beim Ausloggen
oder /reload. Der Export wird deshalb bei PLAYER_LOGOUT frisch gebaut — was
dort auf Platte landet, ist immer der aktuelle Stand.
]]

local ADDON_NAME = ...

EventHelperSync = EventHelperSync or {}
local EHS = EventHelperSync

EHS.name = ADDON_NAME
EHS.version = GetAddOnMetadata and GetAddOnMetadata(ADDON_NAME, "Version") or "1.0.0"

-- Voreinstellungen. lookbackDays begrenzt, wie weit zurück Loot exportiert wird:
-- die Historien beider Addons wachsen über Monate, hochgeladen werden muss aber
-- nur, was noch keinem Event zugeordnet ist. Der Server dedupliziert ohnehin,
-- ein zu grosser Wert kostet also nur Bandbreite, keine Korrektheit.
local DEFAULTS = {
    lookbackDays = 21,
    -- Ab welcher Lücke zwischen zwei Vergaben ein neuer Raid-Abend beginnt.
    sessionGapHours = 6,
    debug = false,
}

local function applyDefaults(target, defaults)
    for key, value in pairs(defaults) do
        if target[key] == nil then target[key] = value end
    end
end

function EHS:Print(...)
    print("|cff5b8dee[EventHelper]|r", ...)
end

function EHS:Debug(...)
    if self.db and self.db.settings and self.db.settings.debug then
        self:Print("|cff888888debug:|r", ...)
    end
end

--- Baut den Export neu und legt ihn in den SavedVariables ab.
-- @return table Der Envelope, so wie ihn auch das Sync-Tool liest.
function EHS:Rebuild()
    local sessions = self:BuildSessions()
    local envelope = self:BuildEnvelope(sessions)
    self.db.export = envelope
    self.db.lastBuild = time()
    return envelope
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_LOGOUT")

frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        EventHelperSyncDB = EventHelperSyncDB or {}
        EHS.db = EventHelperSyncDB
        EHS.db.settings = EHS.db.settings or {}
        applyDefaults(EHS.db.settings, DEFAULTS)
        -- Zeitleiste der besuchten Raid-Instanzen: das Einzige, was das Addon
        -- laufend mitschreiben MUSS, weil es sich nachträglich nicht mehr
        -- rekonstruieren lässt (siehe Zones.lua).
        EHS.db.zones = EHS.db.zones or {}
        return
    end

    if event == "PLAYER_LOGIN" then
        EHS:StartZoneTracking()
        return
    end

    if event == "PLAYER_LOGOUT" then
        -- Letzte Gelegenheit vor dem Schreiben der SavedVariables.
        local ok, err = pcall(function() EHS:Rebuild() end)
        if not ok then
            -- Beim Logout sieht das niemand mehr, aber der Fehler steht dann
            -- wenigstens in der DB und taucht beim nächsten /ehs auf.
            EHS.db.lastError = tostring(err)
        else
            EHS.db.lastError = nil
        end
        return
    end
end)

-- ---------------------------------------------------------------------------
-- Slash-Befehle
-- ---------------------------------------------------------------------------

SLASH_EVENTHELPERSYNC1 = "/ehs"
SLASH_EVENTHELPERSYNC2 = "/eventhelper"

local function reportStatus()
    local envelope = EHS:Rebuild()
    local items = 0
    for _, session in ipairs(envelope.sessions) do
        items = items + #session.items
    end
    EHS:Print(("%d Raid-Session(s), %d Item(s) exportbereit."):format(#envelope.sessions, items))

    local sources = EHS:AvailableSources()
    EHS:Print(("Quellen: RCLootcouncil %s, Gargul %s."):format(
        sources.rclc and "|cff44dd44gefunden|r" or "|cffdd4444nicht geladen|r",
        sources.gargul and "|cff44dd44gefunden|r" or "|cffdd4444nicht geladen|r"))

    for _, session in ipairs(envelope.sessions) do
        EHS:Print((" · %s — %s, %d Item(s)"):format(
            date("%d.%m.%Y %H:%M", session.startedAt),
            session.instance ~= "" and session.instance or "unbekannte Instanz",
            #session.items))
    end

    if EHS.db.lastError then
        EHS:Print("|cffdd4444Letzter Fehler:|r " .. EHS.db.lastError)
    end
    EHS:Print("Das Sync-Tool holt das nach dem Ausloggen oder einem /reload ab.")
end

SlashCmdList.EVENTHELPERSYNC = function(msg)
    local cmd, rest = strsplit(" ", strtrim(msg or ""), 2)
    cmd = strlower(cmd or "")

    if cmd == "" or cmd == "status" then
        reportStatus()
    elseif cmd == "export" then
        EHS:ShowExportFrame()
    elseif cmd == "days" then
        local days = tonumber(rest)
        if not days or days < 1 then
            EHS:Print(("Aktuell werden %d Tage exportiert. Ändern mit: /ehs days <Zahl>"):format(EHS.db.settings.lookbackDays))
        else
            EHS.db.settings.lookbackDays = math.floor(days)
            EHS:Print(("Es werden jetzt %d Tage exportiert."):format(EHS.db.settings.lookbackDays))
        end
    elseif cmd == "debug" then
        EHS.db.settings.debug = not EHS.db.settings.debug
        EHS:Print("Debug-Ausgaben " .. (EHS.db.settings.debug and "an" or "aus") .. ".")
    else
        EHS:Print("Befehle:")
        EHS:Print("  /ehs            — Status und gefundene Raid-Sessions")
        EHS:Print("  /ehs export     — Export als JSON zum Kopieren anzeigen")
        EHS:Print("  /ehs days <n>   — wie viele Tage zurück exportiert werden")
        EHS:Print("  /ehs debug      — Debug-Ausgaben umschalten")
    end
end
