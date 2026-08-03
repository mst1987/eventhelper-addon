--[[
Das Optionsfenster — die Antwort auf "was ist eigentlich der Stand?".

Bis hierher gab es nur Chat-Ausgaben und einen Knopf. Wer wissen wollte, ob das
Addon überhaupt etwas sieht, welche Raid-Abende gefunden wurden und was davon
schon auf der Platte liegt, musste /ehs tippen und die Zeilen im Chat suchen.

Das Fenster zeigt dasselbe auf einen Blick und lässt daneben alles einstellen:

  * Status oben — welche Loot-Addons gefunden wurden, wie viel exportbereit ist
    und wie viel davon noch ungespeichert.
  * Die Liste der Raid-Abende, jeder mit Datum, Instanz und Item-Zahl. Über das
    Häkchen fliegt ein Abend aus dem Export — der Pug vom Dienstag, die Runde
    mit Freunden, alles, was den Gilden-Loot nicht betrifft. Die Auswahl wird
    gespeichert und gilt dauerhaft.
  * Die Einstellungen darunter: wie weit zurück exportiert wird, ab welcher
    Lücke ein neuer Abend beginnt, ob der Upload-Knopf erscheinen soll.

Bewusst ohne Ace-Bibliotheken gebaut: das Addon soll eine Datei zum Kopieren
bleiben, ohne Abhängigkeiten, die mitgeliefert und gepflegt werden müssen.
]]

local EHS = EventHelperSync

local frame
local rows = {}

local WIDTH, HEIGHT = 560, 680
local ROW_HEIGHT = 22
-- So viele Zeilen passen in die Liste; der Rest wird gescrollt.
local VISIBLE_ROWS = 9

local function fmtDay(at)
    return date("%d.%m.%Y", at)
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

