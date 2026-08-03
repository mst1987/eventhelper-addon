"use strict";

/**
 * Die SavedVariables-Datei des Addons auf der Platte finden.
 *
 * WoW legt sie pro Spiel-Variante und pro Battle.net-Account ab:
 *
 *   <WoW>/_classic_era_/WTF/Account/<ACCOUNT>/SavedVariables/EventHelperSync.lua
 *
 * Die erste Fassung hat sechs fest verdrahtete Installationspfade abgeklappert
 * und ist bei jeder anderen Installation stumm gescheitert — "nicht gefunden",
 * ohne zu sagen, wo überhaupt gesucht wurde. Deshalb jetzt:
 *
 *   1. Jeder vorhandene Laufwerksbuchstabe wird betrachtet, nicht nur C/D/E.
 *   2. Unter jedem Laufwerk werden die üblichen Spiele-Ordner geprüft, und
 *      zusätzlich eine Ebene tief nach allem gesucht, was wie "World of
 *      Warcraft" heisst — das deckt auch ungewöhnliche Installationen ab.
 *   3. Wo gesucht wurde, wird zurückgegeben (searchedRoots), damit "nicht
 *      gefunden" eine überprüfbare Aussage ist statt einer Sackgasse.
 *   4. Und wenn all das nicht reicht, nimmt resolveUserPath() einen von Hand
 *      angegebenen Pfad — auch einen Ordner, nicht nur die Datei selbst.
 */
const fs = require("fs");
const path = require("path");

const SAVED_VARIABLES_FILE = "EventHelperSync.lua";

// Bekannte Varianten-Ordner — nur noch als Reihenfolge-Hinweis und für Tests.
// Gesucht wird NICHT nach dieser Liste: Blizzard legt neue Varianten an (zuletzt
// `_anniversary_` für die TBC-Anniversary-Realms), und eine feste Liste lässt das
// Werkzeug jedes Mal stumm scheitern. Erkannt wird stattdessen jeder Unterordner,
// der ein WTF/Account enthält — das ist die Eigenschaft, auf die es ankommt.
const FLAVORS = [
    "_anniversary_", "_classic_era_", "_classic_", "_retail_",
    "_classic_era_ptr_", "_classic_ptr_", "_classic_beta_", "_ptr_", "_beta_", "_xptr_",
];

// Ordner, in denen unterhalb eines Laufwerks üblicherweise Spiele liegen.
const GAME_FOLDERS = [
    "", "Games", "Spiele", "Program Files", "Program Files (x86)",
    "Battle.net", "Blizzard", "Blizzard Entertainment", "Program Files (x86)/Battle.net",
    "Program Files/Battle.net", "Games/Battle.net", "SteamLibrary",
];

// Wie ein WoW-Verzeichnis heissen kann.
const WOW_NAME = /^(world of warcraft|wow[\s_-]*classic|wow)$/i;

function isDir(p) {
    try {
        return fs.statSync(p).isDirectory();
    } catch {
        return false;
    }
}

function listDirs(p) {
    try {
        return fs.readdirSync(p, { withFileTypes: true })
            .filter((e) => e.isDirectory())
            .map((e) => e.name);
    } catch {
        return [];
    }
}

/** Alle vorhandenen Laufwerke (Windows) bzw. die üblichen Wurzeln (macOS/Linux). */
function driveRoots() {
    if (process.platform !== "win32") {
        return ["/Applications", process.env.HOME || "/", "/opt", "/mnt", "/media"];
    }
    const roots = [];
    for (let code = "A".charCodeAt(0); code <= "Z".charCodeAt(0); code += 1) {
        const drive = `${String.fromCharCode(code)}:/`;
        if (isDir(drive)) roots.push(drive);
    }
    return roots;
}

/**
 * Alle Verzeichnisse, die eine WoW-Installation sein könnten.
 * Bewusst breit und trotzdem billig: pro Laufwerk ein paar feste Kandidaten und
 * eine Ebene Auflistung, kein rekursives Durchsuchen der ganzen Platte.
 */
function candidateRoots(extraRoots = []) {
    const found = [];
    const seen = new Set();
    const add = (p) => {
        const key = path.normalize(p).toLowerCase();
        if (seen.has(key)) return;
        seen.add(key);
        found.push(path.normalize(p));
    };

    for (const root of extraRoots) {
        if (root) add(root);
    }

    for (const drive of driveRoots()) {
        for (const folder of GAME_FOLDERS) {
            const base = folder ? path.join(drive, folder) : drive;
            if (!isDir(base)) continue;

            // Direkter Treffer: <base>/World of Warcraft
            add(path.join(base, "World of Warcraft"));

            // Und alles, was in diesem Ordner nach WoW aussieht — deckt
            // "WoW Classic", "Wow_Anniversary" und ähnliche Eigennamen ab.
            for (const name of listDirs(base)) {
                if (WOW_NAME.test(name) || /world of warcraft/i.test(name)) {
                    add(path.join(base, name));
                }
            }
        }
    }
    return found;
}

/**
 * Alle Addon-SavedVariables unterhalb eines WoW-Verzeichnisses.
 * @param {string} root WoW-Installationsverzeichnis
 * @returns {{ path: string, flavor: string, account: string, mtime: number }[]}
 */
