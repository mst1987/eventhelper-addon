--[[
EventHelper Sync - Module.

Das Addon macht drei Dinge, die selten dieselbe Person braucht: Loot
hochladen (Loot-Verteiler, Raidleitung), den Loot-Council anzeigen (der
Council) und die Gildenbank verwalten (Bankverwalter). Wer nur eins davon
braucht, soll die anderen nicht sehen - keine Knöpfe, keine Tooltip-Zeilen,
kein Fenster, das am Briefkasten aufgeht.

Beim ersten Einloggen fragt deshalb ein kleines Fenster, welche Module an
sein sollen (EventHelperSyncDB.modules). Bis dahin ist alles an, so wie vor
dieser Frage - ein Update nimmt niemandem etwas weg. Später ändern: /ehs module
oder der Knopf "Module" im EventHelper-Fenster.

Umgeschaltet wird ohne /reload: jede Stelle, die zu einem Modul gehört, fragt
EHS:ModuleOn(id) in dem Moment, in dem sie etwas tun würde (Ereignis,
Tooltip, Klick). Haken, die einmal gesetzt sind, bleiben stehen und tun bei
ausgeschaltetem Modul nichts; eingeschaltet wird nachgeholt, was beim Login
übersprungen wurde (SetModule).
]]

local EHS = EventHelperSync

EHS.MODULES = {
    {
        id = "loot",
        name = "Loot-Sync",
        text = "Vergebenen Loot aus RCLootCouncil und Gargul sammeln und hochladen: Upload-Knopf, Raid-Abende im Fenster. Für Loot-Verteiler und Raidleitung.",
    },
    {
        id = "council",
        name = "Loot-Council",
        text = "Bedarf und erhaltener Loot je Raider: Fenster (/ehc), Zeilen im Item-Tooltip und Vorschlag neben RCLootCouncil. Für den Council.",
    },
    {
        id = "guildbank",
        name = "Gildenbank",
        text = "Gildenbank scannen, Ausgabeliste mit Post und Entnahme (/ehb), eigener Minimap-Knopf. Für die Bankverwaltung.",
    },
}

local BY_ID = {}
for _, module in ipairs(EHS.MODULES) do BY_ID[module.id] = module end

--- Ob ein Modul an ist. Vor der ersten Wahl (und vor ADDON_LOADED) ist alles an.
function EHS:ModuleOn(id)
    local modules = self.db and self.db.modules
    if type(modules) ~= "table" then return true end
    return modules[id] ~= false
end

--- Ob schon einmal gewählt wurde.
function EHS:ModulesChosen()
    return type(self.db and self.db.modules) == "table"
end

