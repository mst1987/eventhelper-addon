"use strict";

// lib/levelhelper.js against a real (temporary) WoW folder: finding the
// installs, reading both SavedVariables files, building the payload,
// deduplication, splitting, change detection and the 404 of an old server.
const fs = require("fs");
const os = require("os");
const path = require("path");
const lh = require("../lib/levelhelper");
const { UploadError } = require("../lib/uploader");

// --- fixtures --------------------------------------------------------------

/** A JS value as WoW writes SavedVariables: lists positionally, maps with ["key"]. */
function lua(value, indent = "\t") {
    if (typeof value === "string") return JSON.stringify(value);
    if (typeof value !== "object" || value === null) return String(value);
    const inner = indent + "\t";
    if (Array.isArray(value)) {
        return `{\n${value.map((v, i) => `${inner}${lua(v, inner)}, -- [${i + 1}]\n`).join("")}${indent}}`;
    }
    return `{\n${Object.entries(value).filter(([, v]) => v !== null).map(([k, v]) => `${inner}[${JSON.stringify(k)}] = ${lua(v, inner)},\n`).join("")}${indent}}`;
}
const saved = (name, value) => `${name} = ${lua(value, "")}\n`;

// A group run in the addon's own short fields (class as an index: 2 = PALADIN, 8 = MAGE).
const RAGEFIRE = {
    d: "Ragefire Chasm", s: 1260, st: 1760000000, i: 4711,
    m: [
        { g: "4720-0001ABCD", n: "Devi", c: 2 },
        { g: "4720-0001ABCE", n: "Gemli", c: 8 },
    ],
    at: 1760001260, r: 2,
    id: "Ragefire Chasm|4720-0001ABCD,4720-0001ABCE|29333333|4711",
};
// The same run, reported by another member a few seconds later and slower: another id, same group.
const RAGEFIRE_AGAIN = { ...RAGEFIRE, s: 1268, st: 1760000030, id: "other-id", m: RAGEFIRE.m.map((m) => ({ ...m })) };
// A run in the long field names, class as a file name, with a medal.
const DEADMINES = {
    id: "dm-1", dungeon: "The Deadmines", seconds: 2100, start: 1760100000, instance: null, medal: "gold",
    members: [{ guid: "Player-4720-0001ABCD", name: "Devi", class: "PALADIN" }, { name: "Nameless", class: "Krieger" }],
};

const ACCOUNT_DB = {
    guildBoards: {
        Pulse: {
            "Ragefire Chasm": { top: [RAGEFIRE, RAGEFIRE_AGAIN], mine: RAGEFIRE },
            "The Deadmines": { top: [DEADMINES] },
        },
    },
    achievementSummary: { "Player-4720-0001ABCD": { name: "Devi", points: 135, count: 12 } },
    history: {
        "Player-4720-0001ABCD": { name: "Devi", class: "Paladin", realm: "Thunderstrike", levels: {}, current: { level: 23, since: 100 } },
    },
};
const ROSTER = {
    guildRoster: {
        Pulse: {
            "Player-4720-0001ABCE": { name: "Gemli", class: "MAGE", level: 31, points: 80, count: 7, golds: 2, at: 1760200000 },
            "Rexx-Thunderstrike": { name: "Rexx", class: 9, level: 12, points: 20, count: 3, golds: 0, at: 1760200100 },
            // this account's own character, with an older point count
            "Player-4720-0001ABCD": { name: "Devi", class: "PALADIN", level: 22, points: 100, count: 10, golds: 3, at: 1760100000 },
        },
    },
};
// A WoW-written achievements map: numeric keys as [id].
const CHAR_DB = "LevelHelperCharDB = {\n\t[\"achievements\"] = {\n\t\t[101] = 1760000100,\n\t\t[102] = 1760000200,\n\t\t[250] = 1760000300,\n\t},\n}\n";

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "lhtest-"));
let n = 0;

