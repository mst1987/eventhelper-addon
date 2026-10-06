"use strict";

// The runner's guild bank upload: a scan goes up once (not on every tick),
// a newer scan goes up again, a failure (404 while the server does not know
// the endpoint yet) is logged and retried later, and the loot upload is not
// affected either way. config/wowPaths/uploader/fs are mocked as in
// runner.uploadOne.test.js; config keeps what was saved, like the real file.
jest.mock("../lib/config");
jest.mock("../lib/wowPaths");
jest.mock("fs");
// UploadError stays the real class: the runner reads its status (404).
jest.mock("../lib/uploader", () => ({
    ...jest.createMockFromModule("../lib/uploader"),
    UploadError: jest.requireActual("../lib/uploader").UploadError,
}));

const fs = require("fs");
const config = require("../lib/config");
const wowPaths = require("../lib/wowPaths");
const uploader = require("../lib/uploader");
const { createRunner, GUILD_BANK_RETRY_MS } = require("../lib/runner");

const actual = jest.requireActual("../lib/uploader");

const scan = (over = {}) => ({
    format: "eventhelper-guildbank",
    version: 1,
    generatedAt: 1784574100,
    client: { project: "tbc", build: "2.5.5" },
    guild: { name: "Pulse", realm: "Thunderstrike", faction: "Alliance" },
    scannedBy: "Gemli-Thunderstrike",
    scannedAt: 1784574100,
    money: 5,
    tabs: [{ index: 1, name: "Mats", items: [{ itemId: 22445, count: 20, slot: 1 }] }],
    ...over,
});

let stored;
let now;

beforeEach(() => {
    jest.clearAllMocks();
    now = 1_800_000_000_000;
    jest.spyOn(Date, "now").mockImplementation(() => now);
    stored = {
        baseUrl: "https://example.test", token: "ehl_secret", savedVariablesPath: "x.lua",
        extraRoots: [], excludedSessions: [], uploadLog: {}, guildBankUploads: {},
    };
    config.load.mockImplementation(() => ({ ...stored }));
    config.save.mockImplementation((c) => { stored = { ...c }; return { ...stored }; });
    config.missing.mockReturnValue([]);
    wowPaths.discover.mockReturnValue([]);
    fs.existsSync.mockReturnValue(true);
    fs.statSync.mockReturnValue({ mtimeMs: 1 });
    uploader.readEnvelope.mockReturnValue({
        sessions: [{ sessionId: "s1", startedAt: 1, endedAt: 2, instance: "SSC", items: [{ source: "gargul" }] }],
    });
    uploader.uploadFile.mockResolvedValue({
        sessions: 1, skipped: 0, results: [{ sessionId: "s1", status: "pending", added: 1 }],
    });
    uploader.readGuildBank.mockReturnValue(scan());
    uploader.guildBankKey.mockImplementation(actual.guildBankKey);
    uploader.postGuildBank.mockResolvedValue({ ok: true });
});

afterEach(() => {
    jest.restoreAllMocks();
});

