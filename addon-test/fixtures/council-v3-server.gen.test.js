// Generator of council-v3-server.json - NOT run here. It builds the addon's
// cross-check fixture from the EventHelper server's REAL councilRoster() +
// councilSyncPayloadV3() (#670) with mocked data sources, so the paths below
// are relative to the server repo. To regenerate: copy this file to the
// server checkout's test/web/loot/, run there
//   COUNCIL_V3_FIXTURE=<path of council-v3-server.json> npx jest test/web/loot/council-v3-server.gen.test.js
// and delete the copy again (it is no server test).
const fs = require("fs");

const mockListAll = jest.fn(() => []);
const mockGear = jest.fn(() => new Map());
const mockRosters = {};

jest.mock("../../../src/stores/lootStore", () => ({ listAll: (...a) => mockListAll(...a) }));
jest.mock("../../../src/services/characters/characterInfo", () => ({
    annotatedCharacters: () => [
        { key: "gemli", className: "Priest", spec: "Shadow" },
        { key: "heila", className: "Priest", spec: "Holy" },
        { key: "schild", className: "Paladin", spec: "Protection" },
        { key: "messer", className: "Rogue", spec: "Combat" },
        { key: "pfeil", className: "Hunter", spec: "BeastMastery" },
        { key: "neu", className: "Mage", spec: "Arcane" },
    ],
}));
jest.mock("../../../src/services/loot/charGear", () => ({
    gearByCharacter: (...a) => mockGear(...a),
    gearFor: () => null,
    charKey: (n) => String(n).toLowerCase(),
}));
jest.mock("../../../src/stores/characterStore", () => ({ characterMap: () => ({}) }));
jest.mock("../../../src/stores/raiderCharactersStore", () => ({ getCategoryAssignments: () => ({}) }));
jest.mock("../../../src/stores/councilStore", () => {
    const actual = jest.requireActual("../../../src/stores/councilStore");
    return {
        excludedKeys: () => new Set(),
        plannedRoles: () => new Map(),
        listExcluded: () => ({}),
        listViews: () => ({}),
        VIEW_DEFAULTS: actual.VIEW_DEFAULTS,
        viewFor: () => ({ role: "", tiers: [], contents: [], bisTier: "", version: "", stored: true }),
    };
});
jest.mock("../../../src/stores/raidEventStore", () => ({ listRaidEvents: () => [] }));
jest.mock("../../../src/stores/eventStore", () => ({
    listEvents: () => [], getEvent: () => null, isOwnEventId: (id) => String(id || "").startsWith("eh-"),
}));
jest.mock("../../../src/stores/signupStore", () => ({ listSignups: () => [] }));
jest.mock("../../../src/stores/logStore", () => ({ listLogs: () => [] }));
jest.mock("../../../src/stores/reportStore", () => ({ listReports: () => [], getReport: () => null, getReportRoster: () => null }));
jest.mock("../../../src/stores/raiderProfileStore", () => ({ listProfiles: () => [] }));
jest.mock("../../../src/stores/rosterStore", () => ({
    rosterForCategory: (id) => mockRosters[id] || null,
    listRosters: () => Object.values(mockRosters),
}));
jest.mock("../../../src/stores/logGearStore", () => ({ loadLogGear: jest.fn(), clearLogGear: jest.fn(), recentLogs: () => [] }));
jest.mock("../../../src/stores/simStore", () => ({ startCouncilSim: jest.fn(), getJob: jest.fn() }));
jest.mock("../../../src/services/loot/armoryGear", () => ({
    primeArmoryGear: jest.fn(async () => ({ answered: 0 })),
    clearArmoryFor: jest.fn(),
}));
jest.mock("../../../src/stores/raidTemplateStore", () => ({
    getRaidTemplate: (id) => (id === "tpl-t5" ? { id, instanceIds: ["ssc", "tk"] } : null),
}));
jest.mock("../../../src/services/discord/discord", () => ({ listCategories: () => [{ id: "c1", name: "SSC/TK Mittwoch" }] }));
const mockConfig = { categoryIds: ["c1"], categoryLootSystem: { c1: "lootcouncil" }, categoryRaidTemplate: { c1: "tpl-t5" } };
jest.mock("../../../src/stores/settingsStore", () => ({ getConfig: () => mockConfig }));
jest.mock("../../../src/web/http/apiMiddleware", () => require("../../helpers/http").apiMiddlewareMock());
jest.mock("../../../src/web/http/activeGuild", () => ({ activeGuildFor: () => "g1" }));
jest.mock("../../../src/stores/ingestTokenStore", () => ({
    verifyToken: () => ({ id: "t1", name: "PC" }),
    touchToken: jest.fn(),
    bearerFrom: () => "ehl_good",
}));

const { ingestCouncil } = require("../../../src/web/apiRoutes/ingest");
const { mockRes, body } = require("../../helpers/http");
const { lootRow } = require("../../helpers/lootCouncil");
const councilWeights = require("../../../src/stores/councilWeightsStore");
const { tempStoreFile } = require("../../helpers/tempStore");

const DAY = 24 * 60 * 60 * 1000;
const H = 60 * 60 * 1000;
const N1 = Date.UTC(2026, 9, 7, 18, 30, 0); // the sync
const T = N1 + 2 * H + 17 * 1000; // the award after the sync
const N2 = N1 + 30 * H + 17 * 60 * 1000; // when the game recomputes
const iso = (ms) => new Date(ms).toISOString();

