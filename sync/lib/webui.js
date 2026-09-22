"use strict";

/**
 * Die Oberfläche des Sync-Tools: ein kleiner HTTP-Server auf 127.0.0.1, den
 * appWindow.js als chromeloses Fenster öffnet (kein Adressbalken, keine Tabs —
 * sieht wie ein eigenständiges Programm aus, ist aber technisch weiter eine
 * Webseite).
 *
 * Warum so und nicht Electron oder ein natives GUI-Toolkit: das würde die .exe
 * vervielfachen (Electron: ~150-200 statt ~66 MB) und den SEA-Bau (Nodes
 * Single-Executable-Applications, siehe scripts/build-exe.js) zunichtemachen.
 * Edge/Chrome sind auf jedem Windows-Rechner schon da, und die Seite ist eine
 * einzige Zeichenkette, die beim Packen automatisch mitkommt.
 *
 * Abgesichert wird das Ganze auf drei Wegen, denn hier liegt ein Token, das auf
 * dem Gildenserver hochladen darf:
 *
 *   1. Es wird nur an 127.0.0.1 gebunden — von aussen ist nichts erreichbar.
 *   2. Jeder Aufruf braucht den Schlüssel, der beim Start neu ausgewürfelt und
 *      nur in die geöffnete Adresse geschrieben wird. Eine fremde Webseite, die
 *      im Hintergrund auf localhost schiesst, kennt ihn nicht.
 *   3. Das Token selbst verlässt den Server nie — die Seite bekommt nur die
 *      letzten vier Zeichen zu sehen und kann ein neues setzen.
 */
const http = require("http");
const crypto = require("crypto");
const { execFile } = require("child_process");
const config = require("./config");
const wowPaths = require("./wowPaths");
const { fetchRaidStatus } = require("./uploader");
const { PAGE } = require("./webui-page");

const HOST = "127.0.0.1";
// Frei gewählter Port oberhalb der üblichen Entwicklungsports. Ist er belegt,
// wird der nächste genommen (siehe listen()).
const DEFAULT_PORT = 8730;
const PORT_TRIES = 20;

function json(res, status, body) {
    const text = JSON.stringify(body);
    res.writeHead(status, {
        "Content-Type": "application/json; charset=utf-8",
        "Cache-Control": "no-store",
        // Die Antworten sind für diese eine Seite bestimmt, für sonst niemanden.
        "X-Content-Type-Options": "nosniff",
    });
    res.end(text);
}

function readBody(req) {
    return new Promise((resolve) => {
        let data = "";
        req.on("data", (chunk) => {
            data += chunk;
            if (data.length > 1e5) req.destroy();
        });
        req.on("end", () => {
            try {
                resolve(JSON.parse(data || "{}"));
            } catch {
                resolve({});
            }
        });
        req.on("error", () => resolve({}));
    });
}

/** Was die Oberfläche über die Konfiguration erfahren darf — nie das Token. */
function safeConfig(cfg) {
    return {
        baseUrl: cfg.baseUrl || "",
        hasToken: !!cfg.token,
        tokenHint: cfg.token ? String(cfg.token).slice(-4) : "",
        savedVariablesPath: cfg.savedVariablesPath || "",
        pollSeconds: cfg.pollSeconds || 15,
    };
}

/**
 * @param {object} runner  aus createRunner()
 * @param {{ onQuit?: () => void }} [options]  onQuit: nach /api/quit aufgerufen
 *   (index.js reicht hier process.exit rein — hier drin nie direkt aufrufen,
 *   sonst würde ein Test, der den Server startet, den Testlauf mitbeenden).
 * @returns {{ start: () => Promise<string> , stop: () => void }}
 */
