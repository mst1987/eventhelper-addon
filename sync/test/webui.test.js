"use strict";

// Der Server wird echt gestartet und über HTTP angesprochen — die Absicherung
// (Schlüssel, kein Token in der Antwort) ist genau das, was sich nicht durch
// Hinsehen prüfen lässt.

jest.mock("../lib/config", () => ({
    load: jest.fn(),
    save: jest.fn(),
    CONFIG_FILE: "C:/fake/.eventhelper-sync.json",
}));
jest.mock("../lib/wowPaths", () => ({
    discover: jest.fn(() => [
        { path: "C:/WoW/_classic_era_/WTF/Account/PULSE/SavedVariables/EventHelperSync.lua", flavor: "_classic_era_", account: "PULSE", mtime: 1 },
    ]),
}));
jest.mock("../lib/uploader", () => ({ fetchRaidStatus: jest.fn() }));

const config = require("../lib/config");
const { fetchRaidStatus } = require("../lib/uploader");
const { createWebUI, safeConfig } = require("../lib/webui");

const CONFIG = {
    baseUrl: "https://example.test:3005",
    token: "ehl_supersecret_value_1234",
    savedVariablesPath: "",
    extraRoots: [],
    pollSeconds: 15,
};

function fakeRunner(over = {}) {
    return {
        state: {
            version: "1.1.0",
            file: "C:/WoW/EventHelperSync.lua",
            fileMtime: 1700000000000,
            sessions: [{ sessionId: "eh-1-ssc", startedAt: 1e12, endedAt: 1e12, instance: "SSC", items: 3 }],
            readError: null,
            lastCheck: 1700000000000,
            lastUpload: null,
            lastError: null,
            uploading: false,
            log: [{ at: 1700000000000, level: "info", text: "los" }],
        },
        config: CONFIG,
        reload: jest.fn(),
        uploadNow: jest.fn(async () => [{ sessionId: "eh-1-ssc", status: "pending", added: 3 }]),
        uploadOne: jest.fn(async () => [{ sessionId: "eh-1-ssc", status: "pending", added: 3 }]),
        testConnection: jest.fn(async () => true),
        stop: jest.fn(),
        ...over,
    };
}

let ui;
let base;
let key;

beforeEach(async () => {
    jest.clearAllMocks();
    config.load.mockReturnValue({ ...CONFIG });
    fetchRaidStatus.mockResolvedValue({ raids: [] });
});

afterEach(() => {
    if (ui) ui.stop();
    ui = null;
});

async function startUI(runner, options) {
    ui = createWebUI(runner, options);
    // Port 0 lässt das Betriebssystem einen freien wählen.
    const url = await ui.start(0);
    const parsed = new URL(url);
    base = `${parsed.protocol}//${parsed.host}`;
    key = parsed.searchParams.get("key");
    return url;
}

