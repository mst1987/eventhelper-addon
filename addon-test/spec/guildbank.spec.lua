-- GuildBank.lua on the TBC client: opening via GUILDBANKFRAME_OPENED, the
-- viewable tabs queried one after another (each waiting for
-- GUILDBANKBAGSLOTS_CHANGED), the stored "eventhelper-guildbank" v1 envelope,
-- the chat line, combat refusal, the timeout path and the reload via
-- /ehs upload for a scan alone.
loadAddon()
WoWMock.login({ lastFlushedAt = 1 })
local EHS = EventHelperSync

-- both detection paths are registered on a client that knows them all
for _, event in ipairs({ "GUILDBANKFRAME_OPENED", "GUILDBANKFRAME_CLOSED", "PLAYER_INTERACTION_MANAGER_FRAME_SHOW",
    "PLAYER_INTERACTION_MANAGER_FRAME_HIDE", "GUILDBANKBAGSLOTS_CHANGED" }) do
    expect(WoWMock.registered(event), "registered %s", event)
end

WoWMock.guildBank = {
    money = 123456789,
    respondAfter = 0.25,
    tabs = {
        { name = "Mats", slots = { [1] = { id = 22445, count = 20 }, [5] = { id = 22445, count = 7 }, [98] = { id = 21877, count = 1 } } },
        { name = "Offiziere", viewable = false, slots = { [1] = { id = 30000, count = 1 } } },
        { name = "Pets", slots = { [2] = { pet = 1234 }, [3] = { id = 2589 } } },
    },
}

