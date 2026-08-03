--[[
Das Optionsfenster — die Antwort auf "was ist eigentlich der Stand?".

Es zeigt in einer Tabelle, was das Addon gefunden hat, und lässt daneben alles
einstellen. Der Aufbau folgt dem, was man vor einem Upload wissen will:

  * Kopfzeile — welche Loot-Addons gefunden wurden, wie viel exportbereit ist,
    wie viel davon noch nicht auf der Platte liegt.
  * Die Tabelle der Raid-Abende. Jede Zeile beantwortet für sich, ob dieser
    Abend hochgeladen gehört: Datum mit Wochentag (Raids haben feste Tage),
    Zeitspanne, Raid, wie viele Items, an wie viele Spieler, wie viele Bosse,
    aus welcher Quelle, und wie viel davon noch offen ist.
  * Filter darüber, weil eine Gilde nach ein paar Monaten bei fünfzig Abenden
    landet und "alle Karazhan-Abende abwählen" sonst fünfzig Klicks wären.
  * Die Einstellungen darunter.

Bewusst ohne Ace-Bibliotheken gebaut: das Addon soll ein Ordner zum Kopieren
bleiben, ohne Abhängigkeiten, die mitgeliefert und gepflegt werden müssen.
]]

local EHS = EventHelperSync

local frame
local rows = {}

local WIDTH, HEIGHT = 860, 700
local ROW_HEIGHT = 20
-- So viele Zeilen passen in die Tabelle; der Rest wird gescrollt.
local VISIBLE_ROWS = 14

-- Spaltenraster: {Beschriftung, x-Position, Breite, Ausrichtung}
local COLUMNS = {
    { "",         0,   24,  "LEFT"  },
    { "Datum",    26,  104, "LEFT"  },
    { "Zeit",     132, 88,  "LEFT"  },
    { "Raid",     222, 250, "LEFT"  },
    { "Items",    474, 46,  "RIGHT" },
    { "Spieler",  524, 52,  "RIGHT" },
    { "Bosse",    580, 44,  "RIGHT" },
    { "Quelle",   628, 96,  "LEFT"  },
    { "Offen",    726, 48,  "RIGHT" },
}

local WEEKDAYS = { "So", "Mo", "Di", "Mi", "Do", "Fr", "Sa" }

local function green(text) return "|cff44dd44" .. text .. "|r" end
local function red(text) return "|cffdd4444" .. text .. "|r" end
local function gold(text) return "|cffffd200" .. text .. "|r" end
local function grey(text) return "|cff888888" .. text .. "|r" end

local function fmtDay(at)
    local wd = WEEKDAYS[tonumber(date("%w", at)) + 1] or ""
    return ("%s %s"):format(wd, date("%d.%m.%y", at))
end

local function fmtSpan(session)
    local from = date("%H:%M", session.startedAt)
    local to = date("%H:%M", session.endedAt)
    if from == to then return from end
    return from .. "–" .. to
end

-- ---------------------------------------------------------------------------
-- Bausteine
-- ---------------------------------------------------------------------------

local function label(parent, text, font)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontNormal")
    fs:SetText(text)
    return fs
end

