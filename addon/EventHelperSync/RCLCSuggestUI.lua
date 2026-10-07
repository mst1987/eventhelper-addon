--[[
EventHelper-Vorschlag - das Fenster neben RCLootCouncils Abstimmung.

Startet in RCLootCouncil eine Abstimmung (ein Council-Mitglied bekommt die
Loot-Tabelle), oeffnet sich rechts am Abstimmungsfenster ein schmales
Fenster im Stil des Loot-Council-Fensters: je Item der Sitzung eine Zeile
(Caster/Heiler/-, Vorschlag), darunter fuer das gewaehlte Item die Rangliste
aus RCLC-Antwort, BiS-Luecke und Bedarf (RCLCSuggest.lua). Es haengt am
Abstimmungsfenster und wandert mit; gibt es das nicht, steht es frei und
laesst sich ziehen.

Woher die Daten kommen (RCLootCouncil_Classic 1.5.1, wie Retail-RCLootCouncil):
  * das Modul RCLootCouncil:GetActiveModule("votingframe") (RCVotingFrame),
    seine Loot-Tabelle :GetLootTable() mit lootTable[session].candidates
    [Name-Realm].response/class/diff, die Session :GetCurrentSession(),
    der Rahmen .frame (DefaultRCLootCouncilFrame),
  * die Knopf-Texte RCLootCouncil:GetResponse(typeCode or equipLoc, id).
Nachgefuehrt wird ueber hooksecurefunc auf Methoden des Moduls (normale
Lua-Tabellen, kein geschuetzter Code): ReceiveLootTable (neue Sitzung),
SwitchSession (anderes Item), OnResponseReceived & Co. (Antworten), Show/Hide.
Alles unter pcall; ohne RCLootCouncil oder mit anderer API passiert nichts.

Es wird nichts an RCLootCouncil oder den Raid geschickt; ein Klick auf eine
Item-Zeile schaltet nur die eigene Ansicht in RCLootCouncil mit um.
]]

local EHS = EventHelperSync
local Council = EHS.Council
local Suggest = EHS.Suggest

local WIDTH, HEIGHT = 320, 444
local ITEM_ROWS, ITEM_HEIGHT = 5, 30
local SUGG_ROWS, SUGG_HEIGHT = 6, 28
local ITEMS_TOP = -50
local SUGG_TOP = ITEMS_TOP - ITEM_ROWS * ITEM_HEIGHT - 10
local NOTE_TOP = SUGG_TOP - SUGG_ROWS * SUGG_HEIGHT - 4
local LIVE_INTERVAL = 3
local REFRESH_DELAY = 0.2

local panel
local itemRows, suggRows = {}, {}

local state = {
    wanted = false,     -- soll offen sein (Sitzung laeuft bzw. von Hand geoeffnet)
    closed = false,     -- in dieser Sitzung mit "x" geschlossen
    selected = nil,     -- RCLC-Session-Nummer des gewaehlten Items
    offset = 0,         -- Scroll-Position der Item-Liste
    docked = nil,       -- der RCLC-Rahmen, an dem das Fenster haengt
    items = {},         -- zuletzt gelesene Items (fuer Klicks/Tooltips)
    lastData = nil,     -- die Council-Daten der letzten Anzeige
}

local hookedModule
local followed = setmetatable({}, { __mode = "k" })

local function now()
    return time()
end

-- ---------------------------------------------------------------------------
-- RCLootCouncil lesen
-- ---------------------------------------------------------------------------

local function rclcAddon()
    local rc
    if LibStub then
        local ok, result = pcall(function()
            local lib = LibStub("AceAddon-3.0", true)
            return lib and lib:GetAddon("RCLootCouncil", true)
        end)
        if ok and type(result) == "table" then rc = result end
    end
    if not rc and type(_G.RCLootCouncil) == "table" then rc = _G.RCLootCouncil end
    return rc
end

--- RCLootCouncil und sein Abstimmungs-Modul, oder nil.
local function rclc()
    local rc = rclcAddon()
    if not rc then return nil, nil end
    local vf
    if type(rc.GetActiveModule) == "function" then
        local ok, module = pcall(rc.GetActiveModule, rc, "votingframe")
        if ok and type(module) == "table" then vf = module end
    end
    if not vf and type(rc.GetModule) == "function" then
        local ok, module = pcall(rc.GetModule, rc, "RCVotingFrame", true)
        if ok and type(module) == "table" then vf = module end
    end
    if not vf or type(vf.GetLootTable) ~= "function" then return rc, nil end
    return rc, vf
