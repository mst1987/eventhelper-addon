-- The loot council categories in the window (version 2): no category, the
-- category button (menu on Forever, cycling on Anniversary), the remembered
-- choice, the automatic choice by raid instance, the item tooltip of the
-- active category, the role limited by the website, /ehc <name>, /ehs status,
-- version 1 data from an older sync tool.
local EHS = EventHelperSync
local Council = EHS.Council
local FOREVER = WoWMock.flavor == "forever"

WoWMock.Fire("ADDON_LOADED", "EventHelperSync")
WoWMock.Fire("PLAYER_LOGIN")

--- Only characters the game font can draw: in UTF-8 everything above U+00FF
--- starts with a byte from 0xC4 on.
local function latin1(text)
    return not tostring(text or ""):find("[\196-\244]")
end

local function printed()
    return table.concat(WoWMock.prints, "\n")
end

local function active()
    local category, how = EHS:CouncilActive()
    return category and category.id or nil, how
end

-- No loot council category on the website ----------------------------------------------------

EventHelperSync_Council = { format = "eventhelper-council", version = 2, generatedAt = WoWMock.now - 60, categories = {} }
EHS:ShowCouncil()
local council = EventHelperSyncCouncilFrame
expect(council:IsShown(), "window open")
expect(council.header:GetText():match("^Stand: "), "data age still shown")
expectEqual(council.empty:GetText(), Council.NO_CATEGORY_TEXT, "no-category hint")
expect(council.empty:GetText():find("Einstellungen > Kategorien", 1, true), "tells where to switch it on")
expect(latin1(council.empty:GetText()), "no-category hint is Latin-1")
expect(not council.category:IsShown(), "no category button without categories")
WoWMock.prints = {}
SlashCmdList.EVENTHELPERSYNC("status")
expect(printed():find("Loot-Council: Keine Kategorie mit Loot-Council", 1, true), "/ehs status says so:\n" .. printed())
WoWMock.ShowItem(GameTooltip, 30000)
expect(not WoWMock.TooltipText(GameTooltip):find("Loot-Council", 1, true), "no tooltip section without categories")

-- With categories: the first one until something is chosen --------------------------------------

load(__COUNCIL_FIXTURE)()
EHS:RefreshCouncil()
expect(council.category:IsShown(), "category button")
expectEqual(plain(council.category.label:GetText()), "SSC/TK Mittwoch", "first category, name cleaned")
expectEqual(council.filter:GetText(), "SSC/TK Mittwoch · T5/T6 · BiS T6 · 18 Raider", "header line 2")
expectEqual(EHS.db.settings.councilCategory, nil, "nothing chosen yet")
expectEqual(select(2, active()), "default", "first category by default")

