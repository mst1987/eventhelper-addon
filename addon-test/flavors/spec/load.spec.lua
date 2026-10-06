-- The whole addon on both clients: load, log in, open every window, the
-- council window with and without data, the item tooltip, the entry points.
local EHS = EventHelperSync
local FOREVER = WoWMock.flavor == "forever"

WoWMock.Fire("ADDON_LOADED", "EventHelperSync")
WoWMock.Fire("PLAYER_LOGIN")
expectEqual(EHS.version, __TOC_VERSION, "version from the .toc via " .. (FOREVER and "C_AddOns" or "GetAddOnMetadata"))
expect(EHS.db and EHS.db.settings, "SavedVariables set up")

-- Unknown events must not break anything (Forever throws on them).
local probe = CreateFrame("Frame")
EHS:RegisterEvents(probe, "PLAYER_LOGIN", "SOME_EVENT_THIS_CLIENT_LACKS")
expect(probe.__events.PLAYER_LOGIN, "known event registered")

-- The options window, with the fallbacks on Forever -----------------------------------------

EHS:ToggleOptions()
local options = EventHelperSyncOptionsFrame
expect(options and options:IsShown(), "options window open")
if FOREVER then
    expect(options.raidButton and not options.raidDrop, "raid filter as a button with MenuUtil")
    expect(options.scroll.manual, "list scrolls by hand")
    WoWMock.Click(options.raidButton)
    expectEqual(MenuUtil.lastMenu.entries[1].text, "Alle Raids", "raid menu")
else
    expect(options.raidDrop and not options.raidButton, "classic dropdown")
    expect(not options.scroll.manual, "FauxScrollFrame")
end
WoWMock.Click(options.council)
expect(EventHelperSyncCouncilFrame:IsShown(), "council button in the options window")
EHS:ToggleCouncil()
expect(not EventHelperSyncCouncilFrame:IsShown(), "toggle closes")

-- The council window without data -----------------------------------------------------------

EHS:ToggleCouncil()
local council = EventHelperSyncCouncilFrame
expect(council:IsShown(), "council open")
expect(council.header:GetText():find("EventHelper Sync", 1, true), "no-data sentence: " .. council.header:GetText())
expect(council.header:GetText():find("/reload", 1, true), "no-data sentence mentions /reload")
local visible = 0
for _, child in ipairs(WoWMock.frames) do
    if child.__parent == council.list and child.__kind == "Button" and child:IsShown() then visible = visible + 1 end
end
expectEqual(visible, 0, "no rows without data")

local special = false
for _, name in ipairs(UISpecialFrames) do if name == "EventHelperSyncCouncilFrame" then special = true end end
expect(special, "Escape closes the council window")

-- ... and with data -------------------------------------------------------------------------

load(__COUNCIL_FIXTURE)()
EHS:RefreshCouncil()
expect(council.header:GetText():match("^Stand: .+, vor 2 Std%.$"), "header with age: " .. council.header:GetText())
expectEqual(council.filter:GetText(), "SSC/TK Mittwoch · T5/T6 · BiS T6 · 18 Raider", "filter line")

