-- The EventHelper suggestion next to RCLootCouncil's voting frame
-- (RCLCSuggest.lua / RCLCSuggestUI.lua) against a mocked RCLootCouncil
-- voting module (lootTable, candidates, responses, voting frame):
-- no RCLC / other API -> nothing; a session start opens the docked panel;
-- ranking by response tier, BiS gap and (provisional) need; non-responders
-- greyed; candidates outside the council; caster/healer/none by BiS list and
-- by item stats; the category role filter text; response updates re-sort;
-- session switches in both directions; following the voting frame; the
-- setting and /ehc vorschlag; Latin-1 everywhere.
local EHS = EventHelperSync
local Suggest = EHS.Suggest
local FOREVER = WoWMock.flavor == "forever"

local function latin1(text)
    return not tostring(text or ""):find("[\196-\244]")
end

local NOW = WoWMock.now
local G = NOW - 7200 -- generatedAt of the council data
local DAY = 86400

local function link(id, name)
    return ("|cffa335ee|Hitem:%d::::::::70:::::|h[%s]|h|r"):format(id, name)
end

-- Item stats (GetItemStats) -----------------------------------------------------------------

local STATS = {
    [30003] = { ITEM_MOD_SPELL_HEALING_DONE_SHORT = 88, ITEM_MOD_SPELL_DAMAGE_DONE_SHORT = 30,
        ITEM_MOD_MANA_REGENERATION_SHORT = 6, ITEM_MOD_INTELLECT_SHORT = 20 },
    [30005] = { ITEM_MOD_SPELL_DAMAGE_DONE_SHORT = 20, ITEM_MOD_SPELL_HEALING_DONE_SHORT = 20,
        ITEM_MOD_HIT_SPELL_RATING_SHORT = 10 },
}
local statCalls = 0
local function getItemStats(itemLink)
    statCalls = statCalls + 1
    local id = tonumber(tostring(itemLink):match("item:(%d+)"))
    return STATS[id] or {}
end
if FOREVER then C_Item.GetItemStats = getItemStats else GetItemStats = getItemStats end

-- The stat rule on its own
expectEqual(Suggest.StatRole(STATS[30003]), "healer", "TBC healing gear: healing well above damage")
expectEqual(Suggest.StatRole(STATS[30005]), "caster", "spell hit")
expectEqual(Suggest.StatRole({ ITEM_MOD_SPELL_DAMAGE_DONE_SHORT = 40, ITEM_MOD_SPELL_HEALING_DONE_SHORT = 40 }), "caster",
    "TBC spell power (damage = healing)")
expectEqual(Suggest.StatRole({ ITEM_MOD_SPELL_POWER_SHORT = 50 }), "caster", "retail spell power")
expectEqual(Suggest.StatRole({ ITEM_MOD_INTELLECT_SHORT = 12, ITEM_MOD_SPIRIT_SHORT = 10 }), "healer", "spirit, no spell damage")
expectEqual(Suggest.StatRole({ ITEM_MOD_INTELLECT_SHORT = 12 }), "caster", "intellect only")
expectEqual(Suggest.StatRole({ ITEM_MOD_STRENGTH_SHORT = 30, ITEM_MOD_STAMINA_SHORT = 20 }), nil, "plate: none")
expectEqual(Suggest.StatRole({}), nil, "token: no stats")
expectEqual(Suggest.StatRole(nil), nil, "unknown item")

