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

Built like the loot-council window (CouncilUI.lua) and with its building
blocks: flat frame, no Blizzard templates, the same on TBC Anniversary and
WoW Forever.
]]

local EHS = EventHelperSync
local Handouts = EHS.Handouts
local Council = EHS.Council
local W = EHS.Widgets

local frame
local rows = {}
local offset = 0
local list = {}
-- Whether the window was opened by the guild bank (then it closes with it).
local autoOpened = false

local WIDTH = 540
local ROW_HEIGHT = 22
local VISIBLE_ROWS = 14
local LIST_TOP = -70
local ROW_WIDTH = WIDTH - 24

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

    frame.list = CreateFrame("Frame", nil, frame)
    frame.list:SetPoint("TOPLEFT", 8, LIST_TOP)
    frame.list:SetSize(WIDTH - 16, VISIBLE_ROWS * ROW_HEIGHT)
    frame.list:EnableMouseWheel(true)
    frame.list:SetScript("OnMouseWheel", function(_, delta)
        local maxOffset = math.max(0, #list - VISIBLE_ROWS)
        offset = math.max(0, math.min(maxOffset, offset - delta * 3))
        EHS:RefreshGuildBankUI()
    end)
    for i = 1, VISIBLE_ROWS do rows[i] = buildRow(frame.list, i) end

    frame.thumb = W.solid(frame.list, "OVERLAY", 0.85, 0.7, 0.35, 0.6)
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

function EHS:RefreshGuildBankUI()
    if not frame or not frame:IsShown() then return end
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

    if #list > VISIBLE_ROWS then
        local height = VISIBLE_ROWS * ROW_HEIGHT
        local thumb = math.max(16, height * VISIBLE_ROWS / #list)
        frame.thumb:SetHeight(thumb)
        frame.thumb:ClearAllPoints()
        frame.thumb:SetPoint("TOPRIGHT", frame.list, "TOPRIGHT", 0, -(height - thumb) * offset / maxOffset)
        frame.thumb:Show()
    else
        frame.thumb:Hide()
    end
end

function EHS:ToggleGuildBankUI()
    if not frame then build() end
    if frame:IsShown() then
        frame:Hide()
    else
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
-- With the guild bank
-- ---------------------------------------------------------------------------

EHS:OnGuildBankEvent(function(what)
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
        return
    end
    EHS:RefreshGuildBankUI()
end)

SLASH_EVENTHELPERBANK1 = "/ehb"
SlashCmdList.EVENTHELPERBANK = function() EHS:ToggleGuildBankUI() end
