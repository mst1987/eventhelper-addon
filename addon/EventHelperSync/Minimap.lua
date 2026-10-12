--[[
Der Knopf an der Minimap.

Ohne LibDBIcon gebaut — die Bibliothek wäre für einen einzelnen Knopf mehr
Ballast als Nutzen, und das Addon soll ein Ordner zum Kopieren bleiben. Der
Preis dafür sind die knapp zwanzig Zeilen Winkelrechnung unten.

Der Knopf sitzt auf einem Kreis um die Minimap und wird beim Ziehen an ihrem
Rand entlanggeführt; gespeichert wird nur der Winkel, damit die Position eine
andere Minimap-Grösse und einen anderen Bildschirm überlebt.

Er zeigt nebenbei an, ob etwas ansteht: ist ungespeicherter Loot da, bekommt er
einen goldenen Rand. Damit beantwortet schon der Blick auf die Minimap die
Frage, um die es hier die ganze Zeit geht — "muss ich was tun?".
]]

local EHS = EventHelperSync

local button
-- Abstand vom Minimap-Mittelpunkt. 80 legt den Knopf knapp ausserhalb des
-- Randes, dort, wo auch alle anderen Addon-Knöpfe sitzen.
local RADIUS = 80

local function placeAt(target, angle)
    local rad = math.rad(angle)
    target:ClearAllPoints()
    target:SetPoint("CENTER", Minimap, "CENTER", RADIUS * math.cos(rad), RADIUS * math.sin(rad))
end

local function positionAt(angle)
    placeAt(button, angle)
end

--- Winkel zwischen Minimap-Mittelpunkt und Mauszeiger.
local function angleToCursor()
    local mx, my = Minimap:GetCenter()
    local scale = Minimap:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    cx, cy = cx / scale, cy / scale
    return math.deg(math.atan2(cy - my, cx - mx))
end

--- Das Rechtsklick-Menue der Minimap-Knoepfe: alles, was die eingeschalteten
-- Module koennen, ohne das Fenster zu oeffnen.
-- @return false ohne MenuUtil (dann tut der Aufrufer das Alte)
function EHS:OpenMinimapMenu(owner)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then return false end
    local lootOn, councilOn, bankOn = self:ModuleOn("loot"), self:ModuleOn("council"), self:ModuleOn("guildbank")
    local pending = lootOn and self:PendingCount() or 0
    local okOpen, open = pcall(self.HandoutCounts, self)
    open = okOpen and tonumber(open) or 0
    local ok = pcall(MenuUtil.CreateContextMenu, owner, function(_, root)
        root:CreateTitle("EventHelper")
        root:CreateButton("Fenster öffnen", function() EHS:ShowMain() end)
        if lootOn then
            -- Der Klick im Menue ist ein Hardware-Ereignis: ReloadUI() ist erlaubt.
            root:CreateButton(pending > 0 and ("Speichern & hochladen (%d)"):format(pending) or "Speichern & hochladen",
                function() EHS:FlushAndReload() end)
        end
        if councilOn then root:CreateButton("Loot-Council", function() EHS:ShowMain("council") end) end
        if bankOn then
            root:CreateButton(open > 0 and ("Gildenbank-Ausgabe (%d)"):format(open) or "Gildenbank-Ausgabe",
                function() EHS:ShowMain("guildbank") end)
        end
        if root.CreateDivider then pcall(root.CreateDivider, root) end
        root:CreateTitle("Einstellungen")
        root:CreateButton("Einstellungen öffnen", function() EHS:ShowMain("settings") end)
        root:CreateButton("Module wählen", function() EHS:ShowModuleChooser() end)
    end)
    return ok
end

