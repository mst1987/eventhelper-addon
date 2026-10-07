--[[
EventHelper-Vorschlag fuer RCLootCouncil - die Logik ohne Fenster.

Laeuft in RCLootCouncil eine Abstimmung, zeigt RCLCSuggestUI.lua neben dem
Abstimmungsfenster je Item einen Vorschlag: wer es nach den Council-Daten
(Bedarf, fehlende BiS-Teile) UND der eigenen Antwort in RCLootCouncil am
ehesten bekommen sollte. Vergeben wird weiter in RCLootCouncil.

Reihenfolge (vom Raidleiter so abgestimmt):
  1. die Antwort in RCLootCouncil, in vier Stufen:
       1 BiS / Need / Mainspec, 2 Upgrade, 3 kleines Upgrade,
       4 Offspec / Greed / Transmog; Passen faellt heraus,
  2. in derselben Stufe zuerst, wem das Item als BiS-Teil fehlt,
  3. dann der Bedarf aus den Council-Daten (mit den Vergaben seit dem Sync).
Wer nicht im Council steht, aber geantwortet hat, kommt hinter die
Council-Raider derselben Stufe. Wem das Item als BiS fehlt, der aber noch
nicht geantwortet hat, steht grau am Ende.

Ob ein Item ein Caster- oder Heiler-Item ist: steht es auf der BiS-Liste
eines Raiders der Kategorie, zaehlt dessen Rolle; sonst entscheiden die
Werte des Items (GetItemStats); Marken/Tokens ohne Werte bleiben "-".
Zeigt die Kategorie auf der Webseite nur eine Rolle, gibt es fuer Items der
anderen Rolle keinen Vorschlag.

Wie Council.lua ohne Client-Aufrufe ausser date(): die Werte des Items und
die Antworten aus RCLootCouncil reicht RCLCSuggestUI.lua herein.
]]

local EHS = EventHelperSync
local Council = EHS.Council

local Suggest = {}
EHS.Suggest = Suggest

local function num(value)
    return tonumber(value) or 0
end

local function int(value)
    return math.floor(num(value) + 0.5)
end

-- ---------------------------------------------------------------------------
-- Antworten aus RCLootCouncil
-- ---------------------------------------------------------------------------

Suggest.TIER_LABEL = { "BiS", "Upgrade", "Kleines Upgrade", "Offspec" }

-- Feste Antworten von RCLootCouncil (Text-Schluessel statt Knopf-Nummer):
-- diese heissen "hat noch nicht geantwortet" ...
local WAITING = {
    ANNOUNCED = true, NOTANNOUNCED = true, WAIT = true, TIMEOUT = true, NOTHING = true,
}
-- ... alle anderen (PASS, AUTOPASS, DISABLED, NOTINRAID, REMOVED,
-- NOTELIGIBLE, PL, PL_REJECT, BONUSROLL, AWARDED, DEFAULT) fallen heraus.

-- Der Grund einer Vergabe (Council.ReasonFor, die Regel des Servers) -> Stufe.
local REASON_TIER = {
    bis = 1, mainspec = 1, upgrade = 2, minor = 3,
    offspec = 4, pvp = 4, greed = 4, disenchant = 4, bank = 4,
}

-- Knopf-Texte, die "will ich nicht" heissen.
local PASS_PATTERNS = {
    "^%s*pass", "passen", "kein.?interesse", "not.?interested", "no.?interest", "verzicht",
}

--- Die Stufe einer Antwort.
-- @param response candidates[name].response aus RCLootCouncil: die Nummer
--   eines Knopfes oder ein fester Text-Schluessel ("PASS", "WAIT", ...)
-- @param info die Beschreibung des Knopfes ({ text, sort }) aus
--   RCLootCouncil:GetResponse(), oder nil
-- @return 1..4, "waiting" (noch keine Antwort) oder "pass" (faellt heraus)
function Suggest.ResponseTier(response, info)
    if response == nil then return "waiting" end
    if type(response) == "string" and not tonumber(response) then
        if WAITING[response:upper()] then return "waiting" end
        return "pass"
    end
    info = type(info) == "table" and info or {}
    local text = tostring(info.text or ""):lower()
    if text ~= "" then
        for _, pattern in ipairs(PASS_PATTERNS) do
            if text:find(pattern) then return "pass" end
        end
        local tier = REASON_TIER[Council.ReasonFor(text, false)]
        if tier then return tier end
    end
    -- Ein eigener Knopf mit unbekanntem Text: seine Position (sort, sonst die
    -- Nummer) - der erste Knopf ist in jeder Gilde der wichtigste.
    local position = tonumber(info.sort)
    if not position or position <= 0 or position >= 100 then position = tonumber(response) end
    if not position then return 4 end
    return math.max(1, math.min(4, math.floor(position)))
