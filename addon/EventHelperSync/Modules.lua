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
        short = "Loot hochladen, Raid-Abende",
    },
    {
        id = "council",
        name = "Loot-Council",
        text = "Bedarf und erhaltener Loot je Raider: Bereich im Fenster (/ehc), Zeilen im Item-Tooltip und Vorschlag neben RCLootCouncil. Für den Council.",
        short = "Bedarf, Tooltip, Vorschlag",
    },
    {
        id = "guildbank",
        name = "Gildenbank",
        text = "Gildenbank scannen, Ausgabeliste mit Post und Entnahme (/ehb), eigener Minimap-Knopf. Für die Bankverwaltung.",
        short = "Scan, Ausgabe, Post",
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
    elseif id == "council" and self.HideSuggest then
        pcall(self.HideSuggest, self)
    end
    -- Zeigt das Hauptfenster gerade den Bereich des ausgeschalteten Moduls,
    -- wechselt es dabei auf einen anderen (MainWindow.lua, RefreshMain).
    self:RefreshModuleViews()
end

-- ---------------------------------------------------------------------------
-- Das Fenster
-- ---------------------------------------------------------------------------

local WIDTH = 480
local ROW_HEIGHT = 70
local chooser

local function updateApply()
    local any = false
    for _, row in ipairs(chooser.rows) do
        if row.switch.on then any = true end
    end
    -- Ganz ohne Modul bliebe nur ein Minimap-Knopf, der nichts tut.
    chooser.hint:SetText(any and "" or EHS.Kit.Color("Mindestens ein Modul einschalten.", "gold"))
    chooser.apply:SetActive(any)
end

local function build()
    local Kit = EHS.Kit
    chooser = Kit.Window({
        name = "EventHelperSyncModulesFrame", title = "EventHelper Sync - Module",
        width = WIDTH, height = Kit.TITLE_HEIGHT + 112 + #EHS.MODULES * ROW_HEIGHT,
        strata = "DIALOG", point = { "CENTER", 0, 80 },
    })
    local body = chooser.body

    chooser.intro = Kit.Text(body, "label")
    chooser.intro:SetPoint("TOPLEFT", 20, -16)
    chooser.intro:SetWidth(WIDTH - 40)
    chooser.intro:SetText("Welche Teile brauchst du? Was aus ist, siehst du im Spiel nicht.")

    chooser.rows = {}
    for i, module in ipairs(EHS.MODULES) do
        local row = CreateFrame("Button", nil, body)
        row:SetSize(WIDTH - 40, ROW_HEIGHT - 8)
        row:SetPoint("TOPLEFT", 20, -44 - (i - 1) * ROW_HEIGHT)
        row.module = module
        Kit.Solid(row, "BACKGROUND", Kit.C.panel2):SetAllPoints()
        Kit.Border(row, Kit.C.line)
        local hl = Kit.Solid(row, "HIGHLIGHT", { 1, 1, 1 }, 0.04)
        hl:SetAllPoints()

        -- Die ganze Zeile schaltet um, nicht nur der kleine Schalter.
        local function toggle()
            row.switch:SetOn(not row.switch.on)
            updateApply()
        end
        row.switch = Kit.Switch(row, function() updateApply() end)
        row.switch:SetPoint("TOPLEFT", 12, -12)
        -- "An" / "Aus" unter dem Schalter, damit es auch ohne Farbe lesbar ist.
        row.switch.state = Kit.Text(row, "small", "CENTER")
        row.switch.state:SetPoint("TOP", row.switch, "BOTTOM", 0, -4)
        local setOn = row.switch.SetOn
        function row.switch:SetOn(on)
            setOn(self, on)
            self.state:SetText(self.on and "An" or "Aus")
        end

        row.name = Kit.Text(row, "title")
        row.name:SetPoint("TOPLEFT", 66, -10)
        row.name:SetText(module.name)

        row.text = Kit.Text(row, "hint")
        row.text:SetPoint("TOPLEFT", 66, -30)
        row.text:SetWidth(WIDTH - 120)
        row.text:SetText(module.text)

        row:SetScript("OnClick", toggle)
        chooser.rows[i] = row
    end

    chooser.hint = Kit.Text(body, "labelSmall")
    chooser.hint:SetPoint("BOTTOMLEFT", 20, 46)

    chooser.foot = Kit.Text(body, "hint")
    chooser.foot:SetPoint("BOTTOMLEFT", 20, 20)
    chooser.foot:SetWidth(WIDTH - 260)
    chooser.foot:SetText("Später ändern: /ehs module oder Einstellungen")

    chooser.apply = Kit.Button(body, "Übernehmen", "primary", 120, function()
        for _, row in ipairs(chooser.rows) do EHS:SetModule(row.module.id, row.switch.on) end
        chooser:Hide()
        EHS:Print("Module: " .. EHS:ModuleSummary() .. ".")
    end)
    chooser.apply:SetPoint("BOTTOMRIGHT", -16, 14)

    -- "Später": nichts speichern, beim nächsten Login wird wieder gefragt.
    chooser.later = Kit.Button(body, "Später", "secondary", 90, function() chooser:Hide() end)
    chooser.later:SetPoint("RIGHT", chooser.apply, "LEFT", -8, 0)
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
