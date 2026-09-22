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
oder /reload — es gibt keine API, die das Schreiben erzwingt. Der Export wird
deshalb bei PLAYER_LOGOUT frisch gebaut; was dort auf Platte landet, ist immer
der aktuelle Stand.

Damit dafür niemand ausloggen muss, gibt es den Upload-Knopf (UI.lua) und
`/ehs upload`: beide bauen den Export und lösen anschliessend ein ReloadUI() aus.
Automatisieren lässt sich das nicht — ReloadUI() ist von Blizzard auf einen
Hardware-Event beschränkt und muss von einem echten Klick oder Tastendruck
kommen. Ein Reload nach jedem Bosskill von selbst ist deshalb nicht möglich,
ein Knopf, den man in der Pause drückt, schon.
]]

local ADDON_NAME = ...

EventHelperSync = EventHelperSync or {}
local EHS = EventHelperSync

EHS.name = ADDON_NAME
EHS.version = GetAddOnMetadata and GetAddOnMetadata(ADDON_NAME, "Version") or "1.5.0"

-- Voreinstellungen. lookbackDays begrenzt, wie weit zurück Loot exportiert wird:
-- die Historien beider Addons wachsen über Monate, hochgeladen werden muss aber
-- nur, was noch keinem Event zugeordnet ist. Der Server dedupliziert ohnehin,
-- ein zu grosser Wert kostet also nur Bandbreite, keine Korrektheit.
local DEFAULTS = {
    lookbackDays = 21,
    -- Ab welcher Lücke zwischen zwei Vergaben ein neuer Raid-Abend beginnt.
    sessionGapHours = 6,
    debug = false,
    -- Ob der Upload-Knopf von selbst auftaucht, sobald Loot vergeben wurde, der
    -- noch nicht auf Platte liegt.
    showButton = true,
    -- Der Knopf an der Minimap, der das Optionsfenster öffnet.
    showMinimap = true,
    -- Items, die gar nicht an einen Raider gingen, sondern in die Gildenbank
    -- oder zum Entzaubern, gehören nicht in die Loot-Historie (Collect.lua).
    skipAwardReasons = true,
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

--- Wie viele Vergaben es gibt, die noch in keiner geschriebenen Datei stehen.
-- Gemessen an lastFlushedAt: dem Zeitpunkt, zu dem zuletzt bewusst ein Reload
-- bzw. ein Logout ausgelöst wurde. Alles, was danach vergeben wurde, hat die
-- Platte noch nicht gesehen — und genau das ist es, wofür sich der Knopf lohnt.
--
-- Abgewählte Raid-Abende zählen nicht mit: für sie lohnt sich kein Reload, sie
-- werden ohnehin nicht exportiert.
function EHS:PendingCount()
    local since = self.db.lastFlushedAt or 0
    local count = 0
    for _, session in ipairs(self:BuildSessions()) do
        if not self:IsExcluded(session.sessionId) then
            for _, row in ipairs(session.items) do
                if row.awardedAt > since then count = count + 1 end
            end
        end
    end
    return count
end

--- Export bauen und den Reload auslösen, der ihn auf die Platte schreibt.
--
-- Muss aus einem Hardware-Event heraus aufgerufen werden (Knopfklick oder ein
-- getippter Slash-Befehl) — ReloadUI() ist anders nicht erlaubt. Deshalb gibt es
-- hier auch keinen Timer und keinen Automatik-Aufruf.
-- @return boolean ob der Reload angestossen wurde
function EHS:FlushAndReload()
    if InCombatLockdown() then
        self:Print("|cffdd4444Nicht im Kampf.|r Nach dem Kampf nochmal drücken.")
        return false
    end

    local envelope = self:Rebuild()
    local items = 0
    for _, session in ipairs(envelope.sessions) do items = items + #session.items end
    if items == 0 then
        self:Print("Nichts zu speichern — es wurde kein Loot gefunden.")
        return false
    end

    -- Erst merken, dann neu laden: der Wert muss mit in die Datei, die der
    -- Reload gleich schreibt.
    self.db.lastFlushedAt = time()
    self:Print(("Speichere %d Item(s) und lade die UI neu — das Sync-Tool holt sie gleich ab."):format(items))
    ReloadUI()
    return true
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
        -- Abgewählte Raid-Abende: { [sessionId] = true }. Siehe Export.lua.
        EHS.db.excluded = EHS.db.excluded or {}
        -- Zeitleiste der besuchten Raid-Instanzen: das Einzige, was das Addon
        -- laufend mitschreiben MUSS, weil es sich nachträglich nicht mehr
        -- rekonstruieren lässt (siehe Zones.lua).
        EHS.db.zones = EHS.db.zones or {}
        return
    end

    if event == "PLAYER_LOGIN" then
        EHS:StartZoneTracking()
        EHS:StartButton()
        EHS:StartMinimap()
        return
    end

    if event == "PLAYER_LOGOUT" then
        -- Letzte Gelegenheit vor dem Schreiben der SavedVariables.
        local ok, err = pcall(function()
            EHS:Rebuild()
            EHS.db.lastFlushedAt = time()
        end)
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

    local pending = EHS:PendingCount()
    if pending > 0 then
        EHS:Print(("|cffffd200%d Item(s) liegen noch nicht auf der Platte.|r Mit |cffffd200/ehs upload|r speichern (lädt die UI neu)."):format(pending))
    else
        EHS:Print("Alles gespeichert — das Sync-Tool hat den aktuellen Stand.")
    end
end

SlashCmdList.EVENTHELPERSYNC = function(msg)
    local cmd, rest = strsplit(" ", strtrim(msg or ""), 2)
    cmd = strlower(cmd or "")

    if cmd == "" then
        -- Der häufigste Fall ist "was ist der Stand?" — und darauf antwortet
        -- das Fenster besser als eine Handvoll Chat-Zeilen.
        EHS:ToggleOptions()
    elseif cmd == "status" then
        reportStatus()
    elseif cmd == "upload" or cmd == "save" then
        -- Ein getippter Slash-Befehl zählt als Hardware-Event, ReloadUI() ist
        -- von hier aus also erlaubt.
        EHS:FlushAndReload()
    elseif cmd == "button" then
        EHS.db.settings.showButton = not EHS.db.settings.showButton
        EHS:Print("Upload-Knopf " .. (EHS.db.settings.showButton and "an" or "aus") .. ".")
        EHS:RefreshButton()
    elseif cmd == "diag" then
        EHS:Diagnose()
    elseif cmd == "minimap" then
        EHS.db.settings.showMinimap = not EHS.db.settings.showMinimap
        EHS:Print("Minimap-Knopf " .. (EHS.db.settings.showMinimap and "an" or "aus") .. ".")
        EHS:RefreshMinimap()
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
        EHS:Print("  /ehs            — Fenster mit Status, Raid-Abenden und Einstellungen")
        EHS:Print("  /ehs upload     — jetzt speichern (lädt die UI neu) statt auszuloggen")
        EHS:Print("  /ehs status     — dasselbe kurz im Chat")
        EHS:Print("  /ehs diag       — warum findet er nichts? Zeigt jede Stufe einzeln")
        EHS:Print("  /ehs minimap    — Minimap-Knopf ein-/ausblenden")
        EHS:Print("  /ehs button     — Upload-Knopf ein-/ausblenden")
        EHS:Print("  /ehs export     — Export als JSON zum Kopieren anzeigen")
        EHS:Print("  /ehs days <n>   — wie viele Tage zurück exportiert werden")
        EHS:Print("  /ehs debug      — Debug-Ausgaben umschalten")
    end
end
