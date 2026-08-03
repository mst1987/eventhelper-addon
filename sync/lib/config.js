"use strict";

/**
 * Konfiguration des Sync-Tools.
 *
 * Liegt standardmässig im Home-Verzeichnis und nicht neben dem Programm: sie
 * enthält das API-Token, und das soll nicht versehentlich in einem Ordner
 * landen, der irgendwann kopiert oder geteilt wird.
 */
const fs = require("fs");
const os = require("os");
const path = require("path");

const CONFIG_FILE = process.env.EVENTHELPER_SYNC_CONFIG
    || path.join(os.homedir(), ".eventhelper-sync.json");

const DEFAULTS = {
    // Basis-URL des EventHelper-Webservers, ohne /api.
    baseUrl: "",
    // API-Token aus Einstellungen -> Loot-Sync. Wird dort genau einmal angezeigt.
    token: "",
    // Volle Pfad zur SavedVariables-Datei des Addons. Leer = automatisch suchen.
    savedVariablesPath: "",
    // Zusätzliche Orte, an denen nach WoW gesucht wird.
    extraRoots: [],
    // Wie oft im Watch-Modus geprüft wird, ob die Datei sich geändert hat.
    // Der Client schreibt sie nur beim Ausloggen oder /reload — häufiger als
    // alle paar Sekunden nachzusehen bringt daher nichts.
    pollSeconds: 15,
};

function load() {
    try {
        const raw = JSON.parse(fs.readFileSync(CONFIG_FILE, "utf8"));
        return { ...DEFAULTS, ...raw };
    } catch {
        return { ...DEFAULTS };
    }
}

function save(config) {
    const merged = { ...DEFAULTS, ...config };
    fs.writeFileSync(CONFIG_FILE, JSON.stringify(merged, null, 2), { mode: 0o600 });
    return merged;
}

function exists() {
    return fs.existsSync(CONFIG_FILE);
}

/**
 * Was einer brauchbaren Konfiguration noch fehlt.
 * @returns {string[]} leere Liste = alles da
 */
function missing(config) {
    const problems = [];
    if (!config.baseUrl) problems.push("baseUrl (z.B. https://pulse-gdkp.de:3005)");
    if (!config.token) problems.push("token (Einstellungen -> Loot-Sync -> Token erstellen)");
    return problems;
}

module.exports = { load, save, exists, missing, CONFIG_FILE, DEFAULTS };
