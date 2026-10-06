"use strict";

// Die Gegenrichtung Server -> Spiel: Lua-Serialisierung, Prüfung des Formats,
// Abruf und das Schreiben in die Addon-Ordner. Die Ordnersuche läuft wie in
// wowPaths.test.js gegen echte Verzeichnisse in einem temporären Ordner.
const fs = require("fs");
const os = require("os");
const path = require("path");
const {
    toLua, luaString, toLatin1, buildCouncilFile, validateCouncil, fetchCouncil, syncCouncil, writeAtomic,
    CouncilError, COUNCIL_FILE,
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

/** Den erzeugten Lua-Text wieder einlesen — mit demselben Parser, der die
 * SavedVariables liest (Daten, kein Code). */
function readBack(text) {
    return parseSavedVariables(text).EventHelperSync_Council;
}

function mockFetch(status, body) {
    global.fetch = jest.fn(async () => ({
        ok: status >= 200 && status < 300,
        status,
        text: async () => (typeof body === "string" ? body : JSON.stringify(body)),
    }));
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
    it("nimmt Version 1 an", () => {
        const p = payload();
        expect(validateCouncil(p)).toBe(p);
    });

    it("lehnt eine höhere Version mit klarer Meldung ab", () => {
        expect(() => validateCouncil(payload({ version: 2 })))
            .toThrow(/Version 2, dieses Sync-Tool kennt nur Version 1.*aktualisieren/);
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
        mockFetch(200, { data: payload() });
        const result = await syncCouncil(CONFIG, { roots: [wow], now: new Date("2026-10-05T19:30:00Z") });

        expect(result.raiders).toBe(1);
        expect(result.errors).toEqual([]);
        expect(result.files).toHaveLength(2);
        for (const flavor of ["_anniversary_", "_classic_beta_"]) {
            const file = path.join(wow, flavor, "Interface", "AddOns", "EventHelperSync", COUNCIL_FILE);
            const text = fs.readFileSync(file, "utf8");
            expect(readBack(text).raiders[0].character).toBe("Gemli");
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
        mockFetch(200, { data: payload({ version: 2 }) });
        await expect(syncCouncil(CONFIG, { roots: [wow] })).rejects.toThrow(/Version 2/);
        const dir = path.join(wow, "_anniversary_", "Interface", "AddOns", "EventHelperSync");
        expect(fs.readdirSync(dir)).toEqual([]);
    });

    it("schickt Kategorie und Rolle aus der Konfiguration mit", async () => {
        mockFetch(200, { data: payload() });
        await syncCouncil({ ...CONFIG, councilCategory: "123", councilRole: "caster" }, { roots: [wow] });
        expect(global.fetch.mock.calls[0][0]).toMatch(/council\?category=123&role=caster$/);
    });

    it("writeAtomic räumt die Zwischendatei auf, wenn das Ziel nicht beschreibbar ist", () => {
        // Ein Ordner an der Stelle der Datei: rename schlägt fehl.
        const dir = path.join(wow, "_anniversary_", "Interface", "AddOns", "EventHelperSync");
        fs.mkdirSync(path.join(dir, COUNCIL_FILE));
        expect(() => writeAtomic(path.join(dir, COUNCIL_FILE), "x")).toThrow();
        expect(fs.readdirSync(dir)).toEqual([COUNCIL_FILE]);
    });
});
