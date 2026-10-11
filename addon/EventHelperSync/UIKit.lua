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

Nur Texturen, Schriften und schlichte Frames: WoW Forever ist ein Retail-
Client, TBC Anniversary ein Classic-Client, und beide sollen gleich aussehen.
Kein Gradient (die API unterscheidet sich), keine Vorlagen ausser denen, die
beide Clients kennen.
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

local function tooltipFor(button, tooltip)
    if not tooltip then return end
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        if type(tooltip) == "function" then
            tooltip(self)
        else
            GameTooltip:AddLine(tooltip, 1, 1, 1, true)
        end
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
end
Kit.Tooltip = tooltipFor

-- ---------------------------------------------------------------------------
-- Knoepfe
-- ---------------------------------------------------------------------------

local BUTTON_HEIGHT = { primary = 28, secondary = 24, link = 18 }

--- Ein Knopf. kind: "primary" | "secondary" | "link".
-- Gesperrt (button:SetActive(false)) wird er blass und nimmt keine Klicks an;
-- `button.active` sagt es (auch fuer die Specs).
function Kit.Button(parent, label, kind, width, onClick, tooltip)
    kind = kind or "secondary"
    local button = CreateFrame("Button", nil, parent)
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

--- Das X oben rechts in jeder Titelleiste.
function Kit.CloseButton(parent, onClick)
    local button = CreateFrame("Button", nil, parent)
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
function Kit.Switch(parent, onToggle, tooltip)
    local switch = CreateFrame("Button", nil, parent)
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
function Kit.Chip(parent, label, onClick, tooltip)
    local chip = CreateFrame("Button", nil, parent)
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

--- Eine Zahl mit - und +. get() -> Zahl, set(n); opts { min, max, step, unit }.
function Kit.Stepper(parent, get, set, opts)
    opts = opts or {}
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(112, 24)
    holder.bg = Kit.Solid(holder, "BACKGROUND", Kit.C.field)
    holder.bg:SetAllPoints()
    Kit.Border(holder, Kit.C.borderDim)
    holder.value = Kit.Text(holder, "small", "CENTER")
    holder.value:SetPoint("CENTER", 0, 0)
    holder.value:SetWidth(60)

    local function change(delta)
        local current = tonumber(get()) or 0
        local nextValue = current + delta * (opts.step or 1)
        if opts.min then nextValue = math.max(opts.min, nextValue) end
        if opts.max then nextValue = math.min(opts.max, nextValue) end
        set(nextValue)
        holder.refresh()
        if opts.onChange then opts.onChange(nextValue) end
    end
    local function stepButton(text, point, delta)
        local button = CreateFrame("Button", nil, holder)
        button:SetSize(24, 24)
        button:SetPoint(point, 0, 0)
        button.label = Kit.Text(button, "label", "CENTER")
        button.label:SetPoint("CENTER", 0, 0)
        button.label:SetText(text)
        local hl = Kit.Solid(button, "HIGHLIGHT", { 1, 1, 1 }, 0.1)
        hl:SetAllPoints()
        button:SetScript("OnClick", function() change(delta) end)
        return button
    end
    holder.minus = stepButton("-", "LEFT", -1)
    holder.plus = stepButton("+", "RIGHT", 1)
    function holder.refresh()
        local v = tonumber(get()) or 0
        holder.value:SetText(opts.unit and (v .. " " .. opts.unit) or tostring(v))
    end
    holder.refresh()
    return holder
end

--- Eine aus vielen. items() -> { { value, text } }, selected() -> value, onPick(value).
-- Klick: Kontextmenue (MenuUtil); ohne MenuUtil schaltet Links-/Rechtsklick
-- weiter. dropdown:Refresh() setzt die Beschriftung.
function Kit.Dropdown(parent, width, title, items, selected, onPick, tooltip)
    local drop = CreateFrame("Button", nil, parent)
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
        local current = selected()
        local text = ""
        for _, item in ipairs(items()) do
            if item.value == current then text = item.text end
        end
        self.label:SetText(text)
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

local PILL = {
    on = { text = { 0.5, 0.88, 0.48 }, edge = { 0.24, 0.48, 0.22 }, bg = { 0.08, 0.14, 0.06 } },
    off = { text = { 0.6, 0.58, 0.52 }, edge = { 0.29, 0.27, 0.22 }, bg = { 0.1, 0.09, 0.08 } },
    warn = { text = Kit.C.gold, edge = Kit.C.border, bg = { 0.165, 0.137, 0.078 } },
    bad = { text = { 1, 0.54, 0.48 }, edge = { 0.54, 0.23, 0.19 }, bg = { 0.165, 0.07, 0.06 } },
}

