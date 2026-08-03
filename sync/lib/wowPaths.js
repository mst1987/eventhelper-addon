"use strict";

/**
 * Die SavedVariables-Datei des Addons auf der Platte finden.
 *
 * WoW legt sie pro Spiel-Variante und pro Battle.net-Account ab:
 *
 *   <WoW>/_classic_era_/WTF/Account/<ACCOUNT>/SavedVariables/EventHelperSync.lua
 *
 * Gesucht wird über alle Varianten und alle Accounts, weil kaum jemand aus dem
 * Kopf weiss, welcher Account-Ordner der eigene ist — und weil ein Anniversary-
 * Client mal unter _classic_era_ und mal unter _classic_ liegt.
 */
const fs = require("fs");
const path = require("path");

const SAVED_VARIABLES_FILE = "EventHelperSync.lua";

// Die Unterordner, in denen ein Client stecken kann.
const FLAVORS = ["_classic_era_", "_classic_", "_retail_", "_ptr_", "_beta_"];

// Wo ein Standard-Installer landet. Nur Startpunkte — wer woanders installiert
// hat, gibt den Pfad in der Konfiguration direkt an.
const COMMON_ROOTS = [
    "C:/Program Files (x86)/World of Warcraft",
    "C:/Program Files/World of Warcraft",
    "D:/World of Warcraft",
    "D:/Games/World of Warcraft",
    "E:/World of Warcraft",
    "/Applications/World of Warcraft",
];

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

/**
 * Alle Addon-SavedVariables unterhalb eines WoW-Verzeichnisses.
 * @param {string} root WoW-Installationsverzeichnis
 * @returns {{ path: string, flavor: string, account: string, mtime: number }[]}
 */
function findInRoot(root) {
    const found = [];
    if (!isDir(root)) return found;

    // Sowohl <root>/_classic_era_/WTF als auch <root>/WTF (falls direkt auf
    // einen Varianten-Ordner gezeigt wurde) berücksichtigen.
    const candidates = [
        ...FLAVORS.map((flavor) => ({ flavor, wtf: path.join(root, flavor, "WTF") })),
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
    const roots = [...extraRoots, ...COMMON_ROOTS];
    const found = [];
    const seen = new Set();
    for (const root of roots) {
        for (const entry of findInRoot(root)) {
            const key = entry.path.toLowerCase();
            if (seen.has(key)) continue;
            seen.add(key);
            found.push(entry);
        }
    }
    return found.sort((a, b) => b.mtime - a.mtime);
}

module.exports = { discover, findInRoot, SAVED_VARIABLES_FILE, FLAVORS, COMMON_ROOTS };
