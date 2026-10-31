"use strict";

// Servers and game versions for the window's sidebar (#51): who the key is
// (GET /api/ingest/me), the game version of the addon file, and the server
// tags on council categories and handout banks.
jest.mock("../lib/config");
jest.mock("../lib/wowPaths");
jest.mock("../lib/council");
jest.mock("fs");
jest.mock("../lib/uploader", () => ({
    ...jest.createMockFromModule("../lib/uploader"),
    UploadError: jest.requireActual("../lib/uploader").UploadError,
}));
jest.mock("../lib/guildbankHandouts", () => {
    const actual = jest.requireActual("../lib/guildbankHandouts");
    return { ...actual, syncHandouts: jest.fn(), reportDone: jest.fn(), readGuildBankDone: jest.fn() };
});

const fs = require("fs");
const config = require("../lib/config");
const wowPaths = require("../lib/wowPaths");
const uploader = require("../lib/uploader");
const council = require("../lib/council");
const handouts = require("../lib/guildbankHandouts");
const { createRunner } = require("../lib/runner");

const { UploadError } = uploader;

const CFG = {
    baseUrl: "https://example.test", token: "ehl_secret", savedVariablesPath: "C:/WoW/_anniversary_/WTF/x.lua",
    extraRoots: [], excludedSessions: [], uploadLog: {}, guildBankUploads: {}, guildBankDoneReported: {},
    pollSeconds: 15,
};

const ME = {
    owner: { name: "Marc", id: "123" },
    servers: [
        { guildId: "g1", name: "Nachtwache", label: "Nachtwache", versions: [{ id: "tbc", short: "TBC" }, { id: "forever", short: "FE" }] },
        { guildId: "g2", name: "PuGs", versions: [{ id: "forever" }] },
    ],
    legacy: null,
};

beforeEach(() => {
    jest.clearAllMocks();
    config.load.mockReturnValue({ ...CFG });
    config.save.mockImplementation((c) => c);
    config.missing.mockImplementation((c) => [!c.baseUrl && "baseUrl", !c.token && "token"].filter(Boolean));
    wowPaths.discover.mockReturnValue([]);
    wowPaths.versionOfFlavor.mockImplementation((p) => (/_anniversary_/.test(p) ? "tbc" : ""));
    fs.existsSync.mockReturnValue(true);
    fs.statSync.mockReturnValue({ mtimeMs: 1 });
    uploader.readEnvelope.mockReturnValue({ sessions: [] });
    uploader.readGuildBank.mockReturnValue(null);
    uploader.fetchMe.mockResolvedValue(ME);
    handouts.readGuildBankDone.mockReturnValue([]);
});

