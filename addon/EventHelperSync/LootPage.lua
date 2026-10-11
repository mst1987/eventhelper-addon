--[[
Der Bereich Loot-Sync im Hauptfenster (MainWindow.lua).

Aufgebaut nach dem, was man vor einem Upload wissen will, von oben nach unten:

  * Titel, die gefundenen Loot-Addons und rechts die eine Haupthandlung
    "Speichern & hochladen" (lädt die UI neu, das Sync-Tool holt es ab).
  * Drei Zahlen: ausgewaehlte Raid-Abende, exportbereite Items, Items, die
    noch nicht auf der Platte liegen.
  * Filter (Raid, nur ungespeicherte, nur ausgewaehlte) und die
    Sammelauswahl, die auf das wirkt, was der Filter zeigt.
  * Die Tabelle der Raid-Abende mit Spaltenkopf. Jede Zeile beantwortet fuer
    sich, ob dieser Abend hochgeladen gehoert; Klick nimmt ihn mit oder nicht.

Die Einstellungen (Zeitraum, neuer Abend ab, Bank/Entzaubern weglassen,
Upload-Knopf) stehen im Bereich Einstellungen (SettingsPage.lua).
]]

local EHS = EventHelperSync
local Kit = EHS.Kit

local page
local rows = {}
local offset = 0
local shown = {}

local ROW_HEIGHT = 30
local VISIBLE_ROWS = 11
local PAD = 16
local LIST_TOP = -176

-- Spalten: Beschriftung, x, Breite, Ausrichtung (innerhalb einer Zeile).
local COLUMNS = {
    { "", 0, 22 },
    { "Datum", 26, 90 },
    { "Zeit", 120, 86 },
    { "Raid", 210, 176 },
    { "Items", 390, 44, "RIGHT" },
    { "Spieler", 438, 50, "RIGHT" },
    { "Bosse", 492, 40, "RIGHT" },
    { "Quelle", 542, 90 },
    { "Offen", 632, 30, "RIGHT" },
}
EHS.LootLayout = { columns = COLUMNS, rowHeight = ROW_HEIGHT, visibleRows = VISIBLE_ROWS }

local WEEKDAYS = { "So", "Mo", "Di", "Mi", "Do", "Fr", "Sa" }

local function fmtDay(at)
    local wd = WEEKDAYS[tonumber(date("%w", at)) + 1] or ""
    return ("%s %s"):format(wd, date("%d.%m.%y", at))
end

local function fmtSpan(session)
    local from = date("%H:%M", session.startedAt)
    local to = date("%H:%M", session.endedAt)
    if from == to then return from end
    return from .. "-" .. to
end

-- Nur zur Laufzeit, nicht gespeichert: ein Filter ist eine Frage von Sekunden,
-- keine Einstellung. Beim naechsten Oeffnen soll wieder alles sichtbar sein.
local filter = { raid = "", onlyPending = false, onlySelected = false }