-- The response tiers on their own
local tiers = {
    { 1, { text = "BiS" }, 1 }, { 1, { text = "Mainspec/Need" }, 1 }, { 2, { text = "Upgrade" }, 2 },
    { 2, { text = "Major Upgrade" }, 2 }, { 3, { text = "Minor Upgrade" }, 3 }, { 3, { text = "Kleines Upgrade" }, 3 },
    { 2, { text = "Offspec/Greed" }, 4 }, { 5, { text = "Transmog" }, 4 }, { 4, { text = "Pass" }, "pass" },
    { 6, { text = "Kein Interesse" }, "pass" }, { 1, { text = "Will haben", sort = 1 }, 1 },
    { 2, { text = "Nehme ich", sort = 2 }, 2 }, { 7, { text = "???", sort = 7 }, 4 }, { 3, nil, 3 },
    { "PASS", nil, "pass" }, { "AUTOPASS", nil, "pass" }, { "NOTINRAID", nil, "pass" }, { "WAIT", nil, "waiting" },
    { "ANNOUNCED", nil, "waiting" }, { "TIMEOUT", nil, "waiting" }, { nil, nil, "waiting" },
}
for _, case in ipairs(tiers) do
    expectEqual(Suggest.ResponseTier(case[1], case[2]), case[3],
        "tier of " .. tostring(case[1]) .. " " .. tostring(case[2] and case[2].text))
end

-- Council data: "TBC Montag" (casters only) and "Alle Raids" ----------------------------------

--- The same four raiders in both categories; in "Alle Raids" Naphfss plays
--- resto (healer) and misses the healer slippers.
local function raiders(allRoles)
    local function r(fields)
        local out = {
            specLabel = "", role = "caster", parts = { drought = 50, share = 50, need = 50 }, lootCount = 1,
            lootTotal = 1, otherCount = 0, lastAwardAt = G - 12 * DAY, daysSinceLoot = 12, items = {},
        }
        for k, v in pairs(fields) do out[k] = v end
        return out
    end
    return {
        r({ key = "gemli", character = "Gemli", classFile = "PRIEST", specLabel = "Shadow", need = 82,
            bis = { owned = 5, total = 16, missing = { 30000 } } }),
        r({ key = "zibbo", character = "Zibbo", classFile = "MAGE", specLabel = "Fire", need = 64, lastAwardAt = G - 2 * DAY,
            daysSinceLoot = 2, bis = { owned = 6, total = 16, missing = { 30000, 30002 } } }),
        r({ key = "wlok", character = "Wlok", classFile = "WARLOCK", specLabel = "Destro", need = 71, lastAwardAt = 0,
            daysSinceLoot = -1, bis = { owned = 4, total = 16, missing = { 30001, 30002 } } }),
        allRoles
            and r({ key = "naphfss", character = "Naphfss", classFile = "DRUID", specLabel = "Resto", role = "healer",
                need = 58, bis = { owned = 7, total = 16, missing = { 30003 } } })
            or r({ key = "naphfss", character = "Naphfss", classFile = "DRUID", specLabel = "Balance", need = 58,
                bis = { owned = 7, total = 16, missing = { 30000 } } }),
    }
end

EventHelperSync_Council = {
    format = "eventhelper-council", version = 2, generatedAt = G,
    weights = { drought = 50, share = 40, need = 10 },
    categories = {
        { id = "1", name = "TBC Montag", lootSystem = "lootcouncil", filter = { role = "caster" },
            instances = { { id = "kara", name = "Karazhan", short = "Kara", zoneNames = {} } }, avgLootCount = 1,
            raiders = raiders() },
        { id = "2", name = "Alle Raids", lootSystem = "lootcouncil", filter = { role = "" },
            instances = {}, avgLootCount = 1, raiders = raiders(true) },
    },
}

WoWMock.Fire("ADDON_LOADED", "EventHelperSync")
WoWMock.Fire("PLAYER_LOGIN")
EHS.db.settings.councilCategory = "1"

-- No RCLootCouncil: nothing ------------------------------------------------------------------

expect(not EventHelperSyncSuggestFrame, "no panel without RCLootCouncil")
expectEqual(EHS:StartSuggest(), false, "nothing to hook")
-- another API (no voting module with a loot table): still nothing
RCLootCouncil = { GetActiveModule = function() return {} end }
WoWMock.Fire("ADDON_LOADED", "RCLootCouncil_Classic")
expectEqual(EHS:StartSuggest(), false, "unknown RCLC API: no hooks")
expect(not EventHelperSyncSuggestFrame, "still no panel")
RCLootCouncil = nil

