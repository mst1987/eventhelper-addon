--[[
Der Bereich Einstellungen im Hauptfenster (MainWindow.lua).

Oben die drei Module zum An- und Ausschalten (wirken sofort, Modules.lua),
darunter ein Block pro Modul mit seinen Einstellungen und einer fuer alles
Allgemeine. Ein ausgeschaltetes Modul zeigt in seinem Block nur, dass es aus
ist. An/aus sind Schalter, Zahlen haben - und +.

Bis 1.15 standen diese Einstellungen als Haekchen unter der Raid-Tabelle.
]]

local EHS = EventHelperSync
local Kit = EHS.Kit

local page
local PAD = 16
local GAP = 12
local ROW = 44

local function settings() return EHS.db.settings end

local function refresh()
    EHS:RefreshMain()
    EHS:RefreshButton()
end

local function switchRow(card, index, width, name, hint, get, set)
    local switch = Kit.Switch(card, function(_, on)
        set(on)
        refresh()
    end)
    local label, note = Kit.SettingRow(card, -26 - 8 - (index - 1) * ROW, name, hint, switch, width)
    switch.refresh = function() switch:SetOn(get()) end
    return { control = switch, label = label, note = note }
end

local function stepperRow(card, index, width, name, hint, get, set, opts)
    local stepper = Kit.Stepper(card, get, set, opts)
    local label, note = Kit.SettingRow(card, -26 - 8 - (index - 1) * ROW, name, hint, stepper, width)
    return { control = stepper, label = label, note = note }
end

local function buttonRow(card, index, width, name, hint, text, onClick)
    local button = Kit.Button(card, text, "secondary", 96, onClick)
    local label, note = Kit.SettingRow(card, -26 - 8 - (index - 1) * ROW, name, hint, button, width)
    return { control = button, label = label, note = note }
end

--- Eine Karte fuer ein Modul: ist es aus, nur der Hinweis statt der Zeilen.
local function moduleCard(parent, title, module, width, rowCount)
    local card = Kit.Card(parent, title, width, 26 + 8 + rowCount * ROW)
    card.module = module
    card.rows = {}
    card.offNote = Kit.Text(card, "hint")
    card.offNote:SetPoint("TOPLEFT", 10, -38)
    card.offNote:SetWidth(width - 20)
    card.offNote:SetText("Modul ist aus. Einschalten oben unter Module.")
    card.offNote:Hide()
    return card
end

local function setCardState(card)
    local on = not card.module or EHS:ModuleOn(card.module)
    if card.module then
        -- Wie im Spiel steht nur da, was auffaellt: "aus". Ein laufendes Modul
        -- braucht kein Etikett.
        if on then
            card.pill:Hide()
        else
            card.pill:SetState("aus", "off")
            card.pill:Show()
        end
    end
    for _, row in ipairs(card.rows) do
        row.control:SetShown(on)
        row.label:SetShown(on)
        if row.note then row.note:SetShown(on) end
    end
    card.offNote:SetShown(not on)
end

local function onModuleSwitch(module, on)
    if not on then
        local others = 0
        for _, def in ipairs(EHS.MODULES) do
            if def.id ~= module and EHS:ModuleOn(def.id) then others = others + 1 end
        end
        if others == 0 then
            EHS:Print("Mindestens ein Modul muss an bleiben.")
            refresh()
            return
        end
    end
    EHS:SetModule(module, on)
end

