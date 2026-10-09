"use strict";

// Die Gegenrichtung Server -> Spiel: Lua-Serialisierung, Prüfung des Formats,
// Abruf und das Schreiben in die Addon-Ordner. Die Ordnersuche läuft wie in
// wowPaths.test.js gegen echte Verzeichnisse in einem temporären Ordner.
const fs = require("fs");
const os = require("os");
const path = require("path");
const {
    toLua, luaString, toLatin1, buildCouncilFile, validateCouncil, fetchCouncil, syncCouncil, writeAtomic,
    loadCouncil, wrapV1, cleanCategoryName, countRaiders, CouncilError, COUNCIL_FILE,
} = require("../lib/council");
const { findAddonDirs } = require("../lib/wowPaths");
const { parseSavedVariables } = require("../lib/luaParser");

const CONFIG = { baseUrl: "https://example.test:3005/", token: "ehl_secret", extraRoots: [] };

function payload(over = {}) {
    return {
        format: "eventhelper-council",
        version: 1,
        generatedAt: 1791234567,
        filter: { category: "123", categoryName: "SSC/TK Mittwoch", role: "", bisTier: "t6", bisTierDerived: true },
        categories: [{ id: "123", name: "SSC/TK Mittwoch" }],
        weights: { drought: 50, share: 40, need: 10 },
        avgLootCount: 3.4,
        raiders: [{
            character: "Gemli",
            classFile: "PRIEST",
            specLabel: "Shadow",
            role: "caster",
            need: 82,
            parts: { drought: 100, share: 60, need: 40 },
            lootCount: 2,
            lootTotal: 5,
            otherCount: 1,
            lastAwardAt: 1791000000,
            daysSinceLoot: 12,
            bis: { tier: "t6", source: "wowsims", owned: 9, total: 16, missing: [30000, 30001, 30001] },
            items: [{
                itemId: 30000, itemName: "Name", awardedAt: 1791000000,
                boss: "Lady Vashj", reason: "Main Spec", event: "SSC/TK Mittwoch",
            }],
        }],
        ...over,
    };
}

/** Version 2, wie sie der Server mit ?v=2 liefert: zwei Kategorien, ein
 * Raider in beiden, ein Name mit Emoji. */
function payloadV2(over = {}) {
    const gemli = payload().raiders[0];
    return {
        format: "eventhelper-council",
        version: 2,
        generatedAt: 1791234567,
        weights: { drought: 50, share: 40, need: 10 },
        categories: [
            {
                id: 1234567890,
                name: "🐉 SSC/TK Mittwoch 🔥",
                lootSystem: "lootcouncil",
                filter: { role: "caster", tiers: ["t5"], contents: [], bisTier: "t5", bisTierDerived: false, version: "tbc" },
                instances: [{ id: "ssc", name: "Höhle des Schlangenschreins", short: "SSC", zoneNames: [] }],
                avgLootCount: 3.4,
                raiders: [{ key: "gemli", ...gemli }],
            },
            {
                id: "987",
                name: "Kara Sonntag",
                lootSystem: "lootcouncil",
                filter: { role: "", tiers: [], contents: [], bisTier: "t4", bisTierDerived: true, version: "" },
                instances: [],
                avgLootCount: 1,
                raiders: [
                    { key: "gemli", ...gemli },
                    { key: "naph", character: "Naphfß", role: "healer", need: 10, items: [] },
                ],
            },
        ],
        ...over,
    };
}

/** Version 3, wie sie der Server mit ?v=3 liefert (#670): alle Rollen, Status,
 * Punkte, Zugehörigkeit und die Gewichtung der Kategorie. */
