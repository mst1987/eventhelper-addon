--[[
Guild bank handouts - the window (/ehs bank, /ehb, Ctrl-click on the minimap
button, the button in the options window, and by itself when the guild bank
opens and something is waiting).

What has to go to whom: one row per handout, sorted by recipient - checkbox,
name in class colour, icon, "2x Item" in quality colour, bank tab, how many
are there. While the guild bank is open and was scanned on this visit, the
count is the live one from the scan, else the server's from the last upload.
A row shows "nur 1!" in yellow when there is not enough for it (open handouts
of the same item share the stock in list order).

Ticking stores the handout in EventHelperSyncDB.guildBankDone (see
GuildBankHandouts.lua); the next sync reports it. Ticked rows are dimmed and
struck through, "Offen" hides them.

At the mailbox the window switches to the mail mode (#18, GuildBankMail.lua):
one row per recipient with up to three item lines, whether the items are in
the bags ("in den Taschen" / "fehlt 2 in den Taschen" in yellow) and the
button "Post", which fills the send frame and attaches the items. A prepared
mail shows "in der Post" and "Vorbereitet" in gold; what is sent is ticked
off by itself.

Built like the loot-council window (CouncilUI.lua) and with its building
blocks: flat frame, no Blizzard templates, the same on TBC Anniversary and
WoW Forever.
]]

local EHS = EventHelperSync
local Handouts = EHS.Handouts
local Council = EHS.Council
local Mail = EHS.Mail
local W = EHS.Widgets

local frame
local rows = {}
local mailRows = {}
local offset = 0
local list = {}
-- Whether the window was opened by the guild bank or the mailbox (then it
-- closes with it).
local autoOpened = false
-- The mode of the last refresh, to start a switched list at the top.
local lastMode = nil

local WIDTH = 540
local ROW_HEIGHT = 22
local VISIBLE_ROWS = 14
local MAIL_ROW_HEIGHT = 44
local VISIBLE_MAIL_ROWS = 7
local MAIL_LINES = 3
local LIST_TOP = -70
local ROW_WIDTH = WIDTH - 24

local GOLD = { 1, 0.82, 0 }
local GREY = { 0.5, 0.5, 0.5 }

-- Mail rows: state text and colour.
local MAIL_STATE = {
    bags = { "in den Taschen", GREY },
    prepared = { "in der Post", GOLD },
    manual = { "selbst anhängen", GOLD },
    busy = { "wird gepackt ...", GOLD },
    nochar = { "kein Charakter", GREY },
    faction = { "andere Fraktion", { 1, 0.35, 0.35 } },
}

local function mailMode()
    return EHS.IsMailboxOpen and EHS:IsMailboxOpen() and true or false
end

local function visibleRows()
    return mailMode() and VISIBLE_MAIL_ROWS or VISIBLE_ROWS
end

-- Columns: x position and width inside a row.
local COL = {
    check = { 2, 20 },
    name = { 26, 112 },
    icon = { 142, 18 },
    item = { 164, 210 },
    tab = { 378, 58 },
    count = { 438, 74 },
}

local VIEW_BUTTONS = {
    { view = "open", label = "Offen", tooltip = "Nur was noch raus muss." },
    { view = "all", label = "Alle", tooltip = "Auch die abgehakten Posten." },
}

local function now()
    return time()
end

local function view()
    local v = EHS.db and EHS.db.settings and EHS.db.settings.handoutsView
    if v == "all" then return "all" end
    return "open"
end

--- Item link via C_Item (Forever) or the old global function, if cached.
local function itemLink(itemId)
    local getter = (C_Item and C_Item.GetItemInfo) or _G.GetItemInfo
    if not getter or not itemId or itemId <= 0 then return nil end
    local ok, _, link = pcall(getter, itemId)
    if ok and type(link) == "string" then return link end
    return nil
end

-- ---------------------------------------------------------------------------
-- Tooltip of a row
-- ---------------------------------------------------------------------------

local function showRowTooltip(owner)
    local entry = owner.entry
    if not entry then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:AddLine(itemLink(entry.itemId) or Handouts.ItemLabel(entry))
    if itemLink(entry.itemId) then GameTooltip:AddLine(("Menge: %d"):format(entry.amount), 1, 1, 1) end

    local who = Handouts.NameLabel(entry)
    if entry.hasCharacter then
        if entry.recipientRealm ~= "" then who = who .. " - " .. entry.recipientRealm end
    else
        who = who .. Council.Color(" (kein Charakter hinterlegt)", 0.6, 0.6, 0.6)
    end
    GameTooltip:AddDoubleLine("Für", who, 1, 0.82, 0, 1, 1, 1)
    if entry.purpose ~= "" then GameTooltip:AddDoubleLine("Zweck", entry.purpose, 1, 0.82, 0, 1, 1, 1) end
    if entry.requestedBy ~= "" then
        GameTooltip:AddDoubleLine("Angefragt von", entry.requestedBy
            .. (entry.requestedAt > 0 and (", " .. Council.FormatStamp(entry.requestedAt)) or ""), 1, 0.82, 0, 1, 1, 1)
    end
    if entry.confirmedBy ~= "" then
        GameTooltip:AddDoubleLine("Bestätigt von", entry.confirmedBy
            .. (entry.confirmedAt > 0 and (", " .. Council.FormatStamp(entry.confirmedAt)) or ""), 1, 0.82, 0, 1, 1, 1)
    end

    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine("In der Bank", ("%d (%s)"):format(entry.count,
        entry.live and "gerade gezählt" or "Stand letzter Scan"), 1, 0.82, 0, 1, 1, 1)
    for _, tab in ipairs(entry.stockTabs or {}) do
        local name = tab.name ~= "" and (" " .. tab.name) or ""
        GameTooltip:AddDoubleLine(("  Tab %d%s"):format(tab.index, name), tostring(tab.count), 0.8, 0.8, 0.8, 0.8, 0.8, 0.8)
    end

    GameTooltip:AddLine(" ")
    if entry.done then
        GameTooltip:AddLine(("Abgehakt von %s, %s."):format(tostring(entry.done.by or "?"),
            Council.FormatStamp(entry.done.at)), 0.35, 0.9, 0.35, true)
        GameTooltip:AddLine("Wird beim nächsten Sync gemeldet (speichern mit /ehs upload). Haken weg nimmt es zurück.",
            0.6, 0.6, 0.6, true)
    elseif entry.short then
        GameTooltip:AddLine(("Nur noch %d in der Bank, %d vorgemerkt!"):format(entry.left, entry.amount), 1, 0.82, 0, true)
        GameTooltip:AddLine("Abhaken, wenn rausgegeben.", 1, 1, 1, true)
    else
        GameTooltip:AddLine("Abhaken, wenn rausgegeben.", 1, 1, 1, true)
    end
    GameTooltip:Show()
end

-- ---------------------------------------------------------------------------
-- Building
-- ---------------------------------------------------------------------------

local function toggleEntry(entry)
    if not entry then return end
    if entry.done then
        EHS:UnmarkHandedOut(entry.id)
    else
        EHS:MarkHandedOut(entry.id, "manual")
    end
end

--- A flat checkbox: dark box, thin border, Blizzard's check mark.
local function buildCheck(parent)
    local check = CreateFrame("Button", nil, parent)
    check:SetSize(COL.check[2], COL.check[2])
    local box = W.solid(check, "ARTWORK", 0.12, 0.12, 0.12, 1)
    box:SetPoint("CENTER", 0, 0)
    box:SetSize(12, 12)
    local edges = {
        { "TOPLEFT", "TOPRIGHT", nil, 1 }, { "BOTTOMLEFT", "BOTTOMRIGHT", nil, 1 },
        { "TOPLEFT", "BOTTOMLEFT", 1, nil }, { "TOPRIGHT", "BOTTOMRIGHT", 1, nil },
    }
    for _, e in ipairs(edges) do
        local line = W.solid(check, "OVERLAY", 0.55, 0.45, 0.25, 1)
        line:SetPoint(e[1], box, e[1], 0, 0)
        line:SetPoint(e[2], box, e[2], 0, 0)
        if e[3] then line:SetWidth(e[3]) end
        if e[4] then line:SetHeight(e[4]) end
    end
    local hl = W.solid(check, "HIGHLIGHT", 1, 1, 1, 0.15)
    hl:SetPoint("CENTER", 0, 0)
    hl:SetSize(12, 12)
    check.mark = check:CreateTexture(nil, "OVERLAY")
    check.mark:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    check.mark:SetSize(18, 18)
    check.mark:SetPoint("CENTER", 1, 1)
    check.mark:Hide()
    check:SetScript("OnClick", function(self) toggleEntry(self.entry) end)
    check:SetScript("OnEnter", showRowTooltip)
    check:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return check
end

local function buildRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(ROW_WIDTH, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)

    if index % 2 == 0 then
        local stripe = W.solid(row, "BACKGROUND", 1, 1, 1, 0.03)
        stripe:SetAllPoints()
    end
    local hl = W.solid(row, "HIGHLIGHT", 1, 1, 1, 0.07)
    hl:SetAllPoints()

    row.check = buildCheck(row)
    row.check:SetPoint("LEFT", COL.check[1], 0)

    row.name = W.text(row)
    row.name:SetPoint("LEFT", COL.name[1], 0)
    row.name:SetWidth(COL.name[2])
    if row.name.SetWordWrap then row.name:SetWordWrap(false) end

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(COL.icon[2], COL.icon[2])
    row.icon:SetPoint("LEFT", COL.icon[1], 0)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    row.item = W.text(row)
    row.item:SetPoint("LEFT", COL.item[1], 0)
    row.item:SetWidth(COL.item[2])
    if row.item.SetWordWrap then row.item:SetWordWrap(false) end

    -- The strike-through of a ticked row, across the item text.
    row.strike = W.solid(row, "OVERLAY", 0.85, 0.85, 0.85, 0.9)
    row.strike:SetHeight(1)
    row.strike:SetPoint("LEFT", row.item, "LEFT", 0, 0)
    row.strike:Hide()

    row.tab = W.text(row)
    row.tab:SetPoint("LEFT", COL.tab[1], 0)
    row.tab:SetWidth(COL.tab[2])

    row.count = W.text(row, nil, "RIGHT")
    row.count:SetPoint("LEFT", COL.count[1], 0)
    row.count:SetWidth(COL.count[2])

    row:SetScript("OnEnter", showRowTooltip)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return row
end

-- ---------------------------------------------------------------------------
-- Mail rows (at the mailbox)
-- ---------------------------------------------------------------------------

local function mailStateText(group)
    if group.state == "missing" then
        return ("fehlt %d in den Taschen"):format(group.missing), GOLD
    end
    local key = group.state
    if key == "prepared" then
        local prepared = EHS:PreparedMail()
        if prepared and prepared.mode == "manual" then key = "manual" end
    end
    local def = MAIL_STATE[key] or MAIL_STATE.bags
    return def[1], def[2]
end

local function showMailTooltip(owner)
    local group = owner.group
    if not group then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    local first = group.entries[1]
    local who = first and Handouts.NameLabel(first) or group.recipient
    if group.hasCharacter and group.recipientRealm ~= "" then who = who .. " - " .. group.recipientRealm end
    GameTooltip:AddLine(who)
    for _, entry in ipairs(group.entries) do
        GameTooltip:AddDoubleLine(Handouts.ItemLabel(entry), entry.purpose, 1, 1, 1, 0.8, 0.8, 0.8)
        if (entry.bagMissing or 0) > 0 then
            GameTooltip:AddLine(("  fehlt %d in den Taschen"):format(entry.bagMissing), 1, 0.82, 0)
        end
    end
    GameTooltip:AddLine(" ")
    local state = group.state
    if state == "nochar" then
        GameTooltip:AddLine("Kein Charakter hinterlegt - im EventHelper eintragen lassen.", 0.6, 0.6, 0.6, true)
    elseif state == "faction" then
        GameTooltip:AddLine(("Andere Fraktion (%s): Post geht nicht."):format(tostring(group.otherFaction)), 1, 0.35, 0.35, true)
    elseif state == "missing" then
        GameTooltip:AddLine("Fehlt in den Taschen: erst aus der Gildenbank holen.", 1, 0.82, 0, true)
    else
        local ok, plan = pcall(Mail.PlanGroup, group)
        if ok and plan and #plan.steps > 0 then
            GameTooltip:AddDoubleLine("Porto", ("%d Kupfer (%d Anhänge à %d)"):format(#plan.steps * Mail.POSTAGE,
                #plan.steps, Mail.POSTAGE), 1, 0.82, 0, 1, 1, 1)
            if #plan.rest > 0 then
                GameTooltip:AddLine(("Mehr als %d Anhänge: %d Posten kommen in einen zweiten Brief.")
                    :format(Mail.MaxAttachments(), #plan.rest), 1, 1, 1, true)
            end
        end
        if state == "prepared" or state == "busy" then
            GameTooltip:AddLine("Liegt in der Post - jetzt Senden klicken. Gesendetes wird abgehakt.", 1, 0.82, 0, true)
        else
            GameTooltip:AddLine("Post: füllt den Brief aus und hängt alles an. Senden klickst du selbst.", 1, 1, 1, true)
        end
    end
    GameTooltip:Show()
end

local function buildMailRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(ROW_WIDTH, MAIL_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * MAIL_ROW_HEIGHT)

    if index % 2 == 0 then
        local stripe = W.solid(row, "BACKGROUND", 1, 1, 1, 0.03)
        stripe:SetAllPoints()
    end
    -- a prepared mail: gold tint and a gold bar on the left
    row.prepBg = W.solid(row, "BACKGROUND", 1, 0.82, 0, 0.08)
    row.prepBg:SetAllPoints()
    row.prepBar = W.solid(row, "ARTWORK", 1, 0.82, 0, 1)
    row.prepBar:SetPoint("TOPLEFT")
    row.prepBar:SetPoint("BOTTOMLEFT")
    row.prepBar:SetWidth(2)
    local hl = W.solid(row, "HIGHLIGHT", 1, 1, 1, 0.07)
    hl:SetAllPoints()

    row.name = W.text(row)
    row.name:SetPoint("LEFT", 8, 0)
    row.name:SetWidth(80)
    if row.name.SetWordWrap then row.name:SetWordWrap(false) end

    row.lines = {}
    for k = 1, MAIL_LINES do
        local line = {}
        line.icon = row:CreateTexture(nil, "ARTWORK")
        line.icon:SetSize(14, 14)
        line.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        line.text = W.text(row)
        line.text:SetWidth(214)
        if line.text.SetWordWrap then line.text:SetWordWrap(false) end
        row.lines[k] = line
    end

    row.state = W.text(row)
    row.state:SetPoint("LEFT", 330, 0)
    row.state:SetWidth(108)

    row.button = W.textButton(row, "Post", 70)
    row.button:SetPoint("RIGHT", -6, 0)
    row.button:SetScript("OnClick", function(self)
        local group = self:GetParent().group
        if group then EHS:PrepareMail(group) end
    end)
    row.button:SetScript("OnEnter", function(self) showMailTooltip(self:GetParent()) end)
    row.button:SetScript("OnLeave", function() GameTooltip:Hide() end)

    row:SetScript("OnEnter", showMailTooltip)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return row
end

--- Item lines of a mail row: up to three handouts, else two and "+N weitere".
local function setMailLines(row, entries)
    local shown = #entries <= MAIL_LINES and #entries or (MAIL_LINES - 1)
    local count = #entries > MAIL_LINES and MAIL_LINES or #entries
    for k = 1, MAIL_LINES do
        local line = row.lines[k]
        local y = ((count - 1) / 2 - (k - 1)) * 13
        line.icon:ClearAllPoints()
        line.icon:SetPoint("LEFT", row, "LEFT", 92, y)
        line.text:ClearAllPoints()
        line.text:SetPoint("LEFT", row, "LEFT", 110, y)
        if k <= shown then
            local entry = entries[k]
            line.icon:SetTexture(Handouts.IconTexture(entry))
            line.icon:Show()
            line.text:SetText(Handouts.ItemLabel(entry))
            line.text:Show()
        elseif k == count then
            line.icon:Hide()
            line.text:SetText(Council.Color(("+%d weitere"):format(#entries - shown), 0.6, 0.6, 0.6))
            line.text:Show()
        else
            line.icon:Hide()
            line.text:SetText("")
            line.text:Hide()
        end
    end
end

local function setMailButton(button, state)
    if state ~= "bags" and state ~= "prepared" and state ~= "busy" then
        button:Hide()
        return
    end
    local prepared = state ~= "bags"
    button.label:SetText(prepared and "Vorbereitet" or "Post")
    if prepared then
        button.bg:SetColorTexture(1, 0.82, 0, 0.18)
        button.label:SetTextColor(1, 0.82, 0)
    else
        button.bg:SetColorTexture(1, 1, 1, 0.06)
        button.label:SetTextColor(1, 1, 1)
    end
    button:SetEnabled(state ~= "busy")
    button:Show()
end

local function savePosition(self)
    self:StopMovingOrSizing()
    local point, _, relativePoint, x, y = self:GetPoint()
    if point then EHS.db.guildBankPos = { point = point, relativePoint = relativePoint, x = x, y = y } end
end

local function build()
    frame = CreateFrame("Frame", "EventHelperSyncGuildBankFrame", UIParent)
    frame:SetSize(WIDTH, -LIST_TOP + VISIBLE_ROWS * ROW_HEIGHT + 14)
    local pos = EHS.db.guildBankPos
    if pos and pos.point then
        frame:SetPoint(pos.point, UIParent, pos.relativePoint or pos.point, pos.x or 0, pos.y or 0)
    else
        frame:SetPoint("CENTER", 0, 60)
    end
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", savePosition)
    frame:SetScript("OnHide", function() autoOpened = false end)

    local bg = W.solid(frame, "BACKGROUND", 0.05, 0.05, 0.06, 0.94)
    bg:SetAllPoints()
    local edges = {
        { "TOPLEFT", "TOPRIGHT", nil, 1 }, { "BOTTOMLEFT", "BOTTOMRIGHT", nil, 1 },
        { "TOPLEFT", "BOTTOMLEFT", 1, nil }, { "TOPRIGHT", "BOTTOMRIGHT", 1, nil },
    }
    for _, e in ipairs(edges) do
        local line = W.solid(frame, "BORDER", 0.55, 0.45, 0.25, 1)
        line:SetPoint(e[1])
        line:SetPoint(e[2])
        if e[3] then line:SetWidth(e[3]) end
        if e[4] then line:SetHeight(e[4]) end
    end

    frame.title = W.text(frame, "GameFontNormal")
    frame.title:SetPoint("TOPLEFT", 12, -10)
    frame.title:SetText("Gildenbank-Ausgabe")

    frame.close = W.textButton(frame, "x", 20, "Schliessen (Esc)")
    frame.close:SetPoint("TOPRIGHT", -6, -6)
    frame.close:SetScript("OnClick", function() frame:Hide() end)

    -- Offen / Alle
    frame.viewButtons = {}
    local anchor = frame.close
    for i = #VIEW_BUTTONS, 1, -1 do
        local def = VIEW_BUTTONS[i]
        local button = W.textButton(frame, def.label, 52, def.tooltip)
        button:SetPoint("RIGHT", anchor, "LEFT", -4, 0)
        button:SetScript("OnClick", function()
            EHS.db.settings.handoutsView = def.view
            offset = 0
            EHS:RefreshGuildBankUI()
        end)
        button.view = def.view
        frame.viewButtons[#frame.viewButtons + 1] = button
        anchor = button
    end

    frame.header = W.text(frame, "GameFontHighlightSmall")
    frame.header:SetPoint("TOPLEFT", 12, -32)
    frame.header:SetWidth(WIDTH - 24)

    frame.summary = W.text(frame, "GameFontDisableSmall")
    frame.summary:SetPoint("TOPLEFT", 12, -48)
    frame.summary:SetWidth(WIDTH - 140)

    frame.bankOpen = W.text(frame, "GameFontHighlightSmall", "RIGHT")
    frame.bankOpen:SetPoint("TOPRIGHT", -12, -48)
    frame.bankOpen:SetWidth(110)
    frame.bankOpen:SetText("Gildenbank offen")
    frame.bankOpen:SetTextColor(0.35, 0.9, 0.35)

    local line = W.solid(frame, "ARTWORK", 1, 1, 1, 0.12)
    line:SetPoint("TOPLEFT", 8, LIST_TOP + 4)
    line:SetPoint("TOPRIGHT", -8, LIST_TOP + 4)
    line:SetHeight(1)

    local function onWheel(_, delta)
        local maxOffset = math.max(0, #list - visibleRows())
        offset = math.max(0, math.min(maxOffset, offset - delta * (mailMode() and 1 or 3)))
        EHS:RefreshGuildBankUI()
    end

    frame.list = CreateFrame("Frame", nil, frame)
    frame.list:SetPoint("TOPLEFT", 8, LIST_TOP)
    frame.list:SetSize(WIDTH - 16, VISIBLE_ROWS * ROW_HEIGHT)
    frame.list:EnableMouseWheel(true)
    frame.list:SetScript("OnMouseWheel", onWheel)
    for i = 1, VISIBLE_ROWS do rows[i] = buildRow(frame.list, i) end

    -- the same place at the mailbox: one row per recipient
    frame.mailList = CreateFrame("Frame", nil, frame)
    frame.mailList:SetPoint("TOPLEFT", 8, LIST_TOP)
    frame.mailList:SetSize(WIDTH - 16, VISIBLE_MAIL_ROWS * MAIL_ROW_HEIGHT)
    frame.mailList:EnableMouseWheel(true)
    frame.mailList:SetScript("OnMouseWheel", onWheel)
    for i = 1, VISIBLE_MAIL_ROWS do mailRows[i] = buildMailRow(frame.mailList, i) end
    frame.mailList:Hide()

    frame.thumb = W.solid(frame, "OVERLAY", 0.85, 0.7, 0.35, 0.6)
    frame.thumb:SetWidth(3)

    frame.empty = W.text(frame, "GameFontDisable", "CENTER")
    frame.empty:SetPoint("TOP", frame.list, "TOP", 0, -40)
    frame.empty:SetWidth(WIDTH - 60)

    tinsert(UISpecialFrames, "EventHelperSyncGuildBankFrame")
    frame:Hide()
end

-- ---------------------------------------------------------------------------
-- Refreshing
-- ---------------------------------------------------------------------------

local function setStrike(row, on)
    if not on then
        row.strike:Hide()
        return
    end
    local ok, width = pcall(row.item.GetStringWidth, row.item)
    width = ok and tonumber(width) or COL.item[2]
    row.strike:SetWidth(math.max(8, math.min(COL.item[2], width)))
    row.strike:Show()
end

--- The scroll position mark for `count` rows of which `visible` fit.
local function setThumb(count, visible, rowHeight, anchor)
    if count <= visible then
        frame.thumb:Hide()
        return
    end
    local maxOffset = math.max(1, count - visible)
    local height = visible * rowHeight
    local thumb = math.max(16, height * visible / count)
    frame.thumb:SetHeight(thumb)
    frame.thumb:ClearAllPoints()
    frame.thumb:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", 0, -(height - thumb) * offset / maxOffset)
    frame.thumb:Show()
end

--- The mailbox mode: one row per recipient.
local function refreshMail(self)
    local _, scope, data, status, banks = self:GetHandoutEntries()
    local groups = data and self:GetMailRows() or {}
    list = groups
    if not data then
        frame.header:SetText(Handouts.EMPTY_TEXT[status] or Handouts.EMPTY_TEXT.none)
        frame.summary:SetText("")
        frame.empty:SetText("")
    else
        frame.header:SetText(Handouts.Header(data, now(), scope, banks))
        frame.summary:SetText(("%d Spieler offen - Gesendetes wird automatisch abgehakt"):format(#groups))
        frame.empty:SetText(#groups == 0 and "Nichts per Post auszugeben." or "")
    end

    local maxOffset = math.max(0, #list - VISIBLE_MAIL_ROWS)
    if offset > maxOffset then offset = maxOffset end
    for i = 1, VISIBLE_MAIL_ROWS do
        local row = mailRows[i]
        local group = list[i + offset]
        row.group = group
        if not group then
            row:Hide()
        else
            local first = group.entries[1]
            row.name:SetText(first and Handouts.NameLabel(first) or group.recipient)
            setMailLines(row, group.entries)
            local text, color = mailStateText(group)
            row.state:SetText(text)
            row.state:SetTextColor(color[1], color[2], color[3])
            local prepared = group.state == "prepared" or group.state == "busy"
            row.prepBg:SetShown(prepared)
            row.prepBar:SetShown(prepared)
            setMailButton(row.button, group.state)
            row:Show()
        end
    end
    setThumb(#list, VISIBLE_MAIL_ROWS, MAIL_ROW_HEIGHT, frame.mailList)
end

function EHS:RefreshGuildBankUI()
    if not frame or not frame:IsShown() then return end
    local mode = mailMode() and "mail" or "bank"
    if mode ~= lastMode then
        offset = 0
        lastMode = mode
    end
    frame.list:SetShown(mode == "bank")
    frame.mailList:SetShown(mode == "mail")
    for _, button in ipairs(frame.viewButtons) do button:SetShown(mode == "bank") end
    if mode == "mail" then
        frame.bankOpen:SetText("Briefkasten offen")
        frame.bankOpen:Show()
        return refreshMail(self)
    end
    frame.bankOpen:SetText("Gildenbank offen")

    local current = view()
    for _, button in ipairs(frame.viewButtons) do
        if button.view == current then
            button.label:SetTextColor(1, 0.82, 0)
        else
            button.label:SetTextColor(0.6, 0.6, 0.6)
        end
    end
    frame.bankOpen:SetShown(self:IsGuildBankOpen() and true or false)

    local entries, scope, data, status, banks = self:GetHandoutEntries()
    local open, done = 0, 0
    for _, entry in ipairs(entries) do
        if entry.done then done = done + 1 else open = open + 1 end
    end

    list = {}
    if not data then
        frame.header:SetText(Handouts.EMPTY_TEXT[status] or Handouts.EMPTY_TEXT.none)
        frame.summary:SetText("")
        frame.empty:SetText("")
    else
        for _, entry in ipairs(entries) do
            if current == "all" or not entry.done then list[#list + 1] = entry end
        end
        frame.header:SetText(Handouts.Header(data, now(), scope, banks))
        frame.summary:SetText(Handouts.SummaryLine(open, done))
        if scope == "none" then
            frame.empty:SetText("Im EventHelper ist noch keine Gildenbank eingerichtet.")
        elseif #entries == 0 then
            frame.empty:SetText("Nichts auszugeben.")
        elseif #list == 0 then
            frame.empty:SetText("Alles abgehakt. Wird beim nächsten Sync gemeldet.")
        else
            frame.empty:SetText("")
        end
    end

    local maxOffset = math.max(0, #list - VISIBLE_ROWS)
    if offset > maxOffset then offset = maxOffset end

    for i = 1, VISIBLE_ROWS do
        local row = rows[i]
        local entry = list[i + offset]
        row.entry = entry
        row.check.entry = entry
        if not entry then
            row:Hide()
        else
            -- Grouped by recipient: the name on the first row of a group (and
            -- on the top row, so a group scrolled into view keeps its name).
            local previous = list[i + offset - 1]
            local first = i == 1 or not previous or previous.recipient ~= entry.recipient
                or previous.recipientRealm ~= entry.recipientRealm
            row.name:SetText(first and Handouts.NameLabel(entry) or "")
            row.icon:SetTexture(Handouts.IconTexture(entry))
            row.item:SetText(Handouts.ItemLabel(entry))
            row.tab:SetText(Handouts.TabLabel(entry))
            row.count:SetText(Handouts.CountLabel(entry))
            if entry.done then
                row.check.mark:Show()
            else
                row.check.mark:Hide()
            end
            local alpha = entry.done and 0.45 or 1
            for _, cell in ipairs({ row.name, row.icon, row.item, row.tab, row.count }) do cell:SetAlpha(alpha) end
            setStrike(row, entry.done ~= nil)
            row:Show()
        end
    end

    setThumb(#list, VISIBLE_ROWS, ROW_HEIGHT, frame.list)
end

function EHS:ToggleGuildBankUI()
    if not frame then build() end
    if frame:IsShown() then
        frame:Hide()
    else
        -- opened by hand: stays when the guild bank or mailbox closes
        autoOpened = false
        frame:Show()
        self:RefreshGuildBankUI()
    end
end

function EHS:ShowGuildBankUI()
    if not frame then build() end
    frame:Show()
    self:RefreshGuildBankUI()
end

-- ---------------------------------------------------------------------------
-- With the guild bank and the mailbox
-- ---------------------------------------------------------------------------

--- Open by itself when something is waiting (setting autoOpenHandouts), and
-- close again with the guild bank / mailbox that opened it.
local function onPlaceEvent(what)
    if what == "open" then
        local settings = EHS.db and EHS.db.settings or {}
        if settings.autoOpenHandouts ~= false and not (frame and frame:IsShown()) then
            local open = EHS:HandoutCounts()
            if open > 0 then
                EHS:ShowGuildBankUI()
                autoOpened = true
                return
            end
        end
    elseif what == "close" and autoOpened and frame and frame:IsShown() then
        frame:Hide()
        autoOpened = false
        return
    end
    EHS:RefreshGuildBankUI()
end

EHS:OnGuildBankEvent(onPlaceEvent)
EHS:OnMailboxEvent(onPlaceEvent)

SLASH_EVENTHELPERBANK1 = "/ehb"
SlashCmdList.EVENTHELPERBANK = function() EHS:ToggleGuildBankUI() end
