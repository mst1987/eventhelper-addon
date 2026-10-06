--[[
Loot-Council im Spiel - die Logik ohne Fenster.

Die Daten kommen nicht aus dem Spiel, sondern vom EventHelper-Server: das
Sync-Tool holt sie dort ab und schreibt sie als CouncilData.lua in diesen
Ordner (Format "eventhelper-council", siehe README). Nach dem naechsten
/reload liegen sie in der globalen Variable EventHelperSync_Council.

Version 2: jede Raid-Kategorie, deren Lootsystem auf der Webseite
Loot-Council ist, mit den Filtern der Loot-Council-Seite (categories = {...}).
Version 1 (ein aelteres Sync-Tool) hat nur eine Raider-Liste; Load() macht
daraus eine einzige Kategorie, der Rest der Datei kennt nur Kategorien.

Pro Raider: Bedarf 0..100 aus drei Teilen (Wartezeit seit dem letzten
zaehlenden Item, Anteil am Loot im Vergleich zum Schnitt, fehlende BiS-Teile),
die Items, die er schon bekommen hat, und die Item-IDs der BiS-Teile, die ihm
noch fehlen. Daraus macht diese Datei:

  * den Index Item-ID -> Raider, denen genau dieses Item fehlt (fuer den
    Item-Tooltip beim Verteilen),
  * die Auswahl der Kategorie (von Hand, oder passend zur Raid-Instanz),
  * die Texte und Farben, die Fenster und Tooltip anzeigen.

Bewusst ohne Client-Aufrufe ausser date(): so laesst sie sich ausserhalb des
Spiels testen (addon-test), und sie laeuft auf TBC Anniversary wie auf WoW
Forever gleich.
]]

local EHS = EventHelperSync

local Council = {}
EHS.Council = Council

Council.FORMAT = "eventhelper-council"
Council.VERSION = 2

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

local function trim(text)
    return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Ein Kategorie-Name, wie ihn die Spielschrift zeigen kann. Das Sync-Tool
-- nimmt Emoji schon heraus; ein aelteres macht daraus "?". Die fallen hier am
-- Anfang und Ende weg, ebenso Trenner ("? | SSC ?" -> "SSC").
-- @return name, sonst "Kategorie <id>"
function Council.CleanName(name, id)
    local text = trim(tostring(name or ""):gsub("%s+", " "))
    text = text:gsub("^[%s%?%-|:/,;%*~_%.]+", "")
    -- Ein " ?" am Ende war ein Emoji; ein "Wort?" ist eine Frage und bleibt.
    repeat
        local before = text
        text = text:gsub("%s+%?+$", ""):gsub("[%s%-|:/,;%*~_]+$", "")
    until text == before
    if text == "" then return trim("Kategorie " .. tostring(id or "")) end
    return text
end

local function normalizeCategory(raw, index)
    local id = raw.id ~= nil and tostring(raw.id) or tostring(index)
    return {
        id = id,
        name = Council.CleanName(raw.name, id),
        lootSystem = raw.lootSystem,
        filter = type(raw.filter) == "table" and raw.filter or {},
        instances = type(raw.instances) == "table" and raw.instances or {},
        avgLootCount = raw.avgLootCount,
        raiders = raw.raiders,
    }
end

-- Load() baut die Kategorien einmal je Datentabelle (die aendert sich nur
-- mit einem /reload) - und dieselbe Tabelle haelt die Caches darunter.
local loadedCache = setmetatable({}, { __mode = "k" })