-- open: nothing readable yet, the first tab is queried at once
expect(not EHS:IsGuildBankOpen(), "closed before")
WoWMock.openGuildBank("tbc")
expect(EHS:IsGuildBankOpen() and EHS:IsGuildBankScanning(), "open and scanning")
expectEqual(#WoWMock.queries, 1, "one query at a time")
expectEqual(WoWMock.queries[1], 1, "tab 1 first")

-- a second open event (clients that know both events fire both) starts no second scan
WoWMock.fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", Enum.PlayerInteractionType.GuildBanker)
expectEqual(#WoWMock.queries, 1, "no second scan")

-- the answer for tab 1 comes, tab 2 is not viewable, tab 3 follows after the gap
WoWMock.advance(0.25)
expectEqual(#WoWMock.queries, 1, "the next query waits for the gap")
WoWMock.advance(0.5)
expectEqual(#WoWMock.queries, 2, "second query")
expectEqual(WoWMock.queries[2], 3, "tab 2 (not viewable) skipped")
expect(EventHelperSyncDB.guildBank == nil, "nothing stored before the last tab")
WoWMock.advance(0.25)
expect(not EHS:IsGuildBankScanning(), "done")

local scan = EventHelperSyncDB.guildBank
expect(scan ~= nil, "scan stored")
expectEqual(scan.format, "eventhelper-guildbank", "format")
expectEqual(scan.version, 1, "version")
expectEqual(scan.scannedAt, WoWMock.now, "scannedAt")
expectEqual(scan.generatedAt, WoWMock.now, "generatedAt")
expectEqual(scan.client.project, "tbc", "client.project")
expectEqual(scan.client.build, "2.5.5", "client.build")
expectEqual(scan.guild.name, "Pulse", "guild.name")
expectEqual(scan.guild.realm, "Thunderstrike", "guild.realm")
expectEqual(scan.guild.faction, "Alliance", "guild.faction")
expectEqual(scan.scannedBy, "Gemli-Thunderstrike", "scannedBy")
expectEqual(scan.money, 123456789, "money in copper")
expectEqual(#scan.tabs, 2, "only viewable tabs")

local mats, pets = scan.tabs[1], scan.tabs[2]
expectEqual(mats.index, 1, "tab index")
expectEqual(mats.name, "Mats", "tab name")
expectEqual(#mats.items, 3, "three stacks")
expect(mats.items[1].itemId == 22445 and mats.items[1].count == 20 and mats.items[1].slot == 1, "first stack")
expect(mats.items[2].itemId == 22445 and mats.items[2].count == 7 and mats.items[2].slot == 5, "same item, own stack")
expect(mats.items[3].itemId == 21877 and mats.items[3].count == 1 and mats.items[3].slot == 98, "last slot read")
expectEqual(pets.index, 3, "tab 3 keeps its index")
expectEqual(#pets.items, 1, "battle pet cage skipped")
expect(pets.items[1].itemId == 2589 and pets.items[1].count == 1 and pets.items[1].slot == 3, "single item")
for _, tab in ipairs(scan.tabs) do
    for key in pairs(tab) do expect(key == "index" or key == "name" or key == "items", "tab field %s", key) end
end

-- one chat line, Latin-1 only (the glyph check covers the literal)
local line = WoWMock.printed("Gildenbank gescannt")
expect(line and line:find("Gildenbank gescannt: 2 Tabs, 29 Gegenst", 1, true), "chat line: %s", tostring(line))

-- the loot export does not wipe the scan, and the scan alone is worth a reload
EHS:Rebuild()
expect(EventHelperSyncDB.guildBank == scan, "Rebuild keeps guildBank")
expect(EHS:GuildBankUnsaved(), "scan newer than the last flush")
expect(EHS:FlushAndReload(), "reload for the scan alone")
expectEqual(WoWMock.reloads, 1, "ReloadUI called")
expect(not EHS:GuildBankUnsaved(), "saved now")
WoWMock.fire("PLAYER_LOGOUT")
expect(EventHelperSyncDB.guildBank == scan, "logout keeps guildBank")

-- /ehs status shows the state of the scan
SlashCmdList.EVENTHELPERSYNC("status")
expect(WoWMock.printed("Gildenbank: Stand"), "status line")

-- close, reopen: a new scan replaces the old one
WoWMock.closeGuildBank("tbc")
expect(not EHS:IsGuildBankOpen(), "closed")
WoWMock.advance(60)
WoWMock.guildBank.tabs[1].slots[5] = nil
WoWMock.queries = {}
WoWMock.openGuildBank("tbc")
WoWMock.advance(5)
expect(EventHelperSyncDB.guildBank ~= scan, "replaced")
expectEqual(#EventHelperSyncDB.guildBank.tabs[1].items, 2, "latest scan only")
expectEqual(EventHelperSyncDB.guildBank.scannedAt, scan.scannedAt + 61, "new scannedAt (60 s + the scan)")

-- closing mid-scan aborts it and keeps the last complete scan
WoWMock.closeGuildBank("tbc")
local before = EventHelperSyncDB.guildBank
WoWMock.openGuildBank("tbc")
WoWMock.advance(0.25)
WoWMock.closeGuildBank("tbc")
expect(not EHS:IsGuildBankScanning(), "aborted")
expect(WoWMock.printed("Scan abgebrochen"), "abort message")
WoWMock.advance(5)
expect(EventHelperSyncDB.guildBank == before, "half a scan is not stored")

-- combat: no scan at all, and a scan that runs into combat stops
WoWMock.inCombat = true
WoWMock.queries = {}
WoWMock.openGuildBank("tbc")
expectEqual(#WoWMock.queries, 0, "no query in combat")
expect(not EHS:IsGuildBankScanning(), "no scan in combat")
expect(WoWMock.printed("Im Kampf wird die Gildenbank nicht gescannt"), "combat message")
WoWMock.closeGuildBank("tbc")
WoWMock.inCombat = false
WoWMock.openGuildBank("tbc")
WoWMock.advance(0.25)
WoWMock.inCombat = true
WoWMock.advance(5)
expect(not EHS:IsGuildBankScanning(), "stopped by combat")
expect(EventHelperSyncDB.guildBank == before, "nothing stored from the interrupted scan")
WoWMock.inCombat = false
WoWMock.closeGuildBank("tbc")

-- timeout: the server never answers; cached tabs are read anyway, the scan does not hang
WoWMock.guildBank.respondAfter = false
WoWMock.guildBank.tabs[3].cached = false
WoWMock.queries = {}
WoWMock.openGuildBank("tbc")
WoWMock.advance(2.5)
expectEqual(#WoWMock.queries, 1, "still waiting for tab 1")
WoWMock.advance(0.5)
WoWMock.advance(0.5)
expectEqual(#WoWMock.queries, 2, "timeout moves on to the next tab")
WoWMock.advance(3)
expect(not EHS:IsGuildBankScanning(), "finished after the timeouts")
local timedOut = EventHelperSyncDB.guildBank
expectEqual(#timedOut.tabs[1].items, 2, "cached tab 1 read after the timeout")
expectEqual(#timedOut.tabs[2].items, 0, "uncached tab 3 stays empty")

-- a late GUILDBANKBAGSLOTS_CHANGED outside a scan changes nothing
WoWMock.fire("GUILDBANKBAGSLOTS_CHANGED")
expect(EventHelperSyncDB.guildBank == timedOut, "late event ignored")

-- other interaction frames (merchant = 5) are not the guild bank
WoWMock.closeGuildBank("tbc")
WoWMock.fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 5)
expect(not EHS:IsGuildBankOpen(), "merchant is no guild bank")
