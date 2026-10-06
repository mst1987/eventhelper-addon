-- GuildBankHandouts.lua on the TBC client: loading the data, which banks this
-- character sees, the flat sorted list (character nil, colours, labels), the
-- shared stock and the shortage hint, grouping, ticking/unticking into
-- EventHelperSyncDB.guildBankDone, dropping reported ids, the live count of an
-- open guild bank, /ehs upload for ticks alone and /ehs status.
loadAddon()
WoWMock.login({ lastFlushedAt = 1 })
local EHS = EventHelperSync
local Handouts = EHS.Handouts
local NOW = WoWMock.now

local function plain(text)
    return (tostring(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

-- Loading ---------------------------------------------------------------------------------

local data, status = Handouts.Load()
expectEqual(data, nil, "placeholder leaves no data")
expectEqual(status, "none", "status without data")
expectEqual(select(2, Handouts.Load({ format = "eventhelper-council", version = 1, banks = {} })), "format", "wrong format")
expectEqual(select(2, Handouts.Load({ format = "eventhelper-guildbank-handouts", version = 2, banks = {} })), "version", "newer")
expectEqual(select(2, Handouts.Load({ format = "eventhelper-guildbank-handouts", version = 1 })), "format", "no banks")
expectEqual(Handouts.EMPTY_TEXT.none,
    "Noch keine Ausgabe-Daten: EventHelper Sync auf dem PC laufen lassen, dann /reload.", "empty state text")
for _, text in pairs(Handouts.EMPTY_TEXT) do
    -- only ASCII and Latin-1 two-byte sequences (C2/C3 lead bytes)
    for i = 1, #text do
        local b = text:byte(i)
        expect(b < 0x80 or b == 0xC2 or b == 0xC3 or (b >= 0x80 and b <= 0xBF), "Latin-1 only: %s", text)
    end
end

-- without data nothing breaks
local entries, scope = EHS:GetHandoutEntries()
expectEqual(#entries, 0, "no entries without data")
expectEqual(scope, "none", "scope without data")
expectEqual(#EHS:GetHandouts(), 0, "no groups without data")
expectEqual(EHS:PruneHandoutsDone(), 0, "no pruning without data")

-- The data as the sync tool writes it (character nil = the raider has no character).
local NO_CHARACTER = {}
local function handout(id, over)
    local h = {
        id = id, itemId = 24027, name = "Bold Living Ruby", icon = "inv_jewelcrafting_livingruby_03", quality = 3,
        amount = 2, purpose = "Gruul", character = { name = "Zibbo", realm = "Thunderstrike", faction = "Alliance", classFile = "PRIEST" },
        requestedBy = "Anna", requestedAt = NOW - 7200, confirmedBy = "Arthas", confirmedAt = NOW - 3600, inBank = 14,
        tabs = { { index = 1, name = "Edelsteine", count = 10 }, { index = 2, name = "Verbrauch", count = 4 } },
    }
    for k, v in pairs(over or {}) do
        if v == NO_CHARACTER then h[k] = nil else h[k] = v end
    end
    return h
end

EventHelperSync_GuildBankHandouts = {
    format = "eventhelper-guildbank-handouts", version = 1, generatedAt = NOW - 7200,
    banks = {
        { key = "tbc:thunderstrike:pulse", gameVersion = "tbc", realm = "Thunderstrike", guild = "Pulse",
          faction = "Alliance", scannedAt = NOW - 86400, handouts = {
            handout("z1"),
            handout("z2", { itemId = 22829, name = "Super Healing Potion", icon = "", quality = 1, amount = 3, inBank = 4,
                tabs = { { index = 3, name = "Traenke", count = 4 } }, confirmedAt = NOW - 3000 }),
            handout("a1", { character = NO_CHARACTER, requestedBy = "Anna", itemId = 22829, name = "Super Healing Potion", icon = "",
                quality = -1, amount = 2, inBank = 4, tabs = { { index = 3, name = "Traenke", count = 4 } } }),
            handout("n1", { character = { name = "Naphfß", realm = "Thunderstrike", classFile = "WARLOCK" },
                itemId = 22829, name = "Super Healing Potion", icon = "", quality = 7, amount = 1, inBank = 4,
                tabs = { { index = 3, name = "Traenke", count = 4 } } }),
          } },
        { key = "tbc:thunderstrike:andere gilde", gameVersion = "tbc", realm = "Thunderstrike", guild = "Andere Gilde",
          scannedAt = NOW, handouts = { handout("x1", { character = { name = "Fremd", classFile = "MAGE" } }) } },
        { key = "forever:thunderstrike:pulse", gameVersion = "forever", realm = "Thunderstrike", guild = "Pulse",
          scannedAt = NOW, handouts = { handout("f1", { character = { name = "Ewig", classFile = "DRUID" } }) } },
        { key = "tbc:spineshatter:leer", gameVersion = "tbc", realm = "Spineshatter", guild = "Leer", handouts = {} },
    },
}
data, status = Handouts.Load()
expectEqual(status, "ok", "fixture loads")

-- Which banks -----------------------------------------------------------------------------

local client = Handouts.Client()
expect(client.project == "tbc" and client.realm == "Thunderstrike" and client.guild == "Pulse", "client of this character")
local banks
banks, scope = Handouts.Banks(data, client)
expectEqual(scope, "match", "own guild bank on this client")
expectEqual(#banks, 1, "only the own bank")
expectEqual(banks[1].key, "tbc:thunderstrike:pulse", "the right one")
-- realm and guild compared like the server does (case, blanks, apostrophes, dashes)
banks, scope = Handouts.Banks(data, { project = "tbc", realm = "thunder-strike", guild = "  PULSE " })
expectEqual(scope, "match", "normalised compare")
banks, scope = Handouts.Banks(data, { project = "tbc", realm = "Thunderstrike", guild = "" })
expectEqual(scope, "version", "no guild: the banks of this client")
expectEqual(#banks, 3, "three tbc banks")
banks, scope = Handouts.Banks(data, { project = "classic", realm = "Thunderstrike", guild = "Pulse" })
expectEqual(scope, "all", "no bank of this client: all")
expectEqual(#banks, 4, "all banks")
expectEqual(select(2, Handouts.Banks({ banks = {} }, client)), "none", "no banks at all")

-- The list --------------------------------------------------------------------------------

entries, scope = EHS:GetHandoutEntries()
expectEqual(scope, "match", "scope of the list")
expectEqual(#entries, 4, "four handouts of the own bank")
local order = {}
for i, e in ipairs(entries) do order[i] = e.id end
expectEqual(table.concat(order, ","), "a1,n1,z1,z2", "sorted by recipient, then confirmation")

local anna, naph, ruby, potion = entries[1], entries[2], entries[3], entries[4]
expect(not anna.hasCharacter and anna.recipient == "Anna" and anna.character == nil, "no character: requestedBy")
expectEqual(plain(Handouts.NameLabel(anna)), "Anna", "requester's name")
expectEqual(Handouts.NameLabel(anna), "|cff999999Anna|r", "requester in grey")
expectEqual(Handouts.NameLabel(ruby), "|cffffffffZibbo|r", "priest white (fallback colours)")
expectEqual(Handouts.NameLabel(naph), "|cff8787edNaphfß|r", "warlock from the fallback table, Latin-1 name")
expectEqual(ruby.recipientRealm, "Thunderstrike", "recipient realm")
expectEqual(Handouts.ItemLabel(ruby), "|cff0070de2x Bold Living Ruby|r", "rare blue")
expectEqual(plain(Handouts.ItemLabel(anna)), "2x Super Healing Potion", "item label")
expect(select(1, Handouts.QualityColor(-1)) == 0.85, "unknown quality light grey")
expect(select(3, Handouts.QualityColor(7)) == 1, "heirloom from the fallback")
ITEM_QUALITY_COLORS = { [3] = { r = 0.1, g = 0.2, b = 0.3 } }
expect(select(2, Handouts.QualityColor(3)) == 0.2, "client colours first")
ITEM_QUALITY_COLORS = nil
expectEqual(Handouts.IconTexture(ruby), "Interface\\Icons\\inv_jewelcrafting_livingruby_03", "icon by name")
expectEqual(Handouts.IconTexture(anna), Handouts.QUESTION_ICON, "no icon, no client icon: question mark")
function GetItemIcon(id) return id == 22829 and 134830 or nil end
expectEqual(Handouts.IconTexture(anna), 134830, "client icon")
GetItemIcon = nil

expectEqual(Handouts.TabLabel(ruby), "Tab 1/2", "two tabs")
expectEqual(Handouts.TabLabel(anna), "Tab 3", "one tab")
expectEqual(Handouts.TabLabel({ tabs = {} }), "-", "not in the bank")

-- shared stock: 4 potions, Anna 2, Naphfß 1, Zibbo 3 -> Zibbo gets only 1
expectEqual(Handouts.CountLabel(anna), "4 da", "enough for the first")
expectEqual(Handouts.CountLabel(naph), "4 da", "enough for the second")
expect(potion.short and potion.left == 1, "third one short")
expectEqual(Handouts.CountLabel(potion), "|cffffd100nur 1!|r", "shortage hint in yellow")
expectEqual(Handouts.CountLabel(ruby), "14 da", "plenty")

-- grouping
local groups = EHS:GetHandouts()
expectEqual(#groups, 3, "three recipients")
expectEqual(groups[3].recipient, "Zibbo", "last group")
expectEqual(#groups[3].entries, 2, "two handouts for Zibbo")
expectEqual(groups[3].amount, 5, "2 + 3")
expect(groups[3].hasCharacter and groups[3].classFile == "PRIEST", "group keeps the character")
expect(not groups[1].hasCharacter, "Anna has none")

local open, done = EHS:HandoutCounts()
expect(open == 4 and done == 0, "counts")

-- Ticking ---------------------------------------------------------------------------------

expectEqual(EHS:MarkHandedOut("a1"), 1, "tick one")
local mark = EventHelperSyncDB.guildBankDone.a1
expect(mark and mark.id == "a1" and mark.via == "manual" and mark.by == "Gemli-Thunderstrike" and mark.at == NOW, "stored mark")
expectEqual(EHS:MarkHandedOut("a1", "mail"), 0, "an existing mark stays")
expectEqual(EventHelperSyncDB.guildBankDone.a1.via, "manual", "unchanged")
expectEqual(EHS:MarkHandedOut({ "z1", "z2" }, "mail", "Jaina"), 2, "a list, by mail, by someone else")
expect(EventHelperSyncDB.guildBankDone.z2.via == "mail" and EventHelperSyncDB.guildBankDone.z2.by == "Jaina", "mail mark")
expect(EHS:IsHandedOut("z1"), "IsHandedOut")
expectEqual(EHS:UnmarkHandedOut({ "z1", "z2", "nope" }), 2, "untick before the sync")
expect(EventHelperSyncDB.guildBankDone.z1 == nil and not EHS:IsHandedOut("z2"), "removed")

entries = EHS:GetHandoutEntries()
expect(entries[1].done and entries[1].done.by == "Gemli-Thunderstrike", "entry knows its mark")
-- a ticked entry no longer takes from the stock: Zibbo now gets 3 of 4
expect(not entries[1].short, "ticked rows have no shortage")
expect(not entries[4].short and entries[4].left == 3, "Zibbo's potions fit now")
open, done = EHS:HandoutCounts()
expect(open == 3 and done == 1, "3 open, 1 ticked")
groups = EHS:GetHandouts()
expectEqual(groups[1].recipient, "Naphfß", "ticked ones are not in GetHandouts")

-- /ehs status
SlashCmdList.EVENTHELPERSYNC("status")
expect(WoWMock.printed("Gildenbank-Ausgabe: 3 Posten offen, 1 abgehakt"), "status line")

-- A tick alone is worth a reload (/ehs upload) ----------------------------------------------

expect(EHS:HandoutsUnsaved(), "tick newer than the last flush")
EventHelperSyncDB.export = nil
expect(EHS:FlushAndReload(), "reload for the ticks alone")
expectEqual(WoWMock.reloads, 1, "ReloadUI called")
expect(WoWMock.printed("abgehakten Gildenbank-Ausgaben"), "reload message")
expect(not EHS:HandoutsUnsaved(), "saved now")
expect(not EHS:FlushAndReload(), "nothing to save afterwards")
expectEqual(WoWMock.reloads, 1, "no second reload")

-- Dropping what the server knows ------------------------------------------------------------

EHS:MarkHandedOut({ "n1", "gone" })
local snapshot = EventHelperSync_GuildBankHandouts
EventHelperSync_GuildBankHandouts = nil
expectEqual(EHS:PruneHandoutsDone(), 0, "no data: nothing dropped")
EventHelperSync_GuildBankHandouts = snapshot
expectEqual(EHS:PruneHandoutsDone(), 1, "only the id the list no longer has")
expect(EventHelperSyncDB.guildBankDone.gone == nil, "gone is dropped")
expect(EventHelperSyncDB.guildBankDone.a1 and EventHelperSyncDB.guildBankDone.n1, "listed ones stay")
-- the next download no longer lists a1 (reported): dropped on the next login
table.remove(snapshot.banks[1].handouts, 3)
expectEqual(EHS:PruneHandoutsDone(), 1, "reported id dropped")
expect(EventHelperSyncDB.guildBankDone.a1 == nil, "a1 dropped")
-- other banks count as listed too
EHS:MarkHandedOut("f1")
expectEqual(EHS:PruneHandoutsDone(), 0, "an id of another bank stays")
EHS:UnmarkHandedOut({ "f1", "n1" })

-- Live count at the open guild bank ---------------------------------------------------------

entries = EHS:GetHandoutEntries()
expect(not entries[1].live, "closed bank: server count")
WoWMock.guildBank = {
    money = 0, respondAfter = 0.25,
    tabs = {
        { name = "Edelsteine", slots = { [1] = { id = 24027, count = 1 } } },
        { name = "Traenke", slots = { [1] = { id = 22829, count = 5 }, [2] = { id = 22829, count = 2 } } },
    },
}
WoWMock.advance(10)
-- the window is covered by the flavour specs; here it stays shut
EHS.db.settings.autoOpenHandouts = false
WoWMock.openGuildBank("tbc")
entries = EHS:GetHandoutEntries()
expect(not entries[1].live, "open, but the scan of this visit is not there yet")
WoWMock.advance(2)
expect(EventHelperSyncDB.guildBank and EventHelperSyncDB.guildBank.scannedAt >= EHS:GuildBankOpenedAt(), "scanned")
entries = EHS:GetHandoutEntries()
local liveNaph, liveRuby, livePotion = entries[1], entries[2], entries[3]
expect(liveRuby.live and liveRuby.count == 1, "live count of the rubies")
expect(liveRuby.short and Handouts.CountLabel(liveRuby) == "|cffffd100nur 1!|r", "only 1 of 2 there")
expectEqual(Handouts.TabLabel(liveRuby), "Tab 1", "live tab")
expectEqual(liveRuby.stockTabs[1].name, "Edelsteine", "live tab name")
expect(liveNaph.count == 7 and liveNaph.stockTabs[1].count == 7 and liveNaph.stockTabs[1].index == 2, "stacks summed")
expect(not livePotion.short and livePotion.left == 6, "potions: 7 live, 1 to Naphfss first")
-- an item the scan does not have counts 0
snapshot.banks[1].handouts[#snapshot.banks[1].handouts + 1] = handout("m1", { itemId = 99999, name = "Missing" })
entries = EHS:GetHandoutEntries()
local missing
for _, e in ipairs(entries) do if e.id == "m1" then missing = e end end
expect(missing.live and missing.count == 0 and missing.short and Handouts.TabLabel(missing) == "-", "not in the bank")
-- the scan of another guild does not count for this bank
EventHelperSyncDB.guildBank.guild.name = "Andere Gilde"
entries = EHS:GetHandoutEntries()
expect(not entries[1].live, "scan of another bank ignored")
EventHelperSyncDB.guildBank.guild.name = "Pulse"
WoWMock.closeGuildBank("tbc")
entries = EHS:GetHandoutEntries()
expect(not entries[1].live, "closed again: server count")

-- Header and summary ------------------------------------------------------------------------

local header = Handouts.Header(snapshot, NOW, "match", { snapshot.banks[1] })
expect(header:match("^Stand: %d%d%.%d%d%. %d%d:%d%d, vor %d+ Std%. %- Pulse %(Thunderstrike%)$"), "header: " .. header)
expect(Handouts.Header(snapshot, NOW, "all"):find("zeige alle", 1, true), "hint when showing all")
expectEqual(Handouts.SummaryLine(3, 0), "3 Posten offen", "summary without ticks")
expectEqual(Handouts.SummaryLine(3, 1), "3 Posten offen - 1 abgehakt, wird beim nächsten Sync gemeldet", "summary")

-- the logic never needs the window, and with the setting off the bank does not open it
expect(EventHelperSyncGuildBankFrame == nil, "no window built")
