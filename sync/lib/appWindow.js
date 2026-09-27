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
const { execFile, execFileSync } = require("child_process");

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
function openAppWindow(url, { width = 506, height = 560 } = {}) {
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

module.exports = { openAppWindow, findBrowser, showMessageBox };
