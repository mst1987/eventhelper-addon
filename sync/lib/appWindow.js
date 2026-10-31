"use strict";

/**
 * The window for the interface. First choice since 1.16.0: the tool's own
 * frameless window (WebView2, lib/webviewHost.js) without any browser title
 * bar. Without it: Edge or Chrome started with `--app=<url>`, which shows
 * neither address bar nor tabs (but Edge's title bar). See openWindow() below
 * for the whole chain, and webui.js's head comment for why the interface is a
 * local web page at all.
 *
 * Kein installierter Edge/Chrome gefunden, oder der Start schlägt fehl: nie
 * hart scheitern, sondern der Aufrufer fällt auf den normalen Browser-Tab
 * (webui.js's openInBrowser) zurück — die Oberfläche muss auch dann
 * erreichbar bleiben.
 */
const fs = require("fs");
const path = require("path");
const { execFile, execFileSync } = require("child_process");
const webviewHost = require("./webviewHost");

// Reihenfolge = Suchreihenfolge: Edge zuerst, weil es auf jedem Windows 10/11
// vorinstalliert ist; Chrome als Fallback für Rechner ohne Edge.
const CANDIDATES = [
    ["ProgramFiles(x86)", "Microsoft\\Edge\\Application\\msedge.exe"],
    ["ProgramFiles", "Microsoft\\Edge\\Application\\msedge.exe"],
    ["LOCALAPPDATA", "Microsoft\\Edge\\Application\\msedge.exe"],
    ["ProgramFiles(x86)", "Google\\Chrome\\Application\\chrome.exe"],
    ["ProgramFiles", "Google\\Chrome\\Application\\chrome.exe"],
    ["LOCALAPPDATA", "Google\\Chrome\\Application\\chrome.exe"],
];

/** Einen installierten Edge/Chrome finden, oder null. */
function findBrowser() {
    for (const [envVar, rel] of CANDIDATES) {
        const base = process.env[envVar];
        if (!base) continue;
        const full = path.join(base, rel);
        if (fs.existsSync(full)) return full;
    }
    return null;
}

/**
 * Die Oberfläche als chromeloses Fenster öffnen.
 * @returns {boolean} ob ein Browser dafür gestartet wurde — false heisst: der
 *   Aufrufer soll stattdessen den normalen Weg (openInBrowser) versuchen.
 */
// Nur der Startwert: die Seite passt das Fenster danach selbst an ihren
// Inhalt an (fitWindow() in webui-page.js).
function openAppWindow(url, { width = 776, height = 680 } = {}) {
    // Der Sync-Tool wird praktisch nur für Windows gebaut (siehe
    // scripts/build-exe.js) — auf anderen Plattformen bleibt es beim Tab.
    if (process.platform !== "win32") return false;
    const browser = findBrowser();
    if (!browser) return false;
    try {
        const child = execFile(browser, [`--app=${url}`, `--window-size=${width},${height}`], { windowsHide: false });
        // Ohne diesen Listener würde ein Spawn-Fehler (z.B. Datei doch nicht
        // ausführbar) als unbehandeltes "error"-Ereignis den Prozess crashen —
        // hier soll er nur bedeuten "hat nicht geklappt", siehe Kommentar oben.
        child.on("error", () => {});
        return true;
    } catch {
        return false;
    }
}

/**
 * Eine Meldung als Windows-Dialog zeigen und warten, bis er weggeklickt ist.
 *
 * Für die .exe: sie ist ein GUI-Programm ohne Konsole (scripts/exeResources.js)
 * — was dort nur in die Konsole ginge, sähe niemand. Das betrifft genau die
 * Fälle, in denen die Oberfläche nicht aufgeht (Absturz beim Start) oder ein
 * Konsolenbefehl an die .exe übergeben wurde.
 *
 * Node selbst kann keine Dialoge; PowerShell mit WinForms ist auf jedem
 * Windows da. `windowsHide: true` ist hier Pflicht: ohne eigene Konsole
 * würde Windows dem PowerShell-Prozess sonst ein sichtbares Konsolenfenster
 * aufmachen. Der Text reist als Umgebungsvariable, damit weder Anführungszeichen
 * noch Zeilenumbrüche in der Meldung die Befehlszeile zerlegen.
 *
 * @returns {boolean} ob der Dialog gezeigt werden konnte
 */
function showMessageBox(text, { title = "EventHelper Sync", error = false } = {}) {
    if (process.platform !== "win32") return false;
    try {
        execFileSync("powershell.exe", [
            "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-Command",
            "Add-Type -AssemblyName System.Windows.Forms; "
            + "[void][System.Windows.Forms.MessageBox]::Show($env:EHS_MSG_TEXT, $env:EHS_MSG_TITLE, "
            + `'OK', '${error ? "Error" : "Information"}')`,
        ], {
            windowsHide: true,
            env: { ...process.env, EHS_MSG_TEXT: String(text), EHS_MSG_TITLE: String(title) },
        });
        return true;
    } catch {
        return false;
    }
}

/**
 * Open the interface in the best window this machine offers, never failing:
 *
 *   1. the tool's own frameless window (WebView2, lib/webviewHost.js): no
 *      browser title bar, the page's header is the title bar;
 *   2. Edge/Chrome with --app (openAppWindow above);
 *   3. a normal browser tab.
 *
 * Closing the window behaves the same in all three: the sync keeps running in
 * the background, a second start of the .exe opens the window again, and only
 * the page's ✕ (/api/quit) ends the tool.
 *
 * @param {string} url
 * @param {object} [options]
 * @param {number} [options.parentPid]  the sync process the window belongs to
 *   (for a second start: the running instance's, see lib/instance.js)
 * @param {string} [options.version]    host folder name (the tool's version)
 * @param {(level: string, text: string) => void} [options.log]
 * @param {(url: string) => boolean} [options.openTab]  default: webui.js's openInBrowser
 * @param {object} [options.host]  lib/webviewHost.js (tests)
 * @returns {"host"|"app"|"tab"}  what was started (the host may still fall
 *   back later, if WebView2 fails to come up)
 */
function openWindow(url, options = {}) {
    const {
        parentPid = process.pid, version, log = () => {}, host = webviewHost,
    } = options;
    const openTab = options.openTab || ((u) => require("./webui").openInBrowser(u));
    const fallback = () => {
        if (openAppWindow(url)) return "app";
        openTab(url);
        return "tab";
    };

    let exe = null;
    try {
        exe = host.findHost({ version });
    } catch {
        exe = null;
    }
    if (!exe) return fallback();

    const child = host.spawnHost(exe, url, {
        parentPid,
        onError: (e) => {
            log("error", `Fenster ließ sich nicht starten (${e.message}), öffne es im Browser.`);
            fallback();
        },
        onExit: (code, failedEarly) => {
            if (failedEarly) {
                log("error", "WebView2 ließ sich nicht starten, öffne das Fenster im Browser. "
                    + "Details: %LOCALAPPDATA%\\EventHelperSync\\window.log");
                fallback();
            } else if (code !== host.EXIT_HANDED_OVER) {
                // EXIT_HANDED_OVER: the window was already open and came back to the front.
                log("info", "Fenster geschlossen. Der Sync läuft im Hintergrund weiter, "
                    + "ein erneuter Start der .exe öffnet es wieder.");
            }
        },
    });
    return child ? "host" : fallback();
}

module.exports = { openAppWindow, openWindow, findBrowser, showMessageBox };