function makeWow({ flavor = "_classic_beta_", account = "405280973#1", db = ACCOUNT_DB, chars = [["Thunderstrike", "Devi", CHAR_DB]] } = {}) {
    const root = path.join(tmp, `wow${n += 1}`);
    const accountDir = path.join(root, flavor, "WTF", "Account", account);
    fs.mkdirSync(path.join(accountDir, "SavedVariables"), { recursive: true });
    if (db) fs.writeFileSync(path.join(accountDir, "SavedVariables", "LevelHelper.lua"), saved("LevelHelperDB", db));
    for (const [realm, name, text] of chars) {
        const dir = path.join(accountDir, realm, name, "SavedVariables");
        fs.mkdirSync(dir, { recursive: true });
        fs.writeFileSync(path.join(dir, "LevelHelper.lua"), text);
    }
    return root;
}

const installsOf = (root) => lh.findInstalls([], { roots: [root] });

afterAll(() => {
    fs.rmSync(tmp, { recursive: true, force: true });
});

// --- finding ---------------------------------------------------------------

describe("findInstalls", () => {
    it("ordnet _classic_beta_ der Version forever zu und findet Account- und Charakter-Dateien", () => {
        const { installs, skipped } = installsOf(makeWow());
        expect(skipped).toEqual([]);
        expect(installs).toHaveLength(1);
        expect(installs[0]).toMatchObject({ flavor: "_classic_beta_", versionId: "forever" });
        const acct = installs[0].accounts[0];
        expect(acct.account).toBe("405280973#1");
        expect(acct.file).toMatch(/SavedVariables[\\/]LevelHelper\.lua$/);
        expect(acct.characters).toEqual([expect.objectContaining({ realm: "Thunderstrike", name: "Devi" })]);
    });

    it("kennt auch TBC Anniversary", () => {
        expect(installsOf(makeWow({ flavor: "_anniversary_" })).installs[0].versionId).toBe("tbc");
    });

    it("lädt nur von Installationen hoch, in denen LevelHelper liegt", () => {
        const root = path.join(tmp, "ohne");
        fs.mkdirSync(path.join(root, "_classic_beta_", "WTF", "Account", "A", "SavedVariables"), { recursive: true });
        fs.writeFileSync(path.join(root, "_classic_beta_", "WTF", "Account", "A", "SavedVariables", "EventHelperSync.lua"), "x = 1");
        expect(installsOf(root).installs).toEqual([]);
    });

    it("meldet Varianten mit unbekannter Spielversion, statt sie unter einer geratenen Version hochzuladen", () => {
        const { installs, skipped } = installsOf(makeWow({ flavor: "_ptr_" }));
        expect(installs).toEqual([]);
        expect(skipped).toEqual(["_ptr_"]);
    });

    it("nimmt ein Konto mit nur einer Charakter-Datei, aber ohne Account-Datei", () => {
        const acct = installsOf(makeWow({ db: null })).installs[0].accounts[0];
        expect(acct.file).toBeNull();
        expect(acct.characters).toHaveLength(1);
    });

    it("ändert die Signatur, wenn eine LevelHelper-Datei geschrieben wird", () => {
        const root = makeWow();
        const { installs } = installsOf(root);
        const before = lh.signature(installs);
        const file = installs[0].accounts[0].file;
        const t = new Date(Date.now() + 5000);
        fs.utimesSync(file, t, t);
        expect(lh.signature(installs)).not.toBe(before);
    });
});

// --- reading ---------------------------------------------------------------

