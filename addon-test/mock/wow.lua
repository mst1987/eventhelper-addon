--[[
A stand-in for the WoW client API, just enough for EventHelperSync to load and
for the specs to drive it outside the game. Events, time, timers, combat and
the guild bank are driven by the spec through the WoWMock table.

Deliberately explicit: an API the addon calls that is missing here fails with
"attempt to call a nil value", which is the signal to add it (and to double
check that the real clients have it).
]]

WoWMock = {
    now = 1784574000,
    inCombat = false,
    prints = {},
    frames = {},
    timers = {},
    reloads = 0,
    -- Events this client does not know: RegisterEvent raises for them, as the
    -- real client does ("Attempt to register unknown event").
    unknownEvents = {},
    player = { name = "Gemli", realm = "Thunderstrike", faction = "Alliance", guild = "Pulse" },
    build = { version = "2.5.5", build = "65000", date = "Sep 1 2026", interface = 20505 },
    -- The guild bank: tabs = { { name, viewable, cached, slots = { [slot] = { id, count } } } }.
    -- respondAfter: seconds until GUILDBANKBAGSLOTS_CHANGED follows a query,
    -- false = the server never answers. A tab's slots are only readable once
    -- it is cached (answered, or cached = true from the start).
    guildBank = { money = 0, tabs = {}, respondAfter = 0.25 },
    queries = {},
}

-- Assertions ------------------------------------------------------------------------------

__ASSERTIONS = 0
function expect(condition, message, ...)
    __ASSERTIONS = __ASSERTIONS + 1
    if not condition then
        error("expectation failed: " .. string.format(tostring(message), ...), 2)
    end
end
function expectEqual(actual, expected, label)
    __ASSERTIONS = __ASSERTIONS + 1
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", label or "value", tostring(expected), tostring(actual)), 2)
    end
end

-- Lua 5.1 globals the game has ----------------------------------------------------------

