-- The guild bank handout window on both clients: empty state, the rows from
-- the data the sync tool writes (grouped by recipient, colours, tab, count,
-- shortage), ticking and unticking, Offen/Alle, the row tooltip, scrolling,
-- the guild bank opening it by itself, the entry points, and dropping
-- reported ids at login.
local EHS = EventHelperSync
local Handouts = EHS.Handouts
local FOREVER = WoWMock.flavor == "forever"
local P = FOREVER and "f" or "t"
WoWMock.guild = "Pulse"

WoWMock.Fire("ADDON_LOADED", "EventHelperSync")

-- Login with the data and two old marks: the one the list no longer has goes.
load(__HANDOUTS_FIXTURE)()
EHS.db.guildBankDone = {
    gone = { id = "gone", via = "manual", by = "Gemli-Thunderstrike", at = 1 },
    [P .. "r12"] = { id = P .. "r12", via = "manual", by = "Gemli-Thunderstrike", at = 2 },
}
WoWMock.Fire("PLAYER_LOGIN")
expect(EHS.db.guildBankDone.gone == nil, "reported id dropped at login")
expect(EHS.db.guildBankDone[P .. "r12"] ~= nil, "listed id kept")
EHS:UnmarkHandedOut(P .. "r12")

-- Empty state ---------------------------------------------------------------------------------

local saved = EventHelperSync_GuildBankHandouts
EventHelperSync_GuildBankHandouts = nil
SlashCmdList.EVENTHELPERSYNC("bank")
local win = EventHelperSyncGuildBankFrame
expect(win and win:IsShown(), "/ehs bank opens the window")
expectEqual(win.title:GetText(), "Gildenbank-Ausgabe", "title")
expectEqual(win.header:GetText(),
    "Noch keine Ausgabe-Daten: EventHelper Sync auf dem PC laufen lassen, dann /reload.", "empty state")
