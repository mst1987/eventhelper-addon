-- Council.lua with the weighting of council data version 3 (#670), on the TBC
-- client, without the window: the need formula against the server's
-- needScore() (expected values computed in node with
-- src/web/loot/lootCouncil.js on the same inputs), the item weight with
-- missing settings, the drought walk without droughtBase, and a category
-- WITHOUT weighting (a v2 server, written as v3 by the sync tool) that keeps
-- the old three-part math and ignores the clock.
loadAddon()
WoWMock.login({})
local EHS = EventHelperSync
local Council = EHS.Council

local SHARES = { drought = 0.4, share = 0.3, need = 0.1, tenure = 0.2 }
local WEIGHTS = { drought = 40, share = 30, need = 10, tenure = 20, shares = SHARES, droughtDays = 30, tenureDays = 60 }

-- needScore() of the server ------------------------------------------------------------------

-- node: needScore({ droughtDays: 12.5, lootPoints: 2, avgLootPoints: 3.25, bisOwned: 4, bisTotal: 16,
--   tenureDays: 45 }, shares, 60) = { score: 0.507, parts: { drought: 0.417, share: 0.385, need: 0.75, tenure: 0.75 } }
local need, parts = Council.NeedScoreV3({ droughtDays = 12.5, lootPoints = 2, tenureDays = 45, bis = { owned = 4, total = 16 } },
    3.25, WEIGHTS)
expectEqual(need, 51, "need")
expect(parts.drought == 42 and parts.share == 39 and parts.need == 75 and parts.tenure == 75, "parts")
-- { score: 0.6, parts: { drought: 1, share: 0.5, need: 0.5, tenure: 0 } }
need, parts = Council.NeedScoreV3({ droughtDays = 30, lootPoints = 0, tenureDays = 0, bis = { owned = 0, total = 0 } }, 0, WEIGHTS)
expect(need == 60 and parts.drought == 100 and parts.share == 50 and parts.need == 50 and parts.tenure == 0,
    "never looted, no average, no BiS list, unknown tenure")
-- { score: 0.2, parts: { drought: 0, share: 0, need: 0, tenure: 1 } }
need, parts = Council.NeedScoreV3({ droughtDays = 0, lootPoints = 7, tenureDays = 400, bis = { owned = 16, total = 16 } },
    3.25, WEIGHTS)
expect(need == 20 and parts.tenure == 100 and parts.share == 0, "tenure saturates, share clamps at 0")

-- Item weight with incomplete settings -------------------------------------------------------

local category = {
    weights = WEIGHTS,
    itemWeights = { classes = { trinket = 4 }, overrides = { ["500"] = 0 } },
    itemClasses = { ["100"] = "trinket", ["200"] = "weapon", ["300"] = "set" },
}
expectEqual(select(1, Council.ItemWeight(category, {}, 100)), 4, "the category's trinket weight")
expectEqual(select(1, Council.ItemWeight(category, {}, 200)), 1.5, "a class the data does not name: server default")
expectEqual(select(1, Council.ItemWeight(category, { bisWeapons = { 200 } }, 200)), 2, "bisWeapon default 2")
expectEqual(select(2, Council.ItemWeight(category, {}, 500)), "override", "an exception of weight 0 is still an exception")
expectEqual(select(1, Council.ItemWeight(category, {}, 500)), 0, "weight 0")
expectEqual(select(2, Council.ItemWeight({ weights = WEIGHTS }, {}, 300)), "normal", "no item classes: normal")

-- Drought walk without droughtBase (older v3 data): from droughtDays - daysSinceLoot -------------

local G = 1791000000
local DAY = 86400
local function data(raider, weighted)
    local cat = {
        id = "1", name = "Test", lootSystem = "lootcouncil", filter = { role = "" }, instances = {}, avgLootCount = 1,
        raiders = { raider },
    }
    if weighted then
        cat.weights = WEIGHTS
        cat.itemWeights = { classes = { trinket = 2, bisWeapon = 2, weapon = 1.5, set = 1, normal = 1, frequent = 0.5 }, overrides = {} }
        cat.itemClasses = { ["400"] = "frequent" }
    end
    return Council.Load({ format = "eventhelper-council", version = 3, generatedAt = G, weights = { drought = 50, share = 40, need = 10 },
        categories = { cat } })
end
local raider = {
    key = "zed", character = "Zed", role = "melee", need = 50, parts = { drought = 40, share = 50, need = 50, tenure = 0 },
    lootCount = 1, lootPoints = 1, lastAwardAt = G - 4 * DAY, daysSinceLoot = 4, droughtDays = 12,
    joinedAt = G - 10 * DAY, tenureDays = 10, bis = { owned = 0, total = 0, missing = {} }, items = {},
}
local adjusted = Council.ApplyAwards(data(raider, true),
    { { player = "Zed", itemId = 400, awardedAt = G + 2 * DAY, response = "Mainspec" } }, G + 3 * DAY)
local zed = adjusted.categories[1].raiders[1]
-- base 12 - 4 = 8, + 6 days until the award = 14, x 0.5 = 7, + 1 day since = 8
expectEqual(zed.droughtDays, 8, "the walk without droughtBase")
expectEqual(zed.lootPoints, 1.5, "half a point")
expectEqual(zed.daysSinceLoot, 1, "a day since the award")
expectEqual(zed.tenureDays, 13, "tenure moved with the clock")

-- A category without weighting: the old math, the clock ignored ---------------------------------

local old = Council.ApplyAwards(data(raider, false),
    { { player = "Zed", itemId = 400, awardedAt = G + 2 * DAY, response = "Mainspec" } }, G + 30 * DAY)
local oldZed = old.categories[1].raiders[1]
expect(not Council.IsWeighted(old.categories[1]), "no weighting")
expectEqual(oldZed.lootCount, 2, "one more item")
expectEqual(oldZed.daysSinceLoot, 0, "drought 0 like before (v2 rule)")
expectEqual(oldZed.lootPoints, 1, "points untouched without weighting")
expectEqual(oldZed.tenureDays, 10, "tenure untouched without weighting")
expectEqual(#Council.PartsOf(old.categories[1]), 3, "three parts")
