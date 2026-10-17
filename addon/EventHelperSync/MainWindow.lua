--[[
EventHelper Sync - das Hauptfenster (/ehs, Minimap-Knopf).

Ein Fenster mit einer Leiste links: ein Eintrag pro Modul (Loot-Sync,
Loot-Council, Gildenbank), darunter die Einstellungen. Rechts der Bereich des
gewaehlten Eintrags. Ein ausgeschaltetes Modul (Modules.lua) fehlt in der
Leiste. Bis 1.15 waren Council und Gildenbank eigene Fenster und die
Einstellungen sassen unter der Raid-Tabelle.

Die Bereiche melden sich hier an (EHS:RegisterPage) und werden erst gebaut,
wenn sie zum ersten Mal gezeigt werden:

  { id, label, icon, module, order, build(parent) -> frame, refresh(),
    sub() -> Text unter dem Namen, badge() -> Zahl, onShow() }

Der Bereich-Frame liegt im Inhaltsfeld; gezeigt wird immer nur der gewaehlte,
und nur solange das Fenster offen ist (frame:IsShown() eines Bereichs heisst
also "man sieht ihn").
]]

local EHS = EventHelperSync
local Kit = EHS.Kit

local WIDTH, HEIGHT = 880, 572
local RAIL_WIDTH = 178
local NAV_HEIGHT = 46

-- Inhaltsfeld eines Bereichs, fuer die Bereiche selbst.
EHS.MainLayout = {
    width = WIDTH, height = HEIGHT, railWidth = RAIL_WIDTH,
    pageWidth = WIDTH - RAIL_WIDTH - 2, pageHeight = HEIGHT - Kit.TITLE_HEIGHT - 1,
}

local pages = {}
local frame
local current

