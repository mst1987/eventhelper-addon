--[[
Guild bank handouts - the logic without a window (GuildBankUI.lua shows it).

The list comes from the EventHelper server, not from the game: the sync tool
fetches the confirmed guild bank requests and writes them as GuildBankData.lua
into this folder (format "eventhelper-guildbank-handouts", version 1, see
README). After the next /reload they are in the global
EventHelperSync_GuildBankHandouts:

  { format, version, generatedAt,
    banks = { { key, gameVersion, realm, guild, faction, scannedAt,
                handouts = { { id, itemId, name, icon, quality, amount, purpose,
                               character = { name, realm, faction, classFile } or nil,
                               requestedBy, requestedAt, confirmedBy, confirmedAt,
                               inBank, tabs = { { index, name, count } } } } } } }

What is ticked off in game goes to EventHelperSyncDB.guildBankDone,
{ [id] = { id, via = "manual" | "mail", by = "Name-Realm", at = time() } };
the sync tool reports it (POST) once WoW has written the SavedVariables. An
entry is dropped here once the downloaded list no longer has its id - then the
server knows it.

The API at the end (EHS:GetHandouts, EHS:MarkHandedOut, ...) is also meant for
handing out by mail (#18). Everything here runs without client calls except a
few guarded ones (realm, guild, item icon), so the specs can drive it.
]]

local EHS = EventHelperSync

local Handouts = {}
EHS.Handouts = Handouts

Handouts.FORMAT = "eventhelper-guildbank-handouts"
Handouts.VERSION = 1

Handouts.EMPTY_TEXT = {
    none = "Noch keine Ausgabe-Daten: EventHelper Sync auf dem PC laufen lassen, dann /reload.",
    format = "GuildBankData.lua ist unbrauchbar. In EventHelper Sync \"Ausgabeliste holen\", dann /reload.",
    version = "Die Ausgabe-Daten sind neuer als dieses Addon. Bitte das Addon aktualisieren.",
}

Handouts.QUESTION_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- Item quality colours, should a client lack ITEM_QUALITY_COLORS.
local QUALITY_COLORS = {
    [0] = { 0.62, 0.62, 0.62 }, [1] = { 1.00, 1.00, 1.00 }, [2] = { 0.12, 1.00, 0.00 },
    [3] = { 0.00, 0.44, 0.87 }, [4] = { 0.64, 0.21, 0.93 }, [5] = { 1.00, 0.50, 0.00 },
    [6] = { 0.90, 0.80, 0.50 }, [7] = { 0.00, 0.80, 1.00 },
}

local function num(value)
    return tonumber(value) or 0
end

local function int(value)
    return math.floor(num(value) + 0.5)
end

local function str(value)
    if value == nil then return "" end
    return tostring(value)
end

local function call(fn, ...)
    if type(fn) ~= "function" then return false end
    return pcall(fn, ...)
end

local function try(fn, ...)
    local ok, value = call(fn, ...)
    if ok then return value end
    return nil
end

-- ---------------------------------------------------------------------------
-- Data
-- ---------------------------------------------------------------------------

--- The handout data, if usable.
-- @param raw optional, else the global from GuildBankData.lua
-- @return data|nil, status  status: "ok" | "none" | "format" | "version"
function Handouts.Load(raw)
    if raw == nil then raw = _G.EventHelperSync_GuildBankHandouts end
    if type(raw) ~= "table" then return nil, "none" end
    if raw.format ~= Handouts.FORMAT or type(raw.banks) ~= "table" then return nil, "format" end
    local version = tonumber(raw.version)
    if not version then return nil, "format" end
    if version > Handouts.VERSION then return nil, "version" end
    return raw, "ok"
end

--- Realm as the server compares it: lower case, no blanks, apostrophes or dashes.
function Handouts.RealmKey(realm)
    return (str(realm):lower():gsub("[%s'%-]", ""))
end

--- Guild name as the server compares it: lower case, blanks collapsed.
function Handouts.GuildKey(name)
    return (str(name):lower():gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

--- This character: client project, realm and guild (empty if unknown).
function Handouts.Client()
    local project = EHS.ClientProject and EHS:ClientProject() or ""
    local realm = try(GetNormalizedRealmName)
    if not realm or realm == "" then realm = str(try(GetRealmName)) end
    return { project = project, realm = realm, guild = str(try(GetGuildInfo, "player")) }
end

local function sameBank(bank, project, realm, guild)
    return str(bank.gameVersion) == str(project)
        and Handouts.RealmKey(bank.realm) == Handouts.RealmKey(realm)
        and guild ~= "" and Handouts.GuildKey(bank.guild) == Handouts.GuildKey(guild)
end

--- The banks to show for a character.
-- @return banks, scope  scope: "match" (its guild bank on this client),
--   "version" (none of its guild, the banks of this client), "all" (no bank
--   of this client, all of them), "none" (the data lists no bank)
function Handouts.Banks(data, client)
    local all = {}
    if type(data) == "table" and type(data.banks) == "table" then
        for _, bank in ipairs(data.banks) do
            if type(bank) == "table" then all[#all + 1] = bank end
        end
    end
    if #all == 0 then return all, "none" end
    client = client or {}
    local match, version = {}, {}
    for _, bank in ipairs(all) do
        if sameBank(bank, client.project, client.realm, str(client.guild)) then match[#match + 1] = bank end
        if str(bank.gameVersion) == str(client.project) then version[#version + 1] = bank end
    end
    if #match > 0 then return match, "match" end
    if #version > 0 then return version, "version" end
    return all, "all"
end

local function copyTabs(tabs)
    local out = {}
    if type(tabs) ~= "table" then return out end
    for _, tab in ipairs(tabs) do
        if type(tab) == "table" then
            out[#out + 1] = { index = int(tab.index), name = str(tab.name), count = int(tab.count) }
        end
    end
    return out
end

local function byRecipient(a, b)
    local ra, rb = a.recipient:lower(), b.recipient:lower()
    if ra ~= rb then return ra < rb end
    if a.confirmedAt ~= b.confirmedAt then return a.confirmedAt < b.confirmedAt end
    return a.id < b.id
end

--- One flat, sorted list of the handouts of these banks.
-- Entry: { id, itemId, name, icon, quality, amount, purpose, character,
--   hasCharacter, recipient, recipientRealm, classFile, requestedBy,
--   requestedAt, confirmedBy, confirmedAt, inBank, tabs, bankKey, gameVersion,
--   bankRealm, bankGuild, faction, scannedAt, done, count, live, stockTabs,
--   left, short }
-- @param opts { done = guildBankDone map, live = function(entry) -> count, tabs | nil }
function Handouts.Entries(banks, opts)
    opts = opts or {}
    local done = type(opts.done) == "table" and opts.done or {}
    local list = {}
    for _, bank in ipairs(banks or {}) do
        for _, h in ipairs(type(bank.handouts) == "table" and bank.handouts or {}) do
            if type(h) == "table" and h.id ~= nil and str(h.id) ~= "" then
                local character = type(h.character) == "table" and h.character or nil
                local charName = character and str(character.name) or ""
                local id = str(h.id)
                local itemId = int(h.itemId)
                local entry = {
                    id = id,
                    itemId = itemId,
                    name = str(h.name) ~= "" and str(h.name) or ("Item " .. itemId),
                    icon = str(h.icon),
                    quality = tonumber(h.quality) or -1,
                    amount = math.max(1, int(h.amount)),
                    purpose = str(h.purpose),
                    character = character,
                    hasCharacter = charName ~= "",
                    recipient = charName ~= "" and charName or (str(h.requestedBy) ~= "" and str(h.requestedBy) or "?"),
                    recipientRealm = character and str(character.realm) or "",
                    classFile = character and str(character.classFile) or "",
                    requestedBy = str(h.requestedBy),
                    requestedAt = int(h.requestedAt),
                    confirmedBy = str(h.confirmedBy),
                    confirmedAt = int(h.confirmedAt),
                    inBank = int(h.inBank),
                    tabs = copyTabs(h.tabs),
                    bankKey = str(bank.key),
                    gameVersion = str(bank.gameVersion),
                    bankRealm = str(bank.realm),
                    bankGuild = str(bank.guild),
                    faction = str(bank.faction),
                    scannedAt = int(bank.scannedAt),
                }
                entry.done = type(done[id]) == "table" and done[id] or nil
                list[#list + 1] = entry
            end
        end
    end
    table.sort(list, byRecipient)

    -- Stock: the live count of the open guild bank if there is one, else the
    -- server's. Open entries of the same item share it in list order: the
    -- second one only gets what the first leaves.
    local demand = {}
    for _, entry in ipairs(list) do
        local count, tabs
        if opts.live then count, tabs = opts.live(entry) end
        entry.live = count ~= nil
        entry.count = count ~= nil and int(count) or entry.inBank
        entry.stockTabs = tabs or entry.tabs
        local key = entry.bankKey .. "|" .. entry.itemId
        local before = demand[key] or 0
        entry.left = math.max(0, entry.count - before)
        if entry.done then
            entry.short = false
        else
            entry.short = entry.left < entry.amount
            demand[key] = before + entry.amount
        end
    end
    return list
end

--- The entries grouped by recipient, in list order.
-- @return { { recipient, recipientRealm, classFile, character, hasCharacter,
--   entries = { entry, ... }, amount = sum of amounts } }
function Handouts.Group(entries)
    local groups, byKey = {}, {}
    for _, entry in ipairs(entries or {}) do
        local key = entry.recipient:lower() .. "|" .. Handouts.RealmKey(entry.recipientRealm)
        local group = byKey[key]
        if not group then
            group = {
                recipient = entry.recipient, recipientRealm = entry.recipientRealm, classFile = entry.classFile,
                character = entry.character, hasCharacter = entry.hasCharacter, entries = {}, amount = 0,
            }
            byKey[key] = group
            groups[#groups + 1] = group
        end
        group.entries[#group.entries + 1] = entry
        group.amount = group.amount + entry.amount
    end
    return groups
end

--- The items of a guild bank scan: itemId -> { count, tabs = { { index, name, count } } }.
function Handouts.ScanStock(scan)
    local stock = {}
    if type(scan) ~= "table" or type(scan.tabs) ~= "table" then return stock end
    for _, tab in ipairs(scan.tabs) do
        for _, item in ipairs(type(tab.items) == "table" and tab.items or {}) do
            local id = int(item.itemId)
            if id > 0 then
                local s = stock[id]
                if not s then
                    s = { count = 0, tabs = {}, byTab = {} }
                    stock[id] = s
                end
                s.count = s.count + int(item.count)
                local t = s.byTab[tab.index]
                if not t then
                    t = { index = int(tab.index), name = str(tab.name), count = 0 }
                    s.byTab[tab.index] = t
                    s.tabs[#s.tabs + 1] = t
                end
                t.count = t.count + int(item.count)
            end
        end
    end
    return stock
end

--- A live-stock function for Handouts.Entries, or nil. Only while the guild
-- bank is open and the scan is from this visit (scannedAt >= openedAt), and
-- only for entries of the bank that was scanned.
function Handouts.LiveSource(scan, isOpen, openedAt)
    if not isOpen or type(scan) ~= "table" or num(scan.scannedAt) < num(openedAt) then return nil end
    local guild = type(scan.guild) == "table" and scan.guild or {}
    local project = type(scan.client) == "table" and scan.client.project or ""
    local stock = Handouts.ScanStock(scan)
    return function(entry)
        if entry.gameVersion ~= str(project)
            or Handouts.RealmKey(entry.bankRealm) ~= Handouts.RealmKey(guild.realm)
            or Handouts.GuildKey(entry.bankGuild) ~= Handouts.GuildKey(guild.name) then
            return nil
        end
        local s = stock[entry.itemId]
        if not s then return 0, {} end
        return s.count, s.tabs
    end
end

-- ---------------------------------------------------------------------------
-- Texts and colours
-- ---------------------------------------------------------------------------

--- Item quality colour as r, g, b (unknown quality: light grey).
function Handouts.QualityColor(quality)
    local q = tonumber(quality)
    if not q or q < 0 then return 0.85, 0.85, 0.85 end
    local colors = _G.ITEM_QUALITY_COLORS
    local c = type(colors) == "table" and colors[q]
    if type(c) == "table" and c.r then return c.r, c.g, c.b end
    local fallback = QUALITY_COLORS[q]
    if fallback then return fallback[1], fallback[2], fallback[3] end
    return 0.85, 0.85, 0.85
end

--- "Zibbo" in class colour, or the requester in grey if there is no character.
function Handouts.NameLabel(entry)
    local Council = EHS.Council
    if not entry.hasCharacter then return Council.Color(entry.recipient, 0.6, 0.6, 0.6) end
    return Council.Color(entry.recipient, Council.ClassColor(entry.classFile))
end

--- "2x Bold Living Ruby" in quality colour.
function Handouts.ItemLabel(entry)
    return EHS.Council.Color(("%dx %s"):format(entry.amount, entry.name), Handouts.QualityColor(entry.quality))
end

--- "Tab 1", "Tab 1/2", or "-" when the bank does not have it.
function Handouts.TabLabel(entry)
    local tabs = entry.stockTabs or entry.tabs or {}
    if #tabs == 0 then return "-" end
    local parts = {}
    for i = 1, math.min(#tabs, 3) do parts[i] = tostring(tabs[i].index) end
    return "Tab " .. table.concat(parts, "/")
end

--- "14 da", or in yellow "nur 1!" when there is not enough for this entry.
function Handouts.CountLabel(entry)
    if entry.short then return EHS.Council.Color(("nur %d!"):format(entry.left), 1, 0.82, 0) end
    return ("%d da"):format(entry.count)
end

--- The icon texture: by name from the server, else from the client, else "?".
function Handouts.IconTexture(entry)
    if entry.icon ~= "" then return "Interface\\Icons\\" .. entry.icon end
    local getter = (C_Item and C_Item.GetItemIconByID) or _G.GetItemIcon
    local icon = entry.itemId > 0 and try(getter, entry.itemId) or nil
    if icon then return icon end
    return Handouts.QUESTION_ICON
end

--- Line 2 of the window: "3 Posten offen - 1 abgehakt, wird beim naechsten Sync gemeldet".
function Handouts.SummaryLine(open, done)
    local text = ("%d Posten offen"):format(int(open))
    if int(done) > 0 then
        text = text .. (" - %d abgehakt, wird beim nächsten Sync gemeldet"):format(int(done))
    end
    return text
end

--- Line 1: "Stand: 05.10. 21:30, vor 2 Std." (+ which banks, if not the own one).
function Handouts.Header(data, now, scope, banks)
    local text = EHS.Council.Header(data, now)
    if scope == "match" and banks and #banks == 1 then
        text = text .. (" - %s (%s)"):format(str(banks[1].guild), str(banks[1].realm))
    elseif scope == "version" then
        text = text .. " - keine Bank deiner Gilde, zeige alle dieses Clients"
    elseif scope == "all" then
        text = text .. " - keine Bank dieses Clients, zeige alle"
    end
    return text
end

-- ---------------------------------------------------------------------------
-- Ticked entries (EventHelperSyncDB.guildBankDone)
-- ---------------------------------------------------------------------------

local function doneStore()
    if not EHS.db then return {} end
    if type(EHS.db.guildBankDone) ~= "table" then EHS.db.guildBankDone = {} end
    return EHS.db.guildBankDone
end

local function idList(ids)
    if type(ids) == "table" then return ids end
    if ids == nil then return {} end
    return { ids }
end

--- "Name-Realm" of the player, as `by` of a ticked entry.
function EHS:PlayerFullName()
    local name = str(try(UnitName, "player"))
    local realm = try(GetNormalizedRealmName)
    if not realm or realm == "" then realm = str(try(GetRealmName)):gsub("%s+", "") end
    if realm ~= "" and name ~= "" then return name .. "-" .. realm end
    return name
end

--- Mark handouts as handed out. Already marked ones stay as they are.
-- @param ids an id or a list of ids
-- @param via "manual" (ticked, default) | "mail"
-- @param by the officer, default the player ("Name-Realm")
-- @return number how many were newly marked
function EHS:MarkHandedOut(ids, via, by)
    local store = doneStore()
    if not self.db then return 0 end
    via = (via == "mail") and "mail" or "manual"
    by = (by and by ~= "") and by or self:PlayerFullName()
    local count = 0
    for _, id in ipairs(idList(ids)) do
        id = str(id)
        if id ~= "" and not store[id] then
            store[id] = { id = id, via = via, by = by, at = time() }
            count = count + 1
        end
    end
    if count > 0 and self.RefreshGuildBankUI then self:RefreshGuildBankUI() end
    return count
end

--- Take marks back (before the next sync reported them).
-- @return number how many were removed
function EHS:UnmarkHandedOut(ids)
    local store = doneStore()
    local count = 0
    for _, id in ipairs(idList(ids)) do
        id = str(id)
        if store[id] then
            store[id] = nil
            count = count + 1
        end
    end
    if count > 0 and self.RefreshGuildBankUI then self:RefreshGuildBankUI() end
    return count
end

--- The mark of a handout ({ id, via, by, at }), or nil.
function EHS:IsHandedOut(id)
    local entry = doneStore()[str(id)]
    if type(entry) == "table" then return entry end
    return nil
end

--- Whether something was ticked since the SavedVariables were last written.
function EHS:HandoutsUnsaved()
    local since = (self.db and self.db.lastFlushedAt) or 0
    for _, entry in pairs(doneStore()) do
        if type(entry) == "table" and num(entry.at) > since then return true end
    end
    return false
end

--- Drop marks whose id the downloaded list no longer has: the server knows
-- them (the sync tool reported them) or they were withdrawn. Nothing happens
-- without usable data.
-- @return number how many were dropped
function EHS:PruneHandoutsDone(data)
    if data == nil then data = Handouts.Load() end
    if type(data) ~= "table" or type(data.banks) ~= "table" then return 0 end
    local listed = {}
    for _, bank in ipairs(data.banks) do
        for _, h in ipairs(type(bank) == "table" and type(bank.handouts) == "table" and bank.handouts or {}) do
            if type(h) == "table" and h.id ~= nil then listed[str(h.id)] = true end
        end
    end
    local store = doneStore()
    local count = 0
    for id in pairs(store) do
        if not listed[id] then
            store[id] = nil
            count = count + 1
        end
    end
    return count
end

-- ---------------------------------------------------------------------------
-- Public API (window, /ehs status, mail #18)
-- ---------------------------------------------------------------------------

--- The handouts of this character's guild bank(s), with live stock if the
-- guild bank is open and was scanned.
-- @param opts { allBanks = true } to ignore the client filter
-- @return entries, scope, data, status
function EHS:GetHandoutEntries(opts)
    local data, status = Handouts.Load()
    if not data then return {}, "none", nil, status end
    local banks, scope
    if opts and opts.allBanks then
        banks, scope = Handouts.Banks(data, {})
        if scope ~= "none" then scope = "all" end
    else
        banks, scope = Handouts.Banks(data, Handouts.Client())
    end
    local live = Handouts.LiveSource(self.db and self.db.guildBank,
        self.IsGuildBankOpen and self:IsGuildBankOpen(), self.GuildBankOpenedAt and self:GuildBankOpenedAt() or 0)
    local entries = Handouts.Entries(banks, { done = doneStore(), live = live })
    return entries, scope, data, status, banks
end

--- The open (not ticked) handouts for this character, grouped by recipient.
-- @return { { recipient, recipientRealm, classFile, character, hasCharacter,
--   entries = { entry, ... }, amount } }  (entry: see Handouts.Entries)
function EHS:GetHandouts()
    local open = {}
    for _, entry in ipairs((self:GetHandoutEntries())) do
        if not entry.done then open[#open + 1] = entry end
    end
    return Handouts.Group(open)
end

--- How many handouts are open and how many ticked (this character's banks).
function EHS:HandoutCounts()
    local open, done = 0, 0
    for _, entry in ipairs((self:GetHandoutEntries())) do
        if entry.done then done = done + 1 else open = open + 1 end
    end
    return open, done
end

-- Drop what the server already knows, once the data and SavedVariables are there.
local frame = CreateFrame("Frame")
EHS:RegisterEvents(frame, "PLAYER_LOGIN")
frame:SetScript("OnEvent", function()
    local ok, err = pcall(EHS.PruneHandoutsDone, EHS)
    if not ok then EHS:Debug("Gildenbank-Ausgabe:", tostring(err)) end
end)
