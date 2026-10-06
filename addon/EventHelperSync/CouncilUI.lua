--[[
Loot-Council im Spiel - Fenster und Item-Tooltip.

Was der Raidleiter beim Verteilen wissen will, ohne den Browser aufzumachen:
wer wie dringend etwas braucht, und wer was schon hat.

  * Das Fenster (/ehs council, /ehc, Shift-Klick oder Mittelklick auf den
    Minimap-Knopf): eine kompakte Zeile pro Raider - Name, ein Balken fuer den
    Bedarf aus drei Teilen, Zahl der Items, BiS-Stand, letzter Loot. Alles
    Weitere steht im Tooltip der Zeile.
  * Der Item-Tooltip: auf jedem Item-Tooltip (Loot-Fenster, RCLootcouncil,
    Taschen, Links) stehen die Raider, denen genau dieses Item als BiS fehlt.
  * Die Kategorie: jede Raid-Kategorie, die auf der Webseite als Loot-Council
    laeuft, kommt mit. Gewaehlt wird sie oben im Fenster (Knopf, /ehc <Name>)
    und gemerkt in EHS.db.settings.councilCategory; in einer Raid-Instanz,
    zu der genau eine Kategorie passt, gilt die von selbst ("(auto)").

Sieht nur, wer das Addon hat - es wird nichts an den Raid geschickt.

Gebaut ohne Blizzard-Vorlagen (nur Texturen, Schriften, Knoepfe): WoW Forever
ist ein Retail-Client und kennt nicht jede Classic-Vorlage, und so sieht das
Fenster auf beiden Clients gleich aus. Jeder Client-Aufruf, den es nicht auf
beiden gibt, ist abgefragt oder in pcall.
]]

local EHS = EventHelperSync
local Council = EHS.Council

local frame
local rows = {}
local offset = 0
local list = {}

local WIDTH = 540
local CATEGORY_WIDTH = 210
local ROW_HEIGHT = 22
local VISIBLE_ROWS = 14
local LIST_TOP = -70
local BAR_WIDTH = 100

-- Spalten: x-Position und Breite innerhalb einer Zeile.
local COL = {
    name = { 4, 140 },
    bar = { 148, BAR_WIDTH },
    need = { 254, 60 },
    items = { 318, 50 },
    bis = { 370, 56 },
    last = { 428, 84 },
}

local ROLE_BUTTONS = {
    { role = "", label = "Alle" },
    { role = "caster", label = "Caster" },
    { role = "healer", label = "Heiler" },
}

local function now()
    return time()
end

--- Item-Infos ueber C_Item (Forever) oder die alte globale Funktion.
local function itemLink(itemId)
    local getter = (C_Item and C_Item.GetItemInfo) or _G.GetItemInfo
    if not getter or not itemId then return nil end
    local ok, name, link = pcall(getter, itemId)
    if ok and type(link) == "string" then return link end
    return nil
end

local function selectedRole()
    return EHS.db and EHS.db.settings and EHS.db.settings.councilRole or ""
end

-- Die zur Raid-Instanz passende Kategorie (nur fuer diese Sitzung) und der
-- Ort, fuer den sie bestimmt wurde: derselbe Ort waehlt nicht noch einmal,
-- eine Wahl von Hand bleibt dort also stehen.
local autoId, autoPlace

local function manualId()
    return EHS.db and EHS.db.settings and EHS.db.settings.councilCategory or nil
end

--- Die Kategorie, die gerade gilt.
-- @return category|nil, how ("auto" | "manual" | "default"), data
function EHS:CouncilActive()
    local data = Council.Load()
    if not data then return nil, nil, nil end
    local category, how = Council.ActiveCategory(data, manualId(), autoId)
    return category, how, data
end

--- Eine Kategorie von Hand waehlen (Knopf, Menue, /ehc <Name>).
function EHS:SetCouncilCategory(id)
    if not self.db or not self.db.settings then return end
    self.db.settings.councilCategory = id and tostring(id) or nil
    autoId = nil
    offset = 0
    self:RefreshCouncil()
end

-- ---------------------------------------------------------------------------
-- Bausteine
-- ---------------------------------------------------------------------------

