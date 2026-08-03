"use strict";

jest.mock("fs");

const fs = require("fs");
const {
    readEnvelope, uploadFile, envelopeForSession, describeResult, UploadError, SYNC_VERSION,
} = require("../lib/uploader");

const CONFIG = { baseUrl: "https://example.test:3005", token: "ehl_secret" };

const session = (over = {}) => ({
    sessionId: "eh-1-ssc",
    startedAt: 1,
    endedAt: 2,
    instance: "Serpentshrine Cavern",
    items: [{ source: "gargul", rawId: "c1", itemId: 30242, player: "Foo", awardedAt: 1 }],
    ...over,
});

/** Eine SavedVariables-Datei mit dem gegebenen Envelope, als Lua-Text. */
function savedVariables(envelope) {
    const lua = (value) => {
        if (Array.isArray(value)) return `{${value.map((v) => `${lua(v)},`).join("")}}`;
        if (value && typeof value === "object") {
            return `{${Object.entries(value).map(([k, v]) => `["${k}"]=${lua(v)},`).join("")}}`;
        }
        if (typeof value === "string") return `"${value}"`;
        if (typeof value === "boolean") return value ? "true" : "false";
        return String(value);
    };
    return `EventHelperSyncDB = ${lua({ export: envelope })}`;
}

const ENVELOPE = {
    format: "eventhelper-loot",
    version: 1,
    generatedAt: 100,
    realm: "Thunderstrike",
    reporter: "Gemli-Thunderstrike",
    client: { addon: "1.0.0", sync: "" },
    sessions: [session()],
};

function mockFetchOk(data) {
    global.fetch = jest.fn(async () => ({
        ok: true,
        status: 201,
        text: async () => JSON.stringify({ data }),
    }));
}

beforeEach(() => {
    jest.clearAllMocks();
});

describe("readEnvelope", () => {
    it("holt den Envelope aus der Datei", () => {
        fs.readFileSync.mockReturnValue(savedVariables(ENVELOPE));
        expect(readEnvelope("x.lua")).toMatchObject({ format: "eventhelper-loot", version: 1 });
    });

    it("liefert null, wenn das Addon noch nichts geschrieben hat", () => {
        fs.readFileSync.mockReturnValue("EventHelperSyncDB = { [\"settings\"] = { } }");
        expect(readEnvelope("x.lua")).toBeNull();
    });

    it("liefert null bei einer fremden SavedVariables-Datei", () => {
        fs.readFileSync.mockReturnValue('SomeOtherDB = { ["x"] = 1 }');
        expect(readEnvelope("x.lua")).toBeNull();
    });
});

describe("envelopeForSession", () => {
    it("verpackt genau eine Session und trägt die Sync-Version ein", () => {
        const payload = envelopeForSession(ENVELOPE, session({ sessionId: "nur-die" }));
        expect(payload.sessions).toHaveLength(1);
        expect(payload.sessions[0].sessionId).toBe("nur-die");
        expect(payload.client).toEqual({ addon: "1.0.0", sync: SYNC_VERSION });
        // Der Rest des Envelopes bleibt unangetastet.
        expect(payload.reporter).toBe("Gemli-Thunderstrike");
        expect(payload.format).toBe("eventhelper-loot");
    });
});

