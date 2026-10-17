-- The building blocks of UIKit.lua on both clients: with the client's
-- templates they are the game's own (x.native), without them the flat 1.16
-- blocks with the same interface. A missing template never throws.
local EHS = EventHelperSync
local Kit = EHS.Kit
local FOREVER = WoWMock.flavor == "forever"

WoWMock.Fire("ADDON_LOADED", "EventHelperSync")
WoWMock.Fire("PLAYER_LOGIN")
if EventHelperSyncModulesFrame then EventHelperSyncModulesFrame:Hide() end

local parent = CreateFrame("Frame", nil, UIParent)

-- FromTemplate -------------------------------------------------------------------------------

expectEqual(Kit.FromTemplate("Frame", nil, parent, "NoSuchTemplate"), nil, "unknown template: nil, no error")
local inset = Kit.FromTemplate("Frame", nil, parent, "InsetFrameTemplate")
expectEqual(inset and inset.fromTemplate, "InsetFrameTemplate", "known template: the frame")
expectEqual(Kit.FromTemplate("Frame", nil, parent, "InsetFrameTemplate", function() return false end), nil,
    "a failed check gives nil")
expectEqual(Kit.FromTemplate("Frame", nil, parent, "InsetFrameTemplate", function() error("boom") end), nil,
    "a throwing check gives nil")

-- the client answers "unknown" before CreateFrame even runs
local getInfo = C_XMLUtil.GetTemplateInfo
C_XMLUtil.GetTemplateInfo = function() return nil end
expectEqual(Kit.FromTemplate("Frame", nil, parent, "InsetFrameTemplate"), nil, "GetTemplateInfo says no")
C_XMLUtil.GetTemplateInfo = getInfo

-- Native blocks ------------------------------------------------------------------------------

local clicks = 0
local button = Kit.Button(parent, "Hochladen", "primary", 140, function() clicks = clicks + 1 end, "Erklaerung")
expect(button.native, "button from UIPanelButtonTemplate")
expectEqual(button.label:GetText(), "Hochladen", "label is the template's font string")
button:SetLabel("Fertig")
expectEqual(button.label:GetText(), "Fertig", "SetLabel")
WoWMock.Click(button)
expectEqual(clicks, 1, "click runs onClick")
button:SetActive(false)
WoWMock.Click(button)
expectEqual(clicks, 1, "inactive button ignores the click")
expectEqual(button.active, false, "button.active")

local link = Kit.Button(parent, "mehr", "link", 60)
expect(not link.native, "link button stays a text")

local closed = false
local close = Kit.CloseButton(parent, function() closed = true end)
expect(close.native, "close button from UIPanelCloseButton")
WoWMock.Click(close)
expect(closed, "close runs our onClick, not only Hide of the parent")

-- the check keeps the caller's state, not the template's own toggle
local check = Kit.Check(parent)
expect(check.native, "check from UICheckButtonTemplate")
expectEqual(check:GetChecked(), false, "starts unticked")
check:SetScript("OnClick", function(self) self:SetChecked(true) end)
WoWMock.Click(check)
expectEqual(check:GetChecked(), true, "OnClick decides")
check:SetScript("OnClick", function() end)
WoWMock.Click(check)
expectEqual(check:GetChecked(), true, "a click without a decision keeps the state")
expectEqual(check.__checked, true, "and the box shows it (PostClick)")

local card = Kit.Card(parent, "Allgemein", 300, 120)
expect(card.native and card.title and card.pill, "card on an inset, with title and pill")
expectEqual(card.title:GetText(), "Allgemein", "card title")

local window = Kit.Window({ name = "EHSWidgetsSpecFrame", title = "Probe", width = 400, height = 300 })
expect(window.native, "window from ButtonFrameTemplate")
expectEqual(window.title:GetText(), "Probe", "title in the template's title")
expectEqual(window:GetWidth(), 400 - 2 + Kit.NATIVE_BODY.left + Kit.NATIVE_BODY.right, "frame grows by the border")
expect(window.body and window.titleBar and window.subtitle and window.close, "same parts as the flat window")
window:Show()
WoWMock.Click(window.close)
expect(not window:IsShown(), "the X closes")
local found = false
for _, name in ipairs(UISpecialFrames) do found = found or name == "EHSWidgetsSpecFrame" end
expect(found, "Escape closes it")

