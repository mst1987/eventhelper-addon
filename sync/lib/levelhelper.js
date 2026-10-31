"use strict";

/**
 * LevelHelper-Bestzeiten: Dungeon-Läufe und Erfolgs-Zusammenfassungen aus den
 * SavedVariables des LevelHelper-Addons zum EventHelper-Server hochladen
 * (`POST /api/ingest/levelhelper`, Format "levelhelper-runs" v1).
 *
 * Quellen (beide unter `<Variante>/WTF/Account/<Account>/`):
 *
 *   SavedVariables/LevelHelper.lua                      -> LevelHelperDB (Account)
 *     guildBoards[gilde][dungeon] = { top = { Lauf... }, mine = Lauf }
 *     guildRoster[gilde][schluessel] = { name, class, level, points, count, golds, at }
 *     achievementSummary[charKey] = { name, points, count }
 *     history[charKey] = { name, class, realm, current = { level } }
 *   <Realm>/<Charakter>/SavedVariables/LevelHelper.lua  -> LevelHelperCharDB
 *     achievements[id] = time()
 *
 * Ein Lauf steht im Addon in Kurzfeldern (d, s, st, i, m = { g, n, c }, id, at,
 * r); ein dokumentierter Export darf die langen Namen benutzen (dungeon,
 * seconds, start, instance, members = { guid, name, class }, medal). Beides
 * wird gelesen, die Klasse als Index (CLASS_LIST des Addons) oder als
 * Klassendatei ("PALADIN").
 *
 * Eine Anfrage pro (Installation, Account, Gilde); höchstens 500 Läufe und 200
 * Charaktere je Anfrage. Hochgeladen wird nur, was sich seit dem letzten
 * erfolgreichen Upload geändert hat (Hash je Lauf / Charakter in der
 * Konfiguration, `levelHelperUploads`).
 */
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const wowPaths = require("./wowPaths");
const { parseSavedVariables } = require("./luaParser");
const { postJson, UploadError } = require("./uploader");

const SAVED_VARIABLES_FILE = "LevelHelper.lua";
const FORMAT = "levelhelper-runs";
const ENDPOINT = "/api/ingest/levelhelper";
const MAX_RUNS = 500;
const MAX_CHARACTERS = 200;
// Zwei Berichte desselben Laufs (wie DungeonTimer.lua: SAME_RUN_START).
const SAME_RUN_START = 120;

// Welche Variante-Ordner zu welcher Spielversion gehören, steht an einer Stelle
// in wowPaths (gemeinsam mit dem Loot-Upload); was dort fehlt, wird nicht
// hochgeladen (eine falsche versionId wäre schlimmer als keine). _classic_era_
// bleibt draußen: dort laufen auch Season of Discovery und Hardcore, deren
// Läufe nicht als "classic" in die Bestzeiten gehören.
const FLAVOR_VERSIONS = Object.fromEntries(
    Object.entries(wowPaths.FLAVOR_VERSIONS).filter(([flavor]) => flavor !== "_classic_era_"));

// CLASS_LIST aus DungeonTimer.lua: der Klassen-Index im Addon.
const CLASS_LIST = ["WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "DEATHKNIGHT", "SHAMAN", "MAGE", "WARLOCK",
    "MONK", "DRUID", "DEMONHUNTER", "EVOKER"];

// Lokalisierte Klassennamen (die History des Addons speichert UnitClass'
// ersten Rückgabewert), englisch und deutsch.
const CLASS_NAMES = {
    WARRIOR: ["warrior", "krieger", "kriegerin"],
    PALADIN: ["paladin"],
    HUNTER: ["hunter", "jäger", "jägerin"],
    ROGUE: ["rogue", "schurke", "schurkin"],
    PRIEST: ["priest", "priester", "priesterin"],
    DEATHKNIGHT: ["death knight", "deathknight", "todesritter", "todesritterin"],
    SHAMAN: ["shaman", "schamane", "schamanin"],
    MAGE: ["mage", "magier", "magierin"],
    WARLOCK: ["warlock", "hexenmeister", "hexenmeisterin"],
    MONK: ["monk", "mönch", "mönchin"],
    DRUID: ["druid", "druide", "druidin"],
    DEMONHUNTER: ["demon hunter", "demonhunter", "dämonenjäger", "dämonenjägerin"],
    EVOKER: ["evoker", "rufer", "ruferin"],
};
const CLASS_BY_NAME = {};
for (const [file, names] of Object.entries(CLASS_NAMES)) {
    for (const n of names) CLASS_BY_NAME[n] = file;
}

