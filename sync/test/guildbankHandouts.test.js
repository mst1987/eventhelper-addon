"use strict";

// Guild bank handouts, server -> game and back: format check, fetch, the
// GuildBankData.lua the addon reads (written into temp addon folders like
// council.test.js), reading the ticked entries from the SavedVariables and
// reporting them in batches.
const fs = require("fs");
const os = require("os");
const path = require("path");
const {
    syncHandouts, fetchHandouts, validateHandouts, buildHandoutsFile, countHandouts,
    normalizeDone, readGuildBankDone, unreported, pruneReported, reportDone,
    HandoutsError, HANDOUTS_FILE, MAX_DONE, REPORTED_KEEP_MS,
} = require("../lib/guildbankHandouts");
const { parseSavedVariables } = require("../lib/luaParser");

const CONFIG = { baseUrl: "https://example.test:3005/", token: "ehl_secret", extraRoots: [] };

function handout(over = {}) {
    return {
        id: "ad8f943938a6",
        itemId: 24027,
        name: "Bold Living Ruby",
        icon: "inv_jewelcrafting_livingruby_03",
        quality: 3,
        amount: 2,
        purpose: "Gruul – „Mag“ …",
        character: { name: "Zibbo", realm: "Spineshatter", faction: "Alliance", classFile: "PRIEST" },
        requestedBy: "Anna",
        requestedAt: 1791294665,
        confirmedBy: "Arthas",
        confirmedAt: 1791294665,
        inBank: 14,
        tabs: [{ index: 1, name: "Edelsteine", count: 10 }, { index: 2, name: "Verbrauch", count: 4 }],
        ...over,
    };
}

function payload(over = {}) {
    return {
        format: "eventhelper-guildbank-handouts",
        version: 1,
        generatedAt: 1791294674,
        banks: [
            {
                key: "tbc:spineshatter:die gilde", gameVersion: "tbc", realm: "Spineshatter", guild: "Die Gilde",
                faction: "Alliance", scannedAt: 1791000000,
                handouts: [handout(), handout({ id: "b2", character: null, requestedBy: "Bjørn", quality: -1, icon: "" })],
            },
            {
                key: "forever:spineshatter:die gilde", gameVersion: "forever", realm: "Spineshatter", guild: "Die Gilde",
                faction: "Alliance", scannedAt: 1791000001, handouts: [],
            },
        ],
        ...over,
    };
}

function readBack(text) {
    return parseSavedVariables(text).EventHelperSync_GuildBankHandouts;
}

function mockFetch(status, body) {
    global.fetch = jest.fn(async () => ({
        ok: status >= 200 && status < 300,
        status,
        text: async () => (typeof body === "string" ? body : JSON.stringify(body)),
    }));
}

afterEach(() => {
    delete global.fetch;
});

describe("validateHandouts", () => {
    it("nimmt Version 1 an", () => {
        const p = payload();
        expect(validateHandouts(p)).toBe(p);
        expect(countHandouts(p)).toBe(2);
    });

    it("lehnt eine höhere Version mit klarer Meldung ab", () => {
        expect(() => validateHandouts(payload({ version: 2 })))
            .toThrow(/Version 2, dieses Sync-Tool kennt nur Version 1.*aktualisieren/);
    });

    it("lehnt ein anderes Format, kaputte Versionen und fehlende Banken ab", () => {
        expect(() => validateHandouts(payload({ format: "eventhelper-council" }))).toThrow(HandoutsError);
        expect(() => validateHandouts(payload({ version: "1" }))).toThrow(/Ungültige Version/);
        expect(() => validateHandouts(payload({ banks: null }))).toThrow(/keine Gildenbanken/);
        expect(() => validateHandouts(null)).toThrow(/keine Ausgabeliste/);
        expect(() => validateHandouts([])).toThrow(/keine Ausgabeliste/);
    });
});