-- by hand without RCLC: the panel says so
SlashCmdList.EVENTHELPERCOUNCIL("vorschlag")
local panel = EventHelperSyncSuggestFrame
expect(panel and panel:IsShown(), "/ehc vorschlag opens the panel by hand")
expectEqual(panel.header:GetText(), "RCLootCouncil ist nicht geladen.", "no RCLC header")
expect(panel.message:GetText():find("sobald in RCLootCouncil eine Abstimmung", 1, true), "no RCLC message")
expectEqual(panel.title:GetText(), "EventHelper-Vorschlag", "title")
expectEqual(panel:GetWidth(), 320, "about 320 px wide")
SlashCmdList.EVENTHELPERCOUNCIL("vorschlag")
expect(not panel:IsShown(), "/ehc vorschlag closes it again")

-- A mocked RCLootCouncil voting module ---------------------------------------------------------

local lootTable = {}
local current = 1
local vf = {}
vf.frame = CreateFrame("Frame", "DefaultRCLootCouncilFrame", UIParent)
vf.frame.content = CreateFrame("Frame", nil, vf.frame)
vf.frame:Hide()
function vf:GetLootTable() return lootTable end
function vf:GetCurrentSession() return current end
function vf:SwitchSession(s) current = s end
local noSession = false
function vf:Show()
    if noSession then return end
    self.frame:Show()
    WoWMock.Run(self.frame, "OnShow")
end
function vf:Hide() self.frame:Hide() WoWMock.Run(self.frame, "OnHide") end
function vf:ReceiveLootTable(lt)
    lootTable = lt
    self:SwitchSession(1)
    self:Show()
end
function vf:EndSession(hide) if hide then self:Hide() end end
function vf:OnResponseReceived(name, ses, data)
    for k, v in pairs(data) do lootTable[ses].candidates[name][k] = v end
end
function vf:OnChangeResponseReceived(ses, name, response) lootTable[ses].candidates[name].response = response end
function vf:OnAwardedReceived(ses, winner) lootTable[ses].awarded = winner end
-- the frame scripts the addon hooks (HookScript needs a script to hook in the game, too)
vf.frame:SetScript("OnShow", function() end)
vf.frame:SetScript("OnHide", function() end)
WoWMock.Run = function(widget, script, ...)
    if widget.__scripts[script] then widget.__scripts[script](widget, ...) end
    for _, fn in ipairs(widget.__hooks[script] or {}) do fn(widget, ...) end
end

local RESPONSES = {
    default = {
        { text = "BiS", sort = 1 }, { text = "Upgrade", sort = 2 }, { text = "Kleines Upgrade", sort = 3 },
        { text = "Offspec", sort = 4 },
    },
    TOKEN = { { text = "Will haben", sort = 1 }, { text = "Nehme ich", sort = 2 } },
}
local getResponseCalls = 0
RCLootCouncil = {
    GetActiveModule = function(_, name) if name == "votingframe" then return vf end end,
    GetResponse = function(_, kind, id)
        getResponseCalls = getResponseCalls + 1
        local set = RESPONSES[kind] or RESPONSES.default
        return set[id] or {}
    end,
}
WoWMock.Fire("ADDON_LOADED", "RCLootCouncil_Classic")
expectEqual(EHS:StartSuggest(), true, "hooked into the voting module")

local function cand(class, response, diff)
    return { class = class, response = response, diff = diff, votes = 0, ilvl = 120 }