describe("Läufe lesen", () => {
    it("liest Kurzfelder mit Klassen-Index und lange Felder mit Klassendatei oder lokalisiertem Namen", () => {
        const acct = installsOf(makeWow()).installs[0].accounts[0];
        const { guilds } = lh.collectAccount(acct);
        const runs = guilds.Pulse.runs;
        const ragefire = runs.find((r) => r.dungeon === "Ragefire Chasm");
        expect(ragefire).toEqual({
            id: RAGEFIRE.id, dungeon: "Ragefire Chasm", seconds: 1260, start: 1760000000, instance: 4711, medal: null,
            members: [
                { guid: "4720-0001ABCD", name: "Devi", class: "PALADIN" },
                { guid: "4720-0001ABCE", name: "Gemli", class: "MAGE" },
            ],
            at: 1760001260,
        });
        const dm = runs.find((r) => r.dungeon === "The Deadmines");
        expect(dm).toMatchObject({ id: "dm-1", seconds: 2100, instance: null, medal: "gold", at: 1760102100 });
        expect(dm.members).toEqual([
            { guid: "4720-0001ABCD", name: "Devi", class: "PALADIN" },
            { guid: null, name: "Nameless", class: "WARRIOR" },
        ]);
    });

    it("zählt denselben Lauf auf mehreren Brettern und als mine nur einmal, mit der schnellsten Zeit", () => {
        const acct = installsOf(makeWow()).installs[0].accounts[0];
        const runs = lh.collectAccount(acct).guilds.Pulse.runs;
        expect(runs.filter((r) => r.dungeon === "Ragefire Chasm")).toHaveLength(1);
        expect(runs.find((r) => r.dungeon === "Ragefire Chasm").seconds).toBe(1260);
    });

    it("verwirft Einträge ohne Dungeon, Zeit oder Start und baut eine fehlende id", () => {
        expect(lh.normalizeRun({ d: "X", s: 0, st: 5 })).toBeNull();
        expect(lh.normalizeRun({ s: 100, st: 5 })).toBeNull();
        expect(lh.normalizeRun({ d: "X", s: 100 })).toBeNull();
        expect(lh.normalizeRun("kaputt")).toBeNull();
        const run = lh.normalizeRun({ d: "X", s: 100, st: 600, m: [{ g: "1-AB", n: "A" }] });
        expect(run.id).toBe("X|1-AB|10|0");
        expect(run.members[0].class).toBeNull();
    });

    it("kennt Klassen als Index, Klassendatei und (de/en) lokalisierten Namen", () => {
        expect(lh.normalizeClass(2)).toBe("PALADIN");
        expect(lh.normalizeClass("13")).toBe("EVOKER");
        expect(lh.normalizeClass("deathknight")).toBe("DEATHKNIGHT");
        expect(lh.normalizeClass("Todesritter")).toBe("DEATHKNIGHT");
        expect(lh.normalizeClass("Jäger")).toBe("HUNTER");
        expect(lh.normalizeClass("Mage")).toBe("MAGE");
        expect(lh.normalizeClass(99)).toBeNull();
        expect(lh.normalizeClass("")).toBeNull();
    });
});

describe("Charaktere lesen", () => {
    it("nimmt Roster und eigene Charaktere zusammen, der eigene Stand hat Vorrang", () => {
        const acct = installsOf(makeWow({ db: { ...ACCOUNT_DB, ...ROSTER } })).installs[0].accounts[0];
        const chars = lh.collectAccount(acct).guilds.Pulse.characters;
        expect(chars).toHaveLength(3);
        const devi = chars.find((c) => c.name === "Devi");
        // count from the character's achievements (3), points from achievementSummary (135), level from the history (23),
        // golds only the roster knows (3)
        expect(devi).toMatchObject({
            guid: "4720-0001ABCD", realm: "Thunderstrike", class: "PALADIN", level: 23, points: 135, count: 3, golds: 3,
        });
        expect(chars.find((c) => c.name === "Gemli")).toMatchObject({ guid: "4720-0001ABCE", class: "MAGE", level: 31, points: 80, count: 7, golds: 2, at: 1760200000 });
        // key "Name-Realm" and a class index
        expect(chars.find((c) => c.name === "Rexx")).toMatchObject({ guid: null, realm: "Thunderstrike", class: "WARLOCK", level: 12 });
    });

    it("kommt ohne Roster aus: nur die eigenen Charaktere, aus Ordner und Account-Datei", () => {
        const acct = installsOf(makeWow()).installs[0].accounts[0];
        const chars = lh.collectAccount(acct).guilds.Pulse.characters;
        expect(chars).toEqual([expect.objectContaining({
            guid: "4720-0001ABCD", name: "Devi", realm: "Thunderstrike", class: "PALADIN", level: 23, points: 135, count: 3, golds: null,
        })]);
    });

    it("schickt bei unbekannten Punkten null statt zu raten", () => {
        const db = { guildBoards: ACCOUNT_DB.guildBoards };
        const chars = lh.collectAccount(installsOf(makeWow({ db })).installs[0].accounts[0]).guilds.Pulse.characters;
        expect(chars[0]).toMatchObject({ name: "Devi", realm: "Thunderstrike", guid: null, points: null, level: null, count: 3 });
    });

    it("ordnet eigene Charaktere bei mehreren Gilden der Gilde zu, die sie kennt, sonst keiner", () => {
        const db = {
            guildBoards: {
                Pulse: { "The Deadmines": { top: [DEADMINES] } },
                Anders: { "The Deadmines": { top: [{ ...DEADMINES, id: "dm-2", members: [{ guid: "9-FF", name: "Fremd" }] }] } },
            },
        };
        const { guilds } = lh.collectAccount(installsOf(makeWow({ db })).installs[0].accounts[0]);
        expect(guilds.Pulse.characters.map((c) => c.name)).toEqual(["Devi"]);
        expect(guilds.Anders.characters).toEqual([]);
        // a character nobody knows, with two guilds: left out
        const lonely = makeWow({ db, chars: [["Thunderstrike", "Niemand", CHAR_DB]] });
        const again = lh.collectAccount(installsOf(lonely).installs[0].accounts[0]).guilds;
        expect(Object.values(again).every((g) => g.characters.length === 0)).toBe(true);
    });

    it("liest eine kaputte Charakter-Datei nicht, ohne die anderen zu verlieren", () => {
        const root = makeWow({ chars: [["Thunderstrike", "Devi", CHAR_DB], ["Thunderstrike", "Kaputt", "LevelHelperCharDB = {"]] });
        const chars = lh.collectAccount(installsOf(root).installs[0].accounts[0]).guilds.Pulse.characters;
        expect(chars.map((c) => c.name)).toEqual(["Devi"]);
    });

    it("liest auch, wenn die Account-Datei fehlt oder kaputt ist", () => {
        expect(lh.collectAccount({ file: null, characters: [] })).toEqual({ guilds: {} });
        const root = makeWow({ db: null });
        fs.writeFileSync(path.join(root, "_classic_beta_", "WTF", "Account", "405280973#1", "SavedVariables", "LevelHelper.lua"), "LevelHelperDB = {");
        expect(lh.collectAccount(installsOf(root).installs[0].accounts[0])).toEqual({ guilds: {} });
    });
});

