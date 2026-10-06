"use strict";

// The guild bank part of uploader.js: reading EventHelperSyncDB.guildBank
// ("eventhelper-guildbank" v1, written by GuildBank.lua) and posting it.
jest.mock("fs");

const fs = require("fs");
const { readGuildBank, guildBankKey, postGuildBank, readEnvelope, UploadError } = require("../lib/uploader");

const CONFIG = { baseUrl: "https://example.test:3005/", token: "ehl_secret" };

// What WoW writes for a scan: lists positionally, with "-- [n]" comments.
const SAVED = `
EventHelperSyncDB = {
    ["export"] = {
        ["format"] = "eventhelper-loot",
        ["version"] = 1,
        ["sessions"] = {
        },
    },
    ["guildBank"] = {
        ["format"] = "eventhelper-guildbank",
        ["version"] = 1,
        ["generatedAt"] = 1784574100,
        ["client"] = {
            ["project"] = "tbc",
            ["build"] = "2.5.5",
        },
        ["guild"] = {
            ["name"] = "Pulse",
            ["realm"] = "Thunderstrike",
            ["faction"] = "Alliance",
        },
        ["scannedBy"] = "Gemli-Thunderstrike",
        ["scannedAt"] = 1784574100,
        ["money"] = 123456789,
        ["tabs"] = {
            {
                ["index"] = 1,
                ["name"] = "Mats",
                ["items"] = {
                    {
                        ["itemId"] = 22445,
                        ["count"] = 20,
                        ["slot"] = 1,
                    }, -- [1]
                    {
                        ["itemId"] = 21877,
                        ["count"] = 1,
                        ["slot"] = 98,
                    }, -- [2]
                },
            }, -- [1]
            {
                ["index"] = 3,
                ["name"] = "Leer",
                ["items"] = {
                },
            }, -- [2]
        },
    },
}
`;

const SCAN = {
    format: "eventhelper-guildbank",
    version: 1,
    generatedAt: 1784574100,
    client: { project: "tbc", build: "2.5.5" },
    guild: { name: "Pulse", realm: "Thunderstrike", faction: "Alliance" },
    scannedBy: "Gemli-Thunderstrike",
    scannedAt: 1784574100,
    money: 123456789,
    tabs: [
        { index: 1, name: "Mats", items: [{ itemId: 22445, count: 20, slot: 1 }, { itemId: 21877, count: 1, slot: 98 }] },
        { index: 3, name: "Leer", items: [] },
    ],
};

beforeEach(() => {
    jest.clearAllMocks();
});

describe("readGuildBank", () => {
    it("liest den Scan im Format eventhelper-guildbank v1", () => {
        fs.readFileSync.mockReturnValue(SAVED);
        expect(readGuildBank("x.lua")).toEqual(SCAN);
    });

    it("lässt den Loot-Export daneben unberührt", () => {
        fs.readFileSync.mockReturnValue(SAVED);
        expect(readEnvelope("x.lua")).toMatchObject({ format: "eventhelper-loot", sessions: [] });
    });

    it("liefert null ohne Scan", () => {
        fs.readFileSync.mockReturnValue('EventHelperSyncDB = { ["settings"] = { } }');
        expect(readGuildBank("x.lua")).toBeNull();
    });

    it("liefert null bei fremdem Format oder ohne scannedAt", () => {
        fs.readFileSync.mockReturnValue('EventHelperSyncDB = { ["guildBank"] = { ["format"] = "anderes", ["scannedAt"] = 1 } }');
        expect(readGuildBank("x.lua")).toBeNull();
        fs.readFileSync.mockReturnValue('EventHelperSyncDB = { ["guildBank"] = { ["format"] = "eventhelper-guildbank" } }');
        expect(readGuildBank("x.lua")).toBeNull();
    });

    it("macht aus Listen mit [n]-Schlüsseln Arrays", () => {
        fs.readFileSync.mockReturnValue(`EventHelperSyncDB = { ["guildBank"] = {
            ["format"] = "eventhelper-guildbank", ["scannedAt"] = 5,
            ["tabs"] = { [2] = { ["index"] = 2, ["items"] = { [1] = { ["itemId"] = 7 } } }, [1] = { ["index"] = 1 } },
        } }`);
        const scan = readGuildBank("x.lua");
        expect(scan.tabs.map((t) => t.index)).toEqual([1, 2]);
        expect(scan.tabs[0].items).toEqual([]);
        expect(scan.tabs[1].items).toEqual([{ itemId: 7 }]);
    });
});

describe("guildBankKey", () => {
    it("ist Client + Realm + Gilde", () => {
        expect(guildBankKey(SCAN)).toBe("tbc|Thunderstrike|Pulse");
        expect(guildBankKey({ ...SCAN, client: { project: "forever" } })).toBe("forever|Thunderstrike|Pulse");
    });
});

describe("postGuildBank", () => {
    it("schickt den Scan unverändert mit Bearer-Token an /api/ingest/guildbank", async () => {
        global.fetch = jest.fn(async () => ({
            ok: true, status: 201, text: async () => JSON.stringify({ data: { ok: true } }),
        }));
        const answer = await postGuildBank(CONFIG, SCAN);
        const [url, init] = global.fetch.mock.calls[0];
        expect(url).toBe("https://example.test:3005/api/ingest/guildbank");
        expect(init.method).toBe("POST");
        expect(init.headers.Authorization).toBe("Bearer ehl_secret");
        expect(JSON.parse(init.body)).toEqual(SCAN);
        expect(answer).toEqual({ ok: true });
    });

    it("meldet einen fehlenden Endpunkt als UploadError mit Status 404", async () => {
        global.fetch = jest.fn(async () => ({
            ok: false, status: 404, text: async () => "<html>Cannot POST /api/ingest/guildbank</html>",
        }));
        const err = await postGuildBank(CONFIG, SCAN).catch((e) => e);
        expect(err).toBeInstanceOf(UploadError);
        expect(err.status).toBe(404);
    });
});