end
local function session()
    return {
        { link = link(30000, "Zhar'doom, Greatstaff of the Devourer"), texture = 135000, quality = 4,
            equipLoc = "INVTYPE_2HWEAPON", candidates = {
                ["Gemli-Thunderstrike"] = cand("PRIEST", 1, 10), ["Zibbo-Thunderstrike"] = cand("MAGE", 1, 0),
                ["Wlok-Thunderstrike"] = cand("WARLOCK", 2, 13), ["Brakka-Thunderstrike"] = cand("WARRIOR", "PASS", ""),
                ["Naphfss-Thunderstrike"] = cand("DRUID", "WAIT", ""),
            } },
        { link = link(30001, "Shroud of the Highborne"), texture = 135001, quality = 4, equipLoc = "INVTYPE_CLOAK",
            candidates = {
                ["Wlok-Thunderstrike"] = cand("WARLOCK", 2, 23), ["Gemli-Thunderstrike"] = cand("PRIEST", 3, 5),
                ["Zibbo-Thunderstrike"] = cand("MAGE", 4, 0), ["Fremder-Otherrealm"] = cand("MAGE", 2, 8),
            } },
        { link = link(30002, "The Skull of Gul'dan"), texture = 135002, quality = 4, equipLoc = "INVTYPE_TRINKET",
            candidates = {
                ["Gemli-Thunderstrike"] = cand("PRIEST", "ANNOUNCED", ""), ["Zibbo-Thunderstrike"] = cand("MAGE", "ANNOUNCED", ""),
                ["Wlok-Thunderstrike"] = cand("WARLOCK", "ANNOUNCED", ""),
            } },
        { link = link(30003, "Slippers of the Seacaller"), texture = 135003, quality = 4, equipLoc = "INVTYPE_FEET",
            candidates = { ["Naphfss-Thunderstrike"] = cand("DRUID", 1, 10), ["Gemli-Thunderstrike"] = cand("PRIEST", "WAIT", "") } },
        { link = link(30004, "Helm of the Fallen Champion"), texture = 135004, quality = 4, typeCode = "TOKEN",
            equipLoc = "", candidates = {
                ["Gemli-Thunderstrike"] = cand("PRIEST", 2, ""), ["Zibbo-Thunderstrike"] = cand("MAGE", 1, ""),
            } },
        { link = link(30005, "Band of the Eternal Sage"), texture = 135005, quality = 4, equipLoc = "INVTYPE_FINGER",
            candidates = {
                ["Wlok-Thunderstrike"] = cand("WARLOCK", 1, 4), ["Gemli-Thunderstrike"] = cand("PRIEST", "AUTOPASS", ""),
            } },
    }
end

-- Session start: the panel opens, docked at the voting frame -------------------------------------

vf:ReceiveLootTable(session())
expect(vf.frame:IsShown(), "voting frame open")
expect(panel:IsShown(), "panel opens with the session")
local point, relativeTo, relativePoint = panel:GetPoint()
expect(point == "TOPLEFT" and relativeTo == vf.frame and relativePoint == "TOPRIGHT", "docked to the right edge of the voting frame")
expect(panel.header:GetText():find("^Sitzung: 6 Items · Stand "), "header: " .. tostring(panel.header:GetText()))
expect(not panel.header:GetText():find("vorläufig", 1, true), "no provisional awards yet")
expect(panel.category:IsShown(), "category button")
expectEqual(plain(panel.category.label:GetText()), "TBC Montag", "active category")
expectEqual(panel.footer:GetText(), "Reihenfolge: RCLC-Antwort, dann BiS-Lücke, dann Bedarf. Vergeben wird weiter in RCLootCouncil.", "footer")

