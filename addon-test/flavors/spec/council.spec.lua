-- The pure council logic (Council.lua): loading (version 2 and 1), categories,
-- matching an instance, the item index, texts, colours.
local EHS = EventHelperSync
local Council = EHS.Council
local NOW = WoWMock.now

-- Loading and validation ------------------------------------------------------------------

local data, status = Council.Load()
expectEqual(data, nil, "placeholder CouncilData.lua leaves no data")
expectEqual(status, "none", "status without data")
expectEqual(select(2, Council.Load({ format = "eventhelper-loot", version = 2, categories = {} })), "format", "wrong format")
expectEqual(select(2, Council.Load({ format = "eventhelper-council", version = 3, categories = {} })), "version", "newer version")
expectEqual(select(2, Council.Load({ format = "eventhelper-council", version = 2 })), "format", "v2 without categories")
expectEqual(select(2, Council.Load({ format = "eventhelper-council", version = 1 })), "format", "v1 without raiders")
expectEqual(select(2, Council.Load({ format = "eventhelper-council" })), "format", "no version")
local empty = Council.Load({ format = "eventhelper-council", version = 2, categories = {} })
expectEqual(#Council.Categories(empty), 0, "no loot council category is valid data")
expectEqual(Council.ActiveCategory(empty, "1", nil), nil, "no category, none active")
local broken = Council.Load({ format = "eventhelper-council", version = 2,
    categories = { "x", { id = 1, name = "ohne Raider" }, { id = 2, name = "ok", raiders = {} } } })
expectEqual(#Council.Categories(broken), 1, "broken categories are left out")
expectEqual(Council.Categories(broken)[1].id, "2", "ids become strings")

-- the fixture as the sync tool writes it (version 2)
load(__COUNCIL_FIXTURE)()
data, status = Council.Load()
expectEqual(status, "ok", "fixture loads")
expect(Council.Load() == data, "loaded once per data table")
local categories = Council.Categories(data)
expectEqual(#categories, 3, "three loot council categories")
local ssc, karaSo, karaDo = categories[1], categories[2], categories[3]
expectEqual(ssc.id, "1234567890", "numeric id as text")
expectEqual(ssc.name, "SSC/TK Mittwoch", "emoji (serialized as ?) cleaned from the name")
expectEqual(karaSo.name, "Kara - Sonntag", "dash and trailing emoji")
expectEqual(karaDo.name, "Kara Donnerstag", "plain name untouched")
expectEqual(#ssc.raiders, 18, "all raiders")
expectEqual(ssc.raiders[2].character, "Naphfß", "Latin-1 name survives")
expectEqual(ssc.raiders[2].specLabel, "Resto - Totem", "en dash became ASCII")
expectEqual(ssc.raiders[1].items[1].itemName, 'Robe - "Neu" ...', "typographic quotes and ellipsis")
expectEqual(ssc.raiders[1].items[2].itemName, 'Ring "alt"\nzweite Zeile ?', "escapes and emoji")
expectEqual(ssc.avgLootCount, 3.4, "floats")
expectEqual(ssc.filter.tiers[2], "t6", "filter from the website")
expectEqual(ssc.instances[1].short, "SSC", "instances")
expectEqual(Council.FindCategory(data, 987), karaSo, "find by id (number or text)")
expectEqual(Council.FindCategory(data, "nope"), nil, "unknown id")

-- Names --------------------------------------------------------------------------------------

expectEqual(Council.CleanName("? SSC/TK Mittwoch ?"), "SSC/TK Mittwoch", "question marks from emoji")
expectEqual(Council.CleanName("  | Raid  Nacht |  "), "Raid Nacht", "separators and spaces")
expectEqual(Council.CleanName("Wer kommt?"), "Wer kommt?", "a real question stays")
expectEqual(Council.CleanName("??", "5"), "Kategorie 5", "nothing left: id")
expectEqual(Council.CleanName(nil, 7), "Kategorie 7", "no name")

-- Version 1 from an older sync tool: one category --------------------------------------------

local v1Data = (function()
    local saved = EventHelperSync_Council
    load(__COUNCIL_FIXTURE_V1)()
    local loaded, loadStatus = Council.Load()
    EventHelperSync_Council = saved
    return loaded, loadStatus
end)()
expect(v1Data, "version 1 still loads")
expectEqual(v1Data.fromVersion, 1, "marked as version 1")
expectEqual(#Council.Categories(v1Data), 1, "one category")
expectEqual(Council.Categories(v1Data)[1].id, "123", "category id from the filter")
expectEqual(Council.Categories(v1Data)[1].name, "SSC/TK Mittwoch", "category name from the filter")
expectEqual(#Council.Categories(v1Data)[1].raiders, 18, "raiders of version 1")
expectEqual(Council.FilterLine(Council.Categories(v1Data)[1]), "SSC/TK Mittwoch · BiS T6", "v1 filter line")
expectEqual(Council.Categories(Council.Load({ format = "eventhelper-council", version = 1, raiders = {} }))[1].name,
    "Alle Raids", "v1 without a category")
expectEqual(Council.Load() , data, "the v2 data again")

-- Active category ----------------------------------------------------------------------------

local active, how = Council.ActiveCategory(data, nil, nil)
expect(active == ssc and how == "default", "first category without a choice")
active, how = Council.ActiveCategory(data, "987", nil)
expect(active == karaSo and how == "manual", "manual choice")
active, how = Council.ActiveCategory(data, "987", "555")
expect(active == karaDo and how == "auto", "auto beats manual")
active, how = Council.ActiveCategory(data, "gone", "gone too")
expect(active == ssc and how == "default", "unknown ids fall back to the first")

-- Matching the instance ----------------------------------------------------------------------

local function matchIds(places)
    local ids = {}
    for _, c in ipairs(Council.MatchCategories(data, places)) do ids[#ids + 1] = c.id end
    return table.concat(ids, ",")
end
expectEqual(matchIds({ names = { "Höhle des Schlangenschreins" } }), "1234567890", "instance name")
expectEqual(matchIds({ names = { "HÖHLE DES SCHLANGENSCHREINS" } }), "1234567890", "case-insensitive, umlauts too")
expectEqual(matchIds({ names = { "Festung der Stürme" } }), "1234567890", "second instance of the category")
expectEqual(matchIds({ names = { "SSC" } }), "1234567890", "short name, exactly")
expectEqual(matchIds({ names = { "Gruuls Unterschlupf", "Gruuls Unterschlupf" } }), "", "no match")
expectEqual(matchIds({ names = { "Karazhan" } }), "987,555", "ambiguous: two categories ('(Forever)' ignored)")
expectEqual(matchIds({ names = { "Karazhan - Oper" } }), "987,555", "contains")
expectEqual(matchIds({ names = { "Sturmwind" } }), "", "short 'TK'/'SSC' never match inside other words")
expectEqual(matchIds({ names = {} }), "", "nothing known")
expectEqual(#Council.MatchCategories(data, nil), 0, "no place")
local byId = Council.Load({ format = "eventhelper-council", version = 2, categories = {
    { id = 1, name = "A", raiders = {}, instances = { { id = 548, name = "Woanders" } } },
} })
expectEqual(#Council.MatchCategories(byId, { names = { "x" }, instanceId = 548 }), 1, "numeric instance id")

expectEqual(Council.CategoryByText(data, "kara"), karaSo, "/ehc: name prefix")
expectEqual(Council.CategoryByText(data, "DONNER"), karaDo, "/ehc: anywhere in the name")
expectEqual(Council.CategoryByText(data, "ssc"), ssc, "/ehc: ssc")
expectEqual(Council.CategoryByText(data, "xyz"), nil, "/ehc: nothing")
expectEqual(Council.CategoryByText(data, " "), nil, "/ehc: empty")

-- Weights ---------------------------------------------------------------------------------

local w = Council.Weights(data)
expect(w.drought == 50 and w.share == 40 and w.need == 10, "weights from the data")
w = Council.Weights({ weights = { drought = 60 } })
expect(w.drought == 60 and w.share == 40 and w.need == 10, "missing weights fall back")

-- Raiders and role filter -----------------------------------------------------------------

local all = Council.Raiders(ssc)
expectEqual(all[1].character, "Neuling", "highest need first")
expectEqual(all[2].character, "Gemli", "then the next")
local healers = Council.Raiders(ssc, "healer")
for _, r in ipairs(healers) do expectEqual(r.role, "healer", "only healers") end
expectEqual(#healers, 6, "1 + 5 healers")
expectEqual(#Council.Raiders(ssc, ""), 18, "empty role = all")
expectEqual(#Council.Raiders(karaSo, "healer"), 0, "caster-only category has no healers")
expectEqual(#Council.Raiders(nil), 0, "no category")

-- Item index ------------------------------------------------------------------------------

local list, total = Council.ForItem(ssc, 30000, 5)
expectEqual(total, 17, "everyone but the newcomer misses 30000")
expectEqual(#list, 5, "limited to 5")
expectEqual(list[1].raider.character, "Gemli", "sorted by need")
expectEqual(list[2].raider.character, "Naphfß", "second highest")
list, total = Council.ForItem(ssc, 30001)
expectEqual(total, 1, "one raider misses 30001")
expectEqual(list[1].copies, 2, "two copies of the same ring")
list, total = Council.ForItem(ssc, 99999)
expectEqual(total, 0, "nobody misses this")
expectEqual(#Council.ForItem(nil, 30000), 0, "no data, no list")
expectEqual(#Council.ForItem(ssc, "30000", 2), 2, "string ids work")
list, total = Council.ForItem(karaSo, 30000)
expect(total == 1 and list[1].raider.need == 99, "per category: Gemli with the Kara need")
-- all categories together: every raider once
list, total = Council.ForItem(data, 30000)
expectEqual(total, 17, "union: Gemli is in two categories, listed once")
expectEqual(list[1].raider.need, 82, "union: the entry of the first category")
list, total = Council.ForItem(data, 28000)
expectEqual(total, 3, "union: Gemli (Kara), Heila, Karl")
expectEqual(list[1].raider.character, "Gemli", "union sorted by need")
expectEqual(list[2].raider.character, "Heila", "union: other category")

-- Bar segments: weight x part ---------------------------------------------------------------

local seg = Council.Segments(ssc.raiders[1], Council.Weights(data), 100)
expectEqual(seg.drought, 50, "drought 100 x 50%")
expect(math.abs(seg.share - 24) < 1e-9, "share 60 x 40%")
expect(math.abs(seg.need - 4) < 1e-9, "BiS gap 40 x 10%")
seg = Council.Segments({ parts = { drought = 250, share = -5 } }, Council.Weights(data), 100)
expect(seg.drought == 50 and seg.share == 0 and seg.need == 0, "parts clamped to 0..100")

-- Texts -------------------------------------------------------------------------------------

expectEqual(Council.FormatAge(0, NOW), "noch nie", "never")
expectEqual(Council.FormatAge(NOW - 10, NOW), "gerade eben", "seconds")
expectEqual(Council.FormatAge(NOW - 5 * 60, NOW), "vor 5 Min.", "minutes")
expectEqual(Council.FormatAge(NOW - 2 * 3600, NOW), "vor 2 Std.", "hours")
expectEqual(Council.FormatAge(NOW - 86400, NOW), "vor 1 Tag", "one day")
expectEqual(Council.FormatAge(NOW - 12 * 86400, NOW), "vor 12 Tagen", "days")
expectEqual(Council.FormatAge(NOW + 100, NOW), "gerade eben", "clock skew")

expect(Council.FormatStamp(data.generatedAt):match("^%d%d%.%d%d%. %d%d:%d%d$"), "stamp format")
local header = Council.Header(data, NOW)
expect(header:match("^Stand: %d%d%.%d%d%. %d%d:%d%d, vor 2 Std%.$"), "header: " .. header)
expectEqual(Council.Header({}, NOW), "Stand: unbekannt", "header without time")

expectEqual(Council.FilterLine(ssc), "SSC/TK Mittwoch · T5/T6 · BiS T6", "filter line")
expectEqual(Council.FilterLine(karaSo), "Kara - Sonntag · nur Caster · T4 · BiS T4", "filter line with role")
expectEqual(Council.FilterLine({ filter = { role = "healer" } }), "Alle Raids · nur Heiler", "filter line without name")
expectEqual(Council.RoleBlockedText(karaSo, "healer"),
    "Diese Kategorie zeigt nur Caster (Einstellung auf der Webseite).", "role blocked by the website")
expectEqual(Council.RoleBlockedText(karaSo, "caster"), nil, "same role is fine")
expectEqual(Council.RoleBlockedText(karaSo, ""), nil, "all roles is fine")
expectEqual(Council.RoleBlockedText(ssc, "healer"), nil, "category with all roles")
expect(Council.NO_CATEGORY_TEXT:find("Einstellungen > Kategorien", 1, true), "no-category text")

expectEqual(Council.ItemsLabel(1), "1 Item", "singular")
expectEqual(Council.ItemsLabel(3), "3 Items", "plural")
expectEqual(Council.ItemsLabel(nil), "0 Items", "none")
expectEqual(Council.BisLabel(ssc.raiders[1]), "BiS 9/16", "bis label")
expectEqual(Council.BisLabel(ssc.raiders[3]), "BiS -", "no bis list")
expectEqual(Council.MissingCount(ssc.raiders[1]), 3, "missing count")
expectEqual(Council.MissingCount({ bis = { owned = 4, total = 10 } }), 6, "missing from totals")

expectEqual(plain(Council.TooltipLine(ssc.raiders[1])), "Gemli (Shadow) Bedarf 82 - 2 Items", "tooltip line")
expectEqual(plain(Council.TooltipLine(ssc.raiders[3])), "Neuling Bedarf 95 - 0 Items", "tooltip line without spec")

local lines = Council.TooltipLines(ssc, 30000, 5)
expectEqual(#lines, 6, "5 raiders + 'more' line")
expectEqual(plain(lines[6]), "... und 12 weitere", "more line")
lines = Council.TooltipLines(ssc, 30001, 5)
expectEqual(plain(lines[1]), "Gemli (Shadow) Bedarf 82 - 2 Items (fehlt 2x)", "copies shown")
expectEqual(Council.TooltipLines(ssc, 12345), nil, "nothing for unneeded items")
lines = Council.TooltipLines(karaSo, 28000)
expectEqual(plain(lines[1]), "Gemli (Shadow) Bedarf 99 - 0 Items", "tooltip of one category")

-- Colours -----------------------------------------------------------------------------------

local r, g, b = Council.ClassColor("MAGE")
expect(r == 0.25 and g == 0.78 and b == 0.92, "class colour from RAID_CLASS_COLORS")
r, g, b = Council.ClassColor("WARLOCK")
expect(r == 0.53 and b == 0.93, "fallback class colour")
r, g, b = Council.ClassColor("")
expect(r == 0.8 and g == 0.8 and b == 0.8, "unknown class grey")
expectEqual(Council.Color("x", 1, 0, 0.5), "|cffff0080x|r", "colour code")
expect(select(2, Council.NeedColor(90)) > 0.8, "high need green")
expect(select(1, Council.NeedColor(10)) < 0.7, "low need grey")