function createWebUI(runner, { onQuit } = {}) {
    const key = crypto.randomBytes(16).toString("hex");
    let server = null;
    let url = "";

    const authorized = (req, parsed) => parsed.searchParams.get("key") === key;

    const server_ = http.createServer(async (req, res) => {
        const parsed = new URL(req.url, `http://${HOST}`);

        // Der Rumpf jeder POST-Anfrage wird gelesen, auch wenn der Endpunkt ihn
        // nicht braucht und auch wenn gleich abgewiesen wird: antwortet der
        // Server, bevor die Anfrage vollständig eingelesen ist, bricht Node die
        // Verbindung ab (ECONNRESET beim Aufrufer) — und eine abgewiesene
        // Anfrage soll als 403 ankommen, nicht als Verbindungsfehler.
        const body = req.method === "POST" ? await readBody(req) : {};

        if (!authorized(req, parsed)) {
            // Bewusst wortkarg: wer den Schlüssel nicht hat, erfährt auch nicht,
            // was es hier zu holen gäbe.
            json(res, 403, { error: "Ungültiger Schlüssel. Bitte die Adresse aus der Konsole verwenden." });
            return;
        }

        try {
            if (req.method === "GET" && parsed.pathname === "/") {
                res.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
                res.end(PAGE);
                return;
            }

            if (req.method === "GET" && parsed.pathname === "/api/state") {
                const s = runner.state;
                json(res, 200, {
                    version: s.version,
                    file: s.file,
                    fileMtime: s.fileMtime,
                    sessions: s.sessions,
                    readError: s.readError,
                    envelopeMissing: !!s.envelopeMissing,
                    lastCheck: s.lastCheck,
                    lastUpload: s.lastUpload,
                    lastError: s.lastError,
                    uploading: s.uploading,
                    log: s.log,
                    config: safeConfig(runner.config),
                    candidates: wowPaths.discover(runner.config.extraRoots)
                        .map((c) => ({ path: c.path, flavor: c.flavor, account: c.account })),
                    // Nur wenn nichts gefunden wurde: dann ist "wo wurde gesucht?"
                    // die einzige Frage, die weiterhilft. Sonst nur Rauschen.
                    searchedRoots: s.file ? [] : wowPaths.searchedRoots(runner.config.extraRoots),
                });
                return;
            }

            if (req.method === "POST" && parsed.pathname === "/api/settings") {
                const current = config.load();

                // Ein von Hand eingetippter Pfad hat Vorrang vor der Auswahl —
                // er wird ja nur ausgefüllt, wenn die Auswahl nicht reicht. Er
                // darf auch ein Ordner sein; resolveUserPath() findet die Datei.
                const manual = String(body.manualPath || "").trim();
                let savedVariablesPath = String(body.savedVariablesPath || "").trim();
                if (manual) {
                    const resolved = wowPaths.resolveUserPath(manual);
                    if (resolved.error) {
                        json(res, 400, { error: resolved.error });
                        return;
                    }
                    savedVariablesPath = resolved.path;
                }

                const next = {
                    ...current,
                    baseUrl: String(body.baseUrl || "").trim().replace(/\/+$/, ""),
                    savedVariablesPath,
                    pollSeconds: Math.min(600, Math.max(5, Number(body.pollSeconds) || 15)),
                };
                // Ein leeres Feld heisst "unverändert lassen" — sonst wäre das
                // Token nach jedem Speichern der anderen Werte weg.
                const token = String(body.token || "").trim();
                if (token) next.token = token;

                config.save(next);
                runner.reload();
                json(res, 200, { ok: true, config: safeConfig(config.load()) });
                return;
            }

            // Raid-Abende hier ab- oder anwählen. Nimmt eine Liste entgegen,
            // damit "alle angezeigten abwählen" ein Aufruf bleibt und nicht
            // fünfzig.
            if (req.method === "POST" && parsed.pathname === "/api/sessions") {
                const ids = Array.isArray(body.sessionIds) ? body.sessionIds : [body.sessionId];
                const excluded = runner.setExcluded(ids, body.excluded === true);
                json(res, 200, { ok: true, excludedSessions: excluded });
                return;
            }

            if (req.method === "POST" && parsed.pathname === "/api/upload") {
                const results = await runner.uploadNow();
                json(res, 200, { ok: true, results });
                return;
            }

            if (req.method === "POST" && parsed.pathname === "/api/test") {
                await runner.testConnection();
                json(res, 200, { ok: true });
                return;
            }

            // Für die Raid-Liste: welche der letzten Raids schon Loot haben, und
            // welche der lokalen Sessions dafür bereitstehen. Ein Aufruf gegen
            // den echten Server bei jeder Anfrage — das Token bleibt dabei hier
            // im Node-Prozess, die Seite bekommt es nie zu sehen.
            if (req.method === "GET" && parsed.pathname === "/api/raids") {
                const { raids } = await fetchRaidStatus(runner.config, runner.state.sessions);
                json(res, 200, { raids });
                return;
            }

            // Nur eine einzelne Raid-Zeile hochladen (der rote Knopf in der
            // Liste), statt wie /api/upload die ganze Datei.
            if (req.method === "POST" && parsed.pathname === "/api/upload-one") {
                const sessionId = String(body.sessionId || "").trim();
                if (!sessionId) {
                    json(res, 400, { error: "sessionId fehlt." });
                    return;
                }
                const results = await runner.uploadOne(sessionId);
                json(res, 200, { ok: true, results });
                return;
            }

            // Der ✕-Knopf im Fenster: beendet den ganzen Sync-Tool, nicht nur
            // das Browserfenster. Wichtig, seit die Konsole beim Doppelklick
            // versteckt wird (index.js) — ohne das hier gäbe es sonst keine
            // sichtbare Möglichkeit mehr, den Hintergrundprozess zu beenden.
            if (req.method === "POST" && parsed.pathname === "/api/quit") {
                json(res, 200, { ok: true });
                runner.stop();
                // Erst antworten, dann beenden — sonst bekäme die Seite nie
                // die Bestätigung, dass es geklappt hat.
                if (onQuit) setTimeout(onQuit, 50);
                return;
            }

            json(res, 404, { error: "Unbekannter Pfad." });
        } catch (e) {
            json(res, 500, { error: e.message || "Unerwarteter Fehler." });
        }
    });

    /**
     * Ab dem Vorgabeport aufwärts probieren, bis einer frei ist.
     * Port 0 heisst "irgendeinen freien" — dann vergibt ihn das Betriebssystem,
     * und wir melden zurück, welcher es geworden ist.
     */
    function listen(port, attemptsLeft) {
        return new Promise((resolve, reject) => {
            const onError = (e) => {
                server_.removeListener("listening", onListening);
                if (e.code === "EADDRINUSE" && port !== 0 && attemptsLeft > 0) {
                    resolve(listen(port + 1, attemptsLeft - 1));
                } else {
                    reject(e);
                }
            };
            const onListening = () => {
                server_.removeListener("error", onError);
                resolve(server_.address().port);
            };
            server_.once("error", onError);
            server_.once("listening", onListening);
            server_.listen(port, HOST);
        });
    }

    async function start(preferredPort) {
        // Sorgfältig unterschieden: 0 ist ein gültiger Wunsch ("irgendeiner"),
        // undefined/"" heisst "nimm den Vorgabeport".
        const wanted = preferredPort === undefined || preferredPort === null || preferredPort === ""
            ? DEFAULT_PORT
            : Number(preferredPort);
        const port = await listen(Number.isFinite(wanted) ? wanted : DEFAULT_PORT, PORT_TRIES);
        server = server_;
        url = `http://${HOST}:${port}/?key=${key}`;
        return url;
    }

    function stop() {
        if (!server) return;
        // Offene Verbindungen mitschliessen: die Seite hält per Keep-Alive eine
        // Verbindung, und close() allein würde auf deren Ende warten — das
        // Programm bliebe beim Beenden hängen.
        if (server.closeAllConnections) server.closeAllConnections();
        server.close();
        server = null;
    }

    return { start, stop, get url() { return url; }, get key() { return key; } };
}

/** Die Oberfläche im Standardbrowser öffnen. Fehlschläge sind nicht schlimm. */
function openInBrowser(url) {
    try {
        if (process.platform === "win32") {
            // Über cmd, weil "start" ein eingebauter Befehl ist. Der leere
            // Titel-Parameter ist nötig, sonst schluckt start die URL als Titel.
            execFile("cmd", ["/c", "start", "", url], { windowsHide: true });
        } else if (process.platform === "darwin") {
            execFile("open", [url]);
        } else {
            execFile("xdg-open", [url]);
        }
        return true;
    } catch {
        return false;
    }
}

module.exports = { createWebUI, openInBrowser, safeConfig, DEFAULT_PORT };