-- Dropdown: the game's dropdown where MenuUtil exists
local value = "a"
local items = function() return { { value = "a", text = "Alle" }, { value = "b", text = "Bosse" } } end
local drop = Kit.Dropdown(parent, 160, "Raid", items, function() return value end, function(v) value = v end)
drop:Refresh()
expectEqual(drop.label:GetText(), "Alle", "label shows the selected item")
if FOREVER then
    expect(drop.native, "dropdown from WowStyle1DropdownTemplate")
    WoWMock.Click(drop)
    local menu = MenuUtil.lastMenu
    expectEqual(menu.entries[1].title, "Raid", "menu title")
    expectEqual(menu.entries[3].text, "Bosse", "a radio per item")
    menu.entries[3].setSelected()
    drop:Refresh()
    expectEqual(value, "b", "picking sets the value")
    expectEqual(drop.label:GetText(), "Bosse", "and the label")
    expect(drop.generateCount >= 1, "Refresh regenerates the menu")
else
    expect(not drop.native, "no MenuUtil in this mock: flat dropdown")
    WoWMock.Click(drop)
    expectEqual(value, "b", "flat dropdown steps on")
end

-- Tooltip and InfoButton ---------------------------------------------------------------------

local info = Kit.InfoButton(parent, "Was ist das?", "Eine Erklaerung.")
expectEqual(info.label:GetText(), "?", "a question mark")
WoWMock.Run(info, "OnEnter")
expectEqual(GameTooltip:NumLines(), 2, "gold title and text")
expectEqual(GameTooltip.__lines[1].left, "Was ist das?", "title first")

-- a frame's own OnEnter stays, the tooltip hooks in
local own = 0
local hooked = CreateFrame("Button", nil, parent)
hooked:SetScript("OnEnter", function() own = own + 1 end)
Kit.Tooltip(hooked, "Text")
Kit.Tooltip(hooked, "Neuer Text")
expectEqual(#(hooked.__hooks.OnEnter or {}), 1, "hooked once")
hooked.__scripts.OnEnter(hooked)
for _, fn in ipairs(hooked.__hooks.OnEnter) do fn(hooked) end
expectEqual(own, 1, "own OnEnter still runs")
expectEqual(GameTooltip.__lines[1].left, "Neuer Text", "the second call changed the text")

-- Fallbacks: without the templates the flat blocks, same interface --------------------------

for _, name in ipairs({ "UIPanelButtonTemplate", "UIPanelCloseButton", "UICheckButtonTemplate",
    "InsetFrameTemplate", "ButtonFrameTemplate", "WowStyle1DropdownTemplate" }) do
    WoWMock.templates[name] = nil
end

local flat = Kit.Button(parent, "Post", "secondary", 80, function() clicks = clicks + 1 end)
expect(not flat.native and flat.bg and flat.label:GetText() == "Post", "flat button")
local flatClose = Kit.CloseButton(parent, function() end)
expect(not flatClose.native and flatClose.label:GetText() == "x", "flat close")
local flatCheck = Kit.Check(parent)
expect(not flatCheck.native and flatCheck.mark, "flat check")
flatCheck:SetChecked(true)
expect(flatCheck:GetChecked() and flatCheck.mark:IsShown(), "flat check ticks")
local flatCard = Kit.Card(parent, "Module", 300, 80)
expect(not flatCard.native and flatCard.bg and flatCard.head, "flat card")
local flatDrop = Kit.Dropdown(parent, 160, "Raid", items, function() return value end, function(v) value = v end)
expect(not flatDrop.native and flatDrop.arrow, "flat dropdown")
local flatWindow = Kit.Window({ name = "EHSWidgetsSpecFlat", title = "Flach", width = 400, height = 300 })
expect(not flatWindow.native, "flat window")
expectEqual(flatWindow:GetWidth(), 400, "flat window as wide as asked")
expectEqual(flatWindow.title:GetText(), "Flach", "flat title")
expect(flatWindow.body and flatWindow.titleBar.crest and flatWindow.close, "flat parts")
