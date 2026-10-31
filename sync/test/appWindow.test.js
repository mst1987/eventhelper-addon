"use strict";

// Wie wowPaths.test.js: echte Ordner in einem temporären Verzeichnis statt
// eines fs-Mocks — die Suche lebt von fs.existsSync gegen echte Pfade, ein
// Mock würde nur prüfen, was ich beim Schreiben angenommen habe.
const fs = require("fs");
const os = require("os");
const path = require("path");

jest.mock("child_process");
const { execFile, execFileSync } = require("child_process");
const { openAppWindow, openWindow, findBrowser, showMessageBox } = require("../lib/appWindow");

let tmp;
const ORIGINAL_ENV = { ...process.env };

function setPlatform(value) {
    Object.defineProperty(process, "platform", { value, configurable: true });
}

beforeEach(() => {
    tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ehs-appwindow-"));
    process.env = { ...ORIGINAL_ENV };
    delete process.env["ProgramFiles(x86)"];
    delete process.env.ProgramFiles;
    delete process.env.LOCALAPPDATA;
    setPlatform("win32");
    jest.clearAllMocks();
    execFile.mockImplementation(() => ({ on: jest.fn() }));
    execFileSync.mockImplementation(() => "");
});

afterEach(() => {
    fs.rmSync(tmp, { recursive: true, force: true });
    process.env = ORIGINAL_ENV;
    setPlatform(process.platform); // no-op, keeps the descriptor configurable
});

function putEdge(base) {
    const dir = path.join(base, "Microsoft", "Edge", "Application");
    fs.mkdirSync(dir, { recursive: true });
    const exe = path.join(dir, "msedge.exe");
    fs.writeFileSync(exe, "");
    return exe;
}

function putChrome(base) {
    const dir = path.join(base, "Google", "Chrome", "Application");
    fs.mkdirSync(dir, { recursive: true });
    const exe = path.join(dir, "chrome.exe");
    fs.writeFileSync(exe, "");
    return exe;
}

describe("findBrowser", () => {
    it("findet Edge unter ProgramFiles(x86)", () => {
        const exe = putEdge(tmp);
        process.env["ProgramFiles(x86)"] = tmp;
        expect(findBrowser()).toBe(exe);
    });

    it("findet Chrome, wenn kein Edge installiert ist", () => {
        const exe = putChrome(tmp);
        process.env["ProgramFiles(x86)"] = tmp;
        expect(findBrowser()).toBe(exe);
    });

    it("bevorzugt Edge vor Chrome, wenn beide da sind", () => {
        const edge = putEdge(tmp);
        putChrome(tmp);
        process.env["ProgramFiles(x86)"] = tmp;
        expect(findBrowser()).toBe(edge);
    });

    it("liefert null, wenn nichts gefunden wird", () => {
        expect(findBrowser()).toBeNull();
    });
});

describe("openAppWindow", () => {
    it("startet den gefundenen Browser mit --app und --window-size", () => {
        const exe = putEdge(tmp);
        process.env["ProgramFiles(x86)"] = tmp;

        const ok = openAppWindow("http://127.0.0.1:8730/?key=abc", { width: 480, height: 660 });

        expect(ok).toBe(true);
        expect(execFile).toHaveBeenCalledWith(
            exe,
            ["--app=http://127.0.0.1:8730/?key=abc", "--window-size=480,660"],
            expect.objectContaining({ windowsHide: false }),
        );
    });

    it("hat sinnvolle Vorgabemasse, wenn keine angegeben werden", () => {
        putEdge(tmp);
        process.env["ProgramFiles(x86)"] = tmp;
        openAppWindow("http://127.0.0.1:8730/?key=abc");
        expect(execFile.mock.calls[0][1]).toContain("--window-size=776,680");
    });

    // Muss auf den normalen Browser-Tab zurückfallen können (webui.js's
    // openInBrowser) — false ist das Signal dafür, kein Fehler.
    it("liefert false, wenn kein Browser gefunden wird", () => {
        const ok = openAppWindow("http://127.0.0.1:8730/?key=abc");
        expect(ok).toBe(false);
        expect(execFile).not.toHaveBeenCalled();
    });

    it("liefert false, statt zu werfen, wenn der Start fehlschlägt", () => {
        putEdge(tmp);
        process.env["ProgramFiles(x86)"] = tmp;
        execFile.mockImplementation(() => { throw new Error("EACCES"); });
        expect(openAppWindow("http://127.0.0.1:8730/?key=abc")).toBe(false);
    });

    it("versucht es auf anderen Plattformen gar nicht erst", () => {
        putEdge(tmp);
        process.env["ProgramFiles(x86)"] = tmp;
        setPlatform("darwin");
        expect(openAppWindow("http://127.0.0.1:8730/?key=abc")).toBe(false);
        expect(execFile).not.toHaveBeenCalled();
    });
});

