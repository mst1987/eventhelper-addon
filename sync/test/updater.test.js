"use strict";

// Updates von GitHub: Release lesen, Dateien prüfen, das Addon-Zip entpacken
// und die .exe austauschen. Netz gibt es hier keines — fetch wird jedem
// Aufruf als fetchImpl hineingereicht; Dateien landen in einem eigenen
// Temp-Ordner.

const fs = require("fs");
const os = require("os");
const path = require("path");
const zlib = require("zlib");
const crypto = require("crypto");
const {
    createUpdater, fetchLatestRelease, parseRelease, download, readZip, addonFiles, tocFiles, installAddonFiles,
    replaceExe, cleanupOldExe, oldExePath, relaunch, UpdateError, LATEST_URL, RELEASES_PAGE, FIRST_CHECK_MS,
} = require("../lib/updater");

// --- Hilfen ------------------------------------------------------------------

function crc32(buf) {
    let crc = 0xffffffff;
    for (const b of buf) {
        let c = (crc ^ b) & 0xff;
        for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
        crc = (crc >>> 8) ^ c;
    }
    return (crc ^ 0xffffffff) >>> 0;
}

/** Ein Zip wie Compress-Archive es schreibt: lokale Köpfe, Verzeichnis, Ende. */
function makeZip(files, { method = 8 } = {}) {
    const locals = [];
    const centrals = [];
    let offset = 0;
    const names = Object.keys(files);
    for (const name of names) {
        const data = Buffer.from(files[name]);
        const comp = method === 8 ? zlib.deflateRawSync(data) : data;
        const nameBuf = Buffer.from(name);
        const lh = Buffer.alloc(30);
        lh.writeUInt32LE(0x04034b50, 0);
        lh.writeUInt16LE(20, 4);
        lh.writeUInt16LE(method, 8);
        lh.writeUInt32LE(crc32(data), 14);
        lh.writeUInt32LE(comp.length, 18);
        lh.writeUInt32LE(data.length, 22);
        lh.writeUInt16LE(nameBuf.length, 26);
        const ch = Buffer.alloc(46);
        ch.writeUInt32LE(0x02014b50, 0);
        ch.writeUInt16LE(20, 4);
        ch.writeUInt16LE(20, 6);
        ch.writeUInt16LE(method, 10);
        ch.writeUInt32LE(crc32(data), 16);
        ch.writeUInt32LE(comp.length, 20);
        ch.writeUInt32LE(data.length, 24);
        ch.writeUInt16LE(nameBuf.length, 28);
        ch.writeUInt32LE(offset, 42);
        locals.push(lh, nameBuf, comp);
        centrals.push(ch, nameBuf);
        offset += 30 + nameBuf.length + comp.length;
    }
    const cd = Buffer.concat(centrals);
    const end = Buffer.alloc(22);
    end.writeUInt32LE(0x06054b50, 0);
    end.writeUInt16LE(names.length, 8);
    end.writeUInt16LE(names.length, 10);
    end.writeUInt32LE(cd.length, 12);
    end.writeUInt32LE(offset, 16);
    return Buffer.concat([...locals, cd, end]);
}

const sha = (buf) => crypto.createHash("sha256").update(buf).digest("hex");

const TOC_OLD = "## Interface: 20504\n## Version: 1.13.0\nCore.lua\nCouncilData.lua\n";
const TOC_SAME_FILES = "## Interface: 20504\n## Version: 1.15.0\nCore.lua\nCouncilData.lua\n";
const TOC_NEW_FILES = "## Interface: 20504\n## Version: 1.15.0\nCore.lua\nCouncilData.lua\nUpdate.lua\n";

function addonZip(toc = TOC_SAME_FILES) {
    return makeZip({
        "EventHelperSync/EventHelperSync.toc": toc,
        "EventHelperSync/Core.lua": "-- neu",
        "EventHelperSync/CouncilData.lua": "-- Platzhalter",
        "EventHelperSync/GuildBankData.lua": "-- Platzhalter",
        "EventHelperSync/media/icon.tga": "bild",
    });
}