// --- payload ---------------------------------------------------------------

function run(i, over = {}) {
    return {
        id: `run-${i}`, dungeon: "The Stockade", seconds: 1000 + i, start: 1760000000 + i * 1000, instance: null, medal: null,
        members: [{ guid: `1-${i}`, name: `P${i}`, class: "MAGE" }], at: 1760001000 + i * 1000, ...over,
    };
}
const character = (i, over = {}) => ({
    guid: `2-${i}`, name: `C${i}`, realm: "Thunderstrike", class: "MAGE", level: 10, points: 5, count: 1, golds: 0, at: 1760300000, ...over,
});

describe("buildRequests", () => {
    const base = { versionId: "forever", account: "405280973#1", guild: "Pulse" };

    it("baut die Nutzlast des Vertrags", () => {
        const [payload, ...more] = lh.buildRequests({ ...base, runs: [run(1)], characters: [character(1)] });
        expect(more).toEqual([]);
        expect(payload).toEqual({
            format: "levelhelper-runs", v: 1, versionId: "forever", guild: "Pulse",
            uploader: { account: "405280973#1" },
            runs: [run(1)],
            characters: [{
                guid: "2-1", name: "C1", realm: "Thunderstrike", class: "MAGE", level: 10, points: 5, count: 1, golds: 0, at: 1760300000,
            }],
        });
    });

    it("splittet bei mehr als 500 Läufen und 200 Charakteren", () => {
        const runs = Array.from({ length: 1201 }, (_, i) => run(i));
        const characters = Array.from({ length: 450 }, (_, i) => character(i));
        const requests = lh.buildRequests({ ...base, runs, characters });
        expect(requests).toHaveLength(3);
        expect(requests.map((r) => r.runs.length)).toEqual([500, 500, 201]);
        expect(requests.map((r) => r.characters.length)).toEqual([200, 200, 50]);
        // nothing lost, nothing twice
        expect(new Set(requests.flatMap((r) => r.runs.map((x) => x.id))).size).toBe(1201);
        expect(new Set(requests.flatMap((r) => r.characters.map((x) => x.guid))).size).toBe(450);
    });

    it("macht eine Anfrage nur aus Charakteren, wenn es keine Läufe gibt", () => {
        const requests = lh.buildRequests({ ...base, runs: [], characters: [character(1)] });
        expect(requests).toHaveLength(1);
        expect(requests[0].runs).toEqual([]);
    });

    it("macht keine Anfrage, wenn nichts da ist", () => {
        expect(lh.buildRequests({ ...base, runs: [], characters: [] })).toEqual([]);
    });
});