describe("fetchHandouts", () => {
    it("fragt per GET mit Bearer-Token und packt { data } aus", async () => {
        mockFetch(200, { data: payload() });
        const data = await fetchHandouts(CONFIG);
        expect(data.format).toBe("eventhelper-guildbank-handouts");
        const [url, init] = global.fetch.mock.calls[0];
        expect(url).toBe("https://example.test:3005/api/ingest/guildbank/handouts");
        expect(init.method).toBe("GET");
        expect(init.headers.Authorization).toBe("Bearer ehl_secret");
    });

    it("kann auf eine Bank einschränken", async () => {
        mockFetch(200, { data: payload() });
        await fetchHandouts(CONFIG, { bank: "tbc:spineshatter:die gilde" });
        expect(global.fetch.mock.calls[0][0]).toMatch(/handouts\?bank=tbc%3Aspineshatter%3Adie%20gilde$/);
    });

    it("erklärt ein 404 als zu alten Server", async () => {
        mockFetch(404, { error: { code: "not_found", message: "Not found" } });
        await expect(fetchHandouts(CONFIG)).rejects.toThrow(/kennt noch keine Ausgabeliste/);
    });

    it("reicht die Fehlermeldung des Servers weiter", async () => {
        mockFetch(401, { error: { code: "bad_token", message: "API-Token unbekannt oder zurückgezogen." } });
        await expect(fetchHandouts(CONFIG)).rejects.toThrow("API-Token unbekannt oder zurückgezogen.");
    });
});

