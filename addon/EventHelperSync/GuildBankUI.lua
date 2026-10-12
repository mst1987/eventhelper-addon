--[[
Guild bank handouts - the window (/ehs bank, /ehb, its own minimap button,
Ctrl-click on the EventHelper minimap button, the button in the options
window, and by itself when the guild bank opens and something is waiting).

While the guild bank is open, a click on a row (not on its checkbox) takes
what the bags still lack of it out of the bank, Shift-click everything of
that recipient (GuildBankWithdraw.lua). The count column then shows "wird
geholt ..." and, once the bags hold it, "in den Taschen" in green.

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

While ticks are not yet on disk (EHS:HandoutsUnsavedCount), the title row
shows "Jetzt hochladen (/reload)" in both modes: the server learns the ticks
only from the SavedVariables, and the click is the hardware event ReloadUI()
needs.

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

-- A page of the main window (MainWindow.lua), as wide as its content area.
local PAD = 16
local WIDTH = EHS.MainLayout.pageWidth
local LIST_WIDTH = WIDTH - 2 * PAD
local ROW_HEIGHT = 30
local VISIBLE_ROWS = 13
local ICON_SIZE = 24
local MAIL_ROW_HEIGHT = 60
local VISIBLE_MAIL_ROWS = 6
local MAIL_LINES = 3
local MAIL_ICON_SIZE = 18
local MAIL_LINE_GAP = 19
local LIST_TOP = -134
local ROW_WIDTH = LIST_WIDTH - 6
-- Names, items, tab and count in the normal font; the header lines stay small.
local ROW_FONT = "GameFontHighlight"

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
    check = { 4, 22 },
    name = { 32, 130 },
    icon = { 166, ICON_SIZE },
    item = { 196, 280 },
    tab = { 482, 70 },
    count = { 556, 100 },
}
local BANK_HEADER = {
    { "", COL.check[1], COL.check[2] },
    { "Für", COL.name[1], COL.name[2] },
    { "Item", COL.icon[1], COL.icon[2] + COL.item[2] + 6 },
    { "Tab", COL.tab[1], COL.tab[2] },
    { "Bestand", COL.count[1], COL.count[2], "RIGHT" },
}
local MAIL_HEADER = {
    { "Für", 8, 120 },
    { "Items", 136, 300 },
    { "Stand", 450, 120 },
}

-- The geometry, for the specs.
EHS.GuildBankLayout = {
    width = WIDTH, rowHeight = ROW_HEIGHT, visibleRows = VISIBLE_ROWS, iconSize = ICON_SIZE, rowFont = ROW_FONT,
    mailRowHeight = MAIL_ROW_HEIGHT, visibleMailRows = VISIBLE_MAIL_ROWS, mailIconSize = MAIL_ICON_SIZE, columns = COL,
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
    else
        if entry.short then
            GameTooltip:AddLine(("Nur noch %d in der Bank, %d vorgemerkt!"):format(entry.left, entry.amount), 1, 0.82, 0, true)
        end
        GameTooltip:AddLine("Abhaken, wenn rausgegeben.", 1, 1, 1, true)
        -- taking it out of the guild bank (GuildBankWithdraw.lua)
        local missing = tonumber(entry.bagMissing) or entry.amount
        if missing <= 0 then
            GameTooltip:AddLine("In den Taschen - bereit für die Post.", 0.35, 0.9, 0.35, true)
        elseif EHS:IsGuildBankOpen() then
            local line = "Klick: in die Taschen nehmen"
            if missing < entry.amount then line = line .. (" (fehlen noch %d)"):format(missing) end
            GameTooltip:AddLine(line, 0.35, 0.9, 0.35, true)
            GameTooltip:AddLine(("Shift-Klick: alles für %s"):format(entry.recipient), 0.35, 0.9, 0.35, true)
        else
            GameTooltip:AddLine("Klick bei offener Gildenbank: in die Taschen nehmen", 0.6, 0.6, 0.6, true)
        end
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

--- The check of a row (UIKit.lua): ticked = handed out.
local function buildCheck(parent)
    local check = EHS.Kit.Check(parent, COL.check[2])
    check:SetScript("OnClick", function(self) toggleEntry(self.entry) end)
    check:SetScript("OnEnter", showRowTooltip)
    check:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return check
end

local function buildRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(ROW_WIDTH, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
    EHS.Kit.RowBackground(row, index)

    row.check = buildCheck(row)
    row.check:SetPoint("LEFT", COL.check[1], 0)

    row.name = W.text(row, ROW_FONT)
    row.name:SetPoint("LEFT", COL.name[1], 0)
    row.name:SetWidth(COL.name[2])
    if row.name.SetWordWrap then row.name:SetWordWrap(false) end

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(COL.icon[2], COL.icon[2])
    row.icon:SetPoint("LEFT", COL.icon[1], 0)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    row.item = W.text(row, ROW_FONT)
    row.item:SetPoint("LEFT", COL.item[1], 0)
    row.item:SetWidth(COL.item[2])
    if row.item.SetWordWrap then row.item:SetWordWrap(false) end

    -- The strike-through of a ticked row, across the item text.
    row.strike = W.solid(row, "OVERLAY", 0.85, 0.85, 0.85, 0.9)
    row.strike:SetHeight(1)
    row.strike:SetPoint("LEFT", row.item, "LEFT", 0, 0)
    row.strike:Hide()

    row.tab = W.text(row, ROW_FONT)
    row.tab:SetPoint("LEFT", COL.tab[1], 0)
    row.tab:SetWidth(COL.tab[2])

    row.count = W.text(row, ROW_FONT, "RIGHT")
    row.count:SetPoint("LEFT", COL.count[1], 0)
    row.count:SetWidth(COL.count[2])

    -- A click on the row (not on the checkbox) takes it out of the open guild
    -- bank, Shift-click everything of this recipient (GuildBankWithdraw.lua).
    row:RegisterForClicks("LeftButtonUp")
    row:SetScript("OnClick", function(self, button)
        local entry = self.entry
        if button ~= "LeftButton" or not entry or entry.done or not EHS:IsGuildBankOpen() then return end
        local all = IsShiftKeyDown and IsShiftKeyDown() and true or false
        local ok, entries = pcall(EHS.Withdraw.EntriesFor, entry, all)
        if not ok then return EHS:Debug("Entnehmen: Posten nicht lesbar:", tostring(entries)) end
        local started, reason = EHS:WithdrawHandouts(entries)
        if not started then EHS:Debug("Entnehmen nicht gestartet:", tostring(reason)) end
    end)
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
        local stripe = W.solid(row, "BACKGROUND", 1, 1, 1, 0.025)
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

    row.name = W.text(row, ROW_FONT)
    row.name:SetPoint("LEFT", 8, 0)
    row.name:SetWidth(108)
    if row.name.SetWordWrap then row.name:SetWordWrap(false) end

    row.lines = {}
    for k = 1, MAIL_LINES do
        local line = {}
        line.icon = row:CreateTexture(nil, "ARTWORK")
        line.icon:SetSize(MAIL_ICON_SIZE, MAIL_ICON_SIZE)
        line.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        line.text = W.text(row, ROW_FONT)
        line.text:SetWidth(252)
        if line.text.SetWordWrap then line.text:SetWordWrap(false) end
        row.lines[k] = line
    end

    row.state = W.text(row, ROW_FONT)
    row.state:SetPoint("LEFT", 450, 0)
    row.state:SetWidth(120)

    row.button = EHS.Kit.Button(row, "Post", "secondary", 80)
    row.button:SetPoint("RIGHT", -8, 0)
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
        local y = ((count - 1) / 2 - (k - 1)) * MAIL_LINE_GAP
        line.icon:ClearAllPoints()
        line.icon:SetPoint("LEFT", row, "LEFT", 136, y)
        line.text:ClearAllPoints()
        line.text:SetPoint("LEFT", row, "LEFT", 160, y)
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
    local C = EHS.Kit.C
    button.label:SetText(prepared and "Vorbereitet" or "Post")
    if prepared then
        button.bg:SetColorTexture(0.165, 0.137, 0.078, 1)
        button.label:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
    else
        button.bg:SetColorTexture(C.field[1], C.field[2], C.field[3], 1)
        button.label:SetTextColor(C.text[1], C.text[2], C.text[3])
    end
    button:SetActive(state ~= "busy")
    button:Show()
end

local function build(holder)
    local Kit = EHS.Kit
    frame = holder
    frame:SetScript("OnHide", function() autoOpened = false end)

    frame.title = Kit.Text(frame, "h2")
    frame.title:SetPoint("TOPLEFT", PAD, -14)
    frame.title:SetText("Gildenbank-Ausgabe")

    -- "Gildenbank offen" / "Briefkasten offen", right of the title
    frame.place = Kit.Pill(frame)
    frame.place:SetPoint("LEFT", frame.title, "RIGHT", 12, 0)
    frame.place:SetState("Gildenbank offen", "on")
    function frame.place:SetText(text) self:SetState(text, "on") end
    function frame.place:GetText() return self.label:GetText() end
    frame.bankOpen = frame.place

    -- Ticked handouts reach the server only with the SavedVariables, and WoW
    -- writes them on /reload or logout only. One click here is the hardware
    -- event ReloadUI() needs (Core.lua) - no hunting for /ehs upload.
    frame.upload = Kit.Button(frame, "Speichern & hochladen", "primary", 226, function() EHS:FlushAndReload() end,
        function(self)
            GameTooltip:AddLine("Abgehakte Posten hochladen")
            GameTooltip:AddLine(("%d abgehakt, der Server weiß es noch nicht."):format(self.count or 0), 1, 1, 1, true)
            GameTooltip:AddLine("Speichert und lädt die UI neu - danach meldet das Sync-Tool die Haken dem Server.",
                1, 1, 1, true)
        end)
    frame.upload:SetPoint("TOPRIGHT", -PAD, -12)
    frame.upload:Hide()

    frame.header = Kit.Text(frame, "small")
    frame.header:SetPoint("TOPLEFT", PAD, -46)
    frame.header:SetWidth(LIST_WIDTH)

    frame.summary = Kit.Text(frame, "hint")
    frame.summary:SetPoint("TOPLEFT", PAD, -62)
    frame.summary:SetWidth(LIST_WIDTH)

    -- Offen / Alle
    local defs = {}
    for _, def in ipairs(VIEW_BUTTONS) do
        defs[#defs + 1] = { label = def.label, value = def.view, tooltip = def.tooltip, onClick = function()
            EHS.db.settings.handoutsView = def.view
            offset = 0
            EHS:RefreshGuildBankUI()
        end }
    end
    frame.viewButtons = Kit.ChipRow(frame, defs, PAD, -82, 4)
    for _, chip in ipairs(frame.viewButtons) do chip.view = chip.value end

    frame.bankColumns = Kit.Header(frame, BANK_HEADER, LIST_WIDTH)
    frame.bankColumns:SetPoint("TOPLEFT", PAD, LIST_TOP + 22)
    frame.mailColumns = Kit.Header(frame, MAIL_HEADER, LIST_WIDTH)
    frame.mailColumns:SetPoint("TOPLEFT", PAD, LIST_TOP + 22)
    frame.mailColumns:Hide()

    local function onWheel(_, delta)
        local maxOffset = math.max(0, #list - visibleRows())
        offset = math.max(0, math.min(maxOffset, offset - delta * (mailMode() and 1 or 3)))
        EHS:RefreshGuildBankUI()
    end

    frame.list = CreateFrame("Frame", nil, frame)
    frame.list:SetPoint("TOPLEFT", PAD, LIST_TOP)
    frame.list:SetSize(LIST_WIDTH, VISIBLE_ROWS * ROW_HEIGHT)
    Kit.Border(frame.list, Kit.C.line)
    frame.list:EnableMouseWheel(true)
    frame.list:SetScript("OnMouseWheel", onWheel)
    for i = 1, VISIBLE_ROWS do rows[i] = buildRow(frame.list, i) end
    frame.listScroll = Kit.Thumb(frame.list)

    -- the same place at the mailbox: one row per recipient
    frame.mailList = CreateFrame("Frame", nil, frame)
    frame.mailList:SetPoint("TOPLEFT", PAD, LIST_TOP)
    frame.mailList:SetSize(LIST_WIDTH, VISIBLE_MAIL_ROWS * MAIL_ROW_HEIGHT)
    Kit.Border(frame.mailList, Kit.C.line)
    frame.mailList:EnableMouseWheel(true)
    frame.mailList:SetScript("OnMouseWheel", onWheel)
    for i = 1, VISIBLE_MAIL_ROWS do mailRows[i] = buildMailRow(frame.mailList, i) end
    frame.mailScroll = Kit.Thumb(frame.mailList)
    frame.mailList:Hide()

    frame.empty = Kit.Empty(frame, LIST_WIDTH - 40)
    frame.empty:SetPoint("TOP", frame.list, "TOP", 0, -50)
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

--- The scroll position for `count` rows of which `visible` fit.
local function setThumb(count, visible, _, anchor)
    local scroll = anchor == frame.mailList and frame.mailScroll or frame.listScroll
    scroll.Set(offset, count, visible)
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
        local unsaved = frame.upload.count or 0
        if unsaved > 0 then
            frame.summary:SetText(("%d Spieler offen - %d abgehakt, der Server erfährt es nach /reload")
                :format(#groups, unsaved))
        else
            frame.summary:SetText(("%d Spieler offen - Gesendetes wird automatisch abgehakt"):format(#groups))
        end
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

--- The count column: "14 da" / "nur 1!", or for an open entry "wird geholt
-- ..." while it is taken out of the bank and "in den Taschen" once the bags
-- hold it.
local function countText(entry)
    if not entry.done then
        if EHS:WithdrawingHandout(entry.id) then return Council.Color("wird geholt ...", 1, 0.82, 0) end
        if entry.bagMissing == 0 then return Council.Color("in den Taschen", 0.35, 0.9, 0.35) end
    end
    return Handouts.CountLabel(entry)
end

function EHS:RefreshGuildBankUI()
    -- the number on the guild bank minimap button follows every change
    if self.RefreshBankMinimap then pcall(self.RefreshBankMinimap, self) end
    if not frame or not frame:IsShown() then return end
    local mode = mailMode() and "mail" or "bank"
    if mode ~= lastMode then
        offset = 0
        lastMode = mode
    end
    frame.list:SetShown(mode == "bank")
    frame.mailList:SetShown(mode == "mail")
    frame.bankColumns:SetShown(mode == "bank")
    frame.mailColumns:SetShown(mode == "mail")
    local okCount, unsaved = pcall(self.HandoutsUnsavedCount, self)
    frame.upload.count = okCount and tonumber(unsaved) or 0
    frame.upload:SetLabel(("Speichern & hochladen (%d)"):format(frame.upload.count))
    frame.upload:SetShown(frame.upload.count > 0)
    for _, button in ipairs(frame.viewButtons) do button:SetShown(mode == "bank") end
    if mode == "mail" then
        frame.bankOpen:SetText("Briefkasten offen")
        frame.bankOpen:Show()
        return refreshMail(self)
    end
    frame.bankOpen:SetText("Gildenbank offen")

    local current = view()
    for _, chip in ipairs(frame.viewButtons) do chip:SetSelected(chip.view == current) end
    frame.bankOpen:SetShown(self:IsGuildBankOpen() and true or false)

    local entries, scope, data, status, banks = self:GetHandoutEntries()
    -- what the bags already hold (shared in list order, as at the mailbox)
    pcall(EHS.Withdraw.CheckBags, entries)
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
            row.count:SetText(countText(entry))
            row.check:SetChecked(entry.done ~= nil)
            local alpha = entry.done and 0.45 or 1
            for _, cell in ipairs({ row.name, row.icon, row.item, row.tab, row.count }) do cell:SetAlpha(alpha) end
            setStrike(row, entry.done ~= nil)
            row:Show()
        end
    end

    setThumb(#list, VISIBLE_ROWS, ROW_HEIGHT, frame.list)
end

-- A page of the main window: /ehb, its minimap button, the rail and the
-- minimap menu open it.
function EHS:ToggleGuildBankUI()
    if not self:ModuleOn("guildbank") then return self:ModuleOffNotice("guildbank") end
    local shown = self:ToggleMain("guildbank")
    -- opened by hand: stays when the guild bank or mailbox closes
    autoOpened = false
    return shown
end

function EHS:ShowGuildBankUI()
    if not self:ModuleOn("guildbank") then return self:ModuleOffNotice("guildbank") end
    return self:ShowMain("guildbank")
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
                -- Only an window opened here closes with the bank again; one
                -- that was open on another page just switches over and stays.
                local wasOpen = EHS:MainPage() ~= nil
                EHS:ShowGuildBankUI()
                autoOpened = not wasOpen
                return
            end
        end
    elseif what == "close" and autoOpened and frame and frame:IsShown() then
        autoOpened = false
        EHS:HideMain()
        return
    end
    EHS:RefreshGuildBankUI()
end

EHS:OnGuildBankEvent(onPlaceEvent)
EHS:OnMailboxEvent(onPlaceEvent)

EHS:RegisterPage({
    id = "guildbank", label = "Gildenbank", module = "guildbank", order = 30, frameName = "EventHelperSyncGuildBankFrame",
    icon = "Interface\\Icons\\INV_Box_02",
    build = build, refresh = function() EHS:RefreshGuildBankUI() end,
    sub = function()
        if EHS.IsMailboxOpen and EHS:IsMailboxOpen() then return "Briefkasten offen" end
        if EHS:IsGuildBankOpen() then return "Gildenbank offen" end
        return "Ausgabeliste"
    end,
    badge = function()
        local ok, open = pcall(EHS.HandoutCounts, EHS)
        return ok and open or 0
    end,
})

SLASH_EVENTHELPERBANK1 = "/ehb"
SlashCmdList.EVENTHELPERBANK = function() EHS:ToggleGuildBankUI() end
