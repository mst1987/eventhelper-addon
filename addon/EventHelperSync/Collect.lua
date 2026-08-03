--[[
Die beiden Loot-Addons auslesen.

Beide Historien sind im Speicher erreichbar, sobald das jeweilige Addon geladen
ist — es braucht also keinen Export-Dialog. Die Feldnamen unten stammen aus dem
Quellcode der Addons:

  RCLootcouncil  Modules/History/lootHistory.lua speichert nach
                 addon.lootDB.factionrealm[<Spielername>] = { Eintrag, ... }.
                 Ein Eintrag: lootWon (Item-Link), date "tt/mm/jj",
                 time "hh:mm:ss", id "<servertime>-<n>", instance, boss, votes,
                 class, response, responseID, itemReplaced1/2, note, owner.
                 `servertime` ist der Teil von `id` vor dem "-" — genau so
                 macht es auch RCLootcouncils eigener JSON-Export.

  Gargul         Classes/AwardedLoot.lua schreibt nach
                 GargulDB.AwardHistory[<checksum>] = { checksum, itemLink,
                 itemID, awardedTo, awardedBy, timestamp, OS, received,
                 winnerClass, GDKPCost, BRCost, SR, Rolls, ... }.
                 GargulDB ist eine flache, accountweite Tabelle.

Beide werden auf dieselbe Zeilenform gebracht; welches Addon eine Zeile geliefert
hat, bleibt als `source` erhalten. Das ist wichtig: der EventHelper dedupliziert
über (source, rawId), und rawId ist hier dieselbe ID, die auch der jeweilige
Original-Export ausgibt (RCLootcouncils `id`, Garguls `checksum`). Ein Upload
über dieses Addon und ein von Hand eingefügter Export derselben Vergabe fallen
dadurch zu einem einzigen Item zusammen statt doppelt aufzutauchen.
]]

local EHS = EventHelperSync

--- Item-Name aus einem Item-Link, ohne auf den Item-Cache angewiesen zu sein.
-- GetItemInfo() liefert für ein Item, das der Client gerade nicht gecacht hat,
-- nil — der Name steht aber ohnehin im Link selbst.
local function nameFromLink(link)
    if type(link) ~= "string" then return "" end
    return link:match("%[(.-)%]") or ""
end

local function idFromLink(link)
    if type(link) ~= "string" then return nil end
    return tonumber(link:match("item:(%d+)"))
end