end

local statsCache = {}

--- Die Werte eines Items (GetItemStats), nur einmal je Link gefragt -
--- ausser der Client kannte das Item noch nicht.
local function itemStats(link)
    if type(link) ~= "string" then return nil end
    if statsCache[link] then return statsCache[link] end
    local getter = (C_Item and C_Item.GetItemStats) or _G.GetItemStats
    if not getter then return nil end
    local ok, stats = pcall(getter, link)
    if ok and type(stats) == "table" and next(stats) then
        statsCache[link] = stats
        return stats
    end
    return nil
end

local function itemIdOf(entry)
    local id = tonumber(entry.id) or tonumber(entry.itemID)
    if id then return id end
    if type(entry.link) == "string" then return tonumber(entry.link:match("item:(%d+)")) end
    return nil
end

--- Die Items der laufenden Sitzung in der Form, die Suggest.Build() will.
local function readSession(rc, vf)
    local ok, lootTable = pcall(vf.GetLootTable, vf)
    if not ok or type(lootTable) ~= "table" then return {} end
    local items = {}
    for session, entry in ipairs(lootTable) do
        if type(entry) == "table" then
            local typeCode = entry.typeCode or entry.equipLoc
            local candidates = {}
            for name, c in pairs(type(entry.candidates) == "table" and entry.candidates or {}) do
                if type(c) == "table" and type(name) == "string" then
                    local info
                    if tonumber(c.response) and type(rc.GetResponse) == "function" then
                        local okInfo, result = pcall(rc.GetResponse, rc, typeCode, c.response)
                        if okInfo and type(result) == "table" then info = result end
                    end
                    candidates[#candidates + 1] = {
                        name = name, class = c.class, response = c.response, info = info,
                        responseText = info and type(info.text) == "string" and info.text or nil,
                        diff = c.diff,
                    }
                end
            end
            table.sort(candidates, function(a, b) return a.name < b.name end)
            items[#items + 1] = {
                session = session, link = entry.link, itemId = itemIdOf(entry), texture = entry.texture,
                quality = entry.quality, name = entry.name, awarded = entry.awarded, candidates = candidates,
            }
        end
    end
    return items
end

local function currentSession(vf)
    if not vf or type(vf.GetCurrentSession) ~= "function" then return nil end
    local ok, session = pcall(vf.GetCurrentSession, vf)
    return ok and tonumber(session) or nil
end

local function rclcFrame(vf)
    local f = vf and vf.frame
    if type(f) ~= "table" then f = _G.DefaultRCLootCouncilFrame end
    if type(f) == "table" and f.SetPoint then return f end
    return nil
end

-- ---------------------------------------------------------------------------
-- Texte und Farben
-- ---------------------------------------------------------------------------

local QUALITY_COLORS = {
    [0] = "ff9d9d9d", [1] = "ffffffff", [2] = "ff1eff00", [3] = "ff0070dd",
    [4] = "ffa335ee", [5] = "ffff8000", [6] = "ffe6cc80", [7] = "ff00ccff",
}

--- Der Item-Name in Qualitaetsfarbe, ohne Klammern.
local function itemLabel(item)
    local link = type(item.link) == "string" and item.link or ""
    local name = link:match("|h%[(.-)%]|h") or item.name or ("Item " .. tostring(item.itemId or "?"))
    local color = link:match("^|c(%x%x%x%x%x%x%x%x)")
    local quality = tonumber(item.quality) or tonumber(link:match("|cnIQ(%d):"))
    if not color and quality then color = QUALITY_COLORS[quality] end
    if color then return "|c" .. color .. name .. "|r" end
    return name
end

local function itemIcon(item)
    if item.texture then return item.texture end
    local getter = (C_Item and C_Item.GetItemIconByID) or _G.GetItemIcon
    if getter and item.itemId then
        local ok, icon = pcall(getter, item.itemId)
        if ok and icon then return icon end
    end
    return "Interface\\Icons\\INV_Misc_QuestionMark"
