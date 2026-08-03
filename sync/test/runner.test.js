"use strict";

const { whyNothing, describe: describeResult } = require("../lib/runner");

describe("whyNothing", () => {
    // Der Anlass für diese Funktion: "Nichts hochzuladen" allein hat einen
    // Nutzer ratlos zurückgelassen. Jede Stufe der Kette muss sich selbst melden.
    it("nennt eine fehlende Addon-Datei", () => {
        expect(whyNothing({ file: null })).toMatch(/Keine EventHelperSync\.lua gefunden/);
    });

    it("nennt eine unlesbare Datei samt Grund", () => {
        expect(whyNothing({ file: "x.lua", readError: "Nicht abgeschlossene Tabelle (Position 40)" }))
            .toMatch(/nicht lesbar.*Position 40/);
    });

    it("unterscheidet „Datei da, aber noch kein Export“", () => {
        const msg = whyNothing({ file: "x.lua", envelopeMissing: true, sessions: [] });
        expect(msg).toMatch(/noch keinen Export/);
        expect(msg).toMatch(/Upload-Knopf/);
    });

    it("verweist bei leerem Export auf die Diagnose im Spiel", () => {
        const msg = whyNothing({ file: "x.lua", envelopeMissing: false, sessions: [] });
        expect(msg).toMatch(/keinen Raid-Abend gefunden/);
        expect(msg).toMatch(/ehs diag/);
        // Die drei häufigsten Ursachen sollen im Satz stehen.
        expect(msg).toMatch(/Zeitraum/);
        expect(msg).toMatch(/abgewählt/);
    });

    it("erkennt Raid-Abende ohne Items", () => {
        expect(whyNothing({ file: "x.lua", sessions: [{ items: 0 }, { items: 0 }] }))
            .toMatch(/keine Items/);
    });

    it("fällt auf die schlichte Meldung zurück, wenn alles da ist", () => {
        expect(whyNothing({ file: "x.lua", sessions: [{ items: 3 }] })).toBe("Nichts hochzuladen.");
    });
});

describe("describe", () => {
    it("beschreibt jeden Status, den der Server melden kann", () => {
        expect(describeResult({ status: "pending", added: 2, suggested: "SSC" }))
            .toBe("neu in der Inbox — 2 Item(s), vorgeschlagen: SSC");
        expect(describeResult({ status: "updated", added: 1, total: 5 }))
            .toBe("Inbox aktualisiert — 1 neue(s) Item(s), jetzt 5");
        expect(describeResult({ status: "appended", added: 1, skipped: 4, eventLabel: "SSC" }))
            .toBe('1 Item(s) direkt zu „SSC" ergänzt (4 bereits vorhanden)');
        expect(describeResult({ status: "dismissed" })).toBe("übersprungen (im Menü verworfen)");
        expect(describeResult({ status: "empty" })).toBe("keine Items");
    });
});
