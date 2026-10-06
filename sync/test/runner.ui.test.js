"use strict";

// State the window shows beyond the raw data: the connection pill
// (state.connection), "new data for the game" (council/handouts changedAt)
// and the connection test with values that are not saved yet (setup view).
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
const { createRunner, LOG_LIMIT, COUNCIL_INTERVAL_MS, HANDOUTS_INTERVAL_MS } = require("../lib/runner");

const { UploadError } = uploader;

const CFG = {
    baseUrl: "https://example.test", token: "ehl_secret", savedVariablesPath: "x.lua",
    extraRoots: [], excludedSessions: [], uploadLog: {}, guildBankUploads: {}, guildBankDoneReported: {},
    pollSeconds: 15,
};

const COUNCIL = {
    payload: { format: "eventhelper-council", version: 2, generatedAt: 1, categories: [{ id: "1", name: "SSC", raiders: [{}] }] },
    categories: 1, raiders: 1, dirs: [{ dir: "A" }], files: ["A/CouncilData.lua"], errors: [],
};

const HANDOUTS = {
    payload: { format: "eventhelper-guildbank-handouts", version: 1, generatedAt: 1, banks: [{ handouts: [{ id: "x" }] }] },
    banks: 1, handouts: 1, dirs: [{ dir: "A" }], files: ["A/GuildBankData.lua"], errors: [],
};

let now;

beforeEach(() => {
    jest.clearAllMocks();
    now = 1_800_000_000_000;
    jest.spyOn(Date, "now").mockImplementation(() => now);
    config.load.mockReturnValue({ ...CFG });
    config.save.mockImplementation((c) => c);
    config.missing.mockImplementation((c) => [!c.baseUrl && "baseUrl", !c.token && "token"].filter(Boolean));
    wowPaths.discover.mockReturnValue([]);
    fs.existsSync.mockReturnValue(true);
    fs.statSync.mockReturnValue({ mtimeMs: 1 });
    uploader.readEnvelope.mockReturnValue({ sessions: [] });
    uploader.readGuildBank.mockReturnValue(null);
    uploader.postSession.mockResolvedValue({});
    handouts.readGuildBankDone.mockReturnValue([]);
    council.syncCouncil.mockResolvedValue(COUNCIL);
    handouts.syncHandouts.mockResolvedValue(HANDOUTS);
});

afterEach(() => {
    jest.restoreAllMocks();
});

it("hands the UI the log limit and the automatic intervals", () => {
    const runner = createRunner();
    expect(runner.state.logLimit).toBe(LOG_LIMIT);
    expect(LOG_LIMIT).toBeGreaterThanOrEqual(200);
    expect(runner.state.intervals).toEqual({ councilMs: COUNCIL_INTERVAL_MS, handoutsMs: HANDOUTS_INTERVAL_MS });
});

