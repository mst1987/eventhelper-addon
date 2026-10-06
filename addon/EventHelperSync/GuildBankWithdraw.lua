--[[
Guild bank handouts - taking them out of the guild bank (click on a row of
the handout window while the guild bank is open, GuildBankUI.lua).

A click takes what an entry still lacks in the bags (entry.amount minus what
the bags already hold, shared in list order as at the mailbox) out of the
guild bank into the bags; Shift-click does that for all open entries of the
row's recipient. Taking out does not tick anything off: ticking happens when
the mail is sent or by the checkbox.

  1. The stacks are read live from the viewable tabs (GetGuildBankItemLink /
     GetGuildBankItemInfo). Where the stored scan or the server saw the item
     but the client shows none, that tab is queried first (QueryGuildBankTab,
     wait for GUILDBANKBAGSLOTS_CHANGED).
  2. Planning per entry: an exact stack, else whole smaller stacks (largest
     first), else the smallest larger stack is split. Every stack counts as
     one withdrawal against the tab's daily limit (GetGuildBankTabInfo,
     remainingWithdrawals, -1 = unlimited); what the limit or the stock does
     not allow stays out and is named in chat.
  3. One step at a time with small pauses: a whole stack goes into the bags
     with AutoStoreGuildBankItem, a part with SplitGuildBankItem and then
     PickupContainerItem on a free bag slot. Every step waits until the items
     are really in the bags. Each step needs a free plain bag slot.

Whether a Retail-based client (WoW Forever) lets addon code move guild bank
items is unknown. If a call errors, the cursor stays empty or the client fires
ADDON_ACTION_BLOCKED / ADDON_ACTION_FORBIDDEN for this addon, it stops, clears
the cursor, lists "Tab 1 Platz 5: 2x Item" in chat and outlines the slots of
the shown tab in the guild bank frame. That is remembered for the session.

Never in combat; every client call runs under pcall.
]]

local EHS = EventHelperSync
local Handouts = EHS.Handouts
local Mail = EHS.Mail

local Withdraw = {}
EHS.Withdraw = Withdraw

Withdraw.SLOTS_PER_TAB = 98
-- Slots per column of the guild bank frame.
local SLOTS_PER_COLUMN = 14

-- Pause between two steps (the server throttles guild bank actions), and how
-- a step waits for the client.
local STEP_GAP = 0.4
local POLL = 0.1
local POLL_TRIES = 40
-- How long to wait for GUILDBANKBAGSLOTS_CHANGED after a query.
local QUERY_TIMEOUT = 3

-- Runtime state only, nothing of this is saved.
local state = {
    blocked = false, -- moving items was blocked this session: list the slots straight away
    token = 0,       -- invalidates a running job and its timers
    job = nil,
    query = nil,     -- function waiting for GUILDBANKBAGSLOTS_CHANGED
    taken = {},      -- { [entry id] = amount } taken out this session (counts for that entry in the bags)
}

local outlines = {}

local function str(value)
    if value == nil then return "" end
    return tostring(value)
end

local function call(fn, ...)
    if type(fn) ~= "function" then return false end
    return pcall(fn, ...)
end

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

local function refresh()
    if EHS.RefreshGuildBankUI then pcall(EHS.RefreshGuildBankUI, EHS) end
end

local function itemIdFromLink(link)
    if type(link) ~= "string" then return nil end
    return tonumber(link:match("item:(%d+)"))
end

local function bankOpen()
    return EHS.IsGuildBankOpen and EHS:IsGuildBankOpen() and true or false
end

local function bagCount(itemId)
    return Mail.BagCounts()[itemId] or 0
end

-- ---------------------------------------------------------------------------
-- The guild bank as the client shows it right now
-- ---------------------------------------------------------------------------

--- One guild bank slot: { itemId, count, locked } or nil when empty or unknown.
function Withdraw.SlotInfo(tab, slot)
    local id = itemIdFromLink(try(GetGuildBankItemLink, tab, slot))
    if not id then return nil end
    -- texture, itemCount, locked, isFiltered, quality
    local ok, _, count, locked = call(GetGuildBankItemInfo, tab, slot)
    count = ok and tonumber(count) or 0
    return { itemId = id, count = count > 0 and count or 1, locked = ok and locked and true or false }
end

