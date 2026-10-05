"use strict";

/**
 * Die Gegenrichtung: Loot-Council-Daten vom Server ins Spiel.
 *
 * Bis hierher floss nur Loot vom Spiel zum Server. Die Council-Seite des
 * EventHelper rechnet daraus pro Raider einen Bedarf (wie lange kein Loot, wie
 * viel Anteil, wie viel BiS fehlt) — und genau das will der Raidleiter beim
 * Verteilen im Spiel sehen, nicht in einem Browser daneben.
 *
 * Ein Addon kann nichts aus dem Netz holen und keine Dateien lesen ausser den
 * eigenen. Was es aber tut: beim Laden jede .lua-Datei ausführen, die in seiner
 * .toc steht. Das Sync-Tool schreibt die Daten deshalb als Lua-Datei
 * (`CouncilData.lua`) direkt in den Addon-Ordner — nach dem nächsten /reload
 * sind sie im Spiel da. Die Datei liegt im Repo als leerer Platzhalter und wird
 * hier überschrieben.
 *
 * Das Format `eventhelper-council` Version 1 ist mit dem Server (Repo
 * d:/programming/eventhelper, Route GET /api/ingest/council) abgestimmt. Ändert
 * es sich, muss die Version auf beiden Seiten mitwachsen; eine höhere Version
 * lehnt dieses Tool ab, statt sie halb zu schreiben.
 */
const fs = require("fs");
const path = require("path");
const wowPaths = require("./wowPaths");
const { getJson, UploadError, SYNC_VERSION } = require("./uploader");

const COUNCIL_FORMAT = "eventhelper-council";
const COUNCIL_VERSION = 1;
const COUNCIL_FILE = "CouncilData.lua";
// Die globale Variable, die das Addon liest (Council.lua).
const COUNCIL_GLOBAL = "EventHelperSync_Council";

class CouncilError extends Error {
    constructor(message) {
        super(message);
        this.name = "CouncilError";
    }
}

// ---------------------------------------------------------------------------
// Latin-1
// ---------------------------------------------------------------------------

// Die Spielschrift kennt nur Latin-1: alles darüber erscheint im Spiel als
// Kästchen. Typografische Zeichen, die in Namen und Notizen gern vorkommen,
// bekommen eine lesbare ASCII-Entsprechung, der Rest wird zu "?".
const ASCII_REPLACEMENTS = {
    "\u2010": "-", "\u2011": "-", "\u2012": "-", "\u2013": "-", "\u2014": "-", "\u2015": "-", "\u2212": "-",
    "\u2026": "...",
    "\u201C": '"', "\u201D": '"', "\u201E": '"', "\u201F": '"', "\u2033": '"',
    "\u2018": "'", "\u2019": "'", "\u201A": "'", "\u201B": "'", "\u2032": "'",
    "\u2039": "<", "\u203A": ">",
    "\u2192": "->", "\u21D2": "=>", "\u2190": "<-", "\u21D0": "<=", "\u2194": "<->",
    "\u2264": "<=", "\u2265": ">=", "\u2260": "!=",
    "\u2022": "*", "\u2023": "*", "\u2043": "-",
    "\u2122": "TM", "\u20AC": "EUR",
    "\u2713": "v", "\u2714": "v", "\u2715": "x", "\u2716": "x", "\u2717": "x",
    "\u2002": " ", "\u2003": " ", "\u2007": " ", "\u2008": " ", "\u2009": " ", "\u200A": " ", "\u202F": " ",
    "\u200B": "", "\u200C": "", "\u200D": "", "\u2060": "", "\uFEFF": "",
};

/**
 * Einen String so umschreiben, dass ihn die Spielschrift darstellen kann.
 * Latin-1-Zeichen wie ä, ö, ü, ß, é bleiben erhalten (die Datei wird als UTF-8
 * geschrieben, und so liest WoW sie auch).
 */
