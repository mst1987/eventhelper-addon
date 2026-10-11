-- Choosing the modules (Modules.lua) on both clients: asked once at the first
-- login with everything on, "Später" asks again, "Übernehmen" saves; a module
-- that is off leaves no trace (windows, slash commands, tooltip lines, minimap
-- button, mailbox, export) and comes back without /reload.
local EHS = EventHelperSync
WoWMock.guild = "Pulse"

local function printed(text)
    for _, line in ipairs(WoWMock.prints) do
        if line:find(text, 1, true) then return true end
    end
    return false
end

WoWMock.Fire("ADDON_LOADED", "EventHelperSync")
load(__COUNCIL_FIXTURE)()
load(__HANDOUTS_FIXTURE)()
WoWMock.Fire("PLAYER_LOGIN")

-- Asked at the first login, everything on ------------------------------------------------------

local chooser = EventHelperSyncModulesFrame
expect(chooser and chooser:IsShown(), "asked at the first login")
expect(not EHS:ModulesChosen(), "nothing saved yet")
expectEqual(#chooser.rows, 3, "three modules")
expectEqual(chooser.rows[1].name:GetText(), "Loot-Sync", "first module")
expectEqual(chooser.rows[2].name:GetText(), "Loot-Council", "second module")
expectEqual(chooser.rows[3].name:GetText(), "Gildenbank", "third module")
for _, row in ipairs(chooser.rows) do
    expect(row.switch.on, row.module.name .. " preset on")
    expectEqual(row.switch.state:GetText(), "An", row.module.name .. " switch says An")
end
for _, id in ipairs({ "loot", "council", "guildbank" }) do expect(EHS:ModuleOn(id), id .. " on before choosing") end
local escape = false
for _, name in ipairs(UISpecialFrames) do if name == "EventHelperSyncModulesFrame" then escape = true end end
expect(escape, "Escape closes it")

-- "Später" saves nothing, the next login asks again
WoWMock.Click(chooser.later)
expect(not chooser:IsShown(), "Später closes")
expect(not EHS:ModulesChosen(), "Später saves nothing")
WoWMock.Fire("PLAYER_LOGIN")
expect(chooser:IsShown(), "asked again at the next login")

-- All off is not allowed
for _, row in ipairs(chooser.rows) do WoWMock.Click(row) end
for _, row in ipairs(chooser.rows) do expect(not row.switch.on, "row click switches off") end
expectEqual(chooser.rows[1].switch.state:GetText(), "Aus", "switch says Aus")
expect(chooser.hint:GetText():find("Mindestens ein Modul", 1, true), "hint when all are off")

-- Only the loot sync: council and guild bank off
WoWMock.Click(chooser.rows[1].switch)
expect(chooser.rows[1].switch.on, "the switch itself toggles too")
expectEqual(chooser.hint:GetText(), "", "hint gone")
WoWMock.prints = {}
WoWMock.Click(chooser.apply)
expect(not chooser:IsShown(), "Übernehmen closes")
expect(EHS:ModulesChosen(), "saved")
expectEqual(EHS.db.modules.loot, true, "loot saved on")
expectEqual(EHS.db.modules.council, false, "council saved off")
expectEqual(EHS.db.modules.guildbank, false, "guild bank saved off")
expect(printed("Module: Loot-Sync an, Loot-Council aus, Gildenbank aus."), "summary in chat")

WoWMock.Fire("PLAYER_LOGIN")
expect(not chooser:IsShown(), "not asked again once chosen")

-- Council off -------------------------------------------------------------------------------------

WoWMock.prints = {}
EHS:ToggleCouncil()
expect(not (EventHelperSyncCouncilFrame and EventHelperSyncCouncilFrame:IsShown()), "no council window")
expect(printed("Loot-Council ist ausgeschaltet. Einschalten: /ehs module"), "says how to switch it on")
WoWMock.prints = {}
SlashCmdList.EVENTHELPERCOUNCIL("")
expect(printed("Loot-Council ist ausgeschaltet"), "/ehc says it too")
WoWMock.prints = {}
SlashCmdList.EVENTHELPERSYNC("vorschlag")
expect(printed("Loot-Council ist ausgeschaltet"), "/ehs vorschlag says it too")
WoWMock.ShowItem(GameTooltip, 30000)
expect(not WoWMock.TooltipText(GameTooltip):find("Loot-Council", 1, true), "no tooltip lines")

-- Guild bank off ----------------------------------------------------------------------------------

expect(not EventHelperSyncBankMinimapButton:IsShown(), "no guild bank minimap button")
WoWMock.prints = {}
SlashCmdList.EVENTHELPERBANK("")
expect(not (EventHelperSyncGuildBankFrame and EventHelperSyncGuildBankFrame:IsShown()), "no guild bank window")
expect(printed("Gildenbank ist ausgeschaltet"), "/ehb says how to switch it on")
WoWMock.OpenMailbox()
expect(not (EventHelperSyncGuildBankFrame and EventHelperSyncGuildBankFrame:IsShown()), "mailbox opens nothing")
WoWMock.CloseMailbox()

-- The minimap tooltip only lists what is on
WoWMock.Run(EventHelperSyncMinimapButton, "OnEnter")
local tip = WoWMock.TooltipText(GameTooltip)
expect(tip:find("Raid-Abende", 1, true), "loot lines stay")
expect(not tip:find("Loot-Council", 1, true), "no council hint:\n" .. tip)
expect(not tip:find("Gildenbank", 1, true), "no guild bank hint:\n" .. tip)

-- Status names the modules
WoWMock.prints = {}
SlashCmdList.EVENTHELPERSYNC("status")
expect(printed("Module: Loot-Sync an, Loot-Council aus, Gildenbank aus. Ändern: /ehs module"), "status line")
expect(not printed("Gildenbank-Ausgabe:"), "no handout status")

-- Switched back on without /reload ------------------------------------------------------------------

SlashCmdList.EVENTHELPERSYNC("module")
expect(chooser:IsShown(), "/ehs module opens it")
expect(chooser.rows[1].switch.on and not chooser.rows[2].switch.on and not chooser.rows[3].switch.on,
    "preset with the saved choice")
WoWMock.Click(chooser.rows[2])
WoWMock.Click(chooser.rows[3])
WoWMock.Click(chooser.apply)
WoWMock.ShowItem(GameTooltip, 30000)
expect(WoWMock.TooltipText(GameTooltip):find("Loot-Council", 1, true), "tooltip lines back (hooks set now)")
EHS:ToggleCouncil()
expect(EventHelperSyncCouncilFrame:IsShown(), "council window back")
EHS:ToggleCouncil()
expect(EventHelperSyncBankMinimapButton:IsShown(), "guild bank button back")
WoWMock.OpenMailbox()
expect(EventHelperSyncGuildBankFrame and EventHelperSyncGuildBankFrame:IsShown(), "handouts open at the mailbox again")
WoWMock.CloseMailbox()

-- Loot sync off ------------------------------------------------------------------------------------

EHS:ShowCouncil()
EHS:SetModule("council", false)
expect(not EventHelperSyncCouncilFrame:IsShown(), "switching off closes its window")

EHS:SetModule("loot", false)
expectEqual(EHS:PendingCount(), 0, "nothing pending without the loot sync")
EHS:ShowOptions()
local options = EventHelperSyncOptionsFrame
expectEqual(options.sources:GetText(), "|cff888888Loot-Sync ist ausgeschaltet.|r", "options say it")
expect(options.moduleLine:GetText():find("Loot-Sync aus", 1, true), "module line in the options")
WoWMock.Click(options.modules)
expect(chooser:IsShown(), "Module wählen opens the chooser")
chooser:Hide()

local before = EHS.db.export
EHS.db.export = "unchanged"
WoWMock.Fire("PLAYER_LOGOUT")
expectEqual(EHS.db.export, "unchanged", "no export rebuilt at logout")
EHS.db.export = before

WoWMock.prints = {}
SlashCmdList.EVENTHELPERSYNC("diag")
expect(printed("Der Loot-Sync ist ausgeschaltet"), "diag says it first")
EHS:SetModule("loot", true)
EHS:RefreshOptions()
expect(options.sources:GetText():find("Quellen:", 1, true), "table back with the loot sync on")
