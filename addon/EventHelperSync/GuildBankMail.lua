--[[
Guild bank handouts by mail (#18) - the logic behind the "Post" button of the
handout window (GuildBankUI.lua shows the mailbox mode).

At the mailbox (MAIL_SHOW, on Forever also PLAYER_INTERACTION_MANAGER_FRAME_SHOW
with Enum.PlayerInteractionType.MailInfo) the window lists one row per
recipient. "Post" then:

  1. switches to the send tab and fills recipient ("Name", or "Name-Realm" for
     another realm), subject ("Gildenbank: 2 Posten") and body (one line per
     handout, Latin-1),
  2. attaches the exact amounts, one step at a time with small pauses: a stack
     that fits is picked up whole, a larger one is split into a free bag slot
     first; every step waits until the attachment is really there,
  3. stops after 12 attachments (ATTACHMENTS_MAX_SEND); the rest stays open and
     gets its own "Post" after this mail is sent.

The addon never calls SendMail - the player clicks Blizzard's "Senden". A hook
on SendMail (hooksecurefunc, no taint) notes recipient and attachments of the
mail that goes out; on MAIL_SEND_SUCCESS exactly the prepared handouts whose
items were in it are ticked off (via = "mail"), MAIL_FAILED ticks nothing.

Whether a Retail-based client (WoW Forever) lets addon code pick up and attach
items is unknown. If a call errors, leaves the cursor empty or the client fires
ADDON_ACTION_BLOCKED / ADDON_ACTION_FORBIDDEN for this addon, attaching stops:
recipient, subject and body stay filled, the needed bag slots are listed in
chat and outlined in the open bag frames, and the player drags them in. That
is remembered for the session.

Never in combat; every client call runs under pcall.
]]

local EHS = EventHelperSync
local Handouts = EHS.Handouts

local Mail = {}
EHS.Mail = Mail

Mail.MAX_ATTACHMENTS = 12
-- Postage the sender pays per attachment, in copper.
Mail.POSTAGE = 30
-- Mail body limit of the send frame.
Mail.MAX_BODY = 500
-- Enum.PlayerInteractionType.MailInfo, should a client lack the Enum table.
local MAIL_INFO_FALLBACK = 17

-- Pause between two attach steps, and how a step waits for the client.
local STEP_GAP = 0.2
local POLL = 0.1
local POLL_TRIES = 30

-- Runtime state only, nothing of this is saved.
local state = {
    open = false,
    blocked = false,  -- attaching was blocked this session: go straight to the fallback
    token = 0,        -- invalidates a running preparation
    job = nil,
    prepared = nil,   -- the mail the addon filled: see EHS:PrepareMail
    sent = nil,       -- snapshot of the mail that went out (SendMail hook)
    lastSeen = nil,   -- attachments as of the last MAIL_SEND_INFO_UPDATE
}

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

-- Listeners for "open" / "close" / "update" (the window, GuildBankUI.lua).
local listeners = {}

local function notify(what)
    for _, fn in ipairs(listeners) do
        local ok, err = pcall(fn, what)
        if not ok then EHS:Debug("Post-Listener:", tostring(err)) end
    end
end

-- ---------------------------------------------------------------------------
-- Texts
-- ---------------------------------------------------------------------------

-- Characters the game font lacks, by code point, and what to write instead.
local REPLACE = {
    [0x2010] = "-", [0x2011] = "-", [0x2012] = "-", [0x2013] = "-", [0x2014] = "-", [0x2212] = "-",
    [0x2018] = "'", [0x2019] = "'", [0x201A] = "'", [0x201B] = "'",
    [0x201C] = '"', [0x201D] = '"', [0x201E] = '"', [0x201F] = '"',
    [0x2026] = "...", [0x2192] = "->", [0x2190] = "<-", [0x2022] = "*",
}

--- The text with only what the game font can draw (Latin-1): typographic
-- dashes, quotes and the ellipsis become ASCII, anything else outside
-- Latin-1 "?", line breaks and "|" (WoW escape codes) a blank or "/".
function Mail.Latin1(text)
    text = str(text)
    local out = {}
    local i, n = 1, #text
    while i <= n do
        local b = text:byte(i)
        local cp, len = nil, 1
        if b < 0x80 then
            cp = b
        else
            local first
            if b >= 0xC2 and b <= 0xDF then len, first = 2, b - 0xC0
            elseif b >= 0xE0 and b <= 0xEF then len, first = 3, b - 0xE0
            elseif b >= 0xF0 and b <= 0xF4 then len, first = 4, b - 0xF0 end
            if first and i + len - 1 <= n then
                cp = first
                for k = 1, len - 1 do
                    local c = text:byte(i + k)
                    if c < 0x80 or c > 0xBF then
                        cp = nil
                        break
                    end
                    cp = cp * 64 + (c - 0x80)
                end
            end
            if not cp then len = 1 end
        end
        if not cp then
            out[#out + 1] = "?"
        elseif cp < 32 or cp == 127 then
            out[#out + 1] = " "
        elseif cp == 124 then
            out[#out + 1] = "/"
        elseif cp <= 0xFF then
            out[#out + 1] = text:sub(i, i + len - 1)
        else
            out[#out + 1] = REPLACE[cp] or "?"
        end
        i = i + len
    end
    return (table.concat(out):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

local function playerRealm()
    local realm = try(GetNormalizedRealmName)
    if not realm or realm == "" then realm = str(try(GetRealmName)) end
    return realm
end

--- What goes into the recipient box: "Name" on the own realm, else "Name-Realm".
function Mail.RecipientName(group, realm)
    local name = Mail.Latin1(group.recipient)
    local other = str(group.recipientRealm)
    if other == "" or Handouts.RealmKey(other) == Handouts.RealmKey(realm or playerRealm()) then return name end
    return name .. "-" .. Mail.Latin1(other):gsub("[%s%-]", "")
end

--- A recipient for comparing: lower case, without the own realm.
function Mail.RecipientKey(text, realm)
    local s = Mail.Latin1(text):lower()
    local name, other = s:match("^([^%-]+)%-(.+)$")
    if name and Handouts.RealmKey(other) == Handouts.RealmKey(realm or playerRealm()) then return name end
    return s
end

--- The key of a recipient group (as the window keeps it).
function Mail.GroupKey(group)
    return str(group.recipient):lower() .. "|" .. Handouts.RealmKey(group.recipientRealm)
end

function Mail.Subject(count)
    return ("Gildenbank: %d Posten"):format(count)
end

local function entryLine(entry)
    local line = ("%dx %s"):format(entry.amount, Mail.Latin1(entry.name))
    local purpose = Mail.Latin1(entry.purpose)
    if purpose ~= "" then line = line .. " - " .. purpose end
    return line
end

--- The mail text: a head line, one line per handout with its purpose, a
-- greeting. Lines that do not fit into Mail.MAX_BODY become "+N weitere".
function Mail.Body(entries)
    local head, foot = "Gildenbank-Ausgabe (EventHelper)", "Viel Erfolg!"
    local lines = {}
    for _, entry in ipairs(entries) do lines[#lines + 1] = entryLine(entry) end
    local function build(count)
        local out = { head }
        for k = 1, count do out[#out + 1] = lines[k] end
        if count < #lines then out[#out + 1] = ("+%d weitere"):format(#lines - count) end
        out[#out + 1] = foot
        return table.concat(out, "\n")
    end
    local count = #lines
    local text = build(count)
    while #text > Mail.MAX_BODY and count > 0 do
        count = count - 1
        text = build(count)
    end
    return text
end

-- ---------------------------------------------------------------------------
-- Bags (C_Container on both clients where it exists, the old globals else)
-- ---------------------------------------------------------------------------

local function containerFn(name)
    if C_Container and type(C_Container[name]) == "function" then return C_Container[name] end
    return _G[name]
end

local function bagList()
    local last = (tonumber(NUM_BAG_SLOTS) or 4) + (tonumber(NUM_REAGENTBAG_SLOTS) or 0)
    local bags = {}
    for bag = 0, last do bags[#bags + 1] = bag end
    return bags
end

local function numSlots(bag)
    return tonumber(try(containerFn("GetContainerNumSlots"), bag)) or 0
end

--- One bag slot: { itemId, count, locked, bound } or nil when empty.
function Mail.SlotInfo(bag, slot)
    if C_Container and type(C_Container.GetContainerItemInfo) == "function" then
        local ok, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
        if not ok or type(info) ~= "table" then return nil end
        local id = tonumber(info.itemID) or itemIdFromLink(info.hyperlink)
        if not id then return nil end
        return { itemId = id, count = tonumber(info.stackCount) or 1, locked = info.isLocked == true,
            bound = info.isBound == true }
    end
    local ok, _, count, locked, _, _, _, link, _, _, itemId = call(_G.GetContainerItemInfo, bag, slot)
    if not ok then return nil end
    local id = tonumber(itemId) or itemIdFromLink(link)
    if not id and count then id = itemIdFromLink(try(_G.GetContainerItemLink, bag, slot)) end
    if not id then return nil end
    return { itemId = id, count = tonumber(count) or 1, locked = locked and true or false, bound = false }
end

local function bagFamily(bag)
    local ok, _, family = call(containerFn("GetContainerNumFreeSlots"), bag)
    if not ok then return 0 end
    return tonumber(family) or 0
end

--- The stacks in the bags { bag, slot, itemId, count, locked, bound } and the
-- free slots { bag, slot } of plain bags (a split stack has to fit there).
function Mail.BagStacks()
    local stacks, free = {}, {}
    local plainLast = tonumber(NUM_BAG_SLOTS) or 4
    for _, bag in ipairs(bagList()) do
        local plain = bag <= plainLast and bagFamily(bag) == 0
        for slot = 1, numSlots(bag) do
            local info = Mail.SlotInfo(bag, slot)
            if info then
                info.bag, info.slot = bag, slot
                stacks[#stacks + 1] = info
            elseif plain then
                free[#free + 1] = { bag = bag, slot = slot }
            end
        end
    end
    return stacks, free
end

--- How many of each item the bags hold (bound items do not count).
function Mail.BagCounts(stacks)
    local counts = {}
    for _, s in ipairs(stacks or Mail.BagStacks()) do
        if not s.bound then counts[s.itemId] = (counts[s.itemId] or 0) + s.count end
    end
    return counts
end

--- Bag check for the rows: entries of the same item share the bag stock in
-- list order. Sets entry.bagMissing and group.missing (both amounts).
function Mail.CheckBags(groups, counts)
    local left = {}
    for id, count in pairs(counts or {}) do left[id] = count end
    for _, group in ipairs(groups) do
        group.missing = 0
        for _, entry in ipairs(group.entries) do
            local have = left[entry.itemId] or 0
            local take = math.min(have, entry.amount)
            left[entry.itemId] = have - take
            entry.bagMissing = entry.amount - take
            group.missing = group.missing + entry.bagMissing
        end
    end
    return groups
end

-- ---------------------------------------------------------------------------
-- Planning: which stack goes into which attachment
-- ---------------------------------------------------------------------------

--- The steps to attach these entries, at most `max` attachments. A stack that
-- fits is taken whole (largest first), the rest is split off the smallest
-- stack that is large enough - into a free bag slot while there is one.
-- An entry goes into the mail completely or not at all.
-- @return { entries, steps = { { kind = "whole"|"split", bag, slot, itemId,
--   count, entryId, target = { bag, slot } | nil } }, rest, missing }
function Mail.Plan(entries, stacks, free, max)
    max = max or Mail.MAX_ATTACHMENTS
    local pool = {}
    for _, s in ipairs(stacks or {}) do
        if not s.bound then
            pool[s.itemId] = pool[s.itemId] or {}
            table.insert(pool[s.itemId], { bag = s.bag, slot = s.slot, count = s.count })
        end
    end
    local freeLeft = {}
    for _, f in ipairs(free or {}) do freeLeft[#freeLeft + 1] = f end

    local plan = { entries = {}, steps = {}, rest = {}, missing = {} }
    for _, entry in ipairs(entries or {}) do
        local stacksOf = pool[entry.itemId] or {}
        local taken, steps, need, freeUsed = {}, {}, entry.amount, 0
        local function remaining(s) return s.count - (taken[s] or 0) end
        while need > 0 do
            local exact, bigger, smaller
            for _, s in ipairs(stacksOf) do
                local r = remaining(s)
                if r == need and not exact then exact = s end
                if r > need and (not bigger or r < remaining(bigger)) then bigger = s end
                if r > 0 and r < need and (not smaller or r > remaining(smaller)) then smaller = s end
            end
            local pick = exact or smaller or bigger
            if not pick then break end
            local count = math.min(need, remaining(pick))
            local step = { kind = count < remaining(pick) and "split" or "whole", bag = pick.bag, slot = pick.slot,
                itemId = entry.itemId, count = count, entryId = entry.id }
            if step.kind == "split" and freeLeft[freeUsed + 1] then
                freeUsed = freeUsed + 1
                step.target = freeLeft[freeUsed]
            end
            taken[pick] = (taken[pick] or 0) + count
            steps[#steps + 1] = step
            need = need - count
        end
        if need > 0 then
            plan.missing[#plan.missing + 1] = entry
        elseif #plan.steps + #steps > max then
            plan.rest[#plan.rest + 1] = entry
        else
            for s, count in pairs(taken) do s.count = s.count - count end
            for _ = 1, freeUsed do table.remove(freeLeft, 1) end
            for _, step in ipairs(steps) do plan.steps[#plan.steps + 1] = step end
            plan.entries[#plan.entries + 1] = entry
        end
    end
    return plan
end

--- Which entries a sent mail covers: in order, an entry counts when the
-- attachments still hold its full amount. { [itemId] = count } -> ids.
function Mail.Covered(entries, items)
    local left = {}
    for id, count in pairs(items or {}) do left[id] = count end
    local ids = {}
    for _, entry in ipairs(entries or {}) do
        local have = left[entry.itemId] or 0
        if have >= entry.amount then
            left[entry.itemId] = have - entry.amount
            ids[#ids + 1] = entry.id
        end
    end
    return ids
end

--- Whether recipient and player are of the same faction (unknown counts as same).
function Mail.FactionOk(group)
    local player = str(try(UnitFactionGroup, "player"))
    if player == "" then return true end
    for _, entry in ipairs(group.entries or {}) do
        local faction = type(entry.character) == "table" and str(entry.character.faction) or ""
        if faction == "" then faction = str(entry.faction) end
        if faction ~= "" and faction ~= player then return false, faction end
    end
    return true
end

--- "Rucksack Platz 3" / "Tasche 2 Platz 5".
function Mail.SlotLabel(bag, slot)
    if bag == 0 then return ("Rucksack Platz %d"):format(slot) end
    if bag > (tonumber(NUM_BAG_SLOTS) or 4) then return ("Reagenzientasche Platz %d"):format(slot) end
    return ("Tasche %d Platz %d"):format(bag, slot)
end

-- ---------------------------------------------------------------------------
-- The send frame
-- ---------------------------------------------------------------------------

function Mail.MaxAttachments()
    local max = tonumber(ATTACHMENTS_MAX_SEND) or Mail.MAX_ATTACHMENTS
    return math.max(1, math.min(max, Mail.MAX_ATTACHMENTS))
end

--- Attachment i: { itemId, count } or nil.
function Mail.SendItem(index)
    -- name, itemID, texture, count, quality, canUse (both clients)
    local ok, name, itemId, _, count = call(GetSendMailItem, index)
    if not ok or not name then return nil end
    local id = itemIdFromLink(try(GetSendMailItemLink, index)) or tonumber(itemId)
    if not id then return nil end
    return { itemId = id, count = tonumber(count) or 1 }
end

--- All attachments as { [itemId] = count } and how many there are.
function Mail.SendItems()
    local items, n = {}, 0
    for i = 1, Mail.MaxAttachments() do
        local a = Mail.SendItem(i)
        if a then
            items[a.itemId] = (items[a.itemId] or 0) + a.count
            n = n + 1
        end
    end
    return items, n
end

local function showSendTab()
    if type(MailFrameTab_OnClick) == "function" and pcall(MailFrameTab_OnClick, _G.MailFrameTab2, 2) then
        return true
    end
    local tab = _G.MailFrameTab2
    if tab and tab.Click then return (pcall(tab.Click, tab)) end
    return false
end

local function setBox(box, text)
    if type(box) == "table" and box.SetText then return (pcall(box.SetText, box, text)) end
    return false
end

local function boxText(box)
    if type(box) == "table" and box.GetText then return str(try(box.GetText, box)) end
    return ""
end

local function setBody(text)
    if setBox(_G.SendMailBodyEditBox, text) then return true end
    -- Retail: a scrolling edit box
    local box = _G.MailEditBox
    if setBox(box, text) then return true end
    if type(box) == "table" and box.GetEditBox then return setBox(try(box.GetEditBox, box), text) end
    return false
end

local function cursorHasItem()
    if type(CursorHasItem) ~= "function" then return true end
    return try(CursorHasItem) and true or false
end

local function clearCursor()
    if type(CursorHasItem) == "function" and not try(CursorHasItem) then return end
    call(ClearCursor)
end

-- ---------------------------------------------------------------------------
-- Highlighting bag slots (fallback)
-- ---------------------------------------------------------------------------

local highlights = {}

local function eachItemButton(fn)
    for i = 1, tonumber(NUM_CONTAINER_FRAMES) or 13 do
        local f = _G["ContainerFrame" .. i]
        if f and f.IsShown and f:IsShown() then
            local bag = try(f.GetID, f)
            local name = try(f.GetName, f)
            if name then
                for j = 1, 40 do
                    local b = _G[name .. "Item" .. j]
                    if not b then break end
                    fn(b, bag)
                end
            end
        end
    end
    local combined = _G.ContainerFrameCombinedBags
    if combined and combined.IsShown and try(combined.IsShown, combined) and combined.EnumerateValidItems then
        local ok, iter, a, b = pcall(combined.EnumerateValidItems, combined)
        if ok and iter then
            for _, button in iter, a, b do fn(button, nil) end
        end
    end
end

--- The button of the open bag frames that shows this slot, if any.
function Mail.FindItemButton(bag, slot)
    local found
    eachItemButton(function(button, frameBag)
        if found then return end
        local buttonBag = frameBag
        if button.GetBagID then buttonBag = try(button.GetBagID, button) or buttonBag end
        if buttonBag == bag and try(button.GetID, button) == slot then found = button end
    end)
    return found
end

local function hideHighlights()
    for _, h in ipairs(highlights) do pcall(h.Hide, h) end
end

local function highlight(index, button)
    local h = highlights[index]
    if not h then
        h = CreateFrame("Frame", nil, UIParent)
        h:SetFrameStrata("TOOLTIP")
        local fill = h:CreateTexture(nil, "OVERLAY")
        fill:SetAllPoints()
        fill:SetColorTexture(1, 0.82, 0, 0.25)
        local edges = {
            { "TOPLEFT", "TOPRIGHT", nil, 2 }, { "BOTTOMLEFT", "BOTTOMRIGHT", nil, 2 },
            { "TOPLEFT", "BOTTOMLEFT", 2, nil }, { "TOPRIGHT", "BOTTOMRIGHT", 2, nil },
        }
        for _, e in ipairs(edges) do
            local line = h:CreateTexture(nil, "OVERLAY")
            line:SetColorTexture(1, 0.82, 0, 1)
            line:SetPoint(e[1])
            line:SetPoint(e[2])
            if e[3] then line:SetWidth(e[3]) end
            if e[4] then line:SetHeight(e[4]) end
        end
        highlights[index] = h
    end
    h:ClearAllPoints()
    h:SetAllPoints(button)
    h:Show()
    h.button = button
    return h
end

--- Outline the bag slots of these steps in the open bag frames.
-- @return number how many were outlined
function Mail.Highlight(steps)
    hideHighlights()
    local n = 0
    for _, step in ipairs(steps) do
        local ok, button = pcall(Mail.FindItemButton, step.bag, step.slot)
        if ok and button then
            n = n + 1
            pcall(highlight, n, button)
        end
    end
    return n
end

function Mail.Highlights()
    return highlights
end

-- ---------------------------------------------------------------------------
-- Preparing a mail
-- ---------------------------------------------------------------------------

local function stepItemName(step, prepared)
    for _, entry in ipairs(prepared.entries) do
        if entry.id == step.entryId then return Mail.Latin1(entry.name) end
    end
    return "Item " .. step.itemId
end

--- The chat lines for dragging by hand.
function Mail.ManualLines(steps, prepared)
    local lines = {}
    for _, step in ipairs(steps) do
        local line = ("%s: %dx %s"):format(Mail.SlotLabel(step.bag, step.slot), step.count, stepItemName(step, prepared))
        if step.kind == "split" then
            local info = Mail.SlotInfo(step.bag, step.slot)
            line = line .. (" (von %d, Shift-Klick teilt den Stapel)"):format(info and info.count or step.count)
        end
        lines[#lines + 1] = line
    end
    return lines
end

local function restHint(prepared)
    if #prepared.rest > 0 then
        EHS:Print(("Noch %d Posten für %s passen nicht in diesen Brief: nach dem Senden erneut auf Post klicken.")
            :format(#prepared.rest, prepared.display))
    end
end

--- Stop attaching; the player drags the rest in.
local function manual(job, reason)
    if job.token ~= state.token then return end
    state.job = nil
    clearCursor()
    if reason == "blocked" then state.blocked = true end
    local prepared = job.prepared
    prepared.mode = "manual"
    local todo = {}
    for k = job.index, #job.steps do todo[#todo + 1] = job.steps[k] end
    if reason == "combat" then
        EHS:Print("Kampf: Anhängen abgebrochen. Den Rest bitte selbst in die Post legen:")
    elseif reason == "blocked" or reason == "known" then
        EHS:Print("Anhängen ist auf diesem Client gesperrt. Empfänger, Betreff und Text stehen drin - bitte selbst in die Post legen:")
    else
        EHS:Print("Anhängen hat nicht geklappt. Bitte selbst in die Post legen:")
    end
    for _, line in ipairs(Mail.ManualLines(todo, prepared)) do EHS:Print("  " .. line) end
    Mail.Highlight(todo)
    restHint(prepared)
    refresh()
end

local function finish(job)
    if job.token ~= state.token then return end
    state.job = nil
    local prepared = job.prepared
    prepared.mode = "ready"
    EHS:Print(("Post an %s vorbereitet: %d Posten, %d Anhänge (Porto %d Kupfer). Jetzt nur noch Senden klicken.")
        :format(prepared.display, #prepared.entries, #job.steps, #job.steps * Mail.POSTAGE))
    restHint(prepared)
    refresh()
end

--- Wait until check() is true, polling; then onOk(), else manual(job, reason).
local function waitFor(job, check, onOk, reason)
    local function poll(n)
        if job.token ~= state.token then return end
        if job.blocked then return manual(job, "blocked") end
        local ok, done = pcall(check)
        if ok and done then return onOk() end
        if n >= POLL_TRIES then return manual(job, reason or "timeout") end
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

local function nextStep(job)
    job.index = job.index + 1
    after(STEP_GAP, function()
        if job.token == state.token then doStep(job) end
    end)
end

--- The item on the cursor into attachment job.index.
local function attachCursor(job, step)
    if not cursorHasItem() then return manual(job, "blocked") end
    if not act(job, ClickSendMailItemButton, job.index) then return manual(job, "blocked") end
    waitFor(job, function()
        local a = Mail.SendItem(job.index)
        return a and a.itemId == step.itemId and a.count == step.count
    end, function()
        step.done = true
        nextStep(job)
    end)
end

local function slotReady(bag, slot, itemId, count, exact)
    local info = Mail.SlotInfo(bag, slot)
    if not info or info.locked or info.itemId ~= itemId then return false end
    if exact then return info.count == count end
    return info.count >= count
end

doStep = function(job)
    if job.token ~= state.token then return end
    local step = job.steps[job.index]
    if not step then return finish(job) end
    if inCombat() then return manual(job, "combat") end
    -- the source stack must be there and unlocked (an earlier split locks it)
    waitFor(job, function() return slotReady(step.bag, step.slot, step.itemId, step.count) end, function()
        if step.kind == "whole" then
            if not act(job, containerFn("PickupContainerItem"), step.bag, step.slot) then return manual(job, "blocked") end
            return attachCursor(job, step)
        end
        if not act(job, containerFn("SplitContainerItem"), step.bag, step.slot, step.count) then
            return manual(job, "blocked")
        end
        if not step.target then return attachCursor(job, step) end
        -- put the split stack into a free slot, then attach it from there
        if not cursorHasItem() then return manual(job, "blocked") end
        if not act(job, containerFn("PickupContainerItem"), step.target.bag, step.target.slot) then
            return manual(job, "blocked")
        end
        waitFor(job, function()
            return slotReady(step.target.bag, step.target.slot, step.itemId, step.count, true)
        end, function()
            if not act(job, containerFn("PickupContainerItem"), step.target.bag, step.target.slot) then
                return manual(job, "blocked")
            end
            attachCursor(job, step)
        end)
    end, "locked")
end

--- Remove what is attached, then start with step 1.
local function clearAndStart(job)
    local any = false
    for i = 1, Mail.MaxAttachments() do
        if Mail.SendItem(i) then
            any = true
            if not act(job, ClickSendMailItemButton, i, true) then return manual(job, "blocked") end
            -- should a client hand the item to the cursor instead of the bags
            clearCursor()
        end
    end
    if not any then return doStep(job) end
    waitFor(job, function()
        local _, n = Mail.SendItems()
        return n == 0
    end, function() doStep(job) end)
end

--- Whether the mailbox is open.
function EHS:IsMailboxOpen()
    return state.open
end

--- Be told when the mailbox opens ("open"), closes ("close") or the bags or
-- the prepared mail change ("update"). Each call runs under pcall.
function EHS:OnMailboxEvent(fn)
    if type(fn) == "function" then listeners[#listeners + 1] = fn end
end

--- The mail the addon prepared: { key, display, recipientText, entries,
-- rest, steps, mode = "attaching" | "ready" | "manual" } or nil.
function EHS:PreparedMail()
    return state.prepared
end

--- Whether attaching was blocked this session.
function EHS:MailAttachBlocked()
    return state.blocked
end

--- The open handouts grouped by recipient, each with the bag check and its
-- state for the mailbox rows: "bags" (all in the bags), "missing" (group.missing
-- short), "prepared", "busy" (being attached), "nochar", "faction".
function EHS:GetMailRows()
    local groups = self:GetHandouts()
    -- only recipients that can get mail share the bag stock
    local mailable = {}
    for _, group in ipairs(groups) do
        group.key = Mail.GroupKey(group)
        local factionOk, faction = Mail.FactionOk(group)
        group.otherFaction = not factionOk and faction or nil
        group.missing = 0
        if group.hasCharacter and factionOk then mailable[#mailable + 1] = group end
    end
    Mail.CheckBags(mailable, Mail.BagCounts())
    local prepared = state.prepared
    for _, group in ipairs(groups) do
        if not group.hasCharacter then
            group.state = "nochar"
        elseif group.otherFaction then
            group.state = "faction"
        elseif prepared and prepared.key == group.key then
            group.state = prepared.mode == "attaching" and "busy" or "prepared"
        elseif group.missing > 0 then
            group.state = "missing"
        else
            group.state = "bags"
        end
    end
    return groups
end

--- How many attachments the mail for this group would need (for the postage).
function Mail.PlanGroup(group)
    local stacks, free = Mail.BagStacks()
    return Mail.Plan(group.entries, stacks, free, Mail.MaxAttachments())
end

--- Fill the send frame for this recipient group and attach its items.
-- @return boolean started, reason
function EHS:PrepareMail(group)
    if not state.open then
        self:Print("Erst den Briefkasten öffnen.")
        return false, "closed"
    end
    if inCombat() then
        self:Print("|cffdd4444Nicht im Kampf.|r Nach dem Kampf nochmal klicken.")
        return false, "combat"
    end
    if type(group) ~= "table" or type(group.entries) ~= "table" or #group.entries == 0 then return false, "empty" end
    if not group.hasCharacter then
        self:Print(("%s hat keinen Charakter hinterlegt."):format(Mail.Latin1(group.recipient)))
        return false, "nochar"
    end
    if not Mail.FactionOk(group) then
        self:Print(("%s ist in der anderen Fraktion - keine Post möglich."):format(Mail.Latin1(group.recipient)))
        return false, "faction"
    end

    -- a new mail replaces whatever was being prepared
    state.token = state.token + 1
    state.job = nil
    hideHighlights()
    clearCursor()

    local stacks, free = Mail.BagStacks()
    local plan = Mail.Plan(group.entries, stacks, free, Mail.MaxAttachments())
    local display = Mail.Latin1(group.recipient)
    if #plan.entries == 0 then
        state.prepared = nil
        self:Print(("Für %s ist nichts davon in den Taschen."):format(display))
        refresh()
        return false, "missing"
    end

    local recipientText = Mail.RecipientName(group)
    showSendTab()
    setBox(_G.SendMailNameEditBox, recipientText)
    setBox(_G.SendMailSubjectEditBox, Mail.Subject(#plan.entries))
    setBody(Mail.Body(plan.entries))

    local prepared = {
        key = Mail.GroupKey(group), display = display, recipientText = recipientText,
        entries = plan.entries, rest = plan.rest, missing = plan.missing, steps = plan.steps, mode = "attaching",
    }
    state.prepared = prepared
    local job = { token = state.token, prepared = prepared, steps = plan.steps, index = 1 }
    state.job = job
    refresh()
    if state.blocked then
        manual(job, "known")
    else
        clearAndStart(job)
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Sending (the player's click) and the result
-- ---------------------------------------------------------------------------

--- Called after the client's SendMail: recipient and attachments of the mail
-- that goes out. The attachments are still in the send frame then; should a
-- client have cleared them already, the last known ones count.
function Mail.OnSendMail(recipient)
    local items, n = Mail.SendItems()
    if n == 0 and state.lastSeen then items = state.lastSeen end
    state.sent = { recipient = str(recipient), items = items, prepared = state.prepared }
end

local function onSendSuccess()
    local sent = state.sent
    state.sent = nil
    if not sent or not sent.prepared then return end
    local prepared = sent.prepared
    if state.prepared == prepared then
        state.prepared = nil
        state.job = nil
        state.token = state.token + 1
        state.lastSeen = nil
        hideHighlights()
    end
    if Mail.RecipientKey(sent.recipient) ~= Mail.RecipientKey(prepared.recipientText) then
        EHS:Print(("Post ging an %s statt an %s - nichts abgehakt."):format(Mail.Latin1(sent.recipient), prepared.recipientText))
        refresh()
        return
    end
    local ids = Mail.Covered(prepared.entries, sent.items)
    if #ids > 0 then EHS:MarkHandedOut(ids, "mail", EHS:PlayerFullName()) end
    EHS:Print(("Post an %s gesendet: %d Posten abgehakt."):format(prepared.display, #ids))
    local open = #prepared.entries - #ids
    if open > 0 then
        EHS:Print(("%d Posten waren nicht in der Post und bleiben offen."):format(open))
    end
    refresh()
end

local function onOpen()
    if state.open then return end
    state.open = true
    notify("open")
end

local function onClose()
    if not state.open then return end
    state.open = false
    state.token = state.token + 1
    if state.job then clearCursor() end
    state.job = nil
    state.prepared = nil
    state.lastSeen = nil
    hideHighlights()
    notify("close")
end

local function mailInfoType()
    local enum = Enum and Enum.PlayerInteractionType
    return (enum and enum.MailInfo) or MAIL_INFO_FALLBACK
end

local frame = CreateFrame("Frame")
EHS:RegisterEvents(frame, "MAIL_SHOW", "MAIL_CLOSED",
    "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_HIDE",
    "MAIL_SEND_SUCCESS", "MAIL_FAILED", "MAIL_SEND_INFO_UPDATE", "BAG_UPDATE_DELAYED",
    "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN")

frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "MAIL_SHOW" then
        onOpen()
    elseif event == "MAIL_CLOSED" then
        onClose()
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
        if arg1 == mailInfoType() then onOpen() end
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
        if arg1 == mailInfoType() then onClose() end
    elseif event == "MAIL_SEND_SUCCESS" then
        onSendSuccess()
    elseif event == "MAIL_FAILED" then
        if state.sent then
            state.sent = nil
            EHS:Print("Post nicht gesendet - nichts abgehakt.")
        end
    elseif event == "MAIL_SEND_INFO_UPDATE" then
        if state.prepared then
            local items, n = Mail.SendItems()
            if n > 0 then state.lastSeen = items end
        end
        if state.open then notify("update") end
    elseif event == "BAG_UPDATE_DELAYED" then
        if state.open then notify("update") end
    elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
        if arg1 == EHS.name and state.job then
            state.job.blocked = true
            state.blocked = true
        end
    end
end)

-- Note the mail the player sends. hooksecurefunc keeps SendMail untainted.
if type(hooksecurefunc) == "function" and type(SendMail) == "function" then
    local ok, err = pcall(hooksecurefunc, "SendMail", function(recipient)
        local fine, problem = pcall(Mail.OnSendMail, recipient)
        if not fine then EHS:Debug("Post:", tostring(problem)) end
    end)
    if not ok then EHS:Debug("Post-Hook:", tostring(err)) end
end