end

local TAG_STYLE = {
    Caster = { text = { 0.79, 0.72, 1.00 }, bg = { 0.54, 0.49, 1.00, 0.18 } },
    Heiler = { text = { 0.60, 0.60, 0.60 }, bg = { 1, 1, 1, 0.06 } },
}
local TAG_NONE = { text = { 0.50, 0.50, 0.50 }, bg = { 1, 1, 1, 0.04 } }

local function nameLabel(row)
    local name = Council.Color(row.name or "?", Council.ClassColor(row.classFile))
    if row.specLabel and row.specLabel ~= "" then
        name = name .. " " .. Council.Color(row.specLabel, 0.6, 0.6, 0.6)
    end
    return name
end

-- ---------------------------------------------------------------------------
-- Aufbau
-- ---------------------------------------------------------------------------

local function W() return EHS.Widgets end

local function selectSession(session)
    state.selected = session
    local _, vf = rclc()
    if vf and type(vf.SwitchSession) == "function" and rclcFrame(vf) and currentSession(vf) ~= session then
        -- RCLootCouncil mit umschalten; der Haken auf SwitchSession frischt auf.
        local ok = pcall(vf.SwitchSession, vf, session)
        if ok then return end
    end
    EHS:RefreshSuggest()
end

local function showItemTooltip(row)
    local item = row.item
    if not item then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    local ok = type(item.link) == "string" and pcall(GameTooltip.SetHyperlink, GameTooltip, item.link)
    if not ok then GameTooltip:AddLine(itemLabel(item)) end
    GameTooltip:Show()
end

local function buildItemRow(parent, index)
    local w = W()
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(WIDTH - 12, ITEM_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * ITEM_HEIGHT)
    local hl = w.solid(row, "HIGHLIGHT", 1, 1, 1, 0.07)
    hl:SetAllPoints()
    row.selectedBg = w.solid(row, "BACKGROUND", 1, 0.82, 0, 0.10)
    row.selectedBg:SetAllPoints()
    row.selectedBar = w.solid(row, "ARTWORK", 1, 0.82, 0, 1)
    row.selectedBar:SetPoint("TOPLEFT", 0, 0)
    row.selectedBar:SetPoint("BOTTOMLEFT", 0, 0)
    row.selectedBar:SetWidth(2)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(18, 18)
    row.icon:SetPoint("LEFT", 6, 0)

    row.name = w.text(row, "GameFontHighlightSmall")
    row.name:SetPoint("TOPLEFT", 30, -3)
    row.name:SetWidth(WIDTH - 100)
    if row.name.SetWordWrap then row.name:SetWordWrap(false) end

    row.hint = w.text(row, "GameFontDisableSmall")
    row.hint:SetPoint("TOPLEFT", 30, -16)
    row.hint:SetWidth(WIDTH - 100)
    if row.hint.SetWordWrap then row.hint:SetWordWrap(false) end

    row.tag = CreateFrame("Frame", nil, row)
    row.tag:SetSize(44, 14)
    row.tag:SetPoint("RIGHT", -4, 0)
    row.tag.bg = row.tag:CreateTexture(nil, "BACKGROUND")
    row.tag.bg:SetAllPoints()
    row.tag.label = w.text(row.tag, "GameFontHighlightSmall", "CENTER")
    row.tag.label:SetPoint("CENTER", 0, 0)

    row:SetScript("OnClick", function(self)
        if self.item then selectSession(self.item.session) end
    end)
    row:SetScript("OnEnter", showItemTooltip)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return row
end