function findInRoot(root) {
    const found = [];
    if (!isDir(root)) return found;

    // Jeder Unterordner mit einem WTF/Account ist eine Spiel-Variante — egal wie
    // er heisst. Dazu <root>/WTF selbst, falls direkt auf einen Varianten-Ordner
    // gezeigt wurde. Bekannte Namen zuerst, damit die Reihenfolge stabil bleibt.
    const flavors = listDirs(root).sort((a, b) => {
        const ia = FLAVORS.indexOf(a);
        const ib = FLAVORS.indexOf(b);
        return (ia === -1 ? 99 : ia) - (ib === -1 ? 99 : ib) || a.localeCompare(b);
    });
    const candidates = [
        ...flavors.map((flavor) => ({ flavor, wtf: path.join(root, flavor, "WTF") })),
        { flavor: path.basename(root), wtf: path.join(root, "WTF") },
    ];

    for (const { flavor, wtf } of candidates) {
        const accounts = path.join(wtf, "Account");
        if (!isDir(accounts)) continue;
        for (const account of listDirs(accounts)) {
            const file = path.join(accounts, account, "SavedVariables", SAVED_VARIABLES_FILE);
            try {
                const stat = fs.statSync(file);
                found.push({ path: file, flavor, account, mtime: stat.mtimeMs });
            } catch {
                // Addon in diesem Account nie geladen — kein Fehler.
            }
        }
    }
    return found;
}

/**
 * Alle gefundenen Dateien, zuletzt geschriebene zuerst.
 * @param {string[]} extraRoots zusätzliche Suchorte aus der Konfiguration
 */
function discover(extraRoots = []) {
    const found = [];
    const seen = new Set();
    for (const root of candidateRoots(extraRoots)) {
        for (const entry of findInRoot(root)) {
            const key = entry.path.toLowerCase();
            if (seen.has(key)) continue;
            seen.add(key);
            found.push(entry);
        }
    }
    return found.sort((a, b) => b.mtime - a.mtime);
}

/** Wo gesucht wurde — für die Meldung, wenn nichts gefunden wurde. */
function searchedRoots(extraRoots = []) {
    return candidateRoots(extraRoots).filter(isDir);
}

/**
 * Einen von Hand angegebenen Pfad zur Datei auflösen. Angenommen wird alles,
 * was der Nutzer vernünftigerweise eintippen könnte:
 *
 *   …/SavedVariables/EventHelperSync.lua   die Datei selbst
 *   …/SavedVariables                       ihr Ordner
 *   …/WTF/Account/PULSE                    der Account-Ordner
 *   …/_classic_era_                        der Varianten-Ordner
 *   D:/Games/World of Warcraft             die Installation
 *
 * Auf jemanden, der den exakten Dateipfad kennen muss, kann man das nicht
 * abwälzen — dann hätte die automatische Suche auch gleich funktionieren können.
 *
 * @returns {{ path: string }|{ error: string }}
 */
function resolveUserPath(input) {
    const raw = String(input || "").trim().replace(/^"|"$/g, "");
    if (!raw) return { error: "Kein Pfad angegeben." };

    let stat;
    try {
        stat = fs.statSync(raw);
    } catch {
        return { error: `Der Pfad existiert nicht: ${raw}` };
    }

    if (stat.isFile()) {
        if (path.basename(raw).toLowerCase() !== SAVED_VARIABLES_FILE.toLowerCase()) {
            return { error: `Das ist nicht ${SAVED_VARIABLES_FILE}, sondern ${path.basename(raw)}.` };
        }
        return { path: path.normalize(raw) };
    }

    // Ordner: erst direkt darin nachsehen, dann als WoW-Installation deuten,
    // dann begrenzt tiefer suchen.
    const direct = path.join(raw, SAVED_VARIABLES_FILE);
    if (fs.existsSync(direct)) return { path: path.normalize(direct) };

    const inRoot = findInRoot(raw);
    if (inRoot.length) {
        inRoot.sort((a, b) => b.mtime - a.mtime);
        return { path: inRoot[0].path };
    }

    const deep = findBelow(raw, 6);
    if (deep.length) {
        deep.sort((a, b) => b.mtime - a.mtime);
        return { path: deep[0].path };
    }

    return {
        error: `Unter ${raw} wurde keine ${SAVED_VARIABLES_FILE} gefunden. `
            + "Ist das Addon installiert und war im Spiel schon einmal geladen?",
    };
}

/**
 * Begrenzt tief nach der Datei suchen. Die Tiefe reicht von der Installation
 * bis zur Datei (<WoW>/_classic_era_/WTF/Account/<ACC>/SavedVariables/…), ohne
 * dass ein versehentlich angegebenes Laufwerk die Platte durchpflügt.
 */
function findBelow(dir, depth, out = []) {
    if (depth <= 0 || out.length > 20) return out;
    const file = path.join(dir, SAVED_VARIABLES_FILE);
    try {
        const stat = fs.statSync(file);
        out.push({ path: file, flavor: "", account: path.basename(path.dirname(path.dirname(dir))), mtime: stat.mtimeMs });
    } catch {
        // hier nicht — weiter unten schauen
    }
    for (const name of listDirs(dir)) {
        // Cache und Logs enthalten nie SavedVariables und sind gross.
        if (/^(Cache|Logs|Data|Interface|Errors|Screenshots|Utils)$/i.test(name)) continue;
        findBelow(path.join(dir, name), depth - 1, out);
    }
    return out;
}

module.exports = {
    discover, findInRoot, searchedRoots, candidateRoots, resolveUserPath, findBelow,
    SAVED_VARIABLES_FILE, FLAVORS, GAME_FOLDERS,
};
