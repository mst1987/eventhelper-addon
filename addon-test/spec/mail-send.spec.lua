-- GuildBankMail.lua: seeing the player send (1.14.1). On a client like TBC
-- Anniversary all witnesses are there - the Send button (PreClick, OnClick),
-- the global SendMail and the recipient box. One send seen three times ticks
-- once; a second MAIL_SEND_SUCCESS adds nothing; a client that empties the
-- attachment slots while sending still ticks (PreClick saw them). Nothing is
-- ticked silently: an unprepared mail to somebody with open handouts, a mail
-- whose attachments match nothing - the chat says why. An unrelated mail stays
-- quiet. After ticking the chat says the server learns it after /reload.
loadAddon()
WoWMock.login({ lastFlushedAt = 1, settings = { autoOpenHandouts = false } })
local EHS = EventHelperSync
local Mail = EHS.Mail
local NOW = WoWMock.now
local RUBY, MANA = 24027, 22832
WoWMock.items[RUBY] = { name = "Bold Living Ruby" }
WoWMock.items[MANA] = { name = "Super Mana Potion" }

local function handout(id, itemId, name, amount, who)
    return { id = id, itemId = itemId, name = name, icon = "", quality = 3, amount = amount, purpose = "",
        character = { name = who, realm = "Thunderstrike", faction = "Alliance", classFile = "PRIEST" },
        requestedBy = "Anna", requestedAt = NOW - 7200, confirmedBy = "Arthas", confirmedAt = NOW - 3600, inBank = 10, tabs = {} }
end
EventHelperSync_GuildBankHandouts = {
    format = "eventhelper-guildbank-handouts", version = 1, generatedAt = NOW - 600,
    banks = { { key = "tbc:thunderstrike:pulse", gameVersion = "tbc", realm = "Thunderstrike", guild = "Pulse",
        faction = "Alliance", scannedAt = NOW - 600, handouts = {
            handout("z1", RUBY, "Bold Living Ruby", 2, "Zibbo"),
            handout("z2", MANA, "Super Mana Potion", 3, "Zibbo"),
            handout("t1", MANA, "Super Mana Potion", 1, "Thrall"),
        } } },
}

local function group(name)
    for _, g in ipairs(EHS:GetMailRows()) do
        if g.recipient == name then return g end
    end
    return nil
end
local function count(text)
    local n = 0
    for _, line in ipairs(WoWMock.prints) do
        if line:find(text, 1, true) then n = n + 1 end
    end
    return n
end

