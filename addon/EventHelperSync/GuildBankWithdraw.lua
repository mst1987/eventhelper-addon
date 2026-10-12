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
     not allow stays out and is named in chat. The steps run grouped by tab,
     the tab shown right now first.
  3. Item actions only work on the CURRENT guild bank tab: Blizzard's frame
     only ever acts on GetCurrentGuildBankTab(), Baganator calls
     SetCurrentGuildBankTab(tab) before every pick up (ItemButton.lua), and
     the server reports slot changes (GUILDBANKBAGSLOTS_CHANGED) only for the
     current tab. So before the steps of a tab: SetCurrentGuildBankTab(tab) +
     QueryGuildBankTab(tab), wait for the answer. Afterwards the tab shown
     before is selected again (Baganator's view follows the current tab).
  4. One step at a time with small pauses: a whole stack goes into the bags
     with AutoStoreGuildBankItem, a part with SplitGuildBankItem and then
     PickupContainerItem on a free bag slot. Every step waits until the items
     are really in the bags. Each step needs a free plain bag slot.

When something goes wrong it stops, clears the cursor and lists the rest as
"Tab 1 Platz 5: 2x Item" in chat (outlined in Blizzard's guild bank frame if
that is the visible frame and shows the tab - not with a bag addon such as
Baganator, then the chat lines are all):
  - the server refuses (UI_ERROR_MESSAGE while a job runs): "Gildenbank lehnt
    ab: <message>";
  - no answer in time (a wait times out) or a client call raises: "hat nicht
    geklappt";
  - ADDON_ACTION_BLOCKED / ADDON_ACTION_FORBIDDEN for this addon: only this
    is remembered for the session (the next clicks list the slots at once).

Diagnostics: the last LOG_MAX steps go to EventHelperSyncDB.withdrawLog
(see log() below), with /ehs debug also live in chat.

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
-- Pause after a tab switch was answered, before the first item action on it.
local TAB_SETTLE = 0.3
-- Entries kept in EventHelperSyncDB.withdrawLog.
Withdraw.LOG_MAX = 30

-- Runtime state only, nothing of this is saved.
local state = {
    blocked = false, -- ADDON_ACTION_BLOCKED/FORBIDDEN this session: list the slots straight away
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

--- The guild bank tab the client acts on right now (nil if unknown).
local function currentTab()
    return tonumber(try(GetCurrentGuildBankTab))
end

--- A message argument as plain text; nil for a secret value (WoW Forever) or
-- anything that is not a string.
local function plainText(value)
    if type(issecretvalue) == "function" then
        local ok, secret = pcall(issecretvalue, value)
        if not ok or secret then return nil end
    end
    if type(value) == "string" then return value end
    return nil
end

-- ---------------------------------------------------------------------------
-- Diagnostics: EventHelperSyncDB.withdrawLog
-- ---------------------------------------------------------------------------

-- The fields of a log entry, in the order /ehs debug prints them:
--   t       time()
--   kind    start | query | tab | act | done | timeout | refused | info |
--           error | blocked | stop | restore
--   tab, slot, cur (the current tab when it was written), item (item id),
--   count, before / after (that item in the bags), wait (what timed out:
--   query | tab | slot | cursor | bags), reason (stop), err (UI message or
--   Lua error, Latin-1), blocked (the session block was on)
local LOG_FIELDS = { "tab", "slot", "cur", "item", "count", "before", "after", "wait", "reason", "err", "blocked" }

--- Add an entry to the withdraw log (the last Withdraw.LOG_MAX are kept in
-- the SavedVariables) and with /ehs debug print it.
local function log(kind, fields)
    local entry = { t = time and time() or 0, kind = kind, cur = currentTab() }
    for key, value in pairs(fields or {}) do entry[key] = value end
    if state.blocked then entry.blocked = true end
    if type(entry.err) == "string" then entry.err = Mail.Latin1(entry.err) end
    local db = EHS.db
    if type(db) == "table" then
        if type(db.withdrawLog) ~= "table" then db.withdrawLog = {} end
        local buffer = db.withdrawLog
        buffer[#buffer + 1] = entry
        while #buffer > Withdraw.LOG_MAX do table.remove(buffer, 1) end
    end
    local parts = { "Entnehmen:", kind }
    for _, key in ipairs(LOG_FIELDS) do
        if entry[key] ~= nil then parts[#parts + 1] = key .. "=" .. tostring(entry[key]) end
    end
    pcall(EHS.Debug, EHS, table.concat(parts, " "))
end
Withdraw.Log = log

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

--- The steps grouped by tab (each tab is selected once): the tab shown right
-- now first, then ascending; within a tab the planned order stays.
function Withdraw.OrderByTab(steps, first)
    local keyed = {}
    for i, step in ipairs(steps) do
        keyed[i] = { step = step, index = i, rank = step.tab == first and 0 or step.tab }
    end
    table.sort(keyed, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.index < b.index
    end)
    local out = {}
    for i, k in ipairs(keyed) do out[i] = k.step end
    return out
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

--- Whether a frame is on screen: a bag addon such as Baganator keeps
-- Blizzard's guild bank frame shown but parents it to a hidden frame.
local function visible(frame)
    if type(frame.IsVisible) ~= "function" then return true end
    local ok, shown = pcall(frame.IsVisible, frame)
    return not ok or (shown and true or false)
end

--- The button of Blizzard's guild bank frame that shows this slot, if its tab
-- is the one shown and the frame is visible (TBC: GuildBankColumnXButtonY,
-- Retail: GuildBankFrame.Columns).
function Withdraw.FindBankButton(tab, slot)
    if currentTab() ~= tab then return nil end
    local column = math.floor((slot - 1) / SLOTS_PER_COLUMN) + 1
    local index = (slot - 1) % SLOTS_PER_COLUMN + 1
    local button = _G["GuildBankColumn" .. column .. "Button" .. index]
    if not button then
        local frame = _G.GuildBankFrame
        local columns = type(frame) == "table" and frame.Columns
        local col = type(columns) == "table" and columns[column]
        local buttons = type(col) == "table" and col.Buttons
        if type(buttons) == "table" then button = buttons[index] end
    end
    if type(button) ~= "table" or not visible(button) then return nil end
    return button
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

local function live(job)
    return job.token == state.token
end

--- End a job: no timer or event of it does anything any more.
local function close(job)
    state.job = nil
    state.query = nil
    state.token = state.token + 1
    job.token = -1
end

--- Select the tab that was shown before the job again (Baganator follows).
local function restoreTab(job)
    local tab = job.restoreTab
    job.restoreTab = nil
    if not tab or not bankOpen() or currentTab() == tab then return end
    log("restore", { tab = tab })
    call(SetCurrentGuildBankTab, tab)
    call(QueryGuildBankTab, tab)
end

local STOP_TEXT = {
    combat = "Kampf: Entnehmen abgebrochen. Den Rest bitte selbst nehmen:",
    blocked = "Entnehmen aus der Gildenbank ist auf diesem Client gesperrt. Bitte selbst in die Taschen nehmen:",
    bags = "Taschen voll: Entnehmen abgebrochen. Den Rest bitte selbst nehmen:",
    timeout = "Entnehmen hat nicht geklappt (keine Antwort der Gildenbank). Bitte selbst nehmen:",
    error = "Entnehmen hat nicht geklappt (Fehler im Client). Bitte selbst nehmen:",
}
STOP_TEXT.known = STOP_TEXT.blocked

--- Stop a job: the rest is named in chat. Only a real ADDON_ACTION_BLOCKED /
-- ADDON_ACTION_FORBIDDEN (reason "blocked") is remembered for the session.
local function stop(job, reason, detail)
    if not live(job) then return end
    close(job)
    Mail.ClearCursor()
    if reason == "blocked" then state.blocked = true end
    log("stop", { reason = reason, wait = detail and detail.wait, err = detail and detail.err })
    local todo = {}
    for k = job.index, #job.steps do todo[#todo + 1] = job.steps[k] end
    if reason == "closed" then
        EHS:Print("Gildenbank geschlossen - Entnehmen abgebrochen.")
        todo = {}
    elseif reason == "refused" then
        EHS:Print("Gildenbank lehnt ab: " .. Mail.Latin1(detail and detail.err or "?"))
        EHS:Print("Entnehmen abgebrochen. Den Rest bitte selbst nehmen:")
    else
        EHS:Print(STOP_TEXT[reason] or STOP_TEXT.timeout)
    end
    if reason ~= "closed" then restoreTab(job) end
    for _, line in ipairs(Withdraw.ManualLines(todo, names(job))) do EHS:Print("  " .. line) end
    if #todo > 0 then Withdraw.Highlight(todo) end
    report(job)
    refresh()
end

local function finish(job)
    if not live(job) then return end
    close(job)
    log("done", { reason = "finished" })
    restoreTab(job)
    report(job)
    refresh()
end

--- Wait until check() is true, polling; then onOk(), else stop the job with
-- "timeout" (`wait` names what was awaited, `detail()` adds log fields).
local function waitFor(job, check, onOk, wait, detail)
    local function poll(n)
        if not live(job) then return end
        if job.blocked then return stop(job, "blocked") end
        local ok, done = pcall(check)
        if ok and done then return onOk() end
        if n >= POLL_TRIES then
            local fields = detail and select(2, pcall(detail)) or {}
            if type(fields) ~= "table" then fields = {} end
            fields.wait = wait
            log("timeout", fields)
            return stop(job, "timeout", { wait = wait })
        end
        after(POLL, function() poll(n + 1) end)
    end
    poll(0)
end

--- A client call that moves items: true, or false and the stop reason
-- ("error" if it raised, "blocked" if the client blocked it).
local function act(job, step, fn, ...)
    log("act", { tab = step.tab, slot = step.slot, item = step.itemId, count = step.count,
        before = bagCount(step.itemId) })
    if type(fn) ~= "function" then
        log("error", { err = "no such client function" })
        return false, "error"
    end
    local ok, err = pcall(fn, ...)
    if not ok then
        log("error", { tab = step.tab, slot = step.slot, err = str(err) })
        return false, "error"
    end
    if job.blocked then return false, "blocked" end
    return true
end

--- Make `tab` the current guild bank tab, then onOk(). Without
-- SetCurrentGuildBankTab (unknown client) it goes on as before.
local function selectTab(job, tab, onOk)
    local current = currentTab()
    if current == tab or type(SetCurrentGuildBankTab) ~= "function" then return onOk() end
    if job.restoreTab == nil then job.restoreTab = current or false end
    log("tab", { tab = tab })
    local answered = false
    local function go(timedOut)
        if answered or not live(job) then return end
        answered = true
        state.query = nil
        if timedOut then log("timeout", { tab = tab, wait = "tab" }) end
        after(TAB_SETTLE, function()
            if live(job) then onOk() end
        end)
    end
    state.query = function() go(false) end
    call(SetCurrentGuildBankTab, tab)
    call(QueryGuildBankTab, tab)
    after(QUERY_TIMEOUT, function() go(true) end)
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
        if live(job) then doStep(job) end
    end)
end

local function bagSlotHas(bag, slot, itemId, count)
    local info = Mail.SlotInfo(bag, slot)
    return info ~= nil and not info.locked and info.itemId == itemId and info.count == count
end

--- One step on the current tab: wait for the stack, move it, wait for the bags.
local function runStep(job, step)
    -- the stack must still be there and unlocked (an earlier split locks it)
    waitFor(job, function()
        local info = Withdraw.SlotInfo(step.tab, step.slot)
        return info and not info.locked and info.itemId == step.itemId and info.count >= step.count
    end, function()
        if not bankOpen() then return stop(job, "closed") end
        if inCombat() then return stop(job, "combat") end
        local info = Withdraw.SlotInfo(step.tab, step.slot)
        step.stackCount = info.count
        step.kind = info.count > step.count and "split" or "whole"
        local _, free = Mail.BagStacks()
        local target = free[1]
        if not target then return stop(job, "bags") end
        local before = bagCount(step.itemId)
        -- done once the bags hold the items (a refused move puts them back;
        -- a split stack is placed locked until the server agrees)
        local function arrived()
            return bagCount(step.itemId) >= before + step.count
        end
        local function bagsDetail()
            local slotInfo = Withdraw.SlotInfo(step.tab, step.slot)
            return { tab = step.tab, slot = step.slot, item = step.itemId, count = slotInfo and slotInfo.count,
                before = before, after = bagCount(step.itemId) }
        end
        local function done()
            log("done", { tab = step.tab, slot = step.slot, item = step.itemId, count = step.count,
                before = before, after = bagCount(step.itemId) })
            stepDone(job, step)
        end

        if step.kind == "whole" then
            local ok, why = act(job, step, AutoStoreGuildBankItem, step.tab, step.slot)
            if not ok then return stop(job, why) end
            return waitFor(job, arrived, done, "bags", bagsDetail)
        end
        local ok, why = act(job, step, SplitGuildBankItem, step.tab, step.slot, step.count)
        if not ok then return stop(job, why) end
        waitFor(job, Mail.CursorHasItem, function()
            local placed, reason = act(job, step, Mail.ContainerFn("PickupContainerItem"), target.bag, target.slot)
            if not placed then return stop(job, reason) end
            waitFor(job, function()
                return bagSlotHas(target.bag, target.slot, step.itemId, step.count) and arrived()
            end, done, "bags", bagsDetail)
        end, "cursor", bagsDetail)
    end, "slot", function()
        local info = Withdraw.SlotInfo(step.tab, step.slot)
        return { tab = step.tab, slot = step.slot, item = info and info.itemId, count = info and info.count,
            err = info and info.locked and "locked" or nil }
    end)
end

doStep = function(job)
    if not live(job) then return end
    if not bankOpen() then return stop(job, "closed") end
    local step = job.steps[job.index]
    if not step then return finish(job) end
    if inCombat() then return stop(job, "combat") end
    selectTab(job, step.tab, function() runStep(job, step) end)
end

--- Query the tabs whose data the client may not have yet, one after another.
local function queryTabs(job, tabs, onDone)
    local index = 0
    local function nextTab()
        if not live(job) then return end
        index = index + 1
        local tab = tabs[index]
        if not tab then
            state.query = nil
            return onDone()
        end
        local answered = false
        local function go(timedOut)
            if answered or not live(job) then return end
            answered = true
            state.query = nil
            if timedOut then log("timeout", { tab = tab, wait = "query" }) end
            nextTab()
        end
        state.query = function() go(false) end
        log("query", { tab = tab })
        call(QueryGuildBankTab, tab)
        after(QUERY_TIMEOUT, function() go(true) end)
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
    job.steps = Withdraw.OrderByTab(job.plan.steps, currentTab())
    if #job.steps == 0 then
        close(job)
        log("done", { reason = "nothing" })
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
    log("start", { item = needs[1].itemId, count = needs[1].need, reason = #needs .. " Posten" })

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
    "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN", "UI_ERROR_MESSAGE", "UI_INFO_MESSAGE")

frame:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "GUILDBANKBAGSLOTS_CHANGED" then
        local go = state.query
        if go then go() end
    elseif event == "BAG_UPDATE_DELAYED" then
        if bankOpen() then refresh() end
    elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
        if arg1 == EHS.name and state.job then
            log("blocked", { err = event .. " " .. str(plainText(arg2)) })
            state.job.blocked = true
            state.blocked = true
        end
    elseif event == "UI_ERROR_MESSAGE" or event == "UI_INFO_MESSAGE" then
        -- (messageType, message) on current clients, (message) on old ones
        local job = state.job
        if not job then return end
        local text = plainText(arg2) or plainText(arg1) or "?"
        if event == "UI_INFO_MESSAGE" then
            log("info", { err = text })
            return
        end
        log("refused", { err = text })
        stop(job, "refused", { err = text })
    end
end)
