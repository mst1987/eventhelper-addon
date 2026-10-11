"use strict";

// Echte Dateien in einem temporären Ordner für das Auspacken (Hash-Vergleich,
// Versionsordner, Aufräumen); Registry und Prozessstart als Attrappen.
const fs = require("fs");
const os = require("os");
const path = require("path");
const crypto = require("crypto");
const { EventEmitter } = require("events");

const host = require("../lib/webviewHost");

let tmp;
const ORIGINAL_PLATFORM = process.platform;

function setPlatform(value) {
    Object.defineProperty(process, "platform", { value, configurable: true });
}

beforeEach(() => {
    tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ehs-webviewhost-"));
    setPlatform("win32");
});

afterEach(() => {
    fs.rmSync(tmp, { recursive: true, force: true });
    setPlatform(ORIGINAL_PLATFORM);
});

const sha256 = (buf) => crypto.createHash("sha256").update(buf).digest("hex");

/** SEA assets as build-exe.js packs them: one per file plus the manifest. */
function fakeAssets(contents = {}) {
    const files = {};
    const data = {};
    for (const name of host.HOST_FILES) {
        data[name] = Buffer.from(contents[name] || `inhalt von ${name}`);
        files[name] = sha256(data[name]);
    }
    const assets = { [host.MANIFEST_ASSET]: Buffer.from(JSON.stringify({ version: "1.16.0", files })) };
    for (const name of host.HOST_FILES) assets[host.ASSET_PREFIX + name] = data[name];
    const getAsset = jest.fn((key) => {
        if (!assets[key]) throw new Error(`no asset ${key}`);
        return assets[key];
    });
    return { getAsset, assets, files };
}

/** reg.exe-Antworten: Schlüssel -> Wertname -> Ausgabezeile. */
function fakeReg(values) {
    return jest.fn((cmd, args) => {
        const [, key, , name] = args;
        const v = values[key] && values[key][name];
        if (v === undefined) throw new Error("ERROR: The system was unable to find the specified registry key or value.");
        return `\r\n${key}\r\n    ${name}    ${v}\r\n\r\n`;
    });
}

const RUNTIME_OK = {
    [host.RUNTIME_KEYS[0]]: { pv: "REG_SZ    154.0.3456.12" },
    [host.NET_FRAMEWORK_KEY]: { Release: "REG_DWORD    0x82348" },
};

describe("extractHost", () => {
    it("packt alle Dateien in den Versionsordner aus und liefert den Pfad des Fensterprogramms", () => {
        const { getAsset } = fakeAssets();
        const exe = host.extractHost({ getAsset, version: "1.16.0", root: tmp });
        expect(exe).toBe(path.join(tmp, "1.16.0", host.HOST_EXE));
        for (const name of host.HOST_FILES) {
            expect(fs.readFileSync(path.join(tmp, "1.16.0", name), "utf8")).toBe(`inhalt von ${name}`);
        }
    });

    it("lässt Dateien mit passendem Hash stehen (zweiter Start liest nur das Manifest)", () => {
        const { getAsset } = fakeAssets();
        host.extractHost({ getAsset, version: "1.16.0", root: tmp });
        getAsset.mockClear();
        expect(host.extractHost({ getAsset, version: "1.16.0", root: tmp })).toBeTruthy();
        expect(getAsset.mock.calls.map((c) => c[0])).toEqual([host.MANIFEST_ASSET]);
    });

    it("ersetzt eine veränderte Datei", () => {
        const { getAsset } = fakeAssets();
        host.extractHost({ getAsset, version: "1.16.0", root: tmp });
        const dll = path.join(tmp, "1.16.0", "WebView2Loader.dll");
        fs.writeFileSync(dll, "kaputt");
        getAsset.mockClear();
        host.extractHost({ getAsset, version: "1.16.0", root: tmp });
        expect(fs.readFileSync(dll, "utf8")).toBe("inhalt von WebView2Loader.dll");
        expect(getAsset).toHaveBeenCalledWith(host.ASSET_PREFIX + "WebView2Loader.dll");
        expect(getAsset).not.toHaveBeenCalledWith(host.ASSET_PREFIX + host.HOST_EXE);
    });

    it("räumt die Ordner anderer Versionen weg", () => {
        fs.mkdirSync(path.join(tmp, "1.15.9"), { recursive: true });
        fs.writeFileSync(path.join(tmp, "1.15.9", host.HOST_EXE), "alt");
        const { getAsset } = fakeAssets();
        host.extractHost({ getAsset, version: "1.16.0", root: tmp });
        expect(fs.readdirSync(tmp)).toEqual(["1.16.0"]);
    });

    it("liefert null, wenn ein Asset nicht zum Manifest passt", () => {
        const { getAsset, assets } = fakeAssets();
        assets[host.ASSET_PREFIX + host.HOST_EXE] = Buffer.from("untergeschoben");
        expect(host.extractHost({ getAsset, version: "1.16.0", root: tmp })).toBeNull();
        expect(fs.existsSync(path.join(tmp, "1.16.0", host.HOST_EXE))).toBe(false);
    });

    it("liefert null ohne Fenster-Assets (.exe ohne Fenster gebaut)", () => {
        const getAsset = () => { throw new Error("no asset"); };
        expect(host.extractHost({ getAsset, version: "1.16.0", root: tmp })).toBeNull();
    });
});

