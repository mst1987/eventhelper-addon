--[[
A stand-in for the WoW client API, just enough to load EventHelperSync outside
the game. Two flavours, picked by run.js through __FLAVOR:

  anniversary  TBC Anniversary (Classic style): global GetItemInfo and
               GetAddOnMetadata, UIDropDownMenu, FauxScrollFrame,
               GameTooltip:HookScript("OnTooltipSetItem").
  forever      WoW Forever (Retail/Midnight based, Interface 16001): no such
               globals, only C_Item / C_AddOns; TooltipDataProcessor and
               MenuUtil; unknown events throw on RegisterEvent; the classic
               templates are left out on purpose, so the fallbacks get run.

Deliberately explicit: a widget method or global the addon calls that is not
here fails with "attempt to call a nil value" - the signal to add it, and to
check that the real clients have it.
]]

WoWMock = {
    flavor = __FLAVOR or "anniversary",
    now = 1791240000,
    prints = {},
    frames = {},
    items = {},
    shift = false,
    reloaded = false,
    postCalls = {},
}
local FOREVER = WoWMock.flavor == "forever"

unpack = unpack or table.unpack

-- Events both clients know. Forever throws on anything else; Anniversary
-- accepts it silently. COMBAT_LOG_EVENT_UNFILTERED is forbidden on Forever.
local KNOWN_EVENTS = {
    ADDON_LOADED = true, PLAYER_LOGIN = true, PLAYER_LOGOUT = true, PLAYER_ENTERING_WORLD = true,
    ZONE_CHANGED_NEW_AREA = true, ENCOUNTER_END = true, PLAYER_REGEN_DISABLED = true,
    PLAYER_REGEN_ENABLED = true,
    -- the guild bank on both (Forever has no GUILDBANKFRAME_*)
    PLAYER_INTERACTION_MANAGER_FRAME_SHOW = true, PLAYER_INTERACTION_MANAGER_FRAME_HIDE = true,
    GUILDBANKBAGSLOTS_CHANGED = true,
}

local TEMPLATES = {
    BasicFrameTemplateWithInset = true, UIPanelButtonTemplate = true, UICheckButtonTemplate = true,
    InputBoxTemplate = true, UIPanelScrollFrameTemplate = true, BackdropTemplate = true,
}
if not FOREVER then
    TEMPLATES.UIDropDownMenuTemplate = true
    TEMPLATES.FauxScrollFrameTemplate = true
end

-- Widget methods that only have to exist.
local NOOP = {}
for _, name in ipairs({
    "SetSize", "SetAllPoints", "SetFrameStrata", "SetFrameLevel", "RegisterForClicks", "RegisterForDrag",
    "SetMovable", "EnableMouse", "EnableMouseWheel", "SetClampedToScreen", "StartMoving", "StopMovingOrSizing",
    "SetTexture", "SetTexCoord", "SetVertexColor", "SetColorTexture", "SetJustifyH", "SetJustifyV",
    "SetWordWrap", "SetFontObject", "SetMultiLine", "SetAutoFocus", "SetNumeric", "SetMaxLetters",
    "ClearFocus", "SetFocus", "HighlightText", "SetScrollChild", "SetHighlightTexture", "SetEnabled",
    "Enable", "Disable", "SetScale", "UnregisterEvent",
}) do
    NOOP[name] = function() end
end

local Widget = {}
local WidgetMT = {
    __index = function(_, key)
        return Widget[key] or NOOP[key]
    end,
}

