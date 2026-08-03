--[[
Zeitleiste der besuchten Raid-Instanzen.

Der Grund, warum das Addon das überhaupt mitschreibt: Ein Gargul-Export sagt
nicht, WO ein Item gefallen ist — die Award-Einträge haben kein Instanz-Feld.
RCLootcouncil hat eins, aber eine Gilde, die nur Gargul benutzt, hätte sonst
gar keine Instanz-Information. Nachträglich lässt sich das nicht mehr
rekonstruieren, im Moment des Betretens dagegen kostenlos.

Gespeichert wird bewusst nur ein Eintrag pro Instanz-Betreten, nicht pro
Zonenwechsel: ein Raid-Abend erzeugt so eine Handvoll Zeilen, keine Hunderte.
]]

local EHS = EventHelperSync

-- Wie lange die Zeitleiste aufgehoben wird. Etwas grosszügiger als das
-- Export-Fenster, damit auch eine ältere Session noch beschriftet werden kann.
local ZONE_KEEP_DAYS = 60

--- Ältere Einträge wegwerfen, damit die SavedVariables nicht endlos wachsen.
local function prune(zones, now)
    local cutoff = now - (ZONE_KEEP_DAYS * 24 * 60 * 60)
    local kept = {}
    for _, entry in ipairs(zones) do
        if entry.at >= cutoff then kept[#kept + 1] = entry end
    end
    return kept
end

--- Aktuelle Instanz festhalten, sofern wir in einer Raid-Instanz stecken.
function EHS:RecordZone()
    local name, instanceType = GetInstanceInfo()
    if instanceType ~= "raid" or not name or name == "" then return end

    local zones = self.db.zones
    local last = zones[#zones]
    local now = time()

    -- Beim selben Raid nicht bei jedem Ladebildschirm eine neue Zeile anlegen:
    -- ein Wipe mit Rückkehr ist derselbe Abend, kein neuer Ort.
    if last and last.name == name and (now - last.at) < (6 * 60 * 60) then
        last.until_ = now
        return
    end

    zones[#zones + 1] = { name = name, at = now, until_ = now }
    self.db.zones = prune(zones, now)
    self:Debug("Instanz betreten:", name)
end

--- Der Raid, in dem zum Zeitpunkt `at` gespielt wurde, oder "".
-- Nimmt den letzten Eintrag, der vor `at` begann und nicht länger als eine
-- Raid-Länge her ist — ein Item, das Stunden nach dem letzten Instanzbesuch
-- vergeben wurde, wird lieber gar nicht als falsch beschriftet.
function EHS:ZoneAt(at)
    local best, bestAt = "", 0
    for _, entry in ipairs(self.db.zones or {}) do
        if entry.at <= at and entry.at > bestAt and (at - entry.at) < (12 * 60 * 60) then
            best, bestAt = entry.name, entry.at
        end
    end
    return best
end

function EHS:StartZoneTracking()
    local frame = CreateFrame("Frame")
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    frame:RegisterEvent("ENCOUNTER_END")
    frame:SetScript("OnEvent", function() EHS:RecordZone() end)
    self:RecordZone()
end