local itemRows, suggRows = panel.itemRows, panel.suggRows
local function visibleItems()
    local out = {}
    for _, row in ipairs(itemRows) do if row:IsShown() then out[#out + 1] = row end end
    return out
end
local function suggestions()
    local out = {}
    for _, row in ipairs(suggRows) do
        if row:IsShown() then
            out[#out + 1] = { name = plain(row.name:GetText()), reason = row.reason:GetText(), need = plain(row.need:GetText()),
                muted = row.__alpha < 1, needLabel = row.needLabel:IsShown(), data = row.data }
        end
    end
    return out
end
local function names()
    local out = {}
    for _, s in ipairs(suggestions()) do out[#out + 1] = s.data.name end
    return table.concat(out, ",")
end
local function selectedRow()
    for _, row in ipairs(itemRows) do
        if row:IsShown() and row.selectedBg:IsShown() then return row end
    end
end

expectEqual(#visibleItems(), 5, "five item rows visible (six items, mouse wheel)")
expectEqual(selectedRow(), itemRows[1], "first item selected")
expectEqual(itemRows[1].name:GetText(), "|cffa335eeZhar'doom, Greatstaff of the Devourer|r", "name in quality colour, no brackets")
expectEqual(itemRows[1].icon.__texture, 135000, "icon")
expectEqual(itemRows[1].tag.label:GetText(), "Caster", "caster by BiS list")
expectEqual(itemRows[1].hint:GetText(), "Vorschlag: Gemli (BiS, Bedarf 82)", "hint of item 1")

-- Ranking: tier, BiS gap, need; passers out; non-responders with a BiS gap greyed at the bottom
expectEqual(names(), "Gemli,Zibbo,Wlok,Naphfss", "ranking of the staff")
local s = suggestions()
expectEqual(s[1].name, "Gemli Shadow", "name + spec")
expectEqual(s[1].reason, "Antwort BiS · BiS fehlt · +10 iLvl · letztes Item vor 12 Tagen", "reason line 1")
expectEqual(s[1].need, "82", "need")
expectEqual(s[2].reason, "Antwort BiS · BiS fehlt · +0 iLvl · letztes Item vor 2 Tagen", "reason line 2")
expectEqual(s[3].reason, "Antwort Upgrade · nicht auf BiS-Liste · +13 iLvl · noch kein Item", "reason line 3")
expect(not s[1].muted and not s[3].muted, "responders not greyed")
expect(s[4].muted, "non-responder greyed")
expectEqual(s[4].reason, "BiS fehlt, aber noch keine Antwort in RCLC", "non-responder reason")
expectEqual(panel.note:GetText(), "Wlok hat mehr Bedarf als Zibbo, steht aber hinter BiS-Antworten.", "explanation")
expectEqual(panel.message:GetText(), "", "no message")
expectEqual(suggRows[1].rank:GetText(), "1", "rank badge")

-- Item 2: non-council candidate below same-tier council raiders, minor upgrade explanation, offspec greyed
vf:SwitchSession(2)
expectEqual(selectedRow(), itemRows[2], "RCLC session switch selects the row")
expectEqual(names(), "Wlok,Fremder,Gemli,Zibbo", "ranking of the cloak")
s = suggestions()
expectEqual(s[1].reason, "Antwort Upgrade · BiS fehlt · +23 iLvl · noch kein Item", "Wlok BiS gap")
expectEqual(s[2].reason, "Antwort Upgrade · nicht im Council · +8 iLvl", "outsider reason")
expect(s[2].need == "" and not s[2].needLabel, "outsider: no need number")
expectEqual(s[3].reason, "Antwort Kleines Upgrade · +5 iLvl · letztes Item vor 12 Tagen", "minor upgrade")
expect(s[4].muted and s[4].reason:find("^Antwort Offspec"), "offspec greyed")
expectEqual(panel.note:GetText(), "Gemli hat mehr Bedarf, will das Item aber nur als kleines Upgrade.", "explanation 2")
expectEqual(itemRows[2].hint:GetText(), "Vorschlag: Wlok (Upgrade, Bedarf 71)", "hint of item 2")

-- Item 3: nobody answered yet
expectEqual(itemRows[3].hint:GetText(), "Noch keine Antworten in RCLC", "hint of item 3")
WoWMock.Click(itemRows[3])
expectEqual(current, 3, "clicking a row switches RCLC's session too")
expectEqual(selectedRow(), itemRows[3], "and selects it")
expectEqual(names(), "Wlok,Zibbo", "BiS gaps waiting, by need")
s = suggestions()
expect(not s[1].muted and s[1].reason == "BiS fehlt · wartet auf Antwort", "waiting rows not greyed while nobody answered")
expectEqual(panel.note:GetText(), "Sobald Antworten kommen, sortiert sich die Liste neu.", "waiting footer")

-- Item 4: healer item (stats) in a casters-only category
expectEqual(itemRows[4].tag.label:GetText(), "Heiler", "healer by stats")
expectEqual(itemRows[4].hint:GetText(), "Heiler-Item, Kategorie zählt nur Caster", "short blocked hint")
vf:SwitchSession(4)
expectEqual(#suggestions(), 0, "no suggestion for the healer item")
expectEqual(panel.message:GetText(),
    "Heiler-Item: Die Kategorie \"TBC Montag\" zeigt auf der Webseite nur Caster. Kein Vorschlag, in RCLootCouncil normal abstimmen.",
    "non-caster text")

-- Item 5 and 6 are below the fold: the list scrolls to the selection
vf:SwitchSession(5)
expectEqual(selectedRow(), itemRows[5], "item 5 visible")
expectEqual(selectedRow().tag.label:GetText(), "-", "token without stats: -")
expectEqual(names(), "Zibbo,Gemli", "custom buttons by their position")
expectEqual(suggestions()[1].reason, "Antwort Will haben · nicht auf BiS-Liste · letztes Item vor 2 Tagen",
    "custom button text, no iLvl without a diff")
vf:SwitchSession(6)
expectEqual(selectedRow(), itemRows[5], "scrolled: item 6 in the last row")
expectEqual(selectedRow().item.session, 6, "row shows session 6")
expectEqual(selectedRow().tag.label:GetText(), "Caster", "caster by stats")
expectEqual(names(), "Wlok", "autopass left out")
expectEqual(suggestions()[1].reason, "Antwort BiS · nicht auf BiS-Liste · +4 iLvl · noch kein Item", "ring reason")
WoWMock.Run(panel.itemList, "OnMouseWheel", 1)
expectEqual(itemRows[1].item.session, 1, "mouse wheel scrolls back up")
expect(statCalls > 0, "item stats asked")

-- Responses update the ranking --------------------------------------------------------------

vf:SwitchSession(1)
vf:OnResponseReceived("Naphfss-Thunderstrike", 1, { response = 1, diff = 6 })
expectEqual(names(), "Gemli,Zibbo,Naphfss,Wlok", "Naphfss answered BiS: above the upgrade")
expect(not suggestions()[3].muted, "no longer greyed")
vf:OnChangeResponseReceived(1, "Zibbo-Thunderstrike", 4)
expectEqual(names(), "Gemli,Naphfss,Wlok,Zibbo", "Zibbo changed to offspec")
expectEqual(panel.note:GetText(), "Wlok hat mehr Bedarf als Naphfss, steht aber hinter BiS-Antworten.", "new explanation")

-- Awarded in RCLC
vf:OnAwardedReceived(2, "Wlok-Thunderstrike")
expectEqual(itemRows[2].hint:GetText(), "Vergeben an Wlok", "awarded hint")

-- Live awards since the sync: provisional need with "*" ---------------------------------------

local rclcHistory = {}
RCLootCouncilLootDB = { factionrealm = { ["Alliance - Thunderstrike"] = rclcHistory } }
rclcHistory["Gemli-Thunderstrike"] = { { lootWon = link(29999, "Robe"), id = (NOW - 300) .. "-1", response = "BiS",
    responseID = 1, instance = "", boss = "Prince", class = "PRIEST" } }
EHS:RefreshSuggest()
expect(panel.header:GetText():find(" · 1 Vergabe vorläufig %*$"), "provisional header: " .. panel.header:GetText())
s = suggestions()
local gemli
for _, row in ipairs(s) do if row.data.name == "Gemli" then gemli = row end end
expect(gemli.need:find("%*$"), "provisional need marked: " .. gemli.need)
expect(gemli.reason:find("heute 1 Item *", 1, true), "today's item: " .. gemli.reason)
expect(tonumber(gemli.need:match("%d+")) < 82, "Gemli's need dropped after the award")
RCLootCouncilLootDB = nil
EHS:RefreshSuggest()

-- Category switch: the healer item gets a suggestion in "Alle Raids" ------------------------------

EHS:SetCouncilCategory("2")
expectEqual(plain(panel.category.label:GetText()), "Alle Raids", "category switched")
expectEqual(itemRows[4].hint:GetText(), "Vorschlag: Naphfss (BiS, Bedarf 58)", "healer item suggested without role filter")
expectEqual(itemRows[4].tag.label:GetText(), "Heiler", "healer by the BiS list")
EHS:SetCouncilCategory("1")

-- Following the voting frame ------------------------------------------------------------------

vf:Hide()
expect(not panel:IsShown(), "hidden with the voting frame")
noSession = true -- RCLC's Show() without a session: "No session running", the frame stays hidden
vf:Show()
expect(not panel:IsShown(), "no panel when RCLC's Show() shows nothing")
noSession = false
vf:Show()
expect(panel:IsShown(), "shown with the voting frame")
WoWMock.Click(panel.close)
expect(not panel:IsShown(), "x closes")
vf:Hide()
vf:Show()
expect(not panel:IsShown(), "stays closed for this session")
vf:ReceiveLootTable(session())
expect(panel:IsShown(), "a new session opens it again")
expectEqual(selectedRow(), itemRows[1], "new session: first item")

-- The setting and the slash commands ---------------------------------------------------------------

EHS.db.settings.rclcSuggest = false
WoWMock.Click(panel.close)
vf:ReceiveLootTable(session())
expect(not panel:IsShown(), "setting off: no auto open")
SlashCmdList.EVENTHELPERSYNC("vorschlag")
expect(panel:IsShown(), "/ehs vorschlag opens it")
expectEqual(#suggestions(), 4, "with the suggestion")
SlashCmdList.EVENTHELPERSYNC("suggest")
expect(not panel:IsShown(), "/ehs suggest closes it")
EHS.db.settings.rclcSuggest = true

-- No voting frame: a movable standalone panel --------------------------------------------------

local rcFrame = vf.frame
vf.frame = nil
DefaultRCLootCouncilFrame = nil
EHS:ShowSuggest()
point, relativeTo = panel:GetPoint()
expect(relativeTo == UIParent, "standalone without the voting frame")
WoWMock.Run(panel, "OnDragStart")
EHS.db.suggestPos = nil
WoWMock.Run(panel, "OnDragStop")
expect(EHS.db.suggestPos and EHS.db.suggestPos.point, "position remembered")
vf.frame = rcFrame
DefaultRCLootCouncilFrame = rcFrame

-- A broken RCLC never breaks the panel
vf.GetLootTable = function() error("boom") end
EHS:RefreshSuggest()
expectEqual(#visibleItems(), 0, "broken loot table: no rows, no error")

-- Latin-1: everything the panel shows ------------------------------------------------------------

vf.GetLootTable = function() return lootTable end
EHS:RefreshSuggest()
local texts = { panel.title:GetText(), panel.header:GetText(), panel.footer:GetText(), panel.note:GetText(),
    panel.message:GetText() }
for session = 1, 6 do
    vf:SwitchSession(session)
    texts[#texts + 1] = panel.note:GetText()
    texts[#texts + 1] = panel.message:GetText()
    for _, row in ipairs(itemRows) do texts[#texts + 1] = row.hint:GetText() end
    for _, row in ipairs(suggestions()) do texts[#texts + 1] = row.reason end
end
for _, text in ipairs(texts) do expect(latin1(text), "Latin-1: " .. tostring(text)) end
expect(getResponseCalls > 0, "response texts from RCLootCouncil:GetResponse")
