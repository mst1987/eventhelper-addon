"use strict";

/**
 * Höchstens eine laufende Oberfläche pro Rechner.
 *
 * Die .exe hat keine Konsole mehr (scripts/exeResources.js): ist das Fenster
 * zu, läuft der Upload unsichtbar im Hintergrund weiter — gewollt, nur gäbe es
 * dann keinen Weg zurück an die Oberfläche, und ein zweiter Doppelklick würde
 * eine zweite Instanz starten, die dieselbe Datei parallel hochlädt. Deshalb
 * merkt sich die laufende Instanz ihre Adresse, und ein zweiter Start öffnet
 * nur deren Fenster wieder und beendet sich.
 *
 * Die Adresse enthält den Sitzungsschlüssel der Oberfläche (webui.js). Sie
 * liegt deshalb neben der Konfiguration im Home-Verzeichnis, die mit dem
 * Upload-Token ohnehin Wertvolleres enthält.
 */
const fs = require("fs");
const config = require("./config");

const RUN_FILE = config.CONFIG_FILE.replace(/\.json$/i, "") + ".running.json";

/** Ob ein Prozess mit dieser PID noch existiert. */
function alive(pid) {
    try {
        process.kill(pid, 0);
        return true;
    } catch (e) {
        // EPERM: es gibt ihn, er gehört nur jemand anderem.
        return e.code === "EPERM";
    }
}

/**
 * Die Adresse einer laufenden Instanz, oder null. Geprüft wird nicht nur die
 * PID (Windows vergibt sie neu), sondern ob die Oberfläche unter der Adresse
 * mit dem gespeicherten Schlüssel wirklich antwortet.
 */
async function findRunning({ timeoutMs = 1500 } = {}) {
    let entry;
    try {
        entry = JSON.parse(fs.readFileSync(RUN_FILE, "utf8"));
    } catch {
        return null;
    }
    if (!entry || !entry.url || !Number.isInteger(entry.pid)) return null;
    if (entry.pid === process.pid || !alive(entry.pid)) return null;
    try {
        const probe = new URL(entry.url);
        probe.pathname = "/api/state";
        const res = await fetch(probe, { signal: AbortSignal.timeout(timeoutMs) });
        return res.ok ? entry.url : null;
    } catch {
        return null;
    }
}

/** Die eigene Adresse hinterlegen; beim Beenden wieder aufräumen. */
function register(url) {
    try {
        fs.writeFileSync(RUN_FILE, JSON.stringify({ pid: process.pid, url }), { mode: 0o600 });
    } catch {
        // Ohne die Datei klappt nur das Wiederfinden nicht — kein Grund abzubrechen.
        return;
    }
    process.on("exit", unregister);
}

/** Die Datei entfernen, aber nur, wenn sie noch zu diesem Prozess gehört. */
function unregister() {
    try {
        const entry = JSON.parse(fs.readFileSync(RUN_FILE, "utf8"));
        if (entry && entry.pid === process.pid) fs.rmSync(RUN_FILE, { force: true });
    } catch {
        // Schon weg oder unlesbar — nichts zu tun.
    }
}

module.exports = { findRunning, register, unregister, RUN_FILE };