function toLatin1(value) {
    const text = String(value).normalize("NFC");
    let out = "";
    // for…of läuft über Codepoints, ein Emoji wird so zu genau einem "?".
    for (const ch of text) {
        const replacement = ASCII_REPLACEMENTS[ch];
        if (replacement !== undefined) {
            out += replacement;
            continue;
        }
        const code = ch.codePointAt(0);
        // 0x80–0x9F sind Steuerzeichen (C1), nichts Darstellbares.
        if (code > 0xff || (code >= 0x80 && code <= 0x9f)) out += "?";
        else out += ch;
    }
    return out;
}

// ---------------------------------------------------------------------------
// Lua-Serialisierung
// ---------------------------------------------------------------------------

const LUA_KEYWORDS = new Set([
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in",
    "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
]);

const isIdentifier = (key) => /^[A-Za-z_][A-Za-z0-9_]*$/.test(key) && !LUA_KEYWORDS.has(key);

/** Ein Lua-String-Literal in doppelten Anführungszeichen. */
function luaString(value) {
    let out = '"';
    for (const ch of toLatin1(value)) {
        const code = ch.codePointAt(0);
        if (ch === "\\") out += "\\\\";
        else if (ch === '"') out += '\\"';
        else if (ch === "\n") out += "\\n";
        else if (ch === "\r") out += "\\r";
        else if (ch === "\t") out += "\\t";
        // Übrige Steuerzeichen dezimal und immer dreistellig: Lua liest bis zu
        // drei Ziffern, ein "\1" vor einer "2" würde sonst zu "\12".
        else if (code < 0x20 || code === 0x7f) out += `\\${String(code).padStart(3, "0")}`;
        else out += ch;
    }
    return `${out}"`;
}

function luaNumber(value) {
    // Lua 5.1 kennt kein Literal für inf/nan; im Format kommen sie nicht vor.
    if (!Number.isFinite(value)) return "0";
    return String(value);
}

const isPrimitive = (v) => v === null || v === undefined || typeof v !== "object";

/**
 * Einen JSON-Wert als Lua-Ausdruck. Arrays werden Lua-Sequenzen (1-basiert,
 * ohne Schlüssel), Objekte Tabellen mit `name = …` bzw. `["schlüssel"] = …`.
 * Arrays aus lauter einfachen Werten (z.B. Item-IDs) stehen in einer Zeile,
 * alles andere eingerückt — die Datei soll sich zur Not lesen lassen.
 */
function toLua(value, indent = "") {
    if (value === null || value === undefined) return "nil";
    if (typeof value === "boolean") return value ? "true" : "false";
    if (typeof value === "number") return luaNumber(value);
    if (typeof value === "string") return luaString(value);
    if (typeof value !== "object") return "nil";

    const inner = `${indent}  `;
    if (Array.isArray(value)) {
        if (!value.length) return "{}";
        if (value.every(isPrimitive)) return `{ ${value.map((v) => toLua(v)).join(", ")} }`;
        return `{\n${value.map((v) => `${inner}${toLua(v, inner)},`).join("\n")}\n${indent}}`;
    }

    const entries = Object.entries(value).filter(([, v]) => v !== undefined && v !== null);
    if (!entries.length) return "{}";
    const lines = entries.map(([key, v]) => {
        const k = isIdentifier(key) ? key : `[${luaString(key)}]`;
        return `${inner}${k} = ${toLua(v, inner)},`;
    });
    return `{\n${lines.join("\n")}\n${indent}}`;
}

/** Der komplette Inhalt von CouncilData.lua. */
function buildCouncilFile(payload, { syncVersion = SYNC_VERSION, now = new Date() } = {}) {
    return `-- Generated by EventHelper Sync ${syncVersion} at ${now.toISOString()}. Do not edit; it is overwritten.\n`
        + `${COUNCIL_GLOBAL} = ${toLua(payload)}\n`;
}

// ---------------------------------------------------------------------------
// Holen und prüfen
// ---------------------------------------------------------------------------

