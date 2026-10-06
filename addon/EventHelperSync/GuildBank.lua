--[[
Guild bank scan ("eventhelper-guildbank", version 1).

Whenever someone with this addon opens the guild bank, its contents are read
and the latest scan is stored in EventHelperSyncDB.guildBank. The sync tool
uploads it to the EventHelper (POST /api/ingest/guildbank) once WoW has written
the SavedVariables, just like the loot export.

Opening is detected on both client families:
  - TBC/Classic: GUILDBANKFRAME_OPENED / GUILDBANKFRAME_CLOSED
  - Forever (Retail based): PLAYER_INTERACTION_MANAGER_FRAME_SHOW / _HIDE with
    Enum.PlayerInteractionType.GuildBanker
Each event is registered under pcall, a client that does not know one simply
skips it. Clients that know both fire both; the open flag dedupes that.

The server throttles guild bank queries, so the viewable tabs are queried one
after another: QueryGuildBankTab(tab), wait for GUILDBANKBAGSLOTS_CHANGED, read
the 98 slots, next tab. A timer per tab reads the tab anyway if the event never
comes (e.g. the client had the tab cached and did not ask the server again).

Never in combat, and every client call runs under pcall: a scan that breaks
must not break the guild bank window.
]]

local EHS = EventHelperSync

local FORMAT = "eventhelper-guildbank"
local VERSION = 1

local SLOTS_PER_TAB = 98
-- How long to wait for GUILDBANKBAGSLOTS_CHANGED before reading a tab anyway.
local TAB_TIMEOUT = 3
-- Pause between two tab queries, to stay below the server's throttle.
local QUERY_GAP = 0.5
-- Enum.PlayerInteractionType.GuildBanker, should a client lack the Enum table.
local GUILD_BANKER_FALLBACK = 10
-- WOW_PROJECT_ID -> client name used in the key of a guild bank.
local PROJECTS = { [1] = "forever", [2] = "classic", [5] = "tbc" }

-- Runtime state only, nothing of this is saved.
local bank = {
    open = false,
    openedAt = 0,   -- time() of the last open, to tell a scan of this visit
    scanning = false,
    queue = nil,    -- viewable tabs still to read: { { index, name }, ... }
    tabs = nil,     -- tabs read so far (wire format)
    waiting = nil,  -- the tab entry whose GUILDBANKBAGSLOTS_CHANGED is awaited
    token = 0,      -- invalidates timers of an earlier tab or scan
}

local function call(fn, ...)
    if type(fn) ~= "function" then return false end
    return pcall(fn, ...)
end

--- First return value of a client call, or nil if it is missing or fails.
local function try(fn, ...)
    local ok, value = call(fn, ...)
    if ok then return value end
    return nil
end

local function inCombat()
    local ok, combat = call(InCombatLockdown)
    return ok and combat == true
end

local function after(seconds, fn)
    if C_Timer and C_Timer.After then
        pcall(C_Timer.After, seconds, fn)
    else
        fn()
    end
end

local function guildBankerType()
    local enum = Enum and Enum.PlayerInteractionType
    return (enum and enum.GuildBanker) or GUILD_BANKER_FALLBACK
end

--- "tbc" | "forever" | "classic": from WOW_PROJECT_ID, else from the interface
-- number (Forever reports 16001, which is no Classic Era number).
local function clientProject(interface)
    local project = PROJECTS[tonumber(WOW_PROJECT_ID) or -1]
    if project then return project end
    interface = tonumber(interface) or 0
    if interface >= 20000 and interface < 30000 then return "tbc" end
    if interface >= 10000 and interface < 12000 then return "classic" end
    return "forever"
end

-- Listeners for open/close/scan (the handout list, GuildBankHandouts.lua).
local listeners = {}

--- Call every listener with ("open" | "close" | "scan"). A listener that
-- breaks must not break the guild bank.
local function notify(what)
    for _, fn in ipairs(listeners) do
        local ok, err = pcall(fn, what)
        if not ok then EHS:Debug("Gildenbank-Listener:", tostring(err)) end
    end
end

local function realmName()
    local realm = try(GetNormalizedRealmName)
    if not realm or realm == "" then
        realm = (try(GetRealmName) or ""):gsub("%s+", "")
    end
    return realm
end

local function itemIdFromLink(link)
    if type(link) ~= "string" then return nil end
    return tonumber(link:match("item:(%d+)"))
end