describe("showMessageBox", () => {
    it("zeigt den Text per PowerShell/WinForms, ohne Konsolenfenster", () => {
        const ok = showMessageBox('Fehler: "kaputt"\nzweite Zeile', { error: true });

        expect(ok).toBe(true);
        expect(execFileSync).toHaveBeenCalledTimes(1);
        const [cmd, args, opts] = execFileSync.mock.calls[0];
        expect(cmd).toBe("powershell.exe");
        expect(args.join(" ")).toMatch(/MessageBox\]::Show/);
        expect(args.join(" ")).toMatch(/'Error'/);
        // Pflicht in der GUI-.exe: sonst öffnet Windows PowerShell eine Konsole.
        expect(opts.windowsHide).toBe(true);
        // Der Text reist unverändert als Umgebungsvariable, nicht in der Befehlszeile.
        expect(opts.env.EHS_MSG_TEXT).toBe('Fehler: "kaputt"\nzweite Zeile');
        expect(opts.env.EHS_MSG_TITLE).toBe("EventHelper Sync");
        expect(args.join(" ")).not.toMatch(/kaputt/);
    });

    it("nimmt ohne error-Flag das Informations-Symbol", () => {
        showMessageBox("Hinweis");
        expect(execFileSync.mock.calls[0][1].join(" ")).toMatch(/'Information'/);
    });

    it("liefert false, statt zu werfen, wenn PowerShell fehlschlägt", () => {
        execFileSync.mockImplementation(() => { throw new Error("nicht gefunden"); });
        expect(showMessageBox("x")).toBe(false);
    });

    it("versucht es auf anderen Plattformen gar nicht erst", () => {
        setPlatform("darwin");
        expect(showMessageBox("x")).toBe(false);
        expect(execFileSync).not.toHaveBeenCalled();
    });
});

