-- The loot council in game counts the awards since the last council sync, live:
-- RCLootCouncil and Gargul history read like the upload does (Collect.lua),
-- awards after generatedAt only, the server's reason rule (lootReasons.js) and
-- need formula (lootCouncil.js needScore), dedupe of RCLC + Gargul, name/realm
-- matching, BiS gaps closed, provisional markers in window, row and item
-- tooltip, the 3 s live check, newer council data dropping the awards again.
--
-- The expected need values are the server's needScore() run in node on the
-- same inputs (avg, parts and rounding exactly as councilSync.js sends them).
local EHS = EventHelperSync
local Council = EHS.Council

WoWMock.Fire("ADDON_LOADED", "EventHelperSync")
WoWMock.Fire("PLAYER_LOGIN")

local function latin1(text)
    return not tostring(text or ""):find("[\196-\244]")
end

local G = WoWMock.now - 7200 -- generatedAt of the council data
local DAY = 86400

local function link(id, name)
    return ("|cffa335ee|Hitem:%d::::::::70:::::|h[%s]|h|r"):format(id, name or ("Item " .. id))
end

--- Council data as the sync tool writes it (version 2): SSC/TK with four
--- raiders, Kara with two of them. `over` replaces raider fields per name.
local function councilData(generatedAt, over)
    over = over or {}
    local function raider(fields)
        for k, v in pairs(over[fields.character] or {}) do fields[k] = v end
        return fields
    end
    return {
        format = "eventhelper-council", version = 2, generatedAt = generatedAt,
        weights = { drought = 50, share = 40, need = 10 },
        categories = {
            {
                id = "1", name = "SSC/TK", lootSystem = "lootcouncil",
                filter = { role = "", tiers = { "t5" }, contents = {}, bisTier = "t5" },
                instances = { { id = "ssc", name = "Serpentshrine Cavern", short = "SSC", zoneNames = {} } },
                avgLootCount = 1.5,
                raiders = {
                    raider({ key = "gemli", character = "Gemli", classFile = "PRIEST", specLabel = "Shadow", role = "caster",
                        need = 60, parts = { drought = 40, share = 0, need = 40 }, lootCount = 2, lootTotal = 2, otherCount = 0,
                        lastAwardAt = G - 12 * DAY, daysSinceLoot = 12,
                        bis = { tier = "t5", owned = 9, total = 15, missing = { 30000, 30001, 30001 } },
                        items = { { itemId = 29000, itemName = "Altes Item", awardedAt = G - 12 * DAY, boss = "Lurker", reason = "BiS" } } }),
                    raider({ key = "naphfß", character = "Naphfß", classFile = "SHAMAN", specLabel = "Resto", role = "healer",
                        need = 20, parts = { drought = 0, share = 0, need = 75 }, lootCount = 3, lootTotal = 3, otherCount = 0,
                        lastAwardAt = G - 3600, daysSinceLoot = 0,
                        bis = { tier = "t5", owned = 4, total = 16, missing = { 30000 } }, items = {} }),
                    raider({ key = "forever~neuling", character = "Neuling", classFile = "MAGE", specLabel = "", role = "caster",
                        need = 90, parts = { drought = 100, share = 100, need = 50 }, lootCount = 0, lootTotal = 0, otherCount = 0,
                        lastAwardAt = 0, daysSinceLoot = -1,
                        bis = { tier = "t5", owned = 0, total = 0, missing = {} }, items = {} }),
                    raider({ key = "karl", character = "Karl", classFile = "MAGE", specLabel = "Arcane", role = "caster",
                        need = 40, parts = { drought = 17, share = 33, need = 40 }, lootCount = 1, lootTotal = 1, otherCount = 0,
                        lastAwardAt = G - 5 * DAY, daysSinceLoot = 5,
                        bis = { tier = "t5", owned = 3, total = 5, missing = { 30002 } }, items = {} }),
                },
            },
            {
                id = "2", name = "Kara", lootSystem = "lootcouncil",
                filter = { role = "", tiers = { "t4" }, contents = {}, bisTier = "t4" },
                instances = { { id = "kara", name = "Karazhan", short = "Kara", zoneNames = {} } },
                avgLootCount = 0.5,
                raiders = {
                    { key = "gemli", character = "Gemli", classFile = "PRIEST", specLabel = "Shadow", role = "caster",
                        need = 70, parts = { drought = 100, share = 100, need = 60 }, lootCount = 0, lootTotal = 0,
                        otherCount = 0, lastAwardAt = 0, daysSinceLoot = -1,
                        bis = { tier = "t4", owned = 2, total = 5, missing = { 28000, 30000 } }, items = {} },
                    { key = "karl", character = "Karl", classFile = "MAGE", specLabel = "Arcane", role = "caster",
                        need = 30, parts = { drought = 3, share = 0, need = 40 }, lootCount = 1, lootTotal = 1,
                        otherCount = 0, lastAwardAt = G - DAY, daysSinceLoot = 1,
                        bis = { tier = "t4", owned = 3, total = 5, missing = { 28000 } }, items = {} },
                },
            },
        },
    }
