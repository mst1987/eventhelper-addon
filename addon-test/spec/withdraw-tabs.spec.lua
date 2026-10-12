-- GuildBankWithdraw.lua on TBC Anniversary with a bag addon (Baganator) that
-- shows tab 1 while the handouts lie in tab 3 - the reported case. The client
-- acts on the current tab only (the mock ignores actions on another tab, as
-- the real client does), so each tab is selected before its steps (the shown
-- tab first), the shown tab comes back afterwards, and the withdraw log holds
-- the switches. Without the switch every call would land as "@other".
WoWMock.build.interface = 20506
loadAddon()
WoWMock.login({ lastFlushedAt = 1, settings = { autoOpenHandouts = false } })
local EHS = EventHelperSync
local W = EHS.Withdraw
local NOW = WoWMock.now
local PYRESTONE, SPINEL, LIONSEYE, AMETHYST = 23441, 32249, 32228, 32229

local function handout(id, itemId, name, amount, recipient)
    return { id = id, itemId = itemId, name = name, icon = "", quality = 3, amount = amount, purpose = "",
        character = { name = recipient, realm = "Thunderstrike", faction = "Alliance", classFile = "MAGE" },
        requestedBy = "Anna", requestedAt = NOW - 7200, confirmedBy = "Arthas", confirmedAt = NOW - 3600, inBank = 10,
        tabs = { { index = 3, name = "Edelsteine", count = 4 } } }
end
EventHelperSync_GuildBankHandouts = {
    format = "eventhelper-guildbank-handouts", version = 1, generatedAt = NOW - 600,
    banks = { { key = "tbc:thunderstrike:pulse", gameVersion = "tbc", realm = "Thunderstrike", guild = "Pulse",
        faction = "Alliance", scannedAt = NOW - 600, handouts = {
            handout("g1", PYRESTONE, "Pyrestone", 2, "Zibbo"),
            handout("g2", SPINEL, "Crimson Spinel", 7, "Zibbo"),
            handout("g3", LIONSEYE, "Lionseye", 1, "Zibbo"),
            handout("g4", AMETHYST, "Shadowsong Amethyst", 1, "Thrall"),
        } } },
}
WoWMock.guildBank = {
    money = 0, respondAfter = 0.25, withdrawAfter = 0.3, current = 1,
    tabs = {
        { name = "Allgemein", slots = { [5] = { id = LIONSEYE, count = 1 } } },
        { name = "Verbrauch", slots = {} },
        { name = "Edelsteine", slots = { [1] = { id = PYRESTONE, count = 4 }, [2] = { id = SPINEL, count = 7 },
            [3] = { id = AMETHYST, count = 3 } } },
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
local function take(id, all) return EHS:WithdrawHandouts(W.EntriesFor(entry(id), all)) end
local function bags(itemId) return EHS.Mail.BagCounts()[itemId] or 0 end

WoWMock.openGuildBank("tbc")
WoWMock.advance(5)
expect(not EHS:IsGuildBankScanning(), "scanned")
expectEqual(GetCurrentGuildBankTab(), 1, "the bag addon shows tab 1")

-- Shift-click: all of Zibbo - tab 1 (shown) first, then tab 3, then tab 1 again
WoWMock.guildBank.calls = {}
WoWMock.guildBank.switches = {}
WoWMock.prints = {}
expect(take("g1", true), "started")
WoWMock.advance(10)
expect(not EHS:WithdrawingHandout(), "done")
expectEqual(table.concat(WoWMock.guildBank.calls, ","),
    "AutoStoreGuildBankItem,SplitGuildBankItem,AutoStoreGuildBankItem",
    "lionseye whole (tab 1), pyrestone split, spinel whole (tab 3) - each on the current tab")
expectEqual(table.concat(WoWMock.guildBank.switches, ","), "3,1", "tab 3 once, then tab 1 again")
expectEqual(GetCurrentGuildBankTab(), 1, "the shown tab is back")
expectEqual(bags(PYRESTONE), 2, "2 pyrestone")
expectEqual(bags(SPINEL), 7, "7 crimson spinel")
expectEqual(bags(LIONSEYE), 1, "the lionseye")
expect(WoWMock.printed("Aus der Gildenbank genommen: 7x Crimson Spinel"), "chat line")
expectEqual(WoWMock.guildBank.tabs[3].slots[1].count, 2, "2 pyrestone left in tab 3")
expect(WoWMock.guildBank.tabs[3].slots[2] == nil, "the spinel stack left the bank")

-- a single click with tab 2 shown: tab 3 selected, tab 2 back afterwards
WoWMock.guildBank.current = 2
WoWMock.guildBank.calls = {}
WoWMock.guildBank.switches = {}
expect(take("g4"), "started")
WoWMock.advance(5)
expectEqual(table.concat(WoWMock.guildBank.calls, ","), "SplitGuildBankItem", "one split, on tab 3")
expectEqual(table.concat(WoWMock.guildBank.switches, ","), "3,2", "tab 3, then tab 2 again")
expectEqual(bags(AMETHYST), 1, "the amethyst")

-- the log tells the story: switch (from tab 2), act on tab 3, done, restore
local log = EventHelperSyncDB.withdrawLog
local kinds = {}
for _, e in ipairs(log) do
    if e.kind == "start" then kinds = {} end
    kinds[#kinds + 1] = e.kind
end
expectEqual(table.concat(kinds, ","), "start,tab,act,act,done,done,restore", "the last job in the log")
local switch
for _, e in ipairs(log) do if e.kind == "tab" then switch = e end end
expect(switch.tab == 3 and switch.cur == 2, "log: tab 3 selected while tab 2 was shown")

-- the mock really ignores an action on a tab that is not the current one
WoWMock.guildBank.calls = {}
AutoStoreGuildBankItem(3, 1)
expectEqual(WoWMock.guildBank.calls[1], "AutoStoreGuildBankItem@other", "ignored: tab 3 is not current")
WoWMock.advance(1)
expectEqual(WoWMock.guildBank.tabs[3].slots[1].count, 2, "nothing moved")