const MEDALS = new Set(["gold", "silver", "bronze"]);

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

/** A Lua list as an array, even if WoW wrote it with explicit [n] keys. */
function asList(value) {
    if (Array.isArray(value)) return value.filter((v) => v !== null && v !== undefined);
    if (!value || typeof value !== "object") return [];
    return Object.keys(value).filter((k) => /^\d+$/.test(k)).sort((a, b) => a - b).map((k) => value[k]);
}

function isTable(value) {
    return !!value && typeof value === "object";
}

/** Number of entries of a Lua table (list or map). */
function countEntries(value) {
    if (Array.isArray(value)) return value.filter((v) => v !== null && v !== undefined).length;
    return isTable(value) ? Object.keys(value).length : 0;
}

/** [key, value] pairs of a Lua table, list or map. */
function entriesOf(value) {
    if (Array.isArray(value)) return value.map((v, i) => [String(i + 1), v]);
    return isTable(value) ? Object.entries(value) : [];
}

function num(value) {
    const n = typeof value === "string" && value.trim() !== "" ? Number(value) : value;
    return typeof n === "number" && Number.isFinite(n) ? n : null;
}

function str(value) {
    return typeof value === "string" && value.trim() !== "" ? value.trim() : null;
}

function isDir(p) {
    try {
        return fs.statSync(p).isDirectory();
    } catch {
        return false;
    }
}

function listDirs(p) {
    try {
        return (fs.readdirSync(p, { withFileTypes: true }) || []).filter((e) => e.isDirectory()).map((e) => e.name);
    } catch {
        return [];
    }
}

function mtimeOf(file) {
    try {
        return fs.statSync(file).mtimeMs || 0;
    } catch {
        return 0;
    }
}

/** "Player-4720-0001ABCD" or "4720-0001ABCD" -> "4720-0001ABCD"; anything else null. */
function shortGuid(value) {
    const s = str(value);
    if (!s) return null;
    const short = s.replace(/^Player-/, "");
    return short.length <= 32 && /^[\w-]+$/.test(short) ? short : null;
}

function looksLikeGuid(value) {
    return /^\d+-[0-9A-Fa-f]+$/.test(String(value || ""));
}

/** A class index, a class file name or a localized class name -> "PALADIN", else null. */
function normalizeClass(value) {
    if (typeof value === "number" || (typeof value === "string" && /^\d+$/.test(value.trim()))) {
        return CLASS_LIST[Number(value) - 1] || null;
    }
    const s = str(value);
    if (!s) return null;
    const upper = s.toUpperCase().replace(/[\s_]+/g, "");
    if (CLASS_LIST.includes(upper)) return upper;
    return CLASS_BY_NAME[s.toLowerCase().replace(/[\s_]+/g, " ")] || CLASS_BY_NAME[s.toLowerCase()] || null;
}

function hashOf(value) {
    return crypto.createHash("sha1").update(JSON.stringify(value)).digest("hex").slice(0, 12);
}

// ---------------------------------------------------------------------------
// Finding the files
// ---------------------------------------------------------------------------

/**
 * Alle Installationen mit LevelHelper-SavedVariables: je Variante-Ordner die
 * Accounts, in denen `LevelHelper.lua` liegt, und darunter die Dateien der
 * einzelnen Charaktere. Varianten ohne bekannte Spielversion werden in
 * `skipped` gemeldet statt hochgeladen.
 *
 * @param {string[]} extraRoots
 * @param {{ savedVariablesPath?: string, roots?: string[] }} [options]
 *   savedVariablesPath: die von Hand gewählte EventHelperSync.lua - deren
 *   Variante gehört dazu; roots: statt der automatischen Suche (für Tests)
 * @returns {{ installs: object[], skipped: string[] }}
 */