--- Zahleneingabe mit Beschriftung und Erklärung darunter.
local function numberField(parent, labelText, hintText, get, set)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(WIDTH - 60, 44)

    local title = label(holder, labelText)
    title:SetPoint("TOPLEFT", 0, 0)

    local box = CreateFrame("EditBox", nil, holder, "InputBoxTemplate")
    box:SetSize(60, 20)
    box:SetPoint("TOPLEFT", 200, 2)
    box:SetAutoFocus(false)
    box:SetNumeric(true)
    box:SetMaxLetters(4)

    local hint = label(holder, hintText, "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 0, -18)
    hint:SetWidth(WIDTH - 80)
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

    local hint = label(parent, hintText, "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 4, 2)
    hint:SetWidth(WIDTH - 80)
    hint:SetJustifyH("LEFT")

    box:SetScript("OnClick", function(self)
        set(self:GetChecked() and true or false)
        EHS:RefreshOptions()
        EHS:RefreshButton()
    end)
    box.refresh = function() box:SetChecked(get()) end
    return box
end

-- ---------------------------------------------------------------------------
-- Aufbau
-- ---------------------------------------------------------------------------

local function buildRow(parent, index)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(WIDTH - 90, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)

    row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.check:SetSize(20, 20)
    row.check:SetPoint("LEFT", 0, 0)

    row.day = label(row, "", "GameFontHighlightSmall")
    row.day:SetPoint("LEFT", 26, 0)
    row.day:SetWidth(78)
    row.day:SetJustifyH("LEFT")

    row.span = label(row, "", "GameFontDisableSmall")
    row.span:SetPoint("LEFT", 106, 0)
    row.span:SetWidth(80)
    row.span:SetJustifyH("LEFT")

    row.instance = label(row, "", "GameFontHighlightSmall")
    row.instance:SetPoint("LEFT", 188, 0)
    row.instance:SetWidth(190)
    row.instance:SetJustifyH("LEFT")

    row.count = label(row, "", "GameFontHighlightSmall")
    row.count:SetPoint("LEFT", 382, 0)
    row.count:SetWidth(70)
    row.count:SetJustifyH("RIGHT")

    row.check:SetScript("OnClick", function(self)
        if not row.sessionId then return end
        -- Häkchen an = exportieren, also NICHT ausgeschlossen.
        EHS:SetExcluded(row.sessionId, not self:GetChecked())
        EHS:RefreshOptions()
        EHS:RefreshButton()
    end)

    row:SetScript("OnEnter", function()
        if not row.sessionId then return end
        GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
        GameTooltip:AddLine(row.instance:GetText())
        GameTooltip:AddLine(row.sessionId, .6, .6, .6)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(row.check:GetChecked()
            and "Häkchen entfernen, um diesen Abend nicht hochzuladen."
            or "Häkchen setzen, um diesen Abend wieder mitzunehmen.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:EnableMouse(true)

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
    frame.summary:SetWidth(WIDTH - 40)
    frame.summary:SetJustifyH("LEFT")

    frame.pending = label(frame, "", "GameFontNormalSmall")
    frame.pending:SetPoint("TOPLEFT", 16, -76)
    frame.pending:SetWidth(WIDTH - 40)
    frame.pending:SetJustifyH("LEFT")

    frame.upload = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.upload:SetSize(250, 26)
    frame.upload:SetPoint("TOPLEFT", 16, -98)
    frame.upload:SetScript("OnClick", function()
        -- Der Klick ist das Hardware-Event, das ReloadUI() verlangt.
        EHS:FlushAndReload()
    end)

    frame.showExport = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.showExport:SetSize(150, 26)
    frame.showExport:SetPoint("LEFT", frame.upload, "RIGHT", 8, 0)
    frame.showExport:SetText("Export anzeigen")
    frame.showExport:SetScript("OnClick", function() EHS:ShowExportFrame() end)

    -- --- Liste der Raid-Abende ---------------------------------------------
    frame.listTitle = label(frame, "Gefundene Raid-Abende", "GameFontNormal")
    frame.listTitle:SetPoint("TOPLEFT", 16, -136)

    frame.listHint = label(frame, "Häkchen weg = dieser Abend wird nicht hochgeladen.", "GameFontDisableSmall")
    frame.listHint:SetPoint("TOPLEFT", 16, -152)

    frame.scroll = CreateFrame("ScrollFrame", "$parentList", frame, "FauxScrollFrameTemplate")
    frame.scroll:SetPoint("TOPLEFT", 20, -172)
    frame.scroll:SetSize(WIDTH - 62, VISIBLE_ROWS * ROW_HEIGHT)
    frame.scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, function() EHS:RefreshOptions() end)
    end)

    frame.rowHolder = CreateFrame("Frame", nil, frame)
    frame.rowHolder:SetPoint("TOPLEFT", frame.scroll, "TOPLEFT", 0, 0)
    frame.rowHolder:SetSize(WIDTH - 90, VISIBLE_ROWS * ROW_HEIGHT)
    for i = 1, VISIBLE_ROWS do
        rows[i] = buildRow(frame.rowHolder, i)
    end

    frame.empty = label(frame, "", "GameFontDisableLarge")
    frame.empty:SetPoint("TOPLEFT", frame.scroll, "TOPLEFT", 10, -30)
    frame.empty:SetWidth(WIDTH - 80)
    frame.empty:SetJustifyH("LEFT")

    -- --- Einstellungen -----------------------------------------------------
    local settingsTop = -172 - (VISIBLE_ROWS * ROW_HEIGHT) - 18

    frame.settingsTitle = label(frame, "Einstellungen", "GameFontNormal")
    frame.settingsTitle:SetPoint("TOPLEFT", 16, settingsTop)

    frame.days = numberField(frame,
        "Zeitraum (Tage)",
        "Wie weit zurück Loot exportiert wird. Der Server erkennt Doppelte selbst — ein grosser Wert kostet nur Bandbreite.",
        function() return EHS.db.settings.lookbackDays end,
        function(v) EHS.db.settings.lookbackDays = math.max(1, math.floor(v)) end)
    frame.days:SetPoint("TOPLEFT", 26, settingsTop - 22)

    frame.gap = numberField(frame,
        "Neuer Abend ab (Std.)",
        "Ab welcher Pause zwischen zwei Vergaben ein neuer Raid-Abend beginnt.",
        function() return EHS.db.settings.sessionGapHours end,
        function(v) EHS.db.settings.sessionGapHours = math.max(1, math.floor(v)) end)
    frame.gap:SetPoint("TOPLEFT", 26, settingsTop - 68)

    frame.showButton = checkbox(frame,
        "Upload-Knopf anzeigen",
        "Erscheint von selbst, sobald es etwas zu speichern gibt.",
        function() return EHS.db.settings.showButton end,
        function(v) EHS.db.settings.showButton = v end)
    frame.showButton:SetPoint("TOPLEFT", 26, settingsTop - 116)

    frame.minimap = checkbox(frame,
        "Minimap-Knopf anzeigen",
        "Der kleine Knopf am Rand der Minimap, der dieses Fenster öffnet.",
        function() return EHS.db.settings.showMinimap end,
        function(v) EHS.db.settings.showMinimap = v; EHS:RefreshMinimap() end)
    frame.minimap:SetPoint("TOPLEFT", 26, settingsTop - 156)

    frame.skipAward = checkbox(frame,
        "Bank- und Entzauber-Items weglassen",
        "Items, die nicht an einen Raider gingen (RCLootcouncil: Banking, Disenchant; Gargul: ||de||).",
        function() return EHS.db.settings.skipAwardReasons ~= false end,
        function(v) EHS.db.settings.skipAwardReasons = v end)
    frame.skipAward:SetPoint("TOPLEFT", 26, settingsTop - 196)

    frame.skipInfo = label(frame, "", "GameFontDisableSmall")
    frame.skipInfo:SetPoint("TOPLEFT", 46, settingsTop - 228)
    frame.skipInfo:SetWidth(WIDTH - 80)
    frame.skipInfo:SetJustifyH("LEFT")

    tinsert(UISpecialFrames, "EventHelperSyncOptionsFrame")
    frame:Hide()
end

-- ---------------------------------------------------------------------------
-- Auffrischen
-- ---------------------------------------------------------------------------

local function green(text) return "|cff44dd44" .. text .. "|r" end
local function red(text) return "|cffdd4444" .. text .. "|r" end
local function gold(text) return "|cffffd200" .. text .. "|r" end

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

    -- Liste: neueste zuerst, das ist die, die interessiert.
    local ordered = {}
    for i = #sessions, 1, -1 do ordered[#ordered + 1] = sessions[i] end

    frame.empty:SetText(#ordered == 0
        and "Nichts gefunden. Zeitraum erhöhen oder prüfen, ob eins der Loot-Addons geladen ist."
        or "")

    FauxScrollFrame_Update(frame.scroll, #ordered, VISIBLE_ROWS, ROW_HEIGHT)
    local offset = FauxScrollFrame_GetOffset(frame.scroll)
    for i = 1, VISIBLE_ROWS do
        local row = rows[i]
        local session = ordered[i + offset]
        if not session then
            row:Hide()
        else
            row.sessionId = session.sessionId
            row.check:SetChecked(not self:IsExcluded(session.sessionId))
            row.day:SetText(fmtDay(session.startedAt))
            row.span:SetText(fmtSpan(session))
            row.instance:SetText(session.instance ~= "" and session.instance or "|cff888888unbekannt|r")
            row.count:SetText(("%d Item(s)"):format(#session.items))

            -- Abgewählte Zeilen sichtbar zurücknehmen, statt sie zu verstecken:
            -- man muss sie ja wiederfinden, um sie zurückzuholen.
            local alpha = self:IsExcluded(session.sessionId) and .4 or 1
            row.day:SetAlpha(alpha)
            row.span:SetAlpha(alpha)
            row.instance:SetAlpha(alpha)
            row.count:SetAlpha(alpha)
            row:Show()
        end
    end

    frame.days.refresh()
    frame.gap.refresh()
    frame.showButton.refresh()
    frame.minimap.refresh()
    frame.skipAward.refresh()

    -- Wie viel der Schalter tatsächlich wegnimmt — sonst bleibt er eine
    -- Behauptung, und niemand weiss, ob er greift.
    local stats = self.collectStats or {}
    local weg = (stats.skippedRclc or 0) + (stats.skippedGargul or 0)
    if weg > 0 then
        frame.skipInfo:SetText(("Zuletzt %d Item(s) übersprungen (%d RCLootcouncil, %d Gargul)."):format(
            weg, stats.skippedRclc or 0, stats.skippedGargul or 0))
    elseif self.db.settings.skipAwardReasons ~= false then
        frame.skipInfo:SetText("Im Zeitraum war nichts zum Überspringen dabei.")
    else
        frame.skipInfo:SetText("Aus — Bank- und Entzauber-Items werden mit hochgeladen.")
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
