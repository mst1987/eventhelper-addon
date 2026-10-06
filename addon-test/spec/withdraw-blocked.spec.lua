-- GuildBankWithdraw.lua on WoW Forever when the client answers the guild
-- bank calls with ADDON_ACTION_BLOCKED for this addon: stop at the first
-- call, clear the cursor, list the slot in chat (Latin-1) and go straight to
-- the list on the next click.
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
WoWMock.guildBank.block = "event"
WoWMock.guildBank.calls = {}
WoWMock.prints = {}
expect(take("f1"), "started")
WoWMock.advance(5)
expect(EHS:GuildBankWithdrawBlocked(), "ADDON_ACTION_BLOCKED: blocked")
expectEqual(#WoWMock.guildBank.calls, 1, "stopped at the first call")
expectEqual(WoWMock.guildBank.calls[1], "SplitGuildBankItem", "the split")
expect(WoWMock.printed("Entnehmen aus der Gildenbank ist auf diesem Client gesperrt."), "blocked line")
expect(WoWMock.printed("  Tab 1 Platz 3: 2x Bold Living Ruby (von 10, Shift-Klick teilt den Stapel)"), "slot line")
expect(WoWMock.cursor == nil, "cursor clean")

WoWMock.guildBank.block = nil
WoWMock.prints = {}
expect(take("f3"), "started")
WoWMock.advance(5)
expectEqual(#WoWMock.guildBank.calls, 1, "no call once blocked")
expect(WoWMock.printed("  Tab 1 Platz 4: 5x Super Healing Potion"), "the slot straight away")