function release(over = {}, files = {}) {
    const zip = files.zip || addonZip();
    const exe = files.exe || Buffer.from("neue exe");
    return {
        tag_name: "v1.15.0",
        html_url: "https://github.com/mst1987/eventhelper-addon/releases/tag/v1.15.0",
        published_at: "2026-10-11T10:00:00Z",
        assets: [
            {
                name: "EventHelperSync-1.15.0.zip", size: zip.length, digest: `sha256:${sha(zip)}`,
                browser_download_url: "https://example.test/zip",
            },
            {
                name: "EventHelperSync.exe", size: exe.length, digest: `sha256:${sha(exe)}`,
                browser_download_url: "https://example.test/exe",
            },
        ],
        ...over,
    };
}

function response(status, { json, body } = {}) {
    return {
        ok: status >= 200 && status < 300,
        status,
        json: async () => json,
        arrayBuffer: async () => {
            const b = Buffer.from(body || "");
            return b.buffer.slice(b.byteOffset, b.byteOffset + b.length);
        },
    };
}

/** fetch, das die API-Abfrage und beide Downloads bedient. */
function fakeFetch({ rel = release(), zip = addonZip(), exe = Buffer.from("neue exe") } = {}) {
    return jest.fn(async (url) => {
        if (url === LATEST_URL) return response(200, { json: rel });
        if (url === "https://example.test/zip") return response(200, { body: zip });
        if (url === "https://example.test/exe") return response(200, { body: exe });
        return response(404);
    });
}

let tmp;
beforeEach(() => {
    tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ehs-updater-"));
});
afterEach(() => {
    fs.rmSync(tmp, { recursive: true, force: true });
    jest.useRealTimers();
});

/** Ein installierter Addon-Ordner mit älterer Version und Council-Daten. */
function installedAddon(name = "_anniversary_") {
    const dir = path.join(tmp, name, "Interface", "AddOns", "EventHelperSync");
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, "EventHelperSync.toc"), TOC_OLD);
    fs.writeFileSync(path.join(dir, "Core.lua"), "-- alt");
    fs.writeFileSync(path.join(dir, "CouncilData.lua"), "-- echte Council-Daten");
    return dir;
}

// --- Release ---------------------------------------------------------------

describe("parseRelease", () => {
    it("liest Version, Seite und beide Dateien samt Prüfsumme", () => {
        const r = parseRelease(release());
        expect(r.version).toBe("1.15.0");
        expect(r.url).toMatch(/releases\/tag\/v1\.15\.0$/);
        expect(r.zip).toMatchObject({ name: "EventHelperSync-1.15.0.zip", url: "https://example.test/zip" });
        expect(r.zip.sha256).toMatch(/^[0-9a-f]{64}$/);
        expect(r.exe).toMatchObject({ name: "EventHelperSync.exe", url: "https://example.test/exe" });
    });

    it("fehlende Dateien und Prüfsummen bleiben leer statt zu werfen", () => {
        const r = parseRelease({ tag_name: "1.2.0", assets: [{ name: "EventHelperSync.exe", browser_download_url: "u" }] });
        expect(r.version).toBe("1.2.0");
        expect(r.url).toBe(RELEASES_PAGE);
        expect(r.zip).toBeNull();
        expect(r.exe.sha256).toBe("");
    });

    it("ohne tag_name ist es kein Release", () => {
        expect(() => parseRelease({ message: "Not Found" })).toThrow(UpdateError);
    });
});