local rows = {}
for _, child in ipairs(WoWMock.frames) do
    if child.__parent == council.list and child.__kind == "Button" then rows[#rows + 1] = child end
end
expectEqual(#rows, 14, "14 rows built")
expectEqual(rows[1].raider.character, "Neuling", "highest need on top")
expectEqual(plain(rows[1].need:GetText()), "Bedarf 95", "need text")
expectEqual(rows[1].last:GetText(), "noch nie", "never looted")
expectEqual(plain(rows[2].name:GetText()), "Gemli Shadow", "name + spec")
expectEqual(rows[2].items:GetText(), "2 Items", "items")
expectEqual(rows[2].bis:GetText(), "BiS 9/16", "bis")
expectEqual(rows[2].last:GetText(), "vor 12 Tagen", "last loot")
expectEqual(rows[2].segments.drought.__width, 50, "drought segment = 100 x 50% of 100 px")
expect(math.abs(rows[2].segments.share.__width - 24) < 1e-9, "share segment")
expectEqual(rows[1].segments.need.__alpha, 1, "visible segment")
expect(council.thumb:IsShown(), "scroll position shown for 18 raiders")

-- row tooltip
WoWMock.Run(rows[2], "OnEnter")
local tip = WoWMock.TooltipText(GameTooltip)
expect(tip:find("Wartezeit (50%) | 100/100", 1, true), "drought part in the tooltip:\n" .. tip)
expect(tip:find("Loot-Anteil (40%) | 60/100", 1, true), "share part")
expect(tip:find("BiS-Lücke (10%) | 40/100", 1, true), "bis part")
expect(tip:find("Erhalten: 2 Items, dazu 1 Offspec/Bank", 1, true), "received header")
expect(tip:find("Robe - \"Neu\" ... | Lady Vashj - Main Spec", 1, true), "received item with boss and reason")
expect(tip:find("BiS-Teile offen | 3", 1, true), "missing BiS")
local robe = tip:find("Robe", 1, true)
local ring = tip:find("Ring", 1, true)
expect(robe and ring and robe < ring, "newest item first")
-- cached items show their link
WoWMock.items[30100] = { name = "Robe of Mock" }
WoWMock.Run(rows[2], "OnEnter")
expect(WoWMock.TooltipText(GameTooltip):find("[Robe of Mock]", 1, true), "item link when cached")

-- scrolling
WoWMock.Run(council.list, "OnMouseWheel", -1)
expectEqual(rows[1].raider.character, "Raider01", "three rows per notch")
WoWMock.Run(council.list, "OnMouseWheel", -1)
expectEqual(rows[14].raider.character, "Raider15", "stops at the end (18 - 14 = 4)")
WoWMock.Run(council.list, "OnMouseWheel", 1)
WoWMock.Run(council.list, "OnMouseWheel", 1)
expectEqual(rows[1].raider.character, "Neuling", "scrolled back")

-- role filter
local healerButton
for _, button in ipairs(council.roleButtons) do if button.role == "healer" then healerButton = button end end
WoWMock.Click(healerButton)
expectEqual(EHS.db.settings.councilRole, "healer", "role remembered")
expectEqual(rows[1].raider.character, "Naphfß", "healer with the highest need")
expect(not rows[7]:IsShown(), "only 6 healers")
expect(not council.thumb:IsShown(), "no scrolling needed")
expectEqual(healerButton.label.__color[1], 1, "selected role highlighted")
for _, button in ipairs(council.roleButtons) do if button.role == "" then WoWMock.Click(button) end end
expectEqual(rows[1].raider.character, "Neuling", "all again")

-- position is remembered
council:ClearAllPoints()
council:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 100, -50)
WoWMock.Run(council, "OnDragStop")
expect(EHS.db.councilPos.point == "TOPLEFT" and EHS.db.councilPos.x == 100, "position saved")

-- Item tooltips -----------------------------------------------------------------------------

WoWMock.ShowItem(GameTooltip, 30000)
tip = WoWMock.TooltipText(GameTooltip)
local _, headers = tip:gsub("Loot%-Council:", "")
expectEqual(headers, 1, "section added once:\n" .. tip)
expect(tip:find("Gemli (Shadow) Bedarf 82 - 2 Items", 1, true), "raider line")
expect(tip:find("... und 12 weitere", 1, true), "more line")
-- a second hook call on the same tooltip must not add it again
EHS.AddCouncilTooltipLines(GameTooltip, 30000)
_, headers = WoWMock.TooltipText(GameTooltip):gsub("Loot%-Council:", "")
expectEqual(headers, 1, "never twice")
WoWMock.ShowItem(GameTooltip, 12345)
expect(not WoWMock.TooltipText(GameTooltip):find("Loot-Council", 1, true), "nothing for unneeded items")
WoWMock.ShowItem(ItemRefTooltip, 30001)
expect(WoWMock.TooltipText(ItemRefTooltip):find("(fehlt 2x)", 1, true), "item links (ItemRefTooltip)")
-- without data the tooltip stays untouched
local saved = EventHelperSync_Council
EventHelperSync_Council = nil
WoWMock.ShowItem(GameTooltip, 30000)
expect(not WoWMock.TooltipText(GameTooltip):find("Loot-Council", 1, true), "no data, no section")
EventHelperSync_Council = saved

-- Entry points ------------------------------------------------------------------------------

council:Hide()
SlashCmdList.EVENTHELPERSYNC("council")
expect(council:IsShown(), "/ehs council opens")
SlashCmdList.EVENTHELPERCOUNCIL("")
expect(not council:IsShown(), "/ehc toggles")
local minimap = EventHelperSyncMinimapButton
WoWMock.Click(minimap, "MiddleButton")
expect(council:IsShown(), "middle click opens the council")
council:Hide()
WoWMock.shift = true
WoWMock.Click(minimap, "LeftButton")
expect(council:IsShown(), "shift-left-click opens the council")
WoWMock.shift = false
options:Hide()
WoWMock.Click(minimap, "LeftButton")
expect(options:IsShown(), "plain left click still opens the options")
WoWMock.Run(minimap, "OnEnter")
expect(WoWMock.TooltipText(GameTooltip):find("Shift-Linksklick / Mittelklick: Loot-Council", 1, true), "minimap tooltip")

WoWMock.prints = {}
SlashCmdList.EVENTHELPERSYNC("help")
local help = table.concat(WoWMock.prints, "\n")
expect(help:find("/ehs council", 1, true), "help lists /ehs council")

-- A newer data version is refused with a hint, not half read.
EventHelperSync_Council = { format = "eventhelper-council", version = 3, categories = {} }
EHS:ShowCouncil()
expect(council.header:GetText():find("neuer als dieses Addon", 1, true), "newer version hint")