describe("refreshMe", () => {
    it("takes owner, servers and legacy into the state", async () => {
        const runner = createRunner();
        const answer = await runner.refreshMe();
        expect(answer).toBe(ME);
        expect(uploader.fetchMe).toHaveBeenCalledWith(expect.objectContaining({ baseUrl: CFG.baseUrl }));
        expect(runner.state.me).toMatchObject({
            fetching: false, owner: { name: "Marc" }, servers: ME.servers, legacy: null, unsupported: false, lastError: null,
        });
        expect(runner.state.me.lastFetch).toBeGreaterThan(0);
        expect(runner.state.connection.ok).toBe(true);
    });

    it("an old server key: legacy names the one guild it is valid for", async () => {
        uploader.fetchMe.mockResolvedValue({ owner: null, servers: [ME.servers[1]], legacy: { guildId: 2 } });
        const runner = createRunner();
        await runner.refreshMe();
        expect(runner.state.me.legacy).toEqual({ guildId: "2" });
        expect(runner.state.me.owner).toBeNull();
        expect(runner.state.me.servers).toHaveLength(1);
    });

    it("an older server without the route (404): unsupported, no error, no warning", async () => {
        uploader.fetchMe.mockRejectedValue(new UploadError("Nicht gefunden", 404));
        const runner = createRunner();
        await expect(runner.refreshMe()).resolves.toBeNull();
        expect(runner.state.me).toMatchObject({ unsupported: true, lastError: null, servers: [] });
        expect(runner.state.log.some((e) => e.level === "warn")).toBe(false);
    });

    it("any other error is kept and logged, never thrown", async () => {
        uploader.fetchMe.mockRejectedValue(new UploadError("https://example.test nicht erreichbar: ECONNREFUSED"));
        const runner = createRunner();
        await expect(runner.refreshMe()).resolves.toBeNull();
        expect(runner.state.me).toMatchObject({ unsupported: false, lastError: { message: expect.stringMatching(/ECONNREFUSED/) } });
        expect(runner.state.log.some((e) => e.level === "warn" && /Server-Liste nicht geholt/.test(e.text))).toBe(true);
        expect(runner.state.connection.ok).toBe(false);
    });

    it("does not ask without address or token, and one request at a time", async () => {
        config.load.mockReturnValue({ ...CFG, token: "" });
        await expect(createRunner().refreshMe()).resolves.toBeNull();
        expect(uploader.fetchMe).not.toHaveBeenCalled();

        config.load.mockReturnValue({ ...CFG });
        const runner = createRunner();
        const a = runner.refreshMe();
        const b = runner.refreshMe();
        expect(a).toBe(b);
        await a;
        expect(uploader.fetchMe).toHaveBeenCalledTimes(1);
    });

    it("a new key forgets the servers of the old one", async () => {
        const runner = createRunner();
        await runner.refreshMe();
        config.load.mockReturnValue({ ...CFG, token: "ehl_other" });
        uploader.fetchMe.mockReturnValue(new Promise(() => {}));
        runner.reload();
        expect(runner.state.me.servers).toEqual([]);
        expect(runner.state.me.owner).toBeNull();
        runner.stop();
    });
});

describe("fileVersion", () => {
    it("is the game version of the addon file's flavor folder", () => {
        const runner = createRunner();
        runner.readState();
        expect(runner.state.fileVersion).toBe("tbc");
        expect(wowPaths.versionOfFlavor).toHaveBeenCalledWith(CFG.savedVariablesPath);
    });

    it("is empty without a file", () => {
        fs.existsSync.mockReturnValue(false);
        const runner = createRunner();
        runner.readState();
        expect(runner.state.fileVersion).toBe("");
    });
});

describe("server tags", () => {
    it("council categories keep guildId and gameVersion", async () => {
        council.syncCouncil.mockResolvedValue({
            payload: {
                format: "eventhelper-council", version: 4, generatedAt: 1,
                categories: [
                    { id: "1", name: "Main", guildId: "g1", gameVersion: "tbc", raiders: [{}, {}] },
                    { id: "2", name: "Alt", raiders: [{}] },
                ],
            },
            categories: 2, raiders: 3, dirs: [{ dir: "A" }], files: ["A/CouncilData.lua"], errors: [],
        });
        const runner = createRunner();
        await runner.refreshCouncil({ force: true });
        expect(runner.state.council.categories).toEqual([
            { id: "1", name: "Main", raiders: 2, guildId: "g1", gameVersion: "tbc" },
            { id: "2", name: "Alt", raiders: 1, guildId: "", gameVersion: "" },
        ]);
    });

    it("handouts are counted per bank with their server", async () => {
        handouts.syncHandouts.mockResolvedValue({
            payload: {
                format: "eventhelper-guildbank-handouts", version: 1, generatedAt: 1,
                banks: [
                    { guildId: "g1", gameVersion: "tbc", guild: "Die Gilde", handouts: [{ id: "a" }, { id: "b" }] },
                    { name: "Ohne Tag", handouts: [] },
                ],
            },
            banks: 2, handouts: 2, dirs: [{ dir: "A" }], files: ["A/GuildBankData.lua"], errors: [],
        });
        const runner = createRunner();
        await runner.refreshHandouts({ force: true });
        expect(runner.state.handouts.perBank).toEqual([
            { guildId: "g1", gameVersion: "tbc", guild: "Die Gilde", handouts: 2 },
            { guildId: "", gameVersion: "", guild: "Ohne Tag", handouts: 0 },
        ]);
    });
});