local rows = {}
for _, child in ipairs(WoWMock.frames) do
    if child.__parent == win.list and child.__kind == "Button" then rows[#rows + 1] = child end
end
expectEqual(#rows, 14, "14 rows built")
for _, row in ipairs(rows) do expect(not row:IsShown(), "no rows without data") end
local special = false
for _, name in ipairs(UISpecialFrames) do if name == "EventHelperSyncGuildBankFrame" then special = true end end
expect(special, "Escape closes the window")

EventHelperSync_GuildBankHandouts = { format = "eventhelper-guildbank-handouts", version = 9, banks = {} }
EHS:RefreshGuildBankUI()
expect(win.header:GetText():find("neuer als dieses Addon", 1, true), "newer version hint")
EventHelperSync_GuildBankHandouts = saved

-- With data -----------------------------------------------------------------------------------

EHS:RefreshGuildBankUI()
expect(win.header:GetText():match("^Stand: %d%d%.%d%d%. %d%d:%d%d, vor 1 Std%. %- Pulse %(Thunderstrike%)$"),
    "header: " .. win.header:GetText())
expectEqual(win.summary:GetText(), "16 Posten offen", "summary")
expect(not win.bankOpen:IsShown(), "guild bank closed")
local openButton, allButton
for _, b in ipairs(win.viewButtons) do
    if b.view == "open" then openButton = b else allButton = b end
end
expectEqual(openButton.label.__color[1], 1, "Offen active (gold)")
expectEqual(allButton.label.__color[1], 0.6, "Alle inactive")

-- sorted by recipient: Anna, Naphfss, Raider01..12, Zibbo x2
local r1, r2, r3 = rows[1], rows[2], rows[3]
expectEqual(r1.entry.id, P .. "3", "own bank of this client only, first Anna")
expectEqual(r1.name:GetText(), "|cff999999Anna|r", "no character: requester in grey")
expectEqual(plain(r1.item:GetText()), "3x Super Healing Potion", "amount and item")
expectEqual(r1.item:GetText(), "|cffffffff3x Super Healing Potion|r", "common quality white")
expectEqual(r1.tab:GetText(), "Tab 3", "tab")
expectEqual(r1.count:GetText(), "4 da", "enough")
expectEqual(Handouts.IconTexture(r1.entry), Handouts.QUESTION_ICON, "no icon: question mark")
expectEqual(plain(r2.name:GetText()), "Naphfß", "Latin-1 name")
expectEqual(r2.name:GetText(), "|cff0070deNaphfß|r", "shaman colour")
expectEqual(r2.count:GetText(), "|cffffd100nur 1!|r", "the potions run out")
expectEqual(r3.name:GetText(), "|cff40c7ebRaider01|r", "mage colour")
expectEqual(r3.count:GetText(), "50 da", "plenty")
expectEqual(rows[14].entry.recipient, "Raider12", "14 rows visible")
expect(win.thumb:IsShown(), "scroll position shown for 16 rows")
expect(not r1.check.mark:IsShown(), "not ticked")
expectEqual(r1.item.__alpha, 1, "full alpha")

-- row tooltip
WoWMock.Run(r1, "OnEnter")
local tip = WoWMock.TooltipText(GameTooltip)
expect(tip:find("Für | Anna (kein Charakter hinterlegt)", 1, true), "recipient without character:\n" .. tip)
expect(tip:find("Zweck | Kara", 1, true), "purpose")
expect(tip:find("Angefragt von | Anna, ", 1, true), "requested by")
expect(tip:find("Bestätigt von | Arthas, ", 1, true), "confirmed by")
expect(tip:find("In der Bank | 4 (Stand letzter Scan)", 1, true), "bank count")
expect(tip:find("  Tab 3 Tränke | 4", 1, true), "tab breakdown")
expect(tip:find("Abhaken, wenn rausgegeben.", 1, true), "hint")
WoWMock.Run(r2, "OnEnter")
expect(WoWMock.TooltipText(GameTooltip):find("Nur noch 1 in der Bank, 2 vorgemerkt!", 1, true), "shortage hint")
-- the checkbox shows the same tooltip
WoWMock.Run(r2.check, "OnEnter")
expect(WoWMock.TooltipText(GameTooltip):find("Naphfß - Thunderstrike", 1, true), "tooltip on the checkbox")

-- scrolling: Zibbo's two rows at the end, the name only once
WoWMock.Run(win.list, "OnMouseWheel", -1)
expectEqual(rows[1].entry.recipient, "Raider01", "scrolled by 2 (16 - 14)")
expect(rows[1].name:GetText() ~= "", "top row keeps the name")
expectEqual(rows[13].entry.id, P .. "1", "Zibbo's ruby")
expectEqual(plain(rows[13].name:GetText()), "Zibbo", "name on the first row of the group")
expectEqual(rows[14].name:GetText(), "", "no name on the second row of the group")
expectEqual(rows[13].tab:GetText(), "Tab 1/2", "two tabs")
expectEqual(rows[13].item:GetText(), "|cff0070de2x Bold Living Ruby|r", "rare blue")
expectEqual(rows[14].count:GetText(), "|cffffd100nur 0!|r", "not in the bank")
expectEqual(rows[14].tab:GetText(), "-", "no tab")
WoWMock.Run(rows[13], "OnEnter")
expect(WoWMock.TooltipText(GameTooltip):find('Zweck | Gruul - "Mag" ...', 1, true), "purpose made Latin-1 by the tool")
WoWMock.Run(win.list, "OnMouseWheel", 1)
expectEqual(rows[1].entry.id, P .. "3", "back at the top")

-- Ticking ---------------------------------------------------------------------------------------

WoWMock.Click(rows[1].check)
local mark = EHS.db.guildBankDone[P .. "3"]
expect(mark and mark.via == "manual" and mark.by == "Gemli-Thunderstrike" and mark.at == WoWMock.now, "ticked into guildBankDone")
expectEqual(rows[1].entry.id, P .. "4", "Offen hides the ticked row")
expectEqual(rows[1].count:GetText(), "4 da", "the potions are enough now")
expectEqual(win.summary:GetText(), "15 Posten offen - 1 abgehakt, wird beim nächsten Sync gemeldet", "summary with ticks")
expect(win.thumb:IsShown(), "15 rows: still a little scrolling")
expect(EHS:HandoutsUnsaved(), "worth a reload")

WoWMock.Click(allButton)
expectEqual(EHS.db.settings.handoutsView, "all", "view remembered")
expectEqual(allButton.label.__color[1], 1, "Alle active")
expectEqual(rows[1].entry.id, P .. "3", "Alle shows it again")
expect(rows[1].check.mark:IsShown(), "check mark")
expectEqual(rows[1].item.__alpha, 0.45, "dimmed")
expect(rows[1].strike:IsShown(), "struck through")
expect(not rows[2].strike:IsShown(), "others not")
WoWMock.Run(rows[1], "OnEnter")
expect(WoWMock.TooltipText(GameTooltip):find("Abgehakt von Gemli-Thunderstrike", 1, true), "tooltip of a ticked row")

WoWMock.Click(rows[1].check)
expect(EHS.db.guildBankDone[P .. "3"] == nil, "unticked before the sync")
expect(not rows[1].check.mark:IsShown() and not rows[1].strike:IsShown(), "row back to normal")
expectEqual(win.summary:GetText(), "16 Posten offen", "summary back")
WoWMock.Click(openButton)

-- Tick everything: "Offen" shows the done state
for _, entry in ipairs((EHS:GetHandoutEntries())) do EHS:MarkHandedOut(entry.id) end
expectEqual(win.empty:GetText(), "Alles abgehakt. Wird beim nächsten Sync gemeldet.", "all ticked")
for _, entry in ipairs((EHS:GetHandoutEntries())) do EHS:UnmarkHandedOut(entry.id) end
expectEqual(win.empty:GetText(), "", "rows again")

-- position is remembered
win:ClearAllPoints()
win:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 120, -40)
WoWMock.Run(win, "OnDragStop")
expect(EHS.db.guildBankPos.point == "TOPLEFT" and EHS.db.guildBankPos.x == 120, "position saved")

-- With the guild bank -----------------------------------------------------------------------------

local function openBank()
    if FOREVER then
        WoWMock.Fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", Enum.PlayerInteractionType.GuildBanker)
    else
        WoWMock.Fire("GUILDBANKFRAME_OPENED")
    end
end
local function closeBank()
    if FOREVER then
        WoWMock.Fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", Enum.PlayerInteractionType.GuildBanker)
    else
        WoWMock.Fire("GUILDBANKFRAME_CLOSED")
    end
end

openBank()
expect(EHS:IsGuildBankOpen(), "bank open on " .. WoWMock.flavor)
expect(win.bankOpen:IsShown(), "green 'Gildenbank offen'")
expectEqual(win.bankOpen:GetText(), "Gildenbank offen", "indicator text")
closeBank()
expect(win:IsShown(), "opened by hand: stays when the bank closes")
expect(not win.bankOpen:IsShown(), "indicator gone")

win:Hide()
openBank()
expect(win:IsShown(), "opens by itself with the guild bank")
closeBank()
expect(not win:IsShown(), "and closes with it")

EHS.db.settings.autoOpenHandouts = false
openBank()
expect(not win:IsShown(), "setting off: stays shut")
closeBank()
EHS.db.settings.autoOpenHandouts = true

for _, entry in ipairs((EHS:GetHandoutEntries())) do EHS:MarkHandedOut(entry.id) end
openBank()
expect(not win:IsShown(), "nothing open: stays shut")
closeBank()
for _, entry in ipairs((EHS:GetHandoutEntries())) do EHS:UnmarkHandedOut(entry.id) end

-- Entry points ------------------------------------------------------------------------------------

SlashCmdList.EVENTHELPERBANK("")
expect(win:IsShown(), "/ehb opens")
SlashCmdList.EVENTHELPERBANK("")
expect(not win:IsShown(), "/ehb toggles")
SlashCmdList.EVENTHELPERSYNC("bank")
expect(win:IsShown(), "/ehs bank")
SlashCmdList.EVENTHELPERSYNC("bank")
expect(not win:IsShown(), "/ehs bank toggles")

local minimap = EventHelperSyncMinimapButton
WoWMock.ctrl = true
WoWMock.Click(minimap, "LeftButton")
expect(win:IsShown(), "ctrl-click on the minimap button")
WoWMock.ctrl = false
win:Hide()
WoWMock.Run(minimap, "OnEnter")
local mtip = WoWMock.TooltipText(GameTooltip)
expect(mtip:find("Gildenbank-Ausgabe | 16 offen", 1, true), "minimap tooltip count:\n" .. mtip)
expect(mtip:find("Strg-Linksklick: Gildenbank-Ausgabe", 1, true), "minimap tooltip hint")

EHS:ToggleOptions()
local options = EventHelperSyncOptionsFrame
WoWMock.Click(options.guildBank)
expect(win:IsShown(), "button in the options window")
win:Hide()
WoWMock.Click(options.autoHandouts)
expect(EHS.db.settings.autoOpenHandouts == (options.autoHandouts:GetChecked() and true or false), "auto-open checkbox")
options:Hide()

WoWMock.prints = {}
SlashCmdList.EVENTHELPERSYNC("help")
expect(table.concat(WoWMock.prints, "\n"):find("/ehs bank", 1, true), "help lists /ehs bank")

-- the other client's bank only when this client has none
local all = EHS:GetHandoutEntries({ allBanks = true })
expectEqual(#all, 32, "both banks with allBanks")
WoWMock.guild = nil
local _, scope = EHS:GetHandoutEntries()
expectEqual(scope, "version", "without guild: the banks of this client")
