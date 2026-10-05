--[[
Loot-Council im Spiel - die Logik ohne Fenster.

Die Daten kommen nicht aus dem Spiel, sondern vom EventHelper-Server: das
Sync-Tool holt sie dort ab und schreibt sie als CouncilData.lua in diesen
Ordner (Format "eventhelper-council", Version 1, siehe README). Nach dem
naechsten /reload liegen sie in der globalen Variable EventHelperSync_Council.

Pro Raider: Bedarf 0..100 aus drei Teilen (Wartezeit seit dem letzten
zaehlenden Item, Anteil am Loot im Vergleich zum Schnitt, fehlende BiS-Teile),
die Items, die er schon bekommen hat, und die Item-IDs der BiS-Teile, die ihm
noch fehlen. Daraus macht diese Datei:

  * den Index Item-ID -> Raider, denen genau dieses Item fehlt (fuer den
    Item-Tooltip beim Verteilen),
  * die Texte und Farben, die Fenster und Tooltip anzeigen.

Bewusst ohne Client-Aufrufe ausser date(): so laesst sie sich ausserhalb des
Spiels testen (addon/test), und sie laeuft auf TBC Anniversary wie auf WoW
Forever gleich.
]]

local EHS = EventHelperSync

local Council = {}
EHS.Council = Council

Council.FORMAT = "eventhelper-council"
Council.VERSION = 1

-- Die drei Teile des Bedarfs, in der Reihenfolge der Anzeige. Die Gewichte
-- liefert der Server mit (weights); das hier ist nur der Rueckfall.
Council.PARTS = { "drought", "share", "need" }
local DEFAULT_WEIGHTS = { drought = 50, share = 40, need = 10 }

Council.PART_LABEL = { drought = "Wartezeit", share = "Loot-Anteil", need = "BiS-Lücke" }
Council.PART_HINT = {
    drought = "Wie lange sein letztes zählendes Item her ist.",
    share = "Wie wenig er im Vergleich zum Schnitt bekommen hat.",
    need = "Wie viel seiner BiS-Liste noch fehlt.",
}
Council.PART_COLOR = {
    drought = { 0.90, 0.60, 0.20 },
    share = { 0.30, 0.62, 0.95 },
    need = { 0.62, 0.42, 0.90 },
}

-- Klassenfarben, falls der Client keine RAID_CLASS_COLORS hat.
local CLASS_COLORS = {
    WARRIOR = { 0.78, 0.61, 0.43 }, PALADIN = { 0.96, 0.55, 0.73 }, HUNTER = { 0.67, 0.83, 0.45 },
    ROGUE = { 1.00, 0.96, 0.41 }, PRIEST = { 1.00, 1.00, 1.00 }, SHAMAN = { 0.00, 0.44, 0.87 },
    MAGE = { 0.25, 0.78, 0.92 }, WARLOCK = { 0.53, 0.53, 0.93 }, DRUID = { 1.00, 0.49, 0.04 },
    DEATHKNIGHT = { 0.77, 0.12, 0.23 },
}

local function num(value)
    return tonumber(value) or 0
end

local function int(value)
    return math.floor(num(value) + 0.5)
end

-- ---------------------------------------------------------------------------
-- Daten
-- ---------------------------------------------------------------------------

--- Die Council-Daten, sofern brauchbar.
-- @param raw optional, sonst die globale Variable aus CouncilData.lua
-- @return data|nil, status  status: "ok" | "none" | "format" | "version"
function Council.Load(raw)
    if raw == nil then raw = _G.EventHelperSync_Council end
    if type(raw) ~= "table" then return nil, "none" end
    if raw.format ~= Council.FORMAT or type(raw.raiders) ~= "table" then return nil, "format" end
    local version = tonumber(raw.version)
    if not version then return nil, "format" end
    if version > Council.VERSION then return nil, "version" end
    return raw, "ok"
end

--- Gewichte in Prozent, fehlende mit dem Rueckfallwert.
function Council.Weights(data)
    local weights = {}
    local given = type(data) == "table" and type(data.weights) == "table" and data.weights or {}
    for _, key in ipairs(Council.PARTS) do
        weights[key] = tonumber(given[key]) or DEFAULT_WEIGHTS[key]
    end
    return weights