describe("uploadFile", () => {
    // Eine Anfrage pro Session: das 1-MB-Body-Limit des Servers wird so nie zum
    // Thema, und ein Fehler ist einem Raid-Abend zuzuordnen.
    it("lädt jede Session einzeln hoch", async () => {
        fs.readFileSync.mockReturnValue(savedVariables({
            ...ENVELOPE,
            sessions: [session(), session({ sessionId: "eh-2-tk" })],
        }));
        mockFetchOk({ received: 1, results: [{ sessionId: "x", status: "pending", added: 1 }] });

        await uploadFile(CONFIG, "x.lua");

        expect(global.fetch).toHaveBeenCalledTimes(2);
        const bodies = global.fetch.mock.calls.map((c) => JSON.parse(c[1].body));
        expect(bodies.every((b) => b.sessions.length === 1)).toBe(true);
        expect(bodies.map((b) => b.sessions[0].sessionId)).toEqual(["eh-1-ssc", "eh-2-tk"]);
    });

    it("schickt das Token als Bearer", async () => {
        fs.readFileSync.mockReturnValue(savedVariables(ENVELOPE));
        mockFetchOk({ results: [] });
        await uploadFile(CONFIG, "x.lua");
        const [url, init] = global.fetch.mock.calls[0];
        expect(url).toBe("https://example.test:3005/api/ingest/loot");
        expect(init.headers.Authorization).toBe("Bearer ehl_secret");
    });

    it("verträgt einen abschliessenden Schrägstrich in der Basis-URL", async () => {
        fs.readFileSync.mockReturnValue(savedVariables(ENVELOPE));
        mockFetchOk({ results: [] });
        await uploadFile({ ...CONFIG, baseUrl: "https://example.test:3005///" }, "x.lua");
        expect(global.fetch.mock.calls[0][0]).toBe("https://example.test:3005/api/ingest/loot");
    });

    it("überspringt leere Sessions, statt eine sinnlose Anfrage zu schicken", async () => {
        fs.readFileSync.mockReturnValue(savedVariables({
            ...ENVELOPE,
            sessions: [session({ items: [] }), session({ sessionId: "eh-2-tk" })],
        }));
        mockFetchOk({ results: [] });
        await uploadFile(CONFIG, "x.lua");
        expect(global.fetch).toHaveBeenCalledTimes(1);
    });

    // Die letzte Instanz vor dem Absenden: was hier abgewählt ist, soll den
    // Server gar nicht erst erreichen und folglich auch nicht in seiner Inbox
    // landen, wo es jemand von Hand verwerfen müsste.
    describe("abgewählte Raid-Abende", () => {
        const zwei = () => savedVariables({
            ...ENVELOPE,
            sessions: [session(), session({ sessionId: "eh-2-tk" })],
        });

        it("schickt einen abgewählten Abend nicht", async () => {
            fs.readFileSync.mockReturnValue(zwei());
            mockFetchOk({ results: [] });
            const r = await uploadFile({ ...CONFIG, excludedSessions: ["eh-1-ssc"] }, "x.lua");
            expect(global.fetch).toHaveBeenCalledTimes(1);
            expect(JSON.parse(global.fetch.mock.calls[0][1].body).sessions[0].sessionId).toBe("eh-2-tk");
            expect(r.skipped).toBe(1);
        });

        it("schickt gar nichts, wenn alles abgewählt ist", async () => {
            fs.readFileSync.mockReturnValue(zwei());
            global.fetch = jest.fn();
            const r = await uploadFile({ ...CONFIG, excludedSessions: ["eh-1-ssc", "eh-2-tk"] }, "x.lua");
            expect(global.fetch).not.toHaveBeenCalled();
            expect(r).toMatchObject({ sessions: 2, skipped: 2, results: [] });
        });

        it("schickt alles, wenn nichts abgewählt ist", async () => {
            fs.readFileSync.mockReturnValue(zwei());
            mockFetchOk({ results: [] });
            const r = await uploadFile({ ...CONFIG, excludedSessions: [] }, "x.lua");
            expect(global.fetch).toHaveBeenCalledTimes(2);
            expect(r.skipped).toBe(0);
        });

        it("verträgt eine fehlende Liste in einer alten Konfiguration", async () => {
            fs.readFileSync.mockReturnValue(zwei());
            mockFetchOk({ results: [] });
            const r = await uploadFile(CONFIG, "x.lua");
            expect(global.fetch).toHaveBeenCalledTimes(2);
            expect(r.skipped).toBe(0);
        });

        it("ignoriert eine ID, die es in der Datei gar nicht gibt", async () => {
            fs.readFileSync.mockReturnValue(zwei());
            mockFetchOk({ results: [] });
            const r = await uploadFile({ ...CONFIG, excludedSessions: ["gibts-nicht"] }, "x.lua");
            expect(global.fetch).toHaveBeenCalledTimes(2);
            expect(r.skipped).toBe(0);
        });
    });

    it("sammelt die Antworten aller Sessions ein", async () => {
        fs.readFileSync.mockReturnValue(savedVariables(ENVELOPE));
        mockFetchOk({ results: [{ sessionId: "eh-1-ssc", status: "pending", added: 3 }] });
        const r = await uploadFile(CONFIG, "x.lua");
        expect(r.results).toEqual([{ sessionId: "eh-1-ssc", status: "pending", added: 3 }]);
    });

    it("macht nichts, wenn es noch keinen Export gibt", async () => {
        fs.readFileSync.mockReturnValue("EventHelperSyncDB = { }");
        global.fetch = jest.fn();
        const r = await uploadFile(CONFIG, "x.lua");
        expect(r).toEqual({ sessions: 0, skipped: 0, results: [] });
        expect(global.fetch).not.toHaveBeenCalled();
    });

    describe("Fehler", () => {
        it("reicht die Fehlermeldung des Servers durch", async () => {
            fs.readFileSync.mockReturnValue(savedVariables(ENVELOPE));
            global.fetch = jest.fn(async () => ({
                ok: false,
                status: 401,
                text: async () => JSON.stringify({ error: { code: "bad_token", message: "API-Token unbekannt oder zurückgezogen." } }),
            }));
            await expect(uploadFile(CONFIG, "x.lua"))
                .rejects.toThrow("API-Token unbekannt oder zurückgezogen.");
        });

        it("meldet einen nicht erreichbaren Server verständlich", async () => {
            fs.readFileSync.mockReturnValue(savedVariables(ENVELOPE));
            global.fetch = jest.fn(async () => { throw new Error("ECONNREFUSED"); });
            await expect(uploadFile(CONFIG, "x.lua")).rejects.toThrow(/nicht erreichbar/);
        });

        // Ein Reverse-Proxy, der eine HTML-Fehlerseite ausliefert, darf nicht als
        // "Unexpected token <" enden.
        it("meldet eine Antwort, die kein JSON ist, mit ihrem Anfang", async () => {
            fs.readFileSync.mockReturnValue(savedVariables(ENVELOPE));
            global.fetch = jest.fn(async () => ({
                ok: false, status: 502, text: async () => "<html>Bad Gateway</html>",
            }));
            await expect(uploadFile(CONFIG, "x.lua")).rejects.toThrow(/Unerwartete Antwort \(HTTP 502\)/);
        });

        it("wirft einen UploadError mit Statuscode", async () => {
            fs.readFileSync.mockReturnValue(savedVariables(ENVELOPE));
            global.fetch = jest.fn(async () => ({
                ok: false, status: 403, text: async () => JSON.stringify({ error: { message: "nope" } }),
            }));
            const err = await uploadFile(CONFIG, "x.lua").catch((e) => e);
            expect(err).toBeInstanceOf(UploadError);
            expect(err.status).toBe(403);
        });
    });
});

describe("describeResult", () => {
    it("beschreibt jeden Status, den der Server melden kann", () => {
        expect(describeResult({ status: "pending", added: 2, suggested: "SSC" }))
            .toBe("neu in der Inbox — 2 Item(s), vorgeschlagen: SSC");
        expect(describeResult({ status: "pending", added: 2, suggested: "" }))
            .toBe("neu in der Inbox — 2 Item(s)");
        expect(describeResult({ status: "updated", added: 1, total: 5 }))
            .toBe("Inbox aktualisiert — 1 neue(s) Item(s), jetzt 5");
        expect(describeResult({ status: "appended", added: 1, skipped: 4, eventLabel: "SSC" }))
            .toBe('1 Item(s) direkt zu „SSC" ergänzt (4 bereits vorhanden)');
        expect(describeResult({ status: "dismissed" })).toBe("übersprungen (im Menü verworfen)");
        expect(describeResult({ status: "empty" })).toBe("keine Items");
    });
});
