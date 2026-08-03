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

local function positionAt(angle)
    local rad = math.rad(angle)
    button:SetPoint("CENTER", Minimap, "CENTER", RADIUS * math.cos(rad), RADIUS * math.sin(rad))
end

--- Winkel zwischen Minimap-Mittelpunkt und Mauszeiger.
local function angleToCursor()
    local mx, my = Minimap:GetCenter()
    local scale = Minimap:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    cx, cy = cx / scale, cy / scale
    return math.deg(math.atan2(cy - my, cx - mx))
end

local function build()
    button = CreateFrame("Button", "EventHelperSyncMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetMovable(true)

    -- Das Symbol. Ein vorhandenes Blizzard-Icon statt einer eigenen Grafik:
    -- so bleibt das Addon ohne Medien-Dateien.
    local icon = button:CreateTexture(nil, "BACKGROUND")
    icon:SetTexture("Interface\\Icons\\INV_Misc_Note_02")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", 0, 1)
    icon:SetTexCoord(.07, .93, .07, .93)
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

    button:SetScript("OnClick", function(_, mouseButton)
        if mouseButton == "RightButton" then
            -- Rechtsklick ist der schnelle Weg für alle, die das Fenster nicht
            -- brauchen, sondern nur speichern wollen.
            EHS:FlushAndReload()
        else
            EHS:ToggleOptions()
        end
    end)

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("EventHelper Sync")

        local sources = EHS:AvailableSources()
        GameTooltip:AddDoubleLine("RCLootcouncil",
            sources.rclc and "|cff44dd44gefunden|r" or "|cffdd4444nicht geladen|r")
        GameTooltip:AddDoubleLine("Gargul",
            sources.gargul and "|cff44dd44gefunden|r" or "|cffdd4444nicht geladen|r")

        local sessions = EHS:BuildSessions()
        local included = 0
        for _, session in ipairs(sessions) do
            if not EHS:IsExcluded(session.sessionId) then included = included + 1 end
        end
        GameTooltip:AddDoubleLine("Raid-Abende", ("%d von %d ausgewählt"):format(included, #sessions))

        local pending = EHS:PendingCount()
        if pending > 0 then
            GameTooltip:AddDoubleLine("Ungespeichert", ("|cffffd200%d Item(s)|r"):format(pending))
        else
            GameTooltip:AddDoubleLine("Stand", "|cff44dd44gespeichert|r")
        end

        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Linksklick: Fenster öffnen", 1, 1, 1)
        GameTooltip:AddLine("Rechtsklick: jetzt speichern (lädt die UI neu)", 1, 1, 1)
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
end