end

EventHelperSync_Council = councilData(G)
EHS.db.settings.councilCategory = "1"

-- Reason rule = lootReasons.js reasonIdFor() ------------------------------------------------

local reasons = {
    { "Main Spec", false, "mainspec" }, { "BiS", false, "bis" }, { "Best in Slot", false, "bis" },
    { "Minor Upgrade", false, "minor" }, { "Off-Spec Upgrade", false, "offspec" }, { "Upgrade", false, "upgrade" },
    { "Zweitspec", false, "offspec" }, { "OS", false, "offspec" }, { "Entzaubern", false, "disenchant" },
    { "de", false, "disenchant" }, { "Gildenbank", false, "bank" }, { "PvP", false, "pvp" },
    { "Need", false, "mainspec" }, { "Bedarf", false, "mainspec" }, { "Transmog", false, "greed" },
    { "Rest", false, "greed" }, { "Resto Upgrade", false, "upgrade" }, { "Pass", false, "other" },
    { "Bisschen", false, "other" }, { "Hose", true, "offspec" }, { "", true, "offspec" }, { "", false, "other" },
}
for _, case in ipairs(reasons) do
    expectEqual(Council.ReasonFor(case[1], case[2]), case[3], "reason of '" .. case[1] .. "'")
end
for _, id in ipairs({ "bis", "mainspec", "upgrade", "minor", "other" }) do
    expect(Council.CountsAsLoot(id), id .. " counts")
end
for _, id in ipairs({ "offspec", "pvp", "greed", "disenchant", "bank" }) do
    expect(not Council.CountsAsLoot(id), id .. " does not count")
end

-- Names like characterKeyOf() ----------------------------------------------------------------

expectEqual(Council.NameKey("Gemli-Thunderstrike"), "gemli", "realm suffix dropped")
expectEqual(Council.NameKey("NEULING"), "neuling", "case")
expectEqual(Council.NameKey("forever~Neuling"), "neuling", "version prefix of a key")
expectEqual(Council.NameKey("Naphfß-Thunderstrike"), "naphfß", "non-ASCII name")
expectEqual(Council.NameKey("Ärwin-Realm"), "ärwin", "Latin-1 capital lowered")

-- Need formula = needScore() ----------------------------------------------------------------

local need, parts = Council.NeedScore({ daysSinceLoot = 5, lootCount = 1, bis = { owned = 3, total = 5 } }, 2,
    { drought = 50, share = 40, need = 10 })
expectEqual(need, 32, "need")
expect(parts.drought == 17 and parts.share == 50 and parts.need == 40, "parts")
need, parts = Council.NeedScore({ daysSinceLoot = -1, lootCount = 0, bis = { owned = 0, total = 0 } }, 0,
    { drought = 50, share = 40, need = 10 })
expect(need == 75 and parts.drought == 100 and parts.share == 50 and parts.need == 50, "never looted, no avg, no BiS list")

-- Without RCLootCouncil and Gargul nothing changes ---------------------------------------------

