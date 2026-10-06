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
-- Lua 5.1 (the game) has math.atan2, fengari (5.3) only the two-argument math.atan
math.atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

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
    "SetAllPoints", "SetFrameStrata", "SetFrameLevel", "RegisterForClicks", "RegisterForDrag",
    "SetMovable", "EnableMouse", "EnableMouseWheel", "SetClampedToScreen", "StartMoving", "StopMovingOrSizing",
    "SetTexCoord", "SetVertexColor", "SetColorTexture", "SetJustifyH", "SetJustifyV",
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
function Widget:SetSize(w, h) self.__width, self.__height = w, h end
function Widget:SetTexture(texture) self.__texture = texture end
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
function GetCursorPosition() return WoWMock.cursorX or 0, WoWMock.cursorY or 0 end
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

-- Bags, cursor and mail ---------------------------------------------------------------------
-- Immediate (no locks, no delays; ../mock/wow.lua has the slow client).
-- Anniversary: the old bag globals and SendMailBodyEditBox; Forever:
-- C_Container only and the scrolling MailEditBox. WoWMock.mailBlock = true
-- makes the item calls raise, as a client that forbids them.

for _, event in ipairs({ "MAIL_SHOW", "MAIL_CLOSED", "MAIL_SEND_SUCCESS", "MAIL_FAILED", "MAIL_SEND_INFO_UPDATE",
    "BAG_UPDATE_DELAYED", "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN" }) do
    KNOWN_EVENTS[event] = true
end
Enum.PlayerInteractionType = Enum.PlayerInteractionType or {}
Enum.PlayerInteractionType.MailInfo = 17
ATTACHMENTS_MAX_SEND = 12
NUM_BAG_SLOTS = 4

function Widget:SetID(id) self.__id = id end
function Widget:GetID() return self.__id or 0 end
function Widget:GetInputText() return self.__text end

WoWMock.bags = {}
WoWMock.cursor = nil
WoWMock.attachments = {}
WoWMock.sendCalls = {}
WoWMock.addonSendCalls = 0

local function bagSlot(bag, slot)
    local b = WoWMock.bags[bag]
    return b and b.slots[slot] or nil
end

local function mailItemLink(id)
    return ("|cffffffff|Hitem:%d|h[Item %d]|h|r"):format(id, id)
end

local function guard(fname)
    if WoWMock.mailBlock then error("Interface action failed because of an AddOn: " .. fname) end
end

local function numSlots(bag) return WoWMock.bags[bag] and WoWMock.bags[bag].size or 0 end
local function numFree(bag)
    local b = WoWMock.bags[bag]
    if not b then return 0, 0 end
    local free = 0
    for slot = 1, b.size do if not b.slots[slot] then free = free + 1 end end
    return free, 0
end
local function pickup(bag, slot)
    guard("PickupContainerItem")
    local item, cursor = bagSlot(bag, slot), WoWMock.cursor
    if not cursor then
        if item then WoWMock.cursor = { id = item.id, count = item.count, bag = bag, slot = slot } end
    elseif not item then
        WoWMock.bags[bag].slots[slot] = { id = cursor.id, count = cursor.count }
        if cursor.bankTab then
            WoWMock.BankTook(cursor.bankTab, cursor.bankSlot, cursor.count)
        elseif cursor.split then
            bagSlot(cursor.bag, cursor.slot).count = bagSlot(cursor.bag, cursor.slot).count - cursor.count
        else
            WoWMock.bags[cursor.bag].slots[cursor.slot] = nil
        end
        WoWMock.cursor = nil
    end
end
local function split(bag, slot, count)
    guard("SplitContainerItem")
    local item = bagSlot(bag, slot)
    if item and not WoWMock.cursor and count < item.count then
        WoWMock.cursor = { id = item.id, count = count, bag = bag, slot = slot, split = true }
    end
end

if FOREVER then
    C_Container = {
        GetContainerNumSlots = numSlots, GetContainerNumFreeSlots = numFree,
        PickupContainerItem = pickup, SplitContainerItem = split,
        GetContainerItemInfo = function(bag, slot)
            local item = bagSlot(bag, slot)
            if not item then return nil end
            return { stackCount = item.count, isLocked = false, itemID = item.id, hyperlink = mailItemLink(item.id), isBound = false }
        end,
    }
else
    GetContainerNumSlots, GetContainerNumFreeSlots = numSlots, numFree
    PickupContainerItem, SplitContainerItem = pickup, split
    function GetContainerItemInfo(bag, slot)
        local item = bagSlot(bag, slot)
        if not item then return nil end
        return 134400, item.count, false, 1, false, false, mailItemLink(item.id), false, false, item.id
    end
