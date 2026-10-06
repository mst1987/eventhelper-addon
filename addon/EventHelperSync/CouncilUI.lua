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
        GameTooltip:AddLine("Auf Item-Tooltips steht, wem das Item als BiS fehlt.", 1, 1, 1, true)
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

    if not data then
        list = {}
        frame.header:SetText(EMPTY_TEXT[status] or EMPTY_TEXT.none)
        frame.filter:SetText("")
        frame.empty:SetText("")
    else
        list = Council.Raiders(data, role)
        frame.header:SetText(Council.Header(data, now()))
        frame.filter:SetText(("%s · %d Raider"):format(Council.FilterLine(data), #list))
        frame.empty:SetText(#list == 0 and "Keine Raider für diesen Filter." or "")
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
    local data = Council.Load()
    if not data then return end
    local lines = Council.TooltipLines(data, itemId, 5)
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
-- Befehl
-- ---------------------------------------------------------------------------

SLASH_EVENTHELPERCOUNCIL1 = "/ehc"
SlashCmdList.EVENTHELPERCOUNCIL = function() EHS:ToggleCouncil() end
