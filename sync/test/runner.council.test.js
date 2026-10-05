"use strict";

// Der Council-Abruf im laufenden Betrieb: wann er passiert, was er im Zustand
// hinterlässt — und vor allem, dass sein Scheitern den Upload nie anhält.
jest.mock("../lib/config");
jest.mock("../lib/wowPaths");
jest.mock("../lib/uploader");
jest.mock("../lib/council");
jest.mock("fs");

const fs = require("fs");
const config = require("../lib/config");
const wowPaths = require("../lib/wowPaths");
const uploader = require("../lib/uploader");
const council = require("../lib/council");
const { createRunner, COUNCIL_INTERVAL_MS } = require("../lib/runner");

const CFG = {
    baseUrl: "https://example.test", token: "ehl_secret", savedVariablesPath: "x.lua",
    extraRoots: [], excludedSessions: [], uploadLog: {}, pollSeconds: 15,
    councilCategory: "", councilRole: "",
};

const RESULT = {
    payload: {
        format: "eventhelper-council", version: 1, generatedAt: 1791234567,
        filter: { categoryName: "SSC/TK Mittwoch", role: "", bisTier: "t6" },
        categories: [{ id: 123, name: "SSC/TK Mittwoch" }],
        raiders: [],
    },
    raiders: 24,
    dirs: [{ flavor: "_anniversary_", dir: "A" }, { flavor: "_classic_beta_", dir: "B" }],
    files: ["A/CouncilData.lua", "B/CouncilData.lua"],
    errors: [],
};

/** Alle anstehenden Promise-Fortsetzungen abarbeiten. */
const flush = () => new Promise((r) => jest.requireActual("timers").setImmediate(r));

beforeEach(() => {
    jest.clearAllMocks();
    config.load.mockReturnValue(CFG);
    config.save.mockImplementation((c) => c);
    config.missing.mockReturnValue([]);
    wowPaths.discover.mockReturnValue([]);
    fs.existsSync.mockReturnValue(true);
    fs.statSync.mockReturnValue({ mtimeMs: 1 });
    uploader.readEnvelope.mockReturnValue({
        sessions: [{ sessionId: "s1", startedAt: 1, endedAt: 2, instance: "SSC", items: [{ source: "gargul" }] }],
    });
    uploader.uploadFile.mockResolvedValue({ sessions: 1, skipped: 0, results: [{ sessionId: "s1", status: "pending", added: 1 }] });
    council.syncCouncil.mockResolvedValue(RESULT);
});

describe("refreshCouncil", () => {
    it("übernimmt das Ergebnis in den Zustand", async () => {
        const runner = createRunner();
        const result = await runner.refreshCouncil({ force: true });

        expect(result).toBe(RESULT);
        expect(council.syncCouncil).toHaveBeenCalledWith(CFG);
        expect(runner.state.council).toMatchObject({
            fetching: false,
            raiders: 24,
            generatedAt: 1791234567,
            categoryName: "SSC/TK Mittwoch",
            bisTier: "t6",
            categories: [{ id: "123", name: "SSC/TK Mittwoch" }],
            files: RESULT.files,
            lastError: null,
        });
        expect(runner.state.council.lastFetch).toBeGreaterThan(0);
        expect(runner.state.log.some((e) => /24 Raider in 2 Addon-Ordner/.test(e.text))).toBe(true);
    });

    it("wirft nie, sondern merkt sich den Fehler", async () => {
        council.syncCouncil.mockRejectedValue(new Error("Server weg"));
        const runner = createRunner();

        await expect(runner.refreshCouncil({ force: true })).resolves.toBeNull();
        expect(runner.state.council.lastError).toMatchObject({ message: "Server weg" });
        expect(runner.state.council.fetching).toBe(false);
        expect(runner.state.log.some((e) => e.level === "error" && /Council-Daten: Server weg/.test(e.text))).toBe(true);
    });

    it("warnt, wenn kein Addon-Ordner gefunden wurde", async () => {
        council.syncCouncil.mockResolvedValue({ ...RESULT, dirs: [], files: [] });
        const runner = createRunner();
        await runner.refreshCouncil({ force: true });
        expect(runner.state.log.some((e) => e.level === "warn" && /kein installierter/.test(e.text))).toBe(true);
    });

    it("meldet nicht geschriebene Ordner als Fehler", async () => {
        council.syncCouncil.mockResolvedValue({ ...RESULT, files: ["A/CouncilData.lua"], errors: ["B: EACCES"] });
        const runner = createRunner();
        await runner.refreshCouncil({ force: true });
        expect(runner.state.council.lastError).toMatchObject({ message: "B: EACCES" });
    });

    it("fragt ohne Einrichtung nicht beim Server, und sagt es nur auf Klick", async () => {
        config.missing.mockReturnValue(["token"]);
        const runner = createRunner();

        await expect(runner.refreshCouncil()).resolves.toBeNull();
        expect(runner.state.council.lastError).toBeNull();
        await expect(runner.refreshCouncil({ force: true })).resolves.toBeNull();
        expect(runner.state.council.lastError.message).toMatch(/Noch nicht eingerichtet/);
        expect(council.syncCouncil).not.toHaveBeenCalled();
    });

    it("lässt automatische Anlässe binnen einer Minute zusammenfallen, einen Klick nicht", async () => {
        const runner = createRunner();
        await runner.refreshCouncil();
        await runner.refreshCouncil();
        expect(council.syncCouncil).toHaveBeenCalledTimes(1);
        await runner.refreshCouncil({ force: true });
        expect(council.syncCouncil).toHaveBeenCalledTimes(2);
    });

    it("startet keinen zweiten Abruf, solange einer läuft", async () => {
        let release;
        council.syncCouncil.mockImplementation(() => new Promise((r) => { release = () => r(RESULT); }));
        const runner = createRunner();
        const a = runner.refreshCouncil({ force: true });
        const b = runner.refreshCouncil({ force: true });
        expect(a).toBe(b);
        release();
        await a;
        expect(council.syncCouncil).toHaveBeenCalledTimes(1);
    });
});