end

-- ---------------------------------------------------------------------------
-- Caster- oder Heiler-Item?
-- ---------------------------------------------------------------------------

--- Die Rolle nach den Werten des Items (GetItemStats: { ITEM_MOD_..._SHORT = n }).
-- TBC: Zauberschaden und Heilung stehen getrennt (Heiler-Items: viel Heilung,
-- wenig Schaden), Retail: Zaubermacht. Trefferwertung, Krit und Tempo fuer
-- Zauber oder Durchschlag heissen Caster; Mana-Regeneration oder Willenskraft
-- ohne Zauberschaden heissen Heiler; nur Intelligenz heisst Caster.
-- @return "caster" | "healer" | nil (keine Werte, oder kein Zauber-Item)
function Suggest.StatRole(stats)
    if type(stats) ~= "table" then return nil end
    local s = { heal = 0, dmg = 0, power = 0, regen = 0, spirit = 0, int = 0, casterOnly = 0 }
    for key, value in pairs(stats) do
        local k = tostring(key):upper():gsub("_SHORT$", "")
        local v = num(value)
        if v > 0 then
            if k:find("SPELL_HEALING_DONE", 1, true) then
                s.heal = s.heal + v
            elseif k:find("SPELL_DAMAGE_DONE", 1, true) then
                s.dmg = s.dmg + v
            elseif k:find("SPELL_POWER", 1, true) then
                s.power = s.power + v
            elseif k:find("MANA_REGENERATION", 1, true) or k:find("POWER_REGEN0", 1, true) then
                s.regen = s.regen + v
            elseif k:find("SPIRIT", 1, true) then
                s.spirit = s.spirit + v
            elseif k:find("INTELLECT", 1, true) then
                s.int = s.int + v
            elseif k:find("SPELL_RATING", 1, true) or k:find("SPELL_PENETRATION", 1, true) then
                s.casterOnly = s.casterOnly + v
            end
        end
    end
    if s.casterOnly > 0 then return "caster" end
    local damage = math.max(s.dmg, s.power)
    if s.heal > 0 and s.heal >= damage * 1.5 then return "healer" end
    if damage > 0 then return "caster" end
    if s.regen > 0 or s.spirit > 0 then return "healer" end
    if s.int > 0 then return "caster" end
    return nil
end

--- Die Rolle eines Items in einer Kategorie.
-- @param category die aktive Kategorie (oder nil)
-- @param stats die Werte aus GetItemStats (oder nil)
-- @return "caster" | "healer" | nil, Quelle "bis" | "stats" | nil
function Suggest.ItemRole(category, itemId, stats)
    if type(category) == "table" and tonumber(itemId) then
        local roles = {}
        for _, entry in ipairs(Council.ForItem(category, itemId)) do
            local role = entry.raider and entry.raider.role
            if role == "caster" or role == "healer" then roles[role] = true end
        end
        if roles.caster then return "caster", "bis" end
        if roles.healer then return "healer", "bis" end
    end
    local role = Suggest.StatRole(stats)
    if role then return role, "stats" end
    return nil, nil
end

Suggest.ROLE_TAG = { caster = "Caster", healer = "Heiler" }

--- Zeigt die Kategorie nur eine andere Rolle als die des Items? Dann der
--- Text fuer die Liste und der kurze fuer die Item-Zeile, sonst nil.
function Suggest.BlockedTexts(category, role)
    local filter = type(category) == "table" and type(category.filter) == "table" and category.filter or {}
    local only = Suggest.ROLE_TAG[filter.role]
    local own = Suggest.ROLE_TAG[role]
    if not only or not own or filter.role == role then return nil, nil end
    local long = ("%s-Item: Die Kategorie \"%s\" zeigt auf der Webseite nur %s. Kein Vorschlag, in RCLootCouncil "
        .. "normal abstimmen."):format(own, category.name or "", only)
    local short = ("%s-Item, Kategorie zählt nur %s"):format(own, only)
    return long, short
end

-- ---------------------------------------------------------------------------
-- Die Rangliste eines Items
-- ---------------------------------------------------------------------------

--- "Gemli-Thunderstrike" -> "Gemli"
function Suggest.ShortName(name)
    local text = tostring(name or "")
    local dash = text:find("-", 1, true)
    if dash and dash > 1 then text = text:sub(1, dash - 1) end
    return text
end