end

local function byNeed(a, b)
    local na, nb = num(a.need), num(b.need)
    if na ~= nb then return na > nb end
    return tostring(a.character or "") < tostring(b.character or "")
end

--- Die Raider, optional nur eine Rolle ("caster"/"healer"), Bedarf absteigend.
function Council.Raiders(data, role)
    local out = {}
    if type(data) ~= "table" or type(data.raiders) ~= "table" then return out end
    for _, raider in ipairs(data.raiders) do
        if type(raider) == "table" and (not role or role == "" or raider.role == role) then
            out[#out + 1] = raider
        end
    end
    table.sort(out, byNeed)
    return out
end

--- Item-ID -> { { raider = r, copies = n }, ... }, Bedarf absteigend.
-- `copies` zaehlt, wie oft das Item in seiner Liste fehlt (zwei gleiche Ringe).
function Council.BuildIndex(data)
    local index = {}
    for _, raider in ipairs(Council.Raiders(data)) do
        local missing = type(raider.bis) == "table" and raider.bis.missing
        if type(missing) == "table" then
            local seen = {}
            for _, id in ipairs(missing) do
                local itemId = tonumber(id)
                if itemId then
                    if seen[itemId] then
                        seen[itemId].copies = seen[itemId].copies + 1
                    else
                        seen[itemId] = { raider = raider, copies = 1 }
                        index[itemId] = index[itemId] or {}
                        table.insert(index[itemId], seen[itemId])
                    end
                end
            end
        end
    end
    -- Council.Raiders() liefert schon sortiert, die Listen sind es damit auch.
    return index
end

-- Der Index haengt an genau einer Datentabelle; die aendert sich nur mit
-- einem /reload, also reicht es, ihn einmal zu bauen.
local cachedFor, cachedIndex

--- Die Raider, denen dieses Item als BiS fehlt (hoechstens `limit`).
-- @return list, total  total = alle Treffer, auch die ueber `limit` hinaus
function Council.ForItem(data, itemId, limit)
    itemId = tonumber(itemId)
    if not data or not itemId then return {}, 0 end
    if cachedFor ~= data then
        cachedIndex = Council.BuildIndex(data)
        cachedFor = data
    end
    local all = cachedIndex[itemId] or {}
    local out = {}
    for i = 1, math.min(#all, limit or #all) do out[i] = all[i] end
    return out, #all
end

-- ---------------------------------------------------------------------------
-- Zahlen und Texte
-- ---------------------------------------------------------------------------

--- Breiten der drei Balken-Abschnitte: Gewicht x Teil, zusammen = Bedarf.
-- @return { drought = px, share = px, need = px }
function Council.Segments(raider, weights, width)
    local parts = type(raider) == "table" and type(raider.parts) == "table" and raider.parts or {}
    local out = {}
    for _, key in ipairs(Council.PARTS) do
        local part = math.max(0, math.min(100, num(parts[key])))
        out[key] = width * (num(weights[key]) / 100) * (part / 100)
    end
    return out
end

--- Wie lange etwas her ist: "vor 3 Tagen", "noch nie".
function Council.FormatAge(at, now)
    at = num(at)
    if at <= 0 then return "noch nie" end
    local seconds = num(now) - at
    if seconds < 60 then return "gerade eben" end
    if seconds < 3600 then return ("vor %d Min."):format(math.floor(seconds / 60)) end
    if seconds < 86400 then return ("vor %d Std."):format(math.floor(seconds / 3600)) end
    local days = math.floor(seconds / 86400)
    if days == 1 then return "vor 1 Tag" end
    return ("vor %d Tagen"):format(days)
end

--- "05.10. 21:30"
function Council.FormatStamp(at)
    return date("%d.%m. %H:%M", int(at))
end

--- Kopfzeile des Fensters: wie alt die Daten sind.
function Council.Header(data, now)
    local at = int(data and data.generatedAt)
    if at <= 0 then return "Stand: unbekannt" end
    return ("Stand: %s, %s"):format(Council.FormatStamp(at), Council.FormatAge(at, now))
end

Council.ROLE_LABEL = { caster = "Caster", healer = "Heiler" }

--- Filterzeile: Kategorie, Rolle (falls der Server schon gefiltert hat), BiS-Stufe.
function Council.FilterLine(data)
    local filter = type(data) == "table" and type(data.filter) == "table" and data.filter or {}
    local parts = {}
    if filter.categoryName and filter.categoryName ~= "" then
        parts[#parts + 1] = filter.categoryName
    else
        parts[#parts + 1] = "Alle Raids"
    end
    if Council.ROLE_LABEL[filter.role] then parts[#parts + 1] = "nur " .. Council.ROLE_LABEL[filter.role] end
    if filter.bisTier and filter.bisTier ~= "" then
        parts[#parts + 1] = "BiS " .. tostring(filter.bisTier):upper()
    end
    return table.concat(parts, " · ")
end

function Council.ItemsLabel(count)
    count = int(count)
    if count == 1 then return "1 Item" end
    return ("%d Items"):format(count)
end

function Council.BisLabel(raider)
    local bis = type(raider) == "table" and type(raider.bis) == "table" and raider.bis or {}
    if int(bis.total) <= 0 then return "BiS -" end
    return ("BiS %d/%d"):format(int(bis.owned), int(bis.total))
end

function Council.MissingCount(raider)
    local bis = type(raider) == "table" and type(raider.bis) == "table" and raider.bis or {}
    if type(bis.missing) == "table" then return #bis.missing end
    return math.max(0, int(bis.total) - int(bis.owned))
end

--- Klassenfarbe als r, g, b.
function Council.ClassColor(classFile)
    local key = tostring(classFile or ""):upper()
    local colors = _G.CUSTOM_CLASS_COLORS or _G.RAID_CLASS_COLORS
    local c = type(colors) == "table" and colors[key]
    if type(c) == "table" and c.r then return c.r, c.g, c.b end
    local fallback = CLASS_COLORS[key]
    if fallback then return fallback[1], fallback[2], fallback[3] end
    return 0.8, 0.8, 0.8
end

--- Farbe fuer die Bedarfszahl: hoch = gruen, mittel = gelb, niedrig = grau.
function Council.NeedColor(need)
    need = num(need)
    if need >= 67 then return 0.35, 0.90, 0.35 end
    if need >= 34 then return 1.00, 0.82, 0.00 end
    return 0.65, 0.65, 0.65
end

--- Text in einer Farbe (|cffRRGGBB...|r).
function Council.Color(text, r, g, b)
    local function hex(v) return math.max(0, math.min(255, math.floor((tonumber(v) or 0) * 255 + 0.5))) end
    return ("|cff%02x%02x%02x%s|r"):format(hex(r), hex(g), hex(b), tostring(text))
end

--- "Gemli" in Klassenfarbe, dahinter die Spezialisierung in grau.
function Council.NameLabel(raider)
    local name = Council.Color(raider.character or "?", Council.ClassColor(raider.classFile))
    if raider.specLabel and raider.specLabel ~= "" then
        name = name .. " " .. Council.Color(raider.specLabel, 0.6, 0.6, 0.6)
    end
    return name
end

--- Eine Tooltip-Zeile: "Gemli (Shadow) Bedarf 82 - 2 Items".
function Council.TooltipLine(raider)
    local name = Council.Color(raider.character or "?", Council.ClassColor(raider.classFile))
    if raider.specLabel and raider.specLabel ~= "" then name = name .. " (" .. raider.specLabel .. ")" end
    return ("%s %s - %s"):format(name,
        Council.Color(("Bedarf %d"):format(int(raider.need)), Council.NeedColor(raider.need)),
        Council.ItemsLabel(raider.lootCount))
end

Council.TOOLTIP_HEADER = "Loot-Council:"

--- Die Zeilen fuer einen Item-Tooltip, oder nil, wenn das Item niemandem fehlt.
function Council.TooltipLines(data, itemId, limit)
    local list, total = Council.ForItem(data, itemId, limit or 5)
    if #list == 0 then return nil end
    local lines = {}
    for _, entry in ipairs(list) do
        local line = Council.TooltipLine(entry.raider)
        if entry.copies > 1 then line = line .. (" (fehlt %dx)"):format(entry.copies) end
        lines[#lines + 1] = line
    end
    if total > #list then lines[#lines + 1] = ("... und %d weitere"):format(total - #list) end
    return lines
end
