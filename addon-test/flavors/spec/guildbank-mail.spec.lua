-- The handout window at the mailbox on both clients (#18): opens by itself,
-- one row per recipient with item lines and the bag check, "Post" fills the
-- send frame and attaches (old bag globals on Anniversary, C_Container and
-- MailEditBox on Forever), sending ticks off, combat, other faction, and the
-- fallback with the bag slots outlined in the bag frames of each client.
local EHS = EventHelperSync
local FOREVER = WoWMock.flavor == "forever"
local P = FOREVER and "f" or "t"
WoWMock.guild = "Pulse"

WoWMock.Fire("ADDON_LOADED", "EventHelperSync")
load(__HANDOUTS_FIXTURE)()
WoWMock.Fire("PLAYER_LOGIN")

local RUBY, FLASK, POTION, POWDER = 24027, 13512, 22829, 17020
WoWMock.SetBags({
    [0] = { [1] = { RUBY, 5 }, [2] = { FLASK, 1 }, [3] = { POTION, 1 } },
    [1] = { [1] = { POWDER, 20 } },
})

local function printed(text)
    for i = #WoWMock.prints, 1, -1 do
        if WoWMock.prints[i]:find(text, 1, true) then return true end
    end
    return false
end

-- The mailbox opens the window in the mail mode ----------------------------------------------------

WoWMock.OpenMailbox()
expect(EHS:IsMailboxOpen(), "mailbox open on " .. WoWMock.flavor)
local win = EventHelperSyncGuildBankFrame
expect(win and win:IsShown(), "opens by itself at the mailbox")
expect(win.mailList:IsShown() and not win.list:IsShown(), "mail list instead of the handout list")
expectEqual(win.summary:GetText(), "15 Spieler offen - Gesendetes wird automatisch abgehakt", "line 2")
expect(win.bankOpen:IsShown(), "indicator shown")
expectEqual(win.bankOpen:GetText(), "Briefkasten offen", "indicator text")
for _, button in ipairs(win.viewButtons) do expect(not button:IsShown(), "no Offen/Alle at the mailbox") end

local rows = {}
for _, child in ipairs(WoWMock.frames) do
    if child.__parent == win.mailList and child.__kind == "Button" then rows[#rows + 1] = child end
end
expectEqual(#rows, 7, "7 mail rows")

local anna, naph, raider = rows[1], rows[2], rows[3]
expectEqual(anna.name:GetText(), "|cff999999Anna|r", "no character: grey")
expectEqual(anna.state:GetText(), "kein Charakter", "no character state")
expect(not anna.button:IsShown(), "no button without character")
expectEqual(plain(naph.name:GetText()), "Naphfß", "Naphfß")
expectEqual(naph.state:GetText(), "fehlt 1 in den Taschen", "one potion short (Anna takes none of the stock)")
expectEqual(naph.state.__color[1], 1, "yellow")
expect(not naph.button:IsShown(), "no button when something is missing")
expectEqual(raider.name:GetText(), "|cff40c7ebRaider01|r", "class colour")
expectEqual(plain(raider.lines[1].text:GetText()), "1x Arcane Powder", "item line")
expect(raider.lines[1].icon:IsShown(), "item icon")
expect(not raider.lines[2].text:IsShown(), "one line only")
expectEqual(raider.state:GetText(), "in den Taschen", "in the bags")
expect(raider.button:IsShown(), "button")
expectEqual(raider.button.label:GetText(), "Post", "Post")
expect(not raider.prepBg:IsShown(), "not prepared")
expect(win.thumb:IsShown(), "15 recipients scroll")

-- scroll to Zibbo (the last of 15, one row per notch)
for _ = 1, 10 do WoWMock.Run(win.mailList, "OnMouseWheel", -1) end
local zibbo = rows[7]
expectEqual(zibbo.group.recipient, "Zibbo", "Zibbo at the end")
expectEqual(zibbo.lines[1].text:GetText(), "|cff0070de2x Bold Living Ruby|r", "ruby in quality colour")
expectEqual(plain(zibbo.lines[2].text:GetText()), "1x Flask of Supreme Power", "second line")
expectEqual(zibbo.state:GetText(), "in den Taschen", "all there")
WoWMock.Run(zibbo, "OnEnter")
local tip = WoWMock.TooltipText(GameTooltip)
expect(tip:find("Porto | 60 Kupfer (2 Anhänge à 30)", 1, true), "postage in the tooltip:\n" .. tip)
expect(tip:find('2x Bold Living Ruby | Gruul - "Mag" ...', 1, true), "purpose in the tooltip")

-- Post ----------------------------------------------------------------------------------------------

WoWMock.prints = {}
WoWMock.Click(zibbo.button)
expectEqual(WoWMock.mailTab, 2, "send tab")
expectEqual(SendMailNameEditBox:GetText(), "Zibbo", "recipient")
expectEqual(SendMailSubjectEditBox:GetText(), "Gildenbank: 2 Posten", "subject")
local body = FOREVER and MailEditBox:GetInputText() or SendMailBodyEditBox:GetText()
expectEqual(body, 'Gildenbank-Ausgabe (EventHelper)\n2x Bold Living Ruby - Gruul - "Mag" ...\n1x Flask of Supreme Power\nViel Erfolg!',
    "body (" .. (FOREVER and "MailEditBox" or "SendMailBodyEditBox") .. ")")
local a1, a2 = WoWMock.attachments[1], WoWMock.attachments[2]
expect(a1 and a1.id == RUBY and a1.count == 2, "two rubies split off")
expect(a2 and a2.id == FLASK and a2.count == 1, "the flask")
expectEqual(WoWMock.bags[0].slots[1].count, 3, "three rubies left")
expect(printed("Post an Zibbo vorbereitet: 2 Posten, 2 Anhänge"), "ready line")
expectEqual(zibbo.state:GetText(), "in der Post", "prepared state")
expectEqual(zibbo.state.__color[2], 0.82, "gold")
expectEqual(zibbo.button.label:GetText(), "Vorbereitet", "button Vorbereitet")
expect(zibbo.prepBg:IsShown() and zibbo.prepBar:IsShown(), "gold highlight")
expectEqual(WoWMock.addonSendCalls, 0, "the addon never sends")

WoWMock.SendAndConfirm()
local mark = EHS.db.guildBankDone[P .. "1"]
expect(mark and mark.via == "mail" and mark.by == "Gemli-Thunderstrike", "ruby ticked off via mail")
expect(EHS.db.guildBankDone[P .. "2"], "flask ticked off")
expect(printed("Post an Zibbo gesendet: 2 Posten abgehakt."), "sent line")
expectEqual(win.summary:GetText(), "14 Spieler offen - Gesendetes wird automatisch abgehakt", "one recipient less")
expectEqual(WoWMock.addonSendCalls, 0, "still never SendMail from the addon")

-- Combat and the other faction ------------------------------------------------------------------------

for _ = 1, 10 do WoWMock.Run(win.mailList, "OnMouseWheel", 1) end
raider = rows[3]
expectEqual(raider.group.recipient, "Raider01", "back at the top")
local inCombat = InCombatLockdown
InCombatLockdown = function() return true end
WoWMock.prints = {}
WoWMock.Click(raider.button)
expect(printed("Nicht im Kampf"), "refused in combat")
expect(not WoWMock.attachments[1], "nothing attached in combat")
InCombatLockdown = inCombat

local faction = UnitFactionGroup
UnitFactionGroup = function() return "Horde" end
EHS:RefreshGuildBankUI()
expectEqual(raider.state:GetText(), "andere Fraktion", "other faction")
expect(not raider.button:IsShown(), "no button for the other faction")
WoWMock.Run(raider, "OnEnter")
expect(WoWMock.TooltipText(GameTooltip):find("Andere Fraktion (Alliance): Post geht nicht.", 1, true), "faction tooltip")
UnitFactionGroup = faction
EHS:RefreshGuildBankUI()
expectEqual(raider.state:GetText(), "in den Taschen", "same faction again")

-- The client forbids the item calls: fallback with outlined bag slots ----------------------------------------

WoWMock.mailBlock = true
WoWMock.ShowBags(true)
WoWMock.prints = {}
WoWMock.Click(raider.button)
expect(EHS:MailAttachBlocked(), "blocked")
expectEqual(SendMailNameEditBox:GetText(), "Raider01", "recipient filled anyway")
expect(printed("Tasche 1 Platz 1: 1x Arcane Powder (von 20, Shift-Klick teilt den Stapel)"), "slot line")
local highlight = EHS.Mail.Highlights()[1]
expect(highlight and highlight:IsShown(), "slot outlined")
expect(highlight.button == WoWMock.itemButtons["1:1"], "on the button of bag 1, slot 1 ("
    .. (FOREVER and "combined bags" or "ContainerFrame2") .. ")")
expectEqual(raider.state:GetText(), "selbst anhängen", "row: attach by hand")
expectEqual(raider.button.label:GetText(), "Vorbereitet", "prepared")

-- Closing the mailbox -------------------------------------------------------------------------------------------

WoWMock.CloseMailbox()
expect(not EHS:IsMailboxOpen(), "closed")
expect(not highlight:IsShown(), "outline gone")
expect(not win:IsShown(), "opened by the mailbox: closes with it")

SlashCmdList.EVENTHELPERBANK("")
expect(win:IsShown() and win.list:IsShown() and not win.mailList:IsShown(), "by hand: the handout list again")
for _, button in ipairs(win.viewButtons) do expect(button:IsShown(), "Offen/Alle back") end
expect(not win.bankOpen:IsShown(), "no indicator")
WoWMock.OpenMailbox()
expect(win.mailList:IsShown(), "switches to the mail mode while open")
WoWMock.CloseMailbox()
expect(win:IsShown() and win.list:IsShown(), "opened by hand: stays, back to the list")
