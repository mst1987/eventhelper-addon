"use strict";

const { parseSavedVariables, LuaParseError } = require("../lib/luaParser");

describe("luaParser", () => {
    describe("Werte", () => {
        it("liest Zahlen, auch negative und Kommazahlen", () => {
            expect(parseSavedVariables("A = 42")).toEqual({ A: 42 });
            expect(parseSavedVariables("A = -7")).toEqual({ A: -7 });
            expect(parseSavedVariables("A = 1.5")).toEqual({ A: 1.5 });
            expect(parseSavedVariables("A = 1e3")).toEqual({ A: 1000 });
            expect(parseSavedVariables("A = 0x1F")).toEqual({ A: 31 });
        });

        it("liest Wahrheitswerte und nil", () => {
            expect(parseSavedVariables("A = true")).toEqual({ A: true });
            expect(parseSavedVariables("A = false")).toEqual({ A: false });
            expect(parseSavedVariables("A = nil")).toEqual({ A: null });
        });

        it("liest Zeichenketten in beiden Anführungszeichen", () => {
            expect(parseSavedVariables('A = "hallo"')).toEqual({ A: "hallo" });
            expect(parseSavedVariables("A = 'hallo'")).toEqual({ A: "hallo" });
        });

        it("löst Escape-Sequenzen auf", () => {
            expect(parseSavedVariables('A = "a\\nb"')).toEqual({ A: "a\nb" });
            expect(parseSavedVariables('A = "a\\tb"')).toEqual({ A: "a\tb" });
            expect(parseSavedVariables('A = "sagt \\"hi\\""')).toEqual({ A: 'sagt "hi"' });
            expect(parseSavedVariables('A = "back\\\\slash"')).toEqual({ A: "back\\slash" });
        });

        it("löst numerische Escapes auf, wie WoW sie für Sonderzeichen schreibt", () => {
            expect(parseSavedVariables('A = "\\65\\66"')).toEqual({ A: "AB" });
            expect(parseSavedVariables('A = "\\x41"')).toEqual({ A: "A" });
        });

        it("liest lange Zeichenketten", () => {
            expect(parseSavedVariables("A = [[roh \\n unescaped]]")).toEqual({ A: "roh \\n unescaped" });
        });

        it("behält UTF-8 unverändert", () => {
            expect(parseSavedVariables('A = "Naphfß-Thunderstrike"')).toEqual({ A: "Naphfß-Thunderstrike" });
        });
    });

    describe("Tabellen", () => {
        it("macht aus rein positionellen Einträgen ein Array", () => {
            expect(parseSavedVariables('A = { 1, 2, "drei" }')).toEqual({ A: [1, 2, "drei"] });
        });

        it("macht aus benannten Schlüsseln ein Objekt", () => {
            expect(parseSavedVariables('A = { ["x"] = 1, ["y"] = 2 }')).toEqual({ A: { x: 1, y: 2 } });
        });

        it("versteht auch nackte Bezeichner als Schlüssel", () => {
            expect(parseSavedVariables("A = { x = 1, y = 2 }")).toEqual({ A: { x: 1, y: 2 } });
        });

        it("versteht numerische Schlüssel in Klammern", () => {
            expect(parseSavedVariables('A = { [1] = "a", [2] = "b" }')).toEqual({ A: { 1: "a", 2: "b" } });
        });

        it("verschachtelt beliebig tief", () => {
            const lua = 'A = { ["a"] = { ["b"] = { ["c"] = { 1, 2 } } } }';
            expect(parseSavedVariables(lua)).toEqual({ A: { a: { b: { c: [1, 2] } } } });
        });

        it("verträgt ein nachgestelltes Komma", () => {
            expect(parseSavedVariables("A = { 1, 2, }")).toEqual({ A: [1, 2] });
        });

        it("liefert für eine leere Tabelle ein leeres Array", () => {
            expect(parseSavedVariables("A = {}")).toEqual({ A: [] });
        });
    });

    describe("Kommentare", () => {
        // WoW hängt hinter jeden Listeneintrag ein "-- [n]".
        it("überspringt Zeilenkommentare, wie WoW sie schreibt", () => {
            const lua = 'A = {\n\t"x", -- [1]\n\t"y", -- [2]\n}';
            expect(parseSavedVariables(lua)).toEqual({ A: ["x", "y"] });
        });

        it("überspringt Blockkommentare", () => {
            expect(parseSavedVariables("A = --[[ weg ]] 5")).toEqual({ A: 5 });
        });

        // Ein "-" leitet auch eine negative Zahl ein — das darf nicht als
        // Kommentaranfang durchgehen.
        it("verwechselt ein Minus nicht mit einem Kommentar", () => {
            expect(parseSavedVariables("A = { -1, -2 }")).toEqual({ A: [-1, -2] });
        });
    });

    describe("mehrere Variablen", () => {
        it("liest alle Zuweisungen der Datei", () => {
            const lua = 'A = 1\nB = "zwei"\nC = { x = 3 }';
            expect(parseSavedVariables(lua)).toEqual({ A: 1, B: "zwei", C: { x: 3 } });
        });
    });

    describe("Fehler", () => {
        it("meldet eine nicht abgeschlossene Tabelle", () => {
            expect(() => parseSavedVariables("A = { 1, 2")).toThrow(LuaParseError);
        });

        it("meldet eine nicht abgeschlossene Zeichenkette", () => {
            expect(() => parseSavedVariables('A = "offen')).toThrow(LuaParseError);
        });

        it("meldet ein fehlendes Gleichheitszeichen", () => {
            expect(() => parseSavedVariables("A 5")).toThrow(LuaParseError);
        });

        it("nennt die Position, damit eine kaputte Datei auffindbar ist", () => {
            let error;
            try {
                parseSavedVariables("A = { 1, 2");
            } catch (e) {
                error = e;
            }
            expect(error.message).toMatch(/Position \d+/);
        });
    });

    // Der eigentliche Ernstfall: genau so, wie WoW die Datei schreibt —
    // Tabs, ["key"]-Schlüssel, "-- [n]"-Kommentare, abschliessendes Komma.
    describe("echte SavedVariables-Datei", () => {
        const REAL = `
EventHelperSyncDB = {
\t["settings"] = {
\t\t["lookbackDays"] = 21,
\t\t["sessionGapHours"] = 6,
\t\t["debug"] = false,
\t},
\t["lastBuild"] = 1784581200,
\t["zones"] = {
\t\t{
\t\t\t["name"] = "Serpentshrine Cavern",
\t\t\t["at"] = 1784574000,
\t\t\t["until_"] = 1784581200,
\t\t}, -- [1]
\t},
\t["export"] = {
\t\t["format"] = "eventhelper-loot",
\t\t["version"] = 1,
\t\t["generatedAt"] = 1784581200,
\t\t["realm"] = "Thunderstrike",
\t\t["reporter"] = "Gemli-Thunderstrike",
\t\t["client"] = {
\t\t\t["addon"] = "1.0.0",
\t\t\t["sync"] = "",
\t\t},
\t\t["sessions"] = {
\t\t\t{
\t\t\t\t["sessionId"] = "eh-1784574000-serpentshrine-cavern",
\t\t\t\t["startedAt"] = 1784574000,
\t\t\t\t["endedAt"] = 1784581200,
\t\t\t\t["instance"] = "Serpentshrine Cavern",
\t\t\t\t["items"] = {
\t\t\t\t\t{
\t\t\t\t\t\t["source"] = "rclc",
\t\t\t\t\t\t["rawId"] = "1784574268-1",
\t\t\t\t\t\t["itemId"] = 29920,
\t\t\t\t\t\t["itemName"] = "Phoenix-Ring of Rebirth",
\t\t\t\t\t\t["player"] = "Naphfß-Thunderstrike",
\t\t\t\t\t\t["class"] = "SHAMAN",
\t\t\t\t\t\t["response"] = "Off Spec",
\t\t\t\t\t\t["offspec"] = true,
\t\t\t\t\t\t["boss"] = "Lady Vashj",
\t\t\t\t\t\t["replacedGear"] = {
\t\t\t\t\t\t\t"Ancestral Ring of Conquest", -- [1]
\t\t\t\t\t\t},
\t\t\t\t\t\t["awardedAt"] = 1784574268,
\t\t\t\t\t\t["awardedBy"] = "Gemli-Thunderstrike",
\t\t\t\t\t\t["votes"] = 1,
\t\t\t\t\t}, -- [1]
\t\t\t\t\t{
\t\t\t\t\t\t["source"] = "gargul",
\t\t\t\t\t\t["rawId"] = "abc123",
\t\t\t\t\t\t["itemId"] = 30242,
\t\t\t\t\t\t["itemName"] = "",
\t\t\t\t\t\t["player"] = "Keslight",
\t\t\t\t\t\t["offspec"] = false,
\t\t\t\t\t\t["replacedGear"] = {
\t\t\t\t\t\t},
\t\t\t\t\t\t["awardedAt"] = 1784574375,
\t\t\t\t\t\t["gdkpCost"] = 15000,
\t\t\t\t\t}, -- [2]
\t\t\t\t},
\t\t\t}, -- [1]
\t\t},
\t},
}
`;

        it("liest sie vollständig", () => {
            const db = parseSavedVariables(REAL).EventHelperSyncDB;
            expect(db.settings).toEqual({ lookbackDays: 21, sessionGapHours: 6, debug: false });
            expect(db.lastBuild).toBe(1784581200);
            expect(db.zones).toHaveLength(1);
            expect(db.zones[0].name).toBe("Serpentshrine Cavern");
        });

        it("liefert den Envelope in der Form, die der Server erwartet", () => {
            const envelope = parseSavedVariables(REAL).EventHelperSyncDB.export;
            expect(envelope.format).toBe("eventhelper-loot");
            expect(envelope.version).toBe(1);
            expect(envelope.reporter).toBe("Gemli-Thunderstrike");
            expect(envelope.client).toEqual({ addon: "1.0.0", sync: "" });
            expect(envelope.sessions).toHaveLength(1);
        });

        it("liest die Items einer Session als Array, nicht als Objekt", () => {
            const [session] = parseSavedVariables(REAL).EventHelperSyncDB.export.sessions;
            expect(Array.isArray(session.items)).toBe(true);
            expect(session.items).toHaveLength(2);
            expect(session.items[0]).toMatchObject({
                source: "rclc", rawId: "1784574268-1", itemId: 29920,
                player: "Naphfß-Thunderstrike", offspec: true, awardedAt: 1784574268,
            });
            expect(session.items[1]).toMatchObject({ source: "gargul", gdkpCost: 15000 });
        });

        it("macht aus einer leeren replacedGear-Tabelle ein leeres Array", () => {
            const [session] = parseSavedVariables(REAL).EventHelperSyncDB.export.sessions;
            expect(session.items[0].replacedGear).toEqual(["Ancestral Ring of Conquest"]);
            expect(session.items[1].replacedGear).toEqual([]);
        });
    });
});