describe("fetchLatestRelease", () => {
    it("fragt releases/latest mit User-Agent", async () => {
        const fetchImpl = fakeFetch();
        const r = await fetchLatestRelease({ fetchImpl });
        expect(r.version).toBe("1.15.0");
        const [url, init] = fetchImpl.mock.calls[0];
        expect(url).toBe(LATEST_URL);
        expect(init.headers["User-Agent"]).toMatch(/^EventHelperSync\//);
    });

    it("Drosselung und Netzfehler werden lesbare Fehler", async () => {
        await expect(fetchLatestRelease({ fetchImpl: async () => response(403) })).rejects.toThrow(/zu viele Abfragen/);
        await expect(fetchLatestRelease({ fetchImpl: async () => response(500) })).rejects.toThrow(/HTTP 500/);
        await expect(fetchLatestRelease({ fetchImpl: async () => { throw new Error("offline"); } }))
            .rejects.toThrow(/GitHub nicht erreichbar: offline/);
    });
});

describe("download", () => {
    const body = Buffer.from("inhalt");
    const asset = { name: "a.zip", url: "https://example.test/a", size: body.length, sha256: sha(body) };

    it("liefert die Datei, wenn Grösse und SHA-256 stimmen", async () => {
        const buf = await download(asset, { fetchImpl: async () => response(200, { body }) });
        expect(buf.toString()).toBe("inhalt");
    });

    it("falsche Prüfsumme oder Grösse: nichts zurück", async () => {
        await expect(download({ ...asset, sha256: "0".repeat(64) }, { fetchImpl: async () => response(200, { body }) }))
            .rejects.toThrow(/Prüfsumme/);
        await expect(download({ ...asset, size: 99 }, { fetchImpl: async () => response(200, { body }) }))
            .rejects.toThrow(/unvollständig/);
        await expect(download(null)).rejects.toThrow(/fehlt im Release/);
        await expect(download(asset, { fetchImpl: async () => response(404) })).rejects.toThrow(/HTTP 404/);
    });
});

// --- Zip -------------------------------------------------------------------

describe("readZip", () => {
    it("liest deflate und stored, Ordner-Einträge fallen weg", () => {
        const deflated = readZip(makeZip({ "A/": "", "A/x.lua": "hallo welt" }));
        expect(deflated).toEqual([{ name: "A/x.lua", data: Buffer.from("hallo welt") }]);
        const stored = readZip(makeZip({ "A/y.lua": "roh" }, { method: 0 }));
        expect(stored[0].data.toString()).toBe("roh");
    });

    it("Backslashes im Namen (älteres Compress-Archive) werden zu /", () => {
        expect(readZip(makeZip({ "A\\x.lua": "1" }))[0].name).toBe("A/x.lua");
    });

    it("kein Zip oder unbekanntes Packverfahren", () => {
        expect(() => readZip(Buffer.from("kein zip, nur Text, lang genug für die Suche"))).toThrow(/Kein gültiges Zip/);
        const zip = makeZip({ "A/x.lua": "1" }, { method: 0 });
        // Packverfahren im zentralen Verzeichnis auf 14 (LZMA) setzen.
        zip.writeUInt16LE(14, zip.indexOf(Buffer.from([0x50, 0x4b, 0x01, 0x02])) + 10);
        expect(() => readZip(zip)).toThrow(/Packverfahren 14/);
    });
});

describe("addonFiles", () => {
    it("nur der Addon-Ordner, ohne Wege nach draussen", () => {
        const files = addonFiles([
            { name: "EventHelperSync/EventHelperSync.toc", data: Buffer.from("t") },
            { name: "EventHelperSync/Core.lua", data: Buffer.from("c") },
            { name: "EventHelperSync/../evil.lua", data: Buffer.from("x") },
            { name: "EventHelperSync/C:/evil.lua", data: Buffer.from("x") },
            { name: "Anderes/Core.lua", data: Buffer.from("x") },
        ]);
        expect(files.map((f) => f.rel)).toEqual(["EventHelperSync.toc", "Core.lua"]);
    });

    it("ohne .toc ist es kein Addon-Paket", () => {
        expect(() => addonFiles([{ name: "EventHelperSync/Core.lua", data: Buffer.from("c") }])).toThrow(/toc/);
    });
});

describe("tocFiles", () => {
    it("nur Dateizeilen, ohne Metadaten und Gross/Klein", () => {
        expect(tocFiles("## Version: 1\n# Kommentar\r\nCore.lua\n\n  UI.LUA \n")).toEqual(["core.lua", "ui.lua"]);
    });
});

describe("installAddonFiles", () => {
    it("überschreibt das Addon, lässt die Council-Daten stehen, legt fehlende Platzhalter an", () => {
        const dir = installedAddon();
        const files = addonFiles(readZip(addonZip()));
        const r = installAddonFiles(files, dir);

        expect(fs.readFileSync(path.join(dir, "Core.lua"), "utf8")).toBe("-- neu");
        expect(fs.readFileSync(path.join(dir, "EventHelperSync.toc"), "utf8")).toBe(TOC_SAME_FILES);
        expect(fs.readFileSync(path.join(dir, "CouncilData.lua"), "utf8")).toBe("-- echte Council-Daten");
        expect(fs.readFileSync(path.join(dir, "GuildBankData.lua"), "utf8")).toBe("-- Platzhalter");
        expect(fs.readFileSync(path.join(dir, "media", "icon.tga"), "utf8")).toBe("bild");
        expect(r).toEqual({ files: 4, restartNeeded: false });
    });

    it("neue Dateien in der .toc: WoW muss neu starten", () => {
        const dir = installedAddon();
        const r = installAddonFiles(addonFiles(readZip(addonZip(TOC_NEW_FILES))), dir);
        expect(r.restartNeeded).toBe(true);
    });
});

// --- Die .exe ----------------------------------------------------------------

describe("replaceExe / cleanupOldExe", () => {
    it("neue .exe an den Platz, alte daneben; aufräumen entfernt sie", () => {
        const exe = path.join(tmp, "EventHelperSync.exe");
        fs.writeFileSync(exe, "alt");
        replaceExe(Buffer.from("neu"), exe);
        expect(fs.readFileSync(exe, "utf8")).toBe("neu");
        expect(fs.readFileSync(oldExePath(exe), "utf8")).toBe("alt");
        expect(fs.existsSync(`${exe}.new`)).toBe(false);

        cleanupOldExe(exe);
        expect(fs.existsSync(oldExePath(exe))).toBe(false);
        expect(fs.readFileSync(exe, "utf8")).toBe("neu");
    });

    it("nicht beschreibbarer Ordner: Fehler, nichts verändert", () => {
        const exe = path.join(tmp, "fehlt", "EventHelperSync.exe");
        expect(() => replaceExe(Buffer.from("neu"), exe)).toThrow(/nicht schreiben/);
    });

    it("oldExePath", () => {
        expect(oldExePath("C:\\x\\EventHelperSync.exe")).toBe("C:\\x\\EventHelperSync.old.exe");
    });
});

describe("relaunch", () => {
    it("startet losgelöst und hängt nicht am alten Prozess", () => {
        const child = { on: jest.fn(), unref: jest.fn() };
        const spawnImpl = jest.fn(() => child);
        relaunch("C:/x/EventHelperSync.exe", { spawnImpl });
        expect(spawnImpl).toHaveBeenCalledWith("C:/x/EventHelperSync.exe", [], { detached: true, stdio: "ignore" });
        expect(child.unref).toHaveBeenCalled();
        expect(child.on).toHaveBeenCalledWith("error", expect.any(Function));
    });
});

// --- Der laufende Betrieb ------------------------------------------------------

function updater(over = {}) {
    const dirs = over.dirs || [];
    const log = jest.fn();
    const u = createUpdater({
        getConfig: () => ({}),
        log,
        toolVersion: "1.14.0",
        fetchImpl: fakeFetch(),
        addonDirs: () => dirs.map((dir) => ({ flavor: "_anniversary_", label: "TBC Anniversary", dir, version: fs.existsSync(dir) ? "1.13.0" : "" })),
        ...over,
    });
    return { u, log };
}

describe("createUpdater", () => {
    it("check: findet veraltetes Sync-Tool und Addon, meldet es einmal", async () => {
        const dir = installedAddon();
        const { u, log } = updater({ dirs: [dir] });
        await u.check();
        await u.check();
        expect(u.state).toMatchObject({
            available: true, toolOutdated: true, latest: { version: "1.15.0" },
            addons: [{ label: "TBC Anniversary", dir, version: "1.13.0" }], lastError: null,
        });
        expect(u.state.checkedAt).toBeGreaterThan(0);
        expect(log).toHaveBeenCalledTimes(1);
        expect(log.mock.calls[0][1]).toMatch(/Update verfügbar: 1\.15\.0 .*Sync-Tool 1\.14\.0, Addon TBC Anniversary 1\.13\.0/);
    });

    it("check: alles aktuell", async () => {
        const { u, log } = updater({ toolVersion: "1.15.0" });
        await u.check();
        expect(u.state.available).toBe(false);
        expect(log).not.toHaveBeenCalled();
    });

    it("check: offline wird einmal geloggt und steht im Zustand", async () => {
        const { u, log } = updater({ fetchImpl: async () => { throw new Error("offline"); } });
        await u.check();
        await u.check();
        expect(u.state.lastError.message).toMatch(/offline/);
        expect(log).toHaveBeenCalledTimes(1);
        expect(log.mock.calls[0][0]).toBe("warn");
    });

    it("install ohne gepackte .exe: nur das Addon, kein Neustart", async () => {
        const dir = installedAddon();
        const onRestart = jest.fn();
        const { u } = updater({ dirs: [dir], onRestart });
        const r = await u.install();
        expect(r).toEqual({ restarting: false, addons: [{ label: "TBC Anniversary", dir, files: 4, restartNeeded: false }] });
        expect(fs.readFileSync(path.join(dir, "Core.lua"), "utf8")).toBe("-- neu");
        expect(onRestart).not.toHaveBeenCalled();
        expect(u.state.installing).toBe(false);
        expect(u.state.lastInstall.version).toBe("1.15.0");
    });

    it("install als .exe: tauscht sich aus und startet neu", async () => {
        jest.useFakeTimers({ doNotFake: ["setImmediate", "nextTick"] });
        const exe = path.join(tmp, "EventHelperSync.exe");
        fs.writeFileSync(exe, "alt");
        const onRestart = jest.fn();
        const { u } = updater({ canSelfUpdate: true, exePath: exe, onRestart });
        const r = await u.install();
        expect(r.restarting).toBe(true);
        expect(fs.readFileSync(exe, "utf8")).toBe("neue exe");
        jest.runOnlyPendingTimers();
        expect(onRestart).toHaveBeenCalledTimes(1);
    });

    it("install: kaputter Download fasst nichts an", async () => {
        const dir = installedAddon();
        const { u } = updater({ dirs: [dir], fetchImpl: fakeFetch({ zip: Buffer.from("manipuliert") }) });
        await expect(u.install()).rejects.toThrow(/unvollständig|Prüfsumme/);
        expect(fs.readFileSync(path.join(dir, "Core.lua"), "utf8")).toBe("-- alt");
        expect(u.state.lastError.message).toMatch(/unvollständig|Prüfsumme/);
        expect(u.state.installing).toBe(false);
    });

    it("install, wenn nichts zu tun ist", async () => {
        const { u } = updater({ toolVersion: "1.15.0" });
        await expect(u.install()).resolves.toEqual({ addons: [], restarting: false });
    });

    it("start/stop: erste Prüfung nach kurzer Zeit, räumt die alte .exe weg", async () => {
        jest.useFakeTimers({ doNotFake: ["setImmediate", "nextTick"] });
        const exe = path.join(tmp, "EventHelperSync.exe");
        fs.writeFileSync(exe, "neu");
        fs.writeFileSync(oldExePath(exe), "alt");
        const fetchImpl = fakeFetch();
        const { u } = updater({ canSelfUpdate: true, exePath: exe, fetchImpl });
        u.start();
        expect(fs.existsSync(oldExePath(exe))).toBe(false);
        expect(fetchImpl).not.toHaveBeenCalled();
        jest.advanceTimersByTime(FIRST_CHECK_MS);
        expect(fetchImpl).toHaveBeenCalledTimes(1);
        u.stop();
        jest.advanceTimersByTime(24 * 60 * 60 * 1000);
        expect(fetchImpl).toHaveBeenCalledTimes(1);
    });

    it("snapshot bewertet die Addon-Ordner neu, aber nicht bei jedem Abruf", async () => {
        let version = "1.13.0";
        const listing = jest.fn(() => [{ flavor: "_anniversary_", label: "TBC Anniversary", dir: "D", version }]);
        const { u } = updater({ addonDirs: listing, toolVersion: "1.15.0" });
        await u.check();
        expect(u.state.addons).toHaveLength(1);

        // Von Hand aktualisiert: erst nach einer halben Minute bemerkt.
        version = "1.15.0";
        expect(u.snapshot().available).toBe(true);
        expect(listing).toHaveBeenCalledTimes(1);
        const later = Date.now() + 60 * 1000;
        jest.spyOn(Date, "now").mockReturnValue(later);
        expect(u.snapshot().available).toBe(false);
        expect(u.state.addons).toEqual([]);
        Date.now.mockRestore();
    });
});
