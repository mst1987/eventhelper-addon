-- The bigger handout window and taking out of the guild bank by clicking a
-- row, on both clients: geometry of list and mail rows, a click with the bank
-- closed does nothing (tooltip says how), with the bank open a split and a
-- whole stack go into the bags (old bag globals on Anniversary, C_Container
-- on Forever), the row then shows "in den Taschen", nothing is ticked, the
-- checkbox still only ticks, Shift-click takes all of a recipient, and the
-- fallback outlines the slot in the guild bank frame of each client.
local EHS = EventHelperSync
local L = EHS.GuildBankLayout
local FOREVER = WoWMock.flavor == "forever"
local P = FOREVER and "f" or "t"
WoWMock.guild = "Pulse"

WoWMock.Fire("ADDON_LOADED", "EventHelperSync")
load(__HANDOUTS_FIXTURE)()
WoWMock.Fire("PLAYER_LOGIN")

local RUBY, POTION, POWDER = 24027, 22829, 17020
WoWMock.SetBags({})

local function printed(text)
    for i = #WoWMock.prints, 1, -1 do
        if WoWMock.prints[i]:find(text, 1, true) then return true end
    end
    return false
end

-- Geometry ------------------------------------------------------------------------------------------

SlashCmdList.EVENTHELPERBANK("")
local win = EventHelperSyncGuildBankFrame
expect(win:IsShown(), "window open")
expectEqual(L.width, 640, "wider window")
expectEqual(win:GetWidth(), 640, "frame width")
expectEqual(win:GetHeight(), 70 + 12 * 30 + 14, "frame height for 12 rows of 30")
local rows = {}
for _, child in ipairs(WoWMock.frames) do
    if child.__parent == win.list and child.__kind == "Button" then rows[#rows + 1] = child end
end
expectEqual(#rows, 12, "12 rows")
expectEqual(rows[1]:GetHeight(), 30, "row height 30")
expectEqual(rows[1]:GetWidth(), 616, "row width")
expectEqual(rows[1].icon:GetWidth(), 24, "icon 24")
expectEqual(rows[1].check:GetWidth(), 26, "checkbox 26")
expectEqual(rows[1].check.box:GetWidth(), 16, "check box 16")
for _, cell in ipairs({ "name", "item", "tab", "count" }) do
    expectEqual(rows[1][cell].__font, "GameFontHighlight", cell .. " in the normal font")
end
expectEqual(win.header.__font, "GameFontHighlightSmall", "header stays small")
local col = L.columns
expect(col.count[1] + col.count[2] <= 616, "count column inside the row")
expect(col.item[2] >= 250, "room for long item names")
expectEqual(win.list:GetHeight(), 360, "list height")

-- Bank closed: a click does nothing ---------------------------------------------------------------------

local raider = rows[3]
expectEqual(raider.entry.id, P .. "r1", "Raider01's powder")
WoWMock.Run(raider, "OnEnter")
expect(WoWMock.TooltipText(GameTooltip):find("Klick bei offener Gildenbank: in die Taschen nehmen", 1, true), "how to")
WoWMock.prints = {}
WoWMock.Click(raider, "LeftButton")
expectEqual(#WoWMock.bank.calls, 0, "closed: no call")
expectEqual(#WoWMock.prints, 0, "closed: no chat")

-- Bank open ---------------------------------------------------------------------------------------------

WoWMock.bank.tabs = {
    { name = "Edelsteine", slots = { [1] = { id = RUBY, count = 10 } } },
    { name = "Verbrauch", slots = {} },
    { name = "Tränke", slots = { [1] = { id = POWDER, count = 50 }, [2] = { id = POTION, count = 3 }, [9] = { id = POTION, count = 1 } } },
}
if FOREVER then
    WoWMock.Fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", Enum.PlayerInteractionType.GuildBanker)
else
    WoWMock.Fire("GUILDBANKFRAME_OPENED")
end
expect(EHS:IsGuildBankOpen(), "bank open")
expect(EventHelperSyncDB.guildBank, "scanned")

WoWMock.Run(raider, "OnEnter")
local tip = WoWMock.TooltipText(GameTooltip)
expect(tip:find("Klick: in die Taschen nehmen", 1, true), "click hint:\n" .. tip)
expect(tip:find("Shift-Klick: alles für Raider01", 1, true), "shift hint")

-- a part of a stack: split
WoWMock.prints = {}
WoWMock.Click(raider, "LeftButton")
expectEqual(WoWMock.bank.calls[1], "SplitGuildBankItem", "split 1 off the 50")
local slot = WoWMock.bags[0].slots[1]
expect(slot and slot.id == POWDER and slot.count == 1, "powder in the bags")
expectEqual(WoWMock.bank.tabs[3].slots[1].count, 49, "49 left")
expect(printed("Aus der Gildenbank genommen: 1x Arcane Powder"), "chat")
expectEqual(raider.count:GetText(), "|cff59e659in den Taschen|r", "row: in the bags")
expectEqual(EHS:IsHandedOut(P .. "r1"), nil, "not ticked")
WoWMock.Run(raider, "OnEnter")
expect(WoWMock.TooltipText(GameTooltip):find("In den Taschen - bereit für die Post.", 1, true), "tooltip: in the bags")

-- the checkbox still only ticks
local calls = #WoWMock.bank.calls
WoWMock.Click(rows[4].check)
expect(EHS:IsHandedOut(P .. "r2"), "ticked by the checkbox")
expectEqual(#WoWMock.bank.calls, calls, "no withdrawal from the checkbox")
EHS:UnmarkHandedOut(P .. "r2")

-- a whole stack: Anna's 3 potions
local anna = rows[1]
expectEqual(anna.entry.id, P .. "3", "Anna")
WoWMock.prints = {}
WoWMock.Click(anna, "LeftButton")
expectEqual(WoWMock.bank.calls[#WoWMock.bank.calls], "AutoStoreGuildBankItem", "the stack of 3 whole")
expect(WoWMock.bank.tabs[3].slots[2] == nil, "gone from the bank")
expect(printed("Aus der Gildenbank genommen: 3x Super Healing Potion"), "chat")
expectEqual(anna.count:GetText(), "|cff59e659in den Taschen|r", "Anna: in the bags")

-- Naphfß wants 2, the bank has 1 left
WoWMock.prints = {}
WoWMock.Click(rows[2], "LeftButton")
expect(printed("Aus der Gildenbank genommen: 1x Super Healing Potion"), "took the last one")
expect(printed("Super Healing Potion: 1 von 2 nicht genommen - nicht genug in der Gildenbank."), "short")

-- a ticked row is not taken out
EHS:MarkHandedOut(P .. "r3")
EHS.db.settings.handoutsView = "all"
EHS:RefreshGuildBankUI()
calls = #WoWMock.bank.calls
WoWMock.Click(rows[5], "LeftButton")
expectEqual(rows[5].entry.id, P .. "r3", "Raider03, ticked")
expectEqual(#WoWMock.bank.calls, calls, "ticked: no withdrawal")
EHS:UnmarkHandedOut(P .. "r3")
EHS.db.settings.handoutsView = "open"
EHS:RefreshGuildBankUI()

-- Shift-click: Zibbo's ruby and flask (scroll to the end)
WoWMock.Run(win.list, "OnMouseWheel", -1)
WoWMock.Run(win.list, "OnMouseWheel", -1)
local zibbo = rows[11]
expectEqual(zibbo.entry.id, P .. "1", "Zibbo's ruby")
WoWMock.shift = true
WoWMock.prints = {}
WoWMock.Click(zibbo, "LeftButton")
WoWMock.shift = false
expect(printed("Aus der Gildenbank genommen: 2x Bold Living Ruby"), "the ruby")
expect(printed("Flask of Supreme Power: 1 von 1 nicht genommen - nicht genug in der Gildenbank."), "and the flask is missing")
expectEqual(WoWMock.bank.tabs[1].slots[1].count, 8, "2 rubies split off")
expectEqual(zibbo.count:GetText(), "|cff59e659in den Taschen|r", "Zibbo's ruby in the bags")
WoWMock.Run(win.list, "OnMouseWheel", 1)
WoWMock.Run(win.list, "OnMouseWheel", 1)

-- Blocked: the slot in chat and outlined in the guild bank frame --------------------------------------------

WoWMock.bankBlock = true
WoWMock.bank.current = 3
WoWMock.prints = {}
WoWMock.Click(rows[5], "LeftButton")
expectEqual(rows[5].entry.id, P .. "r3", "Raider03")
expect(EHS:GuildBankWithdrawBlocked(), "blocked")
expect(printed("Entnehmen aus der Gildenbank ist auf diesem Client gesperrt."), "blocked line")
expect(printed("  Tab 3 Platz 1: 1x Arcane Powder (von 49, Shift-Klick teilt den Stapel)"), "slot line")
local outline = EHS.Withdraw.Highlights()[1]
expect(outline and outline:IsShown(), "outlined")
expect(outline.button == WoWMock.bankButtons[1], "on slot 1 of the shown tab ("
    .. (FOREVER and "GuildBankFrame.Columns" or "GuildBankColumn1Button1") .. ")")
expect(WoWMock.cursor == nil, "cursor clean")
WoWMock.bankBlock = false

if FOREVER then
    WoWMock.Fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", Enum.PlayerInteractionType.GuildBanker)
else
    WoWMock.Fire("GUILDBANKFRAME_CLOSED")
end
expect(not outline:IsShown(), "outline gone with the bank")
calls = #WoWMock.bank.calls
WoWMock.Click(rows[6], "LeftButton")
expectEqual(#WoWMock.bank.calls, calls, "closed again: nothing")

-- Mail rows: bigger as well -----------------------------------------------------------------------------------

WoWMock.OpenMailbox()
local mailRows = {}
for _, child in ipairs(WoWMock.frames) do
    if child.__parent == win.mailList and child.__kind == "Button" then mailRows[#mailRows + 1] = child end
end
expectEqual(#mailRows, 6, "6 mail rows")
expectEqual(mailRows[1]:GetHeight(), 60, "mail row height 60")
expectEqual(mailRows[1].lines[1].icon:GetWidth(), 18, "mail item icon 18")
expectEqual(mailRows[1].lines[1].text.__font, "GameFontHighlight", "mail item in the normal font")
expectEqual(win.mailList:GetHeight(), 360, "same list height")
-- Anna's potions and Raider01's powder are in the bags now
expectEqual(mailRows[3].group.recipient, "Raider01", "Raider01")
expectEqual(mailRows[3].state:GetText(), "in den Taschen", "ready for the mail")
WoWMock.CloseMailbox()