describe("buildHandoutsFile", () => {
    it("schreibt Kopfzeile und globale Variable, Latin-1 und lesbar zurück", () => {
        const text = buildHandoutsFile(payload(), { syncVersion: "9.9.9", now: new Date("2026-10-05T19:30:00Z") });
        expect(text.split("\n")[0]).toBe(
            "-- Generated by EventHelper Sync 9.9.9 at 2026-10-05T19:30:00.000Z. Do not edit; it is overwritten.",
        );
        expect(text).toMatch(/^EventHelperSync_GuildBankHandouts = \{$/m);
        expect([...text].every((ch) => ch.codePointAt(0) <= 0xff)).toBe(true);
        const back = readBack(text);
        expect(back.banks).toHaveLength(2);
        const [first, second] = back.banks[0].handouts;
        expect(first.purpose).toBe('Gruul - "Mag" ...');
        expect(first.character).toEqual({ name: "Zibbo", realm: "Spineshatter", faction: "Alliance", classFile: "PRIEST" });
        expect(first.tabs).toEqual([{ index: 1, name: "Edelsteine", count: 10 }, { index: 2, name: "Verbrauch", count: 4 }]);
        // character null: simply missing in Lua (nil), the addon shows requestedBy
        expect(second.character).toBeUndefined();
        expect(second.requestedBy).toBe("Bjørn");
        expect(second.quality).toBe(-1);
        expect(second.icon).toBe("");
        // a bank without handouts stays, so the addon clears its list
        expect(back.banks[1].handouts).toEqual([]);
    });
});

describe("syncHandouts", () => {
    let tmp;
    let wow;

    beforeEach(() => {
        tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ehs-handouts-"));
        wow = path.join(tmp, "World of Warcraft");
        for (const flavor of ["_anniversary_", "_classic_beta_"]) {
            fs.mkdirSync(path.join(wow, flavor, "Interface", "AddOns", "EventHelperSync"), { recursive: true });
        }
        fs.mkdirSync(path.join(wow, "_classic_era_", "Interface", "AddOns", "Gargul"), { recursive: true });
    });

    afterEach(() => {
        fs.rmSync(tmp, { recursive: true, force: true });
    });

    it("schreibt GuildBankData.lua in jeden gefundenen Addon-Ordner und legt keinen an", async () => {
        mockFetch(200, { data: payload() });
        const result = await syncHandouts(CONFIG, { roots: [wow], now: new Date("2026-10-05T19:30:00Z") });

        expect(result).toMatchObject({ banks: 2, handouts: 2, errors: [] });
        expect(result.files).toHaveLength(2);
        for (const flavor of ["_anniversary_", "_classic_beta_"]) {
            const dir = path.join(wow, flavor, "Interface", "AddOns", "EventHelperSync");
            expect(fs.readdirSync(dir)).toEqual([HANDOUTS_FILE]);
            expect(readBack(fs.readFileSync(path.join(dir, HANDOUTS_FILE), "utf8")).banks[0].handouts[0].id)
                .toBe("ad8f943938a6");
        }
        expect(fs.existsSync(path.join(wow, "_classic_era_", "Interface", "AddOns", "EventHelperSync"))).toBe(false);
    });

    it("schreibt nichts, wenn der Server eine neuere Version liefert", async () => {
        mockFetch(200, { data: payload({ version: 2 }) });
        await expect(syncHandouts(CONFIG, { roots: [wow] })).rejects.toThrow(/Version 2/);
        expect(fs.readdirSync(path.join(wow, "_anniversary_", "Interface", "AddOns", "EventHelperSync"))).toEqual([]);
    });

    it("meldet einen nicht beschreibbaren Ordner und schreibt die anderen trotzdem", async () => {
        const blocked = path.join(wow, "_anniversary_", "Interface", "AddOns", "EventHelperSync", HANDOUTS_FILE);
        fs.mkdirSync(blocked);
        mockFetch(200, { data: payload() });
        const result = await syncHandouts(CONFIG, { roots: [wow] });
        expect(result.files).toHaveLength(1);
        expect(result.errors).toHaveLength(1);
        expect(result.errors[0]).toContain(HANDOUTS_FILE);
    });
});

describe("abgehakte Posten lesen", () => {
    it("versteht eine Tabelle nach id, eine Liste und blosse ids", () => {
        expect(normalizeDone({
            a1: { id: "a1", via: "manual", by: "Gemli-Thunderstrike", at: 1791300000 },
            b2: { via: "mail", by: "Jaina", at: 1791300001.7 },
            c3: true,
        })).toEqual([
            { id: "a1", via: "manual", by: "Gemli-Thunderstrike", at: 1791300000 },
            { id: "b2", via: "mail", by: "Jaina", at: 1791300001 },
            { id: "c3", via: "manual", by: "", at: 0 },
        ]);
        expect(normalizeDone([{ id: "x", via: "post" }, "y", { id: "x" }, { via: "mail" }, null, { id: "  " }]))
            .toEqual([{ id: "x", via: "manual", by: "", at: 0 }, { id: "y", via: "manual", by: "", at: 0 }]);
        expect(normalizeDone(undefined)).toEqual([]);
        expect(normalizeDone("kaputt")).toEqual([]);
    });

    it("kürzt by auf 60 Zeichen", () => {
        expect(normalizeDone([{ id: "x", by: "a".repeat(80) }])[0].by).toHaveLength(60);
    });

    it("liest EventHelperSyncDB.guildBankDone aus der SavedVariables-Datei", () => {
        const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ehs-done-"));
        try {
            const file = path.join(dir, "EventHelperSync.lua");
            fs.writeFileSync(file, [
                "EventHelperSyncDB = {",
                '  ["guildBankDone"] = {',
                '    ["ad8f943938a6"] = { ["id"] = "ad8f943938a6", ["via"] = "manual", ["by"] = "Gemli-Thunderstrike", ["at"] = 1791300000 },',
                "  },",
                '  ["settings"] = { ["debug"] = false },',
                "}",
            ].join("\n"));
            expect(readGuildBankDone(file)).toEqual([
                { id: "ad8f943938a6", via: "manual", by: "Gemli-Thunderstrike", at: 1791300000 },
            ]);
            fs.writeFileSync(file, "EventHelperSyncDB = { [\"settings\"] = {} }\n");
            expect(readGuildBankDone(file)).toEqual([]);
        } finally {
            fs.rmSync(dir, { recursive: true, force: true });
        }
    });

    it("lässt schon gemeldete ids weg und vergisst sie nach 30 Tagen", () => {
        const entries = normalizeDone(["a", "b", "c"]);
        expect(unreported(entries, { b: 1 }).map((e) => e.id)).toEqual(["a", "c"]);
        expect(unreported(entries, undefined)).toHaveLength(3);
        const now = 1_800_000_000_000;
        expect(pruneReported({ old: now - REPORTED_KEEP_MS - 1, fresh: now - 1000 }, now)).toEqual({ fresh: now - 1000 });
    });
});

describe("reportDone", () => {
    const answer = (over = {}) => ({
        format: "eventhelper-guildbank-handouts", version: 1,
        ok: [], duplicate: [], notConfirmed: [], unknown: [], invalid: 0, ...over,
    });

    it("schickt die Posten per POST und sammelt die Antwort", async () => {
        mockFetch(200, { data: answer({ ok: ["a"], duplicate: ["b"], unknown: ["c"], invalid: 0 }) });
        const entries = normalizeDone([
            { id: "a", via: "manual", by: "Gemli-Thunderstrike", at: 1791300000 }, { id: "b", via: "mail" }, "c",
        ]);
        const result = await reportDone(CONFIG, entries);

        const [url, init] = global.fetch.mock.calls[0];
        expect(url).toBe("https://example.test:3005/api/ingest/guildbank/handouts");
        expect(init.method).toBe("POST");
        expect(init.headers.Authorization).toBe("Bearer ehl_secret");
        expect(JSON.parse(init.body)).toEqual({
            done: [
                { id: "a", via: "manual", by: "Gemli-Thunderstrike", at: 1791300000 },
                { id: "b", via: "mail" },
                { id: "c", via: "manual" },
            ],
        });
        expect(result).toEqual({
            reported: ["a", "b", "c"], ok: ["a"], duplicate: ["b"], notConfirmed: [], unknown: ["c"], invalid: 0,
        });
    });

    it("teilt in Pakete zu höchstens 200", async () => {
        mockFetch(200, { data: answer() });
        const entries = normalizeDone(Array.from({ length: 450 }, (_, i) => `id${i}`));
        const result = await reportDone(CONFIG, entries);
        const sizes = global.fetch.mock.calls.map(([, init]) => JSON.parse(init.body).done.length);
        expect(MAX_DONE).toBe(200);
        expect(sizes).toEqual([200, 200, 50]);
        expect(result.reported).toHaveLength(450);
    });

    it("nennt bei einem Fehler die schon gemeldeten Pakete und den Status", async () => {
        let call = 0;
        global.fetch = jest.fn(async () => {
            call += 1;
            if (call === 1) return { ok: true, status: 200, text: async () => JSON.stringify({ data: answer() }) };
            return { ok: false, status: 503, text: async () => JSON.stringify({ error: { message: "Wartung" } }) };
        });
        const entries = normalizeDone(Array.from({ length: 250 }, (_, i) => `id${i}`));
        const err = await reportDone(CONFIG, entries).catch((e) => e);
        expect(err).toBeInstanceOf(HandoutsError);
        expect(err.message).toBe("Wartung");
        expect(err.status).toBe(503);
        expect(err.reported).toHaveLength(200);
        expect(err.reported[0]).toBe("id0");
    });

    it("erklärt ein 404 beim Melden", async () => {
        mockFetch(404, { error: { message: "Not found" } });
        await expect(reportDone(CONFIG, normalizeDone(["a"]))).rejects.toThrow(/kennt die Ausgabeliste noch nicht/);
    });

    it("ein Netzwerkfehler hat keinen Status", async () => {
        global.fetch = jest.fn(async () => { throw new Error("ECONNREFUSED"); });
        const err = await reportDone(CONFIG, normalizeDone(["a"])).catch((e) => e);
        expect(err.status).toBeUndefined();
        expect(err.reported).toEqual([]);
        expect(err.message).toMatch(/nicht erreichbar: ECONNREFUSED/);
    });
});