local function numberField(parent, labelText, hintText, get, set)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(WIDTH - 60, 40)

    local title = label(holder, labelText)
    title:SetPoint("TOPLEFT", 0, 0)

    local box = CreateFrame("EditBox", nil, holder, "InputBoxTemplate")
    box:SetSize(60, 20)
    box:SetPoint("TOPLEFT", 200, 2)
    box:SetAutoFocus(false)
    box:SetNumeric(true)
    box:SetMaxLetters(4)

    local hint = label(holder, hintText, "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 270, -2)
    hint:SetWidth(WIDTH - 320)
    hint:SetJustifyH("LEFT")

    local function commit()
        local value = tonumber(box:GetText())
        if value then set(value) end
        box:SetText(tostring(get()))
        box:ClearFocus()
        EHS:RefreshOptions()
        EHS:RefreshButton()
    end
    box:SetScript("OnEnterPressed", commit)
    box:SetScript("OnEditFocusLost", function() box:SetText(tostring(get())) end)
    box:SetScript("OnEscapePressed", function() box:SetText(tostring(get())); box:ClearFocus() end)

    holder.refresh = function() box:SetText(tostring(get())) end
    return holder
end

local function checkbox(parent, labelText, hintText, get, set)
    local box = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    box:SetSize(24, 24)
    box.text = label(box, labelText)
    box.text:SetPoint("LEFT", box, "RIGHT", 4, 0)

    if hintText and hintText ~= "" then
        local hint = label(parent, hintText, "GameFontDisableSmall")
        hint:SetPoint("LEFT", box, "RIGHT", 240, 0)
        hint:SetWidth(WIDTH - 340)
        hint:SetJustifyH("LEFT")
    end

    box:SetScript("OnClick", function(self)
        set(self:GetChecked() and true or false)
        EHS:RefreshOptions()
        EHS:RefreshButton()
    end)
    box.refresh = function() box:SetChecked(get()) end
    return box
end

-- ---------------------------------------------------------------------------
-- Filter
-- ---------------------------------------------------------------------------

-- Nur zur Laufzeit, nicht gespeichert: ein Filter ist eine Frage von Sekunden,
-- keine Einstellung. Beim nächsten Öffnen soll wieder alles sichtbar sein.
local filter = { raid = "", onlyPending = false, onlySelected = false }

--- Die Abende, die die Filter durchlassen — neueste zuerst.
local function visibleSessions()
    local all = EHS:BuildSessions()
    local out = {}
    for i = #all, 1, -1 do
        local s = all[i]
        local raidOk = filter.raid == "" or s.instance == filter.raid
        local pendingOk = not filter.onlyPending or (s.stats.pending or 0) > 0
        local selOk = not filter.onlySelected or not EHS:IsExcluded(s.sessionId)
        if raidOk and pendingOk and selOk then out[#out + 1] = s end
    end
    return out
end

--- Alle vorkommenden Raidnamen, für das Filter-Menü.
local function raidNames()
    local seen, names = {}, {}
    for _, s in ipairs(EHS:BuildSessions()) do
        local name = s.instance ~= "" and s.instance or "(unbekannt)"
        if not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
end

-- ---------------------------------------------------------------------------
-- Aufbau
-- ---------------------------------------------------------------------------

local function buildRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(WIDTH - 60, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)

    -- Zebrastreifen: bei vierzehn Zeilen mit acht Spalten verrutscht das Auge
    -- sonst in die Nachbarzeile.
    local stripe = row:CreateTexture(nil, "BACKGROUND")
    stripe:SetAllPoints()
    stripe:SetColorTexture(1, 1, 1, index % 2 == 0 and 0.03 or 0)
    row.stripe = stripe

    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")

    row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.check:SetSize(20, 20)
    row.check:SetPoint("LEFT", 0, 0)

    row.cells = {}
    for i = 2, #COLUMNS do
        local col = COLUMNS[i]
        local fs = label(row, "", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", col[2], 0)
        fs:SetWidth(col[3])
        fs:SetJustifyH(col[4])
        row.cells[i] = fs
    end

    row.check:SetScript("OnClick", function(self)
        if not row.sessionId then return end
        -- Häkchen an = exportieren, also NICHT ausgeschlossen.
        EHS:SetExcluded(row.sessionId, not self:GetChecked())
        EHS:RefreshOptions()
        EHS:RefreshButton()
    end)

    -- Ein Klick auf die Zeile schaltet dasselbe um: das Häkchen allein ist ein
    -- kleines Ziel, und man klickt ohnehin auf die Zeile, die man meint.
    row:SetScript("OnClick", function()
        if not row.sessionId then return end
        EHS:SetExcluded(row.sessionId, not EHS:IsExcluded(row.sessionId))
        EHS:RefreshOptions()
        EHS:RefreshButton()
    end)

    row:SetScript("OnEnter", function()
        if not row.session then return end
        local s = row.session
        GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
        GameTooltip:AddLine(s.instance ~= "" and s.instance or "Unbekannter Raid")
        GameTooltip:AddDoubleLine("Beginn", date("%d.%m.%Y %H:%M", s.startedAt))
        GameTooltip:AddDoubleLine("Ende", date("%d.%m.%Y %H:%M", s.endedAt))
        GameTooltip:AddDoubleLine("Items", #s.items)
        GameTooltip:AddDoubleLine("Empfänger", s.stats.players)
        if s.stats.bosses > 0 then GameTooltip:AddDoubleLine("Bosse", s.stats.bosses) end
        GameTooltip:AddDoubleLine("RCLootcouncil / Gargul", s.stats.rclc .. " / " .. s.stats.gargul)
        if s.stats.offspec > 0 then GameTooltip:AddDoubleLine("davon Zweitspec", s.stats.offspec) end
        if s.stats.pending > 0 then
            GameTooltip:AddDoubleLine("noch nicht gespeichert", "|cffffd200" .. s.stats.pending .. "|r")
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(EHS:IsExcluded(s.sessionId)
            and "Klicken, um diesen Abend wieder mitzunehmen."
            or "Klicken, um diesen Abend nicht hochzuladen.", 1, 1, 1, true)
        GameTooltip:AddLine(s.sessionId, .5, .5, .5)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    return row
end

local function build()
    frame = CreateFrame("Frame", "EventHelperSyncOptionsFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)

    frame.title = label(frame, "EventHelper Sync", "GameFontHighlight")
    frame.title:SetPoint("TOP", 0, -6)

    -- --- Status ------------------------------------------------------------
    frame.sources = label(frame, "", "GameFontNormalSmall")
    frame.sources:SetPoint("TOPLEFT", 16, -32)
    frame.sources:SetWidth(WIDTH - 40)
    frame.sources:SetJustifyH("LEFT")

    frame.summary = label(frame, "", "GameFontNormalLarge")
    frame.summary:SetPoint("TOPLEFT", 16, -52)
    frame.summary:SetWidth(WIDTH - 300)
    frame.summary:SetJustifyH("LEFT")

    frame.pending = label(frame, "", "GameFontNormalSmall")
    frame.pending:SetPoint("TOPLEFT", 16, -76)
    frame.pending:SetWidth(WIDTH - 300)
    frame.pending:SetJustifyH("LEFT")

    frame.upload = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.upload:SetSize(240, 26)
    frame.upload:SetPoint("TOPRIGHT", -16, -46)
    frame.upload:SetScript("OnClick", function()
        -- Der Klick ist das Hardware-Event, das ReloadUI() verlangt.
        EHS:FlushAndReload()
    end)

    frame.showExport = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.showExport:SetSize(240, 22)
    frame.showExport:SetPoint("TOPRIGHT", -16, -76)
    frame.showExport:SetText("Export als Text anzeigen")
    frame.showExport:SetScript("OnClick", function() EHS:ShowExportFrame() end)

    -- --- Filterleiste ------------------------------------------------------
    local FILTER_Y = -112

    frame.filterLabel = label(frame, "Filter:", "GameFontNormalSmall")
    frame.filterLabel:SetPoint("TOPLEFT", 16, FILTER_Y)

    frame.raidDrop = CreateFrame("Frame", "EventHelperSyncRaidFilter", frame, "UIDropDownMenuTemplate")
    frame.raidDrop:SetPoint("TOPLEFT", 46, FILTER_Y + 6)
    UIDropDownMenu_SetWidth(frame.raidDrop, 190)
    UIDropDownMenu_Initialize(frame.raidDrop, function(_, level)
        local info = UIDropDownMenu_CreateInfo()
        info.func = function(self)
            filter.raid = self.value == "__all__" and "" or self.value
            UIDropDownMenu_SetSelectedValue(frame.raidDrop, self.value)
            EHS:RefreshOptions()
        end
        info.text, info.value = "Alle Raids", "__all__"
        info.checked = filter.raid == ""
        UIDropDownMenu_AddButton(info, level)
        for _, name in ipairs(raidNames()) do
            info = UIDropDownMenu_CreateInfo()
            info.func = function(self)
                filter.raid = self.value
                UIDropDownMenu_SetSelectedValue(frame.raidDrop, self.value)
                EHS:RefreshOptions()
            end
            info.text, info.value = name, name
            info.checked = filter.raid == name
            UIDropDownMenu_AddButton(info, level)
        end
    end)

    frame.onlyPending = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    frame.onlyPending:SetSize(22, 22)
    frame.onlyPending:SetPoint("TOPLEFT", 262, FILTER_Y + 4)
    frame.onlyPending.text = label(frame.onlyPending, "nur ungespeicherte", "GameFontNormalSmall")
    frame.onlyPending.text:SetPoint("LEFT", frame.onlyPending, "RIGHT", 2, 0)
    frame.onlyPending:SetScript("OnClick", function(self)
        filter.onlyPending = self:GetChecked() and true or false
        EHS:RefreshOptions()
    end)

    frame.onlySelected = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    frame.onlySelected:SetSize(22, 22)
    frame.onlySelected:SetPoint("TOPLEFT", 420, FILTER_Y + 4)
    frame.onlySelected.text = label(frame.onlySelected, "nur ausgewählte", "GameFontNormalSmall")
    frame.onlySelected.text:SetPoint("LEFT", frame.onlySelected, "RIGHT", 2, 0)
    frame.onlySelected:SetScript("OnClick", function(self)
        filter.onlySelected = self:GetChecked() and true or false
        EHS:RefreshOptions()
    end)

    -- Sammelauswahl. Bei fünfzig Abenden ist "alle Karazhan abwählen" sonst
    -- fünfzig Klicks — deshalb wirken die Knöpfe auf das, was der Filter zeigt.
    frame.selectAll = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.selectAll:SetSize(110, 22)
    frame.selectAll:SetPoint("TOPRIGHT", -132, FILTER_Y + 4)
    frame.selectAll:SetText("Alle auswählen")
    frame.selectAll:SetScript("OnClick", function()
        for _, s in ipairs(visibleSessions()) do EHS:SetExcluded(s.sessionId, false) end
        EHS:RefreshOptions()
        EHS:RefreshButton()
    end)

    frame.selectNone = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.selectNone:SetSize(110, 22)
    frame.selectNone:SetPoint("TOPRIGHT", -16, FILTER_Y + 4)
    frame.selectNone:SetText("Alle abwählen")
    frame.selectNone:SetScript("OnClick", function()
        for _, s in ipairs(visibleSessions()) do EHS:SetExcluded(s.sessionId, true) end
        EHS:RefreshOptions()
        EHS:RefreshButton()
    end)

    -- --- Tabellenkopf ------------------------------------------------------
    local HEAD_Y = FILTER_Y - 34
    frame.headers = {}
    for i = 2, #COLUMNS do
        local col = COLUMNS[i]
        local fs = label(frame, col[1], "GameFontNormalSmall")
        fs:SetPoint("TOPLEFT", 20 + col[2], HEAD_Y)
        fs:SetWidth(col[3])
        fs:SetJustifyH(col[4])
        frame.headers[i] = fs
    end

    local line = frame:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 1, 1, 0.12)
    line:SetPoint("TOPLEFT", 18, HEAD_Y - 14)
    line:SetPoint("TOPRIGHT", -18, HEAD_Y - 14)
    line:SetHeight(1)

    -- --- Tabelle -----------------------------------------------------------
    local LIST_Y = HEAD_Y - 18
    frame.scroll = CreateFrame("ScrollFrame", "$parentList", frame, "FauxScrollFrameTemplate")
    frame.scroll:SetPoint("TOPLEFT", 20, LIST_Y)
    frame.scroll:SetSize(WIDTH - 62, VISIBLE_ROWS * ROW_HEIGHT)
    frame.scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, function() EHS:RefreshOptions() end)
    end)

    frame.rowHolder = CreateFrame("Frame", nil, frame)
    frame.rowHolder:SetPoint("TOPLEFT", frame.scroll, "TOPLEFT", 0, 0)
    frame.rowHolder:SetSize(WIDTH - 60, VISIBLE_ROWS * ROW_HEIGHT)
    for i = 1, VISIBLE_ROWS do
        rows[i] = buildRow(frame.rowHolder, i)
    end

    frame.empty = label(frame, "", "GameFontDisableLarge")
    frame.empty:SetPoint("TOPLEFT", frame.scroll, "TOPLEFT", 10, -30)
    frame.empty:SetWidth(WIDTH - 80)
    frame.empty:SetJustifyH("LEFT")

    frame.listFoot = label(frame, "", "GameFontDisableSmall")
    frame.listFoot:SetPoint("TOPLEFT", 20, LIST_Y - (VISIBLE_ROWS * ROW_HEIGHT) - 4)
    frame.listFoot:SetWidth(WIDTH - 60)
    frame.listFoot:SetJustifyH("LEFT")

    -- --- Einstellungen -----------------------------------------------------
    local settingsTop = LIST_Y - (VISIBLE_ROWS * ROW_HEIGHT) - 26

    frame.settingsTitle = label(frame, "Einstellungen", "GameFontNormal")
    frame.settingsTitle:SetPoint("TOPLEFT", 16, settingsTop)

    frame.days = numberField(frame,
        "Zeitraum (Tage)",
        "Wie weit zurück Loot gesucht wird. Der Server erkennt Doppelte selbst.",
        function() return EHS.db.settings.lookbackDays end,
        function(v) EHS.db.settings.lookbackDays = math.max(1, math.floor(v)) end)
    frame.days:SetPoint("TOPLEFT", 26, settingsTop - 20)

    frame.gap = numberField(frame,
        "Neuer Abend ab (Std.)",
        "Ab welcher Pause zwischen zwei Vergaben ein neuer Raid-Abend beginnt.",
        function() return EHS.db.settings.sessionGapHours end,
        function(v) EHS.db.settings.sessionGapHours = math.max(1, math.floor(v)) end)
    frame.gap:SetPoint("TOPLEFT", 26, settingsTop - 44)

    frame.skipAward = checkbox(frame,
        "Bank- und Entzauber-Items weglassen",
        "RCLootcouncil: Banking/Disenchant · Gargul: ||de||",
        function() return EHS.db.settings.skipAwardReasons ~= false end,
        function(v) EHS.db.settings.skipAwardReasons = v end)
    frame.skipAward:SetPoint("TOPLEFT", 26, settingsTop - 70)

    frame.showButton = checkbox(frame,
        "Upload-Knopf anzeigen", "",
        function() return EHS.db.settings.showButton end,
        function(v) EHS.db.settings.showButton = v end)
    frame.showButton:SetPoint("TOPLEFT", 26, settingsTop - 96)

    frame.minimap = checkbox(frame,
        "Minimap-Knopf anzeigen", "",
        function() return EHS.db.settings.showMinimap end,
        function(v) EHS.db.settings.showMinimap = v; EHS:RefreshMinimap() end)
    frame.minimap:SetPoint("TOPLEFT", 300, settingsTop - 96)

    frame.skipInfo = label(frame, "", "GameFontDisableSmall")
    frame.skipInfo:SetPoint("TOPLEFT", 26, settingsTop - 122)
    frame.skipInfo:SetWidth(WIDTH - 60)
    frame.skipInfo:SetJustifyH("LEFT")

    tinsert(UISpecialFrames, "EventHelperSyncOptionsFrame")
    frame:Hide()
end

-- ---------------------------------------------------------------------------
-- Auffrischen
-- ---------------------------------------------------------------------------

function EHS:RefreshOptions()
    if not frame or not frame:IsShown() then return end

    local sources = self:AvailableSources()
    frame.sources:SetText(("Quellen:  RCLootcouncil %s    Gargul %s"):format(
        sources.rclc and green("gefunden") or red("nicht geladen"),
        sources.gargul and green("gefunden") or red("nicht geladen")))

    local sessions = self:BuildSessions()
    local included, includedItems, totalItems = 0, 0, 0
    for _, session in ipairs(sessions) do
        totalItems = totalItems + #session.items
        if not self:IsExcluded(session.sessionId) then
            included = included + 1
            includedItems = includedItems + #session.items
        end
    end

    if #sessions == 0 then
        frame.summary:SetText("Kein Loot im gewählten Zeitraum.")
    elseif included == #sessions then
        frame.summary:SetText(("%d Raid-Abende, %d Items exportbereit."):format(included, includedItems))
    else
        frame.summary:SetText(("%d von %d Raid-Abenden, %d von %d Items exportbereit."):format(
            included, #sessions, includedItems, totalItems))
    end

    local pending = self:PendingCount()
    if pending > 0 then
        frame.pending:SetText(gold(("%d Item(s) liegen noch nicht auf der Platte."):format(pending)))
    elseif self.db.lastFlushedAt then
        frame.pending:SetText("Gespeichert am " .. date("%d.%m.%Y um %H:%M", self.db.lastFlushedAt) .. ".")
    else
        frame.pending:SetText("Noch nie gespeichert.")
    end

    frame.upload:SetText(pending > 0
        and ("Jetzt speichern (%d)"):format(pending)
        or "Jetzt speichern")
    frame.upload:SetEnabled(not InCombatLockdown() and (pending > 0 or includedItems > 0))

    UIDropDownMenu_SetText(frame.raidDrop, filter.raid ~= "" and filter.raid or "Alle Raids")
    frame.onlyPending:SetChecked(filter.onlyPending)
    frame.onlySelected:SetChecked(filter.onlySelected)

    local shown = visibleSessions()
    frame.empty:SetText(#shown == 0
        and (#sessions == 0
            and "Nichts gefunden. Zeitraum erhöhen oder prüfen, ob eins der Loot-Addons geladen ist."
            or "Kein Raid-Abend passt zu den Filtern.")
        or "")

    FauxScrollFrame_Update(frame.scroll, #shown, VISIBLE_ROWS, ROW_HEIGHT)
    local offset = FauxScrollFrame_GetOffset(frame.scroll)
    for i = 1, VISIBLE_ROWS do
        local row = rows[i]
        local session = shown[i + offset]
        if not session then
            row:Hide()
        else
            local excluded = self:IsExcluded(session.sessionId)
            local st = session.stats
            row.sessionId = session.sessionId
            row.session = session
            row.check:SetChecked(not excluded)

            local quelle
            if st.rclc > 0 and st.gargul > 0 then
                quelle = ("RCLC %d · Gar %d"):format(st.rclc, st.gargul)
            elseif st.gargul > 0 then
                quelle = "Gargul " .. st.gargul
            else
                quelle = "RCLootc. " .. st.rclc
            end

            row.cells[2]:SetText(fmtDay(session.startedAt))
            row.cells[3]:SetText(fmtSpan(session))
            row.cells[4]:SetText(session.instance ~= "" and session.instance or grey("unbekannt"))
            row.cells[5]:SetText(tostring(#session.items))
            row.cells[6]:SetText(tostring(st.players))
            row.cells[7]:SetText(st.bosses > 0 and tostring(st.bosses) or grey("–"))
            row.cells[8]:SetText(quelle)
            row.cells[9]:SetText(st.pending > 0 and gold(tostring(st.pending)) or grey("–"))

            -- Abgewählte Zeilen sichtbar zurücknehmen, statt sie zu verstecken:
            -- man muss sie ja wiederfinden, um sie zurückzuholen.
            local alpha = excluded and .4 or 1
            for c = 2, #COLUMNS do row.cells[c]:SetAlpha(alpha) end
            row:Show()
        end
    end

    local gefiltert = #sessions - #shown
    frame.listFoot:SetText(gefiltert > 0
        and ("%d von %d Abenden angezeigt — %d durch Filter ausgeblendet."):format(#shown, #sessions, gefiltert)
        or ("%d Raid-Abende."):format(#shown))

    frame.days.refresh()
    frame.gap.refresh()
    frame.showButton.refresh()
    frame.minimap.refresh()
    frame.skipAward.refresh()

    -- Wie viel der Schalter tatsächlich wegnimmt — sonst bleibt er eine
    -- Behauptung, und niemand weiss, ob er greift.
    local stats = self.collectStats or {}
    local weg = (stats.skippedRclc or 0) + (stats.skippedGargul or 0)
    if self.db.settings.skipAwardReasons == false then
        frame.skipInfo:SetText(gold("Bank- und Entzauber-Items werden mit hochgeladen."))
    elseif weg > 0 then
        frame.skipInfo:SetText(("Zuletzt %d Item(s) übersprungen (%d RCLootcouncil, %d Gargul)."):format(
            weg, stats.skippedRclc or 0, stats.skippedGargul or 0))
    else
        frame.skipInfo:SetText("Im Zeitraum war nichts zum Überspringen dabei.")
    end
end

function EHS:ToggleOptions()
    if not frame then build() end
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
        self:RefreshOptions()
    end
end

function EHS:ShowOptions()
    if not frame then build() end
    frame:Show()
    self:RefreshOptions()
end
