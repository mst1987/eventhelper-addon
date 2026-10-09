--[[
Loot-Council im Spiel - die Logik ohne Fenster.

Die Daten kommen nicht aus dem Spiel, sondern vom EventHelper-Server: das
Sync-Tool holt sie dort ab und schreibt sie als CouncilData.lua in diesen
Ordner (Format "eventhelper-council", siehe README). Nach dem naechsten
/reload liegen sie in der globalen Variable EventHelperSync_Council.

Version 2: jede Raid-Kategorie, deren Lootsystem auf der Webseite
Loot-Council ist, mit den Filtern der Loot-Council-Seite (categories = {...}).
Version 3 (ab 1.14.0): dazu alle fuenf Rollen (caster, healer, tank, melee,
ranged), der Roster-Status (Probe/Ersatz), Loot-Punkte, Zugehoerigkeit und je
Kategorie ihre Gewichtung (weights, itemWeights, itemClasses) - damit rechnet
ApplyAwards() eine Vergabe nach dem Sync genau wie der Server. Ein Sync-Tool
schreibt aeltere Antworten als Version 3 ohne Gewichtung (fromVersion); eine
Kategorie ohne weights rechnet wie bisher mit drei Teilen. Version 1 (ein
aelteres Sync-Tool) hat nur eine Raider-Liste; Load() macht daraus eine
einzige Kategorie, der Rest der Datei kennt nur Kategorien.

Pro Raider: Bedarf 0..100 aus drei Teilen (Wartezeit seit dem letzten
zaehlenden Item, Anteil am Loot im Vergleich zum Schnitt, fehlende BiS-Teile;
mit Gewichtung ein vierter: Zugehoerigkeit),
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
Council.VERSION = 3

-- Die drei Teile des Bedarfs, in der Reihenfolge der Anzeige. Die Gewichte
-- liefert der Server mit (weights); das hier ist nur der Rueckfall.
Council.PARTS = { "drought", "share", "need" }
-- Mit der Gewichtung einer Kategorie (Version 3): dazu die Zugehoerigkeit.
Council.PARTS_V3 = { "drought", "share", "need", "tenure" }
local DEFAULT_WEIGHTS = { drought = 50, share = 40, need = 10 }

Council.PART_LABEL = { drought = "Wartezeit", share = "Loot-Anteil", need = "BiS-Lücke", tenure = "Zugehörigkeit" }
Council.PART_HINT = {
    drought = "Wie lange sein letztes zählendes Item her ist.",
    share = "Wie wenig er im Vergleich zum Schnitt bekommen hat.",
    need = "Wie viel seiner BiS-Liste noch fehlt.",
    tenure = "Wie lange er schon zum Raid gehört.",
}
Council.PART_COLOR = {
    drought = { 0.90, 0.60, 0.20 },
    share = { 0.30, 0.62, 0.95 },
    need = { 0.62, 0.42, 0.90 },
    tenure = { 0.35, 0.78, 0.50 },
}

-- Die Rollen des Councils (Version 3; Version 1/2 kennen nur caster/healer).
Council.ROLES = { "caster", "healer", "tank", "melee", "ranged" }

-- Die Gewichte der Item-Klassen, wenn die Daten keine nennen (die Vorgaben
-- des Servers, councilWeightsStore.js DEFAULTS).
Council.DEFAULT_CLASS_WEIGHTS = { trinket = 2, bisWeapon = 2, weapon = 1.5, set = 1, normal = 1, frequent = 0.5 }
-- Deckel der Wartezeit und Saettigung der Zugehoerigkeit in Tagen (Rueckfall).
local DROUGHT_DAYS = 30
local TENURE_DAYS = 90
local DAY = 86400

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
    local category = {
        id = id,
        name = Council.CleanName(raw.name, id),
        lootSystem = raw.lootSystem,
        filter = type(raw.filter) == "table" and raw.filter or {},
        instances = type(raw.instances) == "table" and raw.instances or {},
        avgLootCount = raw.avgLootCount,
        raiders = raw.raiders,
    }
    -- Version 3: die Gewichtung der Kategorie. Nur mit `weights.shares` gilt
    -- sie als da (sonst rechnet die Kategorie wie Version 2).
    if type(raw.weights) == "table" and type(raw.weights.shares) == "table" then
        category.weights = raw.weights
        category.itemWeights = type(raw.itemWeights) == "table" and raw.itemWeights or {}
        category.itemClasses = type(raw.itemClasses) == "table" and raw.itemClasses or {}
        category.avgLootPoints = raw.avgLootPoints
    end
    return category
end

-- Load() baut die Kategorien einmal je Datentabelle (die aendert sich nur
-- mit einem /reload) - und dieselbe Tabelle haelt die Caches darunter.
local loadedCache = setmetatable({}, { __mode = "k" })

--- Die Council-Daten, sofern brauchbar, immer in der Form von Version 3:
-- { format, version = 3, generatedAt, weights, categories = { {id, name,
-- filter, instances, avgLootCount, raiders [, weights, itemWeights,
-- itemClasses, avgLootPoints]}, ... }, fromVersion }. Gelesen werden
-- Version 1, 2 und 3.
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

--- Hat die Kategorie ihre eigene Gewichtung (Version 3)?
function Council.IsWeighted(category)
    return type(category) == "table" and type(category.weights) == "table"
        and type(category.weights.shares) == "table"
end

--- Die Teile des Bedarfs einer Kategorie: mit Gewichtung vier, sonst drei.
function Council.PartsOf(category)
    return Council.IsWeighted(category) and Council.PARTS_V3 or Council.PARTS
end

--- Die Gewichte in Prozent fuer Balken und Legende: die der Kategorie
--- (Version 3), sonst die der Daten (Council.Weights).
function Council.WeightsFor(data, category)
    if not Council.IsWeighted(category) then return Council.Weights(data) end
    local given, shares = category.weights, category.weights.shares
    local weights = {}
    for _, key in ipairs(Council.PARTS_V3) do
        weights[key] = tonumber(given[key]) or (num(shares[key]) * 100)
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
-- Daten aendern sich nur mit einem /reload - oder ApplyAwards() liefert neue
-- Tabellen -, also reicht es, ihn einmal je Tabelle zu bauen. Schwache
-- Schluessel: alte Daten gehen weg.
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

--- Breiten der Balken-Abschnitte: Gewicht x Teil, zusammen = Bedarf.
-- @param keys die Teile (Council.PartsOf), sonst die drei von Version 2
-- @return { drought = px, share = px, need = px [, tenure = px] }
function Council.Segments(raider, weights, width, keys)
    local parts = type(raider) == "table" and type(raider.parts) == "table" and raider.parts or {}
    local out = {}
    for _, key in ipairs(keys or Council.PARTS) do
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

Council.ROLE_LABEL = { caster = "Caster", healer = "Heiler", tank = "Tank", melee = "Nahkampf", ranged = "Fernkampf" }

-- Der Roster-Status als Abzeichen (Version 3). Stamm bekommt keins: Stamm und
-- Probe sind beide Kandidaten, Probe ist nur ein Hinweis; Ersatz steht nur da,
-- wenn die Webseite ihn mitschickt.
Council.STATUS_LABEL = { trial = "Probe", bench = "Ersatz" }
Council.STATUS_COLOR = { trial = { 0.45, 0.78, 1.00 }, bench = { 0.70, 0.70, 0.70 } }

--- "Probe"/"Ersatz" in seiner Farbe, sonst "".
function Council.StatusBadge(raider)
    local status = type(raider) == "table" and raider.status or nil
    local label = Council.STATUS_LABEL[status]
    if not label then return "" end
    return Council.Color(label, unpack(Council.STATUS_COLOR[status]))
end

--- "3,5 Pkt" (deutsches Komma, ganze Zahlen ohne Nachkommastelle).
function Council.PointsLabel(points)
    local value = math.floor(num(points) * 10 + 0.5) / 10
    local textValue
    if value == math.floor(value) then
        textValue = ("%d"):format(value)
    else
        textValue = (("%.1f"):format(value):gsub("%.", ","))
    end
    return textValue .. " Pkt"
end

--- Die Spalte "Items": mit Gewichtung "2 Items · 3,5 Pkt", sonst "2 Items".
function Council.LootLabel(raider, weighted)
    local label = Council.ItemsLabel(type(raider) == "table" and raider.lootCount or 0)
    if weighted and type(raider) == "table" and raider.lootPoints ~= nil then
        label = label .. " · " .. Council.PointsLabel(raider.lootPoints)
    end
    return label
end

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

--- "Gemli" in Klassenfarbe, dahinter das Status-Abzeichen (Probe/Ersatz) und
--- die Spezialisierung in grau (die wird bei Platzmangel zuerst abgeschnitten).
function Council.NameLabel(raider)
    local name = Council.Color(raider.character or "?", Council.ClassColor(raider.classFile))
    local badge = Council.StatusBadge(raider)
    if badge ~= "" then name = name .. " " .. badge end
    if raider.specLabel and raider.specLabel ~= "" then
        name = name .. " " .. Council.Color(raider.specLabel, 0.6, 0.6, 0.6)
    end
    return name
end

--- Eine Tooltip-Zeile: "Gemli (Shadow) Bedarf 82 - 2 Items".
function Council.TooltipLine(raider)
    local name = Council.Color(raider.character or "?", Council.ClassColor(raider.classFile))
    if raider.specLabel and raider.specLabel ~= "" then name = name .. " (" .. raider.specLabel .. ")" end
    local badge = Council.StatusBadge(raider)
    if badge ~= "" then name = name .. " " .. badge end
    return ("%s %s%s - %s"):format(name,
        Council.Color(("Bedarf %d"):format(int(raider.need)), Council.NeedColor(raider.need)),
        Council.ProvisionalMark(raider), Council.ItemsLabel(raider.lootCount))
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

-- ---------------------------------------------------------------------------
-- Vergaben seit dem letzten Sync (vorlaeufig)
-- ---------------------------------------------------------------------------
--
-- Die Council-Daten sind der Stand des Servers zum Zeitpunkt generatedAt. Was
-- danach im Raid vergeben wird, steht schon in den Historien von
-- RCLootcouncil und Gargul (Collect.lua liest sie). ApplyAwards() rechnet es
-- hier nach denselben Regeln wie der Server dazu - vorlaeufig, bis der
-- naechste Sync es mitbringt (dann ist generatedAt neuer, und die Vergaben
-- fallen ueber den Zeitstempel von selbst wieder heraus).
--
-- Nachgebaut aus dem EventHelper (Repo eventhelper):
--   src/utils/loot/lootReasons.js  reasonIdFor(), countsAsLoot()
--   src/web/loot/lootCouncil.js    needScore(), scoreRows(), rosterRow()
--   src/web/loot/councilSync.js    raiderView() (Prozentwerte, Rundung)

-- Die Gruende des Servers, mit seinen Beschriftungen (REASONS).
Council.REASON_LABEL = {
    bis = "BiS", mainspec = "Mainspec", upgrade = "Upgrade", minor = "Kleines Upgrade",
    offspec = "Offspec", pvp = "PvP", greed = "Greed", disenchant = "Entzaubert", bank = "Bank",
    other = "Sonstiges",
}

-- COUNTING_REASONS: was als "hat schon etwas bekommen" zaehlt. "other" zaehlt
-- mit - eine unbekannte Antwort ist viel oefter die Hauptspec-Taste einer
-- Gilde als ein Splitter.
local COUNTING_REASONS = { bis = true, mainspec = true, upgrade = true, minor = true, other = true }

-- PATTERNS aus lootReasons.js, in derselben Reihenfolge (der erste Treffer
-- gewinnt). Lua kennt kein \b und kein "|": je Grund eine Liste von Mustern
-- auf den kleingeschriebenen Text, \b als Frontier %f[%w_] / %f[^%w_].
local function word(w) return "%f[%w_]" .. w .. "%f[^%w_]" end
local REASON_PATTERNS = {
    { "disenchant", { "disenchant", "entzauber", word("shard"), word("sharding"), word("de") } },
    { "bank", { "bank" } },
    { "pvp", { word("pvp"), "arena", "resil" } },
    { "offspec", { "off.?spec", word("os"), "zweit.?spec", "neben.?spec", "second.?spec", "dual.?spec" } },
    { "bis", { word("bis"), "best.?in.?slot" } },
    { "minor", { "minor", "klein", "side.?grade", "leichte" } },
    { "upgrade", { "upgrade", "major", "verbesserung", "aufwert" } },
    { "mainspec", { "main.?spec", "haupt.?spec", word("ms"), word("need"), "bedarf" } },
    { "greed", { "greed", "gier", "free", "kostenlos", word("fun"), "transmog", word("mog"), "twink",
        word("alt"), "%f[%w_]rest" } },
    { "other", { "auto.?pass", "^%s*pass%s*$", "verzicht" } },
}

--- Der Grund einer Vergabe wie reasonIdFor() des Servers: der Antworttext
-- entscheidet; sagt er nichts Bekanntes, trennt das Offspec-Kennzeichen.
-- @return einer der Schluessel von Council.REASON_LABEL
function Council.ReasonFor(response, offspec)
    local text = trim(response):lower()
    if text ~= "" then
        for _, entry in ipairs(REASON_PATTERNS) do
            for _, pattern in ipairs(entry[2]) do
                if text:find(pattern) then return entry[1] end
            end
        end
    end
    return offspec and "offspec" or "other"
end

--- Zaehlt eine Vergabe mit diesem Grund als erhaltenes Item (countsAsLoot)?
function Council.CountsAsLoot(reason)
    return COUNTING_REASONS[tostring(reason or "other")] == true
end

-- Kleinschreibung fuer Namen: ASCII, dazu die Grossbuchstaben aus Latin-1
-- (UTF-8 C3 80 bis C3 9E, ausser dem Malzeichen C3 97), wie toLowerCase().
-- Die Bytes per string.char: als Zeichen im Quelltext waeren sie kein
-- gueltiges UTF-8.
local LATIN1_LEAD = string.char(0xC3)
local LATIN1_UPPER = LATIN1_LEAD .. "([" .. string.char(0x80) .. "-" .. string.char(0x9E) .. "])"
local function lowerName(text)
    return (tostring(text or ""):lower():gsub(LATIN1_UPPER, function(c)
        if c:byte() == 0x97 then return nil end
        return LATIN1_LEAD .. string.char(c:byte() + 32)
    end))
end

--- Der Vergleichsschluessel eines Spielernamens wie characterKeyOf() des
-- Servers: Realm ab dem ersten "-" weg, eine Version davor ("forever~")
-- auch, klein geschrieben. "Gemli-Thunderstrike" -> "gemli".
function Council.NameKey(name)
    local text = trim(name)
    local tilde = text:find("~", 1, true)
    if tilde then text = text:sub(tilde + 1) end
    local dash = text:find("-", 1, true)
    if dash then text = text:sub(1, dash - 1) end
    return lowerName(trim(text))
end

local function round(x) return math.floor(x + 0.5) end
local function round3(x) return round(x * 1000) / 1000 end
local function pct(x) return math.max(0, math.min(100, round((tonumber(x) or 0) * 100))) end

--- Der Bedarf eines Raiders wie needScore() des Servers, in der Form der
-- Council-Daten (0..100, gerundet wie raiderView()).
-- @param row { daysSinceLoot (-1/nil = noch nie), lootCount, bis = { owned, total } }
-- @param avg Durchschnitt lootCount der Kategorie
-- @param weights Gewichte in Prozent (Council.Weights)
-- @return need, parts
function Council.NeedScore(row, avg, weights)
    local days = tonumber(row.daysSinceLoot)
    if not days or days < 0 then days = 30 end
    local drought = math.min(1, days / 30)
    local lootCount = num(row.lootCount)
    local share = 0.5
    if avg > 0 then share = math.max(0, math.min(1, (avg - lootCount) / math.max(1, avg))) end
    local bis = type(row.bis) == "table" and row.bis or {}
    local total, owned = num(bis.total), num(bis.owned)
    local need = 0.5
    if total > 0 then need = 1 - (owned / total) end
    local w = weights or DEFAULT_WEIGHTS
    local score = (num(w.drought) / 100) * drought + (num(w.share) / 100) * share + (num(w.need) / 100) * need
    return pct(round3(score)), {
        drought = pct(round3(drought)), share = pct(round3(share)), need = pct(round3(need)),
    }
end

-- ---------------------------------------------------------------------------
-- Mit der Gewichtung einer Kategorie (Version 3)
-- ---------------------------------------------------------------------------
--
-- Nachgebaut aus dem EventHelper:
--   src/services/loot/itemWeights.js  itemClass(), itemWeight()
--   src/web/loot/lootCouncil.js       droughtDays()/droughtCounter(), needScore()
--   src/web/loot/councilSync.js       raiderViewV3() (droughtBase, Rundung)

local function round1(x) return math.floor(x * 10 + 0.5) / 10 end

local function idKey(itemId)
    local id = tonumber(itemId)
    if not id then return "" end
    return ("%d"):format(id)
end

local function inList(list, itemId)
    local id = tonumber(itemId)
    if type(list) ~= "table" or not id then return false end
    for _, v in ipairs(list) do
        if tonumber(v) == id then return true end
    end
    return false
end

--- Die Klasse eines Items fuer diesen Raider, wie itemClass() des Servers:
--- eine Ausnahme der Kategorie (itemWeights.overrides) vor allem; eine Waffe
--- auf seiner BiS-Liste (bisWeapons) ist "bisWeapon"; sonst die Klasse aus
--- itemClasses der Kategorie; ein unbekanntes Item ist "normal".
-- @return Klasse ("override" | "frequent" | "trinket" | "bisWeapon" | "weapon" | "set" | "normal")
function Council.ItemClass(category, raider, itemId)
    local key = idKey(itemId)
    local itemWeights = type(category) == "table" and type(category.itemWeights) == "table" and category.itemWeights or {}
    local overrides = type(itemWeights.overrides) == "table" and itemWeights.overrides or {}
    if key ~= "" and tonumber(overrides[key]) then return "override" end
    local classes = type(category) == "table" and type(category.itemClasses) == "table" and category.itemClasses or {}
    local cls = classes[key] or "normal"
    if cls == "weapon" and type(raider) == "table" and inList(raider.bisWeapons, itemId) then cls = "bisWeapon" end
    return cls
end

--- Das Gewicht einer Vergabe an diesen Raider (itemWeight() des Servers).
-- @return weight, class
function Council.ItemWeight(category, raider, itemId)
    local cls = Council.ItemClass(category, raider, itemId)
    local itemWeights = type(category) == "table" and type(category.itemWeights) == "table" and category.itemWeights or {}
    if cls == "override" then return tonumber(itemWeights.overrides[idKey(itemId)]), cls end
    local classes = type(itemWeights.classes) == "table" and itemWeights.classes or {}
    local weight = tonumber(classes[cls])
    if weight == nil then weight = Council.DEFAULT_CLASS_WEIGHTS[cls] or 1 end
    return weight, cls
end

local function droughtCap(category)
    return tonumber(category.weights.droughtDays) or DROUGHT_DAYS
end

--- Der Zaehler der Wartezeit direkt nach der neuesten zaehlenden Vergabe
--- (droughtBase vom Server; aeltere Daten: aus droughtDays und den Tagen seit).
local function droughtBaseOf(raider)
    local base = tonumber(raider.droughtBase)
    if base then return base end
    local days = tonumber(raider.daysSinceLoot) or -1
    return math.max(0, num(raider.droughtDays) - math.max(0, days))
end

--- Eine zaehlende Vergabe in Punkte und Wartezeit einrechnen, wie
--- droughtCounter() des Servers: vor ihr waechst der Zaehler um die Tage seit
--- der letzten Vergabe (gedeckelt; ohne Vergabe ist er voll), dann wird er
--- mit max(0, 1 - Gewicht) malgenommen. Vor dem Setzen von lastAwardAt rufen.
-- @return weight, class
local function weighAward(category, raider, award)
    local weight, cls = Council.ItemWeight(category, raider, award.itemId)
    raider.lootPoints = round1(num(raider.lootPoints) + weight)
    local cap = droughtCap(category)
    local at, last = num(award.awardedAt), num(raider.lastAwardAt)
    local before = cap
    if last > 0 then before = math.min(cap, droughtBaseOf(raider) + (at - last) / DAY) end
    raider.droughtBase = before * math.max(0, 1 - weight)
    return weight, cls
end

--- Der Bedarf eines Raiders wie needScore() des Servers mit der Gewichtung
--- der Kategorie, in der Form der Council-Daten (0..100, wie raiderViewV3()).
-- @param row { droughtDays, lootPoints, tenureDays, bis = { owned, total } }
-- @param avgPoints Durchschnitt der Loot-Punkte der Kategorie
-- @param weights category.weights ({ shares, droughtDays, tenureDays })
-- @return need, parts (mit tenure)
function Council.NeedScoreV3(row, avgPoints, weights)
    local shares = type(weights) == "table" and type(weights.shares) == "table" and weights.shares or {}
    local cap = tonumber(weights and weights.droughtDays) or DROUGHT_DAYS
    local saturation = tonumber(weights and weights.tenureDays) or TENURE_DAYS
    local days = tonumber(row.droughtDays) or cap
    local drought = math.min(1, days / cap)
    local points = num(row.lootPoints)
    local share = 0.5
    if avgPoints > 0 then share = math.max(0, math.min(1, (avgPoints - points) / math.max(1, avgPoints))) end
    local bis = type(row.bis) == "table" and row.bis or {}
    local total, owned = num(bis.total), num(bis.owned)
    local need = 0.5
    if total > 0 then need = 1 - (owned / total) end
    local tenure = math.min(1, math.max(0, num(row.tenureDays)) / math.max(1, saturation))
    -- Dieselbe Reihenfolge wie der Server, damit die Summe bitgleich ist.
    local score = num(shares.drought) * drought + num(shares.share) * share + num(shares.need) * need
        + num(shares.tenure) * tenure
    return pct(round3(score)), {
        drought = pct(round3(drought)), share = pct(round3(share)), need = pct(round3(need)),
        tenure = pct(round3(tenure)),
    }
end

--- "Coilfang: Serpentshrine Cavern-25 Player" -> "Coilfang: Serpentshrine Cavern"
local function cleanInstance(raw)
    return (tostring(raw or ""):gsub("%-%d+ Player$", ""):gsub("%-%s*$", ""))
end

-- Dieselbe Vergabe aus beiden Addons (eine Gilde, die mit RCLootcouncil
-- verteilt und Gargul nebenher laufen hat): gleicher Spieler, gleiches Item,
-- andere Quelle, hoechstens so weit auseinander. RCLootcouncil gewinnt, es
-- weiss Instanz, Boss und Antwort.
local DUPLICATE_SECONDS = 300

local function dedupe(awards)
    local kept = {}
    for _, award in ipairs(awards) do
        local key = Council.NameKey(award.player) .. ":" .. tostring(award.itemId)
        local twin
        for _, other in ipairs(kept) do
            if other.key == key and other.award.source ~= award.source
                and math.abs(num(other.award.awardedAt) - num(award.awardedAt)) <= DUPLICATE_SECONDS then
                twin = other
                break
            end
        end
        if not twin then
            kept[#kept + 1] = { key = key, award = award }
        elseif twin.award.source == "gargul" and award.source == "rclc" then
            twin.award = award
        end
    end
    local out = {}
    for i, entry in ipairs(kept) do out[i] = entry.award end
    return out
end

local function copyList(list)
    local out = {}
    for i, v in ipairs(type(list) == "table" and list or {}) do out[i] = v end
    return out
end

local function copyRaider(raider)
    local copy = {}
    for k, v in pairs(raider) do copy[k] = v end
    local bis = type(raider.bis) == "table" and raider.bis or {}
    copy.bis = {}
    for k, v in pairs(bis) do copy.bis[k] = v end
    copy.bis.missing = copyList(bis.missing)
    copy.items = copyList(raider.items)
    copy.parts = {}
    for k, v in pairs(type(raider.parts) == "table" and raider.parts or {}) do copy.parts[k] = v end
    return copy
end

--- Die Raider einer Kategorie nach Namensschluessel (Name und key).
local function raidersByName(category)
    local map = {}
    for _, raider in ipairs(category.raiders) do
        if type(raider) == "table" then
            for _, name in ipairs({ raider.character or "", raider.key or "" }) do
                local key = Council.NameKey(name)
                if key ~= "" and not map[key] then map[key] = raider end
            end
        end
    end
    return map
end

--- Eine Vergabe auf eine Raider-Kopie anwenden (Regeln wie rosterRow()).
-- Mit Gewichtung (Version 3) zaehlt sie mit ihrem Gewicht in Punkten und
-- Wartezeit (weighAward), sonst wie bisher als ein Item.
local function applyToRaider(category, raider, award)
    local reason = award.reason
    local counts = Council.CountsAsLoot(reason)
    raider.provisional = raider.provisional or { awards = {}, counted = 0, other = 0 }
    local entry = {
        itemId = award.itemId, itemName = award.itemName or "", awardedAt = award.awardedAt,
        boss = award.boss or "", reason = Council.REASON_LABEL[reason] or reason, counts = counts,
    }
    table.insert(raider.provisional.awards, entry)
    if counts then
        if Council.IsWeighted(category) then
            entry.weight, entry.weightClass = weighAward(category, raider, award)
        end
        raider.provisional.counted = raider.provisional.counted + 1
        raider.lootCount = num(raider.lootCount) + 1
        raider.lootTotal = num(raider.lootTotal) + 1
        if num(award.awardedAt) > num(raider.lastAwardAt) then raider.lastAwardAt = award.awardedAt end
        -- Seit dieser Vergabe ist (fast) kein Tag vergangen; die Wartezeit der
        -- anderen Raider steht ohnehin auf dem Stand des Syncs.
        raider.daysSinceLoot = 0
        table.insert(raider.items, 1, {
            itemId = award.itemId, itemName = award.itemName or "", awardedAt = award.awardedAt,
            boss = award.boss or "", reason = entry.reason, provisional = true,
            weight = entry.weight, weightClass = entry.weightClass,
        })
    else
        raider.provisional.other = raider.provisional.other + 1
        raider.otherCount = num(raider.otherCount) + 1
    end
    -- Ein fehlendes BiS-Teil hat er jetzt (der Server sieht es erst im
    -- naechsten Log an ihm) - ausser es wurde entzaubert oder ging in die Bank.
    if reason ~= "disenchant" and reason ~= "bank" then
        local missing = raider.bis.missing
        for i, id in ipairs(missing) do
            if tonumber(id) == tonumber(award.itemId) then
                table.remove(missing, i)
                raider.bis.owned = num(raider.bis.owned) + 1
                if num(raider.bis.total) > 0 then
                    raider.bis.owned = math.min(raider.bis.owned, num(raider.bis.total))
                end
                entry.bis = true
                break
            end
        end
    end
end

--- Mit Gewichtung: Wartezeit, Tage seit dem letzten Item und Zugehoerigkeit
--- aller Raider zum Zeitpunkt `now`, dann Schnitt der Punkte und Bedarf neu -
--- wie der Server es zu diesem Zeitpunkt rechnen wuerde (rosterRow(),
--- droughtDays(), tenureDays(), scoreRows()).
local function rescoreWeighted(category, now)
    local cap = droughtCap(category)
    local sum, count = 0, 0
    for _, raider in ipairs(category.raiders) do
        if type(raider) == "table" then
            local last = num(raider.lastAwardAt)
            if last > 0 then
                local days = math.floor((now - last) / DAY)
                raider.daysSinceLoot = days
                raider.droughtDays = round1(math.min(cap, droughtBaseOf(raider) + days))
            else
                raider.daysSinceLoot = -1
                raider.droughtDays = cap
            end
            local joined = num(raider.joinedAt)
            raider.tenureDays = joined > 0 and math.max(0, math.floor((now - joined) / DAY)) or 0
            sum = sum + num(raider.lootPoints)
            count = count + 1
        end
    end
    local avg = count > 0 and sum / count or 0
    category.avgLootPoints = round1(avg)
    for _, raider in ipairs(category.raiders) do
        if type(raider) == "table" then
            local need, parts = Council.NeedScoreV3(raider, avg, category.weights)
            if need ~= num(raider.need) then raider.needBefore = num(raider.need) end
            raider.need = need
            raider.parts = parts
        end
    end
end

--- Schnitt, Bedarf und Teile aller Raider einer Kategorie neu (scoreRows()).
local function rescore(category, weights, now)
    if Council.IsWeighted(category) then return rescoreWeighted(category, now) end
    local sum, count = 0, 0
    for _, raider in ipairs(category.raiders) do
        if type(raider) == "table" then
            sum = sum + num(raider.lootCount)
            count = count + 1
        end
    end
    local avg = count > 0 and sum / count or 0
    category.avgLootCount = round(avg * 10) / 10
    for _, raider in ipairs(category.raiders) do
        if type(raider) == "table" then
            local need, parts = Council.NeedScore(raider, avg, weights)
            if need ~= num(raider.need) then raider.needBefore = num(raider.need) end
            raider.need = need
            raider.parts = parts
        end
    end
end

--- Die Kategorien, in denen eine Vergabe zaehlt. Zu welcher Kategorie eine
-- Vergabe gehoert, weiss nur der Server (ueber das Raid-Event). Hier: nennt
-- die Vergabe eine Instanz, die zu Kategorien passt (Raidvorlage), dann
-- diese - sonst jede Kategorie, in der der Raider steht.
local function targetCategories(data, award, byName)
    local instance = cleanInstance(award.instance)
    if instance ~= "" then
        local matched = Council.MatchCategories(data, { names = { instance } })
        if #matched > 0 then return matched end
    end
    local key = Council.NameKey(award.player)
    local out = {}
    for _, category in ipairs(data.categories) do
        if byName[category][key] then out[#out + 1] = category end
    end
    return out
end

--- Die Council-Daten mit den Vergaben seit dem Sync, vorlaeufig.
--
-- Je Vergabe nach generatedAt (Collect-Zeilen: player, itemId, itemName,
-- awardedAt, response, offspec, boss, instance, source), deren Spieler in
-- einer der Ziel-Kategorien steht: Grund wie der Server; zaehlt sie, dann
-- Items +1, letzter Loot = jetzt (Wartezeit 0), sonst "dazu Offspec/Bank" +1;
-- ein fehlendes BiS-Teil ist abgehakt. Danach in jeder betroffenen Kategorie
-- Schnitt und Bedarf ALLER Raider neu (der Schnitt aendert sich fuer alle).
--
-- Nicht nachgebaut (der Server weiss mehr): ob ein Item im Tier-/Raid-Filter
-- der Kategorie liegt (es zaehlt immer), und Raider, die erst durch diese
-- Vergabe in die Kategorie kaemen (sie fehlen, bis der Sync sie bringt).
--
-- Mit Gewichtung der Kategorie (Version 3) wie der Server: die Vergabe zaehlt
-- mit dem Gewicht ihrer Item-Klasse in Punkten und Wartezeit (Teil-
-- Rueckstellung), und alle Raider der Kategorie werden zum Zeitpunkt `now`
-- gerechnet (Tage seit dem letzten Item, Zugehoerigkeit).
--
-- @param data aus Load() - bleibt unveraendert
-- @param awards Liste von Vergaben (beliebige Reihenfolge, bleiben unveraendert)
-- @param now optional (time()): Zeitpunkt der Neuberechnung mit Gewichtung;
--   ohne: generatedAt bzw. die neueste Vergabe, wenn die spaeter liegt
-- @return data (dieselbe Tabelle, wenn nichts passt) oder eine Kopie mit
--   provisional = { count, since, awards, unmatched } und je betroffener
--   Kategorie provisional = Anzahl; geaenderte Raider tragen provisional =
--   { awards, counted, other } bzw. needBefore.
function Council.ApplyAwards(data, awards, now)
    if type(data) ~= "table" or type(awards) ~= "table" or #awards == 0 then return data end
    local since = num(data.generatedAt)
    if since <= 0 then return data end

    local fresh = {}
    for _, award in ipairs(awards) do
        if type(award) == "table" and num(award.awardedAt) > since and tonumber(award.itemId)
            and Council.NameKey(award.player) ~= "" then
            local copy = {}
            for k, v in pairs(award) do copy[k] = v end
            copy.itemId = tonumber(award.itemId)
            copy.reason = Council.ReasonFor(award.response, award.offspec)
            fresh[#fresh + 1] = copy
        end
    end
    if #fresh == 0 then return data end
    table.sort(fresh, function(a, b) return num(a.awardedAt) < num(b.awardedAt) end)
    fresh = dedupe(fresh)

    local byName = {}
    for _, category in ipairs(Council.Categories(data)) do byName[category] = raidersByName(category) end

    -- Erst nur feststellen, was wohin gehoert; kopiert wird nur Betroffenes.
    local plan, applied, unmatched = {}, {}, 0
    for _, award in ipairs(fresh) do
        local key = Council.NameKey(award.player)
        local hit = false
        for _, category in ipairs(targetCategories(data, award, byName)) do
            local raider = byName[category][key]
            if raider then
                plan[category] = plan[category] or {}
                table.insert(plan[category], { raider = raider, award = award })
                hit = true
            end
        end
        if hit then applied[#applied + 1] = award else unmatched = unmatched + 1 end
    end
    if #applied == 0 then return data end

    local out = {}
    for k, v in pairs(data) do out[k] = v end
    out.categories = {}
    local weights = Council.Weights(data)
    -- Der Zeitpunkt der Neuberechnung: nie vor der neuesten Vergabe.
    local at = math.max(num(now), since, num(applied[#applied].awardedAt))
    for i, category in ipairs(data.categories) do
        local steps = plan[category]
        if not steps then
            out.categories[i] = category
        else
            local copy = {}
            for k, v in pairs(category) do copy[k] = v end
            local copies = {}
            copy.raiders = {}
            for j, raider in ipairs(category.raiders) do
                if type(raider) == "table" then
                    copies[raider] = copyRaider(raider)
                    copy.raiders[j] = copies[raider]
                else
                    copy.raiders[j] = raider
                end
            end
            for _, step in ipairs(steps) do applyToRaider(copy, copies[step.raider], step.award) end
            copy.provisional = #steps
            rescore(copy, weights, at)
            out.categories[i] = copy
        end
    end
    out.provisional = { count = #applied, since = since, awards = applied, unmatched = unmatched }
    return out
end

--- Eine Kategorie zum Zeitpunkt `now` neu gerechnet, ohne neue Vergaben (eine
--- Kopie; die Daten bleiben unveraendert). Mit Gewichtung genau die Rechnung
--- von ApplyAwards() - mit now = generatedAt ergibt sie die Zahlen des Servers.
function Council.Recompute(category, now, data)
    if type(category) ~= "table" or type(category.raiders) ~= "table" then return category end
    local copy = {}
    for k, v in pairs(category) do copy[k] = v end
    copy.raiders = {}
    for i, raider in ipairs(category.raiders) do
        copy.raiders[i] = type(raider) == "table" and copyRaider(raider) or raider
    end
    rescore(copy, Council.Weights(data), num(now))
    return copy
end

--- Hat sich an diesem Raider vorlaeufig etwas geaendert?
-- @return "own" (eigene Vergaben), "avg" (nur sein Bedarf, weil sich der
--   Schnitt verschoben hat), sonst nil
function Council.ProvisionalKind(raider)
    if type(raider) ~= "table" then return nil end
    if raider.provisional then return "own" end
    if raider.needBefore ~= nil then return "avg" end
    return nil
end

Council.PROVISIONAL_COLOR = { 1.00, 0.55, 0.15 }

--- Das Zeichen hinter der Bedarfszahl: ein orangenes "*" fuer eigene
-- Vergaben seit dem Sync, ein graues, wenn sich nur der Schnitt verschoben
-- hat; sonst "".
function Council.ProvisionalMark(raider)
    local kind = Council.ProvisionalKind(raider)
    if kind == "own" then return Council.Color("*", unpack(Council.PROVISIONAL_COLOR)) end
    if kind == "avg" then return Council.Color("*", 0.6, 0.6, 0.6) end
    return ""
end

function Council.AwardsLabel(count)
    count = int(count)
    if count == 1 then return "1 Vergabe" end
    return ("%d Vergaben"):format(count)
end

--- Fuer den Zeilen-Tooltip: "inkl. 2 Vergaben seit dem letzten Sync (vorlaeufig)".
function Council.ProvisionalRaiderLine(raider)
    if type(raider) ~= "table" or not raider.provisional then return nil end
    return ("inkl. %s seit dem letzten Sync (vorläufig)"):format(Council.AwardsLabel(#raider.provisional.awards))
end

--- Fuer die Kopfzeile: "vorlaeufig: 2 Vergaben seit 05.10. 21:30", oder nil.
-- @param category optional: zaehlt nur deren Vergaben
function Council.ProvisionalHeader(data, category)
    local info = type(data) == "table" and data.provisional
    if not info then return nil end
    local count = info.count
    if type(category) == "table" then count = num(category.provisional) end
    if num(count) <= 0 then return nil end
    return ("vorläufig: %s seit %s"):format(Council.AwardsLabel(count), Council.FormatStamp(info.since))
end