describe("Server-Grenzen (ein ungültiger Eintrag würde den ganzen Upload ablehnen)", () => {
    it("lässt einen gültigen Lauf unverändert", () => {
        expect(lh.sanitizeRun(run(1))).toEqual(run(1));
    });

    it("sortiert Läufe aus, die der Server nie nimmt", () => {
        expect(lh.sanitizeRun(run(1, { seconds: 30 }))).toBeNull();
        expect(lh.sanitizeRun(run(1, { seconds: 20000 }))).toBeNull();
        expect(lh.sanitizeRun(run(1, { start: 12345 }))).toBeNull();
        expect(lh.sanitizeRun(run(1, { dungeon: "  " }))).toBeNull();
        expect(lh.sanitizeRun(run(1, { members: [{ guid: "1-1", name: null, class: "MAGE" }] }))).toBeNull();
    });

    it("kürzt, was zu lang ist, und hält höchstens 5 Mitglieder", () => {
        const members = Array.from({ length: 7 }, (_, i) => ({ guid: `g${i}`, name: `N${i}`, class: "WARRIOR" }));
        members.splice(1, 0, { guid: "nameless", name: "", class: "MAGE" });
        const out = lh.sanitizeRun(run(1, { id: "x".repeat(120), members, medal: "platinum", instance: -1, at: 5 }));
        expect(out.id.length).toBeLessThanOrEqual(64);
        expect(out.id).toBe(lh.sanitizeRun(run(1, { id: "x".repeat(120) })).id); // stabil: dieselbe id gibt denselben Hash
        expect(out.members.map((m) => m.name)).toEqual(["N0", "N1", "N2", "N3", "N4"]);
        expect(out.medal).toBeNull();
        expect(out.instance).toBeNull();
        expect(out.at).toBe(out.start + out.seconds);
    });

    it("macht Klassen zu Tokens oder null", () => {
        const out = lh.sanitizeRun(run(1, { members: [{ guid: "1", name: "A", class: "Paladin" }, { guid: "2", name: "B", class: "Krieger!" }] }));
        expect(out.members.map((m) => m.class)).toEqual(["PALADIN", null]);
    });

    it("hält Charaktere in den Grenzen und lässt namenlose weg", () => {
        expect(lh.toUploadCharacter(character(1, { name: "" }))).toBeNull();
        const c = lh.toUploadCharacter(character(1, { name: "N".repeat(80), level: 250, points: -3, count: 2.6, golds: undefined, at: 7, class: "mage" }));
        expect(c.name.length).toBe(48);
        expect(c.level).toBe(100);
        expect(c.points).toBe(0);
        expect(c.count).toBe(3);
        expect(c.golds).toBeNull();
        expect(c.class).toBe("MAGE");
        expect(c.at).toBeGreaterThan(1000000000);
    });

    it("kürzt den Gildennamen auf 60 Zeichen", () => {
        const [payload] = lh.buildRequests({ versionId: "forever", account: "a", guild: "G".repeat(90), runs: [run(1)], characters: [] });
        expect(payload.guild).toHaveLength(60);
    });
});

describe("dedupeRuns", () => {
    it("führt denselben Lauf (gleiche id oder gleiche Gruppe zur gleichen Zeit) zusammen", () => {
        const a = run(1, { members: [{ guid: "1-A", name: "A", class: "MAGE" }] });
        const sameId = { ...a, seconds: 900, medal: "gold" };
        const sameGroup = { ...a, id: "x", start: a.start + 60, members: [{ guid: "1-A", name: "A", class: "MAGE" }] };
        const other = run(2);
        const out = lh.dedupeRuns([a, sameId, sameGroup, other]);
        expect(out).toHaveLength(2);
        expect(out[0]).toMatchObject({ seconds: 900, medal: "gold" });
    });

    it("hält Läufe derselben Gruppe an verschiedenen Tagen auseinander", () => {
        const a = run(1);
        expect(lh.dedupeRuns([a, { ...a, id: "later", start: a.start + 86400 }])).toHaveLength(2);
    });

    it("vereinigt die Mitglieder", () => {
        const a = run(1, { members: [{ guid: "1-A", name: "A", class: null }] });
        const b = { ...a, id: "b", members: [{ guid: "1-A", name: "A", class: "MAGE" }] };
        const out = lh.dedupeRuns([a, b]);
        expect(out).toHaveLength(1);
        expect(out[0].members).toHaveLength(1);
    });
});

