--[[
Die Kopierbox hinter `/ehs export`.

Der Normalfall ist das Sync-Tool — das braucht diese UI nicht. Sie ist der
Rückfall für den Fall, dass auf dem Rechner nichts läuft oder gerade nichts
läuft: derselbe Envelope als JSON, markiert zum Kopieren, einzufügen im
Admin-Menü unter Historie & Loot -> Import. Der Server erkennt das Format von
selbst.

Ein EditBox in einem ScrollFrame ist der einzige Weg, in WoW Text herauszu-
bekommen — es gibt keine API, die in die Zwischenablage schreibt.
]]

local EHS = EventHelperSync

local frame

local function build()
    frame = CreateFrame("Frame", "EventHelperSyncExportFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(640, 440)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetFrameStrata("DIALOG")

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.title:SetPoint("TOP", 0, -6)
    frame.title:SetText("EventHelper — Loot-Export")

    frame.hint = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.hint:SetPoint("TOPLEFT", 14, -32)
    frame.hint:SetPoint("TOPRIGHT", -14, -32)
    frame.hint:SetJustifyH("LEFT")

    local scroll = CreateFrame("ScrollFrame", "$parentScroll", frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -70)
    scroll:SetPoint("BOTTOMRIGHT", -32, 40)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetFontObject(ChatFontNormal)
    edit:SetWidth(580)
    edit:SetAutoFocus(false)
    edit:SetScript("OnEscapePressed", function() frame:Hide() end)
    -- Der Inhalt ist zum Kopieren da, nicht zum Bearbeiten: jede Änderung wird
    -- sofort zurückgesetzt, damit niemand versehentlich kaputtes JSON einfügt.
    edit:SetScript("OnTextChanged", function(self, userInput)
        if userInput then self:SetText(frame.payload or "") end
    end)
    scroll:SetScrollChild(edit)
    frame.edit = edit

    local selectAll = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    selectAll:SetSize(160, 22)
    selectAll:SetPoint("BOTTOMLEFT", 14, 12)
    selectAll:SetText("Alles markieren")
    selectAll:SetScript("OnClick", function()
        frame.edit:SetFocus()
        frame.edit:HighlightText()
    end)

    local close = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    close:SetSize(100, 22)
    close:SetPoint("BOTTOMRIGHT", -14, 12)
    close:SetText("Schliessen")
    close:SetScript("OnClick", function() frame:Hide() end)

    tinsert(UISpecialFrames, "EventHelperSyncExportFrame")
end

function EHS:ShowExportFrame()
    if not frame then build() end

    local envelope = self:Rebuild()
    local items = 0
    for _, session in ipairs(envelope.sessions) do items = items + #session.items end

    if items == 0 then
        self:Print("Nichts zu exportieren — in den letzten "
            .. (self.db.settings.lookbackDays or 21) .. " Tagen wurde kein Loot vergeben.")
        self:Print("Weiter zurück schauen: /ehs days 60")
        return
    end

    frame.payload = self:EncodeJSON(envelope)
    frame.hint:SetText(("%d Raid-Session(s), %d Item(s). Mit Strg+A / Strg+C kopieren und im Admin-Menü unter |cffffd200Historie & Loot -> Import|r einfügen."):format(#envelope.sessions, items))
    frame.edit:SetText(frame.payload)
    frame:Show()
    frame.edit:SetFocus()
    frame.edit:HighlightText()
end
