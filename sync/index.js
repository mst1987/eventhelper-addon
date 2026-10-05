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
 *   npx eventhelper-sync council  Council-Daten einmal holen und ins Addon schreiben
 */
const fs = require("fs");
const readline = require("readline");
const config = require("./lib/config");
const wowPaths = require("./lib/wowPaths");
const { readEnvelope, uploadFile, describeResult, UploadError, SYNC_VERSION } = require("./lib/uploader");
const { createRunner } = require("./lib/runner");
const council = require("./lib/council");
const { createWebUI, openInBrowser } = require("./lib/webui");
const { openAppWindow, showMessageBox } = require("./lib/appWindow");
const instance = require("./lib/instance");

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

/**
 * Nach einem Pfad fragen und ihn gleich prüfen, statt einen unbrauchbaren Wert
 * zu speichern und erst beim nächsten Start zu scheitern. Angenommen wird auch
 * der blosse WoW-Ordner — den exakten Dateipfad kennt niemand auswendig.
 */
async function askForPath(rl, optional = false) {
    for (;;) {
        const answer = await ask(rl, optional
            ? "WoW-Ordner (leer lassen = später automatisch suchen)"
            : "WoW-Ordner oder Pfad zur EventHelperSync.lua");
        if (!answer) return "";
        const resolved = wowPaths.resolveUserPath(answer);
        if (resolved.path) {
            console.log(`  gefunden: ${resolved.path}`);
            return resolved.path;
        }
        console.log(`  ${resolved.error}`);
    }
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
            savedVariablesPath = await askForPath(rl);
        } else {
            // Leer lassen heisst "immer neu suchen" — überlebt einen Neuinstall.
            savedVariablesPath = Number(pick) === 1 ? "" : (found[Number(pick) - 1] || {}).path || "";
        }
    } else {
        console.log("\nKeine EventHelperSync.lua gefunden.");
        console.log("Gesucht wurde unter:");
        for (const root of wowPaths.searchedRoots(current.extraRoots)) console.log(`  ${root}`);
        console.log("\nIst das Addon installiert und war im Spiel schon einmal geladen?");
        console.log("Falls ja, liegt WoW woanders — dann hier den WoW-Ordner angeben.");
        savedVariablesPath = await askForPath(rl, true);
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
        // Geworfen statt beendet, damit main() das Fenster noch offen halten
        // kann — bei der .exe wäre die Meldung sonst weg, bevor man sie liest.
        throw new Error(
            `Konfiguration unvollständig: ${problems.join(", ")}\n`
            + `Einrichten mit dem Befehl "init"   (Datei: ${config.CONFIG_FILE})`,
        );
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

async function cmdOnce() {
    const cfg = requireReady();
    const file = resolveFile(cfg);
    if (!file) {
        fail("Keine EventHelperSync.lua gefunden. Ist das Addon installiert und war einmal geladen?");
        process.exit(1);
    }
    try {
        const { results } = await uploadFile(cfg, file);
        if (!results.length) {
            log("Nichts hochzuladen.");
            return;
        }
        for (const r of results) log(`${r.sessionId}: ${describeResult(r)}`);
        const pending = results.filter((r) => r.status === "pending" || r.status === "updated").length;
        if (pending) {
            log(`${pending} Session(s) warten im Admin-Menü unter Historie & Loot -> Addon-Inbox auf Bestätigung.`);
        }
    } catch (e) {
        fail(e instanceof UploadError ? `Upload fehlgeschlagen: ${e.message}` : e.message);
        process.exit(1);
    }
}

/**
 * Council-Daten einmal holen und als CouncilData.lua in jeden installierten
 * Addon-Ordner schreiben (lib/council.js) — dasselbe, was der Dauerbetrieb
 * alle 15 Minuten tut.
 */
async function cmdCouncil() {
    const cfg = requireReady();
    let result;
    try {
        result = await council.syncCouncil(cfg);
    } catch (e) {
        fail(`Council-Daten nicht geholt: ${e.message}`);
        process.exit(1);
    }
    const filter = result.payload.filter || {};
    log(`${result.raiders} Raider${filter.categoryName ? ` (${filter.categoryName})` : ""}, `
        + `BiS-Liste ${filter.bisTier || "-"}.`);
    if (!result.dirs.length) {
        fail("Kein installierter Addon-Ordner EventHelperSync gefunden — nichts geschrieben.");
        process.exit(1);
    }
    for (const file of result.files) log(`geschrieben: ${file}`);
    for (const err of result.errors) fail(`nicht geschrieben: ${err}`);
    if (result.errors.length) process.exit(1);
    log("Im Spiel /reload, dann /ehc.");
}

/**
 * Ob dies die gepackte Windows-.exe ist. Die ist ein GUI-Programm ohne Konsole
 * (scripts/exeResources.js): Einrichtung läuft dort über die Oberfläche,
 * Meldungen über einen Dialog — was in die Konsole ginge, sähe niemand.
 */
function isGuiExe() {
    if (process.platform !== "win32") return false;
    try {
        return require("node:sea").isSea();
    } catch {
        return false;
    }
}

/** Die Oberfläche öffnen: bevorzugt als eigenes Fenster, sonst als Browser-Tab. */
function openUi(url) {
    if (!openAppWindow(url)) openInBrowser(url);
}

/**
 * Dauerbetrieb. Standardmässig mit Oberfläche: ein eigenes Fenster (Edge/
 * Chrome ohne Adressleiste und Tabs, siehe lib/appWindow.js) zeigt Stand und
 * Raid-Liste, ohne dass jemand einen Befehl kennen muss. Mit --no-ui bleibt es
 * bei den Konsolenzeilen (für den Betrieb als Dienst).
 */
async function cmdWatch() {
    const withUi = !process.argv.includes("--no-ui");
    // Mit Oberfläche lässt sich dort einrichten; ohne gibt es nur die Datei.
    if (!withUi) requireReady();

    if (withUi) {
        // Läuft schon eine Instanz (Fenster nur zugemacht), deren Fenster
        // wieder öffnen statt eine zweite daneben zu starten (lib/instance.js).
        const running = await instance.findRunning();
        if (running) {
            log(`Läuft bereits — öffne das vorhandene Fenster: ${running}`);
            openUi(running);
            return;
        }
    }

    // Jede Zeile aus dem Runner geht zusätzlich in die Konsole, damit beide
    // Wege denselben Verlauf zeigen.
    const runner = createRunner({
        onLog: (e) => (e.level === "error" ? fail(e.text) : log(e.text)),
    });

    if (withUi) {
        // onQuit: process.exit() gehört nicht in webui.js selbst — sonst würde
        // ein Test, der den Server startet, den Testlauf mitbeenden.
        const ui = createWebUI(runner, { onQuit: () => process.exit(0) });
        try {
            const url = await ui.start(process.env.EVENTHELPER_SYNC_UI_PORT);
            log(`Oberfläche: ${url}`);
            instance.register(url);
            openUi(url);
        } catch (e) {
            // In der .exe liefe der Upload ohne Oberfläche unsichtbar und
            // unbeendbar weiter — dort lieber sagen, was los ist, und aufhören.
            if (isGuiExe()) throw new Error(`Die Oberfläche konnte nicht gestartet werden: ${e.message}`);
            fail(`Oberfläche konnte nicht gestartet werden: ${e.message}`);
            fail("Der Upload läuft trotzdem weiter.");
        }
    }

    runner.start();
    process.on("SIGINT", () => {
        runner.stop();
        log("Beendet.");
        process.exit(0);
    });
}

/**
 * Ob das Programm ohne Argumente gestartet wurde — bei der .exe heisst das in
 * aller Regel: per Doppelklick. Dann gibt es keine Konsole, die stehen bleibt,
 * also darf das Fenster nicht einfach zuklappen, bevor jemand die Meldung
 * gelesen hat.
 */
const launchedBare = () => process.argv.length <= 2;

/** Fenster offen halten, bis Enter gedrückt wird. */
function waitForEnter() {
    return new Promise((resolve) => {
        const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
        rl.question("\nEnter zum Schliessen …", () => { rl.close(); resolve(); });
    });
}

async function main() {
    // Ohne Argument: beim ersten Start durch die Einrichtung führen, sonst
    // beobachten. Ein Doppelklick auf die frisch heruntergeladene .exe soll
    // etwas Sinnvolles tun und nicht mit "Konfiguration unvollständig" abbrechen.
    // Die .exe hat keine Konsole für die Fragen von "init": sie geht immer in
    // die Oberfläche, die ein fehlendes Token selbst anmahnt.
    let cmd = (process.argv[2] || "").toLowerCase();
    if (!cmd) {
        cmd = isGuiExe() || !config.missing(config.load()).length ? "watch" : "init";
    }

    if (isGuiExe() && cmd !== "watch") {
        showMessageBox(
            `„${cmd}" ist ein Konsolenbefehl — die EventHelperSync.exe hat keine Konsole.\n\n`
            + "Ein Doppelklick öffnet das Fenster; Einrichtung und Upload liegen dort.\n"
            + "Die Befehle init, once, status und council gibt es mit Node.js: npx eventhelper-sync <befehl>",
        );
        return;
    }

    switch (cmd) {
    case "init":
        await cmdInit();
        // Direkt weiterlaufen, wenn die Einrichtung vollständig ist — sonst
        // müsste man die .exe nach dem Einrichten nochmal starten.
        if (launchedBare() && !config.missing(config.load()).length) {
            console.log("");
            return cmdWatch();
        }
        return;
    case "once": return cmdOnce();
    case "status": return cmdStatus();
    case "council": return cmdCouncil();
    case "watch": return cmdWatch();
    default:
        console.log("Befehle: init | once | watch | status | council");
        console.log("  watch --no-ui   ohne Browser-Oberfläche (für den Betrieb als Dienst)");
        console.log(`Konfiguration: ${config.CONFIG_FILE}`);
        process.exit(1);
    }
}

/** Einstiegspunkt inklusive Fehlerbehandlung — auch von der .exe aus benutzt. */
async function run() {
    try {
        await main();
    } catch (e) {
        fail(e.stack || e.message);
        if (isGuiExe()) showMessageBox(e.message, { error: true });
        else if (launchedBare()) await waitForEnter();
        process.exit(1);
    }
}

// In der gepackten .exe ist `require.main` nicht gesetzt; dort ruft
// scripts/sea-entry.js run() direkt auf.
if (require.main === module) run();

module.exports = { main, run, resolveFile, isGuiExe };
