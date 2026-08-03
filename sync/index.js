#!/usr/bin/env node
"use strict";

/**
 * EventHelper Loot-Sync — die Brücke zwischen dem WoW-Addon und dem Bot.
 *
 * Das Addon schreibt den Loot beider Loot-Addons in seine SavedVariables (mehr
 * kann es nicht: WoWs Lua-Sandbox hat keinen Netzwerkzugriff). Dieses Programm
 * beobachtet die Datei und lädt neue Raid-Sessions hoch.
 *
 * Befehle:
 *   npx eventhelper-sync init     Konfiguration anlegen (fragt interaktiv)
 *   npx eventhelper-sync once     einmal hochladen und beenden
 *   npx eventhelper-sync watch    dauerhaft beobachten (Standard)
 *   npx eventhelper-sync status   zeigen, was gefunden wurde, ohne zu senden
 */
const fs = require("fs");
const readline = require("readline");
const config = require("./lib/config");
const wowPaths = require("./lib/wowPaths");
const { readEnvelope, uploadFile, describeResult, UploadError, SYNC_VERSION } = require("./lib/uploader");

const stamp = () => new Date().toLocaleTimeString("de-DE");
const log = (...args) => console.log(`[${stamp()}]`, ...args);
const fail = (...args) => console.error(`[${stamp()}]`, ...args);

/** Die zu beobachtende Datei: aus der Konfiguration, sonst automatisch gesucht. */
function resolveFile(cfg, { quiet = false } = {}) {
    if (cfg.savedVariablesPath) {
        if (fs.existsSync(cfg.savedVariablesPath)) return cfg.savedVariablesPath;
        fail(`Konfigurierter Pfad existiert nicht: ${cfg.savedVariablesPath}`);
        return null;
    }
    const found = wowPaths.discover(cfg.extraRoots);
    if (!found.length) return null;
    if (found.length > 1 && !quiet) {
        log(`${found.length} WoW-Accounts mit dem Addon gefunden, nehme den zuletzt geschriebenen:`);
        found.forEach((f, i) => log(`   ${i === 0 ? "->" : "  "} ${f.flavor} / ${f.account}`));
        log("   Anderen festlegen: savedVariablesPath in " + config.CONFIG_FILE);
    }
    return found[0].path;
}

function ask(rl, question, fallback = "") {
    return new Promise((resolve) => {
        rl.question(fallback ? `${question} [${fallback}]: ` : `${question}: `, (answer) => {
            resolve(String(answer || "").trim() || fallback);
        });
    });
}

async function cmdInit() {
    const current = config.load();
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });

    console.log("EventHelper Loot-Sync — Einrichtung");
    console.log(`Die Konfiguration wird in ${config.CONFIG_FILE} gespeichert.\n`);

    const baseUrl = await ask(rl, "Adresse des EventHelper (z.B. https://pulse-gdkp.de:3005)", current.baseUrl);
    console.log("\nDas Token steht im Admin-Menü unter Einstellungen -> Loot-Sync.");
    console.log("Es wird dort genau einmal angezeigt.");
    const token = await ask(rl, "API-Token", current.token);

    const found = wowPaths.discover(current.extraRoots);
    let savedVariablesPath = current.savedVariablesPath;
    if (found.length) {
        console.log("\nGefundene Addon-Daten:");
        found.forEach((f, i) => console.log(`  [${i + 1}] ${f.flavor} / ${f.account}`));
        console.log("  [0] anderen Pfad von Hand angeben");
        const pick = await ask(rl, "Auswahl", "1");
        if (pick === "0") {
            savedVariablesPath = await ask(rl, "Voller Pfad zur EventHelperSync.lua");
        } else {
            // Leer lassen heisst "immer neu suchen" — überlebt einen Neuinstall.
            savedVariablesPath = Number(pick) === 1 ? "" : (found[Number(pick) - 1] || {}).path || "";
        }
    } else {
        console.log("\nKeine EventHelperSync.lua gefunden. Das ist normal, solange das Addon");
        console.log("noch nie geladen war — einmal einloggen und /reload genügt.");
        savedVariablesPath = await ask(rl, "Pfad (leer lassen = später automatisch suchen)", "");
    }

    rl.close();
    const saved = config.save({ ...current, baseUrl, token, savedVariablesPath });
    console.log(`\nGespeichert in ${config.CONFIG_FILE}.`);

    const problems = config.missing(saved);
    if (problems.length) {
        console.log("Es fehlt noch: " + problems.join(", "));
    } else {
        console.log("Fertig. Jetzt starten mit:  npx eventhelper-sync watch");
    }
}

function requireReady() {
    const cfg = config.load();
    const problems = config.missing(cfg);
    if (problems.length) {
        fail("Konfiguration unvollständig: " + problems.join(", "));
        fail(`Einrichten mit:  npx eventhelper-sync init   (Datei: ${config.CONFIG_FILE})`);
        process.exit(1);
    }
    return cfg;
}

