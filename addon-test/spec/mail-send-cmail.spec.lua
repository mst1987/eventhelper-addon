-- GuildBankMail.lua on a client whose send frame calls C_Mail.SendMail (no
-- global SendMail, a Send button without HookScript): the hook on
-- C_Mail.SendMail alone notes the mail, and what was sent is ticked off.
-- Neither TBC Anniversary nor WoW Forever has C_Mail.SendMail today
-- (MailInfoDocumentation.lua of both), this guards a client that moves it.
SendMail = nil
C_Mail = { calls = {} }
function C_Mail.SendMail(recipient, subject, body)
    table.insert(C_Mail.calls, { recipient = recipient, subject = subject, body = body })
end
function SendMailFrame_SendMail()
    C_Mail.SendMail(SendMailNameEditBox:GetText(), SendMailSubjectEditBox:GetText(), SendMailBodyEditBox:GetText())
end
SendMailMailButton.HookScript = nil

loadAddon()
WoWMock.login({ lastFlushedAt = 1, settings = { autoOpenHandouts = false } })
local EHS = EventHelperSync
local Mail = EHS.Mail
local NOW = WoWMock.now
local RUBY = 24027
WoWMock.items[RUBY] = { name = "Bold Living Ruby" }

EventHelperSync_GuildBankHandouts = {
    format = "eventhelper-guildbank-handouts", version = 1, generatedAt = NOW - 600,
    banks = { { key = "tbc:thunderstrike:pulse", gameVersion = "tbc", realm = "Thunderstrike", guild = "Pulse",
        faction = "Alliance", scannedAt = NOW - 600, handouts = {
            { id = "c1", itemId = RUBY, name = "Bold Living Ruby", icon = "", quality = 3, amount = 2, purpose = "",
              character = { name = "Zibbo", realm = "Thunderstrike", faction = "Alliance", classFile = "PRIEST" },
              requestedBy = "Anna", requestedAt = NOW - 7200, confirmedBy = "Arthas", confirmedAt = NOW - 3600, inBank = 10, tabs = {} },
        } } },
}
WoWMock.setBags({ [0] = { [1] = { RUBY, 2 } } })
WoWMock.openMailbox()

local hooked = Mail.InstallHooks()
expect(hooked.CMail, "C_Mail.SendMail hooked")
expect(not hooked.SendMail, "no global SendMail to hook")
expect(not hooked.button, "a button without HookScript is left alone")

EHS:PrepareMail(EHS:GetMailRows()[1])
WoWMock.advance(10)
expectEqual(EHS:PreparedMail().mode, "ready", "prepared")
WoWMock.prints = {}
WoWMock.clickSend()
expectEqual(#C_Mail.calls, 1, "Blizzard's click went through C_Mail.SendMail")
expectEqual(C_Mail.calls[1].recipient, "Zibbo", "with the recipient")
WoWMock.mailSent()
local mark = EHS:IsHandedOut("c1")
expect(mark and mark.via == "mail", "ticked off via mail")
expect(WoWMock.printed("Post an Zibbo gesendet: 1 Posten abgehakt."), "sent line")
expect(WoWMock.printed("Der Server erfährt es erst nach /reload"), "upload hint")