local function build()
    button = CreateFrame("Button", "EventHelperSyncMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp", "MiddleButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetMovable(true)

    -- Das Symbol: die EventHelper-Marke in ihrer runden Fassung, damit sie in
    -- den runden Rahmen passt (media/logo-round.tga, siehe Kit.LOGO_ROUND).
    local icon = button:CreateTexture(nil, "BACKGROUND")
    icon:SetTexture(EHS.Kit.LOGO_ROUND)
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", 0, 1)
    button.icon = icon

    -- Der übliche runde Rahmen, den auch die Blizzard-Knöpfe tragen.
    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    button.border = border

    -- Der goldene Ring, der aufleuchtet, wenn etwas ansteht.
    local glow = button:CreateTexture(nil, "OVERLAY")
    glow:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    glow:SetSize(31, 31)
    glow:SetPoint("CENTER", 0, 1)
    glow:SetVertexColor(1, .82, 0)
    glow:Hide()
    button.glow = glow

    button:SetScript("OnDragStart", function(self)
        self.dragging = true
        self:SetScript("OnUpdate", function()
            local angle = angleToCursor()
            EHS.db.minimapAngle = angle
            positionAt(angle)
        end)
    end)
    button:SetScript("OnDragStop", function(self)
        self.dragging = false
        self:SetScript("OnUpdate", nil)
    end)

    button:SetScript("OnClick", function(self, mouseButton)
        local shift = IsShiftKeyDown and IsShiftKeyDown()
        local ctrl = IsControlKeyDown and IsControlKeyDown()
        if mouseButton == "LeftButton" and ctrl then
            -- Die alten Abkuerzungen bleiben: Gildenbank-Ausgabe ...
            EHS:ToggleGuildBankUI()
        elseif mouseButton == "MiddleButton" or (mouseButton == "LeftButton" and shift) then
            -- ... und Loot-Council.
            EHS:ToggleCouncil()
        elseif mouseButton == "RightButton" then
            -- Das Menue mit allem, was die Module koennen. Ohne MenuUtil (alter
            -- Client) bleibt es beim schnellen Speichern.
            if not EHS:OpenMinimapMenu(self) then EHS:FlushAndReload() end
        else
            EHS:ToggleOptions()
        end
    end)

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("EventHelper Sync")

        -- Only what belongs to a module that is on (Modules.lua).
        local lootOn = EHS:ModuleOn("loot")
        local bankOn = EHS:ModuleOn("guildbank")
        if lootOn then
            local sources = EHS:AvailableSources()
            local Kit = EHS.Kit
            GameTooltip:AddDoubleLine("RCLootCouncil",
                sources.rclc and Kit.Color("gefunden", "green") or Kit.Color("nicht geladen", "red"))
            GameTooltip:AddDoubleLine("Gargul",
                sources.gargul and Kit.Color("gefunden", "green") or Kit.Color("nicht geladen", "red"))

            local sessions = EHS:BuildSessions()
            local included = 0
            for _, session in ipairs(sessions) do
                if not EHS:IsExcluded(session.sessionId) then included = included + 1 end
            end
            GameTooltip:AddDoubleLine("Raid-Abende", ("%d von %d ausgewählt"):format(included, #sessions))

            local pending = EHS:PendingCount()
            if pending > 0 then
                GameTooltip:AddDoubleLine("Ungespeichert", EHS.Kit.Color(pending .. " Item(s)", "gold"))
            else
                GameTooltip:AddDoubleLine("Stand", EHS.Kit.Color("gespeichert", "green"))
            end
        end

        -- Nur wenn es Ausgabe-Daten gibt: sonst ist die Zeile nur Rauschen.
        local okHandouts, open = pcall(EHS.HandoutCounts, EHS)
        if bankOn and okHandouts and EHS.Handouts.Load() then
            GameTooltip:AddDoubleLine("Gildenbank-Ausgabe",
                open > 0 and EHS.Kit.Color(open .. " offen", "gold") or EHS.Kit.Color("nichts offen", "green"))
        end

        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Linksklick: Fenster öffnen", 1, 1, 1)
        if MenuUtil and MenuUtil.CreateContextMenu then
            GameTooltip:AddLine("Rechtsklick: Menü", 1, 1, 1)
        elseif lootOn then
            GameTooltip:AddLine("Rechtsklick: Speichern & hochladen (lädt die UI neu)", 1, 1, 1)
        end
        GameTooltip:AddLine("Ziehen: um die Minimap bewegen", .6, .6, .6)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)

    positionAt(EHS.db.minimapAngle or 200)
end

--- Sichtbarkeit und Hinweis-Ring an den aktuellen Stand anpassen.
function EHS:RefreshMinimap()
    if not button then return end
    if not self.db.settings.showMinimap then
        button:Hide()
        return
    end
    button:Show()
    if self:PendingCount() > 0 then
        button.glow:Show()
    else
        button.glow:Hide()
    end
end

function EHS:StartMinimap()
    if not button then build() end
    self:RefreshMinimap()
    -- The guild bank button is an extra: should it break on a client, the
    -- main button must still be there.
    local ok, err = pcall(self.StartBankMinimap, self)
    if not ok then self:Debug("Gildenbank-Knopf:", tostring(err)) end
end

-- ---------------------------------------------------------------------------
-- The second button: the guild bank handouts (GuildBankUI.lua)
-- ---------------------------------------------------------------------------
--
-- Built like the one above, with its own angle (bankMinimapAngle) and its own
-- switch (settings.showBankMinimap, /ehs bankbutton). A chest from the
-- original game, which TBC Anniversary and WoW Forever both have. Gold ring
-- and a small number when handouts are open.

local bankButton
local BANK_ICON = "Interface\\Icons\\INV_Box_02"

local function bankTooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("Gildenbank-Ausgabe")
    local Handouts = EHS.Handouts
    local data, status = Handouts.Load()
    if data then
        local ok, open, done = pcall(EHS.HandoutCounts, EHS)
        if ok then
            GameTooltip:AddLine(("%d Posten offen"):format(open), 1, 1, 1)
            if done > 0 then
                GameTooltip:AddLine(("%d abgehakt, wird beim nächsten Sync gemeldet"):format(done), 0.6, 0.6, 0.6)
            end
        end
        GameTooltip:AddLine(EHS.Council.Header(data, time()), 0.6, 0.6, 0.6)
    else
        GameTooltip:AddLine(Handouts.EMPTY_TEXT[status] or Handouts.EMPTY_TEXT.none, 0.6, 0.6, 0.6, true)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Linksklick: Gildenbank-Ausgabe öffnen/schliessen", 1, 1, 1)
    GameTooltip:AddLine((MenuUtil and MenuUtil.CreateContextMenu) and "Rechtsklick: Menü" or "Rechtsklick: Einstellungen",
        1, 1, 1)
    GameTooltip:AddLine("Ziehen: um die Minimap bewegen", .6, .6, .6)
    GameTooltip:Show()
end

local function buildBank()
    bankButton = CreateFrame("Button", "EventHelperSyncBankMinimapButton", Minimap)
    bankButton:SetSize(31, 31)
    bankButton:SetFrameStrata("MEDIUM")
    bankButton:SetFrameLevel(8)
    bankButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    bankButton:RegisterForDrag("LeftButton")
    bankButton:SetMovable(true)

    local icon = bankButton:CreateTexture(nil, "BACKGROUND")
    icon:SetTexture(BANK_ICON)
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", 0, 1)
    icon:SetTexCoord(.07, .93, .07, .93)
    bankButton.icon = icon

    local border = bankButton:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    bankButton.border = border

    local glow = bankButton:CreateTexture(nil, "OVERLAY")
    glow:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    glow:SetSize(31, 31)
    glow:SetPoint("CENTER", 0, 1)
    glow:SetVertexColor(1, .82, 0)
    glow:Hide()
    bankButton.glow = glow

    -- How many are open, small at the lower right of the icon. An outlined
    -- number font where the client has one, else the plain small font.
    local ok, count = pcall(bankButton.CreateFontString, bankButton, nil, "OVERLAY", "NumberFontNormalSmall")
    if not ok or not count then count = bankButton:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall") end
    count:SetPoint("BOTTOMRIGHT", -5, 6)
    count:SetJustifyH("RIGHT")
    count:Hide()
    bankButton.count = count

    bankButton:SetScript("OnDragStart", function(self)
        self.dragging = true
        self:SetScript("OnUpdate", function()
            local angle = angleToCursor()
            EHS.db.bankMinimapAngle = angle
            placeAt(self, angle)
        end)
    end)
    bankButton:SetScript("OnDragStop", function(self)
        self.dragging = false
        self:SetScript("OnUpdate", nil)
    end)

    bankButton:SetScript("OnClick", function(self, mouseButton)
        if mouseButton == "RightButton" then
            if not EHS:OpenMinimapMenu(self) then EHS:ShowMain("settings") end
        else
            EHS:ToggleGuildBankUI()
        end
    end)
    bankButton:SetScript("OnEnter", bankTooltip)
    bankButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- next to the main button (200 degrees), not on top of it
    placeAt(bankButton, EHS.db.bankMinimapAngle or 235)
end

--- Visibility, gold ring and number of the guild bank button.
function EHS:RefreshBankMinimap()
    if not bankButton then return end
    if self.db.settings.showBankMinimap == false or not self:ModuleOn("guildbank") then
        bankButton:Hide()
        return
    end
    bankButton:Show()
    local ok, open = pcall(self.HandoutCounts, self)
    open = ok and tonumber(open) or 0
    if open > 0 then
        bankButton.glow:Show()
        bankButton.count:SetText(open > 99 and "99+" or tostring(open))
        bankButton.count:Show()
    else
        bankButton.glow:Hide()
        bankButton.count:SetText("")
        bankButton.count:Hide()
    end
end

function EHS:StartBankMinimap()
    if not bankButton then buildBank() end
    self:RefreshBankMinimap()
end