describe("createRunner — guild bank", () => {
    it("lädt einen neuen Scan genau einmal hoch, nicht bei jedem Durchlauf", async () => {
        const runner = createRunner();

        await runner.tick();
        await runner.tick();
        now += GUILD_BANK_RETRY_MS * 2;
        await runner.tick();

        expect(uploader.postGuildBank).toHaveBeenCalledTimes(1);
        expect(uploader.postGuildBank).toHaveBeenCalledWith(expect.objectContaining({ token: "ehl_secret" }), scan());
        expect(stored.guildBankUploads).toEqual({ "tbc|Thunderstrike|Pulse": 1784574100 });
        expect(runner.state.guildBank).toMatchObject({
            guild: "Pulse", realm: "Thunderstrike", project: "tbc", scannedAt: 1784574100000,
            tabs: 1, items: 1, uploaded: true, lastError: null,
        });
        expect(runner.state.log.some((e) => e.level === "ok" && /Gildenbank Pulse: hochgeladen/.test(e.text))).toBe(true);
    });

    it("lädt einen neueren Scan derselben Gildenbank erneut hoch", async () => {
        const runner = createRunner();
        await runner.tick();

        uploader.readGuildBank.mockReturnValue(scan({ scannedAt: 1784574999 }));
        runner.readState();
        expect(runner.state.guildBank.uploaded).toBe(false);
        await runner.syncGuildBank();

        expect(uploader.postGuildBank).toHaveBeenCalledTimes(2);
        expect(stored.guildBankUploads["tbc|Thunderstrike|Pulse"]).toBe(1784574999);
    });

    it("merkt sich den Upload je Gildenbank: eine andere Gilde verdeckt nichts", async () => {
        stored.guildBankUploads = { "forever|Thunderstrike|Pulse": 1884574100 };
        const runner = createRunner();
        await runner.tick();
        expect(uploader.postGuildBank).toHaveBeenCalledTimes(1);
    });

    it("lädt einen schon hochgeladenen Scan nach einem Neustart nicht noch einmal hoch", async () => {
        stored.guildBankUploads = { "tbc|Thunderstrike|Pulse": 1784574100 };
        const runner = createRunner();
        await runner.tick();
        expect(uploader.postGuildBank).not.toHaveBeenCalled();
        expect(runner.state.guildBank.uploaded).toBe(true);
    });

    it("protokolliert einen 404, versucht es nach der Pause erneut und stürzt nicht ab", async () => {
        uploader.postGuildBank.mockRejectedValueOnce(new uploader.UploadError("Unerwartete Antwort (HTTP 404)", 404));
        const runner = createRunner();

        await runner.tick();
        expect(runner.state.guildBank.uploaded).toBe(false);
        expect(runner.state.guildBank.lastError).toMatchObject({ message: "Unerwartete Antwort (HTTP 404)" });
        expect(runner.state.log.some((e) => e.level === "error" && /kennt \/api\/ingest\/guildbank noch nicht/.test(e.text)))
            .toBe(true);
        expect(stored.guildBankUploads).toEqual({});

        // within the pause: no new attempt
        now += GUILD_BANK_RETRY_MS - 1;
        await runner.tick();
        expect(uploader.postGuildBank).toHaveBeenCalledTimes(1);

        // after the pause: retried, and this time it works
        now += 2;
        await runner.tick();
        expect(uploader.postGuildBank).toHaveBeenCalledTimes(2);
        expect(runner.state.guildBank).toMatchObject({ uploaded: true, lastError: null });
        expect(stored.guildBankUploads).toEqual({ "tbc|Thunderstrike|Pulse": 1784574100 });
    });

    it("versucht es bei einer geänderten Datei sofort erneut", async () => {
        uploader.postGuildBank.mockRejectedValueOnce(new Error("ECONNREFUSED"));
        const runner = createRunner();
        await runner.tick();
        expect(uploader.postGuildBank).toHaveBeenCalledTimes(1);

        fs.statSync.mockReturnValue({ mtimeMs: 2 });
        // tick() waits 1.5 s for WoW to finish writing a changed file
        Date.now.mockRestore();
        await runner.tick();

        expect(uploader.postGuildBank).toHaveBeenCalledTimes(2);
        expect(runner.state.guildBank.uploaded).toBe(true);
    }, 10000);

    it("ein Fehler bei der Gildenbank hält den Loot-Upload nicht auf", async () => {
        uploader.postGuildBank.mockRejectedValue(new Error("Server nicht erreichbar"));
        const runner = createRunner();

        await runner.tick();

        expect(uploader.uploadFile).toHaveBeenCalledWith(expect.anything(), "x.lua");
        expect(runner.state.lastUpload.results).toEqual([{ sessionId: "s1", status: "pending", added: 1 }]);
        // the loot error state stays clean, the guild bank error lives on its own
        expect(runner.state.lastError).toBeNull();
        expect(runner.state.guildBank.lastError).toMatchObject({ message: "Server nicht erreichbar" });
    });

    it("ein Fehler beim Loot-Upload hält die Gildenbank nicht auf", async () => {
        uploader.uploadFile.mockRejectedValue(new Error("Loot kaputt"));
        const runner = createRunner();

        await runner.tick();

        expect(runner.state.lastError).toMatchObject({ message: "Loot kaputt" });
        expect(uploader.postGuildBank).toHaveBeenCalledTimes(1);
        expect(runner.state.guildBank.uploaded).toBe(true);
    });

    it("lädt nichts hoch, solange Adresse oder Token fehlen", async () => {
        config.missing.mockReturnValue(["token (…)"]);
        const runner = createRunner();

        await runner.tick();

        expect(uploader.postGuildBank).not.toHaveBeenCalled();
        // the UI still shows the scan
        expect(runner.state.guildBank).toMatchObject({ guild: "Pulse", uploaded: false });
    });

    it("ohne Scan in der Datei gibt es nichts zu tun", async () => {
        uploader.readGuildBank.mockReturnValue(null);
        const runner = createRunner();

        await runner.tick();

        expect(uploader.postGuildBank).not.toHaveBeenCalled();
        expect(runner.state.guildBank).toBeNull();
        expect(uploader.uploadFile).toHaveBeenCalled();
    });

    it("ein unlesbarer Gildenbank-Block stört das Lesen der Sessions nicht", async () => {
        uploader.readGuildBank.mockImplementation(() => { throw new Error("kaputt"); });
        const runner = createRunner();
        runner.readState();
        expect(runner.state.guildBank).toBeNull();
        expect(runner.state.sessions).toHaveLength(1);
        expect(runner.state.readError).toBeNull();
    });
});