async function cmdStatus() {
    const cfg = config.load();
    console.log(`Sync-Tool ${SYNC_VERSION}`);
    console.log(`Konfiguration: ${config.CONFIG_FILE}${config.exists() ? "" : "  (existiert noch nicht)"}`);
    console.log(`Server:        ${cfg.baseUrl || "— nicht gesetzt —"}`);
    console.log(`Token:         ${cfg.token ? `…${cfg.token.slice(-4)}` : "— nicht gesetzt —"}`);

    const file = resolveFile(cfg);
    if (!file) {
        console.log("Addon-Daten:   nicht gefunden");
        return;
    }
    console.log(`Addon-Daten:   ${file}`);

    let envelope;
    try {
        envelope = readEnvelope(file);
    } catch (e) {
        console.log(`Inhalt:        nicht lesbar — ${e.message}`);
        return;
    }
    if (!envelope) {
        console.log("Inhalt:        noch kein Export (im Spiel einmal /reload ausführen)");
        return;
    }
    const sessions = envelope.sessions || [];
    const items = sessions.reduce((sum, s) => sum + ((s.items || []).length), 0);
    console.log(`Inhalt:        ${sessions.length} Session(s), ${items} Item(s), Format v${envelope.version}`);
    for (const s of sessions) {
        const when = new Date((s.startedAt || 0) * 1000).toLocaleString("de-DE");
        console.log(`   · ${when} — ${s.instance || "unbekannte Instanz"}, ${(s.items || []).length} Item(s)`);
    }
}

async function runUpload(cfg, file) {
    const { results } = await uploadFile(cfg, file);
    if (!results.length) {
        log("Nichts hochzuladen.");
        return;
    }
    for (const r of results) {
        log(`${r.sessionId}: ${describeResult(r)}`);
    }
    const pending = results.filter((r) => r.status === "pending" || r.status === "updated").length;
    if (pending) {
        log(`${pending} Session(s) warten im Admin-Menü unter Historie & Loot -> Addon-Inbox auf Bestätigung.`);
    }
}

async function cmdOnce() {
    const cfg = requireReady();
    const file = resolveFile(cfg);
    if (!file) {
        fail("Keine EventHelperSync.lua gefunden. Ist das Addon installiert und war einmal geladen?");
        process.exit(1);
    }
    try {
        await runUpload(cfg, file);
    } catch (e) {
        fail(e instanceof UploadError ? `Upload fehlgeschlagen: ${e.message}` : e.message);
        process.exit(1);
    }
}

async function cmdWatch() {
    const cfg = requireReady();
    let file = resolveFile(cfg);
    let lastMtime = 0;
    let busy = false;

    log(`EventHelper Loot-Sync ${SYNC_VERSION} — Ziel: ${cfg.baseUrl}`);
    if (file) {
        log(`Beobachte ${file}`);
    } else {
        log("Noch keine EventHelperSync.lua gefunden — suche weiter.");
    }
    log("WoW schreibt die Datei erst beim Ausloggen oder nach /reload.");

    const tick = async () => {
        if (busy) return;
        busy = true;
        try {
            if (!file) {
                file = resolveFile(cfg, { quiet: true });
                if (file) log(`Gefunden: ${file}`);
            }
            if (!file) return;

            let mtime;
            try {
                mtime = fs.statSync(file).mtimeMs;
            } catch {
                // Datei ist gerade weg (WoW schreibt sie neu) — beim nächsten
                // Durchlauf nochmal.
                return;
            }
            if (mtime === lastMtime) return;

            // Kurz warten, damit ein noch laufender Schreibvorgang durch ist.
            await new Promise((r) => setTimeout(r, 1500));
            lastMtime = fs.statSync(file).mtimeMs;
            log("Datei hat sich geändert — lade hoch.");
            await runUpload(cfg, file);
        } catch (e) {
            fail(e instanceof UploadError ? `Upload fehlgeschlagen: ${e.message}` : (e.stack || e.message));
            // Nicht beenden: der Server kann gerade neu starten, WoW kann
            // gerade schreiben. Beim nächsten Durchlauf wird es erneut versucht.
        } finally {
            busy = false;
        }
    };

    await tick();
    const handle = setInterval(tick, Math.max(5, Number(cfg.pollSeconds) || 15) * 1000);
    process.on("SIGINT", () => {
        clearInterval(handle);
        log("Beendet.");
        process.exit(0);
    });
}

async function main() {
    const cmd = (process.argv[2] || "watch").toLowerCase();
    switch (cmd) {
    case "init": return cmdInit();
    case "once": return cmdOnce();
    case "status": return cmdStatus();
    case "watch": return cmdWatch();
    default:
        console.log("Befehle: init | once | watch | status");
        console.log(`Konfiguration: ${config.CONFIG_FILE}`);
        process.exit(1);
    }
}

if (require.main === module) {
    main().catch((e) => {
        fail(e.stack || e.message);
        process.exit(1);
    });
}

module.exports = { resolveFile, runUpload };