function findInstalls(extraRoots = [], { savedVariablesPath = "", roots } = {}) {
    const installs = [];
    const skipped = [];
    const seen = new Set();

    const addFlavor = (flavor, flavorDir) => {
        const accountsDir = path.join(flavorDir, "WTF", "Account");
        if (!isDir(accountsDir)) return;
        let real = flavorDir;
        try {
            real = fs.realpathSync(flavorDir);
        } catch {
            // nicht auflösbar - dann der Pfad selbst
        }
        const key = path.normalize(String(real)).toLowerCase();
        if (seen.has(key)) return;

        const accounts = [];
        for (const account of listDirs(accountsDir)) {
            const accountDir = path.join(accountsDir, account);
            const file = path.join(accountDir, "SavedVariables", SAVED_VARIABLES_FILE);
            const characters = [];
            for (const realm of listDirs(accountDir)) {
                if (/^SavedVariables$/i.test(realm)) continue;
                for (const name of listDirs(path.join(accountDir, realm))) {
                    const charFile = path.join(accountDir, realm, name, "SavedVariables", SAVED_VARIABLES_FILE);
                    if (fs.existsSync(charFile)) characters.push({ realm, name, file: charFile });
                }
            }
            const hasAccountFile = fs.existsSync(file);
            if (!hasAccountFile && !characters.length) continue;
            accounts.push({ account, accountDir, file: hasAccountFile ? file : null, characters });
        }
        if (!accounts.length) return;
        seen.add(key);

        const versionId = FLAVOR_VERSIONS[String(flavor).toLowerCase()] || null;
        if (!versionId) {
            skipped.push(flavor);
            return;
        }
        installs.push({ flavor, versionId, dir: flavorDir, accounts });
    };

    if (savedVariablesPath) {
        // <Variante>/WTF/Account/<ACC>/SavedVariables/EventHelperSync.lua
        const flavorDir = path.resolve(path.dirname(savedVariablesPath), "..", "..", "..", "..");
        addFlavor(path.basename(flavorDir), flavorDir);
    }
    for (const root of roots || wowPaths.candidateRoots(extraRoots) || []) {
        if (!isDir(root)) continue;
        for (const flavor of listDirs(root)) addFlavor(flavor, path.join(root, flavor));
        addFlavor(path.basename(root), root);
    }
    return { installs, skipped };
}

