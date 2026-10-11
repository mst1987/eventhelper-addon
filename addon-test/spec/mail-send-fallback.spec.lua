-- GuildBankMail.lua when no witness sees the click (Blizzard's send code runs
-- through nothing the addon can hook): on MAIL_SEND_SUCCESS the prepared mail
-- counts with the recipient and attachments seen last - also when the client
-- emptied the slots while sending. Never for another recipient, never with
-- attachments the player took out before sending, and the chat says why.
local sends = {}
local function send(recipient, subject, body)
    sends[#sends + 1] = { recipient = recipient, subject = subject, body = body }
    if WoWMock.mail.clearOnSend then
        for index in pairs(WoWMock.mail.attachments) do WoWMock.mail.attachments[index] = nil end
        WoWMock.fire("MAIL_SEND_INFO_UPDATE")
    end
end
SendMail = nil
function SendMailFrame_SendMail()
    send(SendMailNameEditBox:GetText(), SendMailSubjectEditBox:GetText(), SendMailBodyEditBox:GetText())
end
SendMailMailButton.HookScript = nil

loadAddon()
WoWMock.login({ lastFlushedAt = 1, settings = { autoOpenHandouts = false } })
local EHS = EventHelperSync
local Mail = EHS.Mail
local NOW = WoWMock.now
local RUBY, MANA = 24027, 22832
WoWMock.items[RUBY] = { name = "Bold Living Ruby" }
WoWMock.items[MANA] = { name = "Super Mana Potion" }

local function handout(id, itemId, name, amount)
    return { id = id, itemId = itemId, name = name, icon = "", quality = 3, amount = amount, purpose = "",
        character = { name = "Zibbo", realm = "Thunderstrike", faction = "Alliance", classFile = "PRIEST" },
        requestedBy = "Anna", requestedAt = NOW - 7200, confirmedBy = "Arthas", confirmedAt = NOW - 3600, inBank = 10, tabs = {} }
end
EventHelperSync_GuildBankHandouts = {
    format = "eventhelper-guildbank-handouts", version = 1, generatedAt = NOW - 600,
    banks = { { key = "tbc:thunderstrike:pulse", gameVersion = "tbc", realm = "Thunderstrike", guild = "Pulse",
        faction = "Alliance", scannedAt = NOW - 600, handouts = {
            handout("f1", RUBY, "Bold Living Ruby", 2),
            handout("f2", MANA, "Super Mana Potion", 1),
        } } },
}
WoWMock.openMailbox()

local hooked = Mail.InstallHooks()
expect(not hooked.SendMail and not hooked.CMail and not hooked.button, "no witness on this client")
expect(hooked.recipient, "only the recipient box")

local function prepare()
    EHS:PrepareMail(EHS:GetMailRows()[1])
    WoWMock.advance(10)
    expectEqual(EHS:PreparedMail().mode, "ready", "prepared")
end

-- the player changes the recipient: nothing ticked, the chat says why
WoWMock.setBags({ [0] = { [1] = { RUBY, 2 } } })
prepare()
SendMailNameEditBox:SetText("Somebody")
WoWMock.prints = {}
WoWMock.clickSend()
expectEqual(#sends, 1, "sent")
WoWMock.mailSent()
expectEqual(EHS:IsHandedOut("f1"), nil, "another recipient: nothing ticked")
expect(WoWMock.printed("Post ging an Somebody statt an Zibbo - nichts abgehakt."), "says why")

-- the player took the attachment out a while before sending
WoWMock.setBags({ [0] = { [1] = { RUBY, 2 } } })
prepare()
ClickSendMailItemButton(1, true)
WoWMock.advance(20)
WoWMock.prints = {}
WoWMock.clickSend()
WoWMock.mailSent()
expectEqual(EHS:IsHandedOut("f1"), nil, "taken out before sending: nothing ticked")
expect(WoWMock.printed("aber die Anhänge passten zu keinem vorbereiteten Posten - nichts abgehakt."), "says why")

-- the prepared mail goes out as it is: ticked from what was seen last
WoWMock.setBags({ [0] = { [1] = { RUBY, 2 } } })
prepare()
WoWMock.advance(20)
WoWMock.prints = {}
WoWMock.clickSend()
WoWMock.mailSent()
local mark = EHS:IsHandedOut("f1")
expect(mark and mark.via == "mail", "ticked without any witness")
expect(WoWMock.printed("Post an Zibbo gesendet: 1 Posten abgehakt."), "sent line")
expect(WoWMock.printed("Der Server erfährt es erst nach /reload"), "upload hint")

-- a client that empties the slots while sending
WoWMock.setBags({ [0] = { [2] = { MANA, 1 } } })
prepare()
WoWMock.advance(20)
WoWMock.mail.clearOnSend = true
WoWMock.clickSend()
WoWMock.advance(0.5)
WoWMock.mailSent()
WoWMock.mail.clearOnSend = false
expect(EHS:IsHandedOut("f2"), "emptied by the send: the last full attachments count")

-- afterwards an unrelated MAIL_SEND_SUCCESS says and ticks nothing
WoWMock.prints = {}
WoWMock.fire("MAIL_SEND_SUCCESS")
expectEqual(#WoWMock.prints, 0, "quiet")
