"use strict";

// Echte Ordner in einem temporären Verzeichnis, kein fs-Mock: die Suche lebt
// von statSync/readdirSync, und ein Mock würde genau das prüfen, was ich beim
// Schreiben angenommen habe — nicht das, was das Dateisystem tut.
const fs = require("fs");
const os = require("os");
const path = require("path");
const wowPaths = require("../lib/wowPaths");

let tmp;

/** Legt einen WoW-Baum an und gibt den Installationsordner zurück. */
function makeWow(root, { flavor = "_classic_era_", accounts = ["PULSE"], withFile = true } = {}) {
    for (const account of accounts) {
        const dir = path.join(root, flavor, "WTF", "Account", account, "SavedVariables");
        fs.mkdirSync(dir, { recursive: true });
        if (withFile) {
            fs.writeFileSync(path.join(dir, "EventHelperSync.lua"), "EventHelperSyncDB = {}\n");
        }
        // Ein anderes Addon liegt immer daneben — es darf nicht verwechselt werden.
        fs.writeFileSync(path.join(dir, "Gargul.lua"), "GargulDB = {}\n");
    }
    return root;
}

beforeEach(() => {
    tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ehs-paths-"));
});

afterEach(() => {
    fs.rmSync(tmp, { recursive: true, force: true });
});

describe("findInRoot", () => {
    it("findet die Datei in einer normalen Installation", () => {
        const wow = makeWow(path.join(tmp, "World of Warcraft"));
        const found = wowPaths.findInRoot(wow);
        expect(found).toHaveLength(1);
        expect(found[0]).toMatchObject({ flavor: "_classic_era_", account: "PULSE" });
        expect(found[0].path.endsWith("EventHelperSync.lua")).toBe(true);
    });

    it("findet alle Accounts", () => {
        const wow = makeWow(path.join(tmp, "World of Warcraft"), { accounts: ["PULSE", "ZWEITER"] });
        expect(wowPaths.findInRoot(wow).map((f) => f.account).sort()).toEqual(["PULSE", "ZWEITER"]);
    });

    it("findet auch _classic_ statt _classic_era_", () => {
        const wow = makeWow(path.join(tmp, "World of Warcraft"), { flavor: "_classic_" });
        expect(wowPaths.findInRoot(wow)).toHaveLength(1);
    });

    // Wer auf den Varianten-Ordner statt auf die Installation zeigt, soll nicht
    // ins Leere laufen.
    it("versteht auch einen Zeiger direkt auf den Varianten-Ordner", () => {
        const wow = makeWow(path.join(tmp, "World of Warcraft"));
        expect(wowPaths.findInRoot(path.join(wow, "_classic_era_"))).toHaveLength(1);
    });

    it("liefert nichts für einen Ordner ohne Installation", () => {
        expect(wowPaths.findInRoot(path.join(tmp, "gibtsnicht"))).toEqual([]);
    });

    it("meldet keine Datei, wenn das Addon nie geladen war", () => {
        const wow = makeWow(path.join(tmp, "World of Warcraft"), { withFile: false });
        expect(wowPaths.findInRoot(wow)).toEqual([]);
    });
});

describe("resolveUserPath", () => {
    // Der Grund für diese Funktion: ein Nutzer, dessen WoW die automatische
    // Suche nicht kannte, musste sonst den exakten Dateipfad kennen.
    let wow;
    let file;

    beforeEach(() => {
        wow = makeWow(path.join(tmp, "World of Warcraft"));
        file = path.join(wow, "_classic_era_", "WTF", "Account", "PULSE", "SavedVariables", "EventHelperSync.lua");
    });

    it("nimmt die Datei selbst", () => {
        expect(wowPaths.resolveUserPath(file).path).toBe(path.normalize(file));
    });

    it("nimmt den SavedVariables-Ordner", () => {
        expect(wowPaths.resolveUserPath(path.dirname(file)).path).toBe(path.normalize(file));
    });

    it("nimmt den Account-Ordner", () => {
        expect(wowPaths.resolveUserPath(path.dirname(path.dirname(file))).path).toBe(path.normalize(file));
    });

    it("nimmt den Varianten-Ordner", () => {
        expect(wowPaths.resolveUserPath(path.join(wow, "_classic_era_")).path).toBe(path.normalize(file));
    });

    it("nimmt den blossen WoW-Ordner — der Normalfall beim Eintippen", () => {
        expect(wowPaths.resolveUserPath(wow).path).toBe(path.normalize(file));
    });

    it("verträgt Anführungszeichen, wie Windows sie beim Kopieren anhängt", () => {
        expect(wowPaths.resolveUserPath(`"${wow}"`).path).toBe(path.normalize(file));
    });

    it("nimmt bei mehreren Accounts den zuletzt geschriebenen", () => {
        const zweit = path.join(wow, "_classic_era_", "WTF", "Account", "ZWEITER", "SavedVariables");
        fs.mkdirSync(zweit, { recursive: true });
        const neuer = path.join(zweit, "EventHelperSync.lua");
        fs.writeFileSync(neuer, "EventHelperSyncDB = {}\n");
        const spaeter = new Date(Date.now() + 60000);
        fs.utimesSync(neuer, spaeter, spaeter);
        expect(wowPaths.resolveUserPath(wow).path).toBe(path.normalize(neuer));
    });

    describe("sagt, was nicht stimmt", () => {
        it("bei leerer Eingabe", () => {
            expect(wowPaths.resolveUserPath("").error).toMatch(/Kein Pfad/);
            expect(wowPaths.resolveUserPath(null).error).toMatch(/Kein Pfad/);
        });

        it("bei einem Pfad, den es nicht gibt", () => {
            expect(wowPaths.resolveUserPath(path.join(tmp, "nixda")).error).toMatch(/existiert nicht/);
        });

        it("bei einer falschen Datei", () => {
            const gargul = path.join(path.dirname(file), "Gargul.lua");
            expect(wowPaths.resolveUserPath(gargul).error).toMatch(/nicht EventHelperSync\.lua.*Gargul\.lua/);
        });

        it("bei einem Ordner ohne die Datei", () => {
            const leer = path.join(tmp, "leer");
            fs.mkdirSync(leer);
            const r = wowPaths.resolveUserPath(leer);
            expect(r.error).toMatch(/keine EventHelperSync\.lua gefunden/);
            expect(r.error).toMatch(/schon einmal geladen/);
        });
    });
});