local hooked = Mail.InstallHooks()
expect(hooked.SendMail, "SendMail hooked")
expect(hooked.button, "Send button hooked")
expect(hooked.recipient, "recipient box hooked")
expect(not hooked.CMail, "no C_Mail.SendMail on this client")
Mail.InstallHooks()
expectEqual(#SendMailMailButton.hooks.PreClick, 1, "hooks only once")

-- One send, three witnesses, one tick ----------------------------------------------------------

WoWMock.setBags({ [0] = { [1] = { RUBY, 2 }, [2] = { MANA, 3 }, [3] = { MANA, 1 } } })
WoWMock.openMailbox()
EHS:PrepareMail(group("Zibbo"))
WoWMock.advance(10)
expectEqual(EHS:PreparedMail().mode, "ready", "prepared")
WoWMock.prints = {}
WoWMock.clickSend()
expectEqual(#WoWMock.mail.sendCalls, 1, "one SendMail")
WoWMock.mailSent()
local mark = EHS:IsHandedOut("z1")
expect(mark and mark.via == "mail", "ruby ticked")
expect(EHS:IsHandedOut("z2"), "potions ticked")
local at = mark.at
expectEqual(count("Post an Zibbo gesendet: 2 Posten abgehakt."), 1, "one line, not three")
expect(WoWMock.printed("Der Server erfährt es erst nach /reload"), "upload hint")
expectEqual(EHS:HandoutsUnsavedCount(), 2, "two ticks not on disk")

WoWMock.advance(5)
WoWMock.prints = {}
WoWMock.fire("MAIL_SEND_SUCCESS")
expectEqual(#WoWMock.prints, 0, "a second MAIL_SEND_SUCCESS says nothing")
expectEqual(EHS:IsHandedOut("z1").at, at, "and ticks nothing again")

-- A client that empties the slots while sending ------------------------------------------------

EHS:UnmarkHandedOut({ "z1", "z2" })
WoWMock.setBags({ [0] = { [1] = { RUBY, 2 }, [2] = { MANA, 3 }, [3] = { MANA, 1 } } })
EHS:PrepareMail(group("Zibbo"))
WoWMock.advance(10)
WoWMock.mail.clearOnSend = true
WoWMock.prints = {}
WoWMock.clickSend()
local _, left = Mail.SendItems()
expectEqual(left, 0, "slots empty after SendMail")
WoWMock.mailSent()
WoWMock.mail.clearOnSend = false
expect(EHS:IsHandedOut("z1") and EHS:IsHandedOut("z2"), "ticked from what PreClick saw")
expect(WoWMock.printed("Post an Zibbo gesendet: 2 Posten abgehakt."), "sent line")

-- No silent paths -------------------------------------------------------------------------------

-- a mail to somebody with open handouts, without "Post"
WoWMock.prints = {}
SendMailNameEditBox:SetText("Thrall")
SendMailSubjectEditBox:SetText("Hi")
WoWMock.playerAttach(1, 0, 3)
WoWMock.clickSend()
WoWMock.mailSent()
expectEqual(EHS:IsHandedOut("t1"), nil, "not prepared: nothing ticked")
expect(WoWMock.printed("Post an Thrall gesendet, aber keine vorbereitete Post erkannt - nichts abgehakt."),
    "says why")

-- an unrelated mail stays quiet
WoWMock.prints = {}
SendMailNameEditBox:SetText("Somebody")
SendMailSubjectEditBox:SetText("Hallo")
WoWMock.clickSend()
WoWMock.mailSent()
expectEqual(#WoWMock.prints, 0, "no word about somebody without handouts")

-- prepared, but the player takes the attachment out again
WoWMock.setBags({ [0] = { [3] = { MANA, 1 } } })
EHS:PrepareMail(group("Thrall"))
WoWMock.advance(10)
expectEqual(EHS:PreparedMail().mode, "ready", "Thrall prepared")
ClickSendMailItemButton(1, true)
WoWMock.prints = {}
WoWMock.clickSend()
WoWMock.mailSent()
expectEqual(EHS:IsHandedOut("t1"), nil, "nothing attached: nothing ticked")
expect(WoWMock.printed("Post an Thrall gesendet, aber die Anhänge passten zu keinem vorbereiteten Posten - nichts abgehakt."),
    "says why")
expectEqual(EHS:PreparedMail(), nil, "the prepared mail is gone with the send")

-- MAIL_FAILED: nothing, and says so
EHS:PrepareMail(group("Thrall"))
WoWMock.advance(10)
WoWMock.prints = {}
WoWMock.clickSend()
WoWMock.fire("MAIL_FAILED")
expect(WoWMock.printed("Post nicht gesendet - nichts abgehakt."), "failure line")
expectEqual(EHS:IsHandedOut("t1"), nil, "nothing ticked on failure")
expectEqual(WoWMock.mail.addonSendCalls, 0, "never SendMail from the addon")

-- Guild bank module off (Modules.lua): the hooks stay, but nothing is noted,
-- ticked or said
EHS.db.modules = { loot = true, council = true, guildbank = true }
WoWMock.setBags({ [0] = { [3] = { MANA, 1 } } })
EHS:PrepareMail(group("Thrall"))
WoWMock.advance(10)
expectEqual(EHS:PreparedMail().mode, "ready", "prepared with the module on")
EHS.db.modules.guildbank = false
WoWMock.prints = {}
WoWMock.clickSend()
WoWMock.mailSent()
expectEqual(EHS:IsHandedOut("t1"), nil, "module off: nothing ticked")
expectEqual(#WoWMock.prints, 0, "module off: no word")
SendMailNameEditBox:SetText("Thrall")
SendMailSubjectEditBox:SetText("Hi")
WoWMock.clickSend()
WoWMock.mailSent()
expectEqual(#WoWMock.prints, 0, "module off: no hint for an unprepared mail either")
EHS.db.modules.guildbank = true
