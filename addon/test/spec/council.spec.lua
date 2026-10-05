-- The pure council logic (Council.lua): loading, index, texts, colours.
local EHS = EventHelperSync
local Council = EHS.Council
local NOW = WoWMock.now

-- Loading and validation ------------------------------------------------------------------

local data, status = Council.Load()
expectEqual(data, nil, "placeholder CouncilData.lua leaves no data")
expectEqual(status, "none", "status without data")
expectEqual(select(2, Council.Load({ format = "eventhelper-loot", version = 1, raiders = {} })), "format", "wrong format")
expectEqual(select(2, Council.Load({ format = "eventhelper-council", version = 2, raiders = {} })), "version", "newer version")
expectEqual(select(2, Council.Load({ format = "eventhelper-council", version = 1 })), "format", "no raiders")

-- the fixture as the sync tool writes it
load(__COUNCIL_FIXTURE)()
data, status = Council.Load()
expectEqual(status, "ok", "fixture loads")
expectEqual(#data.raiders, 18, "all raiders")
expectEqual(data.raiders[2].character, "Naphfß", "Latin-1 name survives")
expectEqual(data.raiders[2].specLabel, "Resto - Totem", "en dash became ASCII")
expectEqual(data.raiders[1].items[1].itemName, 'Robe - "Neu" ...', "typographic quotes and ellipsis")
expectEqual(data.raiders[1].items[2].itemName, 'Ring "alt"\nzweite Zeile ?', "escapes and emoji")
expectEqual(data.avgLootCount, 3.4, "floats")

-- Weights ---------------------------------------------------------------------------------

local w = Council.Weights(data)
expect(w.drought == 50 and w.share == 40 and w.need == 10, "weights from the data")
w = Council.Weights({ weights = { drought = 60 } })
expect(w.drought == 60 and w.share == 40 and w.need == 10, "missing weights fall back")

-- Raiders and role filter -----------------------------------------------------------------

local all = Council.Raiders(data)
expectEqual(all[1].character, "Neuling", "highest need first")
expectEqual(all[2].character, "Gemli", "then the next")
local healers = Council.Raiders(data, "healer")
for _, r in ipairs(healers) do expectEqual(r.role, "healer", "only healers") end
expectEqual(#healers, 6, "1 + 5 healers")
expectEqual(#Council.Raiders(data, ""), 18, "empty role = all")

-- Item index ------------------------------------------------------------------------------

local list, total = Council.ForItem(data, 30000, 5)
expectEqual(total, 17, "everyone but the newcomer misses 30000")
expectEqual(#list, 5, "limited to 5")
expectEqual(list[1].raider.character, "Gemli", "sorted by need")
expectEqual(list[2].raider.character, "Naphfß", "second highest")
list, total = Council.ForItem(data, 30001)
expectEqual(total, 1, "one raider misses 30001")
expectEqual(list[1].copies, 2, "two copies of the same ring")
list, total = Council.ForItem(data, 99999)
expectEqual(total, 0, "nobody misses this")
expectEqual(#Council.ForItem(nil, 30000), 0, "no data, no list")
expectEqual(#Council.ForItem(data, "30000", 2), 2, "string ids work")

-- Bar segments: weight x part ---------------------------------------------------------------

local seg = Council.Segments(data.raiders[1], Council.Weights(data), 100)
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

expectEqual(Council.FilterLine(data), "SSC/TK Mittwoch · BiS T6", "filter line")
expectEqual(Council.FilterLine({ filter = { role = "healer" } }), "Alle Raids · nur Heiler", "filter line with role")

expectEqual(Council.ItemsLabel(1), "1 Item", "singular")
expectEqual(Council.ItemsLabel(3), "3 Items", "plural")
expectEqual(Council.ItemsLabel(nil), "0 Items", "none")
expectEqual(Council.BisLabel(data.raiders[1]), "BiS 9/16", "bis label")
expectEqual(Council.BisLabel(data.raiders[3]), "BiS -", "no bis list")
expectEqual(Council.MissingCount(data.raiders[1]), 3, "missing count")
expectEqual(Council.MissingCount({ bis = { owned = 4, total = 10 } }), 6, "missing from totals")

expectEqual(plain(Council.TooltipLine(data.raiders[1])), "Gemli (Shadow) Bedarf 82 - 2 Items", "tooltip line")
expectEqual(plain(Council.TooltipLine(data.raiders[3])), "Neuling Bedarf 95 - 0 Items", "tooltip line without spec")

local lines = Council.TooltipLines(data, 30000, 5)
expectEqual(#lines, 6, "5 raiders + 'more' line")
expectEqual(plain(lines[6]), "... und 12 weitere", "more line")
lines = Council.TooltipLines(data, 30001, 5)
expectEqual(plain(lines[1]), "Gemli (Shadow) Bedarf 82 - 2 Items (fehlt 2x)", "copies shown")
expectEqual(Council.TooltipLines(data, 12345), nil, "nothing for unneeded items")

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