describe("connection", () => {
    it("is unknown until a request says something", () => {
        expect(createRunner().state.connection).toMatchObject({ ok: null });
    });

    it("a successful test marks it as connected", async () => {
        const runner = createRunner();
        await runner.testConnection();
        expect(uploader.postSession).toHaveBeenCalledWith(expect.objectContaining({ baseUrl: CFG.baseUrl }), expect.anything());
        expect(runner.state.connection).toMatchObject({ ok: true, message: "" });
    });

    it("a network error or a rejected token is no connection, with the reason", async () => {
        const runner = createRunner();
        uploader.postSession.mockRejectedValue(new UploadError("https://example.test nicht erreichbar: ECONNREFUSED"));
        await expect(runner.testConnection()).rejects.toThrow(/ECONNREFUSED/);
        expect(runner.state.connection).toMatchObject({ ok: false, message: expect.stringMatching(/ECONNREFUSED/) });

        uploader.postSession.mockRejectedValue(new UploadError("API-Token unbekannt", 401));
        await expect(runner.testConnection()).rejects.toThrow();
        expect(runner.state.connection).toMatchObject({ ok: false, message: "API-Token unbekannt" });
    });

    it("any other HTTP answer still means the server was reached", () => {
        const runner = createRunner();
        runner.noteConnection(new UploadError("Nicht gefunden", 404));
        expect(runner.state.connection.ok).toBe(true);
        runner.noteConnection({ message: "kaputt" });
        expect(runner.state.connection.ok).toBe(false);
    });

    it("tests typed-in values without saving them and without touching the pill", async () => {
        const runner = createRunner();
        await runner.testConnection({ baseUrl: "https://neu.example", token: "ehl_neu" });
        expect(uploader.postSession).toHaveBeenCalledWith(
            expect.objectContaining({ baseUrl: "https://neu.example", token: "ehl_neu" }), expect.anything(),
        );
        expect(config.save).not.toHaveBeenCalled();
        expect(runner.state.connection.ok).toBeNull();
    });

    it("keeps the saved token when only the address is typed in", async () => {
        const runner = createRunner();
        await runner.testConnection({ baseUrl: "https://neu.example", token: "" });
        expect(uploader.postSession).toHaveBeenCalledWith(
            expect.objectContaining({ baseUrl: "https://neu.example", token: CFG.token }), expect.anything(),
        );
    });

    it("says so when address or token are missing, without asking the server", async () => {
        config.load.mockReturnValue({ ...CFG, token: "" });
        const runner = createRunner();
        await expect(runner.testConnection({ baseUrl: "https://neu.example" })).rejects.toThrow(/Token/);
        expect(uploader.postSession).not.toHaveBeenCalled();
    });

    it("a council fetch counts as a successful request", async () => {
        const runner = createRunner();
        await runner.refreshCouncil({ force: true });
        expect(runner.state.connection.ok).toBe(true);
    });
});

describe("new data for the game", () => {
    it("council: set on the first write and on changed content, not on the same content again", async () => {
        const runner = createRunner();
        await runner.refreshCouncil({ force: true });
        expect(runner.state.council.changedAt).toBe(now);

        const first = now;
        now += 60 * 60 * 1000;
        // Same categories, only the time stamp of the payload moved on.
        council.syncCouncil.mockResolvedValue({ ...COUNCIL, payload: { ...COUNCIL.payload, generatedAt: 2 } });
        await runner.refreshCouncil({ force: true });
        expect(runner.state.council.changedAt).toBe(first);

        now += 60 * 60 * 1000;
        council.syncCouncil.mockResolvedValue({
            ...COUNCIL, payload: { ...COUNCIL.payload, categories: [{ id: "1", name: "SSC", raiders: [{}, {}] }] },
        });
        await runner.refreshCouncil({ force: true });
        expect(runner.state.council.changedAt).toBe(now);
    });

    it("council: nothing written, nothing new", async () => {
        council.syncCouncil.mockResolvedValue({ ...COUNCIL, dirs: [], files: [] });
        const runner = createRunner();
        await runner.refreshCouncil({ force: true });
        expect(runner.state.council.changedAt).toBe(0);
    });

    it("handouts: set on changed content; an empty list only once it empties a full one", async () => {
        const empty = { ...HANDOUTS, payload: { ...HANDOUTS.payload, banks: [] }, banks: 0, handouts: 0 };
        handouts.syncHandouts.mockResolvedValue(empty);
        const runner = createRunner();
        await runner.refreshHandouts({ force: true });
        // A server without a guild bank never asks for a /reload.
        expect(runner.state.handouts.changedAt).toBe(0);

        now += 1000;
        handouts.syncHandouts.mockResolvedValue(HANDOUTS);
        await runner.refreshHandouts({ force: true });
        expect(runner.state.handouts.changedAt).toBe(now);

        const filled = now;
        now += 1000;
        await runner.refreshHandouts({ force: true });
        expect(runner.state.handouts.changedAt).toBe(filled);

        now += 1000;
        handouts.syncHandouts.mockResolvedValue(empty);
        await runner.refreshHandouts({ force: true });
        expect(runner.state.handouts.changedAt).toBe(now);
    });
});