--- Read all slots of one tab. Battle pet cages and empty slots are skipped.
local function readTab(index)
    local items = {}
    for slot = 1, SLOTS_PER_TAB do
        local itemId = itemIdFromLink(try(GetGuildBankItemLink, index, slot))
        if itemId then
            local ok, _, count = call(GetGuildBankItemInfo, index, slot)
            count = ok and tonumber(count) or 0
            items[#items + 1] = { itemId = itemId, count = count > 0 and count or 1, slot = slot }
        end
    end
    return items
end

local function stopScan()
    bank.scanning = false
    bank.queue = nil
    bank.tabs = nil
    bank.waiting = nil
    bank.token = bank.token + 1
end

local function finishScan()
    local now = time()
    local ok, version, _, _, interface = call(GetBuildInfo)
    if not ok then version, interface = nil, nil end
    local name = try(UnitName, "player") or ""
    local realm = realmName()

    local tabs, count = bank.tabs, 0
    for _, tab in ipairs(tabs) do
        for _, item in ipairs(tab.items) do count = count + item.count end
    end

    EHS.db.guildBank = {
        format = FORMAT,
        version = VERSION,
        generatedAt = now,
        client = { project = clientProject(interface), build = version or "" },
        guild = {
            name = try(GetGuildInfo, "player") or "",
            realm = realm,
            faction = try(UnitFactionGroup, "player") or "",
        },
        scannedBy = realm ~= "" and (name .. "-" .. realm) or name,
        scannedAt = now,
        money = tonumber(try(GetGuildBankMoney)) or 0,
        tabs = tabs,
    }
    stopScan()

    EHS:Print(("Gildenbank gescannt: %d Tabs, %d Gegenstände. Speichern mit /ehs upload."):format(#tabs, count))
    notify("scan")
end

local queryNext

--- Store the awaited tab and go on with the next one.
local function readWaiting()
    local entry = bank.waiting
    if not entry then return end
    bank.waiting = nil
    bank.token = bank.token + 1
    bank.tabs[#bank.tabs + 1] = { index = entry.index, name = entry.name, items = readTab(entry.index) }
    if #bank.queue == 0 then
        finishScan()
    else
        local token = bank.token
        after(QUERY_GAP, function()
            if bank.token == token then queryNext() end
        end)
    end
end

queryNext = function()
    if not bank.scanning then return end
    if not bank.open or inCombat() then
        -- Half a scan would show the guild bank emptier than it is.
        stopScan()
        EHS:Print("Gildenbank-Scan abgebrochen.")
        return
    end
    local entry = table.remove(bank.queue, 1)
    bank.waiting = entry
    bank.token = bank.token + 1
    local token = bank.token
    call(QueryGuildBankTab, entry.index)
    after(TAB_TIMEOUT, function()
        if bank.token == token and bank.waiting == entry then
            EHS:Debug(("Gildenbank: Tab %d ohne Antwort, lese den Stand im Cache."):format(entry.index))
            readWaiting()
        end
    end)
end

--- Start a scan of all viewable tabs. Needs the guild bank to be open.
-- @return boolean whether a scan was started
function EHS:ScanGuildBank()
    if not bank.open or bank.scanning or not self.db then return false end
    if inCombat() then
        self:Print("Im Kampf wird die Gildenbank nicht gescannt.")
        return false
    end

    local queue = {}
    local numTabs = tonumber(try(GetNumGuildBankTabs)) or 0
    for index = 1, numTabs do
        local ok, name, _, isViewable = call(GetGuildBankTabInfo, index)
        if ok and isViewable then
            queue[#queue + 1] = { index = index, name = name or "" }
        end
    end
    if #queue == 0 then
        self:Debug("Gildenbank: kein sichtbarer Tab.")
        return false
    end

    bank.scanning = true
    bank.queue = queue
    bank.tabs = {}
    queryNext()
    return true
end

--- Whether the guild bank window is open right now (for later UI).
function EHS:IsGuildBankOpen()
    return bank.open
end

--- time() of the last opening of the guild bank (0 = not yet this session).
function EHS:GuildBankOpenedAt()
    return bank.openedAt
end

--- "tbc" | "forever" | "classic": the client this runs on, as in the key of
-- a guild bank (client.project of a scan, gameVersion of the handouts).
function EHS:ClientProject()
    local ok, _, _, _, interface = call(GetBuildInfo)
    return clientProject(ok and interface or nil)
end

--- Be told when the guild bank opens ("open"), closes ("close") or a scan
-- is stored ("scan"). Each call runs under pcall.
function EHS:OnGuildBankEvent(fn)
    if type(fn) == "function" then listeners[#listeners + 1] = fn end
end

function EHS:IsGuildBankScanning()
    return bank.scanning
end

--- Whether the last scan is newer than the last write of the SavedVariables.
function EHS:GuildBankUnsaved()
    local scan = self.db and self.db.guildBank
    return scan ~= nil and (scan.scannedAt or 0) > (self.db.lastFlushedAt or 0)
end

local function onOpen()
    if bank.open then return end
    bank.open = true
    bank.openedAt = time()
    EHS:ScanGuildBank()
    notify("open")
end

local function onClose()
    local wasOpen = bank.open
    bank.open = false
    if bank.scanning then
        stopScan()
        EHS:Print("Gildenbank geschlossen, Scan abgebrochen.")
    end
    if wasOpen then notify("close") end
end

local frame = CreateFrame("Frame")
for _, event in ipairs({
    "GUILDBANKFRAME_OPENED", "GUILDBANKFRAME_CLOSED",
    "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_HIDE",
    "GUILDBANKBAGSLOTS_CHANGED",
}) do
    pcall(frame.RegisterEvent, frame, event)
end

frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "GUILDBANKFRAME_OPENED" then
        onOpen()
    elseif event == "GUILDBANKFRAME_CLOSED" then
        onClose()
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
        if arg1 == guildBankerType() then onOpen() end
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
        if arg1 == guildBankerType() then onClose() end
    elseif event == "GUILDBANKBAGSLOTS_CHANGED" then
        if bank.scanning and bank.waiting then readWaiting() end
    end
end)