end

--- { [bag] = { [slot] = { id, count } } }, bags 0-4 with 16 slots each.
function WoWMock.SetBags(content)
    WoWMock.bags = {}
    for bag = 0, 4 do
        WoWMock.bags[bag] = { size = 16, slots = {} }
        for slot, item in pairs(content[bag] or {}) do
            WoWMock.bags[bag].slots[slot] = { id = item[1], count = item[2] }
        end
    end
end

function CursorHasItem() return WoWMock.cursor ~= nil end
function ClearCursor() WoWMock.cursor = nil end

-- The guild bank (immediate) ------------------------------------------------------------------
-- WoWMock.bank.tabs[i] = { name, remaining (-1 = unlimited), slots = { [slot] = { id, count } } };
-- WoWMock.bankBlock = true makes the withdraw calls raise. Calls are listed in
-- WoWMock.bank.calls. The bag frames of the guild bank: Anniversary has
-- GuildBankColumnXButtonY, Forever GuildBankFrame.Columns[x].Buttons[y].

WoWMock.bank = { tabs = {}, current = 1, calls = {}, queries = {} }

local function bankItem(tab, slot)
    local t = WoWMock.bank.tabs[tab]
    return t and t.slots[slot] or nil
end

local function bankGuard(fname)
    table.insert(WoWMock.bank.calls, fname)
    if WoWMock.bankBlock then error("Interface action failed because of an AddOn: " .. fname) end
end

function WoWMock.BankTook(tab, slot, count)
    local t = WoWMock.bank.tabs[tab]
    local item = t.slots[slot]
    item.count = item.count - count
    if item.count <= 0 then t.slots[slot] = nil end
    if t.remaining and t.remaining > 0 then t.remaining = t.remaining - 1 end
end

function GetNumGuildBankTabs() return #WoWMock.bank.tabs end
function GetGuildBankTabInfo(tab)
    local t = WoWMock.bank.tabs[tab]
    if not t then return nil end
    local remaining = t.remaining or -1
    -- name, icon, isViewable, canDeposit, numWithdrawals, remainingWithdrawals
    return t.name, 133784, true, true, remaining < 0 and -1 or 10, remaining
end
function GetGuildBankItemLink(tab, slot)
    local item = bankItem(tab, slot)
    return item and mailItemLink(item.id) or nil
end
function GetGuildBankItemInfo(tab, slot)
    local item = bankItem(tab, slot)
    if not item then return nil, 0, false end
    return 134400, item.count, false, false, 1
end
function GetGuildBankMoney() return 0 end
function GetCurrentGuildBankTab() return WoWMock.bank.current end
function QueryGuildBankTab(tab)
    table.insert(WoWMock.bank.queries, tab)
    WoWMock.Fire("GUILDBANKBAGSLOTS_CHANGED")
end
function AutoStoreGuildBankItem(tab, slot)
    bankGuard("AutoStoreGuildBankItem")
    local item = bankItem(tab, slot)
    if not item or WoWMock.bank.tabs[tab].remaining == 0 then return end
    for bag = 0, 4 do
        local b = WoWMock.bags[bag]
        for s = 1, b and b.size or 0 do
            if not b.slots[s] then
                b.slots[s] = { id = item.id, count = item.count }
                WoWMock.BankTook(tab, slot, item.count)
                return
            end
        end
    end
end
function SplitGuildBankItem(tab, slot, count)
    bankGuard("SplitGuildBankItem")
    local item = bankItem(tab, slot)
    if item and not WoWMock.cursor and count < item.count and WoWMock.bank.tabs[tab].remaining ~= 0 then
        WoWMock.cursor = { id = item.id, count = count, bankTab = tab, bankSlot = slot, split = true }
    end
end

WoWMock.bankButtons = {}
if FOREVER then
    GuildBankFrame = newWidget("Frame", "GuildBankFrame")
    GuildBankFrame.Columns = {}
    for column = 1, 7 do
        GuildBankFrame.Columns[column] = { Buttons = {} }
        for index = 1, 14 do
            local button = newWidget("Button", nil, GuildBankFrame)
            GuildBankFrame.Columns[column].Buttons[index] = button
            WoWMock.bankButtons[(column - 1) * 14 + index] = button
        end
    end
else
    for column = 1, 7 do
        for index = 1, 14 do
            WoWMock.bankButtons[(column - 1) * 14 + index] =
                newWidget("Button", "GuildBankColumn" .. column .. "Button" .. index)
        end
    end
end