local function raidersByKey(category)
    local map = {}
    if type(category) ~= "table" or type(category.raiders) ~= "table" then return map end
    for _, raider in ipairs(category.raiders) do
        if type(raider) == "table" then
            for _, name in ipairs({ raider.character or "", raider.key or "" }) do
                local key = Council.NameKey(name)
                if key ~= "" and not map[key] then map[key] = raider end
            end
        end
    end
    return map
end

local function missesItem(raider, itemId)
    local missing = type(raider) == "table" and type(raider.bis) == "table" and raider.bis.missing
    if type(missing) ~= "table" or not itemId then return false end
    for _, id in ipairs(missing) do
        if tonumber(id) == itemId then return true end
    end
    return false
end

local function sameDay(a, b)
    return date("%Y-%m-%d", int(a)) == date("%Y-%m-%d", int(b))
end

--- "letztes Item vor 12 Tagen", "heute 1 Item *" (Vergaben seit dem Sync).
function Suggest.LastItemText(raider, now)
    if type(raider) ~= "table" then return nil end
    local provisional = raider.provisional
    if type(provisional) == "table" and num(provisional.counted) > 0 then
        local today, total = 0, 0
        for _, award in ipairs(provisional.awards or {}) do
            if award.counts then
                total = total + 1
                if sameDay(award.awardedAt, now) then today = today + 1 end
            end
        end
        if today == total then return ("heute %s *"):format(Council.ItemsLabel(today)) end
        return ("seit dem Sync %s *"):format(Council.ItemsLabel(total))
    end
    if num(raider.lastAwardAt) > 0 then
        return "letztes Item " .. Council.FormatAge(raider.lastAwardAt, now)
    end
    return "noch kein Item"
end

local function diffText(diff)
    local value = tonumber(diff)
    if not value then return nil end
    return ("%+d iLvl"):format(math.floor(value + 0.5))
end

local function responseLabel(row)
    if row.responseText and row.responseText ~= "" then return row.responseText end
    return Suggest.TIER_LABEL[row.tier] or "?"
end