const loot = (key, itemId, at, over = {}) => lootRow({
    characterKey: key, character: key[0].toUpperCase() + key.slice(1), categoryId: "c1", contentId: "ssc",
    itemId, itemName: `Item ${itemId}`, awardedAt: at, eventLabel: "SSC/TK Mittwoch", ...over,
});

const BASE_LOOT = [
    loot("gemli", 29982, N1 - 40 * DAY + 3 * H, { contentId: "tk" }), // weapon on his BiS -> bisWeapon
    loot("gemli", 30626, N1 - 15 * DAY - 5 * H), // trinket (3 here)
    loot("gemli", 30021, N1 - 3 * DAY - 2 * H), // trash -> frequent
    loot("heila", 30245, N1 - 25 * DAY), // set token
    loot("heila", 30099, N1 - 8 * DAY - 7 * H), // exception 2.5
    loot("schild", 30103, N1 - 6 * DAY - H), // weapon, not his BiS
    loot("messer", 30101, N1 - 20 * DAY), // normal
    loot("messer", 30022, N1 - DAY - 20 * H), // trash -> frequent
    loot("pfeil", 30105, N1 - 10 * DAY - 11 * H), // weapon on his BiS -> bisWeapon
    loot("pfeil", 30104, N1 - 2 * DAY, { reason: "offspec", reasonLabel: "Offspec" }), // does not count
];
const NEW_AWARD = loot("messer", 30082, T, { reason: "bis", reasonLabel: "BiS", boss: "Morogrim Tidewalker" });

async function ingestAt(ms) {
    jest.spyOn(Date, "now").mockReturnValue(ms);
    const res = mockRes();
    await ingestCouncil({ headers: { authorization: "Bearer ehl_good" } }, res, new URL("http://localhost/api/ingest/council?v=3"));
    return body(res);
}

beforeAll(() => {
    councilWeights.useFile(tempStoreFile("council-weights.json"));
    councilWeights.setWeights("c1", {
        classes: { trinket: 3, bisWeapon: 2, weapon: 1.5, set: 1, normal: 1, frequent: 0.5 },
        items: { 30099: { weight: 2.5, name: "Frayed Tether of the Drowned" } },
        // 105 in all: the shares are not round percents on purpose.
        need: { drought: 35, share: 30, need: 15, tenure: 25 },
        tenureDays: 60,
    });
    const member = (status, key, since) => ({ status, chars: [key], charNames: { [key]: key[0].toUpperCase() + key.slice(1) }, since: iso(since) });
    mockRosters.c1 = {
        id: "r1", name: "Mittwoch", categoryId: "c1", versionId: "tbc", allowMultipleChars: false,
        members: {
            1: member("core", "gemli", N1 - 120 * DAY),
            2: member("core", "heila", N1 - 45 * DAY + 5 * H),
            3: member("core", "schild", N1 - 200 * DAY),
            4: member("trial", "messer", N1 - 12 * DAY - 3 * H),
            5: member("core", "pfeil", N1 - 30 * DAY + 20 * H),
            6: member("trial", "neu", N1 - 3 * DAY),
        },
    };
});
afterAll(() => councilWeights.useFile(null));

it("writes the council v3 cross-check fixture", async () => {
    mockListAll.mockReturnValue(BASE_LOOT);
    mockGear.mockReturnValue(new Map());
    const payload = await ingestAt(N1);

    // The server after the award: the loot store has it, and the next log shows the weapon worn.
    mockListAll.mockReturnValue([...BASE_LOOT, NEW_AWARD]);
    mockGear.mockReturnValue(new Map([["messer", {
        key: "messer", character: "Messer", className: "Rogue", seenAt: T + H, reportId: "r2", reportTitle: "Report",
        items: [{ slot: 15, itemId: 30082, itemLevel: 128, gems: [], enchantId: 0, itemName: "Talon of Azshara" }],
        profile: { role: "melee", confident: true }, skippedReports: 0, roleMismatch: false,
    }]]));
    const after = await ingestAt(N2);
    const cat = after.categories[0];

    const fixture = {
        _about: "Generated from the EventHelper server's real councilRoster() + councilSyncPayloadV3() (#670) "
            + "with mocked data sources; generator: addon-test/fixtures/council-v3-server.gen.test.js.",
        payload,
        award: {
            player: "Messer-Thunderstrike", itemId: 30082, itemName: "Talon of Azshara", awardedAt: T / 1000,
            response: "BiS", source: "rclc", boss: "Morogrim Tidewalker", instance: "",
        },
        now: N2 / 1000,
        expected: {
            avgLootPoints: cat.avgLootPoints,
            avgLootCount: cat.avgLootCount,
            raiders: cat.raiders.map((r) => ({
                key: r.key, need: r.need, parts: r.parts, lootCount: r.lootCount, lootPoints: r.lootPoints,
                droughtDays: r.droughtDays, daysSinceLoot: r.daysSinceLoot, tenureDays: r.tenureDays,
                bisOwned: r.bis.owned, lastAwardAt: r.lastAwardAt,
            })),
        },
    };
    const out = process.env.COUNCIL_V3_FIXTURE;
    if (out) fs.writeFileSync(out, `${JSON.stringify(fixture, null, 2)}\n`);
    expect(payload.version).toBe(3);
    expect(cat.raiders.length).toBe(6);
});