// Die Reihenfolge: eigenes Fenster (WebView2) -> Edge/Chrome --app -> Tab.
// Das Fenster-Modul (lib/webviewHost.js) als Attrappe; Edge/Chrome echt im
// temporären Ordner, der Tab als Funktion.
describe("openWindow", () => {
    const URL_ = "http://127.0.0.1:8730/?key=abc";
    const APP_ARG = "--app=" + URL_;

    function fakeHost({ exe = "C:/host/EventHelperSyncWindow.exe", child = { pid: 1 } } = {}) {
        return {
            findHost: jest.fn(() => exe),
            spawnHost: jest.fn(() => child),
            EXIT_HANDED_OVER: 4,
        };
    }

    it("nimmt zuerst das eigene Fenster, mit Eltern-PID und Version", () => {
        putEdge(tmp);
        process.env["ProgramFiles(x86)"] = tmp;
        const host = fakeHost();
        const openTab = jest.fn();

        expect(openWindow(URL_, { host, openTab, parentPid: 4711, version: "1.16.0" })).toBe("host");
        expect(host.findHost).toHaveBeenCalledWith({ version: "1.16.0" });
        expect(host.spawnHost).toHaveBeenCalledWith("C:/host/EventHelperSyncWindow.exe", URL_,
            expect.objectContaining({ parentPid: 4711 }));
        expect(execFile).not.toHaveBeenCalled();
        expect(openTab).not.toHaveBeenCalled();
    });

    it("fällt ohne eigenes Fenster auf Edge --app zurück", () => {
        const exe = putEdge(tmp);
        process.env["ProgramFiles(x86)"] = tmp;
        const host = fakeHost({ exe: null });
        const openTab = jest.fn();

        expect(openWindow(URL_, { host, openTab })).toBe("app");
        expect(execFile).toHaveBeenCalledWith(exe, expect.arrayContaining([APP_ARG]), expect.anything());
        expect(host.spawnHost).not.toHaveBeenCalled();
        expect(openTab).not.toHaveBeenCalled();
    });

    it("fällt ohne Fenster und ohne Edge/Chrome auf den Browser-Tab zurück", () => {
        const openTab = jest.fn();
        expect(openWindow(URL_, { host: fakeHost({ exe: null }), openTab })).toBe("tab");
        expect(openTab).toHaveBeenCalledWith(URL_);
    });

    it("fällt zurück, wenn das Fenster nicht startet oder findHost wirft", () => {
        const openTab = jest.fn();
        expect(openWindow(URL_, { host: fakeHost({ child: null }), openTab })).toBe("tab");
        const throwing = fakeHost();
        throwing.findHost.mockImplementation(() => { throw new Error("kaputt"); });
        expect(openWindow(URL_, { host: throwing, openTab })).toBe("tab");
        expect(openTab).toHaveBeenCalledTimes(2);
    });

    it("öffnet Edge, wenn WebView2 kurz nach dem Start scheitert", () => {
        const exe = putEdge(tmp);
        process.env["ProgramFiles(x86)"] = tmp;
        const host = fakeHost();
        const log = jest.fn();
        openWindow(URL_, { host, openTab: jest.fn(), log });
        expect(execFile).not.toHaveBeenCalled();

        const { onExit } = host.spawnHost.mock.calls[0][2];
        onExit(3, true);
        expect(execFile).toHaveBeenCalledWith(exe, expect.arrayContaining([APP_ARG]), expect.anything());
        expect(log).toHaveBeenCalledWith("error", expect.stringMatching(/WebView2/));
    });

    it("öffnet nach einem Spawn-Fehler den Tab, wenn auch Edge fehlt", () => {
        const host = fakeHost();
        const openTab = jest.fn();
        openWindow(URL_, { host, openTab });
        host.spawnHost.mock.calls[0][2].onError(new Error("ENOENT"));
        expect(openTab).toHaveBeenCalledWith(URL_);
    });

    // Wie bisher mit Edge: Fenster zu heisst nicht Sync beenden.
    it("lässt beim Schliessen des Fensters alles weiterlaufen und öffnet nichts", () => {
        putEdge(tmp);
        process.env["ProgramFiles(x86)"] = tmp;
        const host = fakeHost();
        const openTab = jest.fn();
        const log = jest.fn();
        openWindow(URL_, { host, openTab, log });
        const { onExit } = host.spawnHost.mock.calls[0][2];

        onExit(0, false);
        expect(log).toHaveBeenCalledWith("info", expect.stringMatching(/Hintergrund/));
        // Später gescheitert (kein failedEarly): kein Browserfenster aus dem Nichts.
        onExit(3, false);
        // Fenster war schon offen und wurde nach vorn geholt: nichts zu melden.
        log.mockClear();
        onExit(4, false);
        expect(log).not.toHaveBeenCalled();
        expect(execFile).not.toHaveBeenCalled();
        expect(openTab).not.toHaveBeenCalled();
    });
});