const get = (path, k = key) => fetch(`${base}${path}${path.includes("?") ? "&" : "?"}key=${k}`);
const post = (path, body, k = key) => fetch(`${base}${path}?key=${k}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body || {}),
});

describe("safeConfig", () => {
    it("gibt das Token nie heraus, nur seine letzten vier Zeichen", () => {
        const safe = safeConfig(CONFIG);
        expect(safe).not.toHaveProperty("token");
        expect(safe.hasToken).toBe(true);
        expect(safe.tokenHint).toBe("1234");
        expect(JSON.stringify(safe)).not.toContain("supersecret");
    });

    it("meldet ein fehlendes Token als solches", () => {
        const safe = safeConfig({ ...CONFIG, token: "" });
        expect(safe.hasToken).toBe(false);
        expect(safe.tokenHint).toBe("");
    });
});

describe("webui", () => {
    describe("Absicherung", () => {
        it("bindet nur an 127.0.0.1", async () => {
            const url = await startUI(fakeRunner());
            expect(url.startsWith("http://127.0.0.1:")).toBe(true);
        });

        it("würfelt bei jedem Start einen neuen Schlüssel aus", async () => {
            const a = createWebUI(fakeRunner());
            const b = createWebUI(fakeRunner());
            expect(a.key).not.toBe(b.key);
            expect(a.key).toHaveLength(32);
        });

        // Eine fremde Webseite könnte im Hintergrund auf localhost schiessen —
        // ohne den Schlüssel darf sie nichts erfahren und nichts ändern.
        it("weist Aufrufe ohne gültigen Schlüssel ab", async () => {
            await startUI(fakeRunner());
            for (const res of await Promise.all([
                get("/", "falsch"),
                get("/api/state", "falsch"),
                post("/api/settings", { baseUrl: "https://boes.example" }, "falsch"),
                post("/api/upload", {}, "falsch"),
            ])) {
                expect(res.status).toBe(403);
            }
        });

        it("ändert bei abgewiesenem Aufruf nichts", async () => {
            const runner = fakeRunner();
            await startUI(runner);
            await post("/api/settings", { baseUrl: "https://boes.example" }, "falsch");
            await post("/api/upload", {}, "falsch");
            expect(config.save).not.toHaveBeenCalled();
            expect(runner.uploadNow).not.toHaveBeenCalled();
        });
    });

    describe("GET /", () => {
        it("liefert die Seite aus", async () => {
            await startUI(fakeRunner());
            const res = await get("/");
            expect(res.status).toBe(200);
            expect(res.headers.get("content-type")).toMatch(/text\/html/);
            const html = await res.text();
            expect(html).toContain("EventHelper Loot-Sync");
        });

        it("hat das Token nicht im Seitenquelltext", async () => {
            await startUI(fakeRunner());
            const html = await (await get("/")).text();
            expect(html).not.toContain("supersecret");
        });
    });

    describe("GET /api/state", () => {
        it("liefert Stand, Sessions und Verlauf", async () => {
            await startUI(fakeRunner());
            const body = await (await get("/api/state")).json();
            expect(body).toMatchObject({
                version: "1.1.0",
                file: "C:/WoW/EventHelperSync.lua",
                uploading: false,
            });
            expect(body.sessions).toHaveLength(1);
            expect(body.log).toHaveLength(1);
        });

        it("liefert die WoW-Installationen zur Auswahl", async () => {
            await startUI(fakeRunner());
            const body = await (await get("/api/state")).json();
            expect(body.candidates).toEqual([{
                path: "C:/WoW/_classic_era_/WTF/Account/PULSE/SavedVariables/EventHelperSync.lua",
                flavor: "_classic_era_",
                account: "PULSE",
            }]);
        });

        it("gibt das Token auch hier nicht preis", async () => {
            await startUI(fakeRunner());
            const text = await (await get("/api/state")).text();
            expect(text).not.toContain("supersecret");
            expect(JSON.parse(text).config.tokenHint).toBe("1234");
        });
    });

    describe("POST /api/settings", () => {
        it("speichert die geänderten Werte und lädt den Runner neu", async () => {
            const runner = fakeRunner();
            await startUI(runner);
            const res = await post("/api/settings", {
                baseUrl: "https://neu.example:3005",
                token: "",
                savedVariablesPath: "C:/anders/EventHelperSync.lua",
                pollSeconds: 30,
            });
            expect(res.status).toBe(200);
            expect(config.save).toHaveBeenCalledWith(expect.objectContaining({
                baseUrl: "https://neu.example:3005",
                savedVariablesPath: "C:/anders/EventHelperSync.lua",
                pollSeconds: 30,
            }));
            expect(runner.reload).toHaveBeenCalled();
        });

        // Sonst wäre das Token weg, sobald jemand nur den Port ändert.
        it("behält das gespeicherte Token, wenn das Feld leer bleibt", async () => {
            await startUI(fakeRunner());
            await post("/api/settings", { baseUrl: "https://neu.example", token: "" });
            expect(config.save.mock.calls[0][0].token).toBe(CONFIG.token);
        });

        it("übernimmt ein neu eingetragenes Token", async () => {
            await startUI(fakeRunner());
            await post("/api/settings", { baseUrl: "https://neu.example", token: "ehl_ganzneu" });
            expect(config.save.mock.calls[0][0].token).toBe("ehl_ganzneu");
        });

        it("schneidet abschliessende Schrägstriche von der Adresse ab", async () => {
            await startUI(fakeRunner());
            await post("/api/settings", { baseUrl: "https://neu.example:3005///" });
            expect(config.save.mock.calls[0][0].baseUrl).toBe("https://neu.example:3005");
        });

        it("hält das Prüfintervall in vernünftigen Grenzen", async () => {
            await startUI(fakeRunner());
            await post("/api/settings", { baseUrl: "x", pollSeconds: 1 });
            expect(config.save.mock.calls[0][0].pollSeconds).toBe(5);
            config.save.mockClear();
            await post("/api/settings", { baseUrl: "x", pollSeconds: 99999 });
            expect(config.save.mock.calls[0][0].pollSeconds).toBe(600);
        });
    });

    describe("POST /api/upload", () => {
        it("stösst einen Upload an und gibt das Ergebnis zurück", async () => {
            const runner = fakeRunner();
            await startUI(runner);
            const body = await (await post("/api/upload")).json();
            expect(runner.uploadNow).toHaveBeenCalled();
            expect(body.results).toEqual([{ sessionId: "eh-1-ssc", status: "pending", added: 3 }]);
        });

        it("reicht einen Fehler als lesbare Meldung durch", async () => {
            const runner = fakeRunner({
                uploadNow: jest.fn(async () => { throw new Error("Server nicht erreichbar"); }),
            });
            await startUI(runner);
            const res = await post("/api/upload");
            expect(res.status).toBe(500);
            expect((await res.json()).error).toBe("Server nicht erreichbar");
        });
    });

    describe("POST /api/test", () => {
        it("prüft die Verbindung", async () => {
            const runner = fakeRunner();
            await startUI(runner);
            expect((await post("/api/test")).status).toBe(200);
            expect(runner.testConnection).toHaveBeenCalled();
        });

        it("meldet ein abgelehntes Token", async () => {
            const runner = fakeRunner({
                testConnection: jest.fn(async () => { throw new Error("API-Token unbekannt oder zurückgezogen."); }),
            });
            await startUI(runner);
            const res = await post("/api/test");
            expect(res.status).toBe(500);
            expect((await res.json()).error).toMatch(/Token unbekannt/);
        });
    });

    describe("GET /api/raids", () => {
        it("gibt die Raid-Liste vom Server weiter", async () => {
            fetchRaidStatus.mockResolvedValue({ raids: [{ eventId: "e1", status: "ready" }] });
            const runner = fakeRunner();
            await startUI(runner);

            const res = await get("/api/raids");

            expect(res.status).toBe(200);
            expect(fetchRaidStatus).toHaveBeenCalledWith(runner.config, runner.state.sessions);
            expect((await res.json()).raids).toEqual([{ eventId: "e1", status: "ready" }]);
        });

        // Das Token bleibt im Node-Prozess — nur der letzte Teil der Antwort
        // geht an die Seite, nie die Anfrage an den echten Server selbst.
        it("reicht einen Fehler vom echten Server als lesbare Meldung durch", async () => {
            fetchRaidStatus.mockRejectedValue(new Error("https://example.test nicht erreichbar: ECONNREFUSED"));
            await startUI(fakeRunner());
            const res = await get("/api/raids");
            expect(res.status).toBe(500);
            expect((await res.json()).error).toMatch(/nicht erreichbar/);
        });
    });

    describe("POST /api/upload-one", () => {
        it("lädt genau die angegebene Session hoch", async () => {
            const runner = fakeRunner();
            await startUI(runner);

            const res = await post("/api/upload-one", { sessionId: "eh-1-ssc" });

            expect(res.status).toBe(200);
            expect(runner.uploadOne).toHaveBeenCalledWith("eh-1-ssc");
            expect((await res.json()).results).toEqual([{ sessionId: "eh-1-ssc", status: "pending", added: 3 }]);
        });

        it("verlangt eine sessionId", async () => {
            const runner = fakeRunner();
            await startUI(runner);
            const res = await post("/api/upload-one", {});
            expect(res.status).toBe(400);
            expect(runner.uploadOne).not.toHaveBeenCalled();
        });

        it("reicht einen Fehler als lesbare Meldung durch", async () => {
            const runner = fakeRunner({
                uploadOne: jest.fn(async () => { throw new Error("Server nicht erreichbar"); }),
            });
            await startUI(runner);
            const res = await post("/api/upload-one", { sessionId: "eh-1-ssc" });
            expect(res.status).toBe(500);
            expect((await res.json()).error).toBe("Server nicht erreichbar");
        });
    });

    describe("POST /api/quit", () => {
        it("stoppt den Runner und antwortet, bevor onQuit aufgerufen wird", async () => {
            const runner = fakeRunner();
            const onQuit = jest.fn();
            await startUI(runner, { onQuit });

            const res = await post("/api/quit");

            expect(res.status).toBe(200);
            expect(runner.stop).toHaveBeenCalled();
            // onQuit (im echten Betrieb process.exit) darf erst NACH der
            // Antwort kommen — sonst bekäme die Seite sie nie zu sehen.
            expect(onQuit).not.toHaveBeenCalled();
            await new Promise((r) => setTimeout(r, 100));
            expect(onQuit).toHaveBeenCalled();
        });

        it("funktioniert auch ohne onQuit (z.B. im Test ohne echten Prozess)", async () => {
            const runner = fakeRunner();
            await startUI(runner);
            const res = await post("/api/quit");
            expect(res.status).toBe(200);
            expect(runner.stop).toHaveBeenCalled();
        });
    });

    it("antwortet auf unbekannte Pfade mit 404", async () => {
        await startUI(fakeRunner());
        expect((await get("/gibtsnicht")).status).toBe(404);
    });
});