// --- change detection and the pass ------------------------------------------

describe("syncInstalls", () => {
    const CONFIG = { baseUrl: "https://example.test", token: "ehl_x" };
    const ok = (runs = {}) => jest.fn(async () => ({ ok: true, runs: { added: 0, merged: 0, skipped: 0, ...runs }, characters: { updated: 1 } }));

    it("lädt beim ersten Mal alles hoch, danach nichts mehr", async () => {
        const installs = installsOf(makeWow({ db: { ...ACCOUNT_DB, ...ROSTER } })).installs;
        const post = ok({ added: 2 });
        const first = await lh.syncInstalls(CONFIG, { installs, post, now: () => 5000 });
        expect(first.error).toBeNull();
        expect(post).toHaveBeenCalledTimes(1);
        const payload = post.mock.calls[0][1];
        expect(payload).toMatchObject({ format: "levelhelper-runs", v: 1, versionId: "forever", guild: "Pulse", uploader: { account: "405280973#1" } });
        expect(payload.runs.map((r) => r.dungeon).sort()).toEqual(["Ragefire Chasm", "The Deadmines"]);
        expect(payload.characters).toHaveLength(3);
        expect(first.sent).toMatchObject({ requests: 1, runsAdded: 2, charactersUpdated: 1, runs: 2, characters: 3 });
        expect(first.summary).toMatchObject({ runs: 2, golds: 1, guilds: 1, characters: 3 });
        expect(lh.lastUploadAt(first.known)).toBe(5000);

        const second = await lh.syncInstalls(CONFIG, { installs, post, known: first.known });
        expect(post).toHaveBeenCalledTimes(1);
        expect(second.sent.requests).toBe(0);
        // the tile numbers are still there without an upload
        expect(second.summary.runs).toBe(2);
        expect(lh.lastUploadAt(second.known)).toBe(5000);
    });

    it("schickt nur den geänderten Lauf und den geänderten Charakter", async () => {
        const root = makeWow({ db: { ...ACCOUNT_DB, ...ROSTER } });
        const installs = installsOf(root).installs;
        const first = await lh.syncInstalls(CONFIG, { installs, post: ok() });

        // a better time for the Deadmines run and a new level for Gemli
        const changed = JSON.parse(JSON.stringify({ ...ACCOUNT_DB, ...ROSTER }));
        changed.guildBoards.Pulse["The Deadmines"].top[0].seconds = 1900;
        changed.guildRoster.Pulse["Player-4720-0001ABCE"].level = 32;
        fs.writeFileSync(installs[0].accounts[0].file, saved("LevelHelperDB", changed));

        const post = ok({ merged: 1 });
        await lh.syncInstalls(CONFIG, { installs, post, known: first.known });
        expect(post).toHaveBeenCalledTimes(1);
        const payload = post.mock.calls[0][1];
        expect(payload.runs.map((r) => [r.id, r.seconds])).toEqual([["dm-1", 1900]]);
        expect(payload.characters.map((c) => [c.name, c.level])).toEqual([["Gemli", 32]]);
    });

    it("schickt einen Charakter nicht neu, nur weil sich sein Zeitstempel geändert hat", async () => {
        const installs = installsOf(makeWow({ db: { ...ACCOUNT_DB, ...ROSTER } })).installs;
        const first = await lh.syncInstalls(CONFIG, { installs, post: ok() });
        const touched = JSON.parse(JSON.stringify({ ...ACCOUNT_DB, ...ROSTER }));
        touched.guildRoster.Pulse["Player-4720-0001ABCE"].at = 1760999999;
        fs.writeFileSync(installs[0].accounts[0].file, saved("LevelHelperDB", touched));
        const post = ok();
        await lh.syncInstalls(CONFIG, { installs, post, known: first.known });
        expect(post).not.toHaveBeenCalled();
    });

    it("schickt denselben Lauf aus zwei Accounts derselben Gilde nur einmal", async () => {
        const root = makeWow({ account: "111#1" });
        const second = makeWow({ account: "222#1" });
        // two accounts in one install: copy the second account's folder next to the first
        fs.cpSync(path.join(second, "_classic_beta_", "WTF", "Account", "222#1"), path.join(root, "_classic_beta_", "WTF", "Account", "222#1"), { recursive: true });
        const installs = installsOf(root).installs;
        expect(installs[0].accounts.map((a) => a.account).sort()).toEqual(["111#1", "222#1"]);
        const post = ok();
        const result = await lh.syncInstalls(CONFIG, { installs, post });
        const sentRuns = post.mock.calls.flatMap((c) => c[1].runs.map((r) => r.id));
        expect(sentRuns.sort()).toEqual([DEADMINES.id, RAGEFIRE.id].sort());
        // both requests name their own account; the second one carries no runs, only characters
        expect(post.mock.calls.map((c) => c[1].uploader.account).sort()).toEqual(["111#1", "222#1"]);
        expect(result.summary.runs).toBe(2);
        // and the second account counts them as known: nothing more on the next pass
        const again = ok();
        await lh.syncInstalls(CONFIG, { installs, post: again, known: result.known });
        expect(again).not.toHaveBeenCalled();
    });

    it("hält einen Fehler fest, vergisst aber nicht, was vorher ankam", async () => {
        const installs = installsOf(makeWow({ db: { ...ACCOUNT_DB, ...ROSTER } })).installs;
        const boom = jest.fn(async () => { throw new UploadError("Server weg"); });
        const failed = await lh.syncInstalls(CONFIG, { installs, post: boom });
        expect(failed.error).toBeInstanceOf(UploadError);
        expect(failed.notFound).toBe(false);
        expect(failed.summary.pending).toBeGreaterThan(0);
        expect(lh.lastUploadAt(failed.known)).toBe(0);
        // the retry sends everything again
        const post = ok();
        await lh.syncInstalls(CONFIG, { installs, post, known: failed.known });
        expect(post.mock.calls[0][1].runs).toHaveLength(2);
    });

    it("meldet ein 404 eines älteren Servers als notFound und hört auf", async () => {
        const root = makeWow({ db: { ...ACCOUNT_DB, ...ROSTER } });
        const installs = installsOf(root).installs;
        const post = jest.fn(async () => { throw new UploadError("HTTP 404", 404); });
        const result = await lh.syncInstalls(CONFIG, { installs, post });
        expect(result.notFound).toBe(true);
        expect(post).toHaveBeenCalledTimes(1);
    });

    it("splittet große Mengen in mehrere Anfragen und merkt sich jede erfolgreiche", async () => {
        const runs = Array.from({ length: 520 }, (_, i) => ({ ...DEADMINES, id: `big-${i}`, start: 1760100000 + i * 5000, members: [{ guid: `7-${i}`, name: `M${i}` }] }));
        const db = { guildBoards: { Pulse: { "The Deadmines": { top: runs } } } };
        const installs = installsOf(makeWow({ db, chars: [] })).installs;
        let calls = 0;
        const post = jest.fn(async () => {
            calls += 1;
            if (calls === 2) throw new UploadError("HTTP 502", 502);
            return { ok: true, runs: { added: 1, merged: 0, skipped: 0 }, characters: { updated: 0 } };
        });
        const failed = await lh.syncInstalls(CONFIG, { installs, post, now: () => 7 });
        expect(post.mock.calls[0][1].runs).toHaveLength(500);
        expect(failed.error).toBeTruthy();
        // the first 500 went up; only the rest is left
        const retry = ok();
        await lh.syncInstalls(CONFIG, { installs, post: retry, known: failed.known });
        expect(retry.mock.calls[0][1].runs).toHaveLength(20);
    });

    it("vergisst Läufe, die nicht mehr in der Datei stehen, damit der Zustand nicht wächst", async () => {
        const root = makeWow({ db: { ...ACCOUNT_DB, ...ROSTER } });
        const installs = installsOf(root).installs;
        const first = await lh.syncInstalls(CONFIG, { installs, post: ok() });
        const slim = { guildBoards: { Pulse: { "The Deadmines": { top: [DEADMINES] } } } };
        fs.writeFileSync(installs[0].accounts[0].file, saved("LevelHelperDB", slim));
        const second = await lh.syncInstalls(CONFIG, { installs, post: ok(), known: first.known });
        expect(Object.keys(second.known["forever|405280973#1"].Pulse.runs)).toEqual(["dm-1"]);
    });
});