local function build(holder)
    page = holder
    local width = EHS.MainLayout.pageWidth - 2 * PAD
    local half = math.floor((width - GAP) / 2)

    page.title = Kit.Text(page, "h2")
    page.title:SetPoint("TOPLEFT", PAD, -14)
    page.title:SetText("Einstellungen")
    page.lead = Kit.Text(page, "hint")
    page.lead:SetPoint("TOPLEFT", PAD, -42)
    page.lead:SetWidth(width)
    page.lead:SetText("Jedes Modul hat seinen eigenen Block. Was aus ist, verschwindet links aus der Leiste.")

    -- Module
    page.modules = Kit.Card(page, "Module", width, 26 + 52)
    page.modules:SetPoint("TOPLEFT", PAD, -62)
    page.modules.note = Kit.Text(page.modules, "hint")
    page.modules.note:SetPoint("LEFT", page.modules.title, "RIGHT", 10, 0)
    page.modules.note:SetText("wirken sofort, ohne /reload")
    page.moduleSwitches = {}
    local third = math.floor(width / #EHS.MODULES)
    for i, def in ipairs(EHS.MODULES) do
        local switch = Kit.Switch(page.modules, function(_, on) onModuleSwitch(def.id, on) end, def.text)
        switch:SetPoint("TOPLEFT", 10 + (i - 1) * third, -38)
        switch.module = def.id
        local name = Kit.Text(page.modules, "body")
        name:SetPoint("TOPLEFT", switch, "TOPRIGHT", 4, -5)
        name:SetText(def.name)
        local hint = Kit.Text(page.modules, "hint")
        hint:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -3)
        hint:SetWidth(third - 50)
        hint:SetText(def.short or "")
        switch.name = name
        page.moduleSwitches[#page.moduleSwitches + 1] = switch
    end

    local top = -62 - (26 + 52) - GAP

    -- Loot-Sync (links)
    page.loot = moduleCard(page, "Loot-Sync", "loot", half, 4)
    page.loot:SetPoint("TOPLEFT", PAD, top)
    page.loot.rows = {
        stepperRow(page.loot, 1, half, "Zeitraum", "wie weit zurück Loot gesucht wird",
            function() return settings().lookbackDays end,
            function(v) settings().lookbackDays = v end, { min = 1, max = 365, step = 7, unit = "Tage", onChange = refresh }),
        stepperRow(page.loot, 2, half, "Neuer Abend ab", "Pause zwischen zwei Vergaben",
            function() return settings().sessionGapHours end,
            function(v) settings().sessionGapHours = v end, { min = 1, max = 24, step = 1, unit = "Std.", onChange = refresh }),
        switchRow(page.loot, 3, half, "Bank- und Entzauber-Items weglassen", "",
            function() return settings().skipAwardReasons ~= false end,
            function(v) settings().skipAwardReasons = v end),
        switchRow(page.loot, 4, half, "Upload-Knopf anzeigen", "erscheint nur, wenn etwas offen ist",
            function() return settings().showButton end,
            function(v) settings().showButton = v end),
    }
    page.skipNote = page.loot.rows[3].note
    if not page.skipNote then
        page.skipNote = Kit.Text(page.loot, "hint")
        page.skipNote:SetPoint("TOPLEFT", page.loot.rows[3].label, "BOTTOMLEFT", 0, -3)
        page.skipNote:SetWidth(half - 80)
        page.loot.rows[3].note = page.skipNote
    end

    -- rechts: Gildenbank, Loot-Council, Allgemein
    local x = PAD + half + GAP
    page.bank = moduleCard(page, "Gildenbank", "guildbank", width - half - GAP, 2)
    page.bank:SetPoint("TOPLEFT", x, top)
    page.bank.rows = {
        switchRow(page.bank, 1, width - half - GAP, "Ausgabeliste automatisch öffnen", "an Bank und Briefkasten, wenn etwas offen ist",
            function() return settings().autoOpenHandouts ~= false end,
            function(v) settings().autoOpenHandouts = v end),
        switchRow(page.bank, 2, width - half - GAP, "Eigener Minimap-Knopf", "Truhe mit Zahl der offenen Posten",
            function() return settings().showBankMinimap ~= false end,
            function(v)
                settings().showBankMinimap = v
                if v and EHS.StartBankMinimap then EHS:StartBankMinimap() end
                if EHS.RefreshBankMinimap then EHS:RefreshBankMinimap() end
            end),
    }

    page.council = moduleCard(page, "Loot-Council", "council", width - half - GAP, 1)
    page.council:SetPoint("TOPLEFT", page.bank, "BOTTOMLEFT", 0, -GAP)
    page.council.rows = {
        switchRow(page.council, 1, width - half - GAP, "Vorschlag neben RCLootCouncil", "öffnet sich bei jeder Abstimmung",
            function() return settings().rclcSuggest ~= false end,
            function(v) settings().rclcSuggest = v end),
    }

    page.general = Kit.Card(page, "Allgemein", width - half - GAP, 26 + 8 + 2 * ROW)
    page.general:SetPoint("TOPLEFT", page.council, "BOTTOMLEFT", 0, -GAP)
    page.general.rows = {
        switchRow(page.general, 1, width - half - GAP, "Minimap-Knopf", "Linksklick Fenster, Rechtsklick Menü",
            function() return settings().showMinimap end,
            function(v)
                settings().showMinimap = v
                EHS:RefreshMinimap()
            end),
        buttonRow(page.general, 2, width - half - GAP, "Diagnose", "schreibt jede Stufe in den Chat",
            "Diagnose", function() EHS:Diagnose() end),
    }
end

local function refreshPage()
    if not page or not page:IsShown() then return end
    for _, switch in ipairs(page.moduleSwitches) do
        local on = EHS:ModuleOn(switch.module)
        switch:SetOn(on)
        if on then
            switch.name:SetTextColor(Kit.C.text[1], Kit.C.text[2], Kit.C.text[3])
        else
            switch.name:SetTextColor(Kit.C.mute[1], Kit.C.mute[2], Kit.C.mute[3])
        end
    end
    for _, card in ipairs({ page.loot, page.bank, page.council, page.general }) do
        if card.module then setCardState(card) end
        for _, row in ipairs(card.rows) do
            if row.control.refresh then row.control.refresh() end
        end
    end

    -- Wie viel der Schalter tatsaechlich wegnimmt: sonst bleibt er eine
    -- Behauptung, und niemand weiss, ob er greift.
    local stats = EHS.collectStats or {}
    local skipped = (stats.skippedRclc or 0) + (stats.skippedGargul or 0)
    if settings().skipAwardReasons == false then
        page.skipNote:SetText(Kit.Color("werden mit hochgeladen", "gold"))
    elseif skipped > 0 then
        page.skipNote:SetText(("zuletzt %d übersprungen (%d RCLootCouncil, %d Gargul)"):format(
            skipped, stats.skippedRclc or 0, stats.skippedGargul or 0))
    else
        page.skipNote:SetText("im Zeitraum war nichts dabei")
    end
end

EHS:RegisterPage({
    id = "settings", label = "Einstellungen", order = 90, bottom = true, frameName = "EventHelperSyncSettingsPage",
    icon = "Interface\\Icons\\Trade_Engineering",
    build = build, refresh = refreshPage,
    sub = function() return "Module, Knöpfe" end,
})