--- Ein kleines Etikett: pill:SetState("an", "on" | "off" | "warn" | "bad").
function Kit.Pill(parent)
    local pill = CreateFrame("Frame", nil, parent)
    pill:SetSize(40, 16)
    pill.bg = Kit.Solid(pill, "BACKGROUND", PILL.off.bg)
    pill.bg:SetAllPoints()
    pill.edges = Kit.Border(pill, PILL.off.edge)
    pill.label = Kit.Text(pill, "small", "CENTER")
    pill.label:SetPoint("CENTER", 0, 0)
    function pill:SetState(text, kind)
        local style = PILL[kind] or PILL.off
        self.kind = kind
        self.label:SetText(text or "")
        self.label:SetTextColor(style.text[1], style.text[2], style.text[3])
        self.bg:SetColorTexture(style.bg[1], style.bg[2], style.bg[3], 1)
        for _, line in ipairs(self.edges) do line:SetColorTexture(style.edge[1], style.edge[2], style.edge[3], 1) end
        local ok, width = pcall(self.label.GetStringWidth, self.label)
        self:SetWidth(math.max(28, (ok and tonumber(width) or #(text or "") * 6) + 12))
    end
    return pill
end

--- Eine Zahl in Gold (Seitenleiste, Minimap): badge:SetCount(n), 0 versteckt sie.
function Kit.Badge(parent)
    local badge = CreateFrame("Frame", nil, parent)
    badge:SetSize(22, 16)
    badge.bg = Kit.Solid(badge, "BACKGROUND", { 0.23, 0.17, 0.05 })
    badge.bg:SetAllPoints()
    Kit.Border(badge, Kit.C.border)
    badge.label = Kit.Text(badge, "labelSmall", "CENTER")
    badge.label:SetPoint("CENTER", 0, 0)
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
function Kit.Check(parent, size)
    local check = CreateFrame("Button", nil, parent)
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
function Kit.Card(parent, title, width, height)
    local card = CreateFrame("Frame", nil, parent)
    card:SetSize(width, height)
    card.bg = Kit.Solid(card, "BACKGROUND", Kit.C.panel2)
    card.bg:SetAllPoints()
    Kit.Border(card, Kit.C.line)
    card.head = Kit.Solid(card, "BACKGROUND", Kit.C.bar)
    card.head:SetPoint("TOPLEFT", 1, -1)
    card.head:SetPoint("TOPRIGHT", -1, -1)
    card.head:SetHeight(26)
    card.title = Kit.Text(card, "label")
    card.title:SetPoint("TOPLEFT", 10, -7)
    card.title:SetText(title)
    card.pill = Kit.Pill(card)
    card.pill:SetPoint("LEFT", card.title, "RIGHT", 8, 0)
    card.pill:Hide()
    return card
end

--- Eine Einstellungszeile in einer Karte: Name, Hinweis, rechts das Bedienelement.
function Kit.SettingRow(card, y, name, hint, control, width)
    -- Der Text bekommt die ganze Breite links vom Bedienelement.
    local controlWidth = tonumber(control:GetWidth()) or 0
    local textWidth = (width or 300) - 30 - math.max(40, controlWidth)
    local label = Kit.Text(card, "body")
    label:SetPoint("TOPLEFT", 10, y)
    label:SetWidth(textWidth)
    label:SetText(name)
    local note
    if hint and hint ~= "" then
        note = Kit.Text(card, "hint")
        note:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -3)
        note:SetWidth(textWidth)
        note:SetText(hint)
    end
    control:SetPoint("TOPRIGHT", card, "TOPRIGHT", -10, y + 2)
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

--- Ein Fenster: Rahmen, Titelleiste (Wappen, Titel, X), Esc schliesst,
-- die Position wird unter EHS.db[posKey] gemerkt (ohne posKey: immer mittig).
-- opts { name, title, width, height, posKey, strata, point, noEscape, noClose }.
-- frame.body ist die Flaeche unter der Titelleiste.
function Kit.Window(opts)
    local frame = CreateFrame("Frame", opts.name, UIParent)
    frame:SetSize(opts.width, opts.height)
    frame.posKey = opts.posKey
    local pos = opts.posKey and EHS.db and EHS.db[opts.posKey]
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
    bar:EnableMouse(true)
    bar:RegisterForDrag("LeftButton")
    bar:SetScript("OnDragStart", function() frame:StartMoving() end)
    bar:SetScript("OnDragStop", function() savePosition(frame) end)
    frame.titleBar = bar

    bar.crest = CreateFrame("Frame", nil, bar)
    bar.crest:SetSize(20, 20)
    bar.crest:SetPoint("LEFT", 8, 0)
    Kit.Solid(bar.crest, "BACKGROUND", Kit.C.field):SetAllPoints()
    Kit.Border(bar.crest, Kit.C.border)
    bar.crest.icon = bar.crest:CreateTexture(nil, "ARTWORK")
    bar.crest.icon:SetPoint("TOPLEFT", 2, -2)
    bar.crest.icon:SetPoint("BOTTOMRIGHT", -2, 2)
    bar.crest.icon:SetTexture(opts.icon or "Interface\\Icons\\INV_Misc_Note_02")
    bar.crest.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

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

    if opts.name and not opts.noEscape then tinsert(UISpecialFrames, opts.name) end
    frame:Hide()
    return frame
end
