-- The main window of 1.16 (MainWindow.lua, UIKit.lua) on both clients: the
-- rail lists the modules in order and the settings after a separator, the
-- window remembers the page, toggling, the settings page changes the real
-- settings (steppers with - / +, switches), and every window uses the same
-- frame (title bar, X, Escape).
local EHS = EventHelperSync
WoWMock.guild = "Pulse"

WoWMock.Fire("ADDON_LOADED", "EventHelperSync")
load(__HANDOUTS_FIXTURE)()
WoWMock.Fire("PLAYER_LOGIN")
-- the module question of the first login is the modules spec's business
if EventHelperSyncModulesFrame then EventHelperSyncModulesFrame:Hide() end

-- Window and rail ------------------------------------------------------------------------------------

EHS:ShowMain()
local main = EventHelperSyncMainFrame
expect(main:IsShown(), "opens")
expectEqual(main:GetWidth(), main.native and 888 or 880, "width (game frame: body stays 878 wide)")
expectEqual(main.title:GetText(), "EventHelper Sync", "title in the title bar")
expectEqual(main.subtitle:GetText(), "v" .. __TOC_VERSION, "version next to it")
expect(main.close and main.titleBar, "close button and title bar")
if main.native then
    -- the game's window: no crest, rail and content each an inset of their own
    expect(not main.titleBar.crest, "no crest in the game's window")
    expect(main.inset == nil, "no window inset behind rail and content")
    expect(main.rail.native and main.content.native, "rail and content are insets")
    local nav = main.navs.loot
    expect(nav.native and nav.bg.__texture == "Interface\\QuestFrame\\UI-QuestTitleHighlight",
        "rail entry: the quest log glow")
    expectEqual(#nav.edges, 0, "no box around the entry")
else
    expectEqual(main.titleBar.crest.icon.__texture, "Interface\\AddOns\\EventHelperSync\\media\\logo",
        "the EventHelper mark as crest (flat window)")
end
expectEqual(EventHelperSyncMinimapButton.icon.__texture, "Interface\\AddOns\\EventHelperSync\\media\\logo-round",
    "and its round version on the minimap button")
expectEqual(EHS:MainPage(), "loot", "first page: the first module")

local function y(nav) return nav.__points[#nav.__points][5] end
local order = { "loot", "council", "guildbank", "settings" }
for i = 2, #order do
    expect(y(main.navs[order[i]]) < y(main.navs[order[i - 1]]), order[i] .. " below " .. order[i - 1])
end
expect(main.railSep:IsShown(), "separator before the settings")
expectEqual(main.navs.loot.name:GetText(), "Loot-Sync", "rail label")
expectEqual(main.navs.guildbank.badge.label:GetText(), "16", "badge: open handouts")
expect(not main.navs.loot.badge:IsShown(), "no badge when nothing is pending")

-- remembered page, toggling
WoWMock.Click(main.navs.settings)
expectEqual(EHS:MainPage(), "settings", "rail click")
expectEqual(EHS.db.mainPage, "settings", "remembered")
EHS:ToggleMain()
expect(not main:IsShown(), "toggle without a page closes")
EHS:ToggleOptions()
expectEqual(EHS:MainPage(), "settings", "reopens on the remembered page")
EHS:ToggleMain("guildbank")
expectEqual(EHS:MainPage(), "guildbank", "toggle to another page switches")
EHS:ToggleMain("guildbank")
expect(not main:IsShown(), "toggle on the same page closes")

-- Settings page --------------------------------------------------------------------------------------

SlashCmdList.EVENTHELPERSYNC("einstellungen")
local settings = EventHelperSyncSettingsPage
expect(settings:IsShown(), "/ehs einstellungen")

local days = settings.loot.rows[1].control
expectEqual(days.value:GetText(), "21 Tage", "stepper shows the value with unit")
expect(days.native and days.slider, "stepper is the game's slider")
expectEqual(days.slider:GetValue(), 21, "slider stands on the value")
WoWMock.Click(days.plus)
expectEqual(EHS.db.settings.lookbackDays, 28, "+ adds a week")
expectEqual(days.value:GetText(), "28 Tage", "and shows it")
expectEqual(days.slider:GetValue(), 28, "and the slider follows")
WoWMock.Click(days.minus)
WoWMock.Click(days.minus)
expectEqual(EHS.db.settings.lookbackDays, 14, "- takes a week")
for _ = 1, 5 do WoWMock.Click(days.minus) end
expectEqual(EHS.db.settings.lookbackDays, 1, "not below 1")
EHS.db.settings.lookbackDays = 21

local gap = settings.loot.rows[2].control
WoWMock.Click(gap.plus)
expectEqual(EHS.db.settings.sessionGapHours, 7, "gap + 1 hour")
WoWMock.Click(gap.minus)

local showButton = settings.loot.rows[4].control
expect(showButton.on, "upload button switch on")
WoWMock.Click(showButton)
expectEqual(EHS.db.settings.showButton, false, "switched off")
WoWMock.Click(showButton)
expectEqual(EHS.db.settings.showButton, true, "and on")

local suggest = settings.council.rows[1].control
WoWMock.Click(suggest)
expectEqual(EHS.db.settings.rclcSuggest, false, "RCLootCouncil suggestion off")
WoWMock.Click(suggest)

local minimapSwitch = settings.general.rows[1].control
WoWMock.Click(minimapSwitch)
expect(not EventHelperSyncMinimapButton:IsShown(), "minimap button hidden by its switch")
WoWMock.Click(minimapSwitch)
expect(EventHelperSyncMinimapButton:IsShown(), "and back")

WoWMock.prints = {}
WoWMock.Click(settings.general.rows[2].control)
expect(WoWMock.prints[1] and WoWMock.prints[1]:find("Diagnose", 1, true), "Diagnose button writes to chat")

-- One frame for every window ----------------------------------------------------------------------------

EHS:ShowModuleChooser()
local chooser = EventHelperSyncModulesFrame
expect(chooser.titleBar and chooser.close, "module chooser: same frame")
chooser:Hide()
local special = {}
for _, name in ipairs(UISpecialFrames) do special[name] = true end
expect(special.EventHelperSyncMainFrame and special.EventHelperSyncModulesFrame, "Escape closes them")

-- the floating upload button uses the same main button
EHS:StartButton()
expectEqual(EventHelperSyncUploadButton.kind, "primary", "upload button: the primary button")
EHS:HideMain()
