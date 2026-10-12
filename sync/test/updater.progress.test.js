"use strict";

// Download progress, stall detection and the error state of the installer
// (1.16.5 -> 1.16.6: the strip stayed on "Wird installiert ..." with no sign of
// life). Bodies are real ReadableStreams so the streaming code path runs; the
// test decides when each chunk arrives.
const fs = require("fs");
const os = require("os");
const path = require("path");
const crypto = require("crypto");
const { createUpdater, download, relaunch, LATEST_URL, STALL_MS } = require("../lib/updater");

const sha = (buf) => crypto.createHash("sha256").update(buf).digest("hex");
const tick = () => new Promise((r) => setImmediate(r));

/** A response whose chunks the test enqueues itself. */
function controlledResponse(total, { withLength = true } = {}) {
    let controller;
    const body = new ReadableStream({ start(c) { controller = c; } });
    const res = new Response(body, { status: 200, headers: withLength ? { "content-length": String(total) } : {} });
    return {
        res,
        push: (buf) => controller.enqueue(new Uint8Array(buf)),
        end: () => controller.close(),
    };
}

describe("download: Fortschritt", () => {
    const data = Buffer.alloc(1000, 7);
    const asset = { name: "a.exe", url: "https://example.test/a", size: data.length, sha256: sha(data) };

    it("zählt Bytes gegen Content-Length und meldet erst Laden, dann Prüfen", async () => {
        const ctl = controlledResponse(data.length);
        const seen = [];
        const p = download(asset, { fetchImpl: async () => ctl.res, onProgress: (x) => seen.push({ ...x }) });
        await tick();
        ctl.push(data.subarray(0, 250));
        await tick();
        ctl.push(data.subarray(250, 600));
        await tick();
        ctl.push(data.subarray(600));
        ctl.end();
        const buf = await p;
        expect(buf.equals(data)).toBe(true);
        const download_ = seen.filter((s) => s.step === "download").map((s) => s.received);
        expect(download_).toEqual([0, 250, 600, 1000]);
        expect(seen.every((s) => s.total === 1000)).toBe(true);
        expect(seen[seen.length - 1]).toEqual({ step: "verify", received: 1000, total: 1000 });
    });

    it("nimmt ohne Content-Length die Grösse des Release-Anhangs", async () => {
        const ctl = controlledResponse(0, { withLength: false });
        const seen = [];
        const p = download(asset, { fetchImpl: async () => ctl.res, onProgress: (x) => seen.push(x) });
        await tick();
        ctl.push(data);
        ctl.end();
        await p;
        expect(seen[0].total).toBe(1000);
    });

    it("prüft weiter Grösse und Prüfsumme", async () => {
        const ctl = controlledResponse(5);
        const p = download({ ...asset, size: 0, sha256: "0".repeat(64) }, { fetchImpl: async () => ctl.res });
        await tick();
        ctl.push(Buffer.from("hallo"));
        ctl.end();
        await expect(p).rejects.toThrow(/Prüfsumme/);
    });
});