--- Einen Bereich anmelden (aus den Dateien der Module, beim Laden).
function EHS:RegisterPage(def)
    pages[#pages + 1] = def
    table.sort(pages, function(a, b) return (a.order or 50) < (b.order or 50) end)
end

local function pageById(id)
    for _, page in ipairs(pages) do
        if page.id == id then return page end
    end
    return nil
end

local function pageOn(page)
    return page and (not page.module or EHS:ModuleOn(page.module))
end

-- ---------------------------------------------------------------------------
-- Leiste
-- ---------------------------------------------------------------------------

local function buildNav(parent, page)
    local nav = CreateFrame("Button", nil, parent)
    nav:SetSize(RAIL_WIDTH - 16, NAV_HEIGHT - 4)
    nav.page = page

    nav.bg = Kit.Solid(nav, "BACKGROUND", { 0.17, 0.14, 0.09 })
    nav.bg:SetAllPoints()
    nav.edges = Kit.Border(nav, Kit.C.border)
    local hl = Kit.Solid(nav, "HIGHLIGHT", { 1, 1, 1 }, 0.05)
    hl:SetAllPoints()

    nav.iconFrame = CreateFrame("Frame", nil, nav)
    nav.iconFrame:SetSize(30, 30)
    nav.iconFrame:SetPoint("LEFT", 6, 0)
    Kit.Solid(nav.iconFrame, "BACKGROUND", Kit.C.field):SetAllPoints()
    Kit.Border(nav.iconFrame, Kit.C.borderDim)
    nav.icon = nav.iconFrame:CreateTexture(nil, "ARTWORK")
    nav.icon:SetPoint("TOPLEFT", 2, -2)
    nav.icon:SetPoint("BOTTOMRIGHT", -2, 2)
    nav.icon:SetTexture(page.icon)
    nav.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    nav.name = Kit.Text(nav, "body")
    nav.name:SetPoint("TOPLEFT", nav.iconFrame, "TOPRIGHT", 8, -1)
    nav.name:SetWidth(RAIL_WIDTH - 90)
    nav.name:SetText(page.label)

    nav.sub = Kit.Text(nav, "hint")
    nav.sub:SetPoint("TOPLEFT", nav.name, "BOTTOMLEFT", 0, -3)
    nav.sub:SetWidth(RAIL_WIDTH - 90)
    if nav.sub.SetWordWrap then nav.sub:SetWordWrap(false) end

    nav.badge = Kit.Badge(nav)
    nav.badge:SetPoint("RIGHT", -6, 0)

    nav:SetScript("OnClick", function() EHS:ShowMain(page.id) end)
    return nav
end

local function setNavSelected(nav, on)
    nav.bg:SetShown(on)
    for _, line in ipairs(nav.edges) do line:SetShown(on) end
    if on then
        nav.name:SetTextColor(Kit.C.gold[1], Kit.C.gold[2], Kit.C.gold[3])
    else
        nav.name:SetTextColor(Kit.C.text[1], Kit.C.text[2], Kit.C.text[3])
    end
end

local function refreshRail()
    local y = -10
    local separatorPlaced = false
    for _, page in ipairs(pages) do
        local nav = frame.navs[page.id]
        if pageOn(page) then
            if page.bottom and not separatorPlaced then
                frame.railSep:ClearAllPoints()
                frame.railSep:SetPoint("TOPLEFT", frame.rail, "TOPLEFT", 12, y - 4)
                frame.railSep:SetPoint("TOPRIGHT", frame.rail, "TOPRIGHT", -12, y - 4)
                frame.railSep:Show()
                y = y - 12
                separatorPlaced = true
            end
            nav:ClearAllPoints()
            nav:SetPoint("TOPLEFT", frame.rail, "TOPLEFT", 8, y)
            y = y - NAV_HEIGHT
            local okSub, sub = pcall(page.sub or function() return "" end)
            nav.sub:SetText(okSub and sub or "")
            local okBadge, badge = pcall(page.badge or function() return 0 end)
            nav.badge:SetCount(okBadge and badge or 0)
            setNavSelected(nav, page.id == current)
            nav:Show()
        else
            nav:Hide()
        end
    end
    if not separatorPlaced then frame.railSep:Hide() end
end

-- ---------------------------------------------------------------------------
-- Aufbau
-- ---------------------------------------------------------------------------

local function build()
    frame = Kit.Window({
        name = "EventHelperSyncMainFrame", title = "EventHelper Sync", width = WIDTH, height = HEIGHT,
        posKey = "mainPos", strata = "HIGH",
    })
    frame.subtitle:SetText("v" .. tostring(EHS.version))

    -- Die Leiste ist eine vertiefte Flaeche wie im Spiel (Kit.Inset).
    frame.rail = Kit.Inset(frame.body)
    frame.rail:SetPoint("TOPLEFT", 0, 0)
    frame.rail:SetPoint("BOTTOMLEFT", 0, 0)
    frame.rail:SetWidth(RAIL_WIDTH)
    frame.railSep = Kit.Solid(frame.rail, "ARTWORK", Kit.C.line)
    frame.railSep:SetHeight(1)

    frame.content = CreateFrame("Frame", nil, frame.body)
    frame.content:SetPoint("TOPLEFT", RAIL_WIDTH + 1, 0)
    frame.content:SetPoint("BOTTOMRIGHT", 0, 0)

    frame.navs = {}
    for _, page in ipairs(pages) do frame.navs[page.id] = buildNav(frame.rail, page) end

    frame:SetScript("OnShow", function()
        local page = pageById(current)
        if page and page.frame then page.frame:Show() end
    end)
    frame:SetScript("OnHide", function()
        -- ohne Fenster ist kein Bereich zu sehen (auch fuer IsShown der Bereiche)
        for _, page in ipairs(pages) do
            if page.frame then page.frame:Hide() end
        end
        if EHS.OnMainHidden then EHS:OnMainHidden() end
    end)
end

--- Fenster zu, samt Bereichen (OnHide tut dasselbe; hier ausdruecklich, damit
--- es nicht davon abhaengt, dass der Client OnHide ausloest).
local function closeMain()
    for _, page in ipairs(pages) do
        if page.frame then page.frame:Hide() end
    end
    frame:Hide()
end

local function ensurePage(page)
    if page.frame then return page.frame end
    local holder = CreateFrame("Frame", page.frameName, frame.content)
    holder:SetAllPoints()
    holder:Hide()
    page.frame = holder
    page.build(holder)
    return holder
end

--- Der Bereich, den /ehs ohne Angabe zeigt: der zuletzt gewaehlte, sonst der erste.
local function defaultPage()
    local last = EHS.db and EHS.db.mainPage
    if pageOn(pageById(last)) then return last end
    for _, page in ipairs(pages) do
        if pageOn(page) then return page.id end
    end
    return nil
end

--- Das Fenster auf einem Bereich oeffnen. Ein Bereich eines ausgeschalteten
-- Moduls sagt das im Chat und oeffnet nichts.
-- @return true, wenn das Fenster jetzt den Bereich zeigt
function EHS:ShowMain(id)
    local page = pageById(id or defaultPage())
    if not page then return false end
    if not pageOn(page) then return self:ModuleOffNotice(page.module) end
    if not frame then build() end
    current = page.id
    if self.db then self.db.mainPage = page.id end
    for _, other in ipairs(pages) do
        if other.frame and other ~= page then other.frame:Hide() end
    end
    local holder = ensurePage(page)
    frame:Show()
    holder:Show()
    if page.onShow then pcall(page.onShow) end
    self:RefreshMain()
    return true
end

--- Auf/zu: ist das Fenster auf diesem Bereich offen, schliesst es; sonst
-- zeigt es ihn.
function EHS:ToggleMain(id)
    if frame and frame:IsShown() and (id == nil or id == current) then
        closeMain()
        return false
    end
    return self:ShowMain(id)
end

function EHS:HideMain()
    if frame then closeMain() end
end

--- Welcher Bereich offen ist (nil, wenn das Fenster zu ist).
function EHS:MainPage()
    if frame and frame:IsShown() then return current end
    return nil
end

--- Leiste und offenen Bereich neu zeichnen. Ist der offene Bereich gerade
--- ausgeschaltet worden, wechselt das Fenster auf den ersten anderen.
function EHS:RefreshMain()
    if not frame or not frame:IsShown() then return end
    local page = pageById(current)
    if not pageOn(page) then
        local fallback = defaultPage()
        if not fallback then
            closeMain()
            return
        end
        return self:ShowMain(fallback)
    end
    refreshRail()
    if page.refresh then
        local ok, err = pcall(page.refresh)
        if not ok then self:Debug("Bereich " .. tostring(page.id) .. ":", tostring(err)) end
    end
end

-- Die alten Namen: /ehs, der Minimap-Knopf und andere Dateien rufen sie.
function EHS:ToggleOptions() return self:ToggleMain(nil) end
function EHS:ShowOptions() return self:ShowMain(nil) end
function EHS:RefreshOptions() return self:RefreshMain() end
