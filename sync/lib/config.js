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
    // Raid-Abende, die hier nicht hochgeladen werden sollen (sessionId).
    //
    // Absichtlich eine zweite Stelle neben der Abwahl im Addon: dort entscheidet
    // man beim Spielen, hier vor dem Absenden — und hier sieht man, was die
    // Uploads bisher bewirkt haben. Was das Addon schon weggelassen hat, kommt
    // ohnehin nicht an; diese Liste ist die letzte Instanz davor.
    excludedSessions: [],
    // Was der Server zuletzt zu einem Abend gesagt hat:
    // { [sessionId]: { at, status, added, skipped } }. Nur zur Anzeige — der
    // Server dedupliziert selbst, das hier ersetzt keine Prüfung.
    uploadLog: {},
    // Loot-Council im Spiel (lib/council.js): Kategorien und Filter kommen seit
    // Version 2 von der Webseite. Diese beiden gelten nur noch für ältere
    // Server, die nur Version 1 kennen (Raid-Kategorie und Rolle, "" = alle
    // bzw. Caster und Heiler); in der Oberfläche gibt es sie nicht mehr.
    councilCategory: "",
    councilRole: "",
    // The scannedAt of the last guild bank scan the server accepted, per guild
    // bank: { ["<project>|<realm>|<guild>"]: scannedAt }. A scan is uploaded
    // once, not on every file change.
    guildBankUploads: {},
    // Guild bank handouts ticked in game and already reported to the server:
    // { [handoutId]: reportedAt (ms) }. Keeps them from being sent again while
    // the SavedVariables still list them; pruned after 30 days
    // (lib/guildbankHandouts.js).
    guildBankDoneReported: {},
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
