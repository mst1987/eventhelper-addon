-- GuildBank.lua on the Forever (Retail based) client: GUILDBANKFRAME_* do not
-- exist there (RegisterEvent raises), the guild bank opens and closes through
-- PLAYER_INTERACTION_MANAGER_FRAME_SHOW/_HIDE with the GuildBanker type, and
-- the client project is "forever".
WoWMock.unknownEvents = { GUILDBANKFRAME_OPENED = true, GUILDBANKFRAME_CLOSED = true }
WOW_PROJECT_ID = 1
WoWMock.build = { version = "12.0.1", build = "66000", date = "Sep 1 2026", interface = 16001 }
loadAddon()
WoWMock.login({})
local EHS = EventHelperSync

expect(not WoWMock.registered("GUILDBANKFRAME_OPENED"), "unknown event skipped without an error")
expect(WoWMock.registered("PLAYER_INTERACTION_MANAGER_FRAME_SHOW"), "interaction manager registered")
expect(WoWMock.registered("GUILDBANKBAGSLOTS_CHANGED"), "slot event registered")

WoWMock.guildBank = {
    money = 50000,
    respondAfter = 0.25,
    tabs = { { name = "Allgemein", slots = { [10] = { id = 210796, count = 200 } } } },
}

WoWMock.fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 5)
expect(not EHS:IsGuildBankOpen(), "another interaction type is ignored")

WoWMock.openGuildBank("retail")
expect(EHS:IsGuildBankOpen(), "open via the interaction manager")
WoWMock.advance(1)
local scan = EventHelperSyncDB.guildBank
expect(scan ~= nil, "scanned")
expectEqual(scan.client.project, "forever", "project from WOW_PROJECT_ID 1")
expectEqual(scan.client.build, "12.0.1", "build")
expectEqual(scan.tabs[1].items[1].itemId, 210796, "item id")
expectEqual(scan.tabs[1].items[1].count, 200, "count")
expect(WoWMock.printed("Gildenbank gescannt: 1 Tabs, 200 Gegenst"), "chat line")

WoWMock.fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", 5)
expect(EHS:IsGuildBankOpen(), "another interaction frame closing leaves the bank open")
WoWMock.closeGuildBank("retail")
expect(not EHS:IsGuildBankOpen(), "closed via the interaction manager")

-- without WOW_PROJECT_ID the interface number decides: 16001 is Forever, 2xxxx TBC
WOW_PROJECT_ID = nil
WoWMock.advance(10)
WoWMock.openGuildBank("retail")
WoWMock.advance(1)
expectEqual(EventHelperSyncDB.guildBank.client.project, "forever", "16001 -> forever")
WoWMock.closeGuildBank("retail")
WoWMock.build.interface = 20505
WoWMock.advance(10)
WoWMock.openGuildBank("retail")
WoWMock.advance(1)
expectEqual(EventHelperSyncDB.guildBank.client.project, "tbc", "20505 -> tbc")
WoWMock.closeGuildBank("retail")
WoWMock.build.interface = 11507
WoWMock.advance(10)
WoWMock.openGuildBank("retail")
WoWMock.advance(1)
expectEqual(EventHelperSyncDB.guildBank.client.project, "classic", "11507 -> classic")

-- every client call is guarded: a missing guild bank API fails no event handler
WoWMock.closeGuildBank("retail")
GetNumGuildBankTabs = nil
WoWMock.openGuildBank("retail")
expect(not EHS:IsGuildBankScanning(), "no tabs, no scan")
WoWMock.closeGuildBank("retail")
GetNumGuildBankTabs = function() return 1 end
GetGuildBankItemLink = function() error("boom") end
WoWMock.advance(10)
WoWMock.openGuildBank("retail")
WoWMock.advance(1)
expectEqual(#EventHelperSyncDB.guildBank.tabs[1].items, 0, "a failing slot call reads as empty")
