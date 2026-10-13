"use strict";

// The runner's LevelHelper part: the module switch (automatic = on when
// LevelHelper data exists), uploading only when a file was written, the pause
// after a failure, and the 404 of an older server (logged once, not retried
// until the next start). config/wowPaths/uploader/fs are mocked as in
// runner.guildbank.test.js; lib/levelhelper keeps its pure parts and has the
// file access and the upload replaced.
jest.mock("../lib/config");
jest.mock("../lib/wowPaths");
jest.mock("../lib/council");
jest.mock("fs");
jest.mock("../lib/guildbankHandouts", () => {
    const actual = jest.requireActual("../lib/guildbankHandouts");
    return { ...actual, syncHandouts: jest.fn(async () => { throw new Error("aus"); }), reportDone: jest.fn(), readGuildBankDone: jest.fn(() => []) };
});
jest.mock("../lib/uploader", () => ({
    ...jest.createMockFromModule("../lib/uploader"),
    UploadError: jest.requireActual("../lib/uploader").UploadError,
}));
jest.mock("../lib/levelhelper", () => ({
    ...jest.createMockFromModule("../lib/levelhelper"),
    lastUploadAt: jest.requireActual("../lib/levelhelper").lastUploadAt,
}));

const fs = require("fs");
const config = require("../lib/config");
const wowPaths = require("../lib/wowPaths");
const uploader = require("../lib/uploader");
const levelhelper = require("../lib/levelhelper");
const council = require("../lib/council");
const { createRunner, LEVELHELPER_RETRY_MS } = require("../lib/runner");

const INSTALL = { flavor: "_classic_beta_", versionId: "forever", accounts: [{ account: "A#1", file: "x", characters: [] }] };
const result = (over = {}) => ({
    known: { "forever|A#1": { Pulse: { at: 1_800_000_005_000, runs: { a: "h" }, chars: {} } } },
    summary: { runs: 12, golds: 4, characters: 30, guilds: 1, pending: 0 },
    sent: { requests: 1, runsAdded: 3, runsMerged: 1, runsSkipped: 0, charactersUpdated: 5, runs: 4, characters: 30 },
    error: null,
    notFound: false,
    ...over,
});

let stored;
let now;
let stamp;

beforeEach(() => {
    jest.clearAllMocks();
    now = 1_800_000_000_000;
    stamp = "s1";
    jest.spyOn(Date, "now").mockImplementation(() => now);
    stored = {
        baseUrl: "https://example.test", token: "ehl_secret", savedVariablesPath: "x.lua",
        extraRoots: [], excludedSessions: [], uploadLog: {}, guildBankUploads: {}, modules: {}, levelHelperUploads: {},
    };
    config.load.mockImplementation(() => ({ ...stored }));
    config.save.mockImplementation((c) => { stored = { ...c }; return { ...stored }; });
    config.missing.mockReturnValue([]);
    wowPaths.discover.mockReturnValue([]);
    wowPaths.flavorLabel.mockImplementation((f) => f);
    fs.existsSync.mockReturnValue(true);
    fs.statSync.mockReturnValue({ mtimeMs: 1 });
    uploader.readEnvelope.mockReturnValue({ sessions: [] });
    uploader.uploadFile.mockResolvedValue({ sessions: 0, skipped: 0, results: [] });
    uploader.readGuildBank.mockReturnValue(null);
    council.syncCouncil.mockRejectedValue(new Error("aus"));
    levelhelper.findInstalls.mockReturnValue({ installs: [INSTALL], skipped: [] });
    levelhelper.signature.mockImplementation(() => stamp);
    levelhelper.syncInstalls.mockResolvedValue(result());
});

afterEach(() => {
    jest.restoreAllMocks();
});

const errors = (runner) => runner.state.log.filter((e) => e.level === "error" || e.level === "warn");

