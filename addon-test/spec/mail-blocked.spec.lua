-- GuildBankMail.lua on a Retail-like client (WoW Forever): mailbox via the
-- interaction manager, C_Container only, the body in MailEditBox - and the
-- client blocks the item calls. Once with ADDON_ACTION_BLOCKED (the call does
-- nothing, the event names the addon), then in a fresh session the same
-- without an event (the cursor just stays empty).
WOW_PROJECT_ID = 1
WoWMock.build.interface = 16001
WoWMock.useBagApi("c_container")
SendMailBodyEditBox = nil
MailEditBox = { text = "" }
function MailEditBox:SetText(text) self.text = text end
function MailEditBox:GetInputText() return self.text end

loadAddon()
WoWMock.login({ lastFlushedAt = 1, settings = { autoOpenHandouts = false } })
local EHS = EventHelperSync
local NOW = WoWMock.now
local RUBY = 24027
WoWMock.items[RUBY] = { name = "Bold Living Ruby" }

EventHelperSync_GuildBankHandouts = {
    format = "eventhelper-guildbank-handouts", version = 1, generatedAt = NOW - 600,
    banks = { { key = "forever:thunderstrike:pulse", gameVersion = "forever", realm = "Thunderstrike", guild = "Pulse",
        faction = "Alliance", scannedAt = NOW - 600, handouts = {
            { id = "f1", itemId = RUBY, name = "Bold Living Ruby", icon = "", quality = 3, amount = 2, purpose = "Gruul",
              character = { name = "Zibbo", realm = "Thunderstrike", faction = "Alliance", classFile = "PRIEST" },
              requestedBy = "Anna", requestedAt = NOW - 7200, confirmedBy = "Arthas", confirmedAt = NOW - 3600, inBank = 10, tabs = {} },
        } } },
}
WoWMock.setBags({ [1] = { [4] = { RUBY, 2 } } })

WoWMock.openMailbox("retail")
expect(EHS:IsMailboxOpen(), "open via PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
local group = EHS:GetMailRows()[1]
expectEqual(group.state, "bags", "in the bags (C_Container)")

WoWMock.mail.block = "event"
WoWMock.prints = {}
expect(EHS:PrepareMail(group), "prepared")
WoWMock.advance(10)
expect(EHS:MailAttachBlocked(), "ADDON_ACTION_BLOCKED for this addon: blocked")
expectEqual(EHS:PreparedMail().mode, "manual", "by hand")
expectEqual(SendMailNameEditBox:GetText(), "Zibbo", "recipient")
expectEqual(MailEditBox.text, "Gildenbank-Ausgabe (EventHelper)\n2x Bold Living Ruby - Gruul\nViel Erfolg!", "body in MailEditBox")
expect(WoWMock.printed("Tasche 1 Platz 4: 2x Bold Living Ruby"), "slot line")
expectEqual(WoWMock.cursor, nil, "cursor clean")
expectEqual(#WoWMock.mail.calls, 1, "stopped at the first blocked call")

WoWMock.closeMailbox("retail")
expectEqual(EHS:PreparedMail(), nil, "dropped with the mailbox")

-- the player drags it in and sends
WoWMock.openMailbox("retail")
EHS:PrepareMail(EHS:GetMailRows()[1])
WoWMock.playerAttach(1, 1, 4)
WoWMock.playerClicking = true
SendMail(SendMailNameEditBox:GetText(), SendMailSubjectEditBox:GetText(), MailEditBox:GetInputText())
WoWMock.playerClicking = false
WoWMock.mailSent()
local mark = EHS:IsHandedOut("f1")
expect(mark and mark.via == "mail", "ticked off via mail")
expectEqual(WoWMock.mail.addonSendCalls, 0, "never SendMail from the addon")
