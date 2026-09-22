"use strict";

// Wie wowPaths.test.js: echte Ordner in einem temporären Verzeichnis statt
// eines fs-Mocks — die Suche lebt von fs.existsSync gegen echte Pfade, ein
// Mock würde nur prüfen, was ich beim Schreiben angenommen habe.
const fs = require("fs");
const os = require("os");
const path = require("path");

jest.mock("child_process");
const { execFile } = require("child_process");
const { openAppWindow, findBrowser } = require("../lib/appWindow");

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
        expect(execFile.mock.calls[0][1]).toContain("--window-size=480,660");
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