local function newWidget(kind, name, parent)
    local w = setmetatable({
        -- Internal fields carry "__" so they never clash with what the addon
        -- stores on its frames (row.name, box.text, ...).
        __kind = kind, __parent = parent, __scripts = {}, __hooks = {}, __events = {}, __shown = true,
        __points = {}, __width = 0, __height = 0, __alpha = 1, __lines = {},
    }, WidgetMT)
    if type(name) == "string" then
        if parent and name:find("$parent", 1, true) then
            name = name:gsub("%$parent", parent.__name or "")
        end
        w.__name = name
        _G[name] = w
    end
    WoWMock.frames[#WoWMock.frames + 1] = w
    return w
end
WoWMock.newWidget = newWidget

function Widget:GetName() return self.__name end
function Widget:GetParent() return self.__parent end
function Widget:SetScript(script, fn) self.__scripts[script] = fn end
function Widget:GetScript(script) return self.__scripts[script] end
function Widget:HookScript(script, fn)
    if FOREVER and script == "OnTooltipSetItem" then
        error(("%s doesn't have a \"%s\" script"):format(tostring(self.__name), script))
    end
    self.__hooks[script] = self.__hooks[script] or {}
    table.insert(self.__hooks[script], fn)
end
function Widget:RegisterEvent(event)
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then error("ADDON_ACTION_FORBIDDEN") end
    if FOREVER and not KNOWN_EVENTS[event] then
        error(("Attempt to register unknown event \"%s\""):format(event))
    end
    self.__events[event] = true
end
function Widget:Show() self.__shown = true end
function Widget:Hide() self.__shown = false end
function Widget:SetShown(shown) self.__shown = shown and true or false end
function Widget:IsShown() return self.__shown end
function Widget:SetText(text) self.__text = text end
function Widget:GetText() return self.__text end
function Widget:SetTextColor(r, g, b) self.__color = { r, g, b } end
function Widget:SetAlpha(a) self.__alpha = a end
function Widget:SetWidth(w) self.__width = w end
function Widget:SetHeight(h) self.__height = h end
function Widget:GetWidth() return self.__width end
function Widget:GetHeight() return self.__height end
function Widget:GetStringWidth() return #(self.__text or "") * 6 end
function Widget:SetPoint(point, a, b, c, d)
    self.__points[#self.__points + 1] = { point, a, b, c, d }
end
function Widget:ClearAllPoints() self.__points = {} end
function Widget:GetPoint()
    local p = self.__points[1]
    if not p then return nil end
    -- SetPoint(point, relativeTo, relativePoint, x, y) or SetPoint(point, x, y)
    if type(p[2]) == "number" then return p[1], nil, p[1], p[2], p[3] end
    return p[1], p[2], p[3], p[4], p[5]
end
function Widget:SetChecked(checked) self.__checked = checked and true or false end
function Widget:GetChecked() return self.__checked end
function Widget:CreateTexture(name, layer) local t = newWidget("Texture", name, self) t.__layer = layer return t end
function Widget:CreateFontString(name, layer, font) local t = newWidget("FontString", name, self) t.__font = font return t end

-- Tooltips ---------------------------------------------------------------------------------

function Widget:SetOwner(owner) self.__owner = owner end
function Widget:ClearLines()
    self.__lines = {}
end
local function addTooltipLine(self, left, right)
    self.__lines[#self.__lines + 1] = { left = left, right = right }
    local n = #self.__lines
    local name = self.__name or "Tooltip"
    local fs = _G[name .. "TextLeft" .. n] or newWidget("FontString", name .. "TextLeft" .. n, self)
    fs.__text = left
end
function Widget:AddLine(text) addTooltipLine(self, text) end
function Widget:AddDoubleLine(left, right) addTooltipLine(self, left, right) end
function Widget:NumLines() return #self.__lines end
function Widget:GetItem() return self.__itemName, self.__itemLink end

--- Plain text of all tooltip lines (colour codes removed), for assertions.
function WoWMock.TooltipText(tooltip)
    local out = {}
    for _, line in ipairs(tooltip.__lines) do
        local text = tostring(line.left or "")
        if line.right then text = text .. " | " .. tostring(line.right) end
        out[#out + 1] = (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
    end
    return table.concat(out, "\n")
end

--- What the client does when an item tooltip is set: the item line, then the
--- addon hooks of this flavour.
function WoWMock.ShowItem(tooltip, itemId)
    tooltip:ClearLines()
    local item = WoWMock.items[itemId] or { name = "Item " .. itemId }
    tooltip.__itemName = item.name
    tooltip.__itemLink = ("|cffa335ee|Hitem:%d::::::::70:::::|h[%s]|h|r"):format(itemId, item.name)
    tooltip:AddLine(item.name)
    if FOREVER then
        for _, fn in ipairs(WoWMock.postCalls[Enum.TooltipDataType.Item] or {}) do
            fn(tooltip, { type = Enum.TooltipDataType.Item, id = itemId })
        end
    else
        for _, fn in ipairs(tooltip.__hooks.OnTooltipSetItem or {}) do fn(tooltip) end
    end
end

-- Frames ------------------------------------------------------------------------------------

function CreateFrame(kind, name, parent, template)
    if template and not TEMPLATES[template] then
        error(("CreateFrame: Couldn't find inherited node \"%s\""):format(template))
    end
    local w = newWidget(kind, name, parent)
    w.__template = template
    return w
end

UIParent = newWidget("Frame", "UIParent")
Minimap = newWidget("Frame", "Minimap")
function Minimap:GetCenter() return 0, 0 end
function Minimap:GetEffectiveScale() return 1 end
GameTooltip = newWidget("GameTooltip", "GameTooltip")
ItemRefTooltip = newWidget("GameTooltip", "ItemRefTooltip")
ChatFontNormal = {}

--- Fire an event at every frame that registered it.
function WoWMock.Fire(event, ...)
    for _, frame in ipairs(WoWMock.frames) do
        if frame.__events[event] and frame.__scripts.OnEvent then
            frame.__scripts.OnEvent(frame, event, ...)
        end
    end
end

function WoWMock.Click(widget, button)
    assert(widget.__scripts.OnClick, "widget has no OnClick")
    widget.__scripts.OnClick(widget, button or "LeftButton")
end

function WoWMock.Run(widget, script, ...)
    assert(widget.__scripts[script], "widget has no " .. script)
    return widget.__scripts[script](widget, ...)
end

-- Globals -----------------------------------------------------------------------------------

UISpecialFrames = {}
SlashCmdList = {}
RAID_CLASS_COLORS = {
    PRIEST = { r = 1, g = 1, b = 1 }, MAGE = { r = 0.25, g = 0.78, b = 0.92 },
    SHAMAN = { r = 0, g = 0.44, b = 0.87 }, DRUID = { r = 1, g = 0.49, b = 0.04 },
}

function print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    WoWMock.prints[#WoWMock.prints + 1] = table.concat(parts, " ")
end

function time(t)
    if t then return os.time(t) end
    return WoWMock.now
end
date = os.date
tinsert = table.insert
strlower = string.lower
function strtrim(s) return (tostring(s):gsub("^%s+", ""):gsub("%s+$", "")) end
function strsplit(sep, text, limit)
    local out, start = {}, 1
    while true do
        if limit and #out == limit - 1 then break end
        local i = text:find(sep, start, true)
        if not i then break end
        out[#out + 1] = text:sub(start, i - 1)
        start = i + #sep
    end
    out[#out + 1] = text:sub(start)
    return unpack(out)
end

function InCombatLockdown() return false end
function IsShiftKeyDown() return WoWMock.shift end
function IsControlKeyDown() return WoWMock.ctrl end
function GetGuildInfo(unit) if unit == "player" then return WoWMock.guild end end
function UnitName() return "Gemli" end
function GetRealmName() return "Thunderstrike" end
function UnitFactionGroup() return "Alliance" end
function GetInstanceInfo() return "", "none" end
function GetCursorPosition() return 0, 0 end
function ReloadUI() WoWMock.reloaded = true end

C_Timer = {}
function C_Timer.NewTicker(_, fn) return { fn = fn, Cancel = function() end } end
function C_Timer.After(_, fn) fn() end

local function itemInfo(id)
    local item = WoWMock.items[tonumber(id)]
    if not item then return nil end
    return item.name, ("|cffa335ee|Hitem:%d|h[%s]|h|r"):format(id, item.name)
end

local function metadata(addon, field)
    if addon == "EventHelperSync" and field == "Version" then return __TOC_VERSION end
    return nil
end

if FOREVER then
    WOW_PROJECT_ID, WOW_PROJECT_MAINLINE = 1, 1
    Enum = { TooltipDataType = { Item = 0, Spell = 1 }, PlayerInteractionType = { GuildBanker = 10 } }
    C_Item = { GetItemInfo = itemInfo }
    C_AddOns = { GetAddOnMetadata = metadata }
    TooltipDataProcessor = {}
    function TooltipDataProcessor.AddTooltipPostCall(kind, fn)
        WoWMock.postCalls[kind] = WoWMock.postCalls[kind] or {}
        table.insert(WoWMock.postCalls[kind], fn)
    end
    function issecretvalue() return false end
    MenuUtil = {}
    function MenuUtil.CreateContextMenu(owner, generator)
        local root = { entries = {} }
        function root:CreateRadio(text, isSelected, setSelected)
            self.entries[#self.entries + 1] = { text = text, isSelected = isSelected, setSelected = setSelected }
        end
        function root:CreateButton(text, callback)
            self.entries[#self.entries + 1] = { text = text, callback = callback }
        end
        function root:CreateTitle(text) self.entries[#self.entries + 1] = { title = text } end
        generator(owner, root)
        MenuUtil.lastMenu = root
        return root
    end
else
    WOW_PROJECT_ID, WOW_PROJECT_MAINLINE = 5, 1
    Enum = {}
    GetItemInfo = itemInfo
    GetAddOnMetadata = metadata

    WoWMock.dropdown = { buttons = {} }
    function UIDropDownMenu_SetWidth() end
    function UIDropDownMenu_Initialize(frame, fn) frame.initialize = fn end
    function UIDropDownMenu_CreateInfo() return {} end
    function UIDropDownMenu_AddButton(info) table.insert(WoWMock.dropdown.buttons, info) end
    function UIDropDownMenu_SetSelectedValue(frame, value) frame.selectedValue = value end
    function UIDropDownMenu_SetText(frame, text) frame.__text = text end

    function FauxScrollFrame_Update(frame, total) frame.total = total end
    function FauxScrollFrame_GetOffset(frame) return frame.fauxOffset or 0 end
    function FauxScrollFrame_OnVerticalScroll(frame, value, rowHeight, update)
        frame.fauxOffset = math.floor(value / rowHeight)
        update()
    end
end

-- Assertions ----------------------------------------------------------------------------------

__ASSERTIONS = 0
function expect(condition, message)
    __ASSERTIONS = __ASSERTIONS + 1
    if not condition then error("expectation failed: " .. tostring(message), 2) end
end
function expectEqual(actual, expected, label)
    __ASSERTIONS = __ASSERTIONS + 1
    if actual ~= expected then
        error(("%s: expected %s, got %s"):format(tostring(label), tostring(expected), tostring(actual)), 2)
    end
end
--- The text without WoW colour codes.
function plain(text)
    return (tostring(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end