function ClickSendMailItemButton(index, clear)
    guard("ClickSendMailItemButton")
    if clear then
        WoWMock.attachments[index] = nil
        return
    end
    local cursor = WoWMock.cursor
    if not cursor then return end
    WoWMock.cursor = nil
    WoWMock.attachments[index] = { id = cursor.id, count = cursor.count, bag = cursor.bag, slot = cursor.slot }
end
function GetSendMailItem(index)
    local a = WoWMock.attachments[index]
    if not a then return nil end
    return "Item " .. a.id, a.id, 134400, a.count, 1, true
end
function GetSendMailItemLink(index)
    local a = WoWMock.attachments[index]
    return a and mailItemLink(a.id) or nil
end

-- the send frame
MailFrameTab2 = newWidget("Button", "MailFrameTab2")
WoWMock.mailTab = 1
function MailFrameTab_OnClick(_, tab) WoWMock.mailTab = tab end
newWidget("EditBox", "SendMailNameEditBox")
newWidget("EditBox", "SendMailSubjectEditBox")
if FOREVER then newWidget("EditBox", "MailEditBox") else newWidget("EditBox", "SendMailBodyEditBox") end

function SendMail(recipient, subject, body)
    WoWMock.sendCalls[#WoWMock.sendCalls + 1] = { recipient = recipient, subject = subject, body = body }
    if not WoWMock.playerClicking then WoWMock.addonSendCalls = WoWMock.addonSendCalls + 1 end
end

function hooksecurefunc(a, b, c)
    local tbl, name, fn = _G, a, b
    if type(a) == "table" then tbl, name, fn = a, b, c end
    local original = tbl[name]
    assert(type(original) == "function", "hooksecurefunc: no function " .. tostring(name))
    tbl[name] = function(...)
        local results = { original(...) }
        fn(...)
        return unpack(results)
    end
end

--- The player clicks "Senden", then the server confirms.
function WoWMock.SendAndConfirm()
    WoWMock.playerClicking = true
    local body = FOREVER and MailEditBox:GetInputText() or SendMailBodyEditBox:GetText()
    SendMail(SendMailNameEditBox:GetText(), SendMailSubjectEditBox:GetText(), body)
    WoWMock.playerClicking = false
    for index, a in pairs(WoWMock.attachments) do
        local item = bagSlot(a.bag, a.slot)
        if item then WoWMock.bags[a.bag].slots[a.slot] = nil end
        WoWMock.attachments[index] = nil
    end
    WoWMock.Fire("MAIL_SEND_SUCCESS")
end

function WoWMock.OpenMailbox()
    if FOREVER then
        WoWMock.Fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", Enum.PlayerInteractionType.MailInfo)
    else
        WoWMock.Fire("MAIL_SHOW")
    end
end
function WoWMock.CloseMailbox()
    if FOREVER then
        WoWMock.Fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", Enum.PlayerInteractionType.MailInfo)
    else
        WoWMock.Fire("MAIL_CLOSED")
    end
end

-- The bag frames: Anniversary has one frame per bag with named item buttons,
-- Forever the combined bag with EnumerateValidItems.
WoWMock.itemButtons = {}
if FOREVER then
    ContainerFrameCombinedBags = newWidget("Frame", "ContainerFrameCombinedBags")
    ContainerFrameCombinedBags.__shown = false
    for bag = 0, 4 do
        for slot = 1, 16 do
            local button = newWidget("Button", nil, ContainerFrameCombinedBags)
            button:SetID(slot)
            function button:GetBagID() return bag end
            WoWMock.itemButtons[bag .. ":" .. slot] = button
        end
    end
    function ContainerFrameCombinedBags:EnumerateValidItems()
        local list = {}
        for _, button in pairs(WoWMock.itemButtons) do list[#list + 1] = button end
        local i = 0
        return function()
            i = i + 1
            if list[i] then return i, list[i] end
        end
    end
    function WoWMock.ShowBags(shown) ContainerFrameCombinedBags.__shown = shown end
else
    local frames = {}
    for bag = 0, 4 do
        local f = newWidget("Frame", "ContainerFrame" .. (bag + 1))
        f:SetID(bag)
        f.__shown = false
        frames[#frames + 1] = f
        for slot = 1, 16 do
            -- the buttons run backwards, as in the game: Item1 is the last slot
            local button = newWidget("Button", "ContainerFrame" .. (bag + 1) .. "Item" .. (17 - slot), f)
            button:SetID(slot)
            WoWMock.itemButtons[bag .. ":" .. slot] = button
        end
    end
    function WoWMock.ShowBags(shown)
        for _, f in ipairs(frames) do f.__shown = shown end
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
