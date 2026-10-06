-- GuildBankWithdraw.lua on a Retail-like client (WoW Forever): guild bank
-- via the interaction manager, C_Container only. First it works (split into
-- a free slot with C_Container.PickupContainerItem), then the client ignores
-- the calls silently: a whole stack that never arrives only times out (no
-- block), an empty cursor after the split counts as blocked.
-- withdraw-blocked.spec.lua has the same with ADDON_ACTION_BLOCKED.
WOW_PROJECT_ID = 1
WoWMock.build.interface = 16001
WoWMock.useBagApi("c_container")

loadAddon()
WoWMock.login({ lastFlushedAt = 1, settings = { autoOpenHandouts = false } })
local EHS = EventHelperSync
local W = EHS.Withdraw
local NOW = WoWMock.now
local RUBY, POTION = 24027, 22829

local function handout(id, itemId, name, amount, recipient)
    return { id = id, itemId = itemId, name = name, icon = "", quality = 3, amount = amount, purpose = "",
        character = { name = recipient, realm = "Thunderstrike", faction = "Alliance", classFile = "MAGE" },
        requestedBy = "Anna", requestedAt = NOW - 7200, confirmedBy = "Arthas", confirmedAt = NOW - 3600, inBank = 10,
        tabs = {} }
end
EventHelperSync_GuildBankHandouts = {
    format = "eventhelper-guildbank-handouts", version = 1, generatedAt = NOW - 600,
    banks = { { key = "forever:thunderstrike:pulse", gameVersion = "forever", realm = "Thunderstrike", guild = "Pulse",
        faction = "Alliance", scannedAt = NOW - 600, handouts = {
            handout("f1", RUBY, "Bold Living Ruby", 2, "Zibbo"),
            handout("f2", RUBY, "Bold Living Ruby", 1, "Thrall"),
            handout("f3", POTION, "Super Healing Potion", 5, "Jaina"),
        } } },
}
WoWMock.guildBank = {
    money = 0, respondAfter = 0.25,
    tabs = { { name = "Alles", slots = { [3] = { id = RUBY, count = 10 }, [4] = { id = POTION, count = 5 } } } },
}
WoWMock.setBags({ [0] = { [1] = { 6948, 1 } } })

local function entry(id)
    for _, e in ipairs((EHS:GetHandoutEntries())) do
        if e.id == id then return e end
    end
    error("no entry " .. id)
end
local function take(id) return EHS:WithdrawHandouts(W.EntriesFor(entry(id))) end

WoWMock.openGuildBank("retail")
expect(EHS:IsGuildBankOpen(), "open via PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
WoWMock.advance(3)

-- it works: split 2 off the 10 into the first free slot (bag 0 slot 2)
WoWMock.prints = {}
expect(take("f1"), "started")
WoWMock.advance(2)
local placed = WoWMock.bags[0].slots[2]
expect(placed and placed.id == RUBY and placed.count == 2, "split into the bags via C_Container")
expect(WoWMock.printed("Aus der Gildenbank genommen: 2x Bold Living Ruby"), "chat line")

-- silent AutoStore: the stack never arrives - a timeout, not a block
WoWMock.guildBank.block = "silent"
WoWMock.prints = {}
expect(take("f3"), "started")
WoWMock.advance(10)
expect(WoWMock.printed("Entnehmen hat nicht geklappt. Bitte selbst nehmen:"), "timeout line")
expect(WoWMock.printed("  Tab 1 Platz 4: 5x Super Healing Potion"), "slot line")
expect(not EHS:GuildBankWithdrawBlocked(), "a timeout is no block")
expect(not EHS:WithdrawingHandout(), "stopped")
expectEqual(WoWMock.guildBank.tabs[1].slots[4].count, 5, "nothing moved")

-- silent split: the cursor stays empty - blocked
WoWMock.prints = {}
expect(take("f2"), "started")
WoWMock.advance(5)
expect(EHS:GuildBankWithdrawBlocked(), "empty cursor after the split: blocked")
expect(WoWMock.printed("Entnehmen aus der Gildenbank ist auf diesem Client gesperrt."), "blocked line")
expect(WoWMock.printed("  Tab 1 Platz 3: 1x Bold Living Ruby (von 8, Shift-Klick teilt den Stapel)"), "slot line")
expect(WoWMock.cursor == nil, "cursor clean")
expectEqual(WoWMock.guildBank.tabs[1].slots[3].count, 8, "nothing moved")
