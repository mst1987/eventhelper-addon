-- The guild bank's own minimap button on both clients: built at login next to
-- the EventHelper button, a chest both clients have, gold ring and number
-- while handouts are open, the tooltip (count, ticked, date, hints), left
-- click toggles the window, right click the options, dragging saves its own
-- angle, and hiding it via /ehs bankbutton and the options checkbox.
local EHS = EventHelperSync
local P = WoWMock.flavor == "forever" and "f" or "t"
WoWMock.guild = "Pulse"

WoWMock.Fire("ADDON_LOADED", "EventHelperSync")
load(__HANDOUTS_FIXTURE)()
WoWMock.Fire("PLAYER_LOGIN")

local button = EventHelperSyncBankMinimapButton
expect(button, "built at login")
expect(EventHelperSyncMinimapButton, "the EventHelper button stays")
expect(button ~= EventHelperSyncMinimapButton, "a separate button")
expect(button:IsShown(), "shown by default")
expectEqual(EHS.db.settings.showBankMinimap, true, "setting default on")
expectEqual(button.icon.__texture, "Interface\\Icons\\INV_Box_02", "a chest icon of the original game")
expectEqual(button.border.__texture, "Interface\\Minimap\\MiniMap-TrackingBorder", "same border as the other button")
local point = button.__points[#button.__points]
expect(point[1] == "CENTER" and point[2] == Minimap, "on the minimap")
expect(math.abs(point[4] - 80 * math.cos(math.rad(235))) < 0.01, "at 235 degrees, next to the EventHelper button")

-- 16 open handouts: gold ring and the number
expect(button.glow:IsShown(), "gold ring while handouts are open")
expectEqual(button.count:GetText(), "16", "count badge")
expect(button.count:IsShown(), "badge shown")

-- tooltip
WoWMock.Run(button, "OnEnter")
local tip = WoWMock.TooltipText(GameTooltip)
expect(tip:find("^Gildenbank%-Ausgabe\n16 Posten offen\nStand: %d%d%.%d%d%. %d%d:%d%d, vor 1 Std%.\n"), "tooltip head:\n" .. tip)
expect(not tip:find("abgehakt", 1, true), "nothing ticked yet")
expect(tip:find("Linksklick: Fenster öffnen/schliessen", 1, true), "left click hint")
expect(tip:find("Rechtsklick: EventHelper-Fenster und Einstellungen", 1, true), "right click hint")
expect(tip:find("Ziehen: um die Minimap bewegen", 1, true), "drag hint")

-- ticking changes number and tooltip
EHS:MarkHandedOut(P .. "3")
expectEqual(button.count:GetText(), "15", "one less")
WoWMock.Run(button, "OnEnter")
tip = WoWMock.TooltipText(GameTooltip)
expect(tip:find("15 Posten offen\n1 abgehakt, wird beim nächsten Sync gemeldet", 1, true), "ticked line:\n" .. tip)
for _, entry in ipairs((EHS:GetHandoutEntries())) do EHS:MarkHandedOut(entry.id) end
expect(not button.glow:IsShown() and not button.count:IsShown(), "nothing open: no ring, no number")
for _, entry in ipairs((EHS:GetHandoutEntries())) do EHS:UnmarkHandedOut(entry.id) end
expectEqual(button.count:GetText(), "16", "back")

-- clicks
WoWMock.Click(button, "LeftButton")
local win = EventHelperSyncGuildBankFrame
expect(win and win:IsShown(), "left click opens the window")
WoWMock.Click(button, "LeftButton")
expect(not win:IsShown(), "and closes it")
WoWMock.Click(button, "RightButton")
local options = EventHelperSyncOptionsFrame
expect(options:IsShown(), "right click opens the options")
expect(not win:IsShown(), "not the window")

-- dragging: its own angle
WoWMock.cursorX, WoWMock.cursorY = 0, 10
WoWMock.Run(button, "OnDragStart")
WoWMock.Run(button, "OnUpdate")
WoWMock.Run(button, "OnDragStop")
expect(math.abs(EHS.db.bankMinimapAngle - 90) < 0.01, "angle saved: " .. tostring(EHS.db.bankMinimapAngle))
expectEqual(EHS.db.minimapAngle, nil, "the other button's angle untouched")
point = button.__points[#button.__points]
expect(math.abs(point[5] - 80) < 0.01 and math.abs(point[4]) < 0.01, "moved to the top")
expectEqual(button:GetScript("OnUpdate"), nil, "drag ended")
WoWMock.cursorX, WoWMock.cursorY = nil, nil

-- hiding: /ehs bankbutton and the options
WoWMock.prints = {}
SlashCmdList.EVENTHELPERSYNC("bankbutton")
expectEqual(EHS.db.settings.showBankMinimap, false, "off")
expect(not button:IsShown(), "hidden")
expect(WoWMock.prints[#WoWMock.prints]:find("Gildenbank-Knopf an der Minimap aus.", 1, true), "chat")
expect(EventHelperSyncMinimapButton:IsShown(), "the EventHelper button stays")
SlashCmdList.EVENTHELPERSYNC("bankbutton")
expect(button:IsShown(), "on again")
expect(WoWMock.prints[#WoWMock.prints]:find("Gildenbank-Knopf an der Minimap an.", 1, true), "chat on")

expect(options.bankMinimap.__checked, "options checkbox checked")
options.bankMinimap:SetChecked(false)
WoWMock.Click(options.bankMinimap)
expectEqual(EHS.db.settings.showBankMinimap, false, "checkbox off")
expect(not button:IsShown(), "hidden by the checkbox")
options.bankMinimap:SetChecked(true)
WoWMock.Click(options.bankMinimap)
expect(button:IsShown(), "shown by the checkbox")

WoWMock.prints = {}
SlashCmdList.EVENTHELPERSYNC("help")
expect(table.concat(WoWMock.prints, "\n"):find("/ehs bankbutton", 1, true), "help lists /ehs bankbutton")

-- without data: the hint instead of the count
EventHelperSync_GuildBankHandouts = nil
EHS:RefreshBankMinimap()
expect(not button.count:IsShown(), "no number without data")
WoWMock.Run(button, "OnEnter")
expect(WoWMock.TooltipText(GameTooltip):find("Noch keine Ausgabe-Daten", 1, true), "empty hint")