local function showSuggestionTooltip(row)
    local data = row.data
    if not data then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(nameLabel(data))
    if data.need then
        GameTooltip:AddDoubleLine("Bedarf", ("%d von 100"):format(data.need) .. (data.mark or ""),
            1, 0.82, 0, Council.NeedColor(data.need))
    else
        GameTooltip:AddLine("Nicht in den Council-Daten dieser Kategorie.", 0.6, 0.6, 0.6, true)
    end
    local reason, start = tostring(data.reason or ""), 1
    while start <= #reason do
        local stop = reason:find(" · ", start, true)
        GameTooltip:AddLine(reason:sub(start, (stop or #reason + 1) - 1), 1, 1, 1, true)
        start = stop and stop + #" · " or #reason + 1
    end
    local provisional = data.raider and Council.ProvisionalRaiderLine(data.raider)
    if provisional then GameTooltip:AddLine(provisional, unpack(Council.PROVISIONAL_COLOR)) end
    GameTooltip:Show()
end

local function buildSuggestionRow(parent, index)
    local w = W()
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(WIDTH - 16, SUGG_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * SUGG_HEIGHT)
    if index == 1 then
        local bg = w.solid(row, "BACKGROUND", 1, 0.82, 0, 0.08)
        bg:SetAllPoints()
        local bar = w.solid(row, "ARTWORK", 1, 0.82, 0, 1)
        bar:SetPoint("TOPLEFT", 0, 0)
        bar:SetPoint("BOTTOMLEFT", 0, 0)
        bar:SetWidth(2)
    end
    local hl = w.solid(row, "HIGHLIGHT", 1, 1, 1, 0.06)
    hl:SetAllPoints()

    row.badge = w.solid(row, "ARTWORK", 1, 1, 1, 0.08)
    row.badge:SetSize(15, 15)
    row.badge:SetPoint("LEFT", 6, 0)
    if index == 1 then row.badge:SetColorTexture(1, 0.82, 0, 1) end
    row.rank = w.text(row, "GameFontHighlightSmall", "CENTER")
    row.rank:SetPoint("CENTER", row.badge, "CENTER", 0, 0)
    row.rank:SetText(tostring(index))
    if index == 1 then
        row.rank:SetTextColor(0.10, 0.08, 0.02)
    else
        row.rank:SetTextColor(0.81, 0.81, 0.81)
    end

    row.name = w.text(row, "GameFontHighlightSmall")
    row.name:SetPoint("TOPLEFT", 28, -3)
    row.name:SetWidth(WIDTH - 96)
    if row.name.SetWordWrap then row.name:SetWordWrap(false) end

    row.reason = w.text(row, "GameFontDisableSmall")
    row.reason:SetPoint("TOPLEFT", 28, -15)
    row.reason:SetWidth(WIDTH - 96)
    if row.reason.SetWordWrap then row.reason:SetWordWrap(false) end

    row.need = w.text(row, "GameFontNormal", "RIGHT")
    row.need:SetPoint("TOPRIGHT", -4, -2)
    row.need:SetWidth(44)
    row.needLabel = w.text(row, "GameFontDisableSmall", "RIGHT")
    row.needLabel:SetPoint("TOPRIGHT", -4, -16)
    row.needLabel:SetWidth(44)
    row.needLabel:SetText("Bedarf")

    row:SetScript("OnEnter", showSuggestionTooltip)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return row
end

local function savePosition(self)
    self:StopMovingOrSizing()
    if state.docked then return end
    local point, _, relativePoint, x, y = self:GetPoint()
    if point and EHS.db then EHS.db.suggestPos = { point = point, relativePoint = relativePoint, x = x, y = y } end
end

local function build()
    local w = W()
    panel = CreateFrame("Frame", "EventHelperSyncSuggestFrame", UIParent)
    panel:SetSize(WIDTH, HEIGHT)
    panel:SetFrameStrata("DIALOG")
    panel:SetClampedToScreen(true)
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", function(self)
        if not state.docked then self:StartMoving() end
    end)
    panel:SetScript("OnDragStop", savePosition)

    local bg = w.solid(panel, "BACKGROUND", 0.05, 0.05, 0.06, 0.94)
    bg:SetAllPoints()
    local edges = {
        { "TOPLEFT", "TOPRIGHT", nil, 1 }, { "BOTTOMLEFT", "BOTTOMRIGHT", nil, 1 },
        { "TOPLEFT", "BOTTOMLEFT", 1, nil }, { "TOPRIGHT", "BOTTOMRIGHT", 1, nil },
    }
    for _, e in ipairs(edges) do
        local line = w.solid(panel, "BORDER", 0.55, 0.45, 0.25, 1)
        line:SetPoint(e[1])
        line:SetPoint(e[2])
        if e[3] then line:SetWidth(e[3]) end
        if e[4] then line:SetHeight(e[4]) end
    end

    panel.title = w.text(panel, "GameFontNormal")
    panel.title:SetPoint("TOPLEFT", 10, -9)
    panel.title:SetText("EventHelper-Vorschlag")

    panel.close = w.textButton(panel, "x", 18, "Schliessen (bis zur nächsten Abstimmung; /ehc vorschlag öffnet wieder)")
    panel.close:SetPoint("TOPRIGHT", -6, -6)
    panel.close:SetScript("OnClick", function()
        state.closed = true
        state.wanted = false
        panel:Hide()
    end)

    panel.category = w.textButton(panel, "", 124)
    panel.category:SetPoint("RIGHT", panel.close, "LEFT", -4, 0)
    panel.category.label:SetWidth(118)
    if panel.category.label.SetWordWrap then panel.category.label:SetWordWrap(false) end
    panel.category:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    panel.category:SetScript("OnClick", function(self, button) EHS:PickCouncilCategory(self, button) end)
    panel.category:SetScript("OnEnter", function(self)
        if EHS.ShowCouncilCategoryTooltip then EHS.ShowCouncilCategoryTooltip(self) end
    end)
    panel.category:SetScript("OnLeave", function() GameTooltip:Hide() end)

    panel.header = w.text(panel, "GameFontDisableSmall")
    panel.header:SetPoint("TOPLEFT", 10, -30)
    panel.header:SetWidth(WIDTH - 20)
    if panel.header.SetWordWrap then panel.header:SetWordWrap(false) end

    local line1 = w.solid(panel, "ARTWORK", 1, 1, 1, 0.12)
    line1:SetPoint("TOPLEFT", 8, ITEMS_TOP + 5)
    line1:SetPoint("TOPRIGHT", -8, ITEMS_TOP + 5)
    line1:SetHeight(1)

    panel.itemList = CreateFrame("Frame", nil, panel)
    panel.itemList:SetPoint("TOPLEFT", 6, ITEMS_TOP)
    panel.itemList:SetSize(WIDTH - 12, ITEM_ROWS * ITEM_HEIGHT)
    panel.itemList:EnableMouseWheel(true)
    panel.itemList:SetScript("OnMouseWheel", function(_, delta)
        local maxOffset = math.max(0, #state.items - ITEM_ROWS)
        state.offset = math.max(0, math.min(maxOffset, state.offset - delta))
        EHS:RefreshSuggest()
    end)
    for i = 1, ITEM_ROWS do itemRows[i] = buildItemRow(panel.itemList, i) end
    panel.itemRows = itemRows
    panel.itemThumb = w.solid(panel.itemList, "OVERLAY", 0.85, 0.7, 0.35, 0.6)
    panel.itemThumb:SetWidth(2)

    local line2 = w.solid(panel, "ARTWORK", 1, 1, 1, 0.12)
    line2:SetPoint("TOPLEFT", 8, SUGG_TOP + 5)
    line2:SetPoint("TOPRIGHT", -8, SUGG_TOP + 5)
    line2:SetHeight(1)

    panel.suggList = CreateFrame("Frame", nil, panel)
    panel.suggList:SetPoint("TOPLEFT", 8, SUGG_TOP)
    panel.suggList:SetSize(WIDTH - 16, SUGG_ROWS * SUGG_HEIGHT)
    for i = 1, SUGG_ROWS do suggRows[i] = buildSuggestionRow(panel.suggList, i) end
    panel.suggRows = suggRows

    -- Statt der Liste: der Hinweis fuer Items der anderen Rolle bzw. "noch nichts".
    panel.message = w.text(panel, "GameFontHighlightSmall")
    panel.message:SetPoint("TOPLEFT", 12, SUGG_TOP - 8)
    panel.message:SetWidth(WIDTH - 24)
    panel.message:SetTextColor(0.6, 0.6, 0.6)

    panel.note = w.text(panel, "GameFontDisableSmall")
    panel.note:SetPoint("TOPLEFT", 10, NOTE_TOP)
    panel.note:SetWidth(WIDTH - 20)

    local line3 = w.solid(panel, "ARTWORK", 1, 1, 1, 0.08)
    line3:SetPoint("BOTTOMLEFT", 1, 34)
    line3:SetPoint("BOTTOMRIGHT", -1, 34)
    line3:SetHeight(1)

    panel.footer = w.text(panel, "GameFontDisableSmall")
    panel.footer:SetPoint("BOTTOMLEFT", 10, 7)
    panel.footer:SetWidth(WIDTH - 20)
    panel.footer:SetTextColor(0.44, 0.44, 0.44)
    panel.footer:SetText(Suggest.FOOTER)

    -- Live: Vergaben in RCLootCouncil aendern den Bedarf (Council-Daten mit
    -- den Vergaben seit dem Sync); billig nachsehen, ob es neue Daten gibt.
    panel:SetScript("OnUpdate", function(self, elapsed)
        self.liveElapsed = (self.liveElapsed or 0) + (tonumber(elapsed) or 0)
        if self.liveElapsed < LIVE_INTERVAL then return end
        self.liveElapsed = 0
        local ok, data = pcall(EHS.CouncilData, EHS)
        if ok and data ~= state.lastData then EHS:RefreshSuggest() end
    end)

    panel:Hide()
end

-- ---------------------------------------------------------------------------
-- Andocken
-- ---------------------------------------------------------------------------

local function onRclcHidden()
    if panel and state.docked and panel:IsShown() then panel:Hide() end
end

local function onRclcShown()
    if state.wanted and not state.closed and EHS.ShowSuggest then EHS:ShowSuggest() end
end

local function follow(f)
    if followed[f] or not f.HookScript then return end
    followed[f] = true
    for _, target in ipairs({ f, type(f.content) == "table" and f.content or nil }) do
        pcall(target.HookScript, target, "OnHide", function() pcall(onRclcHidden) end)
        pcall(target.HookScript, target, "OnShow", function() pcall(onRclcShown) end)
    end
end

--- Rechts an RCLootCouncils Abstimmungsfenster, sonst frei (gemerkte Position).
local function dock()
    local _, vf = rclc()
    local f = rclcFrame(vf)
    panel:ClearAllPoints()
    if f then
        local ok = pcall(panel.SetPoint, panel, "TOPLEFT", f, "TOPRIGHT", 4, 0)
        if ok then
            state.docked = f
            follow(f)
            return
        end
        panel:ClearAllPoints()
    end
    state.docked = nil
    local pos = EHS.db and EHS.db.suggestPos
    if pos and pos.point then
        panel:SetPoint(pos.point, UIParent, pos.relativePoint or pos.point, pos.x or 0, pos.y or 0)
    else
        panel:SetPoint("RIGHT", UIParent, "RIGHT", -80, 40)
    end
end

-- ---------------------------------------------------------------------------
-- Auffrischen
-- ---------------------------------------------------------------------------

local function setTag(tag, label)
    local style = TAG_STYLE[label] or TAG_NONE
    tag.label:SetText(label)
    tag.label:SetTextColor(unpack(style.text))
    tag.bg:SetColorTexture(unpack(style.bg))
end

local function selectedIndex(items)
    for i, item in ipairs(items) do
        if item.session == state.selected then return i end
    end
    return items[1] and 1 or nil
end

local function renderItems(items, index)
    local maxOffset = math.max(0, #items - ITEM_ROWS)
    -- Ein neu gewaehltes Item in den sichtbaren Bereich holen; sonst bleibt
    -- die Liste, wo das Mausrad sie hingeschoben hat.
    if index and index ~= state.shownIndex then
        if index <= state.offset then state.offset = index - 1 end
        if index > state.offset + ITEM_ROWS then state.offset = index - ITEM_ROWS end
    end
    state.shownIndex = index
    state.offset = math.max(0, math.min(maxOffset, state.offset))
    for i = 1, ITEM_ROWS do
        local row = itemRows[i]
        local item = items[i + state.offset]
        row.item = item
        if not item then
            row:Hide()
        else
            row.icon:SetTexture(itemIcon(item))
            row.name:SetText(itemLabel(item))
            row.hint:SetText(item.result.hint or "")
            setTag(row.tag, item.result.tag)
            local selected = (i + state.offset) == index
            if selected then
                row.selectedBg:Show()
                row.selectedBar:Show()
            else
                row.selectedBg:Hide()
                row.selectedBar:Hide()
            end
            row:Show()
        end
    end
    if #items > ITEM_ROWS then
        local height = ITEM_ROWS * ITEM_HEIGHT
        local thumb = math.max(12, height * ITEM_ROWS / #items)
        panel.itemThumb:SetHeight(thumb)
        panel.itemThumb:ClearAllPoints()
        panel.itemThumb:SetPoint("TOPRIGHT", panel.itemList, "TOPRIGHT", 0, -(height - thumb) * state.offset / maxOffset)
        panel.itemThumb:Show()
    else
        panel.itemThumb:Hide()
    end
end

local function renderSuggestions(result)
    local rows = result and not result.blocked and result.rows or {}
    for i = 1, SUGG_ROWS do
        local row = suggRows[i]
        local data = rows[i]
        row.data = data
        if not data then
            row:Hide()
        else
            row.name:SetText(nameLabel(data))
            row.reason:SetText(data.reason or "")
            if data.need then
                row.need:SetText(Council.Color(tostring(data.need), Council.NeedColor(data.need)) .. (data.mark or ""))
                row.needLabel:Show()
            else
                row.need:SetText("")
                row.needLabel:Hide()
            end
            row:SetAlpha(data.muted and 0.55 or 1)
            row:Show()
        end
    end

    local message, note = "", ""
    if not result then
        message = state.noSessionText or ""
    elseif result.blocked then
        message = result.blocked
    elseif #rows == 0 then
        message = result.hint or ""
        note = result.note or ""
    else
        note = result.note or ""
        if #rows > SUGG_ROWS then
            local more = ("+%d weitere."):format(#rows - SUGG_ROWS)
            note = note ~= "" and (more .. " " .. note) or more
        end
    end
    panel.message:SetText(message)
    panel.note:SetText(note)
end

local function renderCategory(category, how)
    if not category then
        panel.category:Hide()
        return
    end
    local label = category.name
    if how == "auto" then label = label .. " " .. Council.Color("(auto)", 0.6, 0.6, 0.6) end
    panel.category.label:SetText(label)
    panel.category:Show()
end

function EHS:RefreshSuggest()
    if not panel or not panel:IsShown() then return end
    local rc, vf = rclc()
    local items = vf and readSession(rc, vf) or {}
    state.items = items

    -- Neue Vergaben in RCLootCouncil sofort mitrechnen (sonst hoechstens
    -- einmal pro Sekunde nachgesehen).
    pcall(self.CouncilData, self, true)
    local okActive, category, how, data = pcall(self.CouncilActive, self)
    if not okActive then category, how, data = nil, nil, nil end
    state.lastData = data
    local current = now()

    for _, item in ipairs(items) do
        item.stats = itemStats(item.link)
        local ok, result = pcall(Suggest.Build, item, category, current)
        if not ok then
            self:Debug("Vorschlag:", tostring(result))
            result = { rows = {}, tag = "-", hint = "" }
        end
        item.result = result
    end

    if state.selected == nil then state.selected = currentSession(vf) end
    local index = selectedIndex(items)
    if index then state.selected = items[index].session end

    renderCategory(category, how)
    if not rc then
        panel.header:SetText("RCLootCouncil ist nicht geladen.")
        state.noSessionText = "Der Vorschlag erscheint, sobald in RCLootCouncil eine Abstimmung läuft."
    elseif #items == 0 then
        panel.header:SetText(Suggest.Header(0, data, category, current))
        state.noSessionText = "Gerade läuft keine Abstimmung in RCLootCouncil."
    else
        panel.header:SetText(Suggest.Header(#items, data, category, current))
        state.noSessionText = nil
    end
    renderItems(items, index)
    renderSuggestions(index and items[index].result or nil)
end

local refreshPending = false

--- Nach einem Haken: kurz sammeln (RCLootCouncil meldet Antworten in Schueben).
local function requestRefresh()
    if not panel or not panel:IsShown() or refreshPending then return end
    refreshPending = true
    local function run()
        refreshPending = false
        local ok, err = pcall(EHS.RefreshSuggest, EHS)
        if not ok then EHS:Debug("Vorschlag:", tostring(err)) end
    end
    if C_Timer and C_Timer.After and pcall(C_Timer.After, REFRESH_DELAY, run) then return end
    run()
end

function EHS:ShowSuggest()
    if not panel then build() end
    dock()
    panel:Show()
    local ok, err = pcall(self.RefreshSuggest, self)
    if not ok then self:Debug("Vorschlag:", tostring(err)) end
end

function EHS:HideSuggest()
    if panel then panel:Hide() end
end

--- /ehc vorschlag: von Hand auf- und zumachen (auch ohne Automatik).
function EHS:ToggleSuggest()
    if panel and panel:IsShown() then
        state.wanted = false
        state.closed = true
        panel:Hide()
    else
        state.wanted = true
        state.closed = false
        self:ShowSuggest()
    end
end

local function autoOpen()
    return not (EHS.db and EHS.db.settings and EHS.db.settings.rclcSuggest == false)
end

-- ---------------------------------------------------------------------------
-- Haken in RCLootCouncil
-- ---------------------------------------------------------------------------

local HANDLERS = {
    -- Neue Sitzung: Loot-Tabelle vom Master Looter (VotingFrame.lua ReceiveLootTable).
    ReceiveLootTable = function()
        state.closed = false
        state.offset = 0
        state.selected = nil
        state.shownIndex = nil
        if autoOpen() then
            state.wanted = true
            EHS:ShowSuggest()
        else
            requestRefresh()
        end
    end,
    -- Ein anderes Item in RCLootCouncil gewaehlt.
    SwitchSession = function(session)
        if tonumber(session) then state.selected = tonumber(session) end
        requestRefresh()
    end,
    -- RCLootCouncil:Show() ohne Sitzung zeigt nichts (nur "No session running").
    Show = function()
        local _, vf = rclc()
        local f = rclcFrame(vf)
        if state.wanted and not state.closed and f and f.IsShown and f:IsShown() then
            EHS:ShowSuggest()
        else
            requestRefresh()
        end
    end,
    Hide = function()
        onRclcHidden()
    end,
}

local HOOKED_METHODS = {
    "ReceiveLootTable", "SwitchSession", "Show", "Hide", "EndSession",
    "OnLootTableAdditionsReceived", "OnReconnectReceived",
    "OnResponseReceived", "OnChangeResponseReceived", "OnChangeToWaitReceived", "OnLootAckReceived",
    "OnAwardedReceived", "OnBaggedReceived",
}

local function onHook(method, ...)
    local handler = HANDLERS[method]
    if handler then
        handler(...)
    else
        requestRefresh()
    end
end

--- Die Haken setzen, sobald RCLootCouncil da ist (PLAYER_LOGIN, ADDON_LOADED).
-- @return true, wenn gehakt (jetzt oder schon frueher)
function EHS:StartSuggest()
    if hookedModule then return true end
    local _, vf = rclc()
    if not vf then return false end
    hookedModule = vf
    local count = 0
    for _, method in ipairs(HOOKED_METHODS) do
        if type(vf[method]) == "function" then
            local ok = pcall(hooksecurefunc, vf, method, function(_, ...)
                local okHook, err = pcall(onHook, method, ...)
                if not okHook then EHS:Debug("Vorschlag (" .. method .. "):", tostring(err)) end
            end)
            if ok then count = count + 1 end
        end
    end
    self:Debug(("Vorschlag: %d Haken in RCLootCouncil."):format(count))
    -- Laeuft schon eine Sitzung (nach /reload), gleich mitmachen.
    local okTable, lootTable = pcall(vf.GetLootTable, vf)
    local f = rclcFrame(vf)
    if okTable and type(lootTable) == "table" and #lootTable > 0 and f and f.IsShown and f:IsShown() and autoOpen() then
        state.wanted = true
        self:ShowSuggest()
    end
    return true
end

local events = CreateFrame("Frame")
EHS:RegisterEvents(events, "ADDON_LOADED", "PLAYER_LOGIN")
events:SetScript("OnEvent", function(_, event, name)
    if event == "ADDON_LOADED" and not (type(name) == "string" and name:find("^RCLootCouncil")) then return end
    local ok, err = pcall(EHS.StartSuggest, EHS)
    if not ok then EHS:Debug("Vorschlag:", tostring(err)) end
end)
