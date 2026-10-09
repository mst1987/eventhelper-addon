-- Council data version 3 (#670) - straight from the EventHelper server: the
-- fixture is the server's real councilRoster() + councilSyncPayloadV3() with
-- mocked data (../../fixtures/council-v3-server.json, generator next to it),
-- written by the real sync tool serializer. Checked here:
--   * loading v3: all five roles, roster status, loot points, the category's
--     own weighting and item classes,
--   * the item class of an award like itemWeights.js (exception > BiS weapon
--     of the recipient > item class > normal),
--   * the cross-check: recomputed at generatedAt without new awards, the
--     addon reproduces every server number; with one award after the sync
--     (a BiS weapon for the trial rogue) it reproduces what the server
--     computed with that award in its loot store,
--   * the window: six role buttons that fit, Probe badge, "x Pkt", the fourth
--     bar segment (Zugehoerigkeit), the row tooltip, the live recompute
--     through RCLootCouncil's history.
local EHS = EventHelperSync
local Council = EHS.Council
local Suggest = EHS.Suggest

WoWMock.Fire("ADDON_LOADED", "EventHelperSync")
WoWMock.Fire("PLAYER_LOGIN")

local function plain(text)
    return (tostring(text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

load(__COUNCIL_FIXTURE_V3)()
local cross = load(__COUNCIL_V3_CROSS)()

-- Loading -------------------------------------------------------------------------------------

local data, status = Council.Load()
expectEqual(status, "ok", "v3 loads")
expectEqual(data.version, 3, "version 3")
expectEqual(data.fromVersion, nil, "straight from a v3 server")
local category = data.categories[1]
expectEqual(category.name, "SSC/TK Mittwoch", "category name")
expect(Council.IsWeighted(category), "the category has its own weighting")
expectEqual(#Council.PartsOf(category), 4, "four need parts")
expectEqual(table.concat(Council.PartsOf(category), ","), "drought,share,need,tenure", "the order of the parts")

local function byKeyOf(cat)
    local map = {}
    for _, raider in ipairs(cat.raiders) do map[raider.key] = raider end
    return map
end
local byKey = byKeyOf(category)
local roles = {}
for _, raider in ipairs(category.raiders) do roles[raider.role] = (roles[raider.role] or 0) + 1 end
expect(roles.caster == 2 and roles.healer == 1 and roles.tank == 1 and roles.melee == 1 and roles.ranged == 1,
    "all five council roles")
expectEqual(byKey.messer.status, "trial", "roster status")
expectEqual(byKey.gemli.status, "core", "core status")
expectEqual(plain(Council.StatusBadge(byKey.messer)), "Probe", "Probe badge")
expectEqual(Council.StatusBadge(byKey.gemli), "", "no badge for core")
expectEqual(plain(Council.StatusBadge({ status = "bench" })), "Ersatz", "Ersatz badge")
expectEqual(Council.PointsLabel(byKey.gemli.lootPoints), "5,5 Pkt", "points with a German comma")
expectEqual(Council.PointsLabel(2), "2 Pkt", "whole points without decimals")
expectEqual(Council.LootLabel(byKey.gemli, true), "3 Items · 5,5 Pkt", "items and points")
expectEqual(Council.LootLabel(byKey.gemli, false), "3 Items", "without weighting: items only")
local weights = Council.WeightsFor(data, category)
expect(weights.drought == 33 and weights.share == 29 and weights.need == 14 and weights.tenure == 24, "weights in % for the bar")
expectEqual(Council.ROLE_LABEL.melee, "Nahkampf", "melee label")
expectEqual(Council.FilterLine({ name = "X", filter = { role = "ranged" } }), "X · nur Fernkampf", "filter line with a new role")

-- Item classes like itemWeights.js -----------------------------------------------------------

local function class(raider, id) return (Council.ItemClass(category, raider, id)) end
local function weight(raider, id) return (Council.ItemWeight(category, raider, id)) end
expectEqual(class(byKey.messer, 30082), "bisWeapon", "a weapon on the recipient's BiS list")
expectEqual(weight(byKey.messer, 30082), 2, "bisWeapon weight")
expectEqual(class(byKey.gemli, 30082), "weapon", "the same weapon for someone else")
expectEqual(weight(byKey.gemli, 30082), 1.5, "weapon weight")
expectEqual(class(byKey.gemli, 30099), "override", "the council's exception wins")
expectEqual(weight(byKey.gemli, 30099), 2.5, "exception weight")
expectEqual(class(byKey.gemli, 30626), "trinket", "trinket")
expectEqual(weight(byKey.gemli, 30626), 3, "the category's trinket weight")
expectEqual(class(byKey.gemli, 30021), "frequent", "trash drop")
expectEqual(weight(byKey.gemli, 30021), 0.5, "frequent weight")
expectEqual(class(byKey.gemli, 30245), "set", "tier token")
expectEqual(class(byKey.gemli, 12345), "normal", "unknown item")
expectEqual(weight(byKey.gemli, 12345), 1, "normal weight")

-- Cross-check 1: no new award, recomputed at generatedAt = the server's numbers ----------------

local again = Council.Recompute(category, data.generatedAt, data)
expect(again ~= category, "a copy")
expectEqual(again.avgLootPoints, category.avgLootPoints, "avg loot points")
for i, raider in ipairs(again.raiders) do
    local server = category.raiders[i]
    local who = server.key
    expectEqual(raider.need, server.need, "need of " .. who)
    for _, key in ipairs(Council.PARTS_V3) do
        expectEqual(raider.parts[key], server.parts[key], key .. " part of " .. who)
    end
    expectEqual(raider.droughtDays, server.droughtDays, "drought days of " .. who)
    expectEqual(raider.daysSinceLoot, server.daysSinceLoot, "days since loot of " .. who)
    expectEqual(raider.tenureDays, server.tenureDays, "tenure days of " .. who)
    expectEqual(raider.lootPoints, server.lootPoints, "loot points of " .. who)
end
expectEqual(category.raiders[1].need, byKey.neu.need, "the data itself unchanged")

-- Cross-check 2: one award after the sync = what the server computed with it -------------------

local adjusted = Council.ApplyAwards(data, { cross.award }, cross.now)
expect(adjusted ~= data, "adjusted copy")
expectEqual(adjusted.provisional.count, 1, "one award applied")
local after = adjusted.categories[1]
expectEqual(after.avgLootPoints, cross.expected.avgLootPoints, "avg loot points after the award")
local afterByKey = byKeyOf(after)
for _, expected in ipairs(cross.expected.raiders) do
    local raider = afterByKey[expected.key]
    local who = expected.key
    expectEqual(raider.need, expected.need, "need of " .. who .. " after the award")
    for _, key in ipairs(Council.PARTS_V3) do
        expectEqual(raider.parts[key], expected.parts[key], key .. " part of " .. who .. " after the award")
    end
    expectEqual(raider.lootPoints, expected.lootPoints, "loot points of " .. who)
    expectEqual(raider.lootCount, expected.lootCount, "loot count of " .. who)
    expectEqual(raider.droughtDays, expected.droughtDays, "drought days of " .. who)
    expectEqual(raider.daysSinceLoot, expected.daysSinceLoot, "days since loot of " .. who)
    expectEqual(raider.tenureDays, expected.tenureDays, "tenure days of " .. who)
    expectEqual(raider.bis.owned, expected.bisOwned, "BiS owned of " .. who)
    expectEqual(raider.lastAwardAt, expected.lastAwardAt, "last award of " .. who)
end
local messer = afterByKey.messer
expectEqual(messer.provisional.awards[1].weightClass, "bisWeapon", "the award counted as a BiS weapon")
expectEqual(messer.provisional.awards[1].weight, 2, "with its weight")
expectEqual(messer.items[1].weight, 2, "the new item carries its weight")
expect(afterByKey.gemli.needBefore ~= nil, "others moved with the time and the average (grey marker)")
expectEqual(Council.ProvisionalKind(afterByKey.gemli), "avg", "grey marker for the others")

-- An exception and a partial reset: a trash drop halves the wait (weight 0.5).
local half = Council.ApplyAwards(data, { {
    player = "Pfeil", itemId = 30021, itemName = "Wildfury Greatstaff", awardedAt = data.generatedAt + 3600,
    response = "Upgrade", source = "rclc",
} }, data.generatedAt + 3600)
local pfeil = byKeyOf(half.categories[1]).pfeil
expectEqual(pfeil.lootPoints, byKey.pfeil.lootPoints + 0.5, "frequent: half a point")
-- base 0 (BiS weapon reset) + 10 days and 1 h until the award, halved, + 0 days since
local expectedDrought = math.floor(math.min(30, (byKey.pfeil.droughtBase + (data.generatedAt + 3600 - byKey.pfeil.lastAwardAt) / 86400)
    * 0.5) * 10 + 0.5) / 10
expectEqual(pfeil.droughtDays, expectedDrought, "the wait halved, not reset")

-- RCLC suggestion: a tank on the BiS list makes a tank item; the badge rides on the row
expectEqual(Suggest.ItemRole(category, 30095), "tank", "Schild's BiS weapon: a tank item")
local suggestion = Suggest.Build({ itemId = 30082, candidates = {
    { name = "Messer-Thunderstrike", class = "ROGUE", response = 1, info = { text = "BiS" } },
} }, category, cross.now)
expectEqual(suggestion.tag, "Nahkampf", "a melee item by Messer's BiS list")
expectEqual(suggestion.rows[1].status, "trial", "status on the suggestion row")

-- The window ------------------------------------------------------------------------------------

EHS.db.settings.councilCategory = category.id
EHS:ShowCouncil()
local council = EventHelperSyncCouncilFrame
local layout = EHS.CouncilLayout
local labels, right = {}, 12
for i, button in ipairs(council.roleButtons) do
    labels[#labels + 1] = button.label:GetText()
    right = right + layout.ROLE_BUTTONS[i].width + (i > 1 and layout.ROLE_GAP or 0)
end
expectEqual(table.concat(labels, "|"), "Alle|Caster|Heiler|Tank|Nahkampf|Fernkampf", "six role buttons")
expect(right <= layout.WIDTH - 12, "the role row fits the window (%d of %d px)", right, layout.WIDTH)
local lastCol = layout.COL.last
expect(lastCol[1] + lastCol[2] <= layout.WIDTH - 24, "the columns fit the row")

local function rows()
    local out = {}
    for _, child in ipairs(WoWMock.frames) do
        if child.__parent == council.list and child.__kind == "Button" and child:IsShown() then out[#out + 1] = child end
    end
    return out
end
local function rowOf(key)
    for _, row in ipairs(rows()) do
        if row.raider and row.raider.key == key then return row end
    end
end
expectEqual(#rows(), 6, "all six raiders")
local messerRow = rowOf("messer")
expectEqual(plain(messerRow.name:GetText()), "Messer Probe Kampf-Schurke", "name, Probe badge, spec")
expectEqual(plain(messerRow.items:GetText()), "2 Items · 1,5 Pkt", "items and points")
expect(messerRow.segments.tenure.__width > 0 and messerRow.segments.tenure.__alpha == 1, "the fourth segment shows tenure")
local gemliRow = rowOf("gemli")
-- 100 px x 24 % x 100/100 = 23.8 px (exact share)
expect(math.abs(gemliRow.segments.tenure.__width - 100 * weights.tenure / 100) < 1e-9, "tenure segment width")
expectEqual(plain(gemliRow.name:GetText()), "Gemli Schattenpriester", "core: no badge")

WoWMock.Run(messerRow, "OnEnter")
local tip = plain(WoWMock.TooltipText(GameTooltip))
expect(tip:find("Probe (Roster)", 1, true), "status in the row tooltip")
expect(tip:find("Zugehörigkeit (24%)", 1, true), "tenure part in the row tooltip")
expect(tip:find("Dabei seit", 1, true), "joined date in the row tooltip")
expect(tip:find("Erhalten: 2 Items · 1,5 Pkt", 1, true), "points in the row tooltip")

-- role buttons filter
local function click(role)
    for _, button in ipairs(council.roleButtons) do
        if button.role == role then WoWMock.Click(button) end
    end
end
click("tank")
expectEqual(#rows(), 1, "Tank: one raider")
expectEqual(rows()[1].raider.key, "schild", "the protection paladin")
click("melee")
expectEqual(rows()[1].raider.key, "messer", "Nahkampf: the rogue")
click("ranged")
expectEqual(rows()[1].raider.key, "pfeil", "Fernkampf: the hunter")
click("")
expectEqual(#rows(), 6, "Alle again")

-- Live: the award in RCLootCouncil's history, the clock at the server's second run
local function link(id, name)
    return ("|cffa335ee|Hitem:%d::::::::70:::::|h[%s]|h|r"):format(id, name)
end
RCLootCouncilLootDB = { factionrealm = { ["Alliance - Thunderstrike"] = {
    ["Messer-Thunderstrike"] = { {
        lootWon = link(30082, "Talon of Azshara"), id = cross.award.awardedAt .. "-1", response = "BiS", responseID = 1,
        instance = "Coilfang: Serpentshrine Cavern-25 Player", boss = "Morogrim Tidewalker", class = "ROGUE",
    } },
} } }
WoWMock.now = cross.now
EHS:RefreshCouncil()
messerRow = rowOf("messer")
local expectedMesser
for _, expected in ipairs(cross.expected.raiders) do
    if expected.key == "messer" then expectedMesser = expected end
end
expectEqual(plain(messerRow.need:GetText()), ("Bedarf %d*"):format(expectedMesser.need), "live: the server's need, marked")
expectEqual(plain(messerRow.items:GetText()), "3 Items · 3,5 Pkt", "live: the BiS weapon counts 2 points")
for _, row in ipairs(rows()) do
    for _, expected in ipairs(cross.expected.raiders) do
        if expected.key == row.raider.key then
            expectEqual(row.raider.need, expected.need, "live window need of " .. expected.key)
        end
    end
end
