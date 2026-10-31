-- Council.lua with council data from sync 1.19.0 and later (#51): the file
-- carries `servers` (Discord servers with their game versions and WoW guilds)
-- and every category is tagged with guildId + gameVersion. Load() keeps only
-- the categories of the server whose guild the character belongs to - two
-- servers may well use the same category id.
loadAddon()
WoWMock.login({})
local EHS = EventHelperSync
local Council = EHS.Council

local function raiders() return { { name = "Gemli", class = "PRIEST", need = 50 } } end

local function data()
    return {
        format = "eventhelper-council", version = 3, generatedAt = 1,
        categories = {
            { id = "c1", name = "Pulse Kara", guildId = "111", gameVersion = "tbc", raiders = raiders() },
            { id = "c2", name = "Pulse Gruul", guildId = "111", gameVersion = "tbc", raiders = raiders() },
            { id = "c1", name = "PuG Kara", guildId = "222", gameVersion = "tbc", raiders = raiders() },
        },
        servers = {
            { guildId = "111", name = "Pulse", versions = {
                { id = "tbc", realm = "Thunderstrike", guilds = { { name = "Pulse", realm = "Thunderstrike", region = "eu" } } },
            } },
            { guildId = "222", name = "PuGs", versions = {
                { id = "tbc", realm = "Thunderstrike", guilds = { { name = "Die Silberne-Hand", realm = "" } } },
            } },
        },
    }
end

local function names(loaded)
    local out = {}
    for _, category in ipairs(Council.Categories(loaded)) do out[#out + 1] = category.name end
    return table.concat(out, ",")
end

-- The guild of the logged-in character (mock: Pulse on Thunderstrike) picks the server.
local raw = data()
local loaded, status = Council.Load(raw)
expectEqual(status, "ok", "status")
expectEqual(names(loaded), "Pulse Kara,Pulse Gruul", "only the categories of server 111")
expectEqual(loaded.server.guildId, "111", "data.server")
expectEqual(Council.FindCategory(loaded, "c1").name, "Pulse Kara", "c1 is the Pulse category")
expectEqual(loaded.categories[1].guildId, "111", "guildId kept")
expectEqual(loaded.categories[1].gameVersion, "tbc", "gameVersion kept")
expect(Council.Load(raw) == loaded, "the same table again for the same guild")

-- Another guild: spaces, hyphens and case do not matter; the realm of the version applies.
local other = Council.Load(raw, { guild = "die silberne hand", realm = "Thunderstrike" })
expectEqual(names(other), "PuG Kara", "server 222 by guild name")
expect(other ~= loaded, "a table per server")

-- The guild matches, the realm does not: no server matches; with two servers all categories stay.
local wrongRealm = Council.Load(data(), { guild = "Pulse", realm = "Everlook" })
expect(wrongRealm.server == nil, "no server")
expectEqual(#wrongRealm.categories, 3, "all categories without a matching server")

-- Not in a guild yet (right after login): all categories, nothing hidden.
local noGuild = Council.Load(data(), { guild = "", realm = "Thunderstrike" })
expectEqual(#noGuild.categories, 3, "all categories without a guild")

-- A single server applies even without a matching guild.
local single = data()
single.servers = { single.servers[2] }
local only = Council.Load(single, { guild = "Pulse", realm = "Thunderstrike" })
expectEqual(only.server.guildId, "222", "the only server")
expectEqual(names(only), "PuG Kara", "its categories")

-- A file without servers (older sync tool) loads as before.
local old = data()
old.servers = nil
expectEqual(#Council.Load(old).categories, 3, "no servers: all categories")

-- ChooseServer by itself.
expect(Council.ChooseServer(nil, {}) == nil, "no list")
expectEqual(Council.ChooseServer(data().servers, { guild = "PULSE", realm = "thunderstrike" }).guildId, "111", "case")

-- The mock character changes guild: Load() without arguments follows Council.Who().
WoWMock.player.guild = "Die Silberne Hand"
expectEqual(Council.Who().guild, "Die Silberne Hand", "Who() reads the guild")
expectEqual(names(Council.Load(raw)), "PuG Kara", "Load() follows the guild")
WoWMock.player.guild = "Pulse"
