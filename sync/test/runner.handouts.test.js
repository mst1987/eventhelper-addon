"use strict";

// The runner's guild bank handouts: when the list is fetched (start, every
// 5 minutes, after uploads, after a guild bank scan went up, on new
// settings), that a failure never stops anything, and the reporting of the
// entries ticked in game (batched in lib/guildbankHandouts.js): sent once,
// remembered in the config, retried after a failure, followed by a fresh
// fetch. config/wowPaths/uploader/fs are mocked as in the other runner tests.
jest.mock("../lib/config");
jest.mock("../lib/wowPaths");
jest.mock("../lib/council");
jest.mock("fs");
jest.mock("../lib/uploader", () => ({
    ...jest.createMockFromModule("../lib/uploader"),
    UploadError: jest.requireActual("../lib/uploader").UploadError,
}));
// The pure helpers stay real, network and file access are mocked.
jest.mock("../lib/guildbankHandouts", () => {
    const actual = jest.requireActual("../lib/guildbankHandouts");
    return {
        ...actual,
        syncHandouts: jest.fn(),
        reportDone: jest.fn(),
        readGuildBankDone: jest.fn(),
    };
});

const fs = require("fs");
const config = require("../lib/config");
const wowPaths = require("../lib/wowPaths");
const uploader = require("../lib/uploader");
const council = require("../lib/council");
const handouts = require("../lib/guildbankHandouts");
const {
    createRunner, HANDOUTS_INTERVAL_MS, HANDOUTS_MIN_GAP_MS, HANDOUTS_REPORT_RETRY_MS,
} = require("../lib/runner");

const actualUploader = jest.requireActual("../lib/uploader");

const RESULT = {
    payload: { format: "eventhelper-guildbank-handouts", version: 1, generatedAt: 1791294674, banks: [{ handouts: [{}, {}] }] },
    banks: 1,
    handouts: 2,
    dirs: [{ flavor: "_anniversary_", dir: "A" }],
    files: ["A/GuildBankData.lua"],
    errors: [],
};

const DONE = [
    { id: "a1", via: "manual", by: "Gemli-Thunderstrike", at: 1791300000 },
    { id: "b2", via: "mail", by: "Gemli-Thunderstrike", at: 1791300001 },
];

/** Run all pending promise continuations. */
const flush = () => new Promise((r) => jest.requireActual("timers").setImmediate(r));

let stored;
let now;

