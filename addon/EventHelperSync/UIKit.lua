--[[
EventHelper Sync - die Bausteine aller Fenster.

Bis 1.15 gab es zwei Fensterarten (Blizzard-Vorlage und flaches Panel), drei
Arten von Haekchen/Schaltern, Knoepfe in vier Hoehen und je drei Toene fuer
Gruen, Rot und Gold. Ab 1.16 baut jedes Fenster aus diesen Teilen, damit alles
gleich aussieht und sich gleich bedient (Entwurf "A Seitenleiste", Okt 2026):

  * Window      Rahmen mit Titelleiste, X, Esc, gemerkter Position
  * Button      "primary" (eine Haupthandlung pro Bereich), "secondary", "link"
  * Switch      an/aus - statt Haekchen
  * Chip        Auswahl in einem Filter (Alle | Caster | ...)
  * Stepper     Zahl mit - / +
  * Dropdown    eine aus vielen (MenuUtil, sonst weiterschalten)
  * Pill, Badge Zustand und Zahl
  * Header      Spaltenkopf einer Liste
  * Thumb       Bildlaufanzeige mit Spur
  * Card        ein Block mit Kopfzeile (Einstellungen)

  * Inset       vertiefte Flaeche (Seitenleiste, Karten)
  * InfoButton  ein goldenes "?" mit Erklaerung im Tooltip

Ab 1.17 sehen die Bausteine aus wie das Spiel selbst: Fenster, Knoepfe, X,
Haekchen, Auswahl und vertiefte Flaechen kommen aus den Vorlagen des Clients
(ButtonFrameTemplate, UIPanelButtonTemplate, UIPanelCloseButton,
UICheckButtonTemplate, WowStyle1DropdownTemplate, InsetFrameTemplate). Beide
Clients (TBC Anniversary 20506, WoW Forever 16001) kennen sie - belegt an
Fremd-Addons im Spielordner (Baganator, Auctionator). Trotzdem wird jede
Vorlage erst geprueft (fromTemplate: C_XMLUtil.GetTemplateInfo, pcall um
CreateFrame, Pruefung der erwarteten Teile); fehlt sie, baut der Baukasten den
alten flachen Baustein mit derselben Schnittstelle. `x.native` sagt, welcher
es geworden ist.

Auch Schalter (Haekchen links, Text rechts, wie in den Optionen), Chips (der
kleine rote Knopf, gewaehlt = festes Leuchten) und Zahlen (der Regler mit
Pfeilen, MinimalSliderWithSteppersTemplate, sonst OptionsSliderTemplate) sind
die des Spiels; Etiketten und Zaehler sind schlichter Text in den Farben des
Spiels. Selbst gezeichnet bleiben nur Spaltenkopf, Bildlaufanzeige,
Zeilenstreifen und der "link"-Knopf: dafuer hat das Spiel keine Vorlage, die
beide Clients gleich haben.
]]

local EHS = EventHelperSync

local Kit = {}
EHS.Kit = Kit

-- Die Farben, einmal. r, g, b (0-1).
Kit.C = {
    gold = { 1, 0.82, 0 },
    goldDim = { 0.79, 0.64, 0.15 },
    border = { 0.55, 0.45, 0.25 },
    borderDim = { 0.35, 0.29, 0.16 },
    line = { 0.23, 0.2, 0.15 },
    panel = { 0.047, 0.047, 0.055 },
    panel2 = { 0.075, 0.067, 0.055 },
    bar = { 0.13, 0.11, 0.08 },
    field = { 0.11, 0.1, 0.08 },
    text = { 0.91, 0.89, 0.82 },
    mute = { 0.55, 0.53, 0.48 },
    green = { 0.31, 0.83, 0.31 },
    red = { 0.88, 0.35, 0.31 },
    primary = { 0.40, 0.09, 0.06 },
    primaryHover = { 0.52, 0.12, 0.08 },
    switchOn = { 0.18, 0.35, 0.16 },
    switchOff = { 0.16, 0.15, 0.13 },
}

-- Die EventHelper-Marke (Kalender mit Haken), dieselbe wie auf der Webseite
-- und im Sync-Tool. Erzeugt aus sync/assets/icon.svg (npm run build:icon);
-- die runde Fassung ist fuer den Minimap-Knopf.
Kit.LOGO = "Interface\\AddOns\\EventHelperSync\\media\\logo"
Kit.LOGO_ROUND = "Interface\\AddOns\\EventHelperSync\\media\\logo-round"

-- Dieselben Farben als Hex fuer |cff...|r im Text.
Kit.HEX = { gold = "ffd100", green = "4fd34f", red = "e05a4f", mute = "8d877a", text = "e9e3d2" }

--- Text in einer der Palettenfarben: Kit.Color("12 offen", "gold").
function Kit.Color(text, key)
    return "|cff" .. (Kit.HEX[key] or Kit.HEX.text) .. tostring(text) .. "|r"
end

-- Schriften nach Rolle. Eine Schrift, die der Client nicht kennt, faellt auf
-- die naechstkleinere zurueck (GameFontNormalHuge gibt es nicht ueberall).
local FONTS = {
    h2 = { "GameFontNormalHuge", "GameFontNormalLarge" },
    title = { "GameFontNormalLarge", "GameFontNormal" },
    big = { "GameFontHighlightLarge", "GameFontHighlight" },
    label = { "GameFontNormal" },
    body = { "GameFontHighlight" },
    small = { "GameFontHighlightSmall" },
    labelSmall = { "GameFontNormalSmall" },
    hint = { "GameFontDisableSmall" },
    empty = { "GameFontDisable" },
}