describe("createRunner — LevelHelper", () => {
    it("lädt automatisch hoch, wenn LevelHelper-Daten da sind, und füllt die Kachel", async () => {
        const runner = createRunner();
        await runner.tick();

        expect(levelhelper.syncInstalls).toHaveBeenCalledTimes(1);
        expect(levelhelper.syncInstalls.mock.calls[0][0]).toMatchObject({ token: "ehl_secret" });
        expect(levelhelper.syncInstalls.mock.calls[0][1].installs).toEqual([INSTALL]);
        expect(runner.state.levelHelper).toMatchObject({
            show: true, enabled: true, auto: true, found: true, versions: ["forever"],
            runs: 12, golds: 4, characters: 30, guilds: 1, lastUpload: 1_800_000_005_000, lastError: null, unsupported: false,
        });
        expect(stored.levelHelperUploads).toEqual(result().known);
        expect(runner.state.log.some((e) => e.level === "ok" && /LevelHelper-Bestzeiten: hochgeladen — 3 Lauf\/Läufe neu, 1 zusammengeführt, 5 Charakter\(e\) aktualisiert/.test(e.text))).toBe(true);
    });

    it("lädt auch ohne Loot-Datei hoch", async () => {
        fs.existsSync.mockReturnValue(false);
        const runner = createRunner();
        await runner.tick();
        expect(levelhelper.syncInstalls).toHaveBeenCalledTimes(1);
    });

    it("bleibt aus und zeigt keine Kachel, wenn es keine LevelHelper-Daten gibt", async () => {
        levelhelper.findInstalls.mockReturnValue({ installs: [], skipped: [] });
        const runner = createRunner();
        await runner.tick();
        expect(levelhelper.syncInstalls).not.toHaveBeenCalled();
        expect(runner.state.levelHelper).toMatchObject({ show: false, enabled: false, auto: true, found: false });
    });

    it("lädt nichts hoch, wenn das Modul ausgeschaltet ist, zeigt aber die Kachel (Daten sind da)", async () => {
        stored.modules = { levelhelper: false };
        const runner = createRunner();
        await runner.tick();
        expect(levelhelper.syncInstalls).not.toHaveBeenCalled();
        expect(runner.state.levelHelper).toMatchObject({ show: true, enabled: false, auto: false, found: true });
    });

    it("ein eingeschaltetes Modul ohne Daten zeigt die Kachel und lädt nichts hoch", async () => {
        stored.modules = { levelhelper: true };
        levelhelper.findInstalls.mockReturnValue({ installs: [], skipped: [] });
        const runner = createRunner();
        await runner.tick();
        expect(levelhelper.syncInstalls).not.toHaveBeenCalled();
        expect(runner.state.levelHelper).toMatchObject({ show: true, enabled: true, auto: false, found: false });
    });

    it("wartet mit dem Hochladen auf die Einrichtung (Adresse und Token)", async () => {
        config.missing.mockReturnValue(["token"]);
        const runner = createRunner();
        await runner.tick();
        expect(levelhelper.syncInstalls).not.toHaveBeenCalled();
        expect(runner.state.levelHelper.enabled).toBe(true);
    });

    it("prüft nur neu, wenn eine LevelHelper-Datei geschrieben wurde", async () => {
        const runner = createRunner();
        await runner.tick();
        await runner.tick();
        expect(levelhelper.syncInstalls).toHaveBeenCalledTimes(1);

        stamp = "s2";
        await runner.tick();
        expect(levelhelper.syncInstalls).toHaveBeenCalledTimes(2);
        // the saved state goes back in
        expect(levelhelper.syncInstalls.mock.calls[1][1].known).toEqual(result().known);
    });

    it("nach einem Fehler: Pause, bei geänderter Datei sofort, sonst nach 5 Minuten", async () => {
        levelhelper.syncInstalls.mockResolvedValueOnce(result({
            error: new uploader.UploadError("Server weg"), sent: { requests: 0 }, summary: { runs: 12, golds: 4, characters: 3, guilds: 1, pending: 9 },
        }));
        const runner = createRunner();
        await runner.tick();
        expect(runner.state.levelHelper.lastError).toMatchObject({ message: "Server weg" });
        expect(errors(runner).some((e) => /LevelHelper-Bestzeiten: Upload fehlgeschlagen — Server weg/.test(e.text))).toBe(true);
        expect(uploader.UploadError).toBeDefined();

        now += 60_000;
        await runner.tick();
        expect(levelhelper.syncInstalls).toHaveBeenCalledTimes(1);

        now += LEVELHELPER_RETRY_MS;
        await runner.tick();
        expect(levelhelper.syncInstalls).toHaveBeenCalledTimes(2);
        expect(runner.state.levelHelper.lastError).toBeNull();
    });

    it("nach einem Fehler und einer geänderten Datei sofort noch einmal", async () => {
        levelhelper.syncInstalls.mockResolvedValueOnce(result({ error: new uploader.UploadError("Server weg"), sent: { requests: 0 } }));
        const runner = createRunner();
        await runner.tick();
        stamp = "s2";
        await runner.tick();
        expect(levelhelper.syncInstalls).toHaveBeenCalledTimes(2);
    });

    it("404 eines älteren Servers: einmal melden und bis zum nächsten Start nicht mehr versuchen", async () => {
        levelhelper.syncInstalls.mockResolvedValue(result({
            error: new uploader.UploadError("HTTP 404", 404), notFound: true, sent: { requests: 0 },
        }));
        const runner = createRunner();
        await runner.tick();
        stamp = "s2";
        await runner.tick();
        now += LEVELHELPER_RETRY_MS * 3;
        stamp = "s3";
        await runner.tick();

        expect(levelhelper.syncInstalls).toHaveBeenCalledTimes(1);
        const notices = runner.state.log.filter((e) => /Server kennt LevelHelper-Upload noch nicht/.test(e.text));
        expect(notices).toHaveLength(1);
        expect(runner.state.levelHelper).toMatchObject({ unsupported: true, lastError: null });
        // a new runner = a new tool start tries again
        const restarted = createRunner();
        await restarted.tick();
        expect(levelhelper.syncInstalls).toHaveBeenCalledTimes(2);
    });

    it("das Umschalten in den Einstellungen wirkt nach reload()", async () => {
        const runner = createRunner();
        await runner.tick();
        expect(levelhelper.syncInstalls).toHaveBeenCalledTimes(1);

        stored.modules = { levelhelper: false };
        runner.reload();
        await runner.syncLevelHelper();
        expect(runner.state.levelHelper).toMatchObject({ enabled: false, show: true, auto: false });
        expect(levelhelper.syncInstalls).toHaveBeenCalledTimes(1);

        stored.modules = { levelhelper: true };
        runner.reload();
        await runner.syncLevelHelper();
        expect(runner.state.levelHelper.enabled).toBe(true);
        expect(levelhelper.syncInstalls).toHaveBeenCalledTimes(2);
        runner.stop();
    });

    it("meldet eine Variante mit unbekannter Spielversion einmal", async () => {
        levelhelper.findInstalls.mockReturnValue({ installs: [], skipped: ["_ptr_"] });
        const runner = createRunner();
        await runner.tick();
        runner.reload();
        await runner.tick();
        runner.stop();
        const notices = runner.state.log.filter((e) => /LevelHelper in _ptr_ gefunden/.test(e.text));
        expect(notices).toHaveLength(1);
    });
});
