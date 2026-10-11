--[[
Loot-Council im Spiel - Fenster und Item-Tooltip.

Was der Raidleiter beim Verteilen wissen will, ohne den Browser aufzumachen:
wer wie dringend etwas braucht, und wer was schon hat.

  * Das Fenster (/ehs council, /ehc, Shift-Klick oder Mittelklick auf den
    Minimap-Knopf): eine kompakte Zeile pro Raider - Name (mit Probe/Ersatz),
    Rollen-Knoepfe Alle/Caster/Heiler/Tank/Nahkampf/Fernkampf, ein Balken fuer den
    Bedarf aus drei Teilen (mit Gewichtung der Kategorie vier), Zahl der Items
    (und Punkte), BiS-Stand, letzter Loot. Alles
    Weitere steht im Tooltip der Zeile.
  * Der Item-Tooltip: auf jedem Item-Tooltip (Loot-Fenster, RCLootcouncil,
    Taschen, Links) stehen die Raider, denen genau dieses Item als BiS fehlt.
  * Die Kategorie: jede Raid-Kategorie, die auf der Webseite als Loot-Council
    laeuft, kommt mit. Gewaehlt wird sie oben im Fenster (Knopf, /ehc <Name>)
    und gemerkt in EHS.db.settings.councilCategory; in einer Raid-Instanz,
    zu der genau eine Kategorie passt, gilt die von selbst ("(auto)").

  * Vergaben seit dem letzten Sync: was RCLootcouncil/Gargul seitdem
    vergeben haben, rechnet das Fenster samt Tooltip live und vorlaeufig
    dazu (Council.ApplyAwards, markiert mit "*").

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

-- Ein Bereich im Hauptfenster (MainWindow.lua): so breit wie dessen Inhaltsfeld.
local PAD = 16
local WIDTH = EHS.MainLayout.pageWidth
local LIST_WIDTH = WIDTH - 2 * PAD
local CATEGORY_WIDTH = 230
local ROW_HEIGHT = 28
local VISIBLE_ROWS = 14
local LIST_TOP = -134
local BAR_WIDTH = 120

-- Spalten: x-Position und Breite innerhalb einer Zeile.
-- "Erhalten" ist breit genug fuer "12 Items · 25,5 Pkt" (Version 3).
local COL = {
    name = { 8, 180 },
    bar = { 194, BAR_WIDTH },
    need = { 320, 40 },
    items = { 372, 150 },
    bis = { 528, 66 },
    last = { 598, 58 },
}
local HEADER = {
    { "Raider", COL.name[1], COL.name[2] },
    { "Bedarf", COL.bar[1], COL.bar[2] + COL.need[2] + 6 },
    { "Erhalten", COL.items[1], COL.items[2] },
    { "BiS", COL.bis[1], COL.bis[2] },
    { "Zuletzt", COL.last[1], COL.last[2], "RIGHT" },
}

-- Rollen als Auswahl-Chips unter dem Titel.
local ROLE_BUTTONS = {
    { role = "", label = "Alle" },
    { role = "caster", label = "Caster" },
    { role = "healer", label = "Heiler" },
    { role = "tank", label = "Tank" },
    { role = "melee", label = "Nahkampf" },
    { role = "ranged", label = "Fernkampf" },
}
local ROLE_GAP = 4
EHS.CouncilLayout = { WIDTH = WIDTH, ROLE_BUTTONS = ROLE_BUTTONS, ROLE_GAP = ROLE_GAP, COL = COL, BAR_WIDTH = BAR_WIDTH }

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

-- ---------------------------------------------------------------------------
-- Vergaben seit dem letzten Sync, live
-- ---------------------------------------------------------------------------
--
-- Die Council-Daten sind der Stand des letzten Syncs. Was seitdem vergeben
-- wurde, steht schon in RCLootcouncils und Garguls Historie: das rechnet
-- Council.ApplyAwards() vorlaeufig dazu. Neu gerechnet wird nur, wenn sich
-- die Historien (Zahl der Eintraege) oder die Council-Daten geaendert haben -
-- beim Oeffnen des Fensters, beim Item-Tooltip (hoechstens einmal pro
-- Sekunde nachgesehen) und alle LIVE_INTERVAL Sekunden bei offenem Fenster.
-- Keine Haken in RCLootcouncil: nur Lesen, alles unter pcall.

local LIVE_INTERVAL = 3
local live = { base = nil, signature = nil, data = nil, checkedAt = nil }

local function historySignature()
    local ok, signature = pcall(EHS.AwardHistorySignature, EHS)
    return ok and signature or "?"
end

--- Die Vergaben seit `since`; Gargul-Zeilen ohne Instanz bekommen sie aus
--- der eigenen Zonen-Zeitleiste (wie die Sessions).
local function awardsSince(since)
    local ok, rows = pcall(EHS.AwardsSince, EHS, since)
    if not ok or type(rows) ~= "table" then return {} end
    for _, row in ipairs(rows) do
        if (row.instance or "") == "" and EHS.ZoneAt then
            local okZone, zone = pcall(EHS.ZoneAt, EHS, row.awardedAt)
            if okZone and type(zone) == "string" then row.instance = zone end
        end
    end
    return rows
end

--- Die Council-Daten samt den Vergaben seit dem letzten Sync.
-- @param force nachsehen, auch wenn es eben erst geschah (Fenster)
-- @return data|nil, status wie Council.Load()
function EHS:CouncilData(force)
    local data, status = Council.Load()
    if not data then return data, status end
    local current = now()
    if live.base == data and live.data and not force and live.checkedAt == current then
        return live.data, status
    end
    live.checkedAt = current
    local signature = historySignature()
    if live.base == data and live.data and live.signature == signature then return live.data, status end
    local ok, adjusted = pcall(Council.ApplyAwards, data, awardsSince(data.generatedAt), current)
    if not ok then
        self:Debug("Loot-Council, Vergaben seit dem Sync:", tostring(adjusted))
        adjusted = data
    end
    live.base, live.signature, live.data = data, signature, adjusted or data
    return live.data, status
end

--- Alle LIVE_INTERVAL Sekunden bei offenem Fenster: hat sich eine Historie
--- geaendert, neu rechnen und neu zeichnen.
function EHS:CouncilLiveTick()
    if live.signature ~= historySignature() or live.base ~= Council.Load() then
        self:RefreshCouncil()
    end
end

--- Die Kategorie, die gerade gilt.
-- @return category|nil, how ("auto" | "manual" | "default"), data
function EHS:CouncilActive()
    local data = self:CouncilData()
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
    if self.RefreshSuggest then self:RefreshSuggest() end
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

-- Die Kategorie, deren Raider das Fenster gerade zeigt (fuer die Tooltips).
local shownCategory

local STATUS_TEXT = { trial = "Probe (Roster)", bench = "Ersatz (Roster)" }

local function showRowTooltip(row)
    local raider = row.raider
    if not raider then return end
    local data = Council.Load()
    local category = shownCategory
    local weights = Council.WeightsFor(data, category)
    local weighted = Council.IsWeighted(category)
    local parts = type(raider.parts) == "table" and raider.parts or {}

    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(Council.NameLabel(raider))
    if STATUS_TEXT[raider.status] then
        GameTooltip:AddLine(STATUS_TEXT[raider.status], unpack(Council.STATUS_COLOR[raider.status]))
    end
    GameTooltip:AddDoubleLine("Bedarf", ("%d von 100"):format(math.floor((tonumber(raider.need) or 0) + 0.5))
        .. Council.ProvisionalMark(raider), 1, 0.82, 0, Council.NeedColor(raider.need))

    -- Vorlaeufig: Vergaben seit dem letzten Sync, oder nur ein neuer Schnitt.
    local provisional = Council.ProvisionalRaiderLine(raider)
    local pr, pg, pb = unpack(Council.PROVISIONAL_COLOR)
    if provisional then
        GameTooltip:AddLine(provisional, pr, pg, pb, true)
        for _, award in ipairs(raider.provisional.awards) do
            local name = itemLink(award.itemId)
                or Council.Color(award.itemName ~= "" and award.itemName or ("Item " .. tostring(award.itemId)), 0.8, 0.8, 0.8)
            local right = award.reason or ""
            if not award.counts then right = right .. " (zählt nicht)" end
            if award.bis then right = right .. ", BiS" end
            if award.weight then right = right .. ", " .. Council.PointsLabel(award.weight) end
            GameTooltip:AddDoubleLine("  " .. Council.FormatStamp(award.awardedAt) .. " " .. name, right,
                1, 1, 1, 0.6, 0.6, 0.6)
        end
    elseif Council.ProvisionalKind(raider) == "avg" then
        local why = weighted and "Schnitt und Tage haben sich seit dem letzten Sync verschoben."
            or "der Schnitt hat sich durch Vergaben seit dem letzten Sync verschoben."
        GameTooltip:AddLine(("Vorläufig: vorher Bedarf %d, %s")
            :format(math.floor((tonumber(raider.needBefore) or 0) + 0.5), why), 0.6, 0.6, 0.6, true)
    end

    for _, key in ipairs(Council.PartsOf(category)) do
        local r, g, b = unpack(Council.PART_COLOR[key])
        GameTooltip:AddDoubleLine(
            ("%s (%d%%)"):format(Council.PART_LABEL[key], math.floor((tonumber(weights[key]) or 0) + 0.5)),
            ("%d/100"):format(math.floor((tonumber(parts[key]) or 0) + 0.5)),
            r, g, b, 1, 1, 1)
        GameTooltip:AddLine("  " .. Council.PART_HINT[key], 0.6, 0.6, 0.6, true)
    end
    if weighted and (tonumber(raider.joinedAt) or 0) > 0 then
        GameTooltip:AddDoubleLine("Dabei seit", ("%s (%d Tage)"):format(date("%d.%m.%Y", raider.joinedAt),
            math.floor((tonumber(raider.tenureDays) or 0) + 0.5)), 0.6, 0.6, 0.6, 1, 1, 1)
    end

    GameTooltip:AddLine(" ")
    local items = type(raider.items) == "table" and raider.items or {}
    local other = tonumber(raider.otherCount) or 0
    GameTooltip:AddLine(("Erhalten: %s%s"):format(Council.LootLabel(raider, weighted),
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
        if weighted and tonumber(item.weight) then
            right = right .. " · " .. Council.PointsLabel(item.weight)
        end
        local stamp = Council.FormatStamp(item.awardedAt):sub(1, 6)
        if item.provisional then stamp = Council.Color(stamp .. "*", unpack(Council.PROVISIONAL_COLOR)) end
        GameTooltip:AddDoubleLine(stamp .. " " .. name, right,
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
-- Auch fuer den Kategorie-Knopf im EventHelper-Vorschlag (RCLCSuggestUI.lua).
EHS.ShowCouncilCategoryTooltip = showCategoryTooltip

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
                    function()
                        local current = EHS:CouncilActive()
                        return current ~= nil and current.id == category.id
                    end,
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
    row:SetSize(LIST_WIDTH - 6, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
    EHS.Kit.RowBackground(row, index)

    row.name = text(row, EHS.Kit.FontFor("body"))
    row.name:SetPoint("LEFT", COL.name[1], 0)
    row.name:SetWidth(COL.name[2])
    if row.name.SetWordWrap then row.name:SetWordWrap(false) end

    -- Der Balken: dunkler Grund, darauf die Teile nebeneinander (drei, mit
    -- Gewichtung der Kategorie vier; ein Teil ohne Breite ist unsichtbar).
    row.barBg = solid(row, "ARTWORK", 0.15, 0.15, 0.15, 1)
    row.barBg:SetPoint("LEFT", COL.bar[1], 0)
    row.barBg:SetSize(BAR_WIDTH, 8)
    row.segments = {}
    local previous
    for _, key in ipairs(Council.PARTS_V3) do
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

    row.need = text(row, EHS.Kit.FontFor("big"), "RIGHT")
    row.need:SetPoint("LEFT", COL.need[1], 0)
    row.need:SetWidth(COL.need[2])

    row.items = text(row, EHS.Kit.FontFor("body"))
    row.items:SetPoint("LEFT", COL.items[1], 0)
    row.items:SetWidth(COL.items[2])

    row.bis = text(row, EHS.Kit.FontFor("body"))
    row.bis:SetPoint("LEFT", COL.bis[1], 0)
    row.bis:SetWidth(COL.bis[2])

    -- one line per cell: a wrapped cell would spill into the next row
    for _, cell in ipairs({ row.need, row.items, row.bis }) do
        if cell.SetWordWrap then cell:SetWordWrap(false) end
    end

    row.last = text(row, "GameFontDisableSmall", "RIGHT")
    row.last:SetPoint("LEFT", COL.last[1], 0)
    row.last:SetWidth(COL.last[2])

    row:SetScript("OnEnter", showRowTooltip)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return row
end

local function build(holder)
    local Kit = EHS.Kit
    frame = holder

    frame.title = Kit.Text(frame, "h2")
    frame.title:SetPoint("TOPLEFT", PAD, -14)
    frame.title:SetText("Loot-Council")

    -- Ein "?" statt einer Legende: die Farben erklaert der Tooltip.
    frame.help = Kit.Button(frame, "?", "secondary", 26)
    frame.help:SetPoint("TOPRIGHT", -PAD, -14)

    -- Kategorie-Wahl: ein Knopf mit dem Namen. Klick oeffnet das Kontextmenue
    -- (MenuUtil), wo es das gibt; sonst schaltet Links-/Rechtsklick zur
    -- naechsten/vorigen Kategorie weiter.
    frame.category = Kit.Button(frame, "", "secondary", CATEGORY_WIDTH,
        function(self, button) EHS:PickCouncilCategory(self, button) end)
    frame.category:SetPoint("RIGHT", frame.help, "LEFT", -6, 0)
    frame.category.label:SetWidth(CATEGORY_WIDTH - 12)
    frame.category:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    frame.category:SetScript("OnEnter", showCategoryTooltip)
    frame.category:SetScript("OnLeave", function() GameTooltip:Hide() end)

    frame.header = Kit.Text(frame, "small")
    frame.header:SetPoint("TOPLEFT", PAD, -46)
    frame.header:SetWidth(LIST_WIDTH)

    frame.filter = Kit.Text(frame, "hint")
    frame.filter:SetPoint("TOPLEFT", PAD, -62)
    frame.filter:SetWidth(LIST_WIDTH)

    -- Rollen: Alle | Caster | Heiler | Tank | Nahkampf | Fernkampf.
    local defs = {}
    for _, def in ipairs(ROLE_BUTTONS) do
        defs[#defs + 1] = { label = def.label, value = def.role, onClick = function()
            EHS.db.settings.councilRole = def.role
            offset = 0
            EHS:RefreshCouncil()
        end }
    end
    frame.roleButtons = Kit.ChipRow(frame, defs, PAD, -82, ROLE_GAP)
    for _, chip in ipairs(frame.roleButtons) do chip.role = chip.value end

    frame.help:SetScript("OnEnter", function(self)
        local data = Council.Load()
        local weights = Council.WeightsFor(data, shownCategory)
        local keys = Council.PartsOf(shownCategory)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Bedarf 0-100")
        for _, key in ipairs(keys) do
            local r, g, b = unpack(Council.PART_COLOR[key])
            GameTooltip:AddDoubleLine(Council.PART_LABEL[key], ("%d%%"):format(math.floor((tonumber(weights[key]) or 0) + 0.5)),
                r, g, b, 1, 1, 1)
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(("Der Balken zeigt die %s Teile, gewichtet. Über eine Zeile fahren zeigt Details und erhaltene Items.")
            :format(#keys == 4 and "vier" or "drei"), 1, 1, 1, true)
        if Council.IsWeighted(shownCategory) then
            GameTooltip:AddLine("Items zählen mit ihrem Gewicht (Pkt): Trinkets und BiS-Waffen mehr, häufige Drops weniger "
                .. "- eingestellt auf der Webseite (Loot-Council, Gewichtung).", 1, 1, 1, true)
        end
        GameTooltip:AddLine("Probe/Ersatz: Status im Roster der Kategorie.", 0.45, 0.78, 1.00, true)
        GameTooltip:AddLine("Auf Item-Tooltips steht, wem das Item als BiS fehlt (in der gewählten Kategorie).", 1, 1, 1, true)
        GameTooltip:AddLine("* = vorläufig: Vergaben aus RCLootCouncil/Gargul seit dem letzten Sync sind schon mitgerechnet "
            .. "(orange: eigene Vergaben, grau: nur der Schnitt hat sich verschoben).", 1, 0.55, 0.15, true)
        GameTooltip:AddLine("Welche Kategorien und Filter, stellt die Webseite ein (Loot-Council-Seite).", 1, 1, 1, true)
        GameTooltip:AddLine("Neue Daten: EventHelper Sync holt sie, im Spiel dann /reload.", 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end)
    frame.help:SetScript("OnLeave", function() GameTooltip:Hide() end)

    frame.columns = Kit.Header(frame, HEADER, LIST_WIDTH)
    frame.columns:SetPoint("TOPLEFT", PAD, LIST_TOP + 22)

    frame.list = CreateFrame("Frame", nil, frame)
    frame.list:SetPoint("TOPLEFT", PAD, LIST_TOP)
    frame.list:SetSize(LIST_WIDTH, VISIBLE_ROWS * ROW_HEIGHT)
    Kit.Border(frame.list, Kit.C.line)
    frame.list:EnableMouseWheel(true)
    frame.list:SetScript("OnMouseWheel", function(_, delta)
        local maxOffset = math.max(0, #list - VISIBLE_ROWS)
        offset = math.max(0, math.min(maxOffset, offset - delta * 3))
        EHS:RefreshCouncil()
    end)
    for i = 1, VISIBLE_ROWS do rows[i] = buildRow(frame.list, i) end

    -- Bildlauf mit dem Mausrad; die Spur rechts zeigt, wo man ist.
    frame.scroll = Kit.Thumb(frame.list)
    frame.thumb = frame.scroll.thumb

    frame.empty = Kit.Empty(frame, LIST_WIDTH - 40)
    frame.empty:SetPoint("TOP", frame.list, "TOP", 0, -50)

    -- Live: alle LIVE_INTERVAL Sekunden, solange das Fenster offen ist (OnUpdate
    -- laeuft nur bei sichtbarem Frame), billig nachsehen, ob neue Vergaben da sind.
    frame:SetScript("OnUpdate", function(self, elapsed)
        self.liveElapsed = (self.liveElapsed or 0) + (tonumber(elapsed) or 0)
        if self.liveElapsed < LIVE_INTERVAL then return end
        self.liveElapsed = 0
        local ok, err = pcall(EHS.CouncilLiveTick, EHS)
        if not ok then EHS:Debug("Loot-Council live:", tostring(err)) end
    end)
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
    local data, status = self:CouncilData(true)
    local role = selectedRole()

    for _, chip in ipairs(frame.roleButtons) do chip:SetSelected(chip.role == role) end

    local category, how
    if data then category, how = Council.ActiveCategory(data, manualId(), autoId) end
    shownCategory = category

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
        local header = Council.Header(data, now())
        local provisional = Council.ProvisionalHeader(data, category)
        if provisional then
            header = header .. "  ·  " .. Council.Color(provisional, unpack(Council.PROVISIONAL_COLOR))
        end
        frame.header:SetText(header)
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
    local weights = Council.WeightsFor(data, category)
    local keys = Council.PartsOf(category)
    local weighted = Council.IsWeighted(category)
    local current = now()

    for i = 1, VISIBLE_ROWS do
        local row = rows[i]
        local raider = list[i + offset]
        row.raider = raider
        if not raider then
            row:Hide()
        else
            row.name:SetText(Council.NameLabel(raider))
            local widths = Council.Segments(raider, weights, BAR_WIDTH, keys)
            for _, key in ipairs(Council.PARTS_V3) do
                local seg = row.segments[key]
                -- Eine Textur mit Breite 0 zeigt der Client trotzdem an: dann 1 px, aber unsichtbar.
                if (widths[key] or 0) >= 0.5 then
                    seg:SetWidth(widths[key])
                    seg:SetAlpha(1)
                else
                    seg:SetWidth(0.01)
                    seg:SetAlpha(0)
                end
            end
            local need = math.floor((tonumber(raider.need) or 0) + 0.5)
            row.need:SetText(Council.Color(tostring(need), Council.NeedColor(need))
                .. Council.ProvisionalMark(raider))
            row.items:SetText(Council.LootLabel(raider, weighted))
            row.bis:SetText(Council.BisLabel(raider))
            row.last:SetText(Council.FormatAge(raider.lastAwardAt, current))
            row:Show()
        end
    end

    frame.scroll.Set(offset, #list, VISIBLE_ROWS)
end

-- Ein Bereich im Hauptfenster: /ehc, die Leiste und das Minimap-Menue oeffnen ihn.
function EHS:ToggleCouncil()
    if not self:ModuleOn("council") then return self:ModuleOffNotice("council") end
    return self:ToggleMain("council")
end

function EHS:ShowCouncil()
    if not self:ModuleOn("council") then return self:ModuleOffNotice("council") end
    return self:ShowMain("council")
end

EHS:RegisterPage({
    id = "council", label = "Loot-Council", module = "council", order = 20, frameName = "EventHelperSyncCouncilFrame",
    icon = "Interface\\Icons\\INV_Misc_Coin_02",
    build = build, refresh = function() EHS:RefreshCouncil() end,
    sub = function()
        local category = EHS:CouncilActive()
        return category and category.name or "keine Daten"
    end,
})

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
    -- The hook stays once set; with the module off it adds nothing (Modules.lua).
    if not EHS:ModuleOn("council") then return end
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
    if self.RefreshSuggest then self:RefreshSuggest() end
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
    local data, status = self:CouncilData(true)
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
    local provisional = Council.ProvisionalHeader(data)
    if provisional then
        lines[#lines + 1] = (" · %s (RCLootCouncil/Gargul, vom Sync noch nicht erfasst)"):format(provisional)
    end
    if #categories > 1 then lines[#lines + 1] = "Kategorie wechseln: /ehc <Name>" end
    return lines
end

SLASH_EVENTHELPERCOUNCIL1 = "/ehc"
SlashCmdList.EVENTHELPERCOUNCIL = function(msg)
    if not EHS:ModuleOn("council") then return EHS:ModuleOffNotice("council") end
    local text = strtrim(msg or "")
    if text == "" then
        EHS:ToggleCouncil()
        return
    end
    -- /ehc vorschlag: der EventHelper-Vorschlag neben RCLootCouncil (RCLCSuggestUI.lua).
    if strlower(text) == "vorschlag" and EHS.ToggleSuggest then
        EHS:ToggleSuggest()
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