local function fontFor(role)
    local list = FONTS[role] or FONTS.body
    for _, name in ipairs(list) do
        if _G[name] then return name end
    end
    return list[#list]
end
Kit.FontFor = fontFor

--- Eine Textzeile in einer Rolle (h2, title, big, label, body, small, labelSmall, hint, empty).
function Kit.Text(parent, role, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY", fontFor(role))
    fs:SetJustifyH(justify or "LEFT")
    if fs.SetWordWrap and role ~= "hint" and role ~= "empty" then fs:SetWordWrap(false) end
    return fs
end

--- Eine einfarbige Flaeche.
function Kit.Solid(parent, layer, color, alpha)
    local tex = parent:CreateTexture(nil, layer or "BACKGROUND")
    tex:SetColorTexture(color[1], color[2], color[3], alpha or 1)
    return tex
end

--- Ein 1-px-Rahmen aus vier Texturen um `frame` (oder um `anchor`).
function Kit.Border(frame, color, anchor, layer)
    anchor = anchor or frame
    local edges = {
        { "TOPLEFT", "TOPRIGHT", nil, 1 }, { "BOTTOMLEFT", "BOTTOMRIGHT", nil, 1 },
        { "TOPLEFT", "BOTTOMLEFT", 1, nil }, { "TOPRIGHT", "BOTTOMRIGHT", 1, nil },
    }
    local lines = {}
    for _, e in ipairs(edges) do
        local line = Kit.Solid(frame, layer or "BORDER", color or Kit.C.border)
        line:SetPoint(e[1], anchor, e[1], 0, 0)
        line:SetPoint(e[2], anchor, e[2], 0, 0)
        if e[3] then line:SetWidth(e[3]) end
        if e[4] then line:SetHeight(e[4]) end
        lines[#lines + 1] = line
    end
    return lines
end

--- Eine waagerechte Trennlinie unter `y` in `parent`.
function Kit.Divider(parent, y, color, inset)
    local line = Kit.Solid(parent, "ARTWORK", color or Kit.C.line)
    line:SetPoint("TOPLEFT", inset or 0, y)
    line:SetPoint("TOPRIGHT", -(inset or 0), y)
    line:SetHeight(1)
    return line
end

--- Einen Frame aus einer Vorlage des Clients bauen - oder nil, wenn der
-- Client sie nicht kennt oder ihr ein erwartetes Teil fehlt (`check(frame)`
-- sagt es). Der Aufrufer baut dann den eigenen Baustein. Eine unbekannte
-- Vorlage wirft in CreateFrame; C_XMLUtil.GetTemplateInfo fragt vorher (gibt
-- es auf beiden Clients), pcall faengt den Rest.
local function fromTemplate(kind, name, parent, template, check)
    if C_XMLUtil and C_XMLUtil.GetTemplateInfo then
        local ok, info = pcall(C_XMLUtil.GetTemplateInfo, template)
        if ok and not info then return nil end
    end
    local ok, frame = pcall(CreateFrame, kind, name, parent, template)
    if not ok or not frame then return nil end
    if check then
        local fine, result = pcall(check, frame)
        if not fine or not result then
            pcall(frame.Hide, frame)
            return nil
        end
    end
    frame.fromTemplate = template
    return frame
end
Kit.FromTemplate = fromTemplate

--- Tooltip beim Darueberfahren: `tooltip` ist ein Text (weiss, umbrechend)
-- oder function(frame), die selbst Zeilen anfuegt; `title` (optional) steht
-- in Gold darueber. Ein eigenes OnEnter des Frames bleibt (eingehakt statt
-- ersetzt); ein zweiter Aufruf aendert nur den Text.
local function tooltipFor(frame, tooltip, title)
    if not tooltip and not title then return end
    frame.ehsTooltip, frame.ehsTooltipTitle = tooltip, title
    if frame.ehsTooltipHooked then return end
    frame.ehsTooltipHooked = true
    local function install(script, fn)
        if frame.GetScript and frame:GetScript(script) and frame.HookScript then
            frame:HookScript(script, fn)
        else
            frame:SetScript(script, fn)
        end
    end
    install("OnEnter", function(self)
        if not GameTooltip then return end
        local text, head = self.ehsTooltip, self.ehsTooltipTitle
        pcall(function()
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            if head and head ~= "" then
                GameTooltip:AddLine(head, Kit.C.gold[1], Kit.C.gold[2], Kit.C.gold[3])
            end
            if type(text) == "function" then
                text(self)
            elseif text then
                GameTooltip:AddLine(text, 1, 1, 1, true)
            end
            GameTooltip:Show()
        end)
    end)
    install("OnLeave", function()
        if GameTooltip then pcall(GameTooltip.Hide, GameTooltip) end
    end)
end
Kit.Tooltip = tooltipFor

--- Ein kleines goldenes "?", das im Tooltip erklaert (Titel in Gold, Text weiss).
function Kit.InfoButton(parent, title, text)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(16, 16)
    button.label = Kit.Text(button, "label", "CENTER")
    button.label:SetPoint("CENTER", 0, 0)
    button.label:SetText("?")
    local hl = Kit.Solid(button, "HIGHLIGHT", { 1, 1, 1 }, 0.12)
    hl:SetAllPoints()
    tooltipFor(button, text, title)
    return button
end

--- Eine vertiefte Flaeche (InsetFrameTemplate wie in den Fenstern des Spiels),
-- sonst dunkel mit Rahmen.
function Kit.Inset(parent)
    local inset = fromTemplate("Frame", nil, parent, "InsetFrameTemplate", function(f) return f.SetWidth end)
    if inset then
        inset.native = true
        return inset
    end
    inset = CreateFrame("Frame", nil, parent)
    inset.native = false
    inset.bg = Kit.Solid(inset, "BACKGROUND", { 0.06, 0.055, 0.047 })
    inset.bg:SetAllPoints()
    inset.edges = Kit.Border(inset, Kit.C.line)
    return inset
end

-- Schriftobjekt eines Zustands setzen, wenn der Knopf es kann.
local function setFontObjects(button, normal, highlight, disabled)
    for method, font in pairs({ SetNormalFontObject = normal, SetHighlightFontObject = highlight,
        SetDisabledFontObject = disabled }) do
        if button[method] and font and _G[font] then pcall(button[method], button, font) end
    end
end

-- ---------------------------------------------------------------------------
-- Knoepfe
-- ---------------------------------------------------------------------------

local BUTTON_HEIGHT = { primary = 28, secondary = 24, link = 18 }

--- Ein Knopf. kind: "primary" | "secondary" | "link".
-- Gesperrt (button:SetActive(false)) wird er blass und nimmt keine Klicks an;
-- `button.active` sagt es (auch fuer die Specs). "primary" und "secondary"
-- sind der rote Knopf des Spiels (UIPanelButtonTemplate, "secondary" mit
-- kleinerer Schrift); "link" bleibt ein unterstrichener Text.
local function nativeButton(parent, label, kind, width)
    local button = fromTemplate("Button", nil, parent, "UIPanelButtonTemplate", function(b)
        return b.SetText and b.GetFontString
    end)
    if not button then return nil end
    button:SetSize(width or 120, BUTTON_HEIGHT[kind] or 24)
    if kind == "secondary" then
        setFontObjects(button, "GameFontNormalSmall", "GameFontHighlightSmall", "GameFontDisableSmall")
    end
    button:SetText(label or "")
    button.label = button:GetFontString() or button.Text
    if not button.label then
        pcall(button.Hide, button)
        return nil
    end
    button.native = true
    return button
end

function Kit.Button(parent, label, kind, width, onClick, tooltip)
    kind = kind or "secondary"
    local button = kind ~= "link" and nativeButton(parent, label, kind, width)
    if button then
        button.kind = kind
        button.active = true
        function button:SetLabel(text) self:SetText(text or "") end
        function button:SetActive(on)
            self.active = on and true or false
            self:SetEnabled(self.active)
        end
        if onClick then
            button:SetScript("OnClick", function(self, mouse)
                if self.active then onClick(self, mouse) end
            end)
        end
        tooltipFor(button, tooltip)
        return button
    end

    button = CreateFrame("Button", nil, parent)
    button.native = false
    button.kind = kind
    button:SetSize(width or 120, BUTTON_HEIGHT[kind] or 24)

    if kind == "primary" then
        button.bg = Kit.Solid(button, "BACKGROUND", Kit.C.primary)
        button.bg:SetAllPoints()
        button.shine = Kit.Solid(button, "ARTWORK", { 1, 0.86, 0.6 }, 0.18)
        button.shine:SetPoint("TOPLEFT", 1, -1)
        button.shine:SetPoint("TOPRIGHT", -1, -1)
        button.shine:SetHeight(1)
        Kit.Border(button, Kit.C.goldDim)
        button.label = Kit.Text(button, "label", "CENTER")
        local hl = Kit.Solid(button, "HIGHLIGHT", Kit.C.primaryHover, 0.6)
        hl:SetAllPoints()
    elseif kind == "link" then
        button.label = Kit.Text(button, "labelSmall", "CENTER")
        local underline = Kit.Solid(button, "ARTWORK", Kit.C.goldDim, 0.8)
        underline:SetPoint("BOTTOMLEFT", button.label, "BOTTOMLEFT", 0, -2)
        underline:SetPoint("BOTTOMRIGHT", button.label, "BOTTOMRIGHT", 0, -2)
        underline:SetHeight(1)
    else
        button.bg = Kit.Solid(button, "BACKGROUND", Kit.C.field)
        button.bg:SetAllPoints()
        Kit.Border(button, Kit.C.borderDim)
        button.label = Kit.Text(button, "small", "CENTER")
        local hl = Kit.Solid(button, "HIGHLIGHT", { 1, 1, 1 }, 0.08)
        hl:SetAllPoints()
    end
    button.label:SetPoint("CENTER", 0, 0)
    button.label:SetText(label or "")
    button.active = true

    function button:SetLabel(text) self.label:SetText(text or "") end
    function button:SetActive(on)
        self.active = on and true or false
        self:SetEnabled(self.active)
        self:SetAlpha(self.active and 1 or 0.45)
    end

    if onClick then
        button:SetScript("OnClick", function(self, mouse)
            if self.active then onClick(self, mouse) end
        end)
    end
    tooltipFor(button, tooltip)
    return button
end

--- Das X oben rechts in jeder Titelleiste: das X des Spiels (UIPanelCloseButton); sonst ein flaches "x". OnClick wird
-- immer gesetzt (die Vorlage schliesst sonst nur den Elternrahmen).
function Kit.CloseButton(parent, onClick)
    local native = fromTemplate("Button", nil, parent, "UIPanelCloseButton")
    if native then
        native.native = true
        native:SetSize(24, 24)
        native:SetScript("OnClick", onClick)
        return native
    end
    local button = CreateFrame("Button", nil, parent)
    button.native = false
    button:SetSize(22, 22)
    button.bg = Kit.Solid(button, "BACKGROUND", Kit.C.field)
    button.bg:SetAllPoints()
    Kit.Border(button, Kit.C.borderDim)
    button.label = Kit.Text(button, "labelSmall", "CENTER")
    button.label:SetPoint("CENTER", 0, 0)
    button.label:SetText("x")
    local hl = Kit.Solid(button, "HIGHLIGHT", { 1, 1, 1 }, 0.1)
    hl:SetAllPoints()
    button:SetScript("OnClick", onClick)
    tooltipFor(button, "Schliessen (Esc)")
    return button
end

-- ---------------------------------------------------------------------------
-- Schalter, Chips, Zahl, Auswahl
-- ---------------------------------------------------------------------------

--- An/aus. onToggle(switch, on) nach jedem Klick; switch:SetOn(on) ohne Rueckruf.
-- Wo es geht, ist es das Haekchen des Spiels (UICheckButtonTemplate) wie in
-- den Optionen des Spiels: Haekchen links, der Text steht daneben (Kit.SettingRow).
-- Die Vorlage schaltet sich beim Klick selbst um; hier gilt aber switch.on,
-- darum setzt PostClick das Haekchen wieder auf ihn. Ohne Vorlage ein flacher
-- Schieber. switch.kind == "switch" sagt Kit.SettingRow, wohin er gehoert.
local function nativeSwitch(parent)
    local switch = fromTemplate("CheckButton", nil, parent, "UICheckButtonTemplate", function(c)
        return c.SetChecked and c.GetChecked
    end)
    if not switch then return nil end
    switch.native = true
    switch:SetSize(26, 26)
    -- Die Vorlage bringt eine eigene Beschriftung mit; der Text steht bei uns daneben.
    local own = switch.Text or switch.text
    if own and own.SetText then own:SetText("") end
    local setNative = switch.SetChecked
    function switch:SetOn(on)
        self.on = on and true or false
        setNative(self, self.on)
    end
    function switch:SetActive(on)
        self.active = on and true or false
        self:SetEnabled(self.active)
    end
    switch:HookScript("PostClick", function(self) setNative(self, self.on) end)
    return switch
end

local function flatSwitch(parent)
    local switch = CreateFrame("Button", nil, parent)
    switch.native = false
    switch:SetSize(40, 20)
    switch.track = Kit.Solid(switch, "BACKGROUND", Kit.C.switchOff)
    switch.track:SetAllPoints()
    switch.edges = Kit.Border(switch, Kit.C.borderDim)
    switch.knob = Kit.Solid(switch, "ARTWORK", { 1, 1, 1 })
    switch.knob:SetSize(14, 14)
    function switch:SetOn(on)
        self.on = on and true or false
        local track = self.on and Kit.C.switchOn or Kit.C.switchOff
        self.track:SetColorTexture(track[1], track[2], track[3], 1)
        local edge = self.on and Kit.C.green or Kit.C.borderDim
        for _, line in ipairs(self.edges) do line:SetColorTexture(edge[1], edge[2], edge[3], self.on and 0.7 or 1) end
        self.knob:ClearAllPoints()
        if self.on then
            self.knob:SetPoint("RIGHT", self, "RIGHT", -3, 0)
            self.knob:SetColorTexture(1, 1, 1, 1)
        else
            self.knob:SetPoint("LEFT", self, "LEFT", 3, 0)
            self.knob:SetColorTexture(0.8, 0.78, 0.71, 1)
        end
    end
    function switch:SetActive(on)
        self.active = on and true or false
        self:SetEnabled(self.active)
        self:SetAlpha(self.active and 1 or 0.4)
    end
    return switch
end

function Kit.Switch(parent, onToggle, tooltip)
    local switch = nativeSwitch(parent) or flatSwitch(parent)
    switch.kind = "switch"
    switch.active = true
    switch:SetScript("OnClick", function(self)
        if not self.active then return end
        self:SetOn(not self.on)
        if onToggle then onToggle(self, self.on) end
    end)
    tooltipFor(switch, tooltip)
    switch:SetOn(false)
    return switch
end

--- Eine Auswahl in einem Filter. chip:SetSelected(on).
-- Wo es geht, der kleine rote Knopf des Spiels (UIPanelButtonTemplate); die
-- Auswahl haelt sein Leuchten fest (LockHighlight), wie bei den Filtern des
-- Spiels. Sonst ein flacher Knopf mit Goldrand.
local function nativeChip(parent, label)
    local chip = fromTemplate("Button", nil, parent, "UIPanelButtonTemplate", function(b)
        return b.SetText and b.GetFontString and b.LockHighlight and b.UnlockHighlight
    end)
    if not chip then return nil end
    setFontObjects(chip, "GameFontNormalSmall", "GameFontHighlightSmall", "GameFontDisableSmall")
    chip:SetText(label or "")
    chip.label = chip:GetFontString() or chip.Text
    if not chip.label then
        pcall(chip.Hide, chip)
        return nil
    end
    local ok, width = pcall(chip.label.GetStringWidth, chip.label)
    chip:SetSize(math.max(40, (ok and tonumber(width) or #(label or "") * 6) + 24), 22)
    chip.native = true
    function chip:SetSelected(on)
        self.selected = on and true or false
        if self.selected then self:LockHighlight() else self:UnlockHighlight() end
    end
    return chip
end

local function flatChip(parent, label)
    local chip = CreateFrame("Button", nil, parent)
    chip.native = false
    chip.label = Kit.Text(chip, "small", "CENTER")
    chip.label:SetPoint("CENTER", 0, 0)
    chip.label:SetText(label)
    local ok, width = pcall(chip.label.GetStringWidth, chip.label)
    chip:SetSize(math.max(36, (ok and tonumber(width) or #label * 6) + 24), 22)
    chip.bg = Kit.Solid(chip, "BACKGROUND", Kit.C.field)
    chip.bg:SetAllPoints()
    chip.edges = Kit.Border(chip, Kit.C.line)
    local hl = Kit.Solid(chip, "HIGHLIGHT", { 1, 1, 1 }, 0.06)
    hl:SetAllPoints()
    function chip:SetSelected(on)
        self.selected = on and true or false
        local edge = self.selected and Kit.C.border or Kit.C.line
        for _, line in ipairs(self.edges) do line:SetColorTexture(edge[1], edge[2], edge[3], 1) end
        if self.selected then
            self.bg:SetColorTexture(0.165, 0.137, 0.078, 1)
            self.label:SetTextColor(Kit.C.gold[1], Kit.C.gold[2], Kit.C.gold[3])
        else
            self.bg:SetColorTexture(Kit.C.field[1], Kit.C.field[2], Kit.C.field[3], 1)
            self.label:SetTextColor(0.72, 0.69, 0.63)
        end
    end
    return chip
end

function Kit.Chip(parent, label, onClick, tooltip)
    local chip = nativeChip(parent, label) or flatChip(parent, label)
    chip:SetScript("OnClick", function(self, mouse) if onClick then onClick(self, mouse) end end)
    tooltipFor(chip, tooltip)
    chip:SetSelected(false)
    return chip
end

--- Eine Reihe Chips nebeneinander ab (x, y) in `parent`; gibt die Chips zurueck.
function Kit.ChipRow(parent, defs, x, y, gap)
    local chips = {}
    local anchor
    for _, def in ipairs(defs) do
        local chip = Kit.Chip(parent, def.label, def.onClick, def.tooltip)
        chip.value = def.value
        if anchor then
            chip:SetPoint("LEFT", anchor, "RIGHT", gap or 4, 0)
        else
            chip:SetPoint("TOPLEFT", x, y)
        end
        chips[#chips + 1] = chip
        anchor = chip
    end
    return chips
end

--- Eine Zahl mit - und +. get() -> Zahl, set(n); opts { min, max, step, unit, onChange }.
-- holder.refresh() zeichnet neu, holder.value ist die Zahl mit Einheit,
-- holder.minus / holder.plus die Knoepfe (ein Klick = opts.step).
--
-- Mit min und max ist es der Regler des Spiels: erst der aus den neuen Optionen
-- (MinimalSliderWithSteppersTemplate, Pfeile links und rechts), sonst der
-- alte (OptionsSliderTemplate) mit - und + daneben, sonst das flache - Zahl +.
-- Der Regler rastet auf ganze Zahlen; die Pfeile springen um opts.step.

-- Die Zahl, die get() liefert, und die Logik, die alle drei Formen teilen.
-- paint(v) stellt den Regler, ohne dass dessen Rueckruf etwas speichert.
local function stepperLogic(holder, get, set, opts, paint)
    local painting = false
    local function current() return tonumber(get()) or 0 end
    local function clamp(v)
        if opts.min then v = math.max(opts.min, v) end
        if opts.max then v = math.min(opts.max, v) end
        return v
    end
    function holder.refresh()
        local v = current()
        holder.value:SetText(opts.unit and (v .. " " .. opts.unit) or tostring(v))
        if paint then
            painting = true
            pcall(paint, clamp(v))
            painting = false
        end
    end
    -- Ein neuer Wert: begrenzen, speichern, neu zeichnen, melden.
    function holder.commit(v)
        if painting then return end
        v = clamp(tonumber(v) or current())
        if v == current() then
            holder.refresh()
            return
        end
        set(v)
        holder.refresh()
        if opts.onChange then opts.onChange(v) end
    end
    function holder.change(delta)
        holder.commit(current() + delta * (opts.step or 1))
    end
    -- Was der Regler meldet, auf eine ganze Zahl.
    function holder.fromSlider(value)
        value = tonumber(value)
        if not value then return end
        holder.commit(math.floor(value + 0.5))
    end
end

local function valueText(holder)
    holder.value = Kit.Text(holder, "body", "LEFT")
    holder.value:SetWidth(56)
end

local function minimalStepper(parent, get, set, opts)
    local mixin = MinimalSliderWithSteppersMixin
    if not (mixin and mixin.Event and mixin.Event.OnValueChanged) then return nil end
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(176, 24)
    -- So legen es auch Fremd-Addons an (Baganator): ein Slider mit der Vorlage.
    local bar = fromTemplate("Slider", nil, holder, "MinimalSliderWithSteppersTemplate", function(s)
        return s.Init and s.RegisterCallback and s.SetValue and s.Back and s.Forward
    end)
    if not bar then
        holder:Hide()
        return nil
    end
    bar:SetSize(116, 20)
    bar:SetPoint("LEFT", 0, 0)
    -- ganze Zahlen von min bis max; formatters {}: die Zahl steht in holder.value
    local start = math.max(opts.min, math.min(opts.max, tonumber(get()) or opts.min))
    if not pcall(bar.Init, bar, start, opts.min, opts.max, opts.max - opts.min, {}) then
        holder:Hide()
        return nil
    end
    holder.native = true
    holder.slider = bar
    valueText(holder)
    holder.value:SetPoint("LEFT", bar, "RIGHT", 6, 0)
    stepperLogic(holder, get, set, opts, function(v) bar:SetValue(v) end)
    bar:RegisterCallback(mixin.Event.OnValueChanged, function(_, value) holder.fromSlider(value) end, holder)
    -- Die Pfeile springen um opts.step statt um eine Rasterstufe.
    holder.minus, holder.plus = bar.Back, bar.Forward
    holder.minus:SetScript("OnClick", function() holder.change(-1) end)
    holder.plus:SetScript("OnClick", function() holder.change(1) end)
    return holder
end

local sliderCount = 0
local function optionsStepper(parent, get, set, opts)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(176, 24)
    -- Die alte Vorlage findet ihre Texte ueber den Namen.
    sliderCount = sliderCount + 1
    local name = "EventHelperSyncSlider" .. sliderCount
    local slider = fromTemplate("Slider", name, holder, "OptionsSliderTemplate", function(s)
        return s.SetMinMaxValues and s.SetValue and s.GetValue
    end)
    if not slider then
        holder:Hide()
        return nil
    end
    for _, key in ipairs({ "Low", "High", "Text" }) do
        local fs = slider[key] or _G[name .. key]
        if fs and fs.Hide then fs:Hide() end
    end
    slider:SetMinMaxValues(opts.min, opts.max)
    if slider.SetValueStep then slider:SetValueStep(1) end
    if slider.SetObeyStepOnDrag then slider:SetObeyStepOnDrag(true) end
    holder.native = true
    holder.slider = slider
    holder.minus = Kit.Button(holder, "-", "secondary", 20, function() holder.change(-1) end)
    holder.minus:SetPoint("LEFT", 0, 0)
    slider:SetSize(72, 16)
    slider:SetPoint("LEFT", holder.minus, "RIGHT", 4, 0)
    holder.plus = Kit.Button(holder, "+", "secondary", 20, function() holder.change(1) end)
    holder.plus:SetPoint("LEFT", slider, "RIGHT", 4, 0)
    valueText(holder)
    holder.value:SetPoint("LEFT", holder.plus, "RIGHT", 6, 0)
    stepperLogic(holder, get, set, opts, function(v) slider:SetValue(v) end)
    slider:HookScript("OnValueChanged", function(_, value) holder.fromSlider(value) end)
    return holder
end

local function flatStepper(parent, get, set, opts)
    local holder = CreateFrame("Frame", nil, parent)
    holder.native = false
    holder:SetSize(112, 24)
    holder.bg = Kit.Solid(holder, "BACKGROUND", Kit.C.field)
    holder.bg:SetAllPoints()
    Kit.Border(holder, Kit.C.borderDim)
    holder.value = Kit.Text(holder, "small", "CENTER")
    holder.value:SetPoint("CENTER", 0, 0)
    holder.value:SetWidth(60)
    stepperLogic(holder, get, set, opts)
    local function stepButton(text, point, delta)
        local button = CreateFrame("Button", nil, holder)
        button:SetSize(24, 24)
        button:SetPoint(point, 0, 0)
        button.label = Kit.Text(button, "label", "CENTER")
        button.label:SetPoint("CENTER", 0, 0)
        button.label:SetText(text)
        local hl = Kit.Solid(button, "HIGHLIGHT", { 1, 1, 1 }, 0.1)
        hl:SetAllPoints()
        button:SetScript("OnClick", function() holder.change(delta) end)
        return button
    end
    holder.minus = stepButton("-", "LEFT", -1)
    holder.plus = stepButton("+", "RIGHT", 1)
    return holder
end

function Kit.Stepper(parent, get, set, opts)
    opts = opts or {}
    local holder
    if opts.min and opts.max and opts.max > opts.min then
        holder = minimalStepper(parent, get, set, opts) or optionsStepper(parent, get, set, opts)
    end
    holder = holder or flatStepper(parent, get, set, opts)
    holder.kind = "stepper"
    holder.refresh()
    return holder
end

--- Eine aus vielen. items() -> { { value, text } }, selected() -> value, onPick(value).
-- Klick: Kontextmenue (MenuUtil); ohne MenuUtil schaltet Links-/Rechtsklick
-- weiter. dropdown:Refresh() setzt die Beschriftung.
--
-- Wo es geht, ist es die Auswahl des Spiels (DropdownButton mit
-- WowStyle1DropdownTemplate, Menue ueber SetupMenu); sonst ein flacher Knopf.

-- Die Beschriftung zum gewaehlten Wert.
local function selectedText(items, selected)
    local current = selected()
    for _, item in ipairs(items()) do
        if item.value == current then return item.text end
    end
    return ""
end

local function nativeDropdown(parent, width, title, items, selected, onPick, tooltip)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then return nil end
    local drop = fromTemplate("DropdownButton", nil, parent, "WowStyle1DropdownTemplate", function(d)
        return d.SetupMenu and d.Text
    end)
    if not drop then return nil end
    drop.native = true
    drop:SetSize(width or 180, 24)
    drop.label = drop.Text
    drop:SetupMenu(function(_, root)
        if title then root:CreateTitle(title) end
        for _, item in ipairs(items()) do
            root:CreateRadio(item.text, function() return selected() == item.value end,
                function() onPick(item.value) end)
        end
    end)
    function drop:Refresh()
        if self.GenerateMenu then pcall(self.GenerateMenu, self) end
        self.label:SetText(selectedText(items, selected))
    end
    tooltipFor(drop, tooltip)
    return drop
end

function Kit.Dropdown(parent, width, title, items, selected, onPick, tooltip)
    local native = nativeDropdown(parent, width, title, items, selected, onPick, tooltip)
    if native then return native end
    local drop = CreateFrame("Button", nil, parent)
    drop.native = false
    drop:SetSize(width or 180, 24)
    drop:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    drop.bg = Kit.Solid(drop, "BACKGROUND", Kit.C.field)
    drop.bg:SetAllPoints()
    Kit.Border(drop, Kit.C.borderDim)
    drop.label = Kit.Text(drop, "small")
    drop.label:SetPoint("LEFT", 8, 0)
    drop.label:SetWidth((width or 180) - 28)
    drop.arrow = Kit.Text(drop, "labelSmall", "RIGHT")
    drop.arrow:SetPoint("RIGHT", -7, 0)
    drop.arrow:SetText("v")
    local hl = Kit.Solid(drop, "HIGHLIGHT", { 1, 1, 1 }, 0.06)
    hl:SetAllPoints()

    function drop:Refresh()
        self.label:SetText(selectedText(items, selected))
    end
    drop:SetScript("OnClick", function(self, mouse)
        local list = items()
        if #list == 0 then return end
        if MenuUtil and MenuUtil.CreateContextMenu then
            local ok = pcall(MenuUtil.CreateContextMenu, self, function(_, root)
                if title then root:CreateTitle(title) end
                for _, item in ipairs(list) do
                    root:CreateRadio(item.text, function() return selected() == item.value end,
                        function() onPick(item.value) end)
                end
            end)
            if ok then return end
        end
        local index = 1
        for i, item in ipairs(list) do
            if item.value == selected() then index = i end
        end
        local step = mouse == "RightButton" and -1 or 1
        onPick(list[(index - 1 + step) % #list + 1].value)
    end)
    tooltipFor(drop, tooltip)
    return drop
end

-- ---------------------------------------------------------------------------
-- Zustand
-- ---------------------------------------------------------------------------

-- Die Farben der Etiketten: die Schriftfarben des Spiels (gruen, grau, gold,
-- rot), sonst ihre Werte.
local function gameColor(global, fallback)
    local c = _G[global]
    if type(c) == "table" and tonumber(c.r) then return { c.r, c.g, c.b } end
    return fallback
end
local PILL = {
    on = function() return gameColor("GREEN_FONT_COLOR", { 0.1, 1, 0.1 }) end,
    off = function() return gameColor("GRAY_FONT_COLOR", { 0.5, 0.5, 0.5 }) end,
    warn = function() return gameColor("NORMAL_FONT_COLOR", { 1, 0.82, 0 }) end,
    bad = function() return gameColor("RED_FONT_COLOR", { 1, 0.1, 0.1 }) end,
}

--- Ein kleines Etikett: pill:SetState("aus", "on" | "off" | "warn" | "bad").
-- Schlichter Text in der Farbe des Zustands, wie das Spiel Zustaende schreibt
-- (kein Kasten). pill.label ist der Text, pill.kind der Zustand.
function Kit.Pill(parent)
    local pill = CreateFrame("Frame", nil, parent)
    pill:SetSize(40, 16)
    pill.label = Kit.Text(pill, "small", "LEFT")
    pill.label:SetPoint("LEFT", 0, 0)
    function pill:SetState(text, kind)
        local color = (PILL[kind] or PILL.off)()
        self.kind = kind
        self.label:SetText(text or "")
        self.label:SetTextColor(color[1], color[2], color[3])
        local ok, width = pcall(self.label.GetStringWidth, self.label)
        self:SetWidth(math.max(8, (ok and tonumber(width) or #(text or "") * 6) + 2))
    end
    return pill
end

--- Eine Zahl in Gold (Seitenleiste, Minimap): badge:SetCount(n), 0 versteckt sie.
-- Nur die goldene Zahl, wie das Spiel Zaehler neben Eintraege schreibt.
function Kit.Badge(parent)
    local badge = CreateFrame("Frame", nil, parent)
    badge:SetSize(22, 16)
    badge.label = Kit.Text(badge, "label", "RIGHT")
    badge.label:SetPoint("RIGHT", 0, 0)
    function badge:SetCount(n)
        n = tonumber(n) or 0
        self.count = n
        if n <= 0 then
            self:Hide()
            return
        end
        self.label:SetText(n > 99 and "99+" or tostring(n))
        self:SetWidth(n > 9 and 26 or 20)
        self:Show()
    end
    badge:SetCount(0)
    return badge
end

-- ---------------------------------------------------------------------------
-- Listen
-- ---------------------------------------------------------------------------

--- Der Spaltenkopf einer Liste: columns = { { label, x, width, justify } }.
function Kit.Header(parent, columns, width)
    local header = CreateFrame("Frame", nil, parent)
    header:SetSize(width, 22)
    header.bg = Kit.Solid(header, "BACKGROUND", Kit.C.bar)
    header.bg:SetAllPoints()
    local line = Kit.Solid(header, "BORDER", Kit.C.line)
    line:SetPoint("BOTTOMLEFT")
    line:SetPoint("BOTTOMRIGHT")
    line:SetHeight(1)
    header.labels = {}
    for _, col in ipairs(columns) do
        local label = Kit.Text(header, "labelSmall", col[4] or "LEFT")
        label:SetPoint("LEFT", col[2], 0)
        label:SetWidth(col[3])
        label:SetText(col[1])
        header.labels[#header.labels + 1] = label
    end
    return header
end

--- Bildlaufanzeige: eine Spur rechts in `list`, darin der Daumen.
-- thumb:Set(offset, total, visible) zeigt sie nur, wenn es mehr gibt als passt.
function Kit.Thumb(list)
    local track = Kit.Solid(list, "OVERLAY", { 1, 1, 1 }, 0.05)
    track:SetPoint("TOPRIGHT", 0, 0)
    track:SetPoint("BOTTOMRIGHT", 0, 0)
    track:SetWidth(4)
    local thumb = Kit.Solid(list, "OVERLAY", Kit.C.goldDim, 0.8)
    thumb:SetWidth(4)
    local self = { track = track, thumb = thumb }
    function self.Set(offset, total, visible)
        if total <= visible then
            track:Hide()
            thumb:Hide()
            return
        end
        local height = list:GetHeight()
        height = (tonumber(height) and height > 0) and height or 100
        local size = math.max(16, height * visible / total)
        local maxOffset = math.max(1, total - visible)
        thumb:SetHeight(size)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOPRIGHT", list, "TOPRIGHT", 0, -(height - size) * offset / maxOffset)
        track:Show()
        thumb:Show()
    end
    return self
end

--- Zeilenhintergrund: Streifen auf geraden Zeilen, heller beim Darueberfahren.
function Kit.RowBackground(row, index)
    if index % 2 == 0 then
        local stripe = Kit.Solid(row, "BACKGROUND", { 1, 1, 1 }, 0.025)
        stripe:SetAllPoints()
    end
    local hl = Kit.Solid(row, "HIGHLIGHT", Kit.C.gold, 0.07)
    hl:SetAllPoints()
    local bar = Kit.Solid(row, "HIGHLIGHT", Kit.C.gold, 1)
    bar:SetPoint("TOPLEFT")
    bar:SetPoint("BOTTOMLEFT")
    bar:SetWidth(2)
end

--- Ein Haekchen fuer Tabellenzeilen (mitnehmen / abgehakt): check:SetChecked(on).
-- Das Haekchen des Spiels (UICheckButtonTemplate) schaltet sich beim Klick
-- selbst um; hier entscheidet aber der Aufrufer (OnClick -> Daten -> neu
-- zeichnen -> SetChecked). Darum merkt sich check.checked den Stand, und
-- nach dem Klick (PostClick) gilt wieder er.
local function nativeCheck(parent, size)
    local check = fromTemplate("CheckButton", nil, parent, "UICheckButtonTemplate", function(c)
        return c.SetChecked and c.GetChecked
    end)
    if not check then return nil end
    check.native = true
    check:SetSize(size or 22, size or 22)
    local setNative = check.SetChecked
    check.checked = false
    function check:SetChecked(on)
        self.checked = on and true or false
        setNative(self, self.checked)
    end
    function check:GetChecked() return self.checked end
    check:HookScript("PostClick", function(self) setNative(self, self.checked) end)
    setNative(check, false)
    return check
end

function Kit.Check(parent, size)
    local native = nativeCheck(parent, size)
    if native then return native end
    local check = CreateFrame("Button", nil, parent)
    check.native = false
    check:SetSize(size or 22, size or 22)
    check.box = Kit.Solid(check, "ARTWORK", { 0.12, 0.12, 0.12 })
    check.box:SetPoint("CENTER", 0, 0)
    check.box:SetSize(14, 14)
    Kit.Border(check, Kit.C.border, check.box, "OVERLAY")
    local hl = Kit.Solid(check, "HIGHLIGHT", { 1, 1, 1 }, 0.15)
    hl:SetPoint("CENTER", 0, 0)
    hl:SetSize(14, 14)
    check.mark = check:CreateTexture(nil, "OVERLAY")
    check.mark:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    check.mark:SetSize(22, 22)
    check.mark:SetPoint("CENTER", 1, 1)
    check.mark:Hide()
    function check:SetChecked(on)
        self.checked = on and true or false
        self.mark:SetShown(self.checked)
    end
    function check:GetChecked() return self.checked end
    return check
end

--- Ein Block mit Kopfzeile (Titel, rechts ein Etikett). card.body ist der Inhalt.
-- Im Spiel-Look ist die Karte eine vertiefte Flaeche (Kit.Inset) mit dem
-- goldenen Titel oben, ohne eigene Kopfleiste - wie die Abschnitte im Spiel.
function Kit.Card(parent, title, width, height)
    local card = Kit.Inset(parent)
    card:SetSize(width, height)
    if not card.native then
        card.bg:SetColorTexture(Kit.C.panel2[1], Kit.C.panel2[2], Kit.C.panel2[3], 1)
        card.head = Kit.Solid(card, "BACKGROUND", Kit.C.bar)
        card.head:SetPoint("TOPLEFT", 1, -1)
        card.head:SetPoint("TOPRIGHT", -1, -1)
        card.head:SetHeight(26)
    end
    card.title = Kit.Text(card, "label")
    card.title:SetPoint("TOPLEFT", 10, -8)
    card.title:SetText(title)
    card.pill = Kit.Pill(card)
    card.pill:SetPoint("LEFT", card.title, "RIGHT", 8, 0)
    card.pill:Hide()
    return card
end

--- Eine Einstellungszeile in einer Karte: Name, Hinweis und das Bedienelement.
-- Ein Schalter (Kit.Switch) steht wie in den Optionen des Spiels links, der
-- Name rechts daneben; jedes andere Bedienelement rechts in der Zeile.
function Kit.SettingRow(card, y, name, hint, control, width)
    local label = Kit.Text(card, "body")
    local textWidth
    if control.kind == "switch" then
        local controlWidth = tonumber(control:GetWidth()) or 26
        control:SetPoint("TOPLEFT", card, "TOPLEFT", 8, y + 5)
        label:SetPoint("TOPLEFT", card, "TOPLEFT", 8 + controlWidth + 4, y)
        textWidth = (width or 300) - 24 - controlWidth
    else
        -- Der Text bekommt die ganze Breite links vom Bedienelement.
        local controlWidth = tonumber(control:GetWidth()) or 0
        textWidth = (width or 300) - 30 - math.max(40, controlWidth)
        label:SetPoint("TOPLEFT", 10, y)
        control:SetPoint("TOPRIGHT", card, "TOPRIGHT", -10, y + 2)
    end
    label:SetWidth(textWidth)
    label:SetText(name)
    local note
    if hint and hint ~= "" then
        note = Kit.Text(card, "hint")
        note:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -3)
        note:SetWidth(textWidth)
        note:SetText(hint)
    end
    return label, note
end

--- Der leere Zustand einer Liste: eine Zeile in Grau, mittig.
function Kit.Empty(parent, width)
    local empty = Kit.Text(parent, "empty", "CENTER")
    empty:SetWidth(width or 400)
    return empty
end

-- ---------------------------------------------------------------------------
-- Fenster
-- ---------------------------------------------------------------------------

local TITLE_HEIGHT = 32
Kit.TITLE_HEIGHT = TITLE_HEIGHT

local function savePosition(frame)
    frame:StopMovingOrSizing()
    if not frame.posKey or not EHS.db then return end
    local point, _, relativePoint, x, y = frame:GetPoint()
    if point then EHS.db[frame.posKey] = { point = point, relativePoint = relativePoint, x = x, y = y } end
end

-- Wo der Inhalt im Fenster des Spiels sitzt (ButtonFrameTemplate ohne Bild
-- und ohne Knopfleiste: wie die Inset-Abstaende des Spiels).
local NATIVE_BODY = { left = 4, top = 24, right = 6, bottom = 4 }
Kit.NATIVE_BODY = NATIVE_BODY

-- Die Titelschrift der Vorlage (Retail: TitleContainer.TitleText, sonst TitleText).
local function templateTitle(frame)
    return (frame.TitleContainer and frame.TitleContainer.TitleText) or frame.TitleText
end

-- Den Titel einmal setzen. Je nach Client schreibt SetTitle in
-- TitleContainer.TitleText oder in TitleText (oder <Name>TitleText); gibt es
-- mehrere, stuenden sonst zwei Titel uebereinander. Darum: SetTitle, dann die
-- Schrift nehmen, die Text traegt, die anderen leeren und verstecken. Traegt
-- keine Text, schreibt der Baukasten selbst in die erste.
local function hasText(fs)
    if not (fs and fs.GetText) then return false end
    local ok, text = pcall(fs.GetText, fs)
    return ok and type(text) == "string" and text ~= ""
end

local function nativeTitle(frame, text)
    if frame.SetTitle then pcall(frame.SetTitle, frame, text) end
    local candidates = {}
    local function add(fs)
        if not (fs and fs.SetText) then return end
        for _, known in ipairs(candidates) do
            if known == fs then return end
        end
        candidates[#candidates + 1] = fs
    end
    add(frame.TitleContainer and frame.TitleContainer.TitleText)
    add(frame.TitleText)
    local name = frame.GetName and frame:GetName()
    if name then add(_G[name .. "TitleText"]) end

    local shown
    for _, fs in ipairs(candidates) do
        if not shown and hasText(fs) then shown = fs end
    end
    if not shown then
        shown = candidates[1]
        if shown then shown:SetText(text) end
    end
    for _, fs in ipairs(candidates) do
        if fs ~= shown then
            fs:SetText("")
            if fs.Hide then fs:Hide() end
        end
    end
    return shown
end
Kit.NativeTitle = nativeTitle

--- Das Fenster des Spiels (ButtonFrameTemplate) oder nil. Der Inhalt
-- (frame.body) ist so gross wie im flachen Fenster; der Rahmen waechst darum.
local function nativeWindow(opts)
    local frame = fromTemplate("Frame", opts.name, UIParent, "ButtonFrameTemplate", function(f)
        return f.CloseButton and templateTitle(f)
    end)
    if not frame then return nil end
    frame.native = true
    if ButtonFrameTemplate_HidePortrait then pcall(ButtonFrameTemplate_HidePortrait, frame) end
    if ButtonFrameTemplate_HideButtonBar then pcall(ButtonFrameTemplate_HideButtonBar, frame) end
    frame:SetSize(opts.width - 2 + NATIVE_BODY.left + NATIVE_BODY.right,
        opts.height - TITLE_HEIGHT - 1 + NATIVE_BODY.top + NATIVE_BODY.bottom)

    frame.title = nativeTitle(frame, opts.title or "")

    -- Die Titelzeile der Vorlage zum Verschieben anfassen (ein unsichtbarer
    -- Streifen darueber, rechts die Versionszeile). Ein Wappen hat das
    -- Fenster des Spiels nicht - der Titel steht allein.
    local bar = CreateFrame("Frame", nil, frame)
    bar:SetPoint("TOPLEFT", 0, 0)
    bar:SetPoint("TOPRIGHT", -28, 0)
    bar:SetHeight(NATIVE_BODY.top - 2)
    frame.titleBar = bar

    frame.subtitle = Kit.Text(bar, "hint", "RIGHT")
    frame.subtitle:SetPoint("RIGHT", bar, "RIGHT", -4, -1)

    if opts.noClose then
        frame.CloseButton:Hide()
    else
        frame.close = frame.CloseButton
        frame.close.native = true
        frame.close:SetScript("OnClick", function() frame:Hide() end)
    end

    frame.body = CreateFrame("Frame", nil, frame)
    frame.body:SetPoint("TOPLEFT", NATIVE_BODY.left, -NATIVE_BODY.top)
    frame.body:SetPoint("BOTTOMRIGHT", -NATIVE_BODY.right, NATIVE_BODY.bottom)

    -- Hinter dem Inhalt die vertiefte Flaeche der Vorlage, wie in jedem
    -- Fenster des Spiels. Fenster mit eigenen Flaechen (Seitenleiste +
    -- Inhalt) sagen opts.inset = false.
    if opts.inset == false then
        if frame.Inset then frame.Inset:Hide() end
    else
        local inset = frame.Inset
        if not inset then
            inset = Kit.Inset(frame)
            inset.own = true
        end
        inset:ClearAllPoints()
        inset:SetPoint("TOPLEFT", frame.body, "TOPLEFT", 0, 0)
        inset:SetPoint("BOTTOMRIGHT", frame.body, "BOTTOMRIGHT", 0, 0)
        inset:Show()
        frame.inset = inset
        local level = inset.GetFrameLevel and tonumber(inset:GetFrameLevel()) or 0
        frame.body:SetFrameLevel(level + 1)
    end
    return frame
end

--- Das flache Fenster (ohne Vorlage), bis 1.16 das einzige.
local function flatWindow(opts)
    local frame = CreateFrame("Frame", opts.name, UIParent)
    frame.native = false
    frame:SetSize(opts.width, opts.height)
    frame.bg = Kit.Solid(frame, "BACKGROUND", Kit.C.panel, 0.96)
    frame.bg:SetAllPoints()
    Kit.Border(frame, Kit.C.border)

    -- Titelleiste: zum Verschieben anfassen.
    local bar = CreateFrame("Frame", nil, frame)
    bar:SetPoint("TOPLEFT", 1, -1)
    bar:SetPoint("TOPRIGHT", -1, -1)
    bar:SetHeight(TITLE_HEIGHT - 1)
    bar.bg = Kit.Solid(bar, "BACKGROUND", Kit.C.bar)
    bar.bg:SetAllPoints()
    local barLine = Kit.Solid(bar, "BORDER", Kit.C.border)
    barLine:SetPoint("BOTTOMLEFT", 0, -1)
    barLine:SetPoint("BOTTOMRIGHT", 0, -1)
    barLine:SetHeight(1)
    frame.titleBar = bar

    -- Das Wappen: ohne opts.icon die EventHelper-Marke, sonst ein Spiel-Icon
    -- mit Rahmen (der Rand der Spiel-Icons wird abgeschnitten).
    local icon = opts.icon or Kit.LOGO
    bar.crest = CreateFrame("Frame", nil, bar)
    bar.crest:SetSize(20, 20)
    bar.crest:SetPoint("LEFT", 8, 0)
    bar.crest.icon = bar.crest:CreateTexture(nil, "ARTWORK")
    bar.crest.icon:SetTexture(icon)
    if icon == Kit.LOGO then
        bar.crest.icon:SetAllPoints()
    else
        Kit.Solid(bar.crest, "BACKGROUND", Kit.C.field):SetAllPoints()
        Kit.Border(bar.crest, Kit.C.border)
        bar.crest.icon:SetPoint("TOPLEFT", 2, -2)
        bar.crest.icon:SetPoint("BOTTOMRIGHT", -2, 2)
        bar.crest.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    end

    frame.title = Kit.Text(bar, "title")
    frame.title:SetPoint("LEFT", bar.crest, "RIGHT", 8, 0)
    frame.title:SetText(opts.title or "")

    frame.subtitle = Kit.Text(bar, "hint")
    frame.subtitle:SetPoint("LEFT", frame.title, "RIGHT", 8, -1)

    if not opts.noClose then
        frame.close = Kit.CloseButton(bar, function() frame:Hide() end)
        frame.close:SetPoint("RIGHT", -5, 0)
    end

    frame.body = CreateFrame("Frame", nil, frame)
    frame.body:SetPoint("TOPLEFT", 1, -TITLE_HEIGHT)
    frame.body:SetPoint("BOTTOMRIGHT", -1, 1)
    return frame
end

--- Ein Fenster: Rahmen, Titelleiste (Wappen, Titel, X), Esc schliesst,
-- die Position wird unter EHS.db[posKey] gemerkt (ohne posKey: immer mittig).
-- opts { name, title, width, height, posKey, strata, point, noEscape, noClose, icon, inset }.
-- frame.body ist die Flaeche unter der Titelleiste, immer (width-2) x
-- (height-TITLE_HEIGHT-1) gross - im Fenster des Spiels wie im flachen.
-- Im Fenster des Spiels liegt hinter frame.body die vertiefte Flaeche
-- (frame.inset); opts.inset = false laesst sie weg (eigene Flaechen).
-- Das Wappen (opts.icon) zeigt nur das flache Fenster.
function Kit.Window(opts)
    local frame = nativeWindow(opts) or flatWindow(opts)
    frame.posKey = opts.posKey
    local pos = opts.posKey and EHS.db and EHS.db[opts.posKey]
    frame:ClearAllPoints()
    if pos and pos.point then
        frame:SetPoint(pos.point, UIParent, pos.relativePoint or pos.point, pos.x or 0, pos.y or 0)
    else
        local p = opts.point or { "CENTER", 0, 40 }
        frame:SetPoint(p[1], p[2], p[3])
    end
    frame:SetFrameStrata(opts.strata or "HIGH")
    if frame.SetToplevel then frame:SetToplevel(true) end
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)

    local bar = frame.titleBar
    bar:EnableMouse(true)
    bar:RegisterForDrag("LeftButton")
    bar:SetScript("OnDragStart", function() frame:StartMoving() end)
    bar:SetScript("OnDragStop", function() savePosition(frame) end)

    if opts.name and not opts.noEscape then tinsert(UISpecialFrames, opts.name) end
    frame:Hide()
    return frame
end
