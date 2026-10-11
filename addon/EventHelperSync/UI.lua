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
    local Kit = EHS.Kit
    frame = Kit.Window({
        name = "EventHelperSyncExportFrame", title = "Loot-Export", width = 640, height = 440,
        strata = "DIALOG", point = { "CENTER", 0, 0 },
    })
    local body = frame.body

    frame.hint = Kit.Text(body, "small")
    frame.hint:SetPoint("TOPLEFT", 14, -12)
    frame.hint:SetPoint("TOPRIGHT", -14, -12)
    if frame.hint.SetWordWrap then frame.hint:SetWordWrap(true) end

    local scroll = CreateFrame("ScrollFrame", "$parentScroll", frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", body, "TOPLEFT", 12, -46)
    scroll:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -32, 44)
    local well = Kit.Solid(frame, "BACKGROUND", Kit.C.field)
    well:SetPoint("TOPLEFT", scroll, "TOPLEFT", -4, 4)
    well:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", 4, -4)

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

    frame.selectAll = Kit.Button(body, "Alles markieren", "primary", 160, function()
        frame.edit:SetFocus()
        frame.edit:HighlightText()
    end)
    frame.selectAll:SetPoint("BOTTOMLEFT", 14, 10)

    frame.closeButton = Kit.Button(body, "Schliessen", "secondary", 100, function() frame:Hide() end)
    frame.closeButton:SetPoint("BOTTOMRIGHT", -14, 12)
end

function EHS:ShowExportFrame()
    if not frame then build() end

    local envelope = self:Rebuild()
    local items = 0
    for _, session in ipairs(envelope.sessions) do items = items + #session.items end

    if items == 0 then
        self:Print("Nichts zu exportieren - in den letzten "
            .. (self.db.settings.lookbackDays or 21) .. " Tagen wurde kein Loot vergeben.")
        self:Print("Weiter zurück schauen: /ehs days 60")
        return
    end

    frame.payload = self:EncodeJSON(envelope)
    frame.hint:SetText(("%d Raid-Session(s), %d Item(s). Mit Strg+A / Strg+C kopieren und im Admin-Menü unter %s einfügen.")
        :format(#envelope.sessions, items, self.Kit.Color("Historie & Loot -> Import", "gold")))
    frame.edit:SetText(frame.payload)
    frame:Show()
    frame.edit:SetFocus()
    frame.edit:HighlightText()
end