--- "Loot-Sync an, Loot-Council aus, Gildenbank an" für /ehs status.
function EHS:ModuleSummary()
    local parts = {}
    for _, module in ipairs(self.MODULES) do
        parts[#parts + 1] = module.name .. (self:ModuleOn(module.id) and " an" or " aus")
    end
    return table.concat(parts, ", ")
end

--- Sagt im Chat, dass ein Modul aus ist, und wie es wieder angeht.
-- @return false, damit Aufrufer `return self:ModuleOffNotice(id)` schreiben können
function EHS:ModuleOffNotice(id)
    local module = BY_ID[id]
    self:Print(("%s ist ausgeschaltet. Einschalten: /ehs module"):format(module and module.name or id))
    return false
end

--- Alles neu zeichnen, was von den Modulen abhängt.
function EHS:RefreshModuleViews()
    for _, refresh in ipairs({ "RefreshButton", "RefreshMinimap", "RefreshBankMinimap", "RefreshOptions" }) do
        if self[refresh] then
            local ok, err = pcall(self[refresh], self)
            if not ok then self:Debug(refresh .. ":", tostring(err)) end
        end
    end
end

--- Ein Modul an- oder ausschalten und gleich wirken lassen.
function EHS:SetModule(id, on)
    if not BY_ID[id] then return end
    self.db.modules = self.db.modules or {}
    for _, module in ipairs(self.MODULES) do
        if self.db.modules[module.id] == nil then self.db.modules[module.id] = true end
    end
    self.db.modules[id] = on and true or false

    if on then
        -- Was beim Login übersprungen wurde, jetzt nachholen.
        if id == "council" then
            if self.StartCouncil then pcall(self.StartCouncil, self) end
            if self.StartSuggest then pcall(self.StartSuggest, self) end
        elseif id == "guildbank" and self.StartBankMinimap then
            pcall(self.StartBankMinimap, self)
        end
    else
        -- Offene Fenster des Moduls schliessen.
        local frames = {
            council = { "EventHelperSyncCouncilFrame" },
            guildbank = { "EventHelperSyncGuildBankFrame" },
        }
        for _, name in ipairs(frames[id] or {}) do
            local f = _G[name]
            if f and f.Hide then f:Hide() end
        end
        if id == "council" and self.HideSuggest then pcall(self.HideSuggest, self) end
    end
    self:RefreshModuleViews()
end

-- ---------------------------------------------------------------------------
-- Das Fenster
-- ---------------------------------------------------------------------------

local WIDTH = 480
local ROW_HEIGHT = 74
local chooser

--- Ein Schalter statt eines Häkchens: grün mit Knopf rechts = an.
local function buildSwitch(parent)
    local switch = CreateFrame("Button", nil, parent)
    switch:SetSize(44, 22)
    switch.track = switch:CreateTexture(nil, "BACKGROUND")
    switch.track:SetAllPoints()
    switch.knob = switch:CreateTexture(nil, "ARTWORK")
    switch.knob:SetSize(18, 18)
    switch.knob:SetColorTexture(1, 1, 1, 1)
    switch.state = switch:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    switch.state:SetPoint("TOP", switch, "BOTTOM", 0, -3)
    function switch:SetOn(on)
        self.on = on and true or false
        if self.on then
            self.track:SetColorTexture(0.27, 0.73, 0.33, 1)
            self.knob:ClearAllPoints()
            self.knob:SetPoint("RIGHT", self, "RIGHT", -2, 0)
            self.state:SetText("An")
        else
            self.track:SetColorTexture(0.35, 0.35, 0.38, 1)
            self.knob:ClearAllPoints()
            self.knob:SetPoint("LEFT", self, "LEFT", 2, 0)
            self.state:SetText("Aus")
        end
    end
    return switch
end

local function updateApply()
    local any = false
    for _, row in ipairs(chooser.rows) do
        if row.switch.on then any = true end
    end
    -- Ganz ohne Modul bliebe nur ein Minimap-Knopf, der nichts tut.
    chooser.hint:SetText(any and "" or "|cffffd200Mindestens ein Modul einschalten.|r")
    chooser.apply:SetEnabled(any)
end

local function build()
    chooser = CreateFrame("Frame", "EventHelperSyncModulesFrame", UIParent, "BasicFrameTemplateWithInset")
    chooser:SetSize(WIDTH, 136 + #EHS.MODULES * ROW_HEIGHT)
    chooser:SetPoint("CENTER", 0, 80)
    chooser:SetFrameStrata("DIALOG")
    chooser:SetMovable(true)
    chooser:EnableMouse(true)
    chooser:RegisterForDrag("LeftButton")
    chooser:SetScript("OnDragStart", chooser.StartMoving)
    chooser:SetScript("OnDragStop", chooser.StopMovingOrSizing)
    chooser:SetClampedToScreen(true)

    chooser.title = chooser:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    chooser.title:SetPoint("TOP", 0, -6)
    chooser.title:SetText("EventHelper Sync - Module")

    chooser.intro = chooser:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    chooser.intro:SetPoint("TOPLEFT", 20, -36)
    chooser.intro:SetWidth(WIDTH - 40)
    chooser.intro:SetJustifyH("LEFT")
    chooser.intro:SetText("Welche Teile brauchst du? Was aus ist, siehst du im Spiel nicht.")

    chooser.rows = {}
    for i, module in ipairs(EHS.MODULES) do
        local row = CreateFrame("Button", nil, chooser)
        row:SetSize(WIDTH - 40, ROW_HEIGHT - 8)
        row:SetPoint("TOPLEFT", 20, -64 - (i - 1) * ROW_HEIGHT)
        row.module = module

        row.switch = buildSwitch(row)
        row.switch:SetPoint("TOPLEFT", 0, -4)

        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        row.name:SetPoint("TOPLEFT", 60, -2)
        row.name:SetText(module.name)

        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetPoint("TOPLEFT", 60, -24)
        row.text:SetWidth(WIDTH - 110)
        row.text:SetJustifyH("LEFT")
        row.text:SetText(module.text)

        -- Die ganze Zeile schaltet um, nicht nur der kleine Schalter.
        local function toggle()
            row.switch:SetOn(not row.switch.on)
            updateApply()
        end
        row:SetScript("OnClick", toggle)
        row.switch:SetScript("OnClick", toggle)
        chooser.rows[i] = row
    end

    chooser.hint = chooser:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    chooser.hint:SetPoint("BOTTOMLEFT", 20, 46)

    chooser.foot = chooser:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    chooser.foot:SetPoint("BOTTOMLEFT", 20, 20)
    chooser.foot:SetWidth(WIDTH - 250)
    chooser.foot:SetJustifyH("LEFT")
    chooser.foot:SetText("Später ändern: /ehs module")

    chooser.apply = CreateFrame("Button", nil, chooser, "UIPanelButtonTemplate")
    chooser.apply:SetSize(120, 26)
    chooser.apply:SetPoint("BOTTOMRIGHT", -16, 14)
    chooser.apply:SetText("Übernehmen")
    chooser.apply:SetScript("OnClick", function()
        for _, row in ipairs(chooser.rows) do EHS:SetModule(row.module.id, row.switch.on) end
        chooser:Hide()
        EHS:Print("Module: " .. EHS:ModuleSummary() .. ".")
    end)

    -- "Später": nichts speichern, beim nächsten Login wird wieder gefragt.
    chooser.later = CreateFrame("Button", nil, chooser, "UIPanelButtonTemplate")
    chooser.later:SetSize(90, 26)
    chooser.later:SetPoint("RIGHT", chooser.apply, "LEFT", -8, 0)
    chooser.later:SetText("Später")
    chooser.later:SetScript("OnClick", function() chooser:Hide() end)

    tinsert(UISpecialFrames, "EventHelperSyncModulesFrame")
    chooser:Hide()
end

--- Das Fenster öffnen, mit dem aktuellen Stand vorbelegt.
function EHS:ShowModuleChooser()
    if not chooser then build() end
    for _, row in ipairs(chooser.rows) do row.switch:SetOn(self:ModuleOn(row.module.id)) end
    updateApply()
    chooser:Show()
end

--- Beim Login: einmal fragen, solange noch nicht gewählt wurde.
function EHS:AskModulesOnce()
    if self:ModulesChosen() then return end
    local function ask()
        if InCombatLockdown() then return end
        self:ShowModuleChooser()
    end
    -- Nicht mitten in den Ladebildschirm hinein.
    if C_Timer and C_Timer.After then
        C_Timer.After(4, ask)
    else
        ask()
    end
end