local rows = {}
for _, child in ipairs(WoWMock.frames) do
    if child.__parent == council.list and child.__kind == "Button" then rows[#rows + 1] = child end
end
expectEqual(#rows, 14, "rows")

-- the category tooltip lists them all
WoWMock.Run(council.category, "OnEnter")
local tip = WoWMock.TooltipText(GameTooltip)
expect(tip:find("SSC/TK Mittwoch  (aktiv)", 1, true), "active one marked:\n" .. tip)
expect(tip:find("Kara - Sonntag", 1, true) and tip:find("Kara Donnerstag", 1, true), "all categories listed")
expect(latin1(tip), "category tooltip is Latin-1")

-- Switching: a menu on Forever, cycling on Anniversary -----------------------------------------

if FOREVER then
    WoWMock.Click(council.category)
    local menu = MenuUtil.lastMenu
    expectEqual(menu.entries[1].title, "Kategorie", "menu title")
    expectEqual(menu.entries[2].text, "SSC/TK Mittwoch", "menu entry")
    expect(menu.entries[2].isSelected(), "current category selected")
    expectEqual(menu.entries[3].text, "Kara - Sonntag", "second entry")
    menu.entries[3].setSelected()
else
    WoWMock.Click(council.category, "LeftButton")
end
expectEqual(EHS.db.settings.councilCategory, "987", "choice remembered by id")
expectEqual(select(2, active()), "manual", "chosen by hand")
expectEqual(plain(council.category.label:GetText()), "Kara - Sonntag", "button shows the choice")
expectEqual(council.filter:GetText(), "Kara - Sonntag · nur Caster · T4 · BiS T4 · 2 Raider", "filter of this category")
expectEqual(rows[1].raider.character, "Gemli", "raiders of this category")
expectEqual(plain(rows[1].need:GetText()), "Bedarf 99", "need of this category")
expectEqual(rows[2].raider.character, "Karl", "second")
expect(not rows[3]:IsShown(), "only two raiders")

if not FOREVER then
    WoWMock.Click(council.category, "RightButton")
    expectEqual(EHS.db.settings.councilCategory, "1234567890", "right click: previous")
    WoWMock.Click(council.category, "RightButton")
    expectEqual(EHS.db.settings.councilCategory, "555", "wraps around backwards")
    WoWMock.Click(council.category, "LeftButton")
    expectEqual(EHS.db.settings.councilCategory, "1234567890", "wraps around forwards")
    WoWMock.Click(council.category, "LeftButton")
else
    WoWMock.Click(council.category)
    expect(MenuUtil.lastMenu.entries[3].isSelected(), "menu shows the choice")
    MenuUtil.lastMenu.entries[4].setSelected()
    expectEqual(EHS.db.settings.councilCategory, "555", "menu: third")
    WoWMock.Click(council.category)
    MenuUtil.lastMenu.entries[3].setSelected()
end
expectEqual(EHS.db.settings.councilCategory, "987", "back to Kara Sonntag")

-- a stored choice (from the SavedVariables) is used
EHS.db.settings.councilCategory = "555"
EHS:RefreshCouncil()
expectEqual(plain(council.category.label:GetText()), "Kara Donnerstag", "stored choice")
EHS.db.settings.councilCategory = "gone"
EHS:RefreshCouncil()
expectEqual(plain(council.category.label:GetText()), "SSC/TK Mittwoch", "unknown stored id: first category")
EHS:SetCouncilCategory("987")

-- The website limits the role ---------------------------------------------------------------

local healerButton, allButton
for _, button in ipairs(council.roleButtons) do
    if button.role == "healer" then healerButton = button end
    if button.role == "" then allButton = button end
end
WoWMock.Click(healerButton)
expectEqual(council.empty:GetText(), "Diese Kategorie zeigt nur Caster (Einstellung auf der Webseite).", "role empty state")
expect(latin1(council.empty:GetText()), "role hint is Latin-1")
expectEqual(council.filter:GetText(), "Kara - Sonntag · nur Caster · T4 · BiS T4 · 0 Raider", "0 healers")
EHS:SetCouncilCategory("1234567890")
expectEqual(council.empty:GetText(), "", "healers in a category with all roles")
expectEqual(rows[1].raider.character, "Naphfß", "healer filter inside the category")
WoWMock.Click(allButton)
EHS:SetCouncilCategory("987")

-- The item tooltip follows the active category ----------------------------------------------

WoWMock.ShowItem(GameTooltip, 30000)
tip = WoWMock.TooltipText(GameTooltip)
expect(tip:find("Gemli (Shadow) Bedarf 99 - 0 Items", 1, true), "need of the active category:\n" .. tip)
expect(not tip:find("weitere", 1, true), "only this category's raiders")
WoWMock.ShowItem(GameTooltip, 28000)
tip = WoWMock.TooltipText(GameTooltip)
expect(tip:find("Karl", 1, true) and not tip:find("Heila", 1, true), "not the other Kara category")

-- Automatic choice by raid instance ---------------------------------------------------------

WoWMock.instance = { name = "Höhle des Schlangenschreins", type = "raid", id = 548 }
WoWMock.Fire("PLAYER_ENTERING_WORLD")
local id, how = active()
expect(id == "1234567890" and how == "auto", "entering SSC picks its category")
expectEqual(plain(council.category.label:GetText()), "SSC/TK Mittwoch (auto)", "auto hint")
expectEqual(EHS.db.settings.councilCategory, "987", "the manual choice is kept underneath")
WoWMock.ShowItem(GameTooltip, 30000)
expect(WoWMock.TooltipText(GameTooltip):find("... und 12 weitere", 1, true), "tooltip follows the auto category")

-- choosing by hand inside the same raid sticks
EHS:SetCouncilCategory("555")
WoWMock.Fire("ZONE_CHANGED_NEW_AREA")
id, how = active()
expect(id == "555" and how == "manual", "same place: no new auto choice")
expectEqual(plain(council.category.label:GetText()), "Kara Donnerstag", "no auto hint")

-- leaving the raid (a ghost run) changes nothing
WoWMock.instance = nil
WoWMock.Fire("PLAYER_ENTERING_WORLD")
id, how = active()
expect(id == "555" and how == "manual", "outside: unchanged")

-- ambiguous: two categories name Karazhan
WoWMock.instance = { name = "Karazhan", type = "raid", id = 532 }
WoWMock.Fire("PLAYER_ENTERING_WORLD")
id, how = active()
expect(id == "555" and how == "manual", "ambiguous: the manual choice stays")

-- no match
EHS:SetCouncilCategory("987")
WoWMock.instance = { name = "Gruuls Unterschlupf", type = "raid", id = 565 }
WoWMock.Fire("PLAYER_ENTERING_WORLD")
id, how = active()
expect(id == "987" and how == "manual", "no match: the manual choice stays")

-- a match through the zone text (second instance of the category)
WoWMock.instance = { name = "Tempest Keep", type = "raid", id = 550, zone = "Festung der Stürme" }
WoWMock.Fire("ZONE_CHANGED_NEW_AREA")
id, how = active()
expect(id == "1234567890" and how == "auto", "zone text matches")

-- a dungeon is not a raid
WoWMock.instance = { name = "Karazhan", type = "party" }
WoWMock.Fire("PLAYER_ENTERING_WORLD")
id, how = active()
expect(id == "1234567890" and how == "auto", "dungeons do not choose")
WoWMock.instance = nil

-- /ehc <name> ---------------------------------------------------------------------------------

council:Hide()
WoWMock.prints = {}
SlashCmdList.EVENTHELPERCOUNCIL("donner")
expect(council:IsShown(), "/ehc <name> opens the window")
id, how = active()
expect(id == "555" and how == "manual", "/ehc switches (and beats auto)")
expect(printed():find("Kategorie Kara Donnerstag", 1, true), "/ehc confirms")
WoWMock.prints = {}
SlashCmdList.EVENTHELPERCOUNCIL("xyz")
expect(printed():find('Keine Kategorie passt zu "xyz". Vorhanden: SSC/TK Mittwoch, Kara - Sonntag, Kara Donnerstag.', 1, true),
    "unknown name lists the categories:\n" .. printed())
expectEqual(EHS.db.settings.councilCategory, "555", "nothing changed")
SlashCmdList.EVENTHELPERCOUNCIL("")
expect(not council:IsShown(), "/ehc alone still toggles")

-- /ehs status ---------------------------------------------------------------------------------

WoWMock.prints = {}
SlashCmdList.EVENTHELPERSYNC("status")
local status = printed()
expect(status:find("Loot-Council: 3 Kategorien, Stand: ", 1, true), "status: count:\n" .. status)
expect(status:find(" · SSC/TK Mittwoch - 18 Raider", 1, true), "status: each category")
expect(status:find(" · Kara Donnerstag (aktiv) - 1 Raider", 1, true), "status: the active one")
expect(status:find("/ehc <Name>", 1, true), "status: how to switch")
expect(latin1(status), "status is Latin-1")

-- Version 1 from an older sync tool -----------------------------------------------------------

EventHelperSync_Council = nil
load(__COUNCIL_FIXTURE_V1)()
EHS:ShowCouncil()
expectEqual(plain(council.category.label:GetText()), "SSC/TK Mittwoch", "v1: one category")
expectEqual(council.filter:GetText(), "SSC/TK Mittwoch · BiS T6 · 18 Raider", "v1: filter line")
expectEqual(rows[1].raider.character, "Neuling", "v1: raiders")
WoWMock.ShowItem(GameTooltip, 30000)
expect(WoWMock.TooltipText(GameTooltip):find("... und 12 weitere", 1, true), "v1: tooltip")
