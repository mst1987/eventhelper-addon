--[[
Den Envelope bauen — das Format, das Addon, Sync-Tool und Server gemeinsam
sprechen ("eventhelper-loot", Version 1).

Serverseitig liest das src/utils/lootImport.js (parseEventHelperSessions). Wird
hier etwas am Format geändert, muss dort die Version mitwachsen: der Server
lehnt einen Payload mit höherer Version ab, statt ihn halb zu lesen.

Die JSON-Kodierung unten braucht das Addon nur für die Kopierbox (`/ehs export`).
Der normale Weg über das Sync-Tool nutzt sie nicht — dort liegt der Envelope als
gewöhnliche Lua-Tabelle in den SavedVariables, und das Tool wandelt selbst um.
]]

local EHS = EventHelperSync

local FORMAT = "eventhelper-loot"
local VERSION = 1

--- Voll qualifizierter Name des Spielers, der exportiert ("Name-Realm").
local function fullPlayerName()
    local name = UnitName("player") or ""
    local realm = GetRealmName() or ""
    realm = realm:gsub("%s+", "")
    if realm == "" then return name end
    return name .. "-" .. realm
end

--- Eine gesammelte Zeile auf die Felder reduzieren, die der Server liest.
-- Der Item-Link bleibt bewusst draussen: der Server baut sich den Wowhead-Link
-- aus der Item-ID selbst, und Links sind das mit Abstand längste Feld.
local function wireItem(row)
    return {
        source = row.source,
        rawId = row.rawId,
        itemId = row.itemId,
        itemName = row.itemName or "",
        player = row.player,
        class = row.class or "",
        response = row.response or "",
        offspec = row.offspec == true,
        boss = row.boss or "",
        instance = row.instance or "",
        note = row.note or "",
        replacedGear = row.replacedGear or {},
        awardedAt = row.awardedAt,
        awardedBy = row.awardedBy or "",
        gdkpCost = row.gdkpCost,
        votes = row.votes,
    }
end

--- Ist dieser Raid-Abend vom Export ausgenommen?
-- Abgewählt wird im Optionsfenster; die Auswahl lebt in den SavedVariables und
-- gilt dauerhaft, damit ein Pug-Abend nicht bei jedem Upload erneut auftaucht.
function EHS:IsExcluded(sessionId)
    return (self.db.excluded or {})[sessionId] == true
end

--- Einen Raid-Abend ein- oder ausschliessen.
function EHS:SetExcluded(sessionId, excluded)
    self.db.excluded = self.db.excluded or {}
    -- Ausgeschlossene werden gespeichert, eingeschlossene wieder entfernt: so
    -- wächst die Liste nur um das, was wirklich abgewählt wurde.
    self.db.excluded[sessionId] = excluded and true or nil
end

function EHS:BuildEnvelope(sessions)
    local wire = {}
    for _, session in ipairs(sessions or {}) do
        if not self:IsExcluded(session.sessionId) then
            local items = {}
            for _, row in ipairs(session.items) do
                items[#items + 1] = wireItem(row)
            end
            wire[#wire + 1] = {
                sessionId = session.sessionId,
                startedAt = session.startedAt,
                endedAt = session.endedAt,
                instance = session.instance or "",
                items = items,
            }
        end
    end

    return {
        format = FORMAT,
        version = VERSION,
        generatedAt = time(),
        realm = (GetRealmName() or ""):gsub("%s+", ""),
        reporter = fullPlayerName(),
        client = { addon = self.version, sync = "" },
        sessions = wire,
    }
end

-- ---------------------------------------------------------------------------
-- JSON (nur für die Kopierbox)
-- ---------------------------------------------------------------------------

local ESCAPES = {
    ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
    ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function escapeString(s)
    return (tostring(s):gsub('[%z\1-\31"\\]', function(c)
        return ESCAPES[c] or ("\\u%04x"):format(c:byte())
    end))
end

local encode

--- Array oder Objekt? Eine leere Tabelle gilt als Array — im Envelope sind alle
-- potenziell leeren Tabellen Listen (sessions, items, replacedGear).
local function isArray(t)
    for key in pairs(t) do
        if type(key) ~= "number" then return false end
    end
    return true
end

encode = function(value)
    local kind = type(value)
    if value == nil then return "null" end
    if kind == "boolean" then return value and "true" or "false" end
    if kind == "number" then
        -- Ganzzahlen ohne ".0" — Zeitstempel und Item-IDs sind alle ganzzahlig.
        if value == math.floor(value) then return ("%d"):format(value) end
        return tostring(value)
    end
    if kind == "string" then return '"' .. escapeString(value) .. '"' end
    if kind ~= "table" then return "null" end

    local parts = {}
    if isArray(value) then
        for _, entry in ipairs(value) do parts[#parts + 1] = encode(entry) end
        return "[" .. table.concat(parts, ",") .. "]"
    end

    -- Sortierte Schlüssel, damit zwei Exporte desselben Standes textgleich sind
    -- (macht "hat sich etwas geändert?" per Blick entscheidbar).
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, key in ipairs(keys) do
        parts[#parts + 1] = '"' .. escapeString(key) .. '":' .. encode(value[key])
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

function EHS:EncodeJSON(value)
    return encode(value)
end
