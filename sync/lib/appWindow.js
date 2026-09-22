"use strict";

/**
 * Ein chromeloses Fenster für die Oberfläche: Edge oder Chrome mit
 * `--app=<url>` gestartet zeigt weder Adressleiste noch Tabs — sieht wie ein
 * eigenständiges Programm aus, ohne dass eine zweite GUI-Laufzeit (Electron,
 * ein natives WebView-Modul) in die .exe müsste. Siehe webui.js's
 * Kopfkommentar für die Abwägung dahinter.
 *
 * Kein installierter Edge/Chrome gefunden, oder der Start schlägt fehl: nie
 * hart scheitern, sondern der Aufrufer fällt auf den normalen Browser-Tab
 * (webui.js's openInBrowser) zurück — die Oberfläche muss auch dann
 * erreichbar bleiben.
 */
const fs = require("fs");
const path = require("path");
const { execFile } = require("child_process");

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
function openAppWindow(url, { width = 480, height = 660 } = {}) {
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

module.exports = { openAppWindow, findBrowser };
