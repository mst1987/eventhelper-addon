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

-- Switch: the game's check box, our state ----------------------------------------------------

local toggles = {}
local switch = Kit.Switch(parent, function(_, on) toggles[#toggles + 1] = on end, "Erklaerung")
expect(switch.native, "switch from UICheckButtonTemplate")
expectEqual(switch.__template, "UICheckButtonTemplate", "a check button of the game")
expectEqual(switch.kind, "switch", "switch.kind")
expectEqual(switch.on, false, "starts off")
expectEqual(switch.Text:GetText(), "", "the template's own label stays empty")
WoWMock.Click(switch)
expectEqual(switch.on, true, "a click switches on")
expectEqual(switch.__checked, true, "and the box is ticked")
expectEqual(toggles[1], true, "onToggle(true)")
WoWMock.Click(switch)
expectEqual(switch.on, false, "a second click switches off")
expectEqual(switch.__checked, false, "box empty")
switch:SetOn(true)
expectEqual(switch.__checked, true, "SetOn ticks the box")
expectEqual(#toggles, 2, "SetOn does not call back")
switch:SetActive(false)
WoWMock.Click(switch)
expectEqual(switch.on, true, "inactive: the click changes nothing")
expectEqual(switch.__checked, true, "the box keeps showing the state (PostClick)")
expectEqual(#toggles, 2, "and no call back")
switch:SetActive(true)

-- SettingRow: a switch stands left, its name right of it, as in the game's options
local rowCard = Kit.Card(parent, "Zeilen", 300, 120)
local rowSwitch = Kit.Switch(rowCard, function() end)
local rowLabel = Kit.SettingRow(rowCard, -36, "Knopf zeigen", "Ein Hinweis", rowSwitch, 300)
expectEqual(rowSwitch.__points[1][1], "TOPLEFT", "switch on the left")
expectEqual(rowLabel.__points[1][4], 8 + 26 + 4, "name right of the box")
local rowStepper = Kit.Stepper(rowCard, function() return 3 end, function() end, { min = 1, max = 9 })
Kit.SettingRow(rowCard, -70, "Zahl", nil, rowStepper, 300)
expectEqual(rowStepper.__points[1][1], "TOPRIGHT", "other controls stay on the right")

-- Chip: the small red button, held lit when selected -----------------------------------------

local picked = 0
local chip = Kit.Chip(parent, "Heiler", function() picked = picked + 1 end)
expect(chip.native, "chip from UIPanelButtonTemplate")
expectEqual(chip.label:GetText(), "Heiler", "chip label")
expectEqual(chip.__locked, false, "not selected: no held light")
chip:SetSelected(true)
expect(chip.selected and chip.__locked, "selected: LockHighlight")
chip:SetSelected(false)
expect(not chip.selected and not chip.__locked, "UnlockHighlight")
WoWMock.Click(chip)
expectEqual(picked, 1, "chip click")

-- Pill and Badge: text in the game's colours, no box -----------------------------------------

local pill = Kit.Pill(parent)
pill:SetState("aus", "off")
expectEqual(pill.label:GetText(), "aus", "pill text")
expectEqual(pill.label.__color[1], GRAY_FONT_COLOR.r, "off: the game's grey")
pill:SetState("bereit", "on")
expectEqual(pill.label.__color[2], GREEN_FONT_COLOR.g, "on: the game's green")
pill:SetState("fehlt", "bad")
expectEqual(pill.label.__color[1], RED_FONT_COLOR.r, "bad: the game's red")
expect(not pill.bg and not pill.edges, "no box around it")
local badge = Kit.Badge(parent)
expect(not badge:IsShown(), "badge 0: hidden")
badge:SetCount(16)
expect(badge:IsShown() and badge.label:GetText() == "16", "badge shows the number")
badge:SetCount(120)
expectEqual(badge.label:GetText(), "99+", "badge caps at 99+")
expect(not badge.bg, "badge: only the number")

-- Stepper: the slider of the game's options ---------------------------------------------------

local function stepperProbe(start)
    local probe = { value = start, changes = {}, sets = 0 }
    probe.get = function() return probe.value end
    probe.set = function(v) probe.value = v; probe.sets = probe.sets + 1 end
    probe.opts = { min = 1, max = 60, step = 7, unit = "Tage", onChange = function(v) probe.changes[#probe.changes + 1] = v end }
    return probe
end

local p = stepperProbe(21)
local stepper = Kit.Stepper(parent, p.get, p.set, p.opts)
expect(stepper.native and stepper.slider, "stepper from MinimalSliderWithSteppersTemplate")
expectEqual(stepper.slider.__template, "MinimalSliderWithSteppersTemplate", "the new options slider")
expect(stepper.slider.__inited, "Init ran")
expectEqual(stepper.slider.__min, 1, "Init min")
expectEqual(stepper.slider.__max, 60, "Init max")
expectEqual(stepper.slider.__steps, 59, "one notch per whole number")
expectEqual(stepper.slider:GetValue(), 21, "slider on the value")
expectEqual(stepper.value:GetText(), "21 Tage", "the number with its unit next to it")
expectEqual(p.sets, 0, "building stores nothing (no echo)")
expectEqual(stepper.minus, stepper.slider.Back, "minus is the template's left arrow")
expectEqual(stepper.plus, stepper.slider.Forward, "plus is the right arrow")
WoWMock.Click(stepper.plus)
expectEqual(p.value, 28, "an arrow steps by opts.step")
expectEqual(stepper.slider:GetValue(), 28, "the slider follows")
expectEqual(stepper.value:GetText(), "28 Tage", "and the number")
expectEqual(p.sets, 1, "stored once (the slider's echo is ignored)")
expectEqual(p.changes[1], 28, "onChange")
for _ = 1, 6 do WoWMock.Click(stepper.minus) end
expectEqual(p.value, 1, "not below min")
for _ = 1, 12 do WoWMock.Click(stepper.plus) end
expectEqual(p.value, 60, "not above max")
-- dragging: the slider reports a fraction, the stepper rounds
stepper.slider:TriggerEvent(MinimalSliderWithSteppersMixin.Event.OnValueChanged, 13.6)
expectEqual(p.value, 14, "dragging rounds to a whole number")
expectEqual(stepper.value:GetText(), "14 Tage", "and shows it")
local setsBefore = p.sets
stepper.slider:TriggerEvent(MinimalSliderWithSteppersMixin.Event.OnValueChanged, 14.2)
expectEqual(p.sets, setsBefore, "same whole number: nothing stored")
p.value = 35
stepper.refresh()
expectEqual(stepper.slider:GetValue(), 35, "refresh moves the slider")
expectEqual(p.sets, setsBefore, "refresh stores nothing")

-- no range: the flat - number +
local open = stepperProbe(5)
open.opts = { step = 1 }
local free = Kit.Stepper(parent, open.get, open.set, open.opts)
expect(not free.native and free.minus and free.plus, "without min/max the flat stepper")
WoWMock.Click(free.plus)
expectEqual(open.value, 6, "flat + still works")

-- the old options slider when the new one is missing
local minimal = WoWMock.templates.MinimalSliderWithSteppersTemplate
WoWMock.templates.MinimalSliderWithSteppersTemplate = nil
local p2 = stepperProbe(21)
local old = Kit.Stepper(parent, p2.get, p2.set, p2.opts)
expect(old.native and old.slider, "fallback: OptionsSliderTemplate")
expectEqual(old.slider.__template, "OptionsSliderTemplate", "the old options slider")
expect(not old.slider.Low.__shown and not old.slider.High.__shown and not old.slider.Text.__shown,
    "its min/max/title texts hidden")
expectEqual(old.slider:GetValue(), 21, "on the value")
expectEqual(p2.sets, 0, "no echo while building")
WoWMock.Click(old.plus)
expectEqual(p2.value, 28, "+ steps by opts.step")
expectEqual(old.slider:GetValue(), 28, "slider follows")
WoWMock.Click(old.minus)
expectEqual(p2.value, 21, "- back")
old.slider:SetValue(40.4)
expectEqual(p2.value, 40, "dragging rounds")
expectEqual(p2.sets, 3, "one store per change")
WoWMock.templates.MinimalSliderWithSteppersTemplate = minimal

-- a template that is there but without the mixin: the old slider, never an error
local mixin = MinimalSliderWithSteppersMixin
MinimalSliderWithSteppersMixin = nil
local noMixin = Kit.Stepper(parent, p2.get, p2.set, p2.opts)
expectEqual(noMixin.slider and noMixin.slider.__template, "OptionsSliderTemplate", "no mixin: old slider")
MinimalSliderWithSteppersMixin = mixin

-- Window: one title, the template's inset behind the body -------------------------------------

local insetWindow = Kit.Window({ name = "EHSWidgetsSpecInset", title = "Mit Flaeche", width = 300, height = 200 })
expect(insetWindow.inset and insetWindow.inset == insetWindow.Inset, "the template's inset behind the body")
expect(insetWindow.inset:IsShown(), "and shown")
expect(insetWindow.body:GetFrameLevel() > insetWindow.inset:GetFrameLevel(), "body above the inset")
local bareWindow = Kit.Window({ name = "EHSWidgetsSpecBare", title = "Ohne", width = 300, height = 200, inset = false })
expect(bareWindow.inset == nil and not bareWindow.Inset:IsShown(), "inset = false: no inset")

-- a client whose template has both title fonts: the title shows once
local buttonFrame = WoWMock.templates.ButtonFrameTemplate
WoWMock.templates.ButtonFrameTemplate = function(frame)
    buttonFrame(frame)
    frame.TitleText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    function frame:SetTitle(text) self.TitleText:SetText(text) end
end
local twoTitles = Kit.Window({ name = "EHSWidgetsSpecTwoTitles", title = "Einmal", width = 300, height = 200 })
local withText = 0
for _, fs in ipairs({ twoTitles.TitleText, twoTitles.TitleContainer.TitleText }) do
    if fs:GetText() and fs:GetText() ~= "" then withText = withText + 1 end
end
expectEqual(withText, 1, "only one title font has text")
expectEqual(twoTitles.title, twoTitles.TitleText, "the one SetTitle wrote")
expect(not twoTitles.TitleContainer.TitleText:IsShown(), "the other is hidden")
WoWMock.templates.ButtonFrameTemplate = buttonFrame
expect(not twoTitles.titleBar.crest, "no crest in the game's window")

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
    "InsetFrameTemplate", "ButtonFrameTemplate", "WowStyle1DropdownTemplate",
    "MinimalSliderWithSteppersTemplate", "OptionsSliderTemplate" }) do
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

local flatSwitch = Kit.Switch(parent, function() end)
expect(not flatSwitch.native and flatSwitch.knob, "flat switch")
WoWMock.Click(flatSwitch)
expectEqual(flatSwitch.on, true, "flat switch toggles")
local flatChip = Kit.Chip(parent, "Tank")
expect(not flatChip.native and flatChip.bg, "flat chip")
flatChip:SetSelected(true)
expect(flatChip.selected, "flat chip selects")
local flatValue = 21
local flatStepper = Kit.Stepper(parent, function() return flatValue end, function(v) flatValue = v end,
    { min = 1, max = 60, step = 7, unit = "Tage" })
expect(not flatStepper.native and not flatStepper.slider, "flat stepper")
WoWMock.Click(flatStepper.plus)
expectEqual(flatValue, 28, "flat stepper steps")
expectEqual(flatStepper.value:GetText(), "28 Tage", "flat stepper shows it")
for _ = 1, 10 do WoWMock.Click(flatStepper.plus) end
expectEqual(flatValue, 60, "flat stepper stops at max")