unpack = unpack or table.unpack
date = os.date
-- whole seconds, like the game
function time() return math.floor(WoWMock.now) end
function GetTime() return WoWMock.now end
function strtrim(s) return (tostring(s):gsub("^%s+", ""):gsub("%s+$", "")) end
function strlower(s) return string.lower(s) end
function strsplit(sep, text, limit)
    local parts, start = {}, 1
    while true do
        if limit and #parts == limit - 1 then break end
        local i, j = string.find(text, sep, start, true)
        if not i then break end
        parts[#parts + 1] = string.sub(text, start, i - 1)
        start = j + 1
    end
    parts[#parts + 1] = string.sub(text, start)
    return unpack(parts)
end

function print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    WoWMock.prints[#WoWMock.prints + 1] = table.concat(parts, " ")
end

--- The last chat line containing `text`, or nil.
function WoWMock.printed(text)
    for i = #WoWMock.prints, 1, -1 do
        if string.find(WoWMock.prints[i], text, 1, true) then return WoWMock.prints[i] end
    end
    return nil
end

-- Client basics ---------------------------------------------------------------------------

SlashCmdList = {}
Enum = { PlayerInteractionType = { GuildBanker = 10 } }
WOW_PROJECT_ID = 5

function GetAddOnMetadata(_, field)
    if field == "Version" then return "1.8.0" end
    return nil
end
function InCombatLockdown() return WoWMock.inCombat end
function ReloadUI() WoWMock.reloads = WoWMock.reloads + 1 end
function UnitName(unit) if unit == "player" then return WoWMock.player.name end end
function GetRealmName() return WoWMock.player.realm end
function GetNormalizedRealmName() return WoWMock.player.realm end
function UnitFactionGroup(unit) if unit == "player" then return WoWMock.player.faction end end
function GetGuildInfo(unit) if unit == "player" then return WoWMock.player.guild, "Officer", 1 end end
function GetBuildInfo()
    local b = WoWMock.build
    return b.version, b.build, b.date, b.interface
end
function GetInstanceInfo() return "", "none" end

-- Frames and events -----------------------------------------------------------------------

local FRAME = {}
FRAME.__index = function(_, key)
    -- Any widget method the specs do not care about is a no-op.
    return FRAME[key] or function() end
end
function FRAME:RegisterEvent(event)
    if WoWMock.unknownEvents[event] then
        error('Attempt to register unknown event "' .. event .. '"')
    end
    self.events[event] = true
end
function FRAME:UnregisterEvent(event) self.events[event] = nil end
function FRAME:SetScript(name, fn) self.scripts[name] = fn end
function FRAME:GetScript(name) return self.scripts[name] end
function FRAME:IsShown() return false end

function CreateFrame(kind, name)
    local frame = setmetatable({ kind = kind, name = name, events = {}, scripts = {} }, FRAME)
    WoWMock.frames[#WoWMock.frames + 1] = frame
    if name then _G[name] = frame end
    return frame
end

--- Fire an event at every frame that registered it.
function WoWMock.fire(event, ...)
    for _, frame in ipairs(WoWMock.frames) do
        local handler = frame.scripts.OnEvent
        if frame.events[event] and handler then handler(frame, event, ...) end
    end
end

--- Whether any frame registered `event`.
function WoWMock.registered(event)
    for _, frame in ipairs(WoWMock.frames) do
        if frame.events[event] then return true end
    end
    return false
end

-- Timers ----------------------------------------------------------------------------------

local function schedule(seconds, fn, interval)
    local timer = { at = WoWMock.now + seconds, fn = fn, interval = interval }
    WoWMock.timers[#WoWMock.timers + 1] = timer
    return timer
end

C_Timer = {
    After = function(seconds, fn) schedule(seconds, fn) end,
    NewTicker = function(seconds, fn)
        local timer = schedule(seconds, fn, seconds)
        return { Cancel = function() timer.cancelled = true end }
    end,
}

--- Let `seconds` pass, running every timer that comes due, in order.
function WoWMock.advance(seconds)
    local target = WoWMock.now + seconds
    while true do
        local nextTimer, nextIndex
        for i, timer in ipairs(WoWMock.timers) do
            if timer.at <= target and (not nextTimer or timer.at < nextTimer.at) then
                nextTimer, nextIndex = timer, i
            end
        end
        if not nextTimer then break end
        table.remove(WoWMock.timers, nextIndex)
        WoWMock.now = nextTimer.at
        if not nextTimer.cancelled then
            if nextTimer.interval then
                schedule(nextTimer.interval, nextTimer.fn, nextTimer.interval)
            end
            nextTimer.fn()
        end
    end
    WoWMock.now = target
end

-- Guild bank ------------------------------------------------------------------------------

local function bankTab(tab)
    return WoWMock.guildBank.tabs[tab]
end

function GetNumGuildBankTabs() return #WoWMock.guildBank.tabs end
function GetGuildBankTabInfo(tab)
    local t = bankTab(tab)
    if not t then return nil end
    -- name, icon, isViewable, canDeposit, numWithdrawals, remainingWithdrawals
    return t.name, 133784, t.viewable ~= false, true, 0, 0
end
function GetGuildBankMoney() return WoWMock.guildBank.money end

function QueryGuildBankTab(tab)
    WoWMock.queries[#WoWMock.queries + 1] = tab
    local delay = WoWMock.guildBank.respondAfter
    if delay then
        schedule(delay, function()
            local t = bankTab(tab)
            if t then t.cached = true end
            WoWMock.fire("GUILDBANKBAGSLOTS_CHANGED")
        end)
    end
end

local function bankSlot(tab, slot)
    local t = bankTab(tab)
    if not t or not t.cached then return nil end
    return t.slots[slot]
end

function GetGuildBankItemLink(tab, slot)
    local item = bankSlot(tab, slot)
    if not item then return nil end
    if item.pet then
        return "|cff0070dd|Hbattlepet:" .. item.pet .. ":1:3:150:12:10:0x0|h[Pet]|h|r"
    end
    return "|cff1eff00|Hitem:" .. item.id .. "::::::::70:::::|h[Item " .. item.id .. "]|h|r"
end

function GetGuildBankItemInfo(tab, slot)
    local item = bankSlot(tab, slot)
    if not item then return nil, 0, false end
    -- texture, itemCount, locked, isFiltered, quality
    return 134400, item.count or 1, false, false, 2
end

--- Open the guild bank the way the given client family does.
function WoWMock.openGuildBank(path)
    if path == "retail" then
        WoWMock.fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", Enum.PlayerInteractionType.GuildBanker)
    else
        WoWMock.fire("GUILDBANKFRAME_OPENED")
    end
end

function WoWMock.closeGuildBank(path)
    if path == "retail" then
        WoWMock.fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", Enum.PlayerInteractionType.GuildBanker)
    else
        WoWMock.fire("GUILDBANKFRAME_CLOSED")
    end
end

-- Bags, cursor and mail ------------------------------------------------------------------
--
-- WoWMock.bags[bag] = { size, family, slots = { [slot] = { id, count, locked, bound } } }
-- An item that is picked up or attached stays in its slot, locked (as in the
-- game: it leaves the bags when the mail is sent). A split stack leaves the
-- source locked until it is put down; putting it into an empty slot makes a
-- new stack there, locked for `mail.unlockAfter` seconds (0 = at once).
-- Attachments show up after `mail.attachAfter` seconds (0 = at once).
-- `mail.block`: nil | "error" (the item calls raise) | "event" (they do nothing
-- and ADDON_ACTION_BLOCKED fires) | "silent" (they just do nothing).

ATTACHMENTS_MAX_SEND = 12
NUM_BAG_SLOTS = 4
Enum.PlayerInteractionType.MailInfo = 17

WoWMock.bags = {}
WoWMock.cursor = nil
WoWMock.items = {}
WoWMock.mail = {
    attachments = {}, tab = 1, attachAfter = 0, unlockAfter = 0, block = nil,
    sendCalls = {}, addonSendCalls = 0, calls = {},
}

local function bagSlot(bag, slot)
    local b = WoWMock.bags[bag]
    return b and b.slots[slot] or nil
end

local function itemName(id)
    return (WoWMock.items[id] and WoWMock.items[id].name) or ("Item " .. id)
end

local function itemLink(id)
    return "|cffffffff|Hitem:" .. id .. "::::::::70:::::|h[" .. itemName(id) .. "]|h|r"
end

local function unlockLater(item)
    local delay = WoWMock.mail.unlockAfter
    if delay and delay > 0 then
        schedule(delay, function() item.locked = false end)
    else
        item.locked = false
    end
end

--- Whether an item call of the addon is blocked; raises in "error" mode.
local function blocked(fname)
    WoWMock.mail.calls[#WoWMock.mail.calls + 1] = fname
    local mode = WoWMock.mail.block
    if mode == "error" then error("Interface action failed because of an AddOn") end
    if mode == "event" then
        WoWMock.fire("ADDON_ACTION_BLOCKED", "EventHelperSync", fname)
        return true
    end
    return mode == "silent"
end

local function numSlots(bag)
    local b = WoWMock.bags[bag]
    return b and b.size or 0
end

local function numFree(bag)
    local b = WoWMock.bags[bag]
    if not b then return 0, 0 end
    local free = 0
    for slot = 1, b.size do if not b.slots[slot] then free = free + 1 end end
    return free, b.family or 0
end

local function pickup(bag, slot)
    if blocked("PickupContainerItem") then return end
    local item = bagSlot(bag, slot)
    local cursor = WoWMock.cursor
    if not cursor then
        if item and not item.locked then
            item.locked = true
            WoWMock.cursor = { id = item.id, count = item.count, bag = bag, slot = slot }
        end
        return
    end
    if cursor.bag == bag and cursor.slot == slot and not cursor.split then
        -- put back
        item.locked = false
        WoWMock.cursor = nil
        return
    end
    if not item then
        local b = WoWMock.bags[bag]
        if not b or slot > b.size then return end
        local placed = { id = cursor.id, count = cursor.count, locked = true }
        b.slots[slot] = placed
        WoWMock.cursor = nil
        if cursor.split then
            local source = bagSlot(cursor.bag, cursor.slot)
            source.count = source.count - cursor.count
            unlockLater(source)
        else
            b.slots[slot] = placed
            WoWMock.bags[cursor.bag].slots[cursor.slot] = nil
        end
        unlockLater(placed)
    end
end

local function split(bag, slot, count)
    if blocked("SplitContainerItem") then return end
    local item = bagSlot(bag, slot)
    if WoWMock.cursor or not item or item.locked or count >= item.count then return end
    item.locked = true
    WoWMock.cursor = { id = item.id, count = count, bag = bag, slot = slot, split = true }
end

local function cItemInfo(bag, slot)
    local item = bagSlot(bag, slot)
    if not item then return nil end
    return { iconFileID = 134400, stackCount = item.count, isLocked = item.locked and true or false, quality = 1,
        hyperlink = itemLink(item.id), itemID = item.id, isBound = item.bound and true or false }
end

--- Which bag API the client has: "c_container" (Forever, modern Classic) or
--- "globals" (the old functions only).
function WoWMock.useBagApi(kind)
    WoWMock.bagApi = kind
    if kind == "c_container" then
        C_Container = {
            GetContainerNumSlots = numSlots, GetContainerNumFreeSlots = numFree, GetContainerItemInfo = cItemInfo,
            PickupContainerItem = pickup, SplitContainerItem = split,
            GetContainerItemLink = function(bag, slot)
                local item = bagSlot(bag, slot)
                return item and itemLink(item.id) or nil
            end,
        }
        GetContainerNumSlots, GetContainerNumFreeSlots, GetContainerItemInfo = nil, nil, nil
        PickupContainerItem, SplitContainerItem, GetContainerItemLink = nil, nil, nil
    else
        C_Container = nil
        GetContainerNumSlots, GetContainerNumFreeSlots = numSlots, numFree
        PickupContainerItem, SplitContainerItem = pickup, split
        function GetContainerItemInfo(bag, slot)
            local item = bagSlot(bag, slot)
            if not item then return nil end
            -- texture, count, locked, quality, readable, lootable, link, filtered, noValue, itemID
            return 134400, item.count, item.locked, 1, false, false, itemLink(item.id), false, false, item.id
        end
        function GetContainerItemLink(bag, slot)
            local item = bagSlot(bag, slot)
            return item and itemLink(item.id) or nil
        end
    end
end
WoWMock.useBagApi("globals")

--- Fill the bags: { [bag] = { [slot] = { id, count } } }, every bag 16 slots.
function WoWMock.setBags(content, sizes)
    WoWMock.bags = {}
    for bag = 0, 4 do
        WoWMock.bags[bag] = { size = (sizes and sizes[bag]) or 16, family = 0, slots = {} }
        for slot, item in pairs(content[bag] or {}) do
            WoWMock.bags[bag].slots[slot] = { id = item[1], count = item[2], bound = item.bound }
        end
    end
end

function CursorHasItem() return WoWMock.cursor ~= nil end
function ClearCursor()
    local cursor = WoWMock.cursor
    if not cursor then return end
    local source = bagSlot(cursor.bag, cursor.slot)
    if source then source.locked = false end
    WoWMock.cursor = nil
end

function ClickSendMailItemButton(index, clear)
    if blocked("ClickSendMailItemButton") then return end
    local mail = WoWMock.mail
    if clear then
        local a = mail.attachments[index]
        if a then
            local source = bagSlot(a.bag, a.slot)
            if source then
                if a.split then source.count = source.count + a.count end
                source.locked = false
            end
            mail.attachments[index] = nil
            WoWMock.fire("MAIL_SEND_INFO_UPDATE")
        end
        return
    end
    local cursor = WoWMock.cursor
    if not cursor then return end
    WoWMock.cursor = nil
    local attachment = { id = cursor.id, count = cursor.count, bag = cursor.bag, slot = cursor.slot,
        split = cursor.split, visible = false }
    if cursor.split then
        local source = bagSlot(cursor.bag, cursor.slot)
        source.count = source.count - cursor.count
        unlockLater(source)
    end
    mail.attachments[index] = attachment
    local function show()
        attachment.visible = true
        WoWMock.fire("MAIL_SEND_INFO_UPDATE")
    end
    if mail.attachAfter and mail.attachAfter > 0 then schedule(mail.attachAfter, show) else show() end
end

function GetSendMailItem(index)
    local a = WoWMock.mail.attachments[index]
    if not a or not a.visible then return nil end
    -- name, itemID, texture, count, quality, canUse
    return itemName(a.id), a.id, 134400, a.count, 1, true
end

function GetSendMailItemLink(index)
    local a = WoWMock.mail.attachments[index]
    if not a or not a.visible then return nil end
    return itemLink(a.id)
end

--- What the player drags in by hand (never blocked).
function WoWMock.playerAttach(index, bag, slot)
    local item = bagSlot(bag, slot)
    item.locked = true
    WoWMock.mail.attachments[index] = { id = item.id, count = item.count, bag = bag, slot = slot, visible = true }
    WoWMock.fire("MAIL_SEND_INFO_UPDATE")
end

-- The send frame
local function editBox(name)
    local box = { text = "" }
    function box:SetText(text) self.text = text end
    function box:GetText() return self.text end
    _G[name] = box
    return box
end
editBox("SendMailNameEditBox")
editBox("SendMailSubjectEditBox")
editBox("SendMailBodyEditBox")
MailFrameTab2 = { id = 2 }
function MailFrameTab_OnClick(_, tab) WoWMock.mail.tab = tab end

function SendMail(recipient, subject, body)
    local call = { recipient = recipient, subject = subject, body = body, byPlayer = WoWMock.playerClicking == true }
    table.insert(WoWMock.mail.sendCalls, call)
    if not call.byPlayer then WoWMock.mail.addonSendCalls = WoWMock.mail.addonSendCalls + 1 end
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

--- The player clicks "Senden": Blizzard's SendMailFrame_SendMail calls SendMail.
function WoWMock.clickSend()
    WoWMock.playerClicking = true
    SendMail(SendMailNameEditBox:GetText(), SendMailSubjectEditBox:GetText(), SendMailBodyEditBox:GetText())
    WoWMock.playerClicking = false
end

--- The server answers: the attached items leave the bags, the frame resets.
function WoWMock.mailSent()
    for index, a in pairs(WoWMock.mail.attachments) do
        if a.bag and not a.split then WoWMock.bags[a.bag].slots[a.slot] = nil end
        WoWMock.mail.attachments[index] = nil
    end
    WoWMock.fire("MAIL_SEND_SUCCESS")
    SendMailNameEditBox:SetText("")
    SendMailSubjectEditBox:SetText("")
    if SendMailBodyEditBox then SendMailBodyEditBox:SetText("") end
end

function WoWMock.openMailbox(path)
    if path == "retail" then
        WoWMock.fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", Enum.PlayerInteractionType.MailInfo)
    else
        WoWMock.fire("MAIL_SHOW")
    end
end

function WoWMock.closeMailbox(path)
    if path == "retail" then
        WoWMock.fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", Enum.PlayerInteractionType.MailInfo)
    else
        WoWMock.fire("MAIL_CLOSED")
    end
end

--- What the client does on login: load the SavedVariables, then the addon.
function WoWMock.login(savedVariables)
    EventHelperSyncDB = savedVariables
    WoWMock.fire("ADDON_LOADED", "EventHelperSync")
end