--- Die Abende, die die Filter durchlassen - neueste zuerst.
local function visibleSessions()
    local all = EHS:BuildSessions()
    local out = {}
    for i = #all, 1, -1 do
        local s = all[i]
        local raidOk = filter.raid == "" or s.instance == filter.raid
            or (filter.raid == "(unbekannt)" and (s.instance or "") == "")
        local pendingOk = not filter.onlyPending or (s.stats.pending or 0) > 0
        local selOk = not filter.onlySelected or not EHS:IsExcluded(s.sessionId)
        if raidOk and pendingOk and selOk then out[#out + 1] = s end
    end
    return out
end

--- Alle vorkommenden Raidnamen, fuer die Auswahl.
local function raidItems()
    local seen, names = {}, {}
    for _, s in ipairs(EHS:BuildSessions()) do
        local name = s.instance ~= "" and s.instance or "(unbekannt)"
        if not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
    end
    table.sort(names)
    local items = { { value = "", text = "Alle Raids" } }
    for _, name in ipairs(names) do items[#items + 1] = { value = name, text = name } end
    return items
end

local function refresh() EHS:RefreshMain() end

--- Ein Abend: mitnehmen oder nicht.
local function toggleRow(row)
    if not row.sessionId then return end
    EHS:SetExcluded(row.sessionId, not EHS:IsExcluded(row.sessionId))
    refresh()
    EHS:RefreshButton()
end

local function showRowTooltip(row)
    if not row.session then return end
    local s = row.session
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(s.instance ~= "" and s.instance or "Unbekannter Raid")
    GameTooltip:AddDoubleLine("Beginn", date("%d.%m.%Y %H:%M", s.startedAt))
    GameTooltip:AddDoubleLine("Ende", date("%d.%m.%Y %H:%M", s.endedAt))
    GameTooltip:AddDoubleLine("Items", #s.items)
    GameTooltip:AddDoubleLine("Empfänger", s.stats.players)
    if s.stats.bosses > 0 then GameTooltip:AddDoubleLine("Bosse", s.stats.bosses) end
    GameTooltip:AddDoubleLine("RCLootCouncil / Gargul", s.stats.rclc .. " / " .. s.stats.gargul)
    if s.stats.offspec > 0 then GameTooltip:AddDoubleLine("davon Zweitspec", s.stats.offspec) end
    if s.stats.pending > 0 then
        GameTooltip:AddDoubleLine("noch nicht gespeichert", Kit.Color(s.stats.pending, "gold"))
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(EHS:IsExcluded(s.sessionId)
        and "Klicken, um diesen Abend wieder mitzunehmen."
        or "Klicken, um diesen Abend nicht hochzuladen.", 1, 1, 1, true)
    GameTooltip:AddLine(s.sessionId, .5, .5, .5)
    GameTooltip:Show()
end

local function buildRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(EHS.MainLayout.pageWidth - 2 * PAD - 6, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
    Kit.RowBackground(row, index)

    row.check = Kit.Check(row)
    row.check:SetPoint("LEFT", COLUMNS[1][2], 0)
    row.check:SetScript("OnClick", function() toggleRow(row) end)

    row.cells = {}
    for i = 2, #COLUMNS do
        local col = COLUMNS[i]
        local fs = Kit.Text(row, "body", col[4] or "LEFT")
        fs:SetPoint("LEFT", col[2], 0)
        fs:SetWidth(col[3])
        row.cells[i] = fs
    end

    -- Ein Klick auf die Zeile schaltet dasselbe um wie das Haekchen: das
    -- Haekchen allein ist ein kleines Ziel.
    row:SetScript("OnClick", function() toggleRow(row) end)
    row:SetScript("OnEnter", showRowTooltip)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return row
end

local function statCell(parent, index, width)
    local cell = CreateFrame("Frame", nil, parent)
    cell:SetSize(width, 46)
    cell:SetPoint("TOPLEFT", (index - 1) * width, 0)
    if index > 1 then
        local line = Kit.Solid(cell, "BORDER", Kit.C.line)
        line:SetPoint("TOPLEFT")
        line:SetPoint("BOTTOMLEFT")
        line:SetWidth(1)
    end
    cell.value = Kit.Text(cell, "big")
    cell.value:SetPoint("TOPLEFT", 12, -7)
    cell.value:SetWidth(width - 24)
    cell.label = Kit.Text(cell, "hint")
    cell.label:SetPoint("TOPLEFT", cell.value, "BOTTOMLEFT", 0, -3)
    cell.label:SetWidth(width - 24)
    return cell
end

local function build(holder)
    page = holder
    local width = EHS.MainLayout.pageWidth - 2 * PAD

    page.title = Kit.Text(page, "h2")
    page.title:SetPoint("TOPLEFT", PAD, -14)
    page.title:SetText("Loot-Sync")

    page.sources = Kit.Text(page, "small")
    page.sources:SetPoint("TOPLEFT", PAD, -42)
    page.sources:SetWidth(width - 240)

    -- Die eine Haupthandlung. Der Klick ist das Hardware-Ereignis, das
    -- ReloadUI() verlangt (Core.lua).
    page.upload = Kit.Button(page, "Speichern & hochladen", "primary", 226, function() EHS:FlushAndReload() end,
        function()
            GameTooltip:AddLine("Speichern & hochladen")
            GameTooltip:AddLine("Speichert den Loot und lädt dazu die UI neu. Danach holt ihn das Sync-Tool von selbst ab.",
                1, 1, 1, true)
        end)
    page.upload:SetPoint("TOPRIGHT", -PAD, -12)
    page.uploadHint = Kit.Text(page, "hint", "RIGHT")
    page.uploadHint:SetPoint("TOPRIGHT", page.upload, "BOTTOMRIGHT", 0, -4)
    page.uploadHint:SetWidth(260)
    page.uploadHint:SetText("lädt die UI neu, das Sync-Tool holt es ab")

    -- Drei Zahlen
    page.stats = CreateFrame("Frame", nil, page)
    page.stats:SetPoint("TOPLEFT", PAD, -66)
    page.stats:SetSize(width, 46)
    Kit.Solid(page.stats, "BACKGROUND", Kit.C.panel2):SetAllPoints()
    Kit.Border(page.stats, Kit.C.line)
    local third = math.floor(width / 3)
    page.statSessions = statCell(page.stats, 1, third)
    page.statItems = statCell(page.stats, 2, third)
    page.statPending = statCell(page.stats, 3, width - 2 * third)

    -- Filter und Sammelauswahl
    local toolsY = -124
    page.raidDrop = Kit.Dropdown(page, 180, "Raid", raidItems, function() return filter.raid end,
        function(value)
            filter.raid = value
            offset = 0
            refresh()
        end, "Nur die Abende dieses Raids zeigen")
    page.raidDrop:SetPoint("TOPLEFT", PAD, toolsY)

    page.onlyPending = Kit.Chip(page, "Nur ungespeicherte", function()
        filter.onlyPending = not filter.onlyPending
        offset = 0
        refresh()
    end)
    page.onlyPending:SetPoint("LEFT", page.raidDrop, "RIGHT", 10, 0)
    page.onlySelected = Kit.Chip(page, "Nur ausgewählte", function()
        filter.onlySelected = not filter.onlySelected
        offset = 0
        refresh()
    end)
    page.onlySelected:SetPoint("LEFT", page.onlyPending, "RIGHT", 4, 0)

    -- Bei fuenfzig Abenden ist "alle Karazhan abwaehlen" sonst fuenfzig Klicks
    -- - deshalb wirken die Knoepfe auf das, was der Filter zeigt.
    page.selectNone = Kit.Button(page, "Alle abwählen", "secondary", 100, function()
        for _, s in ipairs(visibleSessions()) do EHS:SetExcluded(s.sessionId, true) end
        refresh()
        EHS:RefreshButton()
    end, "Alle Abende, die der Filter zeigt, nicht hochladen")
    page.selectNone:SetPoint("TOPRIGHT", -PAD, toolsY)
    page.selectAll = Kit.Button(page, "Alle auswählen", "secondary", 100, function()
        for _, s in ipairs(visibleSessions()) do EHS:SetExcluded(s.sessionId, false) end
        refresh()
        EHS:RefreshButton()
    end, "Alle Abende, die der Filter zeigt, wieder mitnehmen")
    page.selectAll:SetPoint("RIGHT", page.selectNone, "LEFT", -6, 0)

    -- Tabelle
    page.header = Kit.Header(page, COLUMNS, width)
    page.header:SetPoint("TOPLEFT", PAD, LIST_TOP + 22)

    page.list = CreateFrame("Frame", nil, page)
    page.list:SetPoint("TOPLEFT", PAD, LIST_TOP)
    page.list:SetSize(width, VISIBLE_ROWS * ROW_HEIGHT)
    Kit.Border(page.list, Kit.C.line)
    page.list:EnableMouseWheel(true)
    page.list:SetScript("OnMouseWheel", function(_, delta)
        local maxOffset = math.max(0, #shown - VISIBLE_ROWS)
        offset = math.max(0, math.min(maxOffset, offset - delta * 3))
        refresh()
    end)
    for i = 1, VISIBLE_ROWS do rows[i] = buildRow(page.list, i) end
    page.thumb = Kit.Thumb(page.list)

    page.empty = Kit.Empty(page, width - 40)
    page.empty:SetPoint("TOP", page.list, "TOP", 0, -50)

    page.listFoot = Kit.Text(page, "hint")
    page.listFoot:SetPoint("TOPLEFT", page.list, "BOTTOMLEFT", 0, -8)
    page.listFoot:SetWidth(width - 140)

    page.showExport = Kit.Button(page, "Export als Text", "link", 110, function() EHS:ShowExportFrame() end,
        "Derselbe Export zum Kopieren - für den Import im Admin-Menü ohne Sync-Tool")
    page.showExport:SetPoint("TOPRIGHT", page.list, "BOTTOMRIGHT", 0, -6)
end

local function refreshPage()
    if not page or not page:IsShown() then return end
    local self = EHS

    local sources = self:AvailableSources()
    page.sources:SetText(("%s   ·   %s"):format(
        sources.rclc and Kit.Color("RCLootCouncil gefunden", "green") or Kit.Color("RCLootCouncil nicht geladen", "red"),
        sources.gargul and Kit.Color("Gargul gefunden", "green") or Kit.Color("Gargul nicht geladen", "red")))

    local sessions = self:BuildSessions()
    local included, includedItems = 0, 0
    for _, session in ipairs(sessions) do
        if not self:IsExcluded(session.sessionId) then
            included = included + 1
            includedItems = includedItems + #session.items
        end
    end

    page.statSessions.value:SetText(included == #sessions and tostring(#sessions)
        or ("%d von %d"):format(included, #sessions))
    page.statSessions.label:SetText(#sessions == 1 and "Raid-Abend ausgewählt" or "Raid-Abende ausgewählt")
    page.statItems.value:SetText(tostring(includedItems))
    page.statItems.label:SetText(("Items exportbereit, letzte %d Tage"):format(self.db.settings.lookbackDays or 21))

    local pending = self:PendingCount()
    if pending > 0 then
        page.statPending.value:SetText(Kit.Color(pending, "gold"))
        page.statPending.label:SetText("Items noch nicht gespeichert")
    else
        page.statPending.value:SetText("0")
        page.statPending.label:SetText(self.db.lastFlushedAt
            and ("alles gespeichert, " .. date("%d.%m. %H:%M", self.db.lastFlushedAt))
            or "noch nie gespeichert")
    end

    page.upload:SetLabel(pending > 0 and ("Speichern & hochladen (%d)"):format(pending) or "Speichern & hochladen")
    page.upload:SetActive(not InCombatLockdown() and (pending > 0 or includedItems > 0))

    page.raidDrop:Refresh()
    page.onlyPending:SetSelected(filter.onlyPending)
    page.onlySelected:SetSelected(filter.onlySelected)

    shown = visibleSessions()
    page.empty:SetText(#shown == 0
        and (#sessions == 0
            and "Nichts gefunden. Zeitraum erhöhen (Einstellungen) oder prüfen, ob eins der Loot-Addons geladen ist."
            or "Kein Raid-Abend passt zu den Filtern.")
        or "")

    local maxOffset = math.max(0, #shown - VISIBLE_ROWS)
    if offset > maxOffset then offset = maxOffset end
    for i = 1, VISIBLE_ROWS do
        local row = rows[i]
        local session = shown[i + offset]
        if not session then
            row.sessionId, row.session = nil, nil
            row:Hide()
        else
            local excluded = self:IsExcluded(session.sessionId)
            local st = session.stats
            row.sessionId = session.sessionId
            row.session = session
            row.check:SetChecked(not excluded)

            local source
            if st.rclc > 0 and st.gargul > 0 then
                source = ("RCLC %d · Gar %d"):format(st.rclc, st.gargul)
            elseif st.gargul > 0 then
                source = "Gargul"
            else
                source = "RCLC"
            end

            row.cells[2]:SetText(fmtDay(session.startedAt))
            row.cells[3]:SetText(fmtSpan(session))
            row.cells[4]:SetText(session.instance ~= "" and session.instance or Kit.Color("unbekannt", "mute"))
            row.cells[5]:SetText(tostring(#session.items))
            row.cells[6]:SetText(tostring(st.players))
            row.cells[7]:SetText(st.bosses > 0 and tostring(st.bosses) or Kit.Color("-", "mute"))
            row.cells[8]:SetText(source)
            row.cells[9]:SetText(st.pending > 0 and Kit.Color(st.pending, "gold") or Kit.Color("-", "mute"))

            -- Abgewaehlte Zeilen sichtbar zuruecknehmen, statt sie zu verstecken:
            -- man muss sie ja wiederfinden, um sie zurueckzuholen.
            local alpha = excluded and .42 or 1
            for c = 2, #COLUMNS do row.cells[c]:SetAlpha(alpha) end
            row.check:SetAlpha(excluded and .7 or 1)
            row:Show()
        end
    end
    page.thumb.Set(offset, #shown, VISIBLE_ROWS)

    local hidden = #sessions - #shown
    page.listFoot:SetText(hidden > 0
        and ("%d von %d Abenden angezeigt, %d durch Filter ausgeblendet."):format(#shown, #sessions, hidden)
        or ("%d Raid-Abende."):format(#shown))
end

EHS:RegisterPage({
    id = "loot", label = "Loot-Sync", module = "loot", order = 10, frameName = "EventHelperSyncLootPage",
    icon = "Interface\\Icons\\INV_Misc_Bag_10",
    build = build, refresh = refreshPage,
    sub = function()
        local sessions = EHS:BuildSessions()
        return #sessions == 1 and "1 Abend" or (#sessions .. " Abende")
    end,
    badge = function() return EHS:PendingCount() end,
})