/** Changes whenever any LevelHelper file of the installs is written. */
function signature(installs) {
    const parts = [];
    for (const inst of installs) {
        for (const acct of inst.accounts) {
            if (acct.file) parts.push(`${acct.file}:${mtimeOf(acct.file)}`);
            for (const c of acct.characters) parts.push(`${c.file}:${mtimeOf(c.file)}`);
        }
    }
    return parts.join("|");
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

function readGlobal(file, name) {
    const text = fs.readFileSync(file, "utf8");
    const value = parseSavedVariables(text)[name];
    return isTable(value) ? value : null;
}

/** LevelHelperDB of an account file, or null (missing, unreadable). */
function readAccountDB(file) {
    if (!file) return null;
    try {
        return readGlobal(file, "LevelHelperDB");
    } catch {
        return null;
    }
}

/** LevelHelperCharDB of a character file, or null. */
function readCharDB(file) {
    try {
        return readGlobal(file, "LevelHelperCharDB");
    } catch {
        return null;
    }
}

function normalizeMember(raw) {
    if (!isTable(raw)) return null;
    const guid = shortGuid(raw.guid !== undefined ? raw.guid : raw.g);
    const name = str(raw.name !== undefined ? raw.name : raw.n);
    if (!guid && !name) return null;
    return { guid, name, class: normalizeClass(raw.class !== undefined ? raw.class : raw.c) };
}

function memberKey(m) {
    return m.guid || `n:${String(m.name || "?").toLowerCase()}`;
}

/** One stored run (short or long field names) -> the upload shape, or null. */
function normalizeRun(raw, dungeonFallback) {
    if (!isTable(raw)) return null;
    const dungeon = str(raw.dungeon !== undefined ? raw.dungeon : raw.d) || str(dungeonFallback);
    const seconds = num(raw.seconds !== undefined ? raw.seconds : raw.s);
    const start = num(raw.start !== undefined ? raw.start : raw.st);
    if (!dungeon || seconds === null || seconds <= 0 || start === null || start <= 0) return null;
    const instance = num(raw.instance !== undefined ? raw.instance : raw.i);
    const members = asList(raw.members !== undefined ? raw.members : raw.m).map(normalizeMember).filter(Boolean);
    const medal = typeof raw.medal === "string" && MEDALS.has(raw.medal) ? raw.medal : null;
    const run = {
        id: str(raw.id),
        dungeon,
        seconds: Math.round(seconds),
        start: Math.round(start),
        instance: instance === null ? null : instance,
        medal,
        members,
        at: Math.round(num(raw.at) || start + seconds),
    };
    if (!run.id) {
        // Wie runId() im Addon: Dungeon, Mitglieder, Start auf die Minute, Instanz.
        const keys = members.map(memberKey).sort();
        run.id = [dungeon, keys.join(","), Math.floor(start / 60), instance || 0].join("|");
    }
    return run;
}

function sameRun(a, b) {
    if (a.id === b.id) return true;
    if (a.dungeon !== b.dungeon || Math.abs(a.start - b.start) > SAME_RUN_START) return false;
    if (a.members.length !== b.members.length) return false;
    const keys = new Set(a.members.map(memberKey));
    return b.members.every((m) => keys.has(memberKey(m)));
}

/**
 * The same run reported on several boards (or as "mine" and in "top") only once:
 * by id, else by dungeon + members + start within SAME_RUN_START. The fastest
 * time and the union of the members win, like the addon's own merge.
 */
function dedupeRuns(runs) {
    const out = [];
    for (const run of runs) {
        const known = out.find((other) => sameRun(other, run));
        if (!known) {
            out.push({ ...run, members: run.members.map((m) => ({ ...m })) });
            continue;
        }
        if (run.seconds < known.seconds) known.seconds = run.seconds;
        known.start = Math.min(known.start, run.start);
        known.at = known.start + known.seconds;
        if (!known.medal) known.medal = run.medal;
        if (known.instance === null) known.instance = run.instance;
        const have = new Set(known.members.map(memberKey));
        for (const m of run.members) {
            if (!have.has(memberKey(m))) known.members.push({ ...m });
        }
    }
    return out;
}

// What the server takes (EventHelper utils/dungeons/levelHelperUpload.js). One
// field it refuses fails the whole upload, so runs and characters are trimmed
// or left out here first.
const LIMITS = {
    minSeconds: 60, maxSeconds: 14400, maxMembers: 5,
    id: 64, dungeon: 80, name: 48, realm: 60, guild: 60, guid: 64, classLen: 20,
    level: 100, points: 1000000, count: 100000, timeMin: 1000000000, timeMax: 4000000000, instanceMax: 2147483647,
};
const clip = (value, max) => {
    const s = (value === null || value === undefined ? "" : String(value)).replace(/\s+/g, " ").trim();
    return s.length > max ? s.slice(0, max) : s;
};
const classToken = (value) => {
    const s = clip(value, LIMITS.classLen).toUpperCase();
    return /^[A-Z_]+$/.test(s) ? s : null;
};
const inTime = (t) => Number.isInteger(t) && t >= LIMITS.timeMin && t <= LIMITS.timeMax;
const wholeIn = (v, max) => (Number.isFinite(v) ? Math.min(max, Math.max(0, Math.round(v))) : null);

/** An id the server takes (at most 64 characters); longer ones become a stable hash. */
function uploadId(id) {
    const s = String(id);
    return s.length <= LIMITS.id ? s : `h:${crypto.createHash("sha1").update(s).digest("hex")}`;
}

/**
 * A run in the server's limits, or null when it cannot be (time out of range,
 * no member with a name): members without a name are dropped, at most 5 kept.
 */
function sanitizeRun(run) {
    if (!run) return null;
    const seconds = Math.round(run.seconds);
    if (!(seconds >= LIMITS.minSeconds && seconds <= LIMITS.maxSeconds)) return null;
    if (!inTime(run.start)) return null;
    const dungeon = clip(run.dungeon, LIMITS.dungeon);
    if (!dungeon) return null;
    const members = [];
    for (const m of run.members || []) {
        const name = clip(m && m.name, LIMITS.name);
        if (!name) continue;
        members.push({ guid: m.guid ? clip(m.guid, LIMITS.guid) : null, name, class: m.class ? classToken(m.class) : null });
        if (members.length === LIMITS.maxMembers) break;
    }
    if (!members.length) return null;
    const instance = Number.isInteger(run.instance) && run.instance >= 0 && run.instance <= LIMITS.instanceMax ? run.instance : null;
    return {
        ...run,
        id: uploadId(run.id),
        dungeon,
        seconds,
        instance,
        medal: MEDALS.has(run.medal) ? run.medal : null,
        members,
        at: inTime(run.at) ? run.at : run.start + seconds,
    };
}

/** All runs of a LevelHelperDB, per guild. */
function collectRuns(db) {
    const guilds = {};
    for (const [guild, boards] of entriesOf(db && db.guildBoards)) {
        const raw = [];
        for (const [dungeon, board] of entriesOf(boards)) {
            if (!isTable(board)) continue;
            for (const entry of asList(board.top)) raw.push(normalizeRun(entry, dungeon));
            if (isTable(board.mine)) raw.push(normalizeRun(board.mine, dungeon));
        }
        const runs = dedupeRuns(raw.filter(Boolean)).map(sanitizeRun).filter(Boolean);
        if (runs.length) guilds[guild] = runs;
    }
    return guilds;
}

/**
 * The roster of one guild (LevelHelperDB.guildRoster[guild]) as characters.
 * The key is the character's GUID or "Name-Realm"; name, class, level, points,
 * count, golds and at come from the entry.
 */
function collectRoster(db) {
    const guilds = {};
    for (const [guild, roster] of entriesOf(db && db.guildRoster)) {
        const list = [];
        for (const [key, entry] of entriesOf(roster)) {
            if (!isTable(entry)) continue;
            const guid = looksLikeGuid(String(key).replace(/^Player-/, "")) ? shortGuid(key) : shortGuid(entry.guid);
            let name = str(entry.name);
            let realm = str(entry.realm);
            if (!guid && String(key).includes("-")) {
                const [n, ...r] = String(key).split("-");
                name = name || str(n);
                realm = realm || str(r.join("-"));
            }
            name = name || (!guid ? str(key) : null);
            if (!name) continue;
            list.push({
                guid, name, realm,
                class: normalizeClass(entry.class),
                level: num(entry.level),
                points: num(entry.points),
                count: num(entry.count),
                golds: num(entry.golds),
                at: num(entry.at),
            });
        }
        if (list.length) guilds[guild] = list;
    }
    return guilds;
}

function sameName(a, b) {
    return !!a && !!b && String(a).toLowerCase() === String(b).toLowerCase();
}

/**
 * This account's own characters: name and realm from the folder, count from
 * the character's achievements, points / level / class from the account file
 * (achievementSummary, history) where the addon stored them.
 */
function collectOwn(db, characters) {
    const summaries = entriesOf(db && db.achievementSummary).filter(([, v]) => isTable(v));
    const histories = entriesOf(db && db.history).filter(([, v]) => isTable(v));
    const own = [];
    for (const c of characters) {
        const charDB = readCharDB(c.file);
        if (!charDB) continue;
        const summary = summaries.find(([, v]) => sameName(v.name, c.name));
        const history = histories.find(([, v]) => sameName(v.name, c.name)
            && (!str(v.realm) || sameName(v.realm, c.realm)));
        const keyHint = (summary && summary[0]) || (history && history[0]) || "";
        const guid = looksLikeGuid(String(keyHint).replace(/^Player-/, "")) ? shortGuid(keyHint) : null;
        const hist = history ? history[1] : null;
        let level = hist && hist.current ? num(hist.current.level) : null;
        if (level === null && hist && isTable(hist.levels)) {
            const levels = Object.keys(hist.levels).map(Number).filter(Number.isFinite);
            if (levels.length) level = Math.max(...levels) + 1;
        }
        const own1 = {
            guid,
            name: c.name,
            realm: c.realm || null,
            class: hist ? normalizeClass(hist.class) : null,
            level,
            points: summary ? num(summary[1].points) : null,
            count: isTable(charDB.achievements) ? countEntries(charDB.achievements) : (summary ? num(summary[1].count) : null),
            golds: null,
            at: Math.floor(mtimeOf(c.file) / 1000) || null,
        };
        own.push(own1);
    }
    return own;
}

function sameCharacter(a, b) {
    if (a.guid && b.guid) return a.guid === b.guid;
    if (!sameName(a.name, b.name)) return false;
    return !a.realm || !b.realm || sameName(a.realm, b.realm);
}

/**
 * Everything one account has to say: per guild its runs and characters.
 * Own characters go to the guild whose roster or boards know them; with only
 * one guild in the file, to that one; otherwise they are left out (no way to
 * tell the guild).
 * @returns {{ guilds: { [guild]: { runs: object[], characters: object[] } } }}
 */
function collectAccount(acct) {
    const db = readAccountDB(acct.file);
    const runsByGuild = collectRuns(db);
    const rosterByGuild = collectRoster(db);
    const own = collectOwn(db, acct.characters);

    const names = new Set([...Object.keys(runsByGuild), ...Object.keys(rosterByGuild)]);
    const guilds = {};
    for (const g of names) guilds[g] = { runs: runsByGuild[g] || [], characters: (rosterByGuild[g] || []).map((c) => ({ ...c })) };

    for (const c of own) {
        let target = names.size ? [...names].find((g) => guilds[g].characters.some((r) => sameCharacter(r, c))) : null;
        if (!target) {
            target = [...names].find((g) => guilds[g].runs.some((run) => run.members.some((m) => (
                (m.guid && c.guid) ? m.guid === c.guid : sameName(m.name, c.name)))));
        }
        if (!target && names.size === 1) target = [...names][0];
        if (!target) continue;
        const list = guilds[target].characters;
        const at = list.findIndex((r) => sameCharacter(r, c));
        if (at < 0) {
            list.push({ ...c, own: true });
            continue;
        }
        const r = list[at];
        // Own data is fresher where it exists; the roster keeps what only it knows.
        list[at] = {
            ...r,
            own: true,
            guid: c.guid || r.guid,
            realm: c.realm || r.realm,
            class: c.class || r.class,
            level: c.level !== null ? c.level : r.level,
            points: c.points !== null ? c.points : r.points,
            count: c.count !== null ? c.count : r.count,
            at: Math.max(c.at || 0, r.at || 0) || null,
        };
    }
    for (const g of Object.keys(guilds)) {
        if (!guilds[g].runs.length && !guilds[g].characters.length) delete guilds[g];
    }
    return { guilds };
}

// ---------------------------------------------------------------------------
// Payload, change detection
// ---------------------------------------------------------------------------

function characterKey(c) {
    return c.guid || `${String(c.name).toLowerCase()}|${String(c.realm || "").toLowerCase()}`;
}

/** A character in the server's limits (see LIMITS), or null without a name. */
function toUploadCharacter(c) {
    const name = clip(c.name, LIMITS.name);
    if (!name) return null;
    const at = Math.round(c.at);
    return {
        guid: c.guid ? clip(c.guid, LIMITS.guid) : null,
        name,
        realm: c.realm ? clip(c.realm, LIMITS.realm) || null : null,
        class: c.class ? classToken(c.class) : null,
        level: wholeIn(c.level, LIMITS.level),
        points: wholeIn(c.points, LIMITS.points),
        count: wholeIn(c.count, LIMITS.count),
        golds: wholeIn(c.golds, LIMITS.count),
        at: inTime(at) ? at : Math.floor(Date.now() / 1000),
    };
}

// What counts as "changed": the content without the time stamp of a character
// (an own character's `at` is the file's write time and moves on every logout).
const runHash = (run) => hashOf(run);
const characterHash = (c) => hashOf({ ...c, at: 0 });

/**
 * The runs and characters that differ from what was uploaded last.
 * @param {{ runs?: object, chars?: object }|undefined} known  state of this guild
 */
function pendingChanges(known, runs, characters) {
    const knownRuns = (known && known.runs) || {};
    const knownChars = (known && known.chars) || {};
    return {
        runs: runs.filter((r) => knownRuns[r.id] !== runHash(r)),
        characters: characters.filter((c) => knownChars[characterKey(c)] !== characterHash(c)),
    };
}

/** Split runs / characters into requests of at most MAX_RUNS / MAX_CHARACTERS. */
function buildRequests({ versionId, account, guild, runs, characters }, limits = {}) {
    const maxRuns = limits.maxRuns || MAX_RUNS;
    const maxChars = limits.maxCharacters || MAX_CHARACTERS;
    const sortedRuns = runs.slice().sort((a, b) => a.at - b.at || (a.id < b.id ? -1 : 1));
    const chars = characters.map(toUploadCharacter).filter(Boolean);
    const guildName = clip(guild, LIMITS.guild);
    const count = Math.max(Math.ceil(sortedRuns.length / maxRuns), Math.ceil(chars.length / maxChars));
    const requests = [];
    for (let i = 0; i < count; i += 1) {
        requests.push({
            format: FORMAT,
            v: 1,
            versionId,
            guild: guildName,
            uploader: { account },
            runs: sortedRuns.slice(i * maxRuns, (i + 1) * maxRuns),
            characters: chars.slice(i * maxChars, (i + 1) * maxChars),
        });
    }
    return requests;
}

function postLevelHelper(config, payload) {
    return postJson(config, ENDPOINT, payload);
}

// ---------------------------------------------------------------------------
// The whole pass
// ---------------------------------------------------------------------------

/**
 * Read every account of the installs and upload what changed.
 *
 * Stops at the first failed request (a missing endpoint, no network and a
 * wrong token all hit every following request as well); what went up before
 * is remembered. A run already sent for another account of the same guild and
 * version in this pass is not sent again, but counts as known for this account.
 *
 * @param {object} config  baseUrl / token
 * @param {{ installs: object[], known?: object, post?: Function, now?: () => number }} options
 *   known: the saved state (`levelHelperUploads`)
 * @returns {Promise<{ known: object, summary: object, sent: object, error: Error|null, notFound: boolean }>}
 */
async function syncInstalls(config, { installs, known = {}, post = postLevelHelper, now = Date.now }) {
    const next = JSON.parse(JSON.stringify(known || {}));
    const summary = { runs: 0, golds: 0, medalRuns: 0, ownGolds: 0, characters: 0, guilds: 0, pending: 0 };
    const sent = { requests: 0, runsAdded: 0, runsMerged: 0, runsSkipped: 0, charactersUpdated: 0, runs: 0, characters: 0 };
    const distinct = new Set();
    const sentRuns = new Map();
    const guildsSeen = new Set();
    let error = null;
    let notFound = false;

    outer:
    for (const inst of installs) {
        for (const acct of inst.accounts) {
            let data;
            try {
                data = collectAccount(acct);
            } catch {
                continue;
            }
            const stateKey = `${inst.versionId}|${acct.account}`;
            for (const [guild, { runs, characters }] of Object.entries(data.guilds)) {
                const guildKey = `${inst.versionId}|${guild}`;
                guildsSeen.add(guildKey);
                for (const r of runs) {
                    const id = `${guildKey}|${r.id}`;
                    if (!distinct.has(id)) {
                        distinct.add(id);
                        summary.runs += 1;
                        if (r.medal) summary.medalRuns += 1;
                        if (r.medal === "gold") summary.golds += 1;
                    }
                }
                for (const c of characters) {
                    const id = `${guildKey}|${characterKey(c)}`;
                    if (distinct.has(id)) continue;
                    distinct.add(id);
                    summary.characters += 1;
                    if (c.own) summary.ownGolds += c.golds || 0;
                }

                const slot = (next[stateKey] = next[stateKey] || {});
                const known1 = (slot[guild] = slot[guild] || { at: 0, runs: {}, chars: {} });
                const pending = pendingChanges(known1, runs, characters);
                const already = sentRuns.get(guildKey) || new Set();
                // Same run, other account, this pass: on the server already.
                const toSend = pending.runs.filter((r) => !already.has(r.id));
                for (const r of pending.runs) if (already.has(r.id)) known1.runs[r.id] = runHash(r);
                if (!toSend.length && !pending.characters.length) continue;

                const requests = buildRequests({
                    versionId: inst.versionId, account: acct.account, guild, runs: toSend, characters: pending.characters,
                });
                for (const payload of requests) {
                    let answer;
                    try {
                        answer = await post(config, payload);
                    } catch (e) {
                        error = e;
                        notFound = e instanceof UploadError && e.status === 404;
                        summary.pending += toSend.length + pending.characters.length;
                        break outer;
                    }
                    sent.requests += 1;
                    sent.runs += payload.runs.length;
                    sent.characters += payload.characters.length;
                    const res = (answer && answer.runs) || {};
                    sent.runsAdded += Number(res.added) || 0;
                    sent.runsMerged += Number(res.merged) || 0;
                    sent.runsSkipped += Number(res.skipped) || 0;
                    sent.charactersUpdated += Number(answer && answer.characters && answer.characters.updated) || 0;
                    for (const r of payload.runs) {
                        known1.runs[r.id] = runHash(runs.find((x) => x.id === r.id) || r);
                        already.add(r.id);
                    }
                    for (const c of payload.characters) {
                        const original = characters.find((x) => x.name === c.name && (x.realm || null) === c.realm
                            && (x.guid || null) === c.guid);
                        if (original) known1.chars[characterKey(original)] = characterHash(original);
                    }
                    known1.at = now();
                }
                sentRuns.set(guildKey, already);
                // Forget what is no longer in the file (boards keep only a few runs).
                const liveRuns = new Set(runs.map((r) => r.id));
                for (const id of Object.keys(known1.runs)) if (!liveRuns.has(id)) delete known1.runs[id];
                const liveChars = new Set(characters.map(characterKey));
                for (const k of Object.keys(known1.chars)) if (!liveChars.has(k)) delete known1.chars[k];
            }
        }
    }
    summary.guilds = guildsSeen.size;
    // "Gold": runs with a gold medal; the file may carry no medals at all, then
    // the golds of the characters' roster entries.
    summary.golds = summary.medalRuns ? summary.golds : summary.ownGolds;
    return { known: next, summary, sent, error, notFound };
}

/** The newest upload time (ms) in the saved state, 0 = never. */
function lastUploadAt(known) {
    let latest = 0;
    for (const guilds of Object.values(known || {})) {
        for (const g of Object.values(guilds || {})) latest = Math.max(latest, Number(g && g.at) || 0);
    }
    return latest;
}

module.exports = {
    findInstalls, signature, readAccountDB, readCharDB, collectAccount, collectRuns, collectRoster, collectOwn,
    normalizeRun, normalizeClass, dedupeRuns, sanitizeRun, toUploadCharacter, LIMITS,
    pendingChanges, buildRequests, syncInstalls, postLevelHelper,
    lastUploadAt, characterKey,
    FORMAT, ENDPOINT, MAX_RUNS, MAX_CHARACTERS, FLAVOR_VERSIONS, SAVED_VARIABLES_FILE, CLASS_LIST,
};