local function reasonText(row, now)
    local parts = { "Antwort " .. responseLabel(row) }
    if row.raider then
        if row.bis then
            parts[#parts + 1] = "BiS fehlt"
        elseif row.tier <= 2 then
            parts[#parts + 1] = "nicht auf BiS-Liste"
        end
    else
        parts[#parts + 1] = "nicht im Council"
    end
    parts[#parts + 1] = diffText(row.diff)
    if row.raider then parts[#parts + 1] = Suggest.LastItemText(row.raider, now) end
    return table.concat(parts, " · ")
end

local function compareResponders(a, b)
    if a.tier ~= b.tier then return a.tier < b.tier end
    local ca, cb = a.raider ~= nil, b.raider ~= nil
    if ca ~= cb then return ca end
    if a.bis ~= b.bis then return a.bis end
    local na, nb = num(a.need), num(b.need)
    if na ~= nb then return na > nb end
    return a.name < b.name
end

local function compareWaiting(a, b)
    local na, nb = num(a.need), num(b.need)
    if na ~= nb then return na > nb end
    return a.name < b.name
end

--- Warum jemand mit mehr Bedarf weiter unten steht: der erste in der Liste,
--- ueber dem jemand mit weniger Bedarf steht (beide im Council).
local function explanation(responders)
    for j = 2, #responders do
        local b = responders[j]
        if b.raider then
            for i = 1, j - 1 do
                local a = responders[i]
                if a.raider and num(b.need) > num(a.need) then
                    if b.tier > a.tier then
                        if b.tier == 3 then
                            return ("%s hat mehr Bedarf, will das Item aber nur als kleines Upgrade."):format(b.name)
                        elseif b.tier == 4 then
                            return ("%s hat mehr Bedarf, will das Item aber nur für Offspec."):format(b.name)
                        end
                        return ("%s hat mehr Bedarf als %s, steht aber hinter %s-Antworten."):format(
                            b.name, a.name, Suggest.TIER_LABEL[a.tier])
                    end
                    if a.bis and not b.bis then
                        return ("%s hat mehr Bedarf als %s, aber %s fehlt das Item auf der BiS-Liste."):format(
                            b.name, a.name, a.name)
                    end
                end
            end
        end
    end
    return nil
end

Suggest.WAITING_FOOTER = "Sobald Antworten kommen, sortiert sich die Liste neu."
Suggest.NO_RESPONSES = "Noch keine Antworten in RCLC"

--- Die Rangliste fuer ein Item der Sitzung.
-- @param item { itemId, awarded (Name oder nil), stats (GetItemStats),
--   candidates = { { name ("Name-Realm"), class (classFile), response,
--   responseText, info ({ text, sort }), diff }, ... } }
-- @param category die aktive Kategorie (mit den Vergaben seit dem Sync), oder nil
-- @param now Zeitpunkt (time())
-- @return { role, roleSource, tag, blocked (Text) | nil, hint, rows = { {
--   name, classFile, specLabel, need (nil ausserhalb des Council), mark,
--   reason, tier ("waiting" bei grauen Zeilen), muted, raider } },
--   responders = Zahl, note (Erklaerung/Hinweis unter der Liste) | nil }
function Suggest.Build(item, category, now)
    item = type(item) == "table" and item or {}
    local itemId = tonumber(item.itemId)
    local out = { rows = {}, responders = 0 }
    out.role, out.roleSource = Suggest.ItemRole(category, itemId, item.stats)
    out.tag = Suggest.ROLE_TAG[out.role] or "-"

    -- RCLootCouncil: awarded = Name des Gewinners, true = "spaeter vergeben".
    local awardedHint
    if type(item.awarded) == "string" and item.awarded ~= "" then
        awardedHint = "Vergeben an " .. Suggest.ShortName(item.awarded)
    elseif item.awarded then
        awardedHint = "Wird später vergeben"
    end

    local blocked, short = Suggest.BlockedTexts(category, out.role)
    if blocked then
        out.blocked = blocked
        out.hint = awardedHint or short
        return out
    end

    local byKey = raidersByKey(category)
    local responders, waiting = {}, {}
    local anyWaiting = false
    for _, candidate in ipairs(type(item.candidates) == "table" and item.candidates or {}) do
        local tier = Suggest.ResponseTier(candidate.response, candidate.info)
        local raider = byKey[Council.NameKey(candidate.name)]
        local row = {
            name = raider and raider.character or Suggest.ShortName(candidate.name),
            classFile = raider and raider.classFile ~= "" and raider.classFile or candidate.class,
            specLabel = raider and raider.specLabel or "",
            need = raider and int(raider.need) or nil,
            mark = raider and Council.ProvisionalMark(raider) or "",
            raider = raider,
            bis = raider ~= nil and missesItem(raider, itemId),
            diff = candidate.diff,
            responseText = candidate.responseText,
        }
        if tier == "waiting" then
            anyWaiting = true
            if row.raider and row.bis then
                row.tier = "waiting"
                waiting[#waiting + 1] = row
            end
        elseif type(tier) == "number" then
            row.tier = tier
            row.muted = tier >= 4
            responders[#responders + 1] = row
        end
    end
    table.sort(responders, compareResponders)
    table.sort(waiting, compareWaiting)
    out.responders = #responders

    for _, row in ipairs(responders) do
        row.reason = reasonText(row, now)
        out.rows[#out.rows + 1] = row
    end
    for _, row in ipairs(waiting) do
        if #responders > 0 then
            row.muted = true
            row.reason = "BiS fehlt, aber noch keine Antwort in RCLC"
        else
            row.reason = "BiS fehlt · wartet auf Antwort"
        end
        out.rows[#out.rows + 1] = row
    end

    if #responders > 0 then
        out.note = explanation(responders)
    elseif #waiting > 0 or anyWaiting then
        out.note = Suggest.WAITING_FOOTER
    end

    local top = responders[1]
    if awardedHint then
        out.hint = awardedHint
    elseif top then
        local detail = top.need and ("Bedarf %d"):format(top.need) or "nicht im Council"
        out.hint = ("Vorschlag: %s (%s, %s)"):format(top.name, responseLabel(top), detail)
    elseif anyWaiting then
        out.hint = Suggest.NO_RESPONSES
    else
        out.hint = "Keine Antwort mit Bedarf in RCLC"
    end
    return out
end

--- Kopfzeile: "Sitzung: 4 Items · Stand 21:48 · 1 Vergabe vorläufig *".
function Suggest.Header(itemCount, data, category, now)
    local parts = { "Sitzung: " .. Council.ItemsLabel(itemCount) }
    local at = int(type(data) == "table" and data.generatedAt)
    if at > 0 then
        if sameDay(at, now) then
            parts[#parts + 1] = "Stand " .. date("%H:%M", at)
        else
            parts[#parts + 1] = "Stand " .. Council.FormatStamp(at)
        end
    elseif not data then
        parts[#parts + 1] = "keine Council-Daten"
    end
    local provisional = type(category) == "table" and num(category.provisional) or 0
    if provisional > 0 then
        parts[#parts + 1] = Council.AwardsLabel(provisional) .. " vorläufig *"
    end
    return table.concat(parts, " · ")
end

Suggest.FOOTER = "Reihenfolge: RCLC-Antwort, dann BiS-Lücke, dann Bedarf. Vergeben wird weiter in RCLootCouncil."