--- "[Ancestral Ring]" -> "Ancestral Ring"; leere Werte fallen weg.
local function gearList(...)
    local out = {}
    for i = 1, select("#", ...) do
        local entry = select(i, ...)
        if type(entry) == "string" and entry ~= "" then
            local clean = nameFromLink(entry)
            if clean == "" then clean = entry end
            if clean ~= "" then out[#out + 1] = clean end
        end
    end
    return out
end

--- Der Unix-Zeitstempel einer RCLootcouncil-Zeile.
-- Bevorzugt den servertime-Anteil der id; nur wenn der fehlt, wird aus
-- date+time gerechnet (die stehen in lokaler Zeit des Loot-Masters).
local function rclcTimestamp(entry)
    local servertime = tonumber(tostring(entry.id or ""):match("^(%d+)"))
    if servertime and servertime > 0 then return servertime end

    local d, m, y = tostring(entry.date or ""):match("^(%d+)/(%d+)/(%d+)$")
    if not d then return 0 end
    local hh, mm, ss = tostring(entry.time or ""):match("^(%d+):(%d+):(%d+)$")
    return time({
        year = 2000 + tonumber(y), month = tonumber(m), day = tonumber(d),
        hour = tonumber(hh) or 0, min = tonumber(mm) or 0, sec = tonumber(ss) or 0,
    })
end

--- RCLootcouncils Historie, über die Addon-API wenn möglich.
-- Die API liefert die bereits auf Fraktion+Realm eingegrenzte Tabelle; der
-- Rückfall auf die rohe SavedVariable muss diesen Schlüssel selbst bilden.
local function rclcHistory()
    local lib = LibStub and LibStub("AceAddon-3.0", true)
    local rclc = lib and lib:GetAddon("RCLootCouncil", true)
    if rclc and rclc.GetHistoryDB then
        local ok, db = pcall(rclc.GetHistoryDB, rclc)
        if ok and type(db) == "table" then return db end
    end

    local raw = _G.RCLootCouncilLootDB
    if type(raw) ~= "table" or type(raw.factionrealm) ~= "table" then return nil end
    local faction = UnitFactionGroup("player")
    local key = (faction or "") .. " - " .. (GetRealmName() or "")
    return raw.factionrealm[key]
end

--- Welche Quellen gerade überhaupt verfügbar sind (für die Statusausgabe).
function EHS:AvailableSources()
    return {
        rclc = rclcHistory() ~= nil,
        gargul = type(_G.GargulDB) == "table" and type(_G.GargulDB.AwardHistory) == "table",
    }
end

--- Ging dieses Item gar nicht an einen Raider, sondern in die Gildenbank oder
--- zum Entzaubern?
--
-- RCLootcouncil beantwortet das selbst: `isAwardReason` ist gesetzt, wenn ein
-- Item aus einem Grund vergeben wurde statt an einen Würfelgewinner — genau
-- das sind "Banking", "Disenchant" und was eine Gilde sonst als Award-Reason
-- einträgt. Auf den Antworttext zu prüfen wäre schlechter: jede Gilde benennt
-- ihn anders, und ein normaler "PvP/Bank"-Wurf ginge fälschlich mit weg.
local function isRclcHousekeeping(entry)
    return entry.isAwardReason == true or entry.isAwardReason == "true"
end

-- Gargul kennt kein solches Kennzeichen; es setzt für entzauberte Items einen
-- Pseudo-Empfänger ("||de||"). Alles in solchen Doppelbalken ist kein Spieler.
local function isGargulPlaceholder(winner)
    return type(winner) == "string" and winner:match("^||.*||$") ~= nil
end

local function collectRclc(rows, since)
    local db = rclcHistory()
    if not db then return 0 end

    local skip = EHS.db.settings.skipAwardReasons ~= false
    local count = 0
    for player, entries in pairs(db) do
        if type(entries) == "table" then
            for _, entry in pairs(entries) do
                if type(entry) == "table" then
                    local at = rclcTimestamp(entry)
                    local itemId = idFromLink(entry.lootWon)
                    if skip and at >= since and itemId and isRclcHousekeeping(entry) then
                        EHS.collectStats.skippedRclc = EHS.collectStats.skippedRclc + 1
                    elseif at >= since and itemId then
                        rows[#rows + 1] = {
                            source = "rclc",
                            rawId = tostring(entry.id or (itemId .. "-" .. at .. "-" .. player)),
                            itemId = itemId,
                            itemLink = entry.lootWon,
                            itemName = nameFromLink(entry.lootWon),
                            player = player,
                            class = entry.class or "",
                            response = entry.response or "",
                            -- responseID 4 ist in RCLootcouncil die Offspec-Antwort;
                            -- eine umbenannte Antwort ("Zweitspec") behält sie.
                            offspec = tostring(entry.responseID) == "4",
                            boss = entry.boss or "",
                            instance = entry.instance or "",
                            note = entry.note or "",
                            replacedGear = gearList(entry.itemReplaced1, entry.itemReplaced2),
                            awardedAt = at,
                            awardedBy = entry.owner or "",
                            votes = tonumber(entry.votes) or 0,
                        }
                        count = count + 1
                    end
                end
            end
        end
    end
    return count
end

local function collectGargul(rows, since)
    local db = _G.GargulDB
    local history = type(db) == "table" and db.AwardHistory or nil
    if type(history) ~= "table" then return 0 end

    local skip = EHS.db.settings.skipAwardReasons ~= false
    local count = 0
    -- Nach Checksum gekeyt, nicht als Liste — pairs(), nicht ipairs().
    for key, entry in pairs(history) do
        if type(entry) == "table" then
            local at = tonumber(entry.timestamp) or 0
            local itemId = tonumber(entry.itemID) or idFromLink(entry.itemLink)
            local winner = entry.awardedTo or ""
            if skip and at >= since and itemId and isGargulPlaceholder(winner) then
                EHS.collectStats.skippedGargul = EHS.collectStats.skippedGargul + 1
            elseif at >= since and itemId and winner ~= "" then
                rows[#rows + 1] = {
                    source = "gargul",
                    rawId = tostring(entry.checksum or key),
                    itemId = itemId,
                    itemLink = entry.itemLink,
                    itemName = nameFromLink(entry.itemLink),
                    player = winner,
                    class = entry.winnerClass or "",
                    -- Gargul kennt nur "Offspec ja/nein" — der EventHelper macht
                    -- daraus dieselben Loot-Gründe wie aus RCLootcouncils Text.
                    response = entry.OS and "Off Spec" or "Main Spec",
                    offspec = entry.OS == true,
                    boss = "",
                    instance = "",
                    note = "",
                    replacedGear = {},
                    awardedAt = at,
                    awardedBy = entry.awardedBy or "",
                    -- GDKP-Preis: hier eine GDKP-Gilde, und der Wert ist nach
                    -- einem Leeren der Gargul-Historie nicht wiederherstellbar.
                    -- Reist im Format mit, auch wenn der Server ihn (noch) nicht
                    -- auswertet.
                    gdkpCost = tonumber(entry.GDKPCost) or nil,
                }
                count = count + 1
            end
        end
    end
    return count
end

--- Alle Vergaben der letzten `lookbackDays`, aus beiden Addons.
-- Nebenbei wird in EHS.collectStats festgehalten, wie viel wovon kam und wie
-- viel aussortiert wurde — das Optionsfenster und /ehs diag zeigen es an.
function EHS:CollectRows()
    local days = self.db.settings.lookbackDays or 21
    local since = time() - (days * 24 * 60 * 60)
    local rows = {}

    self.collectStats = { rclc = 0, gargul = 0, skippedRclc = 0, skippedGargul = 0 }
    local fromRclc = collectRclc(rows, since)
    local fromGargul = collectGargul(rows, since)
    self.collectStats.rclc = fromRclc
    self.collectStats.gargul = fromGargul
    self:Debug(("gesammelt: %d aus RCLootcouncil, %d aus Gargul, %d aussortiert"):format(
        fromRclc, fromGargul, self.collectStats.skippedRclc + self.collectStats.skippedGargul))

    table.sort(rows, function(a, b) return a.awardedAt < b.awardedAt end)
    return rows
end