function payloadV3(over = {}) {
    const gemli = payload().raiders[0];
    const weights = {
        drought: 40, share: 30, need: 10, tenure: 20,
        shares: { drought: 0.4, share: 0.3, need: 0.1, tenure: 0.2 }, droughtDays: 30, tenureDays: 90, scope: "global",
    };
    return {
        format: "eventhelper-council",
        version: 3,
        generatedAt: 1791234567,
        weights,
        categories: [{
            id: "c1",
            name: "SSC/TK – Mittwoch 🐉",
            lootSystem: "lootcouncil",
            filter: { role: "", tiers: [], contents: [], bisTier: "t5", bisTierDerived: true, version: "tbc" },
            instances: [{ id: "ssc", name: "Höhle des Schlangenschreins", short: "SSC", zoneNames: [] }],
            avgLootCount: 2,
            avgLootPoints: 2.5,
            weights,
            itemWeights: { classes: { trinket: 2, bisWeapon: 2, weapon: 1.5, set: 1, normal: 1, frequent: 0.5 }, overrides: { 30099: 2.5 } },
            itemClasses: { 30626: "trinket", 30103: "weapon", 30245: "set", 30021: "frequent" },
            raiders: [
                {
                    key: "gemli", ...gemli, parts: { ...gemli.parts, tenure: 50 }, status: "trial", lootPoints: 2.5,
                    droughtDays: 12, droughtBase: 0, joinedAt: 1789000000, tenureDays: 25, bisWeapons: [30103],
                    items: [{ ...gemli.items[0], weight: 1, weightClass: "normal" }],
                },
                {
                    key: "schild", character: "Schild", classFile: "PALADIN", specLabel: "Schutz – Tank", role: "tank", need: 40,
                    parts: { drought: 20, share: 50, need: 50, tenure: 100 }, lootCount: 1, lootTotal: 1, otherCount: 0,
                    lastAwardAt: 1791000000, daysSinceLoot: 3, bis: { tier: "t5", source: "wowsims", owned: 0, total: 0, missing: [] },
                    items: [], status: "", lootPoints: 1.5, droughtDays: 3, droughtBase: 0, joinedAt: 0, tenureDays: 0, bisWeapons: [],
                },
            ],
        }],
        ...over,
    };
}

/** Den erzeugten Lua-Text wieder einlesen — mit demselben Parser, der die
 * SavedVariables liest (Daten, kein Code). */
function readBack(text) {
    return parseSavedVariables(text).EventHelperSync_Council;
}

function response(status, body) {
    return {
        ok: status >= 200 && status < 300,
        status,
        text: async () => (typeof body === "string" ? body : JSON.stringify(body)),
    };
}

function mockFetch(status, body) {
    global.fetch = jest.fn(async () => response(status, body));
}

/** Nacheinander verschiedene Antworten (die letzte gilt für alle weiteren). */
function mockFetchSeq(...answers) {
    let i = 0;
    global.fetch = jest.fn(async () => {
        const [status, body] = answers[Math.min(i, answers.length - 1)];
        i += 1;
        return response(status, body);
    });
}

describe("toLatin1", () => {
    it("ersetzt typografische Zeichen durch ASCII", () => {
        expect(toLatin1("Gruul – Mag — Kara … „Bank“ ‘x’ → ok"))
            .toBe("Gruul - Mag - Kara ... \"Bank\" 'x' -> ok");
    });

    it("lässt Latin-1 wie Umlaute, ß und é stehen", () => {
        expect(toLatin1("Ärger öfter über Straße, Café · ×")).toBe("Ärger öfter über Straße, Café · ×");
    });

    it("macht aus allem anderen genau ein Fragezeichen pro Zeichen", () => {
        expect(toLatin1("Raid 🐉 Ω 漢")).toBe("Raid ? ? ?");
    });

    it("setzt zerlegte Umlaute erst zusammen (NFC)", () => {
        expect(toLatin1("a\u0308")).toBe("ä");
    });

    it("nimmt C1-Steuerzeichen heraus", () => {
        expect(toLatin1("a\u0085b")).toBe("a?b");
    });
});