describe("discover", () => {
    // discover() sucht immer auch die echten Laufwerke ab — auf einem Rechner
    // mit installiertem WoW wären Zusicherungen über die Gesamtzahl von der
    // Umgebung abhängig. Deshalb wird nur betrachtet, was unter tmp liegt.
    const underTmp = (list) => list.filter((f) => f.path.startsWith(path.normalize(tmp)));

    it("findet eine Installation über einen zusätzlich angegebenen Ort", () => {
        const wow = makeWow(path.join(tmp, "Irgendwo", "World of Warcraft"));
        const found = underTmp(wowPaths.discover([wow]));
        expect(found).toHaveLength(1);
        expect(found[0].path.startsWith(path.normalize(wow))).toBe(true);
    });

    it("meldet jede Datei nur einmal, auch wenn ein Ort doppelt genannt wird", () => {
        const wow = makeWow(path.join(tmp, "World of Warcraft"));
        expect(underTmp(wowPaths.discover([wow, wow, wow]))).toHaveLength(1);
    });

    it("sortiert die zuletzt geschriebene nach vorn", () => {
        const a = makeWow(path.join(tmp, "A", "World of Warcraft"));
        const b = makeWow(path.join(tmp, "B", "World of Warcraft"));
        const neuer = path.join(b, "_classic_era_", "WTF", "Account", "PULSE", "SavedVariables", "EventHelperSync.lua");
        const spaeter = new Date(Date.now() + 60000);
        fs.utimesSync(neuer, spaeter, spaeter);
        expect(underTmp(wowPaths.discover([a, b]))[0].path).toBe(path.normalize(neuer));
    });

    // Der Fehler, der dieses Release ausgelöst hat: TBC-Anniversary-Realms
    // liegen unter `_anniversary_`, das in keiner festen Liste stand.
    it("erkennt jeden Varianten-Ordner, auch einen unbekannten", () => {
        const wow = makeWow(path.join(tmp, "World of Warcraft"), { flavor: "_anniversary_" });
        makeWow(wow, { flavor: "_voellig_neu_2029_" });
        const flavors = underTmp(wowPaths.discover([wow])).map((f) => f.flavor).sort();
        expect(flavors).toEqual(["_anniversary_", "_voellig_neu_2029_"]);
    });

    it("verträgt ein # im Account-Namen, wie Battle.net es vergibt", () => {
        const wow = makeWow(path.join(tmp, "World of Warcraft"), {
            flavor: "_anniversary_", accounts: ["405280973#2"],
        });
        expect(underTmp(wowPaths.discover([wow]))[0].account).toBe("405280973#2");
    });
});

describe("searchedRoots", () => {
    // "Nicht gefunden" ohne "wo wurde gesucht" ist eine Sackgasse.
    it("nennt die tatsächlich vorhandenen Suchorte", () => {
        const wow = makeWow(path.join(tmp, "World of Warcraft"));
        const roots = wowPaths.searchedRoots([wow]);
        expect(roots).toContain(path.normalize(wow));
        expect(roots.every((r) => fs.existsSync(r))).toBe(true);
    });

    it("verschluckt einen angegebenen Ort nicht, der gar nicht existiert", () => {
        const roots = wowPaths.searchedRoots([path.join(tmp, "gibtsnicht")]);
        expect(roots).not.toContain(path.join(tmp, "gibtsnicht"));
    });
});