--- The stacks of these items in the viewable tabs, read live.
-- @param wanted { [itemId] = true }
-- @return stacks { { tab, slot, itemId, count, locked } }, limits { [tab] = remaining
--   withdrawals, -1 = unlimited }, names { [tab] = name }
function Withdraw.BankStacks(wanted)
    local stacks, limits, names = {}, {}, {}
    local numTabs = tonumber(try(GetNumGuildBankTabs)) or 0
    for tab = 1, numTabs do
        -- name, icon, isViewable, canDeposit, numWithdrawals, remainingWithdrawals
        local ok, name, _, viewable, _, _, remaining = call(GetGuildBankTabInfo, tab)
        if ok and viewable then
            limits[tab] = tonumber(remaining) or -1
            names[tab] = str(name)
            for slot = 1, Withdraw.SLOTS_PER_TAB do
                local info = Withdraw.SlotInfo(tab, slot)
                if info and wanted[info.itemId] then
                    info.tab, info.slot = tab, slot
                    stacks[#stacks + 1] = info
                end
            end
        end
    end
    return stacks, limits, names
end

--- "Tab 1 Platz 5".
function Withdraw.SlotLabel(tab, slot)
    return ("Tab %d Platz %d"):format(tab, slot)
end

-- ---------------------------------------------------------------------------
-- Planning
-- ---------------------------------------------------------------------------

--- The steps to take these needs out of the bank.
-- @param needs { { key, itemId, need } } in order; they share the stacks
-- @param stacks { { tab, slot, itemId, count } }
-- @param limits { [tab] = remaining withdrawals, -1 or nil = unlimited }
-- @return { steps = { { kind = "whole"|"split", tab, slot, itemId, count,
--   stackCount, key } }, short = { [key] = { missing, reason = "limit"|"stock" } } }
function Withdraw.Plan(needs, stacks, limits)
    limits = limits or {}
    local left = {}
    for tab, remaining in pairs(limits) do left[tab] = remaining end
    local pool = {}
    for _, s in ipairs(stacks or {}) do
        pool[s.itemId] = pool[s.itemId] or {}
        table.insert(pool[s.itemId], { tab = s.tab, slot = s.slot, count = s.count, rest = s.count })
    end
    local function allowed(s)
        local remaining = left[s.tab]
        return remaining == nil or remaining < 0 or remaining > 0
    end

    local plan = { steps = {}, short = {} }
    for _, n in ipairs(needs or {}) do
        local need = n.need
        local limited = false
        while need > 0 do
            local exact, bigger, smaller
            for _, s in ipairs(pool[n.itemId] or {}) do
                if s.rest > 0 then
                    if not allowed(s) then
                        limited = true
                    else
                        if s.rest == need and not exact then exact = s end
                        if s.rest > need and (not bigger or s.rest < bigger.rest) then bigger = s end
                        if s.rest < need and (not smaller or s.rest > smaller.rest) then smaller = s end
                    end
                end
            end
            local pick = exact or smaller or bigger
            if not pick then break end
            local count = math.min(need, pick.rest)
            plan.steps[#plan.steps + 1] = {
                kind = count < pick.rest and "split" or "whole", tab = pick.tab, slot = pick.slot,
                itemId = n.itemId, count = count, stackCount = pick.rest, key = n.key,
            }
            pick.rest = pick.rest - count
            -- a stack the bank still holds part of can be withdrawn again, but
            -- every withdrawal counts against the tab's limit
            if left[pick.tab] and left[pick.tab] > 0 then left[pick.tab] = left[pick.tab] - 1 end
            need = need - count
        end
        if need > 0 then
            plan.short[n.key] = { missing = need, reason = limited and "limit" or "stock" }
        end
    end
    return plan
end

-- ---------------------------------------------------------------------------
-- Which entries need what (bag check as at the mailbox)
-- ---------------------------------------------------------------------------

--- Set entry.bagMissing on the open entries (they share the bag stock in
-- list order) and return them.
function Withdraw.CheckBags(entries, counts)
    local open = {}
    for _, entry in ipairs(entries or {}) do
        if not entry.done then open[#open + 1] = entry end
    end
    Mail.CheckBags({ { entries = open } }, counts or Mail.BagCounts(), state.taken)
    return open
end

local function recipientKey(entry)
    return str(entry.recipient):lower() .. "|" .. Handouts.RealmKey(entry.recipientRealm)
end

--- The open entries to take out for a click: the entry itself, or with
-- `all` every open entry of its recipient - each with bagMissing set from the
-- current bags.
function Withdraw.EntriesFor(entry, all)
    local open = Withdraw.CheckBags((EHS:GetHandoutEntries()))
    local out = {}
    for _, e in ipairs(open) do
        if (all and recipientKey(e) == recipientKey(entry)) or (not all and e.id == entry.id) then
            out[#out + 1] = e
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Outlining the guild bank slots (fallback)
-- ---------------------------------------------------------------------------

--- The button of the guild bank frame that shows this slot, if its tab is
-- the one shown (TBC: GuildBankColumnXButtonY, Retail: GuildBankFrame.Columns).
function Withdraw.FindBankButton(tab, slot)
    local current = tonumber(try(GetCurrentGuildBankTab))
    if current ~= tab then return nil end
    local column = math.floor((slot - 1) / SLOTS_PER_COLUMN) + 1
    local index = (slot - 1) % SLOTS_PER_COLUMN + 1
    local button = _G["GuildBankColumn" .. column .. "Button" .. index]
    if button then return button end
    local frame = _G.GuildBankFrame
    local columns = type(frame) == "table" and frame.Columns
    local col = type(columns) == "table" and columns[column]
    local buttons = type(col) == "table" and col.Buttons
    if type(buttons) == "table" then return buttons[index] end
    return nil
end

--- Outline the slots of these steps in the guild bank frame.
-- @return number how many were outlined
function Withdraw.Highlight(steps)
    Mail.HideOutlines(outlines)
    local n = 0
    for _, step in ipairs(steps) do
        local ok, button = pcall(Withdraw.FindBankButton, step.tab, step.slot)
        if ok and button then
            n = n + 1
            pcall(Mail.Outline, outlines, n, button)
        end
    end
    return n
end

function Withdraw.Highlights()
    return outlines
end

-- ---------------------------------------------------------------------------
-- Texts
-- ---------------------------------------------------------------------------

--- The chat lines for taking by hand: "Tab 1 Platz 5: 2x Bold Living Ruby".
function Withdraw.ManualLines(steps, names)
    local lines = {}
    for _, step in ipairs(steps) do
        local line = ("%s: %dx %s"):format(Withdraw.SlotLabel(step.tab, step.slot), step.count,
            Mail.Latin1(names[step.key] or ("Item " .. step.itemId)))
        if step.kind == "split" then
            line = line .. (" (von %d, Shift-Klick teilt den Stapel)"):format(step.stackCount or step.count)
        end
        lines[#lines + 1] = line
    end
    return lines
end

local SHORT_TEXT = {
    limit = "Tageslimit des Tabs erreicht",
    stock = "nicht genug in der Gildenbank",
}

-- ---------------------------------------------------------------------------
-- Running a job
-- ---------------------------------------------------------------------------

local function names(job)
    local out = {}
    for _, n in ipairs(job.needs) do out[n.key] = n.name end
    return out
end

--- Chat: what was taken, and what not.
local function report(job)
    for _, n in ipairs(job.needs) do
        local name = Mail.Latin1(n.name)
        if n.taken > 0 then
            EHS:Print(("Aus der Gildenbank genommen: %dx %s"):format(n.taken, name))
        end
        local short = job.plan.short[n.key]
        if short and n.taken < n.need then
            EHS:Print(("%s: %d von %d nicht genommen - %s."):format(name, n.need - n.taken, n.need,
                SHORT_TEXT[short.reason] or SHORT_TEXT.stock))
        end
    end
end

local function stop(job, reason)
    if job.token ~= state.token then return end
    state.job = nil
    state.query = nil
    Mail.ClearCursor()
    if reason == "blocked" then state.blocked = true end
    local todo = {}
    for k = job.index, #job.steps do todo[#todo + 1] = job.steps[k] end
    if reason == "closed" then
        EHS:Print("Gildenbank geschlossen - Entnehmen abgebrochen.")
        todo = {}
    elseif reason == "combat" then
        EHS:Print("Kampf: Entnehmen abgebrochen. Den Rest bitte selbst nehmen:")
    elseif reason == "blocked" or reason == "known" then
        EHS:Print("Entnehmen aus der Gildenbank ist auf diesem Client gesperrt. Bitte selbst in die Taschen nehmen:")
    elseif reason == "bags" then
        EHS:Print("Taschen voll: Entnehmen abgebrochen. Den Rest bitte selbst nehmen:")
    else
        EHS:Print("Entnehmen hat nicht geklappt. Bitte selbst nehmen:")
    end
    for _, line in ipairs(Withdraw.ManualLines(todo, names(job))) do EHS:Print("  " .. line) end
    if #todo > 0 then Withdraw.Highlight(todo) end
    report(job)
    refresh()
end

local function finish(job)
    if job.token ~= state.token then return end
    state.job = nil
    report(job)
    refresh()
end

--- Wait until check() is true, polling; then onOk(), else stop(job, reason).
local function waitFor(job, check, onOk, reason)
    local function poll(n)
        if job.token ~= state.token then return end
        if job.blocked then return stop(job, "blocked") end
        local ok, done = pcall(check)
        if ok and done then return onOk() end
        if n >= POLL_TRIES then return stop(job, reason or "timeout") end
        after(POLL, function() poll(n + 1) end)
    end
    poll(0)
end

--- A client call that moves items. False if it errors or the client blocked it.
local function act(job, fn, ...)
    if type(fn) ~= "function" then return false end
    local ok = pcall(fn, ...)
    return ok and not job.blocked
end

local doStep

local function stepDone(job, step)
    for _, n in ipairs(job.needs) do
        if n.key == step.key then
            n.taken = n.taken + step.count
            state.taken[n.key] = (state.taken[n.key] or 0) + step.count
        end
    end
    pcall(EHS.RereadGuildBankTab, EHS, step.tab)
    job.index = job.index + 1
    refresh()
    after(STEP_GAP, function()
        if job.token == state.token then doStep(job) end
    end)
end

local function bagSlotHas(bag, slot, itemId, count)
    local info = Mail.SlotInfo(bag, slot)
    return info ~= nil and not info.locked and info.itemId == itemId and info.count == count
end

doStep = function(job)
    if job.token ~= state.token then return end
    if not bankOpen() then return stop(job, "closed") end
    local step = job.steps[job.index]
    if not step then return finish(job) end
    if inCombat() then return stop(job, "combat") end
    -- the stack must still be there and unlocked (an earlier split locks it)
    waitFor(job, function()
        local info = Withdraw.SlotInfo(step.tab, step.slot)
        return info and not info.locked and info.itemId == step.itemId and info.count >= step.count
    end, function()
        local info = Withdraw.SlotInfo(step.tab, step.slot)
        step.stackCount = info.count
        step.kind = info.count > step.count and "split" or "whole"
        local _, free = Mail.BagStacks()
        local target = free[1]
        if not target then return stop(job, "bags") end
        local before = bagCount(step.itemId)
        -- done once the bags hold the items and the bank stack is that much
        -- smaller (a refused move puts the items back)
        local function arrived()
            if bagCount(step.itemId) < before + step.count then return false end
            local now = Withdraw.SlotInfo(step.tab, step.slot)
            return not now or now.itemId ~= step.itemId or now.count <= step.stackCount - step.count
        end

        if step.kind == "whole" then
            if not act(job, AutoStoreGuildBankItem, step.tab, step.slot) then return stop(job, "blocked") end
            return waitFor(job, arrived, function() stepDone(job, step) end)
        end
        if not act(job, SplitGuildBankItem, step.tab, step.slot, step.count) then return stop(job, "blocked") end
        waitFor(job, Mail.CursorHasItem, function()
            if not act(job, Mail.ContainerFn("PickupContainerItem"), target.bag, target.slot) then
                return stop(job, "blocked")
            end
            waitFor(job, function()
                return bagSlotHas(target.bag, target.slot, step.itemId, step.count) and arrived()
            end, function() stepDone(job, step) end)
        end, "blocked")
    end, "locked")
end

--- Query the tabs whose data the client may not have yet, one after another.
local function queryTabs(job, tabs, onDone)
    local index = 0
    local function nextTab()
        if job.token ~= state.token then return end
        index = index + 1
        local tab = tabs[index]
        if not tab then
            state.query = nil
            return onDone()
        end
        local answered = false
        local function go()
            if answered or job.token ~= state.token then return end
            answered = true
            state.query = nil
            nextTab()
        end
        state.query = go
        call(QueryGuildBankTab, tab)
        after(QUERY_TIMEOUT, go)
    end
    nextTab()
end

--- Tabs where the stored scan or the server saw an item.
local function hintTabs(needs)
    local tabs = {}
    local scan = EHS.db and EHS.db.guildBank
    for _, n in ipairs(needs) do
        for _, t in ipairs(n.entry.stockTabs or {}) do tabs[tonumber(t.index) or 0] = true end
        for _, t in ipairs(n.entry.tabs or {}) do tabs[tonumber(t.index) or 0] = true end
        if type(scan) == "table" and type(scan.tabs) == "table" then
            for _, tab in ipairs(scan.tabs) do
                for _, item in ipairs(type(tab.items) == "table" and tab.items or {}) do
                    if tonumber(item.itemId) == n.itemId then tabs[tonumber(tab.index) or 0] = true end
                end
            end
        end
    end
    return tabs
end

--- Plan from the live stacks and run (or list the slots if blocked).
local function planAndRun(job)
    local stacks, limits = Withdraw.BankStacks(job.wanted)
    job.plan = Withdraw.Plan(job.needs, stacks, limits)
    job.steps = job.plan.steps
    if #job.steps == 0 then
        state.job = nil
        report(job)
        refresh()
        return
    end
    if state.blocked then return stop(job, "known") end
    refresh()
    doStep(job)
end

--- Take the open handouts out of the guild bank into the bags: for each entry
-- what the bags still lack (entry.bagMissing, see Withdraw.EntriesFor).
-- @return boolean started, reason
function EHS:WithdrawHandouts(entries)
    if not bankOpen() then return false, "closed" end
    if inCombat() then
        self:Print("|cffdd4444Nicht im Kampf.|r Nach dem Kampf nochmal klicken.")
        return false, "combat"
    end
    if state.job then
        self:Print("Entnehmen läuft noch - einen Moment.")
        return false, "busy"
    end
    if self.IsGuildBankScanning and self:IsGuildBankScanning() then
        self:Print("Die Gildenbank wird noch gelesen - gleich nochmal klicken.")
        return false, "scanning"
    end

    local needs, wanted = {}, {}
    for _, entry in ipairs(entries or {}) do
        local need = tonumber(entry.bagMissing) or entry.amount
        if not entry.done and need > 0 then
            needs[#needs + 1] = { key = entry.id, itemId = entry.itemId, name = entry.name, need = need, taken = 0,
                entry = entry }
            wanted[entry.itemId] = true
        end
    end
    if #needs == 0 then
        if entries and #entries == 1 then
            self:Print(("%dx %s ist schon in den Taschen."):format(entries[1].amount, Mail.Latin1(entries[1].name)))
        else
            self:Print("Schon alles in den Taschen.")
        end
        return false, "bags"
    end

    local _, free = Mail.BagStacks()
    if #free == 0 and not state.blocked then
        self:Print("Kein freier Taschenplatz - erst Platz schaffen.")
        return false, "nospace"
    end

    Mail.HideOutlines(outlines)
    state.token = state.token + 1
    local job = { token = state.token, needs = needs, wanted = wanted, steps = {}, index = 1,
        plan = { steps = {}, short = {} } }
    state.job = job

    -- Tabs the client may not have loaded: the scan or the server saw the
    -- item there, but the client shows none of it.
    local stacks, limits = Withdraw.BankStacks(wanted)
    local seen, have, need = {}, {}, {}
    for _, s in ipairs(stacks) do
        seen[s.tab .. ":" .. s.itemId] = true
        have[s.itemId] = (have[s.itemId] or 0) + s.count
    end
    for _, n in ipairs(needs) do need[n.itemId] = (need[n.itemId] or 0) + n.need end
    local query = {}
    for tab in pairs(hintTabs(needs)) do
        if limits[tab] then
            for _, n in ipairs(needs) do
                if (have[n.itemId] or 0) < need[n.itemId] and not seen[tab .. ":" .. n.itemId] then
                    query[#query + 1] = tab
                    break
                end
            end
        end
    end
    table.sort(query)
    if #query == 0 then
        planAndRun(job)
    else
        refresh()
        queryTabs(job, query, function() planAndRun(job) end)
    end
    return true
end

--- What was taken out of the guild bank this session per entry id; the bag
-- check counts it for that entry first (Mail.CheckBags).
function EHS:WithdrawnAmounts()
    return state.taken
end

--- Whether taking out was blocked this session.
function EHS:GuildBankWithdrawBlocked()
    return state.blocked
end

--- Whether a withdrawal is running, or this entry is part of it.
function EHS:WithdrawingHandout(id)
    local job = state.job
    if not job then return false end
    if id == nil then return true end
    for _, n in ipairs(job.needs) do
        if n.key == id then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

EHS:OnGuildBankEvent(function(what)
    if what == "close" then
        Mail.HideOutlines(outlines)
        if state.job then stop(state.job, "closed") end
    end
end)

local frame = CreateFrame("Frame")
EHS:RegisterEvents(frame, "GUILDBANKBAGSLOTS_CHANGED", "BAG_UPDATE_DELAYED",
    "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN")

frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "GUILDBANKBAGSLOTS_CHANGED" then
        local go = state.query
        if go then go() end
    elseif event == "BAG_UPDATE_DELAYED" then
        if bankOpen() then refresh() end
    elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
        if arg1 == EHS.name and state.job then
            state.job.blocked = true
            state.blocked = true
        end
    end
end)
