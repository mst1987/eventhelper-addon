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
const {
    readEnvelope, uploadFile, uploadOneSession, postSession, UploadError, SYNC_VERSION,
    readGuildBank, guildBankKey, postGuildBank,
} = require("./uploader");
const council = require("./council");
const handouts = require("./guildbankHandouts");

// Wie viele Log-Zeilen aufgehoben werden. Genug für einen Raid-Abend, wenig
// genug, dass der Speicher nicht mitwächst.
const LOG_LIMIT = 300;

// Council-Daten (lib/council.js): alle 15 Minuten von selbst, dazu nach jedem
// Upload. Zwei automatische Anlässe kurz hintereinander (Start + erster
// Upload) lösen nur einen Abruf aus; ein Klick in der Oberfläche immer.
const COUNCIL_INTERVAL_MS = 15 * 60 * 1000;
const COUNCIL_MIN_GAP_MS = 60 * 1000;
// After a failed guild bank upload: wait this long before the next try (a
// file change retries at once). Keeps a missing endpoint from filling the log
// every poll.
const GUILD_BANK_RETRY_MS = 5 * 60 * 1000;
// Guild bank handouts (lib/guildbankHandouts.js): they change more often than
// the council data (a request confirmed on the website should show up at the
// bank soon), so every 5 minutes, plus after every upload, after a guild bank
// scan went up and after ticked entries were reported. Automatic occasions
// within a minute fall together, like the council.
const HANDOUTS_INTERVAL_MS = 5 * 60 * 1000;
const HANDOUTS_MIN_GAP_MS = 60 * 1000;
// After a failed report of ticked entries: wait this long before the next
// try (a changed file retries at once).
const HANDOUTS_REPORT_RETRY_MS = 5 * 60 * 1000;