--- Die Council-Daten, sofern brauchbar, immer in der Form von Version 2:
-- { format, version = 2, generatedAt, weights, categories = { {id, name,
-- filter, instances, avgLootCount, raiders}, ... }, fromVersion }.
-- @param raw optional, sonst die globale Variable aus CouncilData.lua
-- @return data|nil, status  status: "ok" | "none" | "format" | "version"
function Council.Load(raw)
    if raw == nil then raw = _G.EventHelperSync_Council end
    if type(raw) ~= "table" then return nil, "none" end
    if raw.format ~= Council.FORMAT then return nil, "format" end
    local version = tonumber(raw.version)
    if not version then return nil, "format" end
    if version > Council.VERSION then return nil, "version" end
    if loadedCache[raw] then return loadedCache[raw], "ok" end

    local data = {
        format = raw.format, version = Council.VERSION, generatedAt = raw.generatedAt,
        weights = raw.weights, categories = {},
    }
    if version < 2 then
        -- Version 1: eine Kategorie, gefiltert vom Sync-Tool.
        if type(raw.raiders) ~= "table" then return nil, "format" end
        local filter = type(raw.filter) == "table" and raw.filter or {}
        data.fromVersion = 1
        data.categories[1] = normalizeCategory({
            id = filter.category or "",
            name = (filter.categoryName and filter.categoryName ~= "") and filter.categoryName or "Alle Raids",
            filter = { role = filter.role or "", bisTier = filter.bisTier, bisTierDerived = filter.bisTierDerived },
            avgLootCount = raw.avgLootCount,
            raiders = raw.raiders,
        }, 1)
    else
        if type(raw.categories) ~= "table" then return nil, "format" end
        data.fromVersion = raw.fromVersion
        for index, category in ipairs(raw.categories) do
            if type(category) == "table" and type(category.raiders) == "table" then
                data.categories[#data.categories + 1] = normalizeCategory(category, index)
            end
        end
    end
    loadedCache[raw] = data
    return data, "ok"
end

--- Die Kategorien (leer, wenn keine Kategorie Loot-Council hat).
function Council.Categories(data)
    return type(data) == "table" and type(data.categories) == "table" and data.categories or {}
end

function Council.FindCategory(data, id)
    if id == nil or id == "" then return nil end
    id = tostring(id)
    for _, category in ipairs(Council.Categories(data)) do
        if category.id == id then return category end
    end
    return nil
end

--- Die Kategorie, die gerade gilt.
-- @param manualId die von Hand gewaehlte (gespeichert), oder nil
-- @param autoId die zur Raid-Instanz passende, oder nil
-- @return category|nil, how  how: "auto" | "manual" | "default"
function Council.ActiveCategory(data, manualId, autoId)
    local auto = Council.FindCategory(data, autoId)
    if auto then return auto, "auto" end
    local manual = Council.FindCategory(data, manualId)
    if manual then return manual, "manual" end
    local first = Council.Categories(data)[1]
    if first then return first, "default" end
    return nil, nil
end

-- Kleinschreibung fuer den Vergleich: string.lower kennt nur ASCII, die
-- Umlaute am Wortanfang (UTF-8) kommen von Hand dazu.
local UPPER_UMLAUTS = { { "Ä", "ä" }, { "Ö", "ö" }, { "Ü", "ü" } }

local function placeKey(text)
    local s = tostring(text or ""):lower()
    for _, pair in ipairs(UPPER_UMLAUTS) do s = s:gsub(pair[1], pair[2]) end
    -- "Serpentshrine Cavern (Forever)" heisst im Spiel ohne den Zusatz.
    s = s:gsub("%(forever%)", "")
    return trim(s:gsub("%s+", " "))
end

--- Passt ein Name aus der Kategorie zu einem Ort im Spiel? Gleich, oder einer
-- enthaelt den anderen - kurze Kuerzel ("BT", "SSC") nur, wenn sie gleich sind.
local function placeMatches(term, place)
    if term == "" or place == "" then return false end
    if term == place then return true end
    if #term >= 4 and place:find(term, 1, true) then return true end
    if #place >= 4 and term:find(place, 1, true) then return true end
    return false
end

--- Die Kategorien, deren Instanzen zu einem der Orte passen.
-- @param places { names = { "Instanzname", "Zonenname" }, instanceId = 548 }
function Council.MatchCategories(data, places)
    local out = {}
    if type(places) ~= "table" then return out end
    local keys = {}
    for _, name in ipairs(places.names or {}) do
        local key = placeKey(name)
        if key ~= "" then keys[#keys + 1] = key end
    end
    local placeId = tonumber(places.instanceId)
    for _, category in ipairs(Council.Categories(data)) do
        local hit = false
        for _, instance in ipairs(category.instances) do
            if type(instance) == "table" then
                if placeId and tonumber(instance.id) == placeId then hit = true end
                local terms = { instance.name, instance.short }
                for _, zone in ipairs(type(instance.zoneNames) == "table" and instance.zoneNames or {}) do
                    terms[#terms + 1] = zone
                end
                for _, term in ipairs(terms) do
                    local t = placeKey(term)
                    for _, key in ipairs(keys) do
                        if placeMatches(t, key) then hit = true end
                    end
                end
            end
        end
        if hit then out[#out + 1] = category end
    end
    return out
end

--- Die Kategorie zu einem getippten Namen (/ehc ssc): erst Anfang des Namens,
-- dann irgendwo darin, ohne Gross/klein.
function Council.CategoryByText(data, text)
    local key = placeKey(text)
    if key == "" then return nil end
    for _, category in ipairs(Council.Categories(data)) do
        if placeKey(category.name):sub(1, #key) == key then return category end
    end
    for _, category in ipairs(Council.Categories(data)) do
        if placeKey(category.name):find(key, 1, true) then return category end
    end
    return nil
end

local function raiderKey(raider)
    return tostring(raider.key or raider.character or ""):lower()
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

--- Die Raider einer Kategorie, optional nur eine Rolle ("caster"/"healer"),
-- Bedarf absteigend.
function Council.Raiders(category, role)
    local out = {}
    if type(category) ~= "table" or type(category.raiders) ~= "table" then return out end
    for _, raider in ipairs(category.raiders) do
        if type(raider) == "table" and (not role or role == "" or raider.role == role) then
            out[#out + 1] = raider
        end
    end
    table.sort(out, byNeed)
    return out
end

--- Item-ID -> { { raider = r, copies = n }, ... }, Bedarf absteigend.
-- `copies` zaehlt, wie oft das Item in seiner Liste fehlt (zwei gleiche Ringe).
-- @param category eine Kategorie
function Council.BuildIndex(category)
    local index = {}
    for _, raider in ipairs(Council.Raiders(category)) do
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

-- Ein Index je Kategorie (bzw. je Datentabelle fuer alle zusammen); die
-- Daten aendern sich nur mit einem /reload, also reicht es, ihn einmal zu
-- bauen. Schwache Schluessel: alte Daten gehen weg.
local indexCache = setmetatable({}, { __mode = "k" })

local function indexOf(source)
    if not indexCache[source] then
        if type(source.categories) == "table" then
            -- Alle Kategorien zusammen: je Item jeder Raider nur einmal, mit
            -- seinem Eintrag aus der ersten Kategorie, in der ihm das Item fehlt.
            local index = {}
            for _, category in ipairs(source.categories) do
                for itemId, entries in pairs(indexOf(category)) do
                    local list = index[itemId] or {}
                    index[itemId] = list
                    local have = {}
                    for _, entry in ipairs(list) do have[raiderKey(entry.raider)] = true end
                    for _, entry in ipairs(entries) do
                        local key = raiderKey(entry.raider)
                        if not have[key] then
                            have[key] = true
                            list[#list + 1] = entry
                        end
                    end
                end
            end
            for _, list in pairs(index) do
                table.sort(list, function(a, b) return byNeed(a.raider, b.raider) end)
            end
            indexCache[source] = index
        else
            indexCache[source] = Council.BuildIndex(source)
        end
    end
    return indexCache[source]
end

--- Die Raider, denen dieses Item als BiS fehlt (hoechstens `limit`).
-- @param source eine Kategorie, oder die Daten aus Load() fuer alle
--   Kategorien zusammen (jeder Raider einmal)
-- @return list, total  total = alle Treffer, auch die ueber `limit` hinaus
function Council.ForItem(source, itemId, limit)
    itemId = tonumber(itemId)
    if type(source) ~= "table" or not itemId then return {}, 0 end
    local all = indexOf(source)[itemId] or {}
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

--- Filterzeile einer Kategorie: Name, Rolle (falls die Webseite schon
-- gefiltert hat), Tiers, BiS-Stufe.
function Council.FilterLine(category)
    local filter = type(category) == "table" and type(category.filter) == "table" and category.filter or {}
    local parts = {}
    local name = type(category) == "table" and category.name
    parts[#parts + 1] = (name and name ~= "") and name or "Alle Raids"
    if Council.ROLE_LABEL[filter.role] then parts[#parts + 1] = "nur " .. Council.ROLE_LABEL[filter.role] end
    if type(filter.tiers) == "table" and #filter.tiers > 0 then
        local tiers = {}
        for _, tier in ipairs(filter.tiers) do tiers[#tiers + 1] = tostring(tier):upper() end
        parts[#parts + 1] = table.concat(tiers, "/")
    end
    if filter.bisTier and filter.bisTier ~= "" then
        parts[#parts + 1] = "BiS " .. tostring(filter.bisTier):upper()
    end
    return table.concat(parts, " · ")
end

--- Warum eine Rolle in dieser Kategorie leer bleibt: die Webseite zeigt dort
-- nur eine andere Rolle. Sonst nil.
function Council.RoleBlockedText(category, role)
    local filter = type(category) == "table" and type(category.filter) == "table" and category.filter or {}
    local only = Council.ROLE_LABEL[filter.role]
    if not only or not role or role == "" or role == filter.role then return nil end
    return ("Diese Kategorie zeigt nur %s (Einstellung auf der Webseite)."):format(only)
end

Council.NO_CATEGORY_TEXT = "Keine Kategorie mit Loot-Council: auf der Webseite unter Einstellungen > Kategorien "
    .. "das Lootsystem auf Loot-Council stellen."

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
-- @param source eine Kategorie, oder die Daten fuer alle Kategorien zusammen
function Council.TooltipLines(source, itemId, limit)
    local list, total = Council.ForItem(source, itemId, limit or 5)
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