local base = Council.Load()
expect(EHS:CouncilData(true) == base, "no loot addon: the synced data as it is")
EHS:ShowCouncil()
local council = EventHelperSyncCouncilFrame
expect(not council.header:GetText():find("vorläufig", 1, true), "no provisional header")
local rows = {}
for _, child in ipairs(WoWMock.frames) do
    if child.__parent == council.list and child.__kind == "Button" then rows[#rows + 1] = child end
end
expectEqual(rows[1].raider.character, "Neuling", "server order")
expectEqual(plain(rows[1].need:GetText()), "Bedarf 90", "server need, no marker")

-- The histories ---------------------------------------------------------------------------

local rclc = {}
RCLootCouncilLootDB = { factionrealm = { ["Alliance - Thunderstrike"] = rclc } }
local function rc(player, entry)
    rclc[player] = rclc[player] or {}
    table.insert(rclc[player], entry)
end
-- counted (mainspec), in SSC: only the SSC/TK category, one copy of a doubled BiS item
rc("Gemli-Thunderstrike", { lootWon = link(30001, "Ring"), id = (G + 600) .. "-1", response = "Main Spec",
    responseID = 1, instance = "Coilfang: Serpentshrine Cavern-25 Player", boss = "Lady Vashj", class = "PRIEST" })
-- before the sync: already in the data, ignored
rc("Gemli-Thunderstrike", { lootWon = link(30000, "Robe"), id = (G - 600) .. "-1", response = "Main Spec",
    responseID = 1, instance = "Coilfang: Serpentshrine Cavern-25 Player", boss = "Hydross", class = "PRIEST" })
-- offspec: does not count, but the BiS piece is his now
rc("Naphfß-Thunderstrike", { lootWon = link(30000, "Robe"), id = (G + 900) .. "-1", response = "Offspec",
    responseID = 4, instance = "Coilfang: Serpentshrine Cavern-25 Player", boss = "Hydross", class = "SHAMAN" })
-- an award reason (disenchant): left out like the upload does
rc("Karl-Thunderstrike", { lootWon = link(30002, "Zauberstab"), id = (G + 1000) .. "-1", response = "Disenchant",
    responseID = 1, isAwardReason = true, instance = "Coilfang: Serpentshrine Cavern-25 Player", boss = "Hydross" })

GargulDB = { AwardHistory = {
    -- the same award as RCLC's Gemli ring, 50 s later: one award
    a1 = { checksum = "a1", itemLink = link(30001, "Ring"), itemID = 30001, awardedTo = "Gemli", timestamp = G + 650, OS = false },
    -- name in other case, no realm, no instance: every category he is in (SSC/TK)
    a2 = { checksum = "a2", itemLink = link(31000, "Kappe"), itemID = 31000, awardedTo = "NEULING", timestamp = G + 1200, OS = false },
    -- disenchant placeholder, and someone in no category
    a3 = { checksum = "a3", itemLink = link(31001, "Splitter"), itemID = 31001, awardedTo = "||de||", timestamp = G + 1300 },
    a4 = { checksum = "a4", itemLink = link(31002, "Gürtel"), itemID = 31002, awardedTo = "Fremder", timestamp = G + 1400, OS = false },
} }

-- The window: opening/refreshing recomputes --------------------------------------------------

EHS:RefreshCouncil()
local data = EHS:CouncilData()
expect(data ~= base, "adjusted copy")
expectEqual(data.provisional.count, 3, "three awards applied (Gemli, Naphfß, Neuling)")
expectEqual(data.provisional.unmatched, 1, "the raider in no category")
local ssc, kara = data.categories[1], data.categories[2]
expectEqual(kara, base.categories[2], "Kara untouched: the SSC awards name SSC")
expectEqual(ssc.provisional, 3, "three in SSC/TK")
expectEqual(ssc.avgLootCount, 2, "avg (3 + 3 + 1 + 1) / 4")

local byName = {}
for _, raider in ipairs(ssc.raiders) do byName[raider.character] = raider end
local gemli, naph, neuling, karl = byName.Gemli, byName["Naphfß"], byName.Neuling, byName.Karl
expect(gemli.lootCount == 3 and gemli.lootTotal == 3 and gemli.daysSinceLoot == 0, "Gemli: one more counting item")
expectEqual(gemli.lastAwardAt, G + 600, "Gemli: last award = the RCLC time")
expectEqual(gemli.bis.owned, 10, "Gemli: BiS +1")
expectEqual(table.concat(gemli.bis.missing, ","), "30000,30001", "Gemli: one copy of the doubled ring closed")
expectEqual(#gemli.provisional.awards, 1, "Gemli: RCLC and Gargul deduped")
expectEqual(gemli.items[1].itemId, 30001, "new item first in the list")
expect(gemli.items[1].provisional and gemli.items[2].itemId == 29000, "marked, old items kept")
expect(naph.lootCount == 3 and naph.otherCount == 1, "Naphfß: offspec is an other item")
expect(naph.bis.owned == 5 and #naph.bis.missing == 0, "Naphfß: the BiS robe is closed anyway")
expectEqual(naph.daysSinceLoot, 0, "Naphfß: drought unchanged")
expect(neuling.lootCount == 1 and neuling.daysSinceLoot == 0, "Neuling matched case-insensitively")
expect(karl.lootCount == 1 and not karl.provisional, "Karl: the disenchant award reason is left out")

-- the server's needScore() on these numbers (node): Gemli 3, Naphfß 7, Neuling 25, Karl 32
expect(gemli.need == 3 and gemli.parts.drought == 0 and gemli.parts.share == 0 and gemli.parts.need == 33, "Gemli need")
expect(naph.need == 7 and naph.parts.need == 69, "Naphfß need")
expect(neuling.need == 25 and neuling.parts.share == 50 and neuling.parts.need == 50, "Neuling need")
expect(karl.need == 32 and karl.parts.drought == 17 and karl.parts.share == 50 and karl.parts.need == 40, "Karl need")
expectEqual(karl.needBefore, 40, "Karl: only the avg moved")
expectEqual(Council.ProvisionalKind(karl), "avg", "Karl: grey marker")
expectEqual(Council.ProvisionalKind(gemli), "own", "Gemli: orange marker")

-- base data untouched
expect(base.categories[1].raiders[1].lootCount == 2 and #base.categories[1].raiders[1].bis.missing == 3,
    "the synced data stays as it is")

-- re-sorted rows with markers
expectEqual(rows[1].raider.character, "Karl", "re-sorted: Karl first")
expectEqual(plain(rows[1].need:GetText()), "Bedarf 32*", "marker on a changed need")
expectEqual(rows[2].raider.character, "Neuling", "second")
expectEqual(rows[4].raider.character, "Gemli", "last")
expectEqual(plain(rows[4].items:GetText()), "3 Items", "item count")
expectEqual(plain(rows[4].bis:GetText()), "BiS 10/15", "BiS state")
local header = plain(council.header:GetText())
expect(header:find("vorläufig: 3 Vergaben seit " .. Council.FormatStamp(G), 1, true), "header: " .. header)
expect(latin1(header), "header is Latin-1")

-- row tooltip
WoWMock.Run(rows[4], "OnEnter")
local tip = WoWMock.TooltipText(GameTooltip)
expect(tip:find("inkl. 1 Vergabe seit dem letzten Sync (vorläufig)", 1, true), "provisional line:\n" .. tip)
expect(tip:find("Ring | Mainspec, BiS", 1, true), "the award with its reason:\n" .. tip)
expect(tip:find("Bedarf | 3 von 100*", 1, true), "need with marker")
expect(latin1(tip), "row tooltip is Latin-1")
WoWMock.Run(rows[3], "OnEnter")
tip = WoWMock.TooltipText(GameTooltip)
expect(tip:find("Offspec (zählt nicht), BiS", 1, true), "not counted, but BiS:\n" .. tip)
expect(tip:find("dazu 1 Offspec/Bank", 1, true), "other count")
WoWMock.Run(rows[1], "OnEnter")
tip = WoWMock.TooltipText(GameTooltip)
expect(tip:find("vorher Bedarf 40", 1, true), "avg-only hint:\n" .. tip)
expect(latin1(tip), "hint is Latin-1")

-- item tooltip: adjusted numbers, raiders who just got it dropped
WoWMock.ShowItem(GameTooltip, 30000)
tip = WoWMock.TooltipText(GameTooltip)
expect(tip:find("Gemli (Shadow) Bedarf 3* - 3 Items", 1, true), "adjusted numbers:\n" .. tip)
expect(not tip:find("Naphfß", 1, true), "Naphfß got the robe")
WoWMock.ShowItem(GameTooltip, 30001)
tip = WoWMock.TooltipText(GameTooltip)
expect(tip:find("Gemli", 1, true) and not tip:find("fehlt 2x", 1, true), "one ring left:\n" .. tip)
expect(latin1(tip), "item tooltip is Latin-1")

-- /ehs status
WoWMock.prints = {}
SlashCmdList.EVENTHELPERSYNC("status")
expect(table.concat(WoWMock.prints, "\n"):find("vorläufig: 3 Vergaben", 1, true), "status line")

-- Live: a new award shows up within 3 s while the window is open -------------------------------

rc("Karl-Thunderstrike", { lootWon = link(30002, "Zauberstab"), id = (G + 2000) .. "-1", response = "BiS",
    responseID = 1, instance = "Coilfang: Serpentshrine Cavern-25 Player", boss = "Lady Vashj", class = "MAGE" })
WoWMock.Run(council, "OnUpdate", 1)
expectEqual(rows[1].raider.character, "Karl", "not yet (1 s)")
WoWMock.Run(council, "OnUpdate", 2.5)
-- avg 2.25: Neuling 27, Naphfß 7, Karl 6, Gemli 3 (server needScore)
expectEqual(rows[1].raider.character, "Neuling", "recomputed after 3 s")
expectEqual(plain(rows[1].need:GetText()), "Bedarf 27*", "Neuling")
expectEqual(rows[3].raider.character, "Karl", "Karl dropped")
expectEqual(plain(rows[3].need:GetText()), "Bedarf 6*", "Karl need")
expect(plain(council.header:GetText()):find("vorläufig: 4 Vergaben", 1, true), "four now")
WoWMock.ShowItem(GameTooltip, 30002)
expect(not WoWMock.TooltipText(GameTooltip):find("Karl", 1, true), "Karl's BiS wand is his now")

-- tooltip alone (window closed) also sees new history, at most once a second; a Gargul
-- award has no instance - the own zone timeline says Karazhan, so only the Kara category
council:Hide()
EHS.db.zones = { { name = "Karazhan", at = G + 2050, until_ = G + 2050 } }
GargulDB.AwardHistory.a5 = { checksum = "a5", itemLink = link(28000, "Kara-Ring"), itemID = 28000, awardedTo = "Gemli",
    timestamp = G + 2100, OS = false }
EHS:SetCouncilCategory("2")
WoWMock.now = WoWMock.now + 1
WoWMock.ShowItem(GameTooltip, 28000)
tip = WoWMock.TooltipText(GameTooltip)
expect(tip:find("Karl", 1, true) and not tip:find("Gemli", 1, true), "Kara: Gemli's ring counted without the window:\n" .. tip)
local karaGemli = EHS:CouncilData().categories[2].raiders[1]
expect(karaGemli.character == "Gemli" and karaGemli.lootCount == 1, "Gemli: one item in Kara")
expectEqual(EHS:CouncilData().categories[1].provisional, 4, "SSC/TK untouched by the Kara ring")
EHS:SetCouncilCategory("1")

-- Newer council data: those awards are in the server's numbers, the time filter drops them -----

-- as the server would send it at G + 1500: the first three awards included
EventHelperSync_Council = councilData(G + 1500, {
    Gemli = { need = 3, lootCount = 3, lootTotal = 3, daysSinceLoot = 0, lastAwardAt = G + 600,
        bis = { tier = "t5", owned = 10, total = 15, missing = { 30000, 30001 } } },
    ["Naphfß"] = { need = 7, otherCount = 1, bis = { tier = "t5", owned = 5, total = 16, missing = {} } },
    Neuling = { need = 25, lootCount = 1, lootTotal = 1, daysSinceLoot = 0, lastAwardAt = G + 1200 },
    Karl = { need = 32 },
})
EHS:ShowCouncil()
data = EHS:CouncilData()
expectEqual(data.provisional.count, 2, "only Karl's wand and Gemli's Kara ring are newer")
byName = {}
for _, raider in ipairs(data.categories[1].raiders) do byName[raider.character] = raider end
expectEqual(byName.Gemli.lootCount, 3, "Gemli's ring not counted twice")
expect(not byName.Gemli.provisional and not byName.Gemli.needBefore, "Gemli unchanged (need 3 as before)")
expectEqual(byName.Neuling.need, 27, "Neuling: new avg")
expect(byName.Karl.need == 6 and byName.Karl.lootCount == 2, "Karl: his wand")
expect(plain(council.header:GetText()):find("vorläufig: 1 Vergabe seit", 1, true), "one award in SSC/TK")

EventHelperSync_Council = councilData(G + 5000)
EHS:RefreshCouncil()
expect(EHS:CouncilData() == Council.Load(), "everything synced: the data as it is")
expect(not council.header:GetText():find("vorläufig", 1, true), "no provisional header")
expectEqual(plain(rows[1].need:GetText()), "Bedarf 90", "no markers")

-- Award reasons kept (setting off): a disenchant counts as an other item ------------------------

EventHelperSync_Council = councilData(G)
EHS.db.settings.skipAwardReasons = false
EHS:RefreshCouncil()
data = EHS:CouncilData()
for _, raider in ipairs(data.categories[1].raiders) do byName[raider.character] = raider end
expect(byName.Karl.otherCount == 1 and byName.Karl.lootCount == 2, "Karl: disenchant other, wand counted")
expectEqual(byName.Karl.bis.owned, 4, "the disenchanted wand is not his - the BiS wand is")
EHS.db.settings.skipAwardReasons = true

-- RCLootCouncil over its API (GetHistoryDB), as in the game ------------------------------------

RCLootCouncilLootDB = nil
local api = { GetHistoryDB = function() return rclc end }
LibStub = function(name) if name == "AceAddon-3.0" then return { GetAddon = function() return api end } end end
EHS:RefreshCouncil()
data = EHS:CouncilData()
expect(data.provisional and data.provisional.count >= 4, "history over the RCLC API")

-- A broken history never breaks the council
api.GetHistoryDB = function() error("boom") end
GargulDB = { AwardHistory = "nope" }
EHS:RefreshCouncil()
expect(EHS:CouncilData() == Council.Load(), "broken history: the synced data")
LibStub = nil