describe("download: hängende Verbindung", () => {
    const asset = { name: "a.exe", url: "https://example.test/a", size: 100, sha256: "" };

    it("bricht ab, wenn keine Bytes mehr kommen", async () => {
        const ctl = controlledResponse(100);
        const p = download(asset, { fetchImpl: async () => ctl.res, stallMs: 40 });
        await tick();
        ctl.push(Buffer.alloc(10));
        await expect(p).rejects.toThrow(/^Download hängt – keine Daten seit \d+ s$/);
    });

    it("sagt 30 s mit dem Standardwert", () => {
        expect(STALL_MS).toBe(30000);
    });

    it("bricht auch ab, wenn schon die Antwort ausbleibt und fetch das Signal ignoriert", async () => {
        const never = () => new Promise(() => {});
        await expect(download(asset, { fetchImpl: never, stallMs: 30 })).rejects.toThrow(/Download hängt/);
    });

    it("jedes Byte setzt die Uhr zurück: langsam ist nicht hängend", async () => {
        const ctl = controlledResponse(30);
        const p = download({ ...asset, size: 30 }, { fetchImpl: async () => ctl.res, stallMs: 80 });
        await tick();
        for (let i = 0; i < 3; i += 1) {
            await new Promise((r) => setTimeout(r, 40));
            ctl.push(Buffer.alloc(10));
        }
        ctl.end();
        await expect(p).resolves.toHaveProperty("length", 30);
    });

    it("die Obergrenze für alles bleibt", async () => {
        const ctl = controlledResponse(100);
        const p = download(asset, { fetchImpl: async () => ctl.res, stallMs: 5000, timeoutMs: 40 });
        await tick();
        const steady = setInterval(() => { try { ctl.push(Buffer.alloc(1)); } catch { /* closed */ } }, 10);
        await expect(p).rejects.toThrow(/dauert zu lange/);
        clearInterval(steady);
    });
});