describe("Council im laufenden Betrieb", () => {
    it("holt nach einem erfolgreichen Upload", async () => {
        const runner = createRunner();
        runner.readState();
        await runner.uploadNow();
        await flush();
        expect(council.syncCouncil).toHaveBeenCalledTimes(1);
    });

    it("ein scheiternder Council-Abruf hält die Uploads nicht an", async () => {
        council.syncCouncil.mockRejectedValue(new Error("kaputt"));
        const runner = createRunner();

        await runner.tick();
        await flush();
        expect(uploader.uploadFile).toHaveBeenCalledTimes(1);
        expect(runner.state.lastError).toBeNull();

        // Die Datei ändert sich: der nächste Durchlauf lädt trotzdem wieder hoch.
        fs.statSync.mockReturnValue({ mtimeMs: 2 });
        jest.useFakeTimers({ doNotFake: ["setImmediate", "nextTick"] });
        try {
            const tick = runner.tick();
            await jest.advanceTimersByTimeAsync(2000);
            await tick;
        } finally {
            jest.useRealTimers();
        }
        expect(uploader.uploadFile).toHaveBeenCalledTimes(2);
        expect(runner.state.council.lastError).toMatchObject({ message: "kaputt" });
    });

    it("holt beim Start und danach alle 15 Minuten", async () => {
        jest.useFakeTimers({ doNotFake: ["setImmediate", "nextTick"] });
        const runner = createRunner();
        try {
            runner.start();
            await jest.advanceTimersByTimeAsync(10);
            // Start und erster Upload fallen zu einem Abruf zusammen.
            expect(council.syncCouncil).toHaveBeenCalledTimes(1);

            await jest.advanceTimersByTimeAsync(COUNCIL_INTERVAL_MS);
            expect(council.syncCouncil).toHaveBeenCalledTimes(2);

            runner.stop();
            await jest.advanceTimersByTimeAsync(COUNCIL_INTERVAL_MS * 2);
            expect(council.syncCouncil).toHaveBeenCalledTimes(2);
        } finally {
            runner.stop();
            jest.useRealTimers();
        }
    });

    it("holt nach geänderten Council-Einstellungen sofort neu", async () => {
        const runner = createRunner();
        await runner.refreshCouncil();
        expect(council.syncCouncil).toHaveBeenCalledTimes(1);

        config.load.mockReturnValue({ ...CFG, councilRole: "healer" });
        runner.reload();
        await flush();
        runner.stop();
        expect(council.syncCouncil).toHaveBeenCalledTimes(2);
    });
});
