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
const { readEnvelope, uploadFile, uploadOneSession, postSession, UploadError, SYNC_VERSION } = require("./uploader");

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
            const excluded = new Set(Array.isArray(cfg.excludedSessions) ? cfg.excludedSessions : []);
            const uploadLog = cfg.uploadLog || {};
            state.sessions = !envelope ? [] : (envelope.sessions || []).map((s) => {
                const items = s.items || [];
                // Die Kennzahlen, die vor dem Absenden interessieren — dieselben
                // Fragen wie im Spiel, nur hier eine Stufe später.
                const players = new Set();
                let gargul = 0;
                for (const it of items) {
                    if (it && it.player) players.add(it.player);
                    if (it && it.source === "gargul") gargul += 1;
                }
                return {
                    sessionId: s.sessionId,
                    startedAt: (s.startedAt || 0) * 1000,
                    endedAt: (s.endedAt || 0) * 1000,
                    instance: s.instance || "",
                    items: items.length,
                    players: players.size,
                    gargul,
                    rclc: items.length - gargul,
                    excluded: excluded.has(s.sessionId),
                    lastUpload: uploadLog[s.sessionId] || null,
                };
            });
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
            const { results, skipped } = await uploadFile(cfg, state.file);
            state.lastUpload = { at: Date.now(), results, skipped };
            state.lastError = null;
            rememberResults(results);
            if (skipped) log("info", `${skipped} Raid-Abend(e) hier abgewählt — nicht gesendet.`);
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
            // uploadLog wurde in rememberResults() gespeichert — die Raid-Liste
            // soll das sofort zeigen, nicht erst beim nächsten Tick.
            readState();
        }
    }

    /**
     * Nur eine einzelne Session hochladen — der Klick auf eine Raid-Zeile in
     * der Oberfläche soll auch nur die betreffen, nicht den ganzen Abend.
     */
    async function uploadOne(sessionId) {
        if (!state.file) {
            throw new Error("Keine EventHelperSync.lua gefunden. Ist das Addon installiert und war einmal geladen?");
        }
        state.uploading = true;
        try {
            const { results } = await uploadOneSession(cfg, state.file, sessionId);
            if (results.length) {
                state.lastUpload = { at: Date.now(), results, skipped: 0 };
                state.lastError = null;
                rememberResults(results);
                for (const r of results) log("ok", `${r.sessionId}: ${describe(r)}`);
            }
            return results;
        } catch (e) {
            state.lastError = { at: Date.now(), message: e.message };
            log("error", e instanceof UploadError ? `Upload fehlgeschlagen: ${e.message}` : e.message);
            throw e;
        } finally {
            state.uploading = false;
            // uploadLog wurde in rememberResults() gespeichert — der Stand der
            // Zeile (state.sessions[].lastUpload) muss das jetzt zeigen.
            readState();
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

    /**
     * Festhalten, was der Server zu jedem Abend gesagt hat. Nur zur Anzeige:
     * "zuletzt 12 neu" beantwortet vor dem nächsten Upload die Frage, ob dieser
     * Abend schon durch ist — der Server dedupliziert ohnehin selbst.
     */
    function rememberResults(results) {
        if (!results || !results.length) return;
        const uploadLog = { ...(cfg.uploadLog || {}) };
        for (const r of results) {
            if (!r || !r.sessionId) continue;
            uploadLog[r.sessionId] = {
                at: Date.now(),
                status: r.status,
                added: r.added || 0,
                skipped: r.skipped || 0,
                eventLabel: r.eventLabel || "",
            };
        }
        cfg = config.save({ ...config.load(), uploadLog });
    }

    /** Raid-Abende hier ab- oder wieder anwählen. */
    function setExcluded(sessionIds, excluded) {
        const ids = Array.isArray(sessionIds) ? sessionIds : [sessionIds];
        const current = new Set(Array.isArray(cfg.excludedSessions) ? cfg.excludedSessions : []);
        for (const id of ids) {
            if (!id) continue;
            if (excluded) current.add(String(id)); else current.delete(String(id));
        }
        cfg = config.save({ ...config.load(), excludedSessions: [...current] });
        readState();
        return [...current];
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
        uploadOne,
        testConnection,
        readState,
        setExcluded,
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
        return "Keine EventHelperSync.lua gefunden — ist das Addon installiert und war einmal geladen? "
            + "Falls ja, liegt WoW an einem Ort, den die Suche nicht kennt: in der Oberfläche unter "
            + "„Pfad selbst angeben\" den WoW-Ordner eintragen.";
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