beforeEach(() => {
    jest.clearAllMocks();
    now = 1_800_000_000_000;
    jest.spyOn(Date, "now").mockImplementation(() => now);
    stored = {
        baseUrl: "https://example.test", token: "ehl_secret", savedVariablesPath: "x.lua",
        extraRoots: [], excludedSessions: [], uploadLog: {}, guildBankUploads: {}, guildBankDoneReported: {},
        pollSeconds: 15,
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
    uploader.uploadFile.mockResolvedValue({ sessions: 1, skipped: 0, results: [{ sessionId: "s1", status: "pending", added: 1 }] });
    uploader.readGuildBank.mockReturnValue(null);
    uploader.guildBankKey.mockImplementation(actualUploader.guildBankKey);
    council.syncCouncil.mockResolvedValue(null);
    handouts.syncHandouts.mockResolvedValue(RESULT);
    handouts.readGuildBankDone.mockReturnValue([]);
    handouts.reportDone.mockImplementation(async (_cfg, entries) => ({
        reported: entries.map((e) => e.id), ok: entries.map((e) => e.id),
        duplicate: [], notConfirmed: [], unknown: [], invalid: 0,
    }));
});

afterEach(() => {
    jest.restoreAllMocks();
});

describe("refreshHandouts", () => {
    it("übernimmt das Ergebnis in den Zustand und protokolliert es", async () => {
        const runner = createRunner();
        const result = await runner.refreshHandouts({ force: true });

        expect(result).toBe(RESULT);
        expect(handouts.syncHandouts).toHaveBeenCalledWith(expect.objectContaining({ token: "ehl_secret" }));
        expect(runner.state.handouts).toMatchObject({
            fetching: false, generatedAt: 1791294674, banks: 1, handouts: 2, files: RESULT.files, lastError: null,
        });
        expect(runner.state.handouts.lastFetch).toBe(now);
        expect(runner.state.log.filter((e) => /Ausgabeliste: 2 Posten aus 1 Gildenbank/.test(e.text))).toHaveLength(1);
    });

    it("protokolliert eine unveränderte Liste nicht jedes Mal", async () => {
        const runner = createRunner();
        await runner.refreshHandouts({ force: true });
        await runner.refreshHandouts({ force: true });
        expect(handouts.syncHandouts).toHaveBeenCalledTimes(2);
        expect(runner.state.log.filter((e) => /Ausgabeliste: /.test(e.text))).toHaveLength(1);
    });

    it("wirft nie, merkt sich den Fehler und protokolliert ihn nur einmal", async () => {
        handouts.syncHandouts.mockRejectedValue(new Error("Server weg"));
        const runner = createRunner();

        await expect(runner.refreshHandouts()).resolves.toBeNull();
        now += HANDOUTS_MIN_GAP_MS + 1;
        await expect(runner.refreshHandouts()).resolves.toBeNull();
        expect(handouts.syncHandouts).toHaveBeenCalledTimes(2);
        expect(runner.state.handouts.lastError).toMatchObject({ message: "Server weg" });
        expect(runner.state.handouts.fetching).toBe(false);
        expect(runner.state.log.filter((e) => e.level === "error" && /Ausgabeliste: Server weg/.test(e.text)))
            .toHaveLength(1);
    });

    it("warnt, wenn kein Addon-Ordner gefunden wurde, und meldet nicht beschreibbare", async () => {
        handouts.syncHandouts.mockResolvedValueOnce({ ...RESULT, dirs: [], files: [] });
        const runner = createRunner();
        await runner.refreshHandouts({ force: true });
        expect(runner.state.log.some((e) => e.level === "warn" && /kein installierter/.test(e.text))).toBe(true);

        handouts.syncHandouts.mockResolvedValueOnce({ ...RESULT, errors: ["B: EACCES"] });
        await runner.refreshHandouts({ force: true });
        expect(runner.state.handouts.lastError).toMatchObject({ message: "B: EACCES" });
    });

    it("fragt ohne Einrichtung nicht, und sagt es nur auf Klick", async () => {
        config.missing.mockReturnValue(["token"]);
        const runner = createRunner();
        await expect(runner.refreshHandouts()).resolves.toBeNull();
        expect(runner.state.handouts.lastError).toBeNull();
        await runner.refreshHandouts({ force: true });
        expect(runner.state.handouts.lastError.message).toMatch(/Noch nicht eingerichtet/);
        expect(handouts.syncHandouts).not.toHaveBeenCalled();
    });

    it("lässt automatische Anlässe binnen einer Minute zusammenfallen", async () => {
        const runner = createRunner();
        await runner.refreshHandouts();
        await runner.refreshHandouts();
        expect(handouts.syncHandouts).toHaveBeenCalledTimes(1);
        now += HANDOUTS_MIN_GAP_MS + 1;
        await runner.refreshHandouts();
        expect(handouts.syncHandouts).toHaveBeenCalledTimes(2);
    });

    it("holt nach einem erzwungenen Abruf während eines laufenden noch einmal", async () => {
        let release;
        handouts.syncHandouts.mockImplementationOnce(() => new Promise((r) => { release = () => r(RESULT); }));
        const runner = createRunner();
        const a = runner.refreshHandouts({ force: true });
        const b = runner.refreshHandouts();
        expect(a).toBe(b);
        runner.refreshHandouts({ force: true });
        release();
        await a;
        await flush();
        expect(handouts.syncHandouts).toHaveBeenCalledTimes(2);
    });
});

describe("Ausgabeliste im laufenden Betrieb", () => {
    it("holt beim Start und danach alle 5 Minuten", async () => {
        Date.now.mockRestore();
        jest.useFakeTimers({ doNotFake: ["setImmediate", "nextTick"] });
        const runner = createRunner();
        try {
            runner.start();
            await jest.advanceTimersByTimeAsync(10);
            // start and the first upload fall together
            expect(handouts.syncHandouts).toHaveBeenCalledTimes(1);

            await jest.advanceTimersByTimeAsync(HANDOUTS_INTERVAL_MS);
            expect(handouts.syncHandouts).toHaveBeenCalledTimes(2);
            await jest.advanceTimersByTimeAsync(HANDOUTS_INTERVAL_MS);
            expect(handouts.syncHandouts).toHaveBeenCalledTimes(3);

            runner.stop();
            await jest.advanceTimersByTimeAsync(HANDOUTS_INTERVAL_MS * 3);
            expect(handouts.syncHandouts).toHaveBeenCalledTimes(3);
        } finally {
            runner.stop();
            jest.useRealTimers();
        }
    });

    it("holt nach einem Upload", async () => {
        const runner = createRunner();
        runner.readState();
        await runner.uploadNow();
        await flush();
        expect(handouts.syncHandouts).toHaveBeenCalledTimes(1);
    });

    it("holt nach einem hochgeladenen Gildenbank-Scan sofort neu", async () => {
        const runner = createRunner();
        await runner.refreshHandouts();
        expect(handouts.syncHandouts).toHaveBeenCalledTimes(1);

        uploader.readGuildBank.mockReturnValue({
            format: "eventhelper-guildbank", version: 1, scannedAt: 1784574100,
            client: { project: "tbc" }, guild: { name: "Pulse", realm: "Thunderstrike" }, tabs: [],
        });
        uploader.postGuildBank.mockResolvedValue({ ok: true });
        runner.readState();
        await runner.syncGuildBank();
        await flush();
        // within the minute, but forced
        expect(handouts.syncHandouts).toHaveBeenCalledTimes(2);
    });

    it("ein scheiternder Abruf hält Upload und Gildenbank nicht an", async () => {
        handouts.syncHandouts.mockRejectedValue(new Error("kaputt"));
        const runner = createRunner();
        await runner.tick();
        await flush();
        expect(uploader.uploadFile).toHaveBeenCalledTimes(1);
        expect(runner.state.lastError).toBeNull();
        expect(runner.state.handouts.lastError).toMatchObject({ message: "kaputt" });
    });

    it("holt nach neuer Adresse oder neuem Token sofort", async () => {
        const runner = createRunner();
        await runner.refreshHandouts();
        expect(handouts.syncHandouts).toHaveBeenCalledTimes(1);

        runner.reload();
        await flush();
        // nothing changed: within the minute nothing new
        expect(handouts.syncHandouts).toHaveBeenCalledTimes(1);

        stored.token = "ehl_new";
        runner.reload();
        await flush();
        runner.stop();
        expect(handouts.syncHandouts).toHaveBeenCalledTimes(2);
    });
});

describe("abgehakte Posten melden", () => {
    it("meldet sie beim Durchlauf, merkt sie sich und holt danach neu", async () => {
        handouts.readGuildBankDone.mockReturnValue(DONE);
        const runner = createRunner();
        runner.readState();
        expect(runner.state.handouts.done).toBe(2);

        await runner.tick();
        await flush();

        expect(handouts.reportDone).toHaveBeenCalledTimes(1);
        expect(handouts.reportDone).toHaveBeenCalledWith(expect.objectContaining({ token: "ehl_secret" }), DONE);
        expect(stored.guildBankDoneReported).toEqual({ a1: now, b2: now });
        expect(runner.state.handouts.done).toBe(0);
        expect(runner.state.handouts.lastReport).toMatchObject({ reported: 2, ok: 2 });
        expect(runner.state.log.some((e) => e.level === "ok" && /2 abgehakte\(n\) Posten gemeldet/.test(e.text)))
            .toBe(true);
        // the forced fetch after the report (the upload's own one fell together with it or ran first)
        const calls = handouts.syncHandouts.mock.calls.length;
        expect(calls).toBeGreaterThanOrEqual(1);
    });

    it("schickt schon gemeldete ids nicht noch einmal, neue schon", async () => {
        handouts.readGuildBankDone.mockReturnValue(DONE);
        const runner = createRunner();
        await runner.tick();
        await runner.tick();
        expect(handouts.reportDone).toHaveBeenCalledTimes(1);

        // a restart knows them from the config
        const again = createRunner();
        await again.tick();
        expect(handouts.reportDone).toHaveBeenCalledTimes(1);

        handouts.readGuildBankDone.mockReturnValue([...DONE, { id: "c3", via: "manual", by: "", at: 0 }]);
        await again.tick();
        expect(handouts.reportDone).toHaveBeenCalledTimes(2);
        expect(handouts.reportDone.mock.calls[1][1].map((e) => e.id)).toEqual(["c3"]);
    });

    it("holt nach dem Melden mit Vorrang neu, auch kurz nach dem letzten Abruf", async () => {
        const runner = createRunner();
        await runner.refreshHandouts();
        expect(handouts.syncHandouts).toHaveBeenCalledTimes(1);

        handouts.readGuildBankDone.mockReturnValue(DONE);
        runner.readState();
        await runner.reportHandoutsDone();
        await flush();
        expect(handouts.syncHandouts).toHaveBeenCalledTimes(2);
    });

    it("versucht es nach einem Serverfehler erst nach der Pause erneut", async () => {
        handouts.readGuildBankDone.mockReturnValue(DONE);
        handouts.reportDone.mockRejectedValueOnce(
            new handouts.HandoutsError("Wartung", { status: 503, reported: [] }),
        );
        const runner = createRunner();
        await runner.tick();

        expect(handouts.reportDone).toHaveBeenCalledTimes(1);
        expect(stored.guildBankDoneReported).toEqual({});
        expect(runner.state.handouts.reportError).toMatchObject({ message: "Wartung" });
        expect(runner.state.handouts.done).toBe(2);
        expect(runner.state.log.some((e) => e.level === "error" && /Melden fehlgeschlagen — Wartung/.test(e.text)))
            .toBe(true);

        now += HANDOUTS_REPORT_RETRY_MS - 1;
        await runner.tick();
        expect(handouts.reportDone).toHaveBeenCalledTimes(1);

        now += 2;
        await runner.tick();
        expect(handouts.reportDone).toHaveBeenCalledTimes(2);
        expect(stored.guildBankDoneReported).toEqual({ a1: now, b2: now });
        expect(runner.state.handouts.reportError).toBeNull();
    });

    it("merkt sich bei einem Fehler die Pakete, die schon durch sind", async () => {
        handouts.readGuildBankDone.mockReturnValue(DONE);
        handouts.reportDone.mockRejectedValueOnce(
            new handouts.HandoutsError("Wartung", { status: 503, reported: ["a1"] }),
        );
        const runner = createRunner();
        await runner.tick();
        expect(stored.guildBankDoneReported).toEqual({ a1: now });
        expect(runner.state.handouts.done).toBe(1);

        now += HANDOUTS_REPORT_RETRY_MS + 1;
        await runner.tick();
        expect(handouts.reportDone.mock.calls[1][1].map((e) => e.id)).toEqual(["b2"]);
    });

    it("versucht es bei einer geänderten Datei sofort erneut", async () => {
        handouts.readGuildBankDone.mockReturnValue(DONE);
        handouts.reportDone.mockRejectedValueOnce(new Error("ECONNREFUSED"));
        const runner = createRunner();
        await runner.tick();
        expect(handouts.reportDone).toHaveBeenCalledTimes(1);

        fs.statSync.mockReturnValue({ mtimeMs: 2 });
        // tick() waits 1.5 s for WoW to finish writing a changed file
        Date.now.mockRestore();
        await runner.tick();
        expect(handouts.reportDone).toHaveBeenCalledTimes(2);
    }, 10000);

    it("meldet nichts ohne Einrichtung und nichts ohne abgehakte Posten", async () => {
        const runner = createRunner();
        await runner.tick();
        expect(handouts.reportDone).not.toHaveBeenCalled();

        handouts.readGuildBankDone.mockReturnValue(DONE);
        config.missing.mockReturnValue(["token"]);
        const other = createRunner();
        other.readState();
        await expect(other.reportHandoutsDone({ force: true })).resolves.toBe(false);
        expect(handouts.reportDone).not.toHaveBeenCalled();
        expect(other.state.handouts.done).toBe(2);
    });

    it("eine unlesbare Datei stört weder Sessions noch Meldungen", async () => {
        handouts.readGuildBankDone.mockImplementation(() => { throw new Error("kaputt"); });
        const runner = createRunner();
        runner.readState();
        expect(runner.state.sessions).toHaveLength(1);
        expect(runner.state.handouts.done).toBe(0);
    });

    it("vergisst gemeldete ids nach 30 Tagen", async () => {
        stored.guildBankDoneReported = { alt: now - 31 * 24 * 3600 * 1000, frisch: now - 1000 };
        handouts.readGuildBankDone.mockReturnValue([DONE[0]]);
        const runner = createRunner();
        await runner.tick();
        expect(stored.guildBankDoneReported).toEqual({ frisch: now - 1000, a1: now });
    });
});