local function text(parent, font, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    fs:SetJustifyH(justify or "LEFT")
    return fs
end

local function solid(parent, layer, r, g, b, a)
    local tex = parent:CreateTexture(nil, layer or "BACKGROUND")
    tex:SetColorTexture(r, g, b, a or 1)
    return tex
end

--- Ein schlichter Knopf: Text, heller beim Darueberfahren, Tooltip.
local function textButton(parent, label, width, tooltip)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(width, 18)
    button.bg = solid(button, "BACKGROUND", 1, 1, 1, 0.06)
    button.bg:SetAllPoints()
    local hl = solid(button, "HIGHLIGHT", 1, 1, 1, 0.10)
    hl:SetAllPoints()
    button.label = text(button, "GameFontNormalSmall", "CENTER")
    button.label:SetPoint("CENTER", 0, 0)
    button.label:SetText(label)
    if tooltip then
        button:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(tooltip, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    return button
end

-- Die Bausteine auch fuer das Gildenbank-Fenster (GuildBankUI.lua): gleicher Look.
EHS.Widgets = { text = text, solid = solid, textButton = textButton }

-- ---------------------------------------------------------------------------
-- Tooltip einer Zeile
-- ---------------------------------------------------------------------------

local MAX_TOOLTIP_ITEMS = 10

local function showRowTooltip(row)
    local raider = row.raider
    if not raider then return end
    local data = Council.Load()
    local weights = Council.Weights(data)
    local parts = type(raider.parts) == "table" and raider.parts or {}

    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(Council.NameLabel(raider))
    GameTooltip:AddDoubleLine("Bedarf", ("%d von 100"):format(math.floor((tonumber(raider.need) or 0) + 0.5)),
        1, 0.82, 0, Council.NeedColor(raider.need))

    for _, key in ipairs(Council.PARTS) do
        local r, g, b = unpack(Council.PART_COLOR[key])
        GameTooltip:AddDoubleLine(
            ("%s (%d%%)"):format(Council.PART_LABEL[key], math.floor(weights[key] + 0.5)),
            ("%d/100"):format(math.floor((tonumber(parts[key]) or 0) + 0.5)),
            r, g, b, 1, 1, 1)
        GameTooltip:AddLine("  " .. Council.PART_HINT[key], 0.6, 0.6, 0.6, true)
    end

    GameTooltip:AddLine(" ")
    local items = type(raider.items) == "table" and raider.items or {}
    local other = tonumber(raider.otherCount) or 0
    GameTooltip:AddLine(("Erhalten: %s%s"):format(Council.ItemsLabel(raider.lootCount),
        other > 0 and (", dazu %d Offspec/Bank"):format(other) or ""), 1, 0.82, 0)
    if #items == 0 then
        GameTooltip:AddLine("  noch kein zählendes Item", 0.6, 0.6, 0.6)
    end
    for i = 1, math.min(#items, MAX_TOOLTIP_ITEMS) do
        local item = items[i]
        local name = itemLink(item.itemId) or Council.Color(item.itemName or ("Item " .. tostring(item.itemId)), 0.8, 0.8, 0.8)
        local right = item.boss or ""
        if item.reason and item.reason ~= "" then
            right = right ~= "" and (right .. " - " .. item.reason) or item.reason
        end
        GameTooltip:AddDoubleLine(Council.FormatStamp(item.awardedAt):sub(1, 6) .. " " .. name, right,
            1, 1, 1, 0.6, 0.6, 0.6)
    end
    if #items > MAX_TOOLTIP_ITEMS then
        GameTooltip:AddLine(("  ... und %d weitere"):format(#items - MAX_TOOLTIP_ITEMS), 0.6, 0.6, 0.6)
    end

    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine("BiS-Teile offen", tostring(Council.MissingCount(raider)), 1, 0.82, 0, 1, 1, 1)
    GameTooltip:Show()
end

-- ---------------------------------------------------------------------------
-- Kategorie-Wahl
-- ---------------------------------------------------------------------------

local function showCategoryTooltip(self)
    local active, how, data = EHS:CouncilActive()
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Kategorie")
    for _, category in ipairs(Council.Categories(data)) do
        local mark = category == active and (how == "auto" and "  (aktiv, auto)" or "  (aktiv)") or ""
        if category == active then
            GameTooltip:AddLine(category.name .. mark, 1, 0.82, 0)
        else
            GameTooltip:AddLine(category.name, 1, 1, 1)
        end
    end
    GameTooltip:AddLine(" ")
    if MenuUtil and MenuUtil.CreateContextMenu then
        GameTooltip:AddLine("Klick: Kategorie wählen", 0.6, 0.6, 0.6, true)
    else
        GameTooltip:AddLine("Linksklick: nächste, Rechtsklick: vorige Kategorie", 0.6, 0.6, 0.6, true)
    end
    GameTooltip:AddLine("In einer Raid-Instanz gilt von selbst die passende Kategorie (auto). Auch: /ehc <Name>",
        0.6, 0.6, 0.6, true)
    GameTooltip:Show()
end

--- Klick auf den Kategorie-Knopf: Menue, sonst weiterschalten.
function EHS:PickCouncilCategory(owner, button)
    local active, _, data = self:CouncilActive()
    local categories = Council.Categories(data)
    if #categories == 0 then return end
    if MenuUtil and MenuUtil.CreateContextMenu then
        local ok = pcall(MenuUtil.CreateContextMenu, owner, function(_, root)
            root:CreateTitle("Kategorie")
            for _, category in ipairs(categories) do
                root:CreateRadio(category.name,
                    function() return select(1, EHS:CouncilActive()) == category end,
                    function() EHS:SetCouncilCategory(category.id) end)
            end
        end)
        if ok then return end
    end
    local current = 1
    for i, category in ipairs(categories) do
        if category == active then current = i end
    end
    local step = button == "RightButton" and -1 or 1
    local nextIndex = (current - 1 + step) % #categories + 1
    self:SetCouncilCategory(categories[nextIndex].id)
end

-- ---------------------------------------------------------------------------
-- Aufbau
-- ---------------------------------------------------------------------------

local function buildRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(WIDTH - 24, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)

    if index % 2 == 0 then
        local stripe = solid(row, "BACKGROUND", 1, 1, 1, 0.03)
        stripe:SetAllPoints()
    end
    local hl = solid(row, "HIGHLIGHT", 1, 1, 1, 0.07)
    hl:SetAllPoints()

    row.name = text(row)
    row.name:SetPoint("LEFT", COL.name[1], 0)
    row.name:SetWidth(COL.name[2])
    if row.name.SetWordWrap then row.name:SetWordWrap(false) end

    -- Der Balken: dunkler Grund, darauf die drei Teile nebeneinander.
    row.barBg = solid(row, "ARTWORK", 0.15, 0.15, 0.15, 1)
    row.barBg:SetPoint("LEFT", COL.bar[1], 0)
    row.barBg:SetSize(BAR_WIDTH, 8)
    row.segments = {}
    local previous
    for _, key in ipairs(Council.PARTS) do
        local seg = solid(row, "OVERLAY", unpack(Council.PART_COLOR[key]))
        seg:SetHeight(8)
        if previous then
            seg:SetPoint("LEFT", previous, "RIGHT", 0, 0)
        else
            seg:SetPoint("LEFT", row.barBg, "LEFT", 0, 0)
        end
        row.segments[key] = seg
        previous = seg
    end

    row.need = text(row)
    row.need:SetPoint("LEFT", COL.need[1], 0)
    row.need:SetWidth(COL.need[2])

    row.items = text(row)
    row.items:SetPoint("LEFT", COL.items[1], 0)
    row.items:SetWidth(COL.items[2])

    row.bis = text(row)
    row.bis:SetPoint("LEFT", COL.bis[1], 0)
    row.bis:SetWidth(COL.bis[2])

    row.last = text(row, "GameFontDisableSmall", "RIGHT")
    row.last:SetPoint("LEFT", COL.last[1], 0)
    row.last:SetWidth(COL.last[2])

    row:SetScript("OnEnter", showRowTooltip)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return row
end

local function savePosition(self)
    self:StopMovingOrSizing()
    local point, _, relativePoint, x, y = self:GetPoint()
    if point then EHS.db.councilPos = { point = point, relativePoint = relativePoint, x = x, y = y } end
end

local function build()
    frame = CreateFrame("Frame", "EventHelperSyncCouncilFrame", UIParent)
    frame:SetSize(WIDTH, -LIST_TOP + VISIBLE_ROWS * ROW_HEIGHT + 14)
    local pos = EHS.db.councilPos
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

    -- Hintergrund und ein schmaler Rahmen, von Hand statt per Vorlage.
    local bg = solid(frame, "BACKGROUND", 0.05, 0.05, 0.06, 0.94)
    bg:SetAllPoints()
    local edges = {
        { "TOPLEFT", "TOPRIGHT", nil, 1 }, { "BOTTOMLEFT", "BOTTOMRIGHT", nil, 1 },
        { "TOPLEFT", "BOTTOMLEFT", 1, nil }, { "TOPRIGHT", "BOTTOMRIGHT", 1, nil },
    }
    for _, e in ipairs(edges) do
        local line = solid(frame, "BORDER", 0.55, 0.45, 0.25, 1)
        line:SetPoint(e[1])
        line:SetPoint(e[2])
        if e[3] then line:SetWidth(e[3]) end
        if e[4] then line:SetHeight(e[4]) end
    end

    frame.title = text(frame, "GameFontNormal")
    frame.title:SetPoint("TOPLEFT", 12, -10)
    frame.title:SetText("Loot-Council")

    frame.close = textButton(frame, "x", 20, "Schliessen (Esc)")
    frame.close:SetPoint("TOPRIGHT", -6, -6)
    frame.close:SetScript("OnClick", function() frame:Hide() end)

    -- Kategorie-Wahl: ein flacher Knopf mit dem Namen. Klick oeffnet das
    -- Kontextmenue (MenuUtil), wo es das gibt; sonst schaltet Links-/Rechtsklick
    -- zur naechsten/vorigen Kategorie weiter.
    frame.category = textButton(frame, "", CATEGORY_WIDTH)
    frame.category:SetPoint("LEFT", frame.title, "RIGHT", 10, 0)
    frame.category.label:SetWidth(CATEGORY_WIDTH - 8)
    if frame.category.label.SetWordWrap then frame.category.label:SetWordWrap(false) end
    frame.category:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    frame.category:SetScript("OnClick", function(self, button) EHS:PickCouncilCategory(self, button) end)
    frame.category:SetScript("OnEnter", showCategoryTooltip)
    frame.category:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Rollen-Umschalter: Alle / Caster / Heiler.
    frame.roleButtons = {}
    local anchor = frame.close
    for i = #ROLE_BUTTONS, 1, -1 do
        local def = ROLE_BUTTONS[i]
        local button = textButton(frame, def.label, 52)
        button:SetPoint("RIGHT", anchor, "LEFT", -4, 0)
        button:SetScript("OnClick", function()
            EHS.db.settings.councilRole = def.role
            offset = 0
            EHS:RefreshCouncil()
        end)
        button.role = def.role
        frame.roleButtons[#frame.roleButtons + 1] = button
        anchor = button
    end

    frame.header = text(frame, "GameFontHighlightSmall")
    frame.header:SetPoint("TOPLEFT", 12, -32)
    frame.header:SetWidth(WIDTH - 50)

    frame.filter = text(frame, "GameFontDisableSmall")
    frame.filter:SetPoint("TOPLEFT", 12, -48)
    frame.filter:SetWidth(WIDTH - 50)

    -- Ein "?" statt einer Legende: die Farben erklaert der Tooltip.
    frame.help = textButton(frame, "?", 18)
    frame.help:SetPoint("TOPRIGHT", -8, -40)
    frame.help:SetScript("OnEnter", function(self)
        local weights = Council.Weights(Council.Load())
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Bedarf 0-100")
        for _, key in ipairs(Council.PARTS) do
            local r, g, b = unpack(Council.PART_COLOR[key])
            GameTooltip:AddDoubleLine(Council.PART_LABEL[key], ("%d%%"):format(math.floor(weights[key] + 0.5)), r, g, b, 1, 1, 1)
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Der Balken zeigt die drei Teile, gewichtet. Über eine Zeile fahren zeigt Details und erhaltene Items.", 1, 1, 1, true)
        GameTooltip:AddLine("Auf Item-Tooltips steht, wem das Item als BiS fehlt (in der gewählten Kategorie).", 1, 1, 1, true)
        GameTooltip:AddLine("Welche Kategorien und Filter, stellt die Webseite ein (Loot-Council-Seite).", 1, 1, 1, true)
        GameTooltip:AddLine("Neue Daten: EventHelper Sync holt sie, im Spiel dann /reload.", 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end)
    frame.help:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local line = solid(frame, "ARTWORK", 1, 1, 1, 0.12)
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
        EHS:RefreshCouncil()
    end)
    for i = 1, VISIBLE_ROWS do rows[i] = buildRow(frame.list, i) end

    -- Schlanke Positionsanzeige statt Scrollleiste: gescrollt wird mit dem Mausrad.
    frame.thumb = solid(frame.list, "OVERLAY", 0.85, 0.7, 0.35, 0.6)
    frame.thumb:SetWidth(3)

    frame.empty = text(frame, "GameFontDisable", "CENTER")
    frame.empty:SetPoint("TOP", frame.list, "TOP", 0, -40)
    frame.empty:SetWidth(WIDTH - 60)

    tinsert(UISpecialFrames, "EventHelperSyncCouncilFrame")
    frame:Hide()
end

-- ---------------------------------------------------------------------------
-- Auffrischen
-- ---------------------------------------------------------------------------

local EMPTY_TEXT = {
    none = "Noch keine Council-Daten: EventHelper Sync auf dem PC laufen lassen, dann /reload.",
    format = "CouncilData.lua ist unbrauchbar. In EventHelper Sync \"Council-Daten holen\", dann /reload.",
    version = "Die Council-Daten sind neuer als dieses Addon. Bitte das Addon aktualisieren.",
}

function EHS:RefreshCouncil()
    if not frame or not frame:IsShown() then return end
    local data, status = Council.Load()
    local role = selectedRole()

    for _, button in ipairs(frame.roleButtons) do
        if button.role == role then
            button.label:SetTextColor(1, 0.82, 0)
        else
            button.label:SetTextColor(0.6, 0.6, 0.6)
        end
    end

    local category, how
    if data then category, how = Council.ActiveCategory(data, manualId(), autoId) end

    if not data then
        list = {}
        frame.header:SetText(EMPTY_TEXT[status] or EMPTY_TEXT.none)
        frame.filter:SetText("")
        frame.empty:SetText("")
        frame.category:Hide()
    elseif not category then
        list = {}
        frame.header:SetText(Council.Header(data, now()))
        frame.filter:SetText("")
        frame.empty:SetText(Council.NO_CATEGORY_TEXT)
        frame.category:Hide()
    else
        list = Council.Raiders(category, role)
        frame.header:SetText(Council.Header(data, now()))
        frame.filter:SetText(("%s · %d Raider"):format(Council.FilterLine(category), #list))
        if #list == 0 then
            frame.empty:SetText(Council.RoleBlockedText(category, role) or "Keine Raider für diesen Filter.")
        else
            frame.empty:SetText("")
        end
        local label = category.name
        if how == "auto" then label = label .. " " .. Council.Color("(auto)", 0.6, 0.6, 0.6) end
        frame.category.label:SetText(label)
        frame.category:Show()
    end

    local maxOffset = math.max(0, #list - VISIBLE_ROWS)
    if offset > maxOffset then offset = maxOffset end
    local weights = Council.Weights(data)
    local current = now()

    for i = 1, VISIBLE_ROWS do
        local row = rows[i]
        local raider = list[i + offset]
        row.raider = raider
        if not raider then
            row:Hide()
        else
            row.name:SetText(Council.NameLabel(raider))
            local widths = Council.Segments(raider, weights, BAR_WIDTH)
            for _, key in ipairs(Council.PARTS) do
                local seg = row.segments[key]
                -- Eine Textur mit Breite 0 zeigt der Client trotzdem an: dann 1 px, aber unsichtbar.
                if widths[key] >= 0.5 then
                    seg:SetWidth(widths[key])
                    seg:SetAlpha(1)
                else
                    seg:SetWidth(0.01)
                    seg:SetAlpha(0)
                end
            end
            local need = math.floor((tonumber(raider.need) or 0) + 0.5)
            row.need:SetText(Council.Color(("Bedarf %d"):format(need), Council.NeedColor(need)))
            row.items:SetText(Council.ItemsLabel(raider.lootCount))
            row.bis:SetText(Council.BisLabel(raider))
            row.last:SetText(Council.FormatAge(raider.lastAwardAt, current))
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

function EHS:ToggleCouncil()
    if not frame then build() end
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
        self:RefreshCouncil()
    end
end

function EHS:ShowCouncil()
    if not frame then build() end
    frame:Show()
    self:RefreshCouncil()
end

-- ---------------------------------------------------------------------------
-- Item-Tooltip
-- ---------------------------------------------------------------------------

--- Steht der Abschnitt schon in diesem Tooltip? Manche Wege rufen den Hook
--- fuer denselben Tooltip zweimal auf - der Abschnitt soll nie doppelt stehen.
local function alreadyAdded(tooltip)
    local name = tooltip.GetName and tooltip:GetName()
    if not name or not tooltip.NumLines then return false end
    for i = 1, tooltip:NumLines() do
        local line = _G[name .. "TextLeft" .. i]
        if line and line.GetText and line:GetText() == Council.TOOLTIP_HEADER then return true end
    end
    return false
end

local function addCouncilLines(tooltip, itemId)
    if not tooltip or itemId == nil then return end
    if issecretvalue and issecretvalue(itemId) then return end
    itemId = tonumber(itemId)
    if not itemId then return end
    local category, how, data = EHS:CouncilActive()
    if not data then return end
    -- Die gewaehlte (oder zur Instanz passende) Kategorie; ist keine gewaehlt,
    -- alle zusammen, jeder Raider einmal.
    local source = (category and how ~= "default") and category or data
    local lines = Council.TooltipLines(source, itemId, 5)
    if not lines or alreadyAdded(tooltip) then return end
    tooltip:AddLine(Council.TOOLTIP_HEADER, 1, 0.82, 0)
    for _, line in ipairs(lines) do tooltip:AddLine(line, 1, 1, 1) end
    if tooltip.Show then pcall(tooltip.Show, tooltip) end
end
EHS.AddCouncilTooltipLines = addCouncilLines

local tooltipsHooked = false

--- Den Item-Tooltip erweitern. Forever (Retail-Client): TooltipDataProcessor.
--- TBC Anniversary: OnTooltipSetItem an GameTooltip und ItemRefTooltip.
function EHS:StartCouncilTooltips()
    if tooltipsHooked then return end
    tooltipsHooked = true

    local processor = _G.TooltipDataProcessor
    local types = Enum and Enum.TooltipDataType
    if processor and processor.AddTooltipPostCall and types and types.Item ~= nil then
        pcall(processor.AddTooltipPostCall, types.Item, function(tooltip, data)
            pcall(addCouncilLines, tooltip, type(data) == "table" and data.id or nil)
        end)
        return
    end

    for _, tooltip in ipairs({ _G.GameTooltip, _G.ItemRefTooltip }) do
        if tooltip and tooltip.HookScript then
            pcall(tooltip.HookScript, tooltip, "OnTooltipSetItem", function(self)
                pcall(function()
                    local _, link = self:GetItem()
                    local id = type(link) == "string" and link:match("item:(%d+)") or nil
                    addCouncilLines(self, id)
                end)
            end)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Kategorie zur Raid-Instanz
-- ---------------------------------------------------------------------------

--- Wo der Spieler gerade ist - nur in einer Raid-Instanz, sonst nil.
local function currentRaidPlace()
    if not GetInstanceInfo then return nil end
    local ok, name, instanceType, _, _, _, _, _, instanceId = pcall(GetInstanceInfo)
    if not ok or instanceType ~= "raid" then return nil end
    if issecretvalue and (issecretvalue(name) or issecretvalue(instanceId)) then return nil end
    local names = {}
    if type(name) == "string" and name ~= "" then names[#names + 1] = name end
    if GetRealZoneText then
        local okZone, zone = pcall(GetRealZoneText)
        if okZone and type(zone) == "string" and zone ~= "" and not (issecretvalue and issecretvalue(zone)) then
            names[#names + 1] = zone
        end
    end
    if #names == 0 and not instanceId then return nil end
    return { names = names, instanceId = instanceId }
end

--- Beim Betreten einer Raid-Instanz: passt genau eine Kategorie, gilt sie
--- (auto); passt keine oder mehrere, bleibt die Wahl von Hand. Ausserhalb von
--- Raids aendert sich nichts (ein Geisterlauf soll nicht umschalten).
function EHS:CouncilAutoSelect()
    local place = currentRaidPlace()
    if not place then return end
    local key = table.concat(place.names, "|") .. "|" .. tostring(place.instanceId or "")
    if key == autoPlace then return end
    autoPlace = key
    local data = Council.Load()
    local matches = data and Council.MatchCategories(data, place) or {}
    autoId = #matches == 1 and matches[1].id or nil
    if autoId then self:Debug("Loot-Council: Kategorie passend zur Instanz:", matches[1].name) end
    self:RefreshCouncil()
end

local autoStarted = false

--- Tooltip und automatische Kategorie-Wahl starten (PLAYER_LOGIN).
function EHS:StartCouncil()
    local ok, err = pcall(self.StartCouncilTooltips, self)
    if not ok then self:Debug("Council-Tooltip:", tostring(err)) end
    if autoStarted then return end
    autoStarted = true
    local events = CreateFrame("Frame")
    self:RegisterEvents(events, "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA")
    events:SetScript("OnEvent", function()
        local okAuto, errAuto = pcall(EHS.CouncilAutoSelect, EHS)
        if not okAuto then EHS:Debug("Council-Auswahl:", tostring(errAuto)) end
    end)
    pcall(self.CouncilAutoSelect, self)
end

-- ---------------------------------------------------------------------------
-- Status und Befehl
-- ---------------------------------------------------------------------------

--- Die Zeilen fuer /ehs status.
function EHS:CouncilStatusLines()
    local data, status = Council.Load()
    if not data then
        if status == "none" then return {} end
        return { "Loot-Council: " .. (EMPTY_TEXT[status] or EMPTY_TEXT.none) }
    end
    local categories = Council.Categories(data)
    if #categories == 0 then return { "Loot-Council: " .. Council.NO_CATEGORY_TEXT } end
    local active, how = self:CouncilActive()
    local lines = {
        ("Loot-Council: %d %s, %s."):format(#categories, #categories == 1 and "Kategorie" or "Kategorien",
            Council.Header(data, now())),
    }
    for _, category in ipairs(categories) do
        local mark = ""
        if category == active then mark = how == "auto" and " (aktiv, auto)" or " (aktiv)" end
        lines[#lines + 1] = (" · %s%s - %d Raider"):format(category.name, mark, #category.raiders)
    end
    if #categories > 1 then lines[#lines + 1] = "Kategorie wechseln: /ehc <Name>" end
    return lines
end

SLASH_EVENTHELPERCOUNCIL1 = "/ehc"
SlashCmdList.EVENTHELPERCOUNCIL = function(msg)
    local text = strtrim(msg or "")
    if text == "" then
        EHS:ToggleCouncil()
        return
    end
    -- /ehc <Name>: zur Kategorie wechseln, deren Name so anfaengt (oder es enthaelt).
    local data = Council.Load()
    local category = data and Council.CategoryByText(data, text)
    if not category then
        local names = {}
        for _, c in ipairs(Council.Categories(data)) do names[#names + 1] = c.name end
        EHS:Print(("Keine Kategorie passt zu \"%s\". Vorhanden: %s."):format(text,
            #names > 0 and table.concat(names, ", ") or "keine"))
        return
    end
    EHS:SetCouncilCategory(category.id)
    EHS:ShowCouncil()
    EHS:Print("Loot-Council: Kategorie " .. category.name .. ".")
end