/** "1 Kategorie" / "3 Kategorien". */
function councilCategoriesLabel(count) {
    return count === 1 ? "1 Kategorie" : `${count} Kategorien`;
}

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
        /**
         * The latest guild bank scan in the file, as a summary for the UI:
         * { guild, realm, faction, project, scannedAt (ms), tabs, items, uploaded, lastError },
         * or null if there is none.
         */
        guildBank: null,
        log: [],
        /** Der letzte Abruf der Council-Daten — für die Statuszeile. */
        council: {
            fetching: false,
            lastFetch: 0,
            generatedAt: 0,
            /** Verschiedene Raider über alle Kategorien. */
            raiders: 0,
            /** [{ id, name, raiders }] — die Loot-Council-Kategorien der Webseite. */
            categories: [],
            /** true: ein älterer Server hat nur Version 1 (eine Kategorie) geliefert. */
            fallback: false,
            files: [],
            lastError: null,
        },
        /**
         * Guild bank handouts: the last download (for the status line) and
         * the ticked entries waiting to be reported.
         */
        handouts: {
            fetching: false,
            lastFetch: 0,
            generatedAt: 0,
            banks: 0,
            handouts: 0,
            files: [],
            lastError: null,
            /** Entries ticked in game (in the file) not reported yet. */
            done: 0,
            reporting: false,
            /** { at, reported, ok, duplicate, notConfirmed, unknown } of the last report. */
            lastReport: null,
            reportError: null,
        },
    };

    let cfg = config.load();
    let timer = null;
    let busy = false;
    // Beim Start einmal hochladen; danach nur, wenn sich die Datei geändert hat.
    let firstRun = true;
    let councilTimer = null;
    let councilRun = null;
    // The full scan behind state.guildBank, as it is uploaded.
    let guildBankScan = null;
    let guildBankRetryAt = 0;
    let guildBankError = null;
    let handoutsTimer = null;
    let handoutsRun = null;
    // A forced refresh asked for while one runs: run once more afterwards, the
    // running one may have started before the change (scan, report).
    let handoutsAgain = false;
    let handoutsSignature = "";
    // The entries ticked in game, as read from the file.
    let handoutsDone = [];
    let handoutsReportRun = null;
    let handoutsReportRetryAt = 0;

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
            guildBankScan = null;
            state.guildBank = null;
            handoutsDone = [];
            state.handouts.done = 0;
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
        readGuildBankState();
        readHandoutsDoneState();
    }

    /** The ticked handouts in the file; on their own, like the guild bank scan. */
    function readHandoutsDoneState() {
        try {
            handoutsDone = handouts.readGuildBankDone(state.file) || [];
        } catch {
            handoutsDone = [];
        }
        state.handouts.done = handouts.unreported(handoutsDone, cfg.guildBankDoneReported).length;
    }

    /** The guild bank scan in the file; on its own, so it never breaks the loot part. */
    function readGuildBankState() {
        try {
            guildBankScan = readGuildBank(state.file) || null;
        } catch {
            guildBankScan = null;
        }
        if (!guildBankScan) {
            state.guildBank = null;
            return;
        }
        const scan = guildBankScan;
        const guild = scan.guild || {};
        const uploadedAt = (cfg.guildBankUploads || {})[guildBankKey(scan)] || 0;
        state.guildBank = {
            guild: guild.name || "",
            realm: guild.realm || "",
            faction: guild.faction || "",
            project: (scan.client && scan.client.project) || "",
            scannedAt: Number(scan.scannedAt) * 1000,
            tabs: scan.tabs.length,
            items: scan.tabs.reduce((sum, tab) => sum + tab.items.length, 0),
            uploaded: Number(scan.scannedAt) <= uploadedAt,
            lastError: guildBankError,
        };
    }

    /**
     * Upload the guild bank scan if it is newer than the last one the server
     * accepted for this guild bank. Runs after the loot upload and on its own:
     * a failure here (the endpoint may not exist yet, 404) is logged and
     * retried later, but never stops or delays the loot.
     * @param {{ force?: boolean }} [opts] force: ignore the retry pause
     * @returns {Promise<boolean>} whether a scan was uploaded
     */
    async function syncGuildBank(opts = {}) {
        const scan = guildBankScan;
        if (!scan || !state.guildBank || state.guildBank.uploaded) return false;
        if (!opts.force && Date.now() < guildBankRetryAt) return false;
        const label = `Gildenbank ${state.guildBank.guild || "?"}`;
        try {
            await postGuildBank(cfg, scan);
        } catch (e) {
            guildBankRetryAt = Date.now() + GUILD_BANK_RETRY_MS;
            guildBankError = { at: Date.now(), message: e.message };
            state.guildBank.lastError = guildBankError;
            const why = e instanceof UploadError && e.status === 404
                ? "der Server kennt /api/ingest/guildbank noch nicht (HTTP 404)"
                : e.message;
            log("error", `${label}: Upload fehlgeschlagen — ${why}. Neuer Versuch in 5 min oder bei der nächsten Änderung.`);
            return false;
        }
        guildBankRetryAt = 0;
        guildBankError = null;
        const uploads = { ...(cfg.guildBankUploads || {}), [guildBankKey(scan)]: Number(scan.scannedAt) };
        cfg = config.save({ ...config.load(), guildBankUploads: uploads });
        log("ok", `${label}: hochgeladen — ${state.guildBank.tabs} Tab(s), ${state.guildBank.items} Stapel.`);
        readGuildBankState();
        // The handouts carry the bank count of the last scan: fetch them anew.
        refreshHandouts({ force: true });
        return true;
    }

    /**
     * Fetch the guild bank handouts and write GuildBankData.lua into every
     * installed addon folder (lib/guildbankHandouts.js).
     *
     * Never throws and never rejects, like refreshCouncil(): a failure here
     * must not stop the uploads. It lands in state.handouts.lastError and,
     * once per new message, in the log. A successful fetch is logged only when
     * the list changed - every 5 minutes would drown the log.
     *
     * @param {{ force?: boolean }} [options]  force: also right after the last
     *   fetch, and with a message when nothing is set up (a click in the UI).
     *   A forced call while a fetch runs fetches once more afterwards.
     * @returns {Promise<object|null>} the result of syncHandouts(), else null
     */
    function refreshHandouts({ force = false } = {}) {
        if (handoutsRun) {
            if (force) handoutsAgain = true;
            return handoutsRun;
        }
        const h = state.handouts;
        if (!force && h.lastFetch && Date.now() - h.lastFetch < HANDOUTS_MIN_GAP_MS) return Promise.resolve(null);
        h.fetching = true;
        const run = (async () => {
            try {
                if ((config.missing(cfg) || []).length) {
                    if (force) throw new Error("Noch nicht eingerichtet — Adresse und Token fehlen.");
                    return null;
                }
                const result = await handouts.syncHandouts(cfg);
                const hadError = !!h.lastError;
                Object.assign(h, {
                    lastFetch: Date.now(),
                    generatedAt: Number(result.payload.generatedAt) || 0,
                    banks: result.banks,
                    handouts: result.handouts,
                    files: result.files,
                    lastError: result.errors.length ? { at: Date.now(), message: result.errors.join("; ") } : null,
                });
                const signature = JSON.stringify([result.payload.banks, result.files.length]);
                if (signature !== handoutsSignature || hadError) {
                    handoutsSignature = signature;
                    if (!result.dirs.length) {
                        log("warn", `Ausgabeliste geholt (${result.handouts} Posten), aber kein installierter `
                            + "Addon-Ordner EventHelperSync gefunden — nichts geschrieben.");
                    } else if (result.files.length) {
                        log("ok", `Ausgabeliste: ${result.handouts} Posten aus ${result.banks} Gildenbank(en) in `
                            + `${result.files.length} Addon-Ordner geschrieben — im Spiel nach /reload (/ehs bank).`);
                    }
                }
                for (const err of result.errors) log("error", `Ausgabeliste nicht geschrieben: ${err}`);
                return result;
            } catch (e) {
                const repeated = h.lastError && h.lastError.message === e.message;
                h.lastError = { at: Date.now(), message: e.message };
                if (!repeated || force) log("error", `Ausgabeliste: ${e.message}`);
                return null;
            } finally {
                h.fetching = false;
            }
        })();
        // Released only after the assignment, as in refreshCouncil().
        handoutsRun = run;
        run.then(() => {
            if (handoutsRun === run) handoutsRun = null;
            if (handoutsAgain) {
                handoutsAgain = false;
                refreshHandouts({ force: true });
            }
        });
        return run;
    }

    /** Remember reported ids (with the time) in the config, old ones pruned. */
    function rememberReported(ids) {
        if (!ids || !ids.length) return;
        const reported = handouts.pruneReported(cfg.guildBankDoneReported);
        const now = Date.now();
        for (const id of ids) reported[id] = now;
        cfg = config.save({ ...config.load(), guildBankDoneReported: reported });
    }

    /**
     * Report the handouts ticked in game (EventHelperSyncDB.guildBankDone)
     * that were not reported yet. Runs every tick and does nothing without
     * such entries. A failure is retried after a pause (or at once when the
     * file changes); a success fetches the handouts again, so the next
     * GuildBankData.lua no longer lists them.
     * @param {{ force?: boolean }} [opts] force: ignore the retry pause
     * @returns {Promise<boolean>} whether something was reported
     */
    function reportHandoutsDone(opts = {}) {
        if (handoutsReportRun) return handoutsReportRun;
        const h = state.handouts;
        const pending = handouts.unreported(handoutsDone, cfg.guildBankDoneReported);
        h.done = pending.length;
        if (!pending.length || (config.missing(cfg) || []).length) return Promise.resolve(false);
        if (!opts.force && Date.now() < handoutsReportRetryAt) return Promise.resolve(false);
        h.reporting = true;
        const run = (async () => {
            try {
                const result = await handouts.reportDone(cfg, pending);
                rememberReported(result.reported);
                handoutsReportRetryAt = 0;
                h.reportError = null;
                h.lastReport = {
                    at: Date.now(),
                    reported: result.reported.length,
                    ok: result.ok.length,
                    duplicate: result.duplicate.length,
                    notConfirmed: result.notConfirmed.length,
                    unknown: result.unknown.length,
                };
                const extra = [];
                if (result.duplicate.length) extra.push(`${result.duplicate.length} schon ausgegeben`);
                if (result.notConfirmed.length) extra.push(`${result.notConfirmed.length} nicht mehr vorgemerkt`);
                if (result.unknown.length) extra.push(`${result.unknown.length} unbekannt`);
                log("ok", `Gildenbank-Ausgabe: ${result.reported.length} abgehakte(n) Posten gemeldet`
                    + `${extra.length ? ` (${extra.join(", ")})` : ""}.`);
                refreshHandouts({ force: true });
                return true;
            } catch (e) {
                const partial = (e && e.reported) || [];
                rememberReported(partial);
                handoutsReportRetryAt = Date.now() + HANDOUTS_REPORT_RETRY_MS;
                h.reportError = { at: Date.now(), message: e.message };
                log("error", `Gildenbank-Ausgabe: Melden fehlgeschlagen — ${e.message}. `
                    + "Neuer Versuch in 5 min oder bei der nächsten Änderung.");
                if (partial.length) refreshHandouts({ force: true });
                return false;
            } finally {
                h.reporting = false;
                h.done = handouts.unreported(handoutsDone, cfg.guildBankDoneReported).length;
            }
        })();
        handoutsReportRun = run;
        run.then(() => {
            if (handoutsReportRun === run) handoutsReportRun = null;
        });
        return run;
    }

    /**
     * Council-Daten vom Server holen und als CouncilData.lua in jeden
     * installierten Addon-Ordner schreiben (lib/council.js).
     *
     * Wirft nie und lehnt nie ab: ein Fehler hier — Server ohne die Route,
     * Addon-Ordner schreibgeschützt — darf den Upload-Takt nicht anhalten. Er
     * landet in state.council.lastError und im Verlauf.
     *
     * @param {{ force?: boolean }} [options]  force: auch kurz nach dem letzten
     *   Abruf und mit Meldung, wenn noch nichts eingerichtet ist (Klick in der
     *   Oberfläche). Ohne force fallen automatische Anlässe binnen einer Minute
     *   zu einem zusammen.
     * @returns {Promise<object|null>} das Ergebnis von syncCouncil(), sonst null
     */
    function refreshCouncil({ force = false } = {}) {
        if (councilRun) return councilRun;
        const c = state.council;
        if (!force && c.lastFetch && Date.now() - c.lastFetch < COUNCIL_MIN_GAP_MS) return Promise.resolve(null);
        c.fetching = true;
        const run = (async () => {
            try {
                if ((config.missing(cfg) || []).length) {
                    if (force) throw new Error("Noch nicht eingerichtet — Adresse und Token fehlen.");
                    return null;
                }
                const result = await council.syncCouncil(cfg);
                const categories = Array.isArray(result.payload.categories) ? result.payload.categories : [];
                Object.assign(c, {
                    lastFetch: Date.now(),
                    generatedAt: Number(result.payload.generatedAt) || 0,
                    raiders: result.raiders,
                    // Die Loot-Council-Kategorien, wie sie ins Spiel gehen.
                    categories: categories.map((k) => ({
                        id: String(k.id ?? ""),
                        name: String(k.name || k.id || ""),
                        raiders: Array.isArray(k.raiders) ? k.raiders.length : 0,
                    })),
                    // Ein älterer Server (Version 1): eine Kategorie aus der
                    // Konfiguration statt aller von der Webseite.
                    fallback: result.payload.fromVersion === 1,
                    files: result.files,
                    lastError: result.errors.length ? { at: Date.now(), message: result.errors.join("; ") } : null,
                });
                const what = `${councilCategoriesLabel(categories.length)}, ${result.raiders} Raider`;
                if (!result.dirs.length) {
                    log("warn", `Council-Daten geholt (${what}), aber kein installierter `
                        + "Addon-Ordner EventHelperSync gefunden — nichts geschrieben.");
                } else if (result.files.length) {
                    log("ok", `Council-Daten: ${what} in ${result.files.length} Addon-Ordner `
                        + "geschrieben — im Spiel nach /reload sichtbar.");
                }
                if (!categories.length) {
                    log("warn", "Keine Kategorie mit Loot-Council: auf der Webseite unter Einstellungen > "
                        + "Kategorien das Lootsystem auf Loot-Council stellen.");
                }
                for (const err of result.errors) log("error", `Council-Daten nicht geschrieben: ${err}`);
                return result;
            } catch (e) {
                c.lastError = { at: Date.now(), message: e.message };
                log("error", `Council-Daten: ${e.message}`);
                return null;
            } finally {
                c.fetching = false;
            }
        })();
        // Erst nach der Zuweisung freigeben: ohne await im Körper (nicht
        // eingerichtet) ist `run` schon fertig, bevor es hier ankommt.
        councilRun = run;
        run.then(() => {
            if (councilRun === run) councilRun = null;
        });
        return run;
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
            // Nicht abgewartet: der Abruf blockiert den Upload-Takt nicht und
            // kann ihn auch nicht scheitern lassen (refreshCouncil wirft nie).
            refreshCouncil();
            refreshHandouts();
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
                refreshCouncil();
                refreshHandouts();
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
            // Die .exe startet auch uneingerichtet direkt mit der Oberfläche
            // (dort wird eingerichtet) — bis dahin gibt es kein Ziel, an das
            // sich hochladen liesse. Nach dem Speichern setzt reload() neu auf.
            if (config.missing(cfg).length) return;

            const changed = state.fileMtime !== tick.lastSeenMtime;
            if (changed || firstRun) {
                if (changed && !firstRun) {
                    log("info", "Datei hat sich geändert — lade hoch.");
                    // Kurz warten, damit ein noch laufender Schreibvorgang durch ist.
                    await new Promise((r) => setTimeout(r, 1500));
                    readState();
                }
                tick.lastSeenMtime = state.fileMtime;
                firstRun = false;
                try {
                    await uploadNow();
                } catch {
                    // Already logged. The guild bank below goes on regardless.
                }
                // A changed file retries a failed guild bank upload (and a
                // failed report of ticked handouts) at once.
                guildBankRetryAt = 0;
                handoutsReportRetryAt = 0;
            }
            // Every tick, not only on a change: a failed upload is retried
            // once its pause is over.
            await syncGuildBank();
            await reportHandoutsDone();
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
        log("info", `EventHelper Loot-Sync ${SYNC_VERSION} — Ziel: ${cfg.baseUrl || "noch nicht eingerichtet"}`);
        if (state.file) log("info", `Beobachte ${state.file}`);
        else log("warn", "Noch keine EventHelperSync.lua gefunden — suche weiter.");
        log("info", "WoW schreibt die Datei beim Ausloggen, bei /reload und über den Upload-Knopf im Spiel.");

        tick();
        timer = setInterval(tick, Math.max(5, Number(cfg.pollSeconds) || 15) * 1000);
        refreshCouncil();
        councilTimer = setInterval(() => refreshCouncil(), COUNCIL_INTERVAL_MS);
        refreshHandouts();
        handoutsTimer = setInterval(() => refreshHandouts(), HANDOUTS_INTERVAL_MS);
    }

    function stop() {
        if (timer) clearInterval(timer);
        timer = null;
        if (councilTimer) clearInterval(councilTimer);
        councilTimer = null;
        if (handoutsTimer) clearInterval(handoutsTimer);
        handoutsTimer = null;
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
        const before = cfg;
        cfg = config.load();
        stop();
        firstRun = true;
        tick.lastSeenMtime = -1;
        readState();
        timer = setInterval(tick, Math.max(5, Number(cfg.pollSeconds) || 15) * 1000);
        councilTimer = setInterval(() => refreshCouncil(), COUNCIL_INTERVAL_MS);
        handoutsTimer = setInterval(() => refreshHandouts(), HANDOUTS_INTERVAL_MS);
        log("info", "Einstellungen neu geladen.");
        // Ein neues Ziel (oder, nur für ältere Server, eine andere
        // Kategorie/Rolle in der Konfiguration): gleich neu holen, nicht erst
        // in einer Viertelstunde.
        const councilChanged = ["baseUrl", "token", "councilCategory", "councilRole"]
            .some((k) => (before[k] || "") !== (cfg[k] || ""));
        refreshCouncil({ force: councilChanged });
        // A new target: fetch the handouts at once as well.
        const targetChanged = ["baseUrl", "token"].some((k) => (before[k] || "") !== (cfg[k] || ""));
        refreshHandouts({ force: targetChanged });
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
        syncGuildBank,
        testConnection,
        readState,
        setExcluded,
        refreshCouncil,
        refreshHandouts,
        reportHandoutsDone,
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

module.exports = {
    createRunner, describe, whyNothing, LOG_LIMIT, COUNCIL_INTERVAL_MS, COUNCIL_MIN_GAP_MS, GUILD_BANK_RETRY_MS,
    HANDOUTS_INTERVAL_MS, HANDOUTS_MIN_GAP_MS, HANDOUTS_REPORT_RETRY_MS, councilCategoriesLabel,
};
