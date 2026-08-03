"use strict";

/**
 * Der laufende Betrieb: beobachten, hochladen, und dabei festhalten, was
 * passiert ist.
 *
 * Bis hierher lebte das in index.js und schrieb nur in die Konsole — wer das
 * Fenster nicht offen hatte, wusste nichts. Der Zustand liegt jetzt an einer
 * Stelle, aus der sich sowohl die Konsole als auch die Weboberfläche bedienen,
 * und beantwortet die Frage "was ist der Stand?" ohne dass jemand einen Befehl
 * tippen muss.
 */
const fs = require("fs");
const config = require("./config");
const wowPaths = require("./wowPaths");
const { readEnvelope, uploadFile, postSession, UploadError, SYNC_VERSION } = require("./uploader");

// Wie viele Log-Zeilen aufgehoben werden. Genug für einen Raid-Abend, wenig
// genug, dass der Speicher nicht mitwächst.
const LOG_LIMIT = 300;

function createRunner(options = {}) {
    const state = {
        version: SYNC_VERSION,
        startedAt: Date.now(),
        /** Pfad zur SavedVariables-Datei, oder null wenn (noch) nicht gefunden. */
        file: null,
        fileMtime: 0,
        /** Was in der Datei steht: Sessions mit Instanz, Zeit und Item-Zahl. */
        sessions: [],
        readError: null,
        lastCheck: 0,
        lastUpload: null,
        lastError: null,
        uploading: false,
        log: [],
    };

    let cfg = config.load();
    let timer = null;
    let busy = false;
    // Beim Start einmal hochladen; danach nur, wenn sich die Datei geändert hat.
    let firstRun = true;

    function log(level, text) {
        const entry = { at: Date.now(), level, text };
        state.log.push(entry);
        if (state.log.length > LOG_LIMIT) state.log.shift();
        if (options.onLog) options.onLog(entry);
        return entry;
    }

    /** Die zu beobachtende Datei bestimmen: aus der Konfiguration, sonst suchen. */
    function resolveFile() {
        if (cfg.savedVariablesPath) {
            return fs.existsSync(cfg.savedVariablesPath) ? cfg.savedVariablesPath : null;
        }
        const found = wowPaths.discover(cfg.extraRoots);
        return found.length ? found[0].path : null;
    }

    /** Den Inhalt der Datei in den Zustand übernehmen (ohne hochzuladen). */
    function readState() {
        state.file = resolveFile();
        if (!state.file) {
            state.sessions = [];
            state.readError = null;
            return;
        }
        try {
            state.fileMtime = fs.statSync(state.file).mtimeMs;
        } catch {
            state.fileMtime = 0;
        }
        try {
            const envelope = readEnvelope(state.file);
            state.readError = null;
            state.sessions = !envelope ? [] : (envelope.sessions || []).map((s) => ({
                sessionId: s.sessionId,
                startedAt: (s.startedAt || 0) * 1000,
                endedAt: (s.endedAt || 0) * 1000,
                instance: s.instance || "",
                items: (s.items || []).length,
            }));
            state.envelopeMissing = !envelope;
        } catch (e) {
            state.readError = e.message;
            state.sessions = [];
        }
    }

    /** Einmal hochladen, egal ob sich etwas geändert hat. */
    async function uploadNow() {
        if (!state.file) {
            throw new Error("Keine EventHelperSync.lua gefunden. Ist das Addon installiert und war einmal geladen?");
        }
        state.uploading = true;
        try {
            const { results } = await uploadFile(cfg, state.file);
            state.lastUpload = { at: Date.now(), results };
            state.lastError = null;
            if (!results.length) {
                // "Nichts hochzuladen" allein lässt offen, woran es liegt — und
                // die drei Ursachen brauchen völlig verschiedene Abhilfen.
                log("warn", whyNothing(state));
            } else {
                for (const r of results) log("ok", `${r.sessionId}: ${describe(r)}`);
            }
            return results;
        } catch (e) {
            state.lastError = { at: Date.now(), message: e.message };
            log("error", e instanceof UploadError ? `Upload fehlgeschlagen: ${e.message}` : e.message);
            throw e;
        } finally {
            state.uploading = false;
        }
    }

    /**
     * Prüfen, ob sich die Datei geändert hat, und dann hochladen.
     * Fehler beenden den Lauf nicht: der Server kann gerade neu starten, WoW
     * kann gerade schreiben — beim nächsten Durchlauf wird es erneut versucht.
     */
    async function tick() {
        if (busy) return;
        busy = true;
        try {
            const before = state.file;
            readState();
            state.lastCheck = Date.now();
            if (state.file && state.file !== before) log("info", `Gefunden: ${state.file}`);
            if (!state.file) return;

            const changed = state.fileMtime !== tick.lastSeenMtime;
            if (!changed && !firstRun) return;

            if (changed && !firstRun) {
                log("info", "Datei hat sich geändert — lade hoch.");
                // Kurz warten, damit ein noch laufender Schreibvorgang durch ist.
                await new Promise((r) => setTimeout(r, 1500));
                readState();
            }
            tick.lastSeenMtime = state.fileMtime;
            firstRun = false;
            await uploadNow();
        } catch {
            // Bereits protokolliert; der nächste Durchlauf versucht es erneut.
        } finally {
            busy = false;
        }
    }
    tick.lastSeenMtime = -1;

    /** Token und Erreichbarkeit prüfen, ohne etwas zu importieren. */
    async function testConnection() {
        const probe = {
            format: "eventhelper-loot",
            version: 1,
            generatedAt: Math.floor(Date.now() / 1000),
            realm: "",
            reporter: "",
            client: { addon: "", sync: SYNC_VERSION },
            // Ohne Sessions: der Server prüft das Token und antwortet, ohne dass
            // etwas in der Inbox landet.
            sessions: [],
        };
        await postSession(cfg, probe);
        return true;
    }

    function start() {
        readState();
        log("info", `EventHelper Loot-Sync ${SYNC_VERSION} — Ziel: ${cfg.baseUrl}`);
        if (state.file) log("info", `Beobachte ${state.file}`);
        else log("warn", "Noch keine EventHelperSync.lua gefunden — suche weiter.");
        log("info", "WoW schreibt die Datei beim Ausloggen, bei /reload und über den Upload-Knopf im Spiel.");

        tick();
        timer = setInterval(tick, Math.max(5, Number(cfg.pollSeconds) || 15) * 1000);
    }

    function stop() {
        if (timer) clearInterval(timer);
        timer = null;
    }

    /** Nach dem Speichern neuer Einstellungen: alles neu aufsetzen. */
    function reload() {
        cfg = config.load();
        stop();
        firstRun = true;
        tick.lastSeenMtime = -1;
        readState();
        timer = setInterval(tick, Math.max(5, Number(cfg.pollSeconds) || 15) * 1000);
        log("info", "Einstellungen neu geladen.");
    }

    return {
        state,
        log,
        start,
        stop,
        reload,
        tick,
        uploadNow,
        testConnection,
        readState,
        get config() { return cfg; },
    };
}

