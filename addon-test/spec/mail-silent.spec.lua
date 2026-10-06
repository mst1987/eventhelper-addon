-- GuildBankMail.lua: an ADDON_ACTION_BLOCKED of another addon does not stop
-- attaching; a client that silently ignores the pickup (cursor stays empty)
-- counts as blocked.
loadAddon()
WoWMock.login({ lastFlushedAt = 1, settings = { autoOpenHandouts = false } })
local EHS = EventHelperSync
local NOW = WoWMock.now
local RUBY = 24027
WoWMock.items[RUBY] = { name = "Bold Living Ruby" }

EventHelperSync_GuildBankHandouts = {
    format = "eventhelper-guildbank-handouts", version = 1, generatedAt = NOW - 600,
    banks = { { key = "tbc:thunderstrike:pulse", gameVersion = "tbc", realm = "Thunderstrike", guild = "Pulse",
        faction = "Alliance", scannedAt = NOW - 600, handouts = {
            { id = "t1", itemId = RUBY, name = "Bold Living Ruby", icon = "", quality = 3, amount = 2, purpose = "",
              character = { name = "Zibbo", realm = "Thunderstrike", faction = "Alliance", classFile = "PRIEST" },
              requestedBy = "Anna", requestedAt = NOW - 7200, confirmedBy = "Arthas", confirmedAt = NOW - 3600, inBank = 10, tabs = {} },
        } } },
}
WoWMock.setBags({ [0] = { [1] = { RUBY, 2 } } })
WoWMock.openMailbox()

WoWMock.mail.attachAfter = 0.3
EHS:PrepareMail(EHS:GetMailRows()[1])
WoWMock.fire("ADDON_ACTION_BLOCKED", "SomeOtherAddon", "CastSpellByName")
WoWMock.advance(10)
expect(not EHS:MailAttachBlocked(), "another addon's block is none of ours")
expectEqual(EHS:PreparedMail().mode, "ready", "attached")
expectEqual(WoWMock.mail.attachments[1].count, 2, "the stack")

-- take it out again and try on a client that ignores the call
ClickSendMailItemButton(1, true)
WoWMock.mail.attachAfter = 0
WoWMock.mail.block = "silent"
WoWMock.prints = {}
EHS:PrepareMail(EHS:GetMailRows()[1])
WoWMock.advance(10)
expect(EHS:MailAttachBlocked(), "empty cursor after the pickup: blocked")
expectEqual(EHS:PreparedMail().mode, "manual", "by hand")
expect(WoWMock.printed("Rucksack Platz 1: 2x Bold Living Ruby"), "slot line")
expectEqual(WoWMock.mail.addonSendCalls, 0, "never SendMail from the addon")
