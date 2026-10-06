-- GuildBankMail.lua (#18) on the TBC client: texts (Latin-1, recipient,
-- subject, body), bag counting with both bag APIs, the shared bag stock,
-- planning (whole vs split, 12 attachments, rest), the mailbox events, the
-- rows' states, preparing a mail step by step with a slow client, ticking off
-- only on MAIL_SEND_SUCCESS and only what was attached, nothing on MAIL_FAILED
-- or another recipient, never SendMail from the addon, combat, timeouts and
-- the fallback when the client raises on the item calls.
loadAddon()
WoWMock.login({ lastFlushedAt = 1, settings = { autoOpenHandouts = false } })
local EHS = EventHelperSync
local Mail = EHS.Mail
local NOW = WoWMock.now

local function plain(text)
    return (tostring(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

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

-- Texts ---------------------------------------------------------------------------------------

-- "Gruul – „Mag“ …" and an arrow and an emoji, written as UTF-8 bytes
local fancy = "Gruul \226\128\147 \226\128\158Mag\226\128\156 \226\128\166 \226\134\146 \240\159\144\137"
expectEqual(Mail.Latin1(fancy), 'Gruul - "Mag" ... -> ?', "typographic characters made Latin-1")
expectEqual(Mail.Latin1("Naphf\195\159"), "Naphf\195\159", "Latin-1 umlauts stay")
expectEqual(Mail.Latin1("a|cffff0000b\nc"), "a/cffff0000b c", "escape codes and line breaks defused")
expectEqual(Mail.Latin1("\255\254x"), "??x", "broken UTF-8")
expectEqual(Mail.Latin1(nil), "", "nil")

expectEqual(Mail.RecipientName({ recipient = "Thrall", recipientRealm = "Thunderstrike" }), "Thrall", "same realm: name only")
expectEqual(Mail.RecipientName({ recipient = "Thrall", recipientRealm = "" }), "Thrall", "no realm: name only")
expectEqual(Mail.RecipientName({ recipient = "Jaina", recipientRealm = "Living Flame" }), "Jaina-LivingFlame",
    "other realm: Name-Realm without blanks")
expectEqual(Mail.RecipientName({ recipient = "Jaina", recipientRealm = "Azjol-Nerub" }), "Jaina-AzjolNerub", "realm dash")
expectEqual(Mail.RecipientKey("thrall-Thunderstrike"), "thrall", "own realm dropped for comparing")
expectEqual(Mail.RecipientKey("Jaina-LivingFlame"), "jaina-livingflame", "other realm kept")
expectEqual(Mail.Subject(2), "Gildenbank: 2 Posten", "subject")

local body = Mail.Body({
    { amount = 2, name = "Bold Living Ruby", purpose = fancy },
    { amount = 3, name = "Super Mana Potion", purpose = "" },
})
expectEqual(body, 'Gildenbank-Ausgabe (EventHelper)\n2x Bold Living Ruby - Gruul - "Mag" ... -> ?\n3x Super Mana Potion\nViel Erfolg!',
    "body: one line per handout with its purpose")
expect(latin1Only(body), "body Latin-1")
local many = {}
for i = 1, 30 do many[i] = { amount = 1, name = "A rather long item name number " .. i, purpose = "for the raid tonight" } end
local long = Mail.Body(many)
expect(#long <= Mail.MAX_BODY, "body fits the send frame: %d", #long)
expect(long:find("\n%+%d+ weitere\nViel Erfolg!$"), "the rest as +N weitere:\n" .. long)

expectEqual(Mail.SlotLabel(0, 3), "Rucksack Platz 3", "backpack")
expectEqual(Mail.SlotLabel(2, 5), "Tasche 2 Platz 5", "bag")

-- Shared bag stock in list order
local groups = {
    { entries = { { itemId = 1, amount = 2 }, { itemId = 2, amount = 1 } } },
    { entries = { { itemId = 1, amount = 2 } } },
    { entries = { { itemId = 3, amount = 1 } } },
}
Mail.CheckBags(groups, { [1] = 3, [2] = 5 })
expectEqual(groups[1].missing, 0, "the first gets what it needs")
expectEqual(groups[2].missing, 1, "the second only what is left")
expectEqual(groups[2].entries[1].bagMissing, 1, "per entry")
expectEqual(groups[3].missing, 1, "not in the bags at all")

-- Planning --------------------------------------------------------------------------------------

local function stack(bag, slot, itemId, count) return { bag = bag, slot = slot, itemId = itemId, count = count } end
local plan = Mail.Plan({ { id = "e1", itemId = 7, amount = 5 } },
    { stack(0, 1, 7, 3), stack(0, 2, 7, 20), stack(0, 3, 7, 2) }, { { bag = 1, slot = 1 } })
expectEqual(#plan.steps, 2, "3 + 2 whole rather than splitting the 20")
expectEqual(plan.steps[1].kind .. plan.steps[1].slot .. "/" .. plan.steps[1].count, "whole1/3", "largest fitting first")
expectEqual(plan.steps[2].kind .. plan.steps[2].slot .. "/" .. plan.steps[2].count, "whole3/2", "then the rest")

plan = Mail.Plan({ { id = "e1", itemId = 7, amount = 4 } }, { stack(0, 1, 7, 20), stack(0, 2, 7, 6) }, { { bag = 1, slot = 1 } })
expectEqual(#plan.steps, 1, "one split")
expect(plan.steps[1].kind == "split" and plan.steps[1].slot == 2 and plan.steps[1].count == 4, "split off the smallest large enough")
expect(plan.steps[1].target and plan.steps[1].target.bag == 1, "into the free slot")

plan = Mail.Plan({ { id = "e1", itemId = 7, amount = 4 }, { id = "e2", itemId = 7, amount = 4 } }, { stack(0, 1, 7, 6) }, {})
expectEqual(#plan.entries, 1, "6 are enough for one of two")
expectEqual(plan.missing[1].id, "e2", "the second is missing")
expect(plan.steps[1].kind == "split" and not plan.steps[1].target, "no free slot: split straight into the mail")

plan = Mail.Plan({ { id = "e1", itemId = 7, amount = 6 } }, { stack(0, 1, 7, 6) }, {})
expectEqual(plan.steps[1].kind, "whole", "exact stack whole")
plan = Mail.Plan({ { id = "e1", itemId = 7, amount = 1 } }, { { bag = 0, slot = 1, itemId = 7, count = 5, bound = true } }, {})
expectEqual(#plan.missing, 1, "bound items cannot be mailed")

local thirteen, stacks13 = {}, {}
for i = 1, 13 do
    thirteen[i] = { id = "m" .. i, itemId = 30000 + i, amount = 1 }
    stacks13[i] = stack(2, i, 30000 + i, 1)
end
plan = Mail.Plan(thirteen, stacks13, {}, 12)
expectEqual(#plan.steps, 12, "at most 12 attachments")
expectEqual(#plan.entries, 12, "12 handouts in this mail")
expectEqual(#plan.rest, 1, "one for the next mail")
expectEqual(plan.rest[1].id, "m13", "the last one waits")

expectEqual(table.concat(Mail.Covered({ { id = "a", itemId = 1, amount = 2 }, { id = "b", itemId = 1, amount = 2 },
    { id = "c", itemId = 2, amount = 1 } }, { [1] = 3, [2] = 1 }), ","), "a,c", "covered: only full amounts")

-- The data and the bags ----------------------------------------------------------------------------

local RUBY, MANA, FLASK, DAWN = 24027, 22832, 13512, 24048
WoWMock.items[RUBY] = { name = "Bold Living Ruby" }
WoWMock.items[MANA] = { name = "Super Mana Potion" }
WoWMock.items[FLASK] = { name = "Flask of Supreme Power" }

local function character(name, realm, faction, classFile)
    return { name = name, realm = realm, faction = faction, classFile = classFile }
end
local function handout(id, itemId, name, amount, who, over)
    local h = {
        id = id, itemId = itemId, name = name, icon = "", quality = 1, amount = amount, purpose = "", character = who,
        requestedBy = "Anna", requestedAt = NOW - 7200, confirmedBy = "Arthas", confirmedAt = NOW - 3600, inBank = 10, tabs = {},
    }
    for k, v in pairs(over or {}) do h[k] = v end
    return h
end
local thrall = character("Thrall", "Thunderstrike", "Alliance", "SHAMAN")
local list = {
    handout("t1", RUBY, "Bold Living Ruby", 2, thrall, { purpose = fancy, quality = 3 }),
    handout("t2", MANA, "Super Mana Potion", 3, thrall, { confirmedAt = NOW - 3500 }),
    handout("j1", FLASK, "Flask of Supreme Power", 5, character("Jaina", "Living Flame", "Alliance", "MAGE")),
    handout("u1", DAWN, "Smooth Dawnstone", 2, character("Uther", "Thunderstrike", "Alliance", "PALADIN")),
    handout("a1", 99999, "Something", 1, nil, { requestedBy = "Anna" }),
    handout("g1", 99998, "Horde Thing", 1, character("Garrosh", "Thunderstrike", "Horde", "WARRIOR")),
}
for i = 1, 13 do
    list[#list + 1] = handout("v" .. i, 30000 + i, "Gem " .. i, 1, character("Valeera", "Thunderstrike", "Alliance", "ROGUE"),
        { confirmedAt = NOW - 3000 + i })
end
EventHelperSync_GuildBankHandouts = {
    format = "eventhelper-guildbank-handouts", version = 1, generatedAt = NOW - 600,
    banks = { { key = "tbc:thunderstrike:pulse", gameVersion = "tbc", realm = "Thunderstrike", guild = "Pulse",
        faction = "Alliance", scannedAt = NOW - 600, handouts = list } },
}

local function fillBags(withBound)
    local gems = {}
    for i = 1, 13 do gems[i] = { 30000 + i, 1 } end
    WoWMock.setBags({
        [0] = { [1] = { RUBY, 5 }, [2] = { MANA, 3 } },
        [1] = { [1] = { FLASK, 3 }, [2] = { FLASK, 2 }, [3] = { DAWN, 1 }, [4] = withBound and { RUBY, 4, bound = true } or nil },
        [2] = gems,
    })
end
fillBags(true)

-- both bag APIs count the same
local counts = Mail.BagCounts()
expectEqual(counts[RUBY], 9, "old globals: ruby (they cannot tell a bound stack)")
expectEqual(counts[FLASK], 5, "two stacks of flasks")
local stacksOld, freeOld = Mail.BagStacks()
WoWMock.useBagApi("c_container")
expect(C_Container and not GetContainerItemInfo, "C_Container only now")
counts = Mail.BagCounts()
expectEqual(counts[RUBY], 5, "C_Container: ruby")
expectEqual(counts[FLASK], 5, "C_Container: flasks")
local stacksNew, freeNew = Mail.BagStacks()
expectEqual(#stacksNew, #stacksOld, "same stacks")
expectEqual(#freeNew, #freeOld, "same free slots")
expectEqual(#freeNew, 5 * 16 - #stacksNew, "every empty slot of plain bags is free")
expect(stacksNew[#stacksNew - 13].bound, "bound flag from C_Container")
WoWMock.useBagApi("globals")
fillBags()

-- The mailbox ----------------------------------------------------------------------------------------

expect(WoWMock.registered("MAIL_SHOW") and WoWMock.registered("MAIL_SEND_SUCCESS"), "mail events registered")
expect(not EHS:IsMailboxOpen(), "closed at first")
WoWMock.openMailbox()
expect(EHS:IsMailboxOpen(), "MAIL_SHOW opens")
WoWMock.closeMailbox()
expect(not EHS:IsMailboxOpen(), "MAIL_CLOSED closes")
WoWMock.closeMailbox()
expect(not EHS:IsMailboxOpen(), "a second MAIL_CLOSED is harmless")
WoWMock.openMailbox("retail")
expect(EHS:IsMailboxOpen(), "PLAYER_INTERACTION_MANAGER_FRAME_SHOW with MailInfo opens")
WoWMock.fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", Enum.PlayerInteractionType.GuildBanker)
expect(EHS:IsMailboxOpen(), "another interaction does not close it")
WoWMock.closeMailbox("retail")
expect(not EHS:IsMailboxOpen(), "closed again")

expectEqual(select(2, EHS:PrepareMail({ entries = {} })), "closed", "nothing without the mailbox")
WoWMock.openMailbox()

local function rows()
    local out = {}
    for _, group in ipairs(EHS:GetMailRows()) do out[group.recipient] = group end
    return out
end
local r = rows()
expectEqual(r.Thrall.state, "bags", "Thrall: in the bags")
expectEqual(#r.Thrall.entries, 2, "two handouts for Thrall")
expectEqual(r.Jaina.state, "bags", "Jaina: two stacks of flasks")
expectEqual(r.Uther.state, "missing", "Uther: one dawnstone short")
expectEqual(r.Uther.missing, 1, "fehlt 1")
expectEqual(r.Anna.state, "nochar", "no character")
expectEqual(r.Garrosh.state, "faction", "other faction")
expectEqual(r.Garrosh.otherFaction, "Horde", "which one")
expectEqual(r.Valeera.state, "bags", "Valeera: 13 gems")

-- Preparing a mail on a slow client --------------------------------------------------------------------

WoWMock.mail.attachAfter = 0.3
WoWMock.mail.unlockAfter = 0.3
WoWMock.prints = {}
local ok, reason = EHS:PrepareMail(r.Garrosh)
expect(not ok and reason == "faction", "no mail to the other faction")
ok, reason = EHS:PrepareMail(r.Anna)
expect(not ok and reason == "nochar", "no mail without character")
WoWMock.inCombat = true
ok, reason = EHS:PrepareMail(r.Thrall)
expect(not ok and reason == "combat", "not in combat")
expectEqual(SendMailNameEditBox:GetText(), "", "nothing filled in combat")
expect(WoWMock.printed("Nicht im Kampf"), "combat hint")
WoWMock.inCombat = false

ok = EHS:PrepareMail(r.Thrall)
expect(ok, "Thrall prepared")
expectEqual(WoWMock.mail.tab, 2, "send tab")
expectEqual(SendMailNameEditBox:GetText(), "Thrall", "recipient")
expectEqual(SendMailSubjectEditBox:GetText(), "Gildenbank: 2 Posten", "subject")
expectEqual(SendMailBodyEditBox:GetText(),
    'Gildenbank-Ausgabe (EventHelper)\n2x Bold Living Ruby - Gruul - "Mag" ... -> ?\n3x Super Mana Potion\nViel Erfolg!', "body")
expectEqual(EHS:PreparedMail().mode, "attaching", "attaching")
expectEqual(rows().Thrall.state, "busy", "row busy while attaching")
WoWMock.advance(10)
local prepared = EHS:PreparedMail()
expectEqual(prepared.mode, "ready", "all attached")
local a1, a2 = WoWMock.mail.attachments[1], WoWMock.mail.attachments[2]
expect(a1 and a1.id == RUBY and a1.count == 2, "ruby: 2 split off the 5")
expect(a1.bag == 0 and a1.slot == 3, "split into the first free slot, attached from there")
expectEqual(WoWMock.bags[0].slots[1].count, 3, "3 rubies left in the source stack")
expect(a2 and a2.id == MANA and a2.count == 3 and a2.slot == 2, "mana: the whole stack")
expectEqual(WoWMock.mail.attachments[3], nil, "nothing else")
expectEqual(WoWMock.cursor, nil, "cursor empty")
expect(WoWMock.printed("Post an Thrall vorbereitet: 2 Posten, 2 Anhänge (Porto 60 Kupfer). Jetzt nur noch Senden klicken."),
    "ready line")
expectEqual(rows().Thrall.state, "prepared", "row prepared")
expectEqual(WoWMock.mail.addonSendCalls, 0, "the addon never sends")

-- the player sends, the server confirms
WoWMock.clickSend()
expectEqual(#WoWMock.mail.sendCalls, 1, "the player's click")
expectEqual(EHS:IsHandedOut("t1"), nil, "nothing ticked before MAIL_SEND_SUCCESS")
WoWMock.mailSent()
local mark = EHS:IsHandedOut("t1")
expect(mark and mark.via == "mail" and mark.by == "Gemli-Thunderstrike" and mark.at == time(), "ticked off via mail")
expect(EHS:IsHandedOut("t2"), "both")
expect(WoWMock.printed("Post an Thrall gesendet: 2 Posten abgehakt."), "sent line")
expectEqual(EHS:PreparedMail(), nil, "nothing prepared any more")
expectEqual(rows().Thrall, nil, "Thrall is done")
expectEqual(WoWMock.mail.addonSendCalls, 0, "still never SendMail from the addon")

-- Another realm, C_Container; the player changes the recipient --------------------------------------------

WoWMock.useBagApi("c_container")
WoWMock.prints = {}
EHS:PrepareMail(rows().Jaina)
WoWMock.advance(10)
expectEqual(SendMailNameEditBox:GetText(), "Jaina-LivingFlame", "Name-Realm for another realm")
expectEqual(SendMailSubjectEditBox:GetText(), "Gildenbank: 1 Posten", "one handout")
a1, a2 = WoWMock.mail.attachments[1], WoWMock.mail.attachments[2]
expect(a1 and a1.count == 3 and a2 and a2.count == 2, "two whole flask stacks")
expectEqual(EHS:PreparedMail().mode, "ready", "ready")

-- MAIL_FAILED: nothing; then a successful send
WoWMock.clickSend()
WoWMock.fire("MAIL_FAILED")
expectEqual(EHS:IsHandedOut("j1"), nil, "MAIL_FAILED ticks nothing")
expect(WoWMock.printed("Post nicht gesendet - nichts abgehakt."), "failure line")
expect(EHS:PreparedMail(), "still prepared after a failure")

SendMailNameEditBox:SetText("Somebody")
WoWMock.clickSend()
WoWMock.mailSent()
expectEqual(EHS:IsHandedOut("j1"), nil, "another recipient: nothing ticked")
expect(WoWMock.printed("Post ging an Somebody statt an Jaina-LivingFlame - nichts abgehakt."), "recipient hint")

-- a MAIL_SEND_SUCCESS of some other mail does nothing
WoWMock.fire("MAIL_SEND_SUCCESS")
expectEqual(EHS:IsHandedOut("j1"), nil, "no snapshot, nothing ticked")

-- Only what was attached is ticked off ------------------------------------------------------------------

EHS:UnmarkHandedOut({ "t1", "t2" })
fillBags()
WoWMock.prints = {}
EHS:PrepareMail(rows().Thrall)
WoWMock.advance(10)
expectEqual(EHS:PreparedMail().mode, "ready", "Thrall again")
-- the player takes the potions out again
WoWMock.mail.block = nil
ClickSendMailItemButton(2, true)
WoWMock.clickSend()
WoWMock.mailSent()
expect(EHS:IsHandedOut("t1"), "the ruby went out")
expectEqual(EHS:IsHandedOut("t2"), nil, "the potions did not")
expect(WoWMock.printed("Post an Thrall gesendet: 1 Posten abgehakt."), "one ticked")
expect(WoWMock.printed("1 Posten waren nicht in der Post und bleiben offen."), "the rest stays open")

-- Twelve attachments, the rest in a second mail ---------------------------------------------------------

WoWMock.mail.attachAfter = 0
WoWMock.mail.unlockAfter = 0
WoWMock.prints = {}
EHS:PrepareMail(rows().Valeera)
WoWMock.advance(10)
prepared = EHS:PreparedMail()
expectEqual(#prepared.entries, 12, "12 in the first mail")
expectEqual(#prepared.rest, 1, "one left")
expectEqual(SendMailSubjectEditBox:GetText(), "Gildenbank: 12 Posten", "subject counts this mail")
expect(WoWMock.mail.attachments[12] and not WoWMock.mail.attachments[13], "12 attachments")
expect(WoWMock.printed("Noch 1 Posten für Valeera passen nicht in diesen Brief"), "rest hint")
expect(WoWMock.printed("12 Anhänge (Porto 360 Kupfer)"), "postage")
WoWMock.clickSend()
WoWMock.mailSent()
expect(EHS:IsHandedOut("v12") and not EHS:IsHandedOut("v13"), "12 ticked, the 13th open")
local valeera = rows().Valeera
expect(valeera and #valeera.entries == 1 and valeera.state == "bags", "the row offers Post again for the rest")
EHS:PrepareMail(valeera)
WoWMock.advance(10)
expectEqual(SendMailSubjectEditBox:GetText(), "Gildenbank: 1 Posten", "second mail")
expect(WoWMock.mail.attachments[1] and WoWMock.mail.attachments[1].id == 30013, "the 13th gem")
WoWMock.clickSend()
WoWMock.mailSent()
expectEqual(rows().Valeera, nil, "Valeera done")

-- Preparing again replaces the mail; closing drops it ---------------------------------------------------------

EHS:UnmarkHandedOut({ "t2" })
fillBags()
EHS:PrepareMail(rows().Thrall)
WoWMock.advance(10)
expectEqual(WoWMock.mail.attachments[1].id, MANA, "only the potions are left for Thrall")
WoWMock.mail.calls = {}
EHS:PrepareMail(rows().Thrall)
WoWMock.advance(10)
expectEqual(table.concat(WoWMock.mail.calls, ","), "ClickSendMailItemButton,PickupContainerItem,ClickSendMailItemButton",
    "old attachment taken out first")
expect(WoWMock.mail.attachments[1] and WoWMock.mail.attachments[1].id == MANA and not WoWMock.mail.attachments[2],
    "attached once again, not twice")
WoWMock.closeMailbox()
expectEqual(EHS:PreparedMail(), nil, "closing the mailbox drops the prepared mail")
WoWMock.openMailbox()
WoWMock.mail.attachments = {}
fillBags()

-- A client that never shows the attachment: timeout, by hand ------------------------------------------------

WoWMock.mail.attachAfter = 60
WoWMock.prints = {}
EHS:PrepareMail(rows().Thrall)
WoWMock.advance(10)
expectEqual(EHS:PreparedMail().mode, "manual", "gave up after the timeout")
expect(WoWMock.printed("Anhängen hat nicht geklappt. Bitte selbst in die Post legen:"), "timeout line")
expect(not EHS:MailAttachBlocked(), "a timeout is no block")
WoWMock.advance(60)
WoWMock.closeMailbox()
WoWMock.mail.attachAfter = 0
WoWMock.mail.attachments = {}
fillBags()
WoWMock.openMailbox()

-- The client raises on the item calls: fallback ----------------------------------------------------------------

EHS:UnmarkHandedOut({ "t1" })
WoWMock.mail.block = "error"
WoWMock.prints = {}
ok = EHS:PrepareMail(rows().Thrall)
expect(ok, "still prepared")
expect(EHS:MailAttachBlocked(), "blocked for this session")
expectEqual(EHS:PreparedMail().mode, "manual", "by hand")
expectEqual(SendMailNameEditBox:GetText(), "Thrall", "recipient filled anyway")
expectEqual(SendMailSubjectEditBox:GetText(), "Gildenbank: 2 Posten", "subject filled anyway")
expect(WoWMock.printed("Anhängen ist auf diesem Client gesperrt."), "blocked line")
expect(WoWMock.printed("Rucksack Platz 1: 2x Bold Living Ruby (von 5, Shift-Klick teilt den Stapel)"), "ruby slot")
expect(WoWMock.printed("Rucksack Platz 2: 3x Super Mana Potion"), "mana slot")
expectEqual(rows().Thrall.state, "prepared", "row shows the prepared mail")
expectEqual(WoWMock.cursor, nil, "cursor clean")

-- next time straight to the fallback, no item call at all
WoWMock.mail.block = nil
WoWMock.mail.calls = {}
WoWMock.prints = {}
EHS:PrepareMail(rows().Thrall)
WoWMock.advance(10)
expectEqual(#WoWMock.mail.calls, 0, "no item call once blocked")
expectEqual(EHS:PreparedMail().mode, "manual", "by hand again")
-- the player drags the items in and sends
WoWMock.setBags({ [0] = { [1] = { RUBY, 2 }, [2] = { MANA, 3 } } })
WoWMock.playerAttach(1, 0, 1)
WoWMock.playerAttach(2, 0, 2)
WoWMock.clickSend()
WoWMock.mailSent()
expect(EHS:IsHandedOut("t1") and EHS:IsHandedOut("t2"), "dragged by hand, ticked off all the same")
expectEqual(EHS:IsHandedOut("t1").via, "mail", "via mail")
expectEqual(WoWMock.mail.addonSendCalls, 0, "never SendMail from the addon")