/**
 * Warum ein Upload nichts zu tun hatte — mit dem nächsten Schritt dazu.
 * Die Datei sagt selbst, an welcher Stelle die Kette abbricht: gar keine Datei,
 * Datei ohne Export-Block, Export ohne Raid-Abende oder Abende ohne Items.
 */
function whyNothing(state) {
    if (!state.file) {
        return "Keine EventHelperSync.lua gefunden — ist das Addon installiert und war einmal geladen?";
    }
    if (state.readError) {
        return `Die Addon-Datei ist nicht lesbar: ${state.readError}`;
    }
    if (state.envelopeMissing) {
        return "Die Addon-Datei enthält noch keinen Export. Im Spiel den Upload-Knopf drücken "
            + "(oder /ehs upload), damit WoW sie schreibt.";
    }
    if (!state.sessions.length) {
        return "Der Export ist leer — das Addon hat keinen Raid-Abend gefunden. "
            + "Im Spiel „/ehs diag\" zeigt, an welcher Stelle es hakt "
            + "(Loot-Addon nicht geladen, Zeitraum zu kurz, oder alle Abende abgewählt).";
    }
    const items = state.sessions.reduce((sum, s) => sum + (s.items || 0), 0);
    if (!items) {
        return "Die gefundenen Raid-Abende enthalten keine Items — im Spiel „/ehs diag\" prüfen.";
    }
    return "Nichts hochzuladen.";
}

/** Eine Ergebniszeile des Servers als Satz. */
function describe(r) {
    switch (r.status) {
    case "pending":
        return `neu in der Inbox — ${r.added} Item(s)${r.suggested ? `, vorgeschlagen: ${r.suggested}` : ""}`;
    case "updated":
        return `Inbox aktualisiert — ${r.added} neue(s) Item(s), jetzt ${r.total}`;
    case "appended":
        return `${r.added} Item(s) direkt zu „${r.eventLabel}" ergänzt`
            + `${r.skipped ? ` (${r.skipped} bereits vorhanden)` : ""}`;
    case "dismissed":
        return "übersprungen (im Menü verworfen)";
    case "empty":
        return "keine Items";
    default:
        return r.status;
    }
}

module.exports = { createRunner, describe, whyNothing, LOG_LIMIT };
