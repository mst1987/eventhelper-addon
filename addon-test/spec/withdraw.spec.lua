-- GuildBankWithdraw.lua on the TBC client with a slow server: planning
-- (exact, whole smaller stacks, split, daily limit per tab, shared stacks),
-- the bag check that counts taken items for their entry, taking out with
-- AutoStoreGuildBankItem (whole) and SplitGuildBankItem + PickupContainerItem
-- (part), the stored scan following, querying a tab the client lost, the
-- limit, no bag space, combat, scanning, a closed bank, the bank closing
-- mid-way, the fallback when the client raises, and every chat line Latin-1.
loadAddon()
WoWMock.login({ lastFlushedAt = 1, settings = { autoOpenHandouts = false } })
local EHS = EventHelperSync
-- every chat line of the spec, for the Latin-1 check at the end
local everything = {}
local basePrint = print
print = function(...)
    basePrint(...)
    everything[#everything + 1] = WoWMock.prints[#WoWMock.prints]
end
local W = EHS.Withdraw
local Mail = EHS.Mail
local NOW = WoWMock.now

local function latin1Only(text)
    local i = 1
    while i <= #text do
        local b = text:byte(i)
        if b >= 0x80 then
            if b ~= 0xC2 and b ~= 0xC3 then return false end
            i = i + 1
        end
        i = i + 1
    end
    return true
end

-- Planning ---------------------------------------------------------------------------------------

local function st(tab, slot, itemId, count) return { tab = tab, slot = slot, itemId = itemId, count = count } end
local function stepText(step) return ("%s %d/%d x%d"):format(step.kind, step.tab, step.slot, step.count) end

local plan = W.Plan({ { key = "a", itemId = 7, need = 5 } }, { st(1, 1, 7, 3), st(1, 2, 7, 20), st(2, 3, 7, 5) })
expectEqual(#plan.steps, 1, "exact stack")
expectEqual(stepText(plan.steps[1]), "whole 2/3 x5", "the stack of 5 whole")

plan = W.Plan({ { key = "a", itemId = 7, need = 5 } }, { st(1, 1, 7, 3), st(1, 2, 7, 20), st(2, 3, 7, 2) })
expectEqual(#plan.steps, 2, "whole smaller stacks before splitting")
expectEqual(stepText(plan.steps[1]), "whole 1/1 x3", "largest smaller first")
expectEqual(stepText(plan.steps[2]), "whole 2/3 x2", "then the exact rest")

plan = W.Plan({ { key = "a", itemId = 7, need = 4 } }, { st(1, 1, 7, 20), st(1, 2, 7, 6) })
expectEqual(#plan.steps, 1, "one split")
expectEqual(stepText(plan.steps[1]), "split 1/2 x4", "split the smallest sufficient stack")
expectEqual(plan.steps[1].stackCount, 6, "from a stack of 6")

plan = W.Plan({ { key = "a", itemId = 7, need = 4 }, { key = "b", itemId = 7, need = 4 } }, { st(1, 1, 7, 6) })
expectEqual(#plan.steps, 2, "two needs share the stack")
expectEqual(stepText(plan.steps[1]) .. ", " .. stepText(plan.steps[2]), "split 1/1 x4, whole 1/1 x2", "the rest of it")
expect(plan.short.b and plan.short.b.missing == 2 and plan.short.b.reason == "stock", "2 missing: stock")
expect(not plan.short.a, "the first is complete")

plan = W.Plan({ { key = "a", itemId = 7, need = 3 } }, { st(1, 1, 7, 1), st(1, 2, 7, 1), st(1, 3, 7, 1) }, { [1] = 2 })
expectEqual(#plan.steps, 2, "two withdrawals left today")
expect(plan.short.a.missing == 1 and plan.short.a.reason == "limit", "the third: limit")
plan = W.Plan({ { key = "a", itemId = 7, need = 1 } }, { st(1, 1, 7, 5) }, { [1] = 0 })
expect(#plan.steps == 0 and plan.short.a.reason == "limit", "no withdrawals left")
plan = W.Plan({ { key = "a", itemId = 7, need = 3 } }, { st(1, 1, 7, 1), st(1, 2, 7, 1), st(1, 3, 7, 1) }, { [1] = -1 })
expect(#plan.steps == 3 and not plan.short.a, "-1: unlimited")
plan = W.Plan({ { key = "a", itemId = 7, need = 2 } }, { st(1, 1, 7, 5) }, { [1] = 0, [2] = 3 })
expect(plan.short.a.reason == "limit", "only the limited tab has it")
plan = W.Plan({ { key = "a", itemId = 8, need = 2 } }, { st(1, 1, 7, 5) }, {})
expect(#plan.steps == 0 and plan.short.a.missing == 2 and plan.short.a.reason == "stock", "not in the bank")

expectEqual(W.SlotLabel(2, 17), "Tab 2 Platz 17", "slot label")
local lines = W.ManualLines({ { kind = "whole", tab = 1, slot = 5, count = 2, itemId = 1, key = "x" },
    { kind = "split", tab = 2, slot = 1, count = 3, stackCount = 10, itemId = 2, key = "y" } },
    { x = "Bold Living Ruby", y = "Robe \226\128\147 neu" })
expectEqual(lines[1], "Tab 1 Platz 5: 2x Bold Living Ruby", "manual line")
expectEqual(lines[2], "Tab 2 Platz 1: 3x Robe - neu (von 10, Shift-Klick teilt den Stapel)", "split line, Latin-1")

-- Bag check: what was taken counts for its entry first
local groups = { { entries = { { id = "a", itemId = 1, amount = 2 }, { id = "b", itemId = 1, amount = 2 } } } }
Mail.CheckBags(groups, { [1] = 2 }, { b = 2 })
expectEqual(groups[1].entries[1].bagMissing, 2, "a gets nothing: b took them")
expectEqual(groups[1].entries[2].bagMissing, 0, "b has its own")
Mail.CheckBags(groups, { [1] = 2 })
expectEqual(groups[1].entries[1].bagMissing, 0, "without reservation: list order")

-- The data, the bank, the bags --------------------------------------------------------------------

local RUBY, POTION, FLASK, POWDER, ROBE, GEM = 24027, 22829, 13512, 17020, 30100, 23436
WoWMock.items[RUBY] = { name = "Bold Living Ruby" }
WoWMock.items[POTION] = { name = "Super Healing Potion" }

local function handout(id, itemId, name, amount, recipient, tabs)
    return { id = id, itemId = itemId, name = name, icon = "", quality = 3, amount = amount, purpose = "",
        character = recipient and { name = recipient, realm = "Thunderstrike", faction = "Alliance", classFile = "MAGE" } or nil,
        requestedBy = "Anna", requestedAt = NOW - 7200, confirmedBy = "Arthas", confirmedAt = NOW - 3600, inBank = 10,
        tabs = tabs or {} }
end
EventHelperSync_GuildBankHandouts = {
    format = "eventhelper-guildbank-handouts", version = 1, generatedAt = NOW - 600,
    banks = { { key = "tbc:thunderstrike:pulse", gameVersion = "tbc", realm = "Thunderstrike", guild = "Pulse",
        faction = "Alliance", scannedAt = NOW - 600, handouts = {
            handout("h1", RUBY, "Bold Living Ruby", 2, "Zibbo"),
            handout("h2", FLASK, "Flask of Supreme Power", 1, "Zibbo"),
            handout("h3", RUBY, "Bold Living Ruby", 3, "Thrall"),
            handout("h4", POTION, "Super Healing Potion", 2, "Jaina"),
            handout("h5", POWDER, "Arcane Powder", 1, nil, { { index = 3, name = "Reserve", count = 1 } }),
            handout("h6", ROBE, "Robe \226\128\147 \226\128\158Neu\226\128\156", 1, "Uther"),
            handout("h7", GEM, "Living Ruby", 1, "Uther"),
        } } },
}

WoWMock.guildBank = {
    money = 0, respondAfter = 0.25, withdrawAfter = 0.3,
    tabs = {
        { name = "Edelsteine", slots = { [1] = { id = RUBY, count = 10 }, [5] = { id = RUBY, count = 2 } } },
        { name = "Verbrauch", remaining = 1, slots = { [1] = { id = POTION, count = 1 }, [2] = { id = POTION, count = 1 },
            [3] = { id = FLASK, count = 1 } } },
        { name = "Reserve", slots = { [7] = { id = POWDER, count = 20 } } },
        { name = "Kleidung", slots = { [1] = { id = ROBE, count = 1 }, [2] = { id = GEM, count = 1 } } },
    },
}
WoWMock.setBags({})
WoWMock.mail.unlockAfter = 0.2

local function entry(id)
    for _, e in ipairs((EHS:GetHandoutEntries())) do
        if e.id == id then return e end
    end
    error("no entry " .. id)
end
local function take(id, all)
    return EHS:WithdrawHandouts(W.EntriesFor(entry(id), all))
end
local function calls() return #(WoWMock.guildBank.calls or {}) end

-- the bank is closed: nothing happens, not even a chat line
WoWMock.prints = {}
local ok, reason = take("h1")
expect(not ok and reason == "closed", "closed bank: nothing")
expectEqual(#WoWMock.prints, 0, "no chat line")
expectEqual(calls(), 0, "no client call")

-- open: the scan reads the tabs first
WoWMock.openGuildBank("tbc")
ok, reason = take("h1")
expect(not ok and reason == "scanning", "not while the scan runs")
expect(WoWMock.printed("Die Gildenbank wird noch gelesen"), "scanning line")
WoWMock.advance(5)
expect(not EHS:IsGuildBankScanning() and EventHelperSyncDB.guildBank, "scanned")

-- combat
WoWMock.inCombat = true
ok, reason = take("h1")
expect(not ok and reason == "combat", "not in combat")
expect(WoWMock.printed("Nicht im Kampf"), "combat line")
WoWMock.inCombat = false

-- Whole stack: AutoStoreGuildBankItem --------------------------------------------------------------

local scannedAt = EventHelperSyncDB.guildBank.scannedAt
WoWMock.advance(10)
WoWMock.prints = {}
expect(take("h1"), "started")
expectEqual(WoWMock.guildBank.calls[1], "AutoStoreGuildBankItem", "the exact stack of 2 whole")
expect(EHS:WithdrawingHandout("h1"), "running")
expect(not EHS:WithdrawingHandout("h3"), "only its entry")
ok, reason = take("h3")
expect(not ok and reason == "busy", "one at a time")
WoWMock.advance(0.2)
expect(WoWMock.bags[0].slots[1] == nil, "not yet (slow server)")
WoWMock.advance(2)
expect(not EHS:WithdrawingHandout(), "done")
local bagRuby = WoWMock.bags[0].slots[1]
expect(bagRuby and bagRuby.id == RUBY and bagRuby.count == 2, "two rubies in the bags")
expect(WoWMock.guildBank.tabs[1].slots[5] == nil, "the stack left the bank")
expect(WoWMock.printed("Aus der Gildenbank genommen: 2x Bold Living Ruby"), "chat line")
expectEqual(EHS:IsHandedOut("h1"), nil, "taking out does not tick")
expectEqual(EHS:WithdrawnAmounts().h1, 2, "noted for the entry")
local scan = EventHelperSyncDB.guildBank
expect(scan.scannedAt > scannedAt, "the stored scan follows")
local rubies = 0
for _, item in ipairs(scan.tabs[1].items) do if item.itemId == RUBY then rubies = rubies + item.count end end
expectEqual(rubies, 10, "scan: 10 rubies left in tab 1")
expectEqual(entry("h1").count, 10, "live count of the window")

-- the bags hold them for Zibbo now (though Thrall comes first in the list)
expectEqual(W.EntriesFor(entry("h1"))[1].bagMissing, 0, "Zibbo's rubies are in the bags")
expectEqual(W.EntriesFor(entry("h3"))[1].bagMissing, 3, "Thrall still needs 3")
WoWMock.prints = {}
ok, reason = take("h1")
expect(not ok and reason == "bags", "already in the bags")
expect(WoWMock.printed("2x Bold Living Ruby ist schon in den Taschen."), "said so")

-- Part of a stack: SplitGuildBankItem, then into a free bag slot ---------------------------------------

local before = calls()
WoWMock.prints = {}
expect(take("h3"), "started")
expectEqual(WoWMock.guildBank.calls[before + 1], "SplitGuildBankItem", "3 split off the 10")
WoWMock.advance(3)
local bagSplit = WoWMock.bags[0].slots[2]
expect(bagSplit and bagSplit.id == RUBY and bagSplit.count == 3 and not bagSplit.locked, "three rubies in a free slot")
expectEqual(WoWMock.guildBank.tabs[1].slots[1].count, 7, "seven left in the bank")
expect(WoWMock.cursor == nil, "cursor empty")
expect(WoWMock.printed("Aus der Gildenbank genommen: 3x Bold Living Ruby"), "chat line")
expectEqual(W.EntriesFor(entry("h3"))[1].bagMissing, 0, "Thrall's are there")
expectEqual(W.EntriesFor(entry("h1"))[1].bagMissing, 0, "and Zibbo's still")

-- The daily limit: one withdrawal left in tab 2 --------------------------------------------------------

WoWMock.prints = {}
expect(take("h4"), "started")
WoWMock.advance(3)
local potion = WoWMock.bags[0].slots[3]
expect(potion and potion.id == POTION and potion.count == 1, "one potion")
expect(WoWMock.printed("Aus der Gildenbank genommen: 1x Super Healing Potion"), "took one")
expect(WoWMock.printed("Super Healing Potion: 1 von 2 nicht genommen - Tageslimit des Tabs erreicht."), "limit line")
expectEqual(WoWMock.guildBank.tabs[2].remaining, 0, "tab 2 used up")
expectEqual(W.EntriesFor(entry("h4"))[1].bagMissing, 1, "one still missing")

before = calls()
WoWMock.prints = {}
take("h2")
WoWMock.advance(1)
expectEqual(calls(), before, "no call against the limit")
expect(WoWMock.printed("Flask of Supreme Power: 1 von 1 nicht genommen - Tageslimit des Tabs erreicht."), "limit")
expect(not EHS:WithdrawingHandout(), "nothing running")

-- A tab the client lost: queried first ------------------------------------------------------------------

WoWMock.guildBank.tabs[3].cached = false
local queries = #WoWMock.queries
WoWMock.prints = {}
expect(take("h5"), "started")
expectEqual(#WoWMock.queries, queries + 1, "tab queried")
expectEqual(WoWMock.queries[#WoWMock.queries], 3, "the tab the server named")
expect(EHS:WithdrawingHandout("h5"), "waiting for the tab")
WoWMock.advance(3)
expect(WoWMock.printed("Aus der Gildenbank genommen: 1x Arcane Powder"), "found after the query")
expectEqual(WoWMock.guildBank.tabs[3].slots[7].count, 19, "split off the 20")

-- Bank closes mid-way -------------------------------------------------------------------------------------

WoWMock.prints = {}
expect(take("h7"), "started")
WoWMock.advance(0.1)
WoWMock.closeGuildBank("tbc")
expect(not EHS:WithdrawingHandout(), "stopped")
expect(WoWMock.printed("Gildenbank geschlossen - Entnehmen abgebrochen."), "closed line")
expect(not WoWMock.printed("Aus der Gildenbank genommen: 1x Living Ruby"), "nothing reported as taken")
expect(WoWMock.cursor == nil, "cursor clean")
WoWMock.advance(1)
ok, reason = take("h7")
expect(not ok and reason == "closed", "closed: nothing")

-- No bag space ----------------------------------------------------------------------------------------------

WoWMock.openGuildBank("tbc")
WoWMock.advance(5)
local bags = WoWMock.bags
WoWMock.setBags({}, { [0] = 0, [1] = 0, [2] = 0, [3] = 0, [4] = 0 })
before = calls()
WoWMock.prints = {}
ok, reason = take("h4")
expect(not ok and reason == "nospace", "no free bag slot")
expect(WoWMock.printed("Kein freier Taschenplatz - erst Platz schaffen."), "bag line")
expectEqual(calls(), before, "no client call")
WoWMock.bags = bags

-- Shift-click: everything of a recipient ---------------------------------------------------------------------

local all = W.EntriesFor(entry("h1"), true)
expectEqual(#all, 2, "both of Zibbo")
-- (the ruby is in the bags: only the flask is taken, and tab 2 has no withdrawals left)
WoWMock.prints = {}
take("h1", true)
WoWMock.advance(2)
expect(not WoWMock.printed("Bold Living Ruby"), "the ruby is not taken again")
expect(WoWMock.printed("Flask of Supreme Power: 1 von 1 nicht genommen"), "the flask hits the limit")

-- The client raises on the item calls: list the slots ---------------------------------------------------------

WoWMock.guildBank.block = "error"
WoWMock.prints = {}
before = calls()
expect(take("h3", false) == false, "Thrall is complete")
WoWMock.prints = {}
take("h6")
WoWMock.advance(2)
expect(EHS:GuildBankWithdrawBlocked(), "remembered for the session")
expect(WoWMock.printed("Entnehmen aus der Gildenbank ist auf diesem Client gesperrt. Bitte selbst in die Taschen nehmen:"),
    "blocked line")
expect(WoWMock.printed("  Tab 4 Platz 1: 1x Robe - \"Neu\""), "slot line, Latin-1")
expect(WoWMock.cursor == nil, "cursor clean")
expect(not EHS:WithdrawingHandout(), "stopped")

-- next click: the slots straight away, no client call
WoWMock.guildBank.block = nil
before = calls()
WoWMock.prints = {}
take("h6")
WoWMock.advance(2)
expectEqual(calls(), before, "no further call this session")
expect(WoWMock.printed("  Tab 4 Platz 1: 1x Robe - \"Neu\""), "slot line again")

-- every chat line of this spec is Latin-1
expect(#everything > 20, "chat lines collected")
for _, line in ipairs(everything) do expect(latin1Only(line), "Latin-1: %s", line) end