/**
 * Prüfen, ob der Server das liefert, was das Addon versteht.
 * @returns {object} der Payload selbst
 */
function validateCouncil(payload) {
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
        throw new CouncilError("Der Server hat keine Council-Daten geliefert.");
    }
    if (payload.format !== COUNCIL_FORMAT) {
        throw new CouncilError(`Unerwartetes Format "${payload.format}" statt "${COUNCIL_FORMAT}".`);
    }
    const version = payload.version;
    if (typeof version !== "number" || !Number.isInteger(version) || version < 1) {
        throw new CouncilError(`Ungültige Version der Council-Daten: ${JSON.stringify(version)}.`);
    }
    if (version > COUNCIL_VERSION) {
        throw new CouncilError(
            `Die Council-Daten haben Version ${version}, dieses Sync-Tool kennt nur Version ${COUNCIL_VERSION}. `
            + "Bitte EventHelper Sync aktualisieren.",
        );
    }
    if (!Array.isArray(payload.raiders)) {
        throw new CouncilError("Die Council-Daten enthalten keine Raider-Liste.");
    }
    return payload;
}

/** Den Payload vom Server holen (noch ungeprüft). */
async function fetchCouncil(config, { category = "", role = "" } = {}) {
    const params = new URLSearchParams();
    if (category) params.set("category", String(category));
    if (role) params.set("role", String(role));
    const query = params.toString();
    try {
        return await getJson(config, `/api/ingest/council${query ? `?${query}` : ""}`);
    } catch (e) {
        // Ein EventHelper ohne diese Route antwortet 404 — das ist kein
        // Verbindungsproblem, sondern ein zu alter Server.
        if (e instanceof UploadError && e.status === 404) {
            throw new CouncilError("Der Server kennt noch keine Council-Daten (HTTP 404) — ist der EventHelper aktuell?");
        }
        throw e;
    }
}

/** Erst in eine Nachbardatei schreiben, dann umbenennen: WoW (oder ein
 * Virenscanner) sieht nie eine halb geschriebene Datei. */
function writeAtomic(file, text) {
    const tmp = `${file}.${process.pid}.${Date.now()}.tmp`;
    try {
        fs.writeFileSync(tmp, text, "utf8");
        fs.renameSync(tmp, file);
    } catch (e) {
        try {
            fs.rmSync(tmp, { force: true });
        } catch {
            // Aufräumen ist nur Kür
        }
        throw e;
    }
}

/**
 * Holen, prüfen und in jeden installierten Addon-Ordner schreiben.
 * @param {object} config  wie aus lib/config.js
 * @param {{ now?: Date, roots?: string[] }} [options]  roots nur für Tests
 * @returns {Promise<{ payload: object, raiders: number, dirs: object[], files: string[], errors: string[] }>}
 */
async function syncCouncil(config, { now = new Date(), roots } = {}) {
    const payload = validateCouncil(await fetchCouncil(config, {
        category: config.councilCategory || "",
        role: config.councilRole || "",
    }));
    const text = buildCouncilFile(payload, { now });
    const dirs = wowPaths.findAddonDirs(config.extraRoots, {
        savedVariablesPath: config.savedVariablesPath || "",
        roots,
    });
    const files = [];
    const errors = [];
    for (const { dir } of dirs) {
        const file = path.join(dir, COUNCIL_FILE);
        try {
            writeAtomic(file, text);
            files.push(file);
        } catch (e) {
            errors.push(`${file}: ${e.message}`);
        }
    }
    return { payload, raiders: payload.raiders.length, dirs, files, errors };
}

module.exports = {
    syncCouncil, fetchCouncil, validateCouncil, buildCouncilFile, toLua, luaString, toLatin1, writeAtomic,
    CouncilError, COUNCIL_FORMAT, COUNCIL_VERSION, COUNCIL_FILE, COUNCIL_GLOBAL,
};
