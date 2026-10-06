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

--- What the client does on login: load the SavedVariables, then the addon.
function WoWMock.login(savedVariables)
    EventHelperSyncDB = savedVariables
    WoWMock.fire("ADDON_LOADED", "EventHelperSync")
end