describe("Registry: WebView2 und .NET Framework", () => {
    it("liest die Version der WebView2-Laufzeit", () => {
        expect(host.webView2Version({ execImpl: fakeReg(RUNTIME_OK) })).toBe("154.0.3456.12");
    });

    it("findet eine Installation nur für den Benutzer (HKCU)", () => {
        const execImpl = fakeReg({ [host.RUNTIME_KEYS[2]]: { pv: "REG_SZ    150.0.1.2" } });
        expect(host.webView2Version({ execImpl })).toBe("150.0.1.2");
    });

    it("zählt 0.0.0.0 (Rest einer Deinstallation) nicht als installiert", () => {
        const execImpl = fakeReg({ [host.RUNTIME_KEYS[0]]: { pv: "REG_SZ    0.0.0.0" } });
        expect(host.webView2Version({ execImpl })).toBeNull();
    });

    it("verlangt .NET Framework 4.6.2 oder neuer", () => {
        expect(host.hasNetFramework({ execImpl: fakeReg(RUNTIME_OK) })).toBe(true);
        const old = fakeReg({ [host.NET_FRAMEWORK_KEY]: { Release: "REG_DWORD    0x5c733" } }); // 4.6.1
        expect(host.hasNetFramework({ execImpl: old })).toBe(false);
        expect(host.hasNetFramework({ execImpl: fakeReg({}) })).toBe(false);
    });
});

describe("findHost", () => {
    it("packt das Fenster aus, wenn WebView2 und .NET da sind", () => {
        const { getAsset } = fakeAssets();
        const exe = host.findHost({ getAsset, version: "1.16.0", root: tmp, execImpl: fakeReg(RUNTIME_OK) });
        expect(exe).toBe(path.join(tmp, "1.16.0", host.HOST_EXE));
    });

    it("nimmt ohne WebView2-Laufzeit nichts (Edge --app übernimmt)", () => {
        const { getAsset } = fakeAssets();
        const execImpl = fakeReg({ [host.NET_FRAMEWORK_KEY]: RUNTIME_OK[host.NET_FRAMEWORK_KEY] });
        expect(host.findHost({ getAsset, version: "1.16.0", root: tmp, execImpl })).toBeNull();
        expect(getAsset).not.toHaveBeenCalled();
    });

    it("nimmt mit Node.js gestartet das Fenster aus build/host/", () => {
        for (const name of host.HOST_FILES) fs.writeFileSync(path.join(tmp, name), "x");
        const exe = host.findHost({ getAsset: null, devDir: tmp, execImpl: fakeReg(RUNTIME_OK) });
        expect(exe).toBe(path.join(tmp, host.HOST_EXE));
    });

    it("versucht es auf anderen Plattformen gar nicht erst", () => {
        setPlatform("linux");
        const execImpl = fakeReg(RUNTIME_OK);
        expect(host.findHost({ getAsset: fakeAssets().getAsset, root: tmp, execImpl })).toBeNull();
        expect(execImpl).not.toHaveBeenCalled();
    });
});

describe("spawnHost", () => {
    function fakeChild() {
        const child = new EventEmitter();
        child.unref = jest.fn();
        return child;
    }

    it("startet das Fenster mit Adresse, Eltern-PID und Grösse, losgelöst und sichtbar", () => {
        const child = fakeChild();
        const spawnImpl = jest.fn(() => child);
        const exe = path.join(tmp, host.HOST_EXE);
        expect(host.spawnHost(exe, "http://127.0.0.1:8730/?key=abc", { parentPid: 4711, spawnImpl })).toBe(child);
        const [cmd, args, opts] = spawnImpl.mock.calls[0];
        expect(cmd).toBe(exe);
        expect(args).toEqual(["--url", "http://127.0.0.1:8730/?key=abc", "--parent-pid", "4711", "--width", "560", "--height", "680"]);
        // detached: sonst nähme libuvs Job-Objekt das Fenster beim Ende des
        // (zweiten) Prozesses mit. windowsHide würde das Fenster verstecken.
        expect(opts).toEqual(expect.objectContaining({ detached: true, windowsHide: false, stdio: "ignore", cwd: tmp }));
    });

    it("meldet ein frühes Scheitern von WebView2 (Code 3) als failedEarly", () => {
        const child = fakeChild();
        const onExit = jest.fn();
        host.spawnHost("x.exe", "http://127.0.0.1:1/", { parentPid: 1, onExit, spawnImpl: () => child });
        child.emit("exit", host.EXIT_WEBVIEW_FAILED);
        expect(onExit).toHaveBeenCalledWith(host.EXIT_WEBVIEW_FAILED, true);
    });

    it("meldet ein normales Schliessen nicht als Fehler", () => {
        const child = fakeChild();
        const onExit = jest.fn();
        host.spawnHost("x.exe", "http://127.0.0.1:1/", { parentPid: 1, onExit, spawnImpl: () => child });
        child.emit("exit", 0);
        expect(onExit).toHaveBeenCalledWith(0, false);
    });

    it("ruft onError statt zu werfen, wenn der Start scheitert", () => {
        const onError = jest.fn();
        const result = host.spawnHost("x.exe", "http://127.0.0.1:1/", {
            parentPid: 1, onError, spawnImpl: () => { throw new Error("EACCES"); },
        });
        expect(result).toBeNull();
        expect(onError).toHaveBeenCalledWith(expect.objectContaining({ message: "EACCES" }));

        const child = fakeChild();
        host.spawnHost("x.exe", "http://127.0.0.1:1/", { parentPid: 1, onError, spawnImpl: () => child });
        child.emit("error", new Error("ENOENT"));
        expect(onError).toHaveBeenLastCalledWith(expect.objectContaining({ message: "ENOENT" }));
    });
});