describe("Lua-Serialisierung", () => {
    it("escapt Backslash, Anführungszeichen, Zeilenumbrüche und Steuerzeichen", () => {
        expect(luaString('a\\b"c\nd\re\tf')).toBe('"a\\\\b\\"c\\nd\\re\\tf"');
        // immer dreistellig — sonst würde "\1" + "2" als "\12" gelesen
        expect(luaString("\u00012")).toBe('"\\0012"');
        expect(luaString("\u007f")).toBe('"\\127"');
    });

    it("braucht für ]] in Strings nichts Besonderes (doppelte Anführungszeichen)", () => {
        expect(luaString("x]]y[[z")).toBe('"x]]y[[z"');
    });

    it("schreibt Zahlen, Booleans und Arrays als Sequenzen", () => {
        expect(toLua(42)).toBe("42");
        expect(toLua(3.4)).toBe("3.4");
        expect(toLua(-1)).toBe("-1");
        expect(toLua(Infinity)).toBe("0");
        expect(toLua(true)).toBe("true");
        expect(toLua([1, 2, 3])).toBe("{ 1, 2, 3 }");
        expect(toLua([])).toBe("{}");
        expect(toLua({})).toBe("{}");
    });

    it("nimmt Bezeichner als Schlüssel, alles andere als [\"…\"]", () => {
        const lua = toLua({ ok: 1, "two words": 2, end: 3, "1st": 4, ä: 5, _x9: 6 });
        expect(lua).toContain("ok = 1,");
        expect(lua).toContain('["two words"] = 2,');
        expect(lua).toContain('["end"] = 3,');
        expect(lua).toContain('["1st"] = 4,');
        expect(lua).toContain('["ä"] = 5,');
        expect(lua).toContain("_x9 = 6,");
    });

    it("lässt null/undefined in Objekten weg", () => {
        expect(toLua({ a: null, b: undefined, c: 1 })).toBe("{\n  c = 1,\n}");
    });

    it("verschachtelte Arrays und Objekte überstehen den Rückweg unverändert", () => {
        const data = {
            list: [[1, 2], [3, [4, 5]], []],
            objs: [{ a: "x" }, { b: [true, false] }],
            deep: { er: { und: { tiefer: "unten" } } },
        };
        const text = `EventHelperSync_Council = ${toLua(data)}\n`;
        expect(readBack(text)).toEqual(data);
    });

    it("knifflige Strings kommen nach dem Rückweg als Latin-1-Fassung an", () => {
        const tricky = [
            'Er sagte "Hallo" \\o/',
            "Zeile1\nZeile2\r\n\tEingerückt",
            "]]--[[ kein Kommentar ]]",
            "Gruul – „Mag“ …",
            "Bjørn Ærøskøbing",
            "Ende\\",
            "\u0001\u00012\u001f",
        ];
        const text = `EventHelperSync_Council = ${toLua({ tricky })}\n`;
        expect(readBack(text).tricky).toEqual(tricky.map(toLatin1));
    });

    it("baut die ganze Datei mit Kopfzeile und globaler Variable", () => {
        const text = buildCouncilFile(payload(), { syncVersion: "9.9.9", now: new Date("2026-10-05T19:30:00Z") });
        expect(text.split("\n")[0]).toBe(
            "-- Generated by EventHelper Sync 9.9.9 at 2026-10-05T19:30:00.000Z. Do not edit; it is overwritten.",
        );
        expect(text).toMatch(/^EventHelperSync_Council = \{$/m);
        expect(text).toContain("missing = { 30000, 30001, 30001 },");
        const back = readBack(text);
        expect(back.raiders[0].character).toBe("Gemli");
        expect(back.raiders[0].bis.missing).toEqual([30000, 30001, 30001]);
        expect(back.weights).toEqual({ drought: 50, share: 40, need: 10 });
        expect(back.avgLootCount).toBe(3.4);
        // In der Datei steht nichts ausserhalb Latin-1 (der Kopf ist ASCII).
        expect([...text].every((ch) => ch.codePointAt(0) <= 0xff)).toBe(true);
    });

    it("schreibt Namen mit Sonderzeichen spielfest", () => {
        const p = payload();
        p.raiders[0].character = "Naphfß";
        p.raiders[0].items[0].itemName = "Ring – des Phönix …";
        const back = readBack(buildCouncilFile(p));
        expect(back.raiders[0].character).toBe("Naphfß");
        expect(back.raiders[0].items[0].itemName).toBe("Ring - des Phönix ...");
    });
});

describe("validateCouncil", () => {
    it("nimmt Version 1 und Version 2 an", () => {
        const p = payload();
        expect(validateCouncil(p)).toBe(p);
        const p2 = payloadV2();
        expect(validateCouncil(p2)).toBe(p2);
        expect(validateCouncil(payloadV2({ categories: [] })).categories).toEqual([]);
    });

    it("nimmt Version 3 an und lehnt eine kaputte Gewichtung ab", () => {
        const p3 = payloadV3();
        expect(validateCouncil(p3)).toBe(p3);
        const broken = (key, value) => payloadV3({ categories: [{ ...payloadV3().categories[0], [key]: value }] });
        expect(() => validateCouncil(broken("weights", 5))).toThrow(/kaputtes Feld "weights"/);
        expect(() => validateCouncil(broken("itemWeights", []))).toThrow(/itemWeights/);
        expect(() => validateCouncil(broken("itemClasses", "x"))).toThrow(/itemClasses/);
        expect(validateCouncil(broken("itemClasses", null))).toBeTruthy();
    });

    it("lehnt eine höhere Version mit klarer Meldung ab", () => {
        expect(() => validateCouncil(payloadV2({ version: 4 })))
            .toThrow(/Version 4, dieses Sync-Tool kennt nur Version 3.*aktualisieren/);
    });

    it("lehnt Version 2 ohne Kategorien oder mit einer Kategorie ohne Raider ab", () => {
        expect(() => validateCouncil(payloadV2({ categories: null }))).toThrow(/Kategorien-Liste/);
        expect(() => validateCouncil(payloadV2({ categories: [{ id: "1", name: "x" }] }))).toThrow(/Raider-Liste/);
        expect(() => validateCouncil(payloadV2({ categories: [null] }))).toThrow(/Raider-Liste/);
    });

    it("lehnt ein anderes Format ab", () => {
        expect(() => validateCouncil(payload({ format: "eventhelper-loot" }))).toThrow(CouncilError);
        expect(() => validateCouncil(payload({ format: "eventhelper-loot" }))).toThrow(/eventhelper-council/);
    });

    it("lehnt kaputte Versionen und fehlende Raider ab", () => {
        expect(() => validateCouncil(payload({ version: "1" }))).toThrow(/Ungültige Version/);
        expect(() => validateCouncil(payload({ version: 0 }))).toThrow(/Ungültige Version/);
        expect(() => validateCouncil(payload({ raiders: null }))).toThrow(/Raider-Liste/);
        expect(() => validateCouncil(null)).toThrow(/keine Council-Daten/);
        expect(() => validateCouncil([])).toThrow(/keine Council-Daten/);
    });
});

describe("fetchCouncil", () => {
    afterEach(() => {
        delete global.fetch;
    });

    it("fragt per GET mit Bearer-Token und packt { data } aus", async () => {
        mockFetch(200, { data: payload() });
        const data = await fetchCouncil(CONFIG, { category: "123", role: "healer" });
        expect(data.format).toBe("eventhelper-council");
        const [url, init] = global.fetch.mock.calls[0];
        expect(url).toBe("https://example.test:3005/api/ingest/council?category=123&role=healer");
        expect(init.method).toBe("GET");
        expect(init.headers.Authorization).toBe("Bearer ehl_secret");
        expect(init.body).toBeUndefined();
    });

    it("lässt leere Filter weg", async () => {
        mockFetch(200, { data: payload() });
        await fetchCouncil(CONFIG);
        expect(global.fetch.mock.calls[0][0]).toBe("https://example.test:3005/api/ingest/council");
    });

    it("fragt Version 2 ohne Kategorie und Rolle", async () => {
        mockFetch(200, { data: payloadV2() });
        await fetchCouncil(CONFIG, { v2: true, category: "123", role: "caster" });
        expect(global.fetch.mock.calls[0][0]).toBe("https://example.test:3005/api/ingest/council?v=2");
    });

    it("reicht die Fehlermeldung des Servers weiter", async () => {
        mockFetch(401, { error: { code: "bad_token", message: "API-Token unbekannt oder zurückgezogen." } });
        await expect(fetchCouncil(CONFIG)).rejects.toThrow("API-Token unbekannt oder zurückgezogen.");
    });

    it("erklärt ein 404 als zu alten Server", async () => {
        mockFetch(404, { error: { code: "not_found", message: "Not found" } });
        await expect(fetchCouncil(CONFIG)).rejects.toThrow(/kennt noch keine Council-Daten/);
    });

    it("meldet eine Antwort, die kein JSON ist", async () => {
        mockFetch(502, "<html>Bad Gateway</html>");
        await expect(fetchCouncil(CONFIG)).rejects.toThrow(/Unerwartete Antwort \(HTTP 502\)/);
    });
});

describe("cleanCategoryName", () => {
    it("nimmt Emoji und Trenner vorne und hinten heraus", () => {
        expect(cleanCategoryName("🐉 SSC/TK Mittwoch 🔥")).toBe("SSC/TK Mittwoch");
        expect(cleanCategoryName("🔥 | Kara – Sonntag")).toBe("Kara - Sonntag");
        expect(cleanCategoryName("👍🏽 Gruul‍  &  Mag ❤️")).toBe("Gruul & Mag");
        expect(cleanCategoryName("Raid ✨ Nacht")).toBe("Raid Nacht");
    });

    it("lässt Latin-1 stehen und ersetzt anderes nicht durch ?", () => {
        expect(cleanCategoryName("Höhle Ω Straße")).toBe("Höhle Straße");
        expect(cleanCategoryName("Wer kommt?")).toBe("Wer kommt?");
    });

    it("fällt ohne Namen auf die id zurück", () => {
        expect(cleanCategoryName("🐉🔥", "42")).toBe("Kategorie 42");
        expect(cleanCategoryName(null, 7)).toBe("Kategorie 7");
    });
});

describe("loadCouncil", () => {
    afterEach(() => {
        delete global.fetch;
    });

    it("Version 3: eine Anfrage, Gewichtung je Kategorie bleibt, Namen spielfest", async () => {
        mockFetch(200, { data: payloadV3() });
        const data = await loadCouncil({ ...CONFIG, councilCategory: "123", councilRole: "healer" });
        expect(global.fetch).toHaveBeenCalledTimes(1);
        expect(global.fetch.mock.calls[0][0]).toMatch(/council\?v=3$/);
        expect(data.version).toBe(3);
        expect(data.fromVersion).toBeUndefined();
        const [c1] = data.categories;
        expect(c1.name).toBe("SSC/TK - Mittwoch");
        expect(c1.weights.shares).toEqual({ drought: 0.4, share: 0.3, need: 0.1, tenure: 0.2 });
        expect(c1.itemWeights).toEqual({
            classes: { trinket: 2, bisWeapon: 2, weapon: 1.5, set: 1, normal: 1, frequent: 0.5 }, overrides: { 30099: 2.5 },
        });
        expect(c1.itemClasses).toEqual({ 30626: "trinket", 30103: "weapon", 30245: "set", 30021: "frequent" });
        expect(c1.raiders.map((r) => [r.key, r.role, r.status, r.lootPoints, r.parts.tenure])).toEqual([
            ["gemli", "caster", "trial", 2.5, 50], ["schild", "tank", "", 1.5, 100],
        ]);
        expect(c1.raiders[0]).toMatchObject({ droughtDays: 12, droughtBase: 0, joinedAt: 1789000000, tenureDays: 25, bisWeapons: [30103] });
    });

    it("Version 3: unbekannte Klassen, kaputte Ausnahmen und Status fallen heraus", async () => {
        const base = payloadV3().categories[0];
        mockFetch(200, { data: payloadV3({ categories: [{
            ...base,
            itemWeights: { classes: { trinket: 2, legendary: 9, set: "x" }, overrides: { 30099: 2.5, abc: 1, 5: "y" } },
            itemClasses: { 30626: "trinket", 30627: "override", x: "set" },
            raiders: [{ ...base.raiders[0], status: "pause", bisWeapons: [30103, "x", 0] }],
        }] }) });
        const [c1] = (await loadCouncil(CONFIG)).categories;
        expect(c1.itemWeights).toEqual({ classes: { trinket: 2 }, overrides: { 30099: 2.5 } });
        expect(c1.itemClasses).toEqual({ 30626: "trinket" });
        expect(c1.raiders[0]).toMatchObject({ status: "", bisWeapons: [30103] });
    });

    it("Server mit Version 2: ?v=3 bekommt Version 1, dann ?v=2 - als Version 3 ohne Gewichtung", async () => {
        mockFetchSeq([200, { data: payload() }], [200, { data: payloadV2() }]);
        const data = await loadCouncil({ ...CONFIG, councilCategory: "123", councilRole: "healer" });
        expect(global.fetch).toHaveBeenCalledTimes(2);
        expect(global.fetch.mock.calls[0][0]).toMatch(/council\?v=3$/);
        expect(global.fetch.mock.calls[1][0]).toMatch(/council\?v=2$/);
        expect(data).toMatchObject({ version: 3, fromVersion: 2, weights: { drought: 50, share: 40, need: 10 } });
        expect(data.categories.map((c) => [c.id, c.name])).toEqual([
            ["1234567890", "SSC/TK Mittwoch"], ["987", "Kara Sonntag"],
        ]);
        expect(data.categories[0].filter.role).toBe("caster");
        expect(data.categories[0].instances[0].short).toBe("SSC");
        expect(data.categories[0]).not.toHaveProperty("weights");
        expect(data.categories[0]).not.toHaveProperty("itemWeights");
        expect(data.categories[0]).not.toHaveProperty("itemClasses");
        // Fehlende Raider-Felder: dieselbe Bedeutung wie in Version 2.
        expect(data.categories[0].raiders[0]).toMatchObject({
            status: "", lootPoints: 2, droughtDays: 12, joinedAt: 0, tenureDays: 0, bisWeapons: [], parts: { tenure: 0 },
        });
        expect(data.categories[0].raiders[0]).not.toHaveProperty("droughtBase");
        expect(data.categories[1].raiders[1]).toMatchObject({ lootPoints: 0, droughtDays: 30 });
        expect(countRaiders(data)).toBe(2);
    });

    it("Version 2 auf ?v=3 (ein Zwischenstand) wird genauso verpackt", async () => {
        mockFetch(200, { data: payloadV2() });
        const data = await loadCouncil(CONFIG);
        expect(global.fetch).toHaveBeenCalledTimes(1);
        expect(data).toMatchObject({ version: 3, fromVersion: 2 });
    });

    it("Version 2 ohne Loot-Council-Kategorie: leere Liste", async () => {
        mockFetch(200, { data: payloadV2({ categories: [] }) });
        const data = await loadCouncil(CONFIG);
        expect(data.categories).toEqual([]);
        expect(countRaiders(data)).toBe(0);
    });

    it("älterer Server (Version 1 auf ?v=3 und ?v=2): fragt mit Kategorie und Rolle nach und verpackt", async () => {
        mockFetchSeq(
            [200, { data: payload({ filter: { category: "1" } }) }],
            [200, { data: payload({ filter: { category: "1" } }) }],
            [200, { data: payload() }],
        );
        const data = await loadCouncil({ ...CONFIG, councilCategory: "123", councilRole: "caster" });
        expect(global.fetch).toHaveBeenCalledTimes(3);
        expect(global.fetch.mock.calls[2][0]).toMatch(/council\?category=123&role=caster$/);
        expect(data).toMatchObject({ format: "eventhelper-council", version: 3, fromVersion: 1, generatedAt: 1791234567 });
        expect(data.categories).toHaveLength(1);
        expect(data.categories[0]).toMatchObject({
            id: "123", name: "SSC/TK Mittwoch", lootSystem: "lootcouncil", instances: [], avgLootCount: 3.4,
            filter: { role: "", bisTier: "t6", bisTierDerived: true, tiers: [] },
        });
        expect(data.categories[0].raiders[0].character).toBe("Gemli");
    });

    it("älterer Server ohne gespeicherte Kategorie: die erste Antwort reicht", async () => {
        mockFetch(200, { data: payload({ filter: {} }) });
        const data = await loadCouncil(CONFIG);
        expect(global.fetch).toHaveBeenCalledTimes(2);
        expect(data.categories[0]).toMatchObject({ id: "", name: "Alle Raids" });
        expect(data.categories[0].raiders[0]).toMatchObject({ lootPoints: 2, status: "" });
    });

    it("404 auf ?v=3 und ?v=2: die alte Anfrage", async () => {
        mockFetchSeq([404, { error: { message: "Not found" } }], [404, { error: { message: "Not found" } }], [200, { data: payload() }]);
        const data = await loadCouncil({ ...CONFIG, councilCategory: "123" });
        expect(global.fetch.mock.calls[2][0]).toMatch(/council\?category=123$/);
        expect(data.categories[0].id).toBe("123");
    });

    it("404 auf beides: der Server kennt keine Council-Daten", async () => {
        mockFetch(404, { error: { message: "Not found" } });
        await expect(loadCouncil(CONFIG)).rejects.toThrow(/kennt noch keine Council-Daten/);
    });

    it("lehnt Version 4 ab, ohne die alte Anfrage zu versuchen", async () => {
        mockFetch(200, { data: payloadV2({ version: 4 }) });
        await expect(loadCouncil(CONFIG)).rejects.toThrow(/Version 4/);
        expect(global.fetch).toHaveBeenCalledTimes(1);
    });

    it("andere Fehler auf ?v=2 gehen durch", async () => {
        mockFetch(401, { error: { code: "bad_token", message: "API-Token unbekannt oder zurückgezogen." } });
        await expect(loadCouncil(CONFIG)).rejects.toThrow("API-Token unbekannt");
        expect(global.fetch).toHaveBeenCalledTimes(1);
    });

    it("wrapV1 nimmt fehlende Felder hin", () => {
        const data = wrapV1({ format: "eventhelper-council", version: 1, raiders: [] });
        expect(data.categories[0]).toMatchObject({ id: "", name: "Alle Raids", raiders: [] });
    });
});

describe("Addon-Ordner finden und beschreiben", () => {
    let tmp;
    let wow;

    /** Ein WoW-Ordner mit Addon in _anniversary_ und _classic_beta_, ohne in
     * _classic_era_ (dort gibt es AddOns, aber nicht dieses). */
    beforeEach(() => {
        tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ehs-council-"));
        wow = path.join(tmp, "World of Warcraft");
        for (const flavor of ["_anniversary_", "_classic_beta_"]) {
            fs.mkdirSync(path.join(wow, flavor, "Interface", "AddOns", "EventHelperSync"), { recursive: true });
        }
        fs.mkdirSync(path.join(wow, "_classic_era_", "Interface", "AddOns", "Gargul"), { recursive: true });
        fs.mkdirSync(path.join(wow, "_retail_", "WTF"), { recursive: true });
    });

    afterEach(() => {
        fs.rmSync(tmp, { recursive: true, force: true });
        delete global.fetch;
    });

    it("findet jede Variante mit installiertem Addon", () => {
        const found = findAddonDirs([], { roots: [wow] });
        expect(found.map((f) => f.flavor).sort()).toEqual(["_anniversary_", "_classic_beta_"]);
        for (const f of found) expect(f.dir.endsWith(path.join("Interface", "AddOns", "EventHelperSync"))).toBe(true);
    });

    it("versteht auch einen Zeiger direkt auf den Varianten-Ordner", () => {
        const found = findAddonDirs([], { roots: [path.join(wow, "_anniversary_")] });
        expect(found.map((f) => f.flavor)).toEqual(["_anniversary_"]);
    });

    it("nimmt die Variante einer von Hand festgelegten Addon-Datei mit", () => {
        const other = path.join(tmp, "Woanders", "_anniversary_");
        fs.mkdirSync(path.join(other, "Interface", "AddOns", "EventHelperSync"), { recursive: true });
        const sv = path.join(other, "WTF", "Account", "PULSE", "SavedVariables", "EventHelperSync.lua");
        const found = findAddonDirs([], { roots: [], savedVariablesPath: sv });
        expect(found).toEqual([{ flavor: "_anniversary_", dir: path.join(other, "Interface", "AddOns", "EventHelperSync") }]);
    });

    it("zählt denselben Ordner nur einmal", () => {
        const found = findAddonDirs([], { roots: [wow, wow, path.join(wow, "_anniversary_")] });
        expect(found).toHaveLength(2);
    });

    it("liefert nichts für einen Ordner ohne Installation", () => {
        expect(findAddonDirs([], { roots: [path.join(tmp, "gibtsnicht")] })).toEqual([]);
    });

    it("schreibt CouncilData.lua in jeden gefundenen Ordner und legt keinen an", async () => {
        mockFetch(200, { data: payloadV2() });
        const result = await syncCouncil(CONFIG, { roots: [wow], now: new Date("2026-10-05T19:30:00Z") });

        expect(result.categories).toBe(2);
        expect(result.raiders).toBe(2);
        expect(result.errors).toEqual([]);
        expect(result.files).toHaveLength(2);
        for (const flavor of ["_anniversary_", "_classic_beta_"]) {
            const file = path.join(wow, flavor, "Interface", "AddOns", "EventHelperSync", COUNCIL_FILE);
            const text = fs.readFileSync(file, "utf8");
            const back = readBack(text);
            expect(back.version).toBe(3);
            expect(back.categories.map((c) => c.name)).toEqual(["SSC/TK Mittwoch", "Kara Sonntag"]);
            expect(back.categories[0].id).toBe("1234567890");
            expect(back.categories[0].filter.tiers).toEqual(["t5"]);
            expect(back.categories[0].instances[0].name).toBe("Höhle des Schlangenschreins");
            expect(back.categories[1].raiders[0].character).toBe("Gemli");
            expect([...text].every((ch) => ch.codePointAt(0) <= 0xff)).toBe(true);
        }
        // Keine Addon-Ordner erfunden, keine Reste der atomaren Schreibweise.
        expect(fs.existsSync(path.join(wow, "_classic_era_", "Interface", "AddOns", "EventHelperSync"))).toBe(false);
        expect(fs.existsSync(path.join(wow, "_retail_", "Interface"))).toBe(false);
        const dir = path.join(wow, "_anniversary_", "Interface", "AddOns", "EventHelperSync");
        expect(fs.readdirSync(dir)).toEqual([COUNCIL_FILE]);
    });

    it("überschreibt eine vorhandene Datei", async () => {
        const file = path.join(wow, "_anniversary_", "Interface", "AddOns", "EventHelperSync", COUNCIL_FILE);
        fs.writeFileSync(file, "-- Platzhalter\n");
        mockFetch(200, { data: payload() });
        await syncCouncil(CONFIG, { roots: [wow] });
        expect(fs.readFileSync(file, "utf8")).toMatch(/^-- Generated by EventHelper Sync/);
    });

    it("schreibt nichts, wenn der Server eine neuere Version liefert", async () => {
        mockFetch(200, { data: payloadV2({ version: 4 }) });
        await expect(syncCouncil(CONFIG, { roots: [wow] })).rejects.toThrow(/Version 4/);
        const dir = path.join(wow, "_anniversary_", "Interface", "AddOns", "EventHelperSync");
        expect(fs.readdirSync(dir)).toEqual([]);
    });

    it("schreibt auch ohne Loot-Council-Kategorie eine gültige Datei", async () => {
        mockFetch(200, { data: payloadV2({ categories: [] }) });
        const result = await syncCouncil(CONFIG, { roots: [wow] });
        expect(result).toMatchObject({ categories: 0, raiders: 0 });
        const file = path.join(wow, "_anniversary_", "Interface", "AddOns", "EventHelperSync", COUNCIL_FILE);
        const back = readBack(fs.readFileSync(file, "utf8"));
        expect(back.version).toBe(3);
        // Eine leere Lua-Tabelle liest der Parser als leeres Objekt oder Array.
        expect(Object.keys(back.categories)).toHaveLength(0);
    });

    it("älterer Server: Kategorie und Rolle aus der Konfiguration, geschrieben als Version 3", async () => {
        mockFetch(200, { data: payload() });
        const result = await syncCouncil({ ...CONFIG, councilCategory: "123", councilRole: "caster" }, { roots: [wow] });
        expect(global.fetch.mock.calls[0][0]).toMatch(/council\?v=3$/);
        expect(global.fetch.mock.calls[1][0]).toMatch(/council\?v=2$/);
        expect(global.fetch.mock.calls[2][0]).toMatch(/council\?category=123&role=caster$/);
        expect(result).toMatchObject({ categories: 1, raiders: 1 });
        const file = path.join(wow, "_anniversary_", "Interface", "AddOns", "EventHelperSync", COUNCIL_FILE);
        const back = readBack(fs.readFileSync(file, "utf8"));
        expect(back).toMatchObject({ version: 3, fromVersion: 1 });
        expect(back.categories[0].raiders[0].character).toBe("Gemli");
    });

    it("Version 3: Gewichtung, Item-Klassen (Item-IDs als Schlüssel) und Status kommen im Lua an", async () => {
        mockFetch(200, { data: payloadV3() });
        await syncCouncil(CONFIG, { roots: [wow] });
        const file = path.join(wow, "_anniversary_", "Interface", "AddOns", "EventHelperSync", COUNCIL_FILE);
        const text = fs.readFileSync(file, "utf8");
        expect(text).toContain('["30626"] = "trinket"');
        expect(text).toContain('["30099"] = 2.5');
        const back = readBack(text);
        expect(back).toMatchObject({ version: 3 });
        expect(back.categories[0]).toMatchObject({
            name: "SSC/TK - Mittwoch",
            weights: { tenure: 20, shares: { tenure: 0.2 }, tenureDays: 90 },
            itemWeights: { classes: { frequent: 0.5 } },
        });
        expect(back.categories[0].raiders[1]).toMatchObject({ role: "tank", specLabel: "Schutz - Tank", status: "" });
        expect([...text].every((ch) => ch.codePointAt(0) <= 0xff)).toBe(true);
    });

    it("writeAtomic räumt die Zwischendatei auf, wenn das Ziel nicht beschreibbar ist", () => {
        // Ein Ordner an der Stelle der Datei: rename schlägt fehl.
        const dir = path.join(wow, "_anniversary_", "Interface", "AddOns", "EventHelperSync");
        fs.mkdirSync(path.join(dir, COUNCIL_FILE));
        expect(() => writeAtomic(path.join(dir, COUNCIL_FILE), "x")).toThrow();
        expect(fs.readdirSync(dir)).toEqual([COUNCIL_FILE]);
    });
});
