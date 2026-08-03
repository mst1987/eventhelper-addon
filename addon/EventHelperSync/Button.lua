--[[
Der Upload-Knopf.

Warum es ihn gibt: SavedVariables landen nur beim Ausloggen oder bei einem
Reload auf der Platte, und eine API, die das Schreiben erzwingt, existiert
nicht. Der Knopf macht aus "nach dem Raid ausloggen" ein "in der Pause einmal
klicken" — er baut den Export und löst danach ReloadUI() aus.

Warum es kein Automatismus ist: ReloadUI() ist von Blizzard auf Hardware-Events
beschränkt (Klick oder Tastendruck). Ein Reload nach jedem Bosskill von selbst
wäre blockiert. Der Knopf ist die Bauform, die die Beschränkung zulässt — er
meldet sich von allein, gedrückt wird er von Hand.

Er zeigt sich nur, wenn es tatsächlich etwas zu speichern gibt, und verschwindet
danach wieder: ein dauerhaft sichtbarer Knopf wäre in einem vollen Raid-Interface
nur ein weiteres Element, das im Weg steht.
]]

local EHS = EventHelperSync

local button
-- Wie oft geprüft wird, ob neuer Loot dazugekommen ist. Loot fällt in Minuten-,
-- nicht in Sekundenabständen an; häufiger zu zählen wäre verschenkte Arbeit.
local CHECK_SECONDS = 20

local function positionFromDb()
    local pos = EHS.db.buttonPos
    if pos and pos.point then
        button:SetPoint(pos.point, UIParent, pos.point, pos.x or 0, pos.y or 0)
    else
        button:SetPoint("CENTER", UIParent, "CENTER", 0, 180)
    end
end

local function build()
    button = CreateFrame("Button", "EventHelperSyncUploadButton", UIParent, "UIPanelButtonTemplate")
    button:SetSize(210, 26)
    button:SetMovable(true)
    button:EnableMouse(true)
    button:RegisterForDrag("LeftButton")
    button:SetClampedToScreen(true)
    button:SetFrameStrata("MEDIUM")
    positionFromDb()

    button:SetScript("OnDragStart", button.StartMoving)
    button:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint()
        EHS.db.buttonPos = { point = point, x = x, y = y }
    end)

    -- Der eigentliche Punkt: der Klick IST das Hardware-Event, das ReloadUI()
    -- verlangt. Deshalb hängt hier direkt FlushAndReload() dran und nicht etwa
    -- ein Timer, der es später täte.
    button:SetScript("OnClick", function() EHS:FlushAndReload() end)

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("EventHelper — Loot hochladen")
        GameTooltip:AddLine("Speichert den bisherigen Loot und lädt dazu die UI neu.", 1, 1, 1, true)
        GameTooltip:AddLine("Danach holt ihn das Sync-Tool von selbst ab.", 1, 1, 1, true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Ziehen verschiebt den Knopf. Ausblenden: /ehs button", .6, .6, .6, true)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)

    button:Hide()
end

--- Sichtbarkeit und Beschriftung an den aktuellen Stand anpassen.
function EHS:RefreshButton()
    if not button then return end

    if not self.db.settings.showButton then
        button:Hide()
        return
    end

    local pending = self:PendingCount()
    if pending == 0 then
        button:Hide()
        return
    end

    button:SetText(("Loot hochladen (%d)"):format(pending))
    -- Im Kampf bleibt er sichtbar, aber unbenutzbar: ihn verschwinden zu lassen
    -- wäre verwirrend, ein Reload mitten im Bosskill wäre schlimmer.
    button:SetEnabled(not InCombatLockdown())
    button:Show()
end

function EHS:StartButton()
    if not button then build() end

    local frame = CreateFrame("Frame")
    frame:RegisterEvent("PLAYER_REGEN_DISABLED")
    frame:RegisterEvent("PLAYER_REGEN_ENABLED")
    frame:SetScript("OnEvent", function()
        EHS:RefreshButton()
        EHS:RefreshOptions()
    end)

    -- Zählen kostet einen Durchlauf durch beide Historien, deshalb im Takt und
    -- nicht bei jedem Frame. Ein Ticker für alle drei Anzeigen: sie beantworten
    -- dieselbe Frage und dürfen nicht auseinanderlaufen.
    C_Timer.NewTicker(CHECK_SECONDS, function()
        EHS:RefreshButton()
        EHS:RefreshMinimap()
        EHS:RefreshOptions()
    end)
    self:RefreshButton()
end