describe("Installer: Phasen und Fehlerzustand", () => {
    let tmp;
    beforeEach(() => { tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ehs-progress-")); });
    afterEach(() => { fs.rmSync(tmp, { recursive: true, force: true }); });

    const exeData = Buffer.alloc(2000, 1);
    const releaseJson = () => ({
        tag_name: "v1.16.6",
        html_url: "https://example.test/release",
        assets: [{ name: "EventHelperSync.exe", size: exeData.length, digest: `sha256:${sha(exeData)}`, browser_download_url: "https://example.test/exe" }],
    });

    function make(exeHandler, over = {}) {
        const exe = path.join(tmp, "EventHelperSync.exe");
        fs.writeFileSync(exe, "alt");
        const fetchImpl = jest.fn(async (url) => {
            if (url === LATEST_URL) return new Response(JSON.stringify(releaseJson()), { status: 200 });
            return exeHandler();
        });
        const log = jest.fn();
        const onRestart = jest.fn();
        const u = createUpdater({
            getConfig: () => ({}), log, toolVersion: "1.16.5", canSelfUpdate: true, exePath: exe, onRestart,
            fetchImpl, addonDirs: () => [], ...over,
        });
        return { u, exe, onRestart, log };
    }

    it("zeigt im Snapshot: Laden (mit Bytes), Prüfen, Neustart", async () => {
        jest.useFakeTimers({ doNotFake: ["setImmediate", "nextTick"] });
        try {
            const ctl = controlledResponse(exeData.length);
            const { u, exe, onRestart } = make(() => ctl.res);
            const p = u.install();
            for (let i = 0; i < 5; i += 1) await tick();
            expect(u.snapshot().installing).toBe(true);
            ctl.push(exeData.subarray(0, 500));
            for (let i = 0; i < 3; i += 1) await tick();
            expect(u.snapshot().progress).toEqual({ phase: "exe", step: "download", received: 500, total: 2000 });
            ctl.push(exeData.subarray(500));
            ctl.end();
            const r = await p;
            expect(r.restarting).toBe(true);
            expect(u.snapshot()).toMatchObject({
                installing: false, installError: null, progress: { phase: "restart" },
            });
            expect(fs.readFileSync(exe).equals(exeData)).toBe(true);
            jest.runOnlyPendingTimers();
            expect(onRestart).toHaveBeenCalledTimes(1);
        } finally {
            jest.useRealTimers();
        }
    });

    it("meldet 'Prüfen' zwischen Laden und Einsetzen", async () => {
        const phases = [];
        const { u } = make(async () => new Response(exeData, { status: 200, headers: { "content-length": "2000" } }), { onRestart: undefined });
        const snap = u.state;
        const orig = Object.getOwnPropertyDescriptor(snap, "progress");
        let value = snap.progress;
        Object.defineProperty(snap, "progress", {
            get: () => value,
            set: (v) => { value = v; if (v) phases.push(`${v.phase}:${v.step}`); },
            configurable: true, enumerable: orig.enumerable,
        });
        await u.install();
        expect(phases).toEqual(expect.arrayContaining(["exe:download", "exe:verify", "exe:install", "restart:install"]));
        expect(phases.indexOf("exe:verify")).toBeGreaterThan(phases.indexOf("exe:download"));
        expect(phases.indexOf("exe:install")).toBeGreaterThan(phases.indexOf("exe:verify"));
    });

    it("hängender Download: Fehler im Zustand, alte .exe bleibt, Erneut versuchen klappt", async () => {
        const stuck = controlledResponse(exeData.length);
        let attempt = 0;
        const { u, exe } = make(() => {
            attempt += 1;
            if (attempt === 1) return stuck.res;
            return new Response(exeData, { status: 200, headers: { "content-length": "2000" } });
        });
        jest.useFakeTimers({ doNotFake: ["setImmediate", "nextTick"] });
        try {
            const p = u.install();
            p.catch(() => {});
            for (let i = 0; i < 5; i += 1) await tick();
            stuck.push(Buffer.alloc(100));
            for (let i = 0; i < 3; i += 1) await tick();
            expect(u.snapshot().progress.received).toBe(100);
            jest.advanceTimersByTime(30 * 1000 + 10);
            await expect(p).rejects.toThrow("Download hängt – keine Daten seit 30 s");
        } finally {
            jest.useRealTimers();
        }
        expect(u.snapshot()).toMatchObject({
            installing: false, progress: null, installError: { message: "Download hängt – keine Daten seit 30 s" },
        });
        expect(fs.readFileSync(exe, "utf8")).toBe("alt");

        // Retry: the error is cleared as soon as the install starts again.
        const second = u.install();
        expect(u.state.installError).toBe(null);
        const r = await second;
        expect(r.restarting).toBe(true);
        expect(u.state.installError).toBe(null);
        expect(fs.readFileSync(exe).equals(exeData)).toBe(true);
    });

    it("jeder andere Fehler steht ebenfalls im Zustand (nie ewig 'Wird installiert')", async () => {
        const { u } = make(async () => new Response("nein", { status: 502 }));
        await expect(u.install()).rejects.toThrow(/HTTP 502/);
        expect(u.state).toMatchObject({ installing: false, progress: null, installError: { message: expect.stringMatching(/HTTP 502/) } });
    });

    it("failRestart: der Neustart ging schief, die alte Instanz meldet es", async () => {
        const { u } = make(async () => new Response(exeData, { status: 200 }), { onRestart: undefined });
        await u.install();
        u.failRestart("Neustart hat nicht geklappt");
        expect(u.state).toMatchObject({
            progress: null, installError: { message: "Neustart hat nicht geklappt" }, lastInstall: { restarting: false },
        });
    });
});

describe("relaunch: wartet auf den Start", () => {
    const exe = "C:/x/EventHelperSync.exe";

    it("ok, sobald der Prozess gestartet ist", async () => {
        const handlers = {};
        const child = { on: (ev, fn) => { handlers[ev] = fn; }, unref: jest.fn() };
        const p = relaunch(exe, { spawnImpl: () => child });
        handlers.spawn();
        await expect(p).resolves.toEqual({ ok: true });
        expect(child.unref).toHaveBeenCalled();
    });

    it("nicht ok bei einem Spawn-Fehler (Datei fehlt, blockiert)", async () => {
        const handlers = {};
        const child = { on: (ev, fn) => { handlers[ev] = fn; }, unref() {} };
        const p = relaunch(exe, { spawnImpl: () => child });
        handlers.error(new Error("spawn EACCES"));
        await expect(p).resolves.toEqual({ ok: false, error: "spawn EACCES" });
        await expect(relaunch(exe, { spawnImpl: () => { throw new Error("kaputt"); } })).resolves.toEqual({ ok: false, error: "kaputt" });
    });
});
