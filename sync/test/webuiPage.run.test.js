"use strict";

// The client script really runs here (test/pageSandbox.js): every render
// function is called against a state fixture, the update strip is checked for
// each phase of an install, and a throwing section must not stop the others.
// 1.16.4 shipped "SVG_RELOAD is not defined" in tileHtml(); a pure string test
// did not see it, executing the script does.
const { loadPage } = require("./pageSandbox");

const NOW = Date.now();

function update(over = {}) {
    return {
        toolVersion: "1.16.5", canSelfUpdate: true, releasesPage: "https://github.com/x/y/releases",
        checking: false, checkedAt: NOW - 60000, latest: { version: "1.16.6", url: "https://github.com/x/y/releases/tag/v1.16.6", publishedAt: "" },
        toolOutdated: true, addons: [{ label: "TBC Anniversary", dir: "C:/wow", version: "1.16.5" }], available: true,
        installing: false, lastError: null, installError: null, progress: null, lastInstall: null,
        ...over,
    };
}

function state(over = {}) {
    return {
        version: "1.16.5",
        file: "C:/wow/WTF/Account/A/SavedVariables/EventHelperSync.lua",
        fileMtime: NOW - 600000,
        sessions: [{ sessionId: "s1", instance: "Karazhan", items: 3, gargul: 3, rclc: 0, startedAt: NOW - 3600000, excluded: false }],
        readError: null, envelopeMissing: false, lastCheck: NOW - 5000, lastUpload: { at: NOW - 100000 }, lastError: null, uploading: false,
        council: { lastFetch: NOW - 1000, categories: [{ name: "Main", raiders: 25 }], raiders: 25, files: ["C:/x"], generatedAt: Math.floor(NOW / 1000) - 100, changedAt: NOW },
        guildBank: { guild: "Gilde", items: 120, tabs: 6, scannedAt: NOW - 1000, uploaded: true },
        handouts: { lastFetch: NOW - 1000, banks: 1, handouts: 2, files: ["C:/x"], generatedAt: Math.floor(NOW / 1000) - 100, changedAt: NOW },
        log: [{ at: NOW, level: "info", text: "Beobachte Datei" }, { at: NOW, level: "error", text: "Fehler" }], logLimit: 200,
        intervals: null, connection: { ok: true },
        update: update(),
        config: { baseUrl: "https://bot.example", hasToken: true, tokenHint: "abcd", pollSeconds: 15, savedVariablesPath: "" },
        candidates: [{ path: "C:/wow/WTF/Account/A/SavedVariables/EventHelperSync.lua", flavor: "_anniversary_", label: "TBC Anniversary", account: "A" }],
        addonDirs: [{ flavor: "_anniversary_", label: "TBC Anniversary", dir: "C:/wow/Interface/AddOns/EventHelperSync", version: "1.16.5" }],
        searchedRoots: [],
        ...over,
    };
}

const RAIDS = [
    { eventId: "e1", title: "Karazhan", startTime: Math.floor(NOW / 1000) - 7200, status: "ready", matchedSessionId: "s1", gargul: 3, rclc: 0 },
    { eventId: "e2", title: "Gruul", startTime: Math.floor(NOW / 1000) - 86400 * 3, status: "done" },
    { eventId: "e3", title: "Magtheridon", startTime: Math.floor(NOW / 1000) + 86400, status: "upcoming" },
    { eventId: "e4", title: "SSC", startTime: Math.floor(NOW / 1000) - 86400, status: "pending", inboxItems: 4 },
];

async function open(over = {}, extra = {}) {
    const page = loadPage({ state: state(over), raids: RAIDS, ...extra });
    await page.settle();
    return page;
}

describe("Seiten-Skript im Sandkasten", () => {
    it("läuft an, holt Stand und Raids und zeigt die Übersicht ohne Fehler", async () => {
        const page = await open();
        expect(page.consoleErrors).toEqual([]);
        expect(page.requests).toEqual(expect.arrayContaining(["GET /api/state", "GET /api/raids"]));
        expect(page.byId["v-main"].hidden).toBe(false);
        expect(page.byId["v-setup"].hidden).toBe(true);
        expect(page.byId.tiles.innerHTML).toContain("Loot-Council");
        expect(page.byId.rows.innerHTML).toContain("Karazhan");
        expect(page.byId["f-status"].textContent).not.toMatch(/nicht erreichbar/);
    });

    it("ruft jede Render-Funktion einmal auf, in jeder Ansicht", async () => {
        const page = await open();
        const fns = [
            "renderChrome", "renderUpdate", "renderVersionCard", "renderMain", "renderSettings", "renderLog",
            "renderSetup", "renderSetupSteps",
        ];
        for (const fn of fns) {
            expect(() => page.run(fn + "()")).not.toThrow();
        }
        const d = "lastState";
        const g = "buildGroups()";
        for (const call of [
            `renderProblems(${d})`, `renderDataStrip(${d})`, `renderTiles(${d}, ${g})`, `renderRaidNights(${d}, ${g})`,
            `renderMainFooter(${d})`,
        ]) {
            expect(() => page.run(call)).not.toThrow();
        }
        // render() through every view; no section may report a failure.
        for (const view of ["main", "settings", "log"]) {
            page.run(`view = ${JSON.stringify(view)}; render();`);
            expect(page.byId["v-" + view].hidden).toBe(false);
        }
        expect(page.consoleErrors).toEqual([]);
    });

    it("zeigt ohne Adresse und Token die Einrichtung", async () => {
        const page = await open({ config: { baseUrl: "", hasToken: false, tokenHint: "", pollSeconds: 15, savedVariablesPath: "" } });
        expect(page.byId["v-setup"].hidden).toBe(false);
        expect(page.byId["v-main"].hidden).toBe(true);
        expect(page.consoleErrors).toEqual([]);
    });

    it("zeigt Probleme ohne Addon-Datei, ohne zu stolpern", async () => {
        const page = await open({ file: null, sessions: [], council: null, guildBank: null, handouts: null, searchedRoots: ["C:/wow"] });
        expect(page.byId.problems.innerHTML).toContain("Keine EventHelperSync.lua");
        expect(page.consoleErrors).toEqual([]);
    });
});

describe("Update-Leiste", () => {
    const strip = (page) => ({
        hidden: page.byId.upd.hidden,
        title: page.byId["upd-title"].textContent,
        text: page.byId["upd-text"].textContent,
        btn: page.byId["upd-btn"].textContent,
        btnDisabled: page.byId["upd-btn"].disabled,
        dlHidden: page.byId["upd-dl"].hidden,
        err: page.byId.upd.classList.contains("err"),
    });

    it("bietet das Update an", async () => {
        const s = strip(await open());
        expect(s).toMatchObject({ hidden: false, title: "Update auf v1.16.6 verfügbar", btn: "Installieren", btnDisabled: false, dlHidden: true, err: false });
    });

    it("zeigt Fortschritt in Prozent und MB", async () => {
        const mb = 1048576;
        const page = await open({
            update: update({ installing: true, progress: { phase: "exe", step: "download", received: 25 * mb, total: 74 * mb } }),
        });
        expect(strip(page)).toMatchObject({
            title: "Update auf v1.16.6 wird installiert", text: "Lädt herunter … 33 % (25 von 74 MB)", btnDisabled: true,
        });
        expect(page.byId["upd-notes"].hidden).toBe(true);
    });

    it("zeigt Prüfen und Neustart", async () => {
        let page = await open({ update: update({ installing: true, progress: { phase: "exe", step: "verify", received: 5, total: 5 } }) });
        expect(strip(page).text).toBe("Prüfe …");
        page = await open({ update: update({ installing: false, progress: { phase: "restart", step: "install", received: 0, total: 0 } }) });
        expect(strip(page).text).toBe("Starte neu …");
        expect(strip(page).btnDisabled).toBe(true);
    });

    it("bei einem Fehler: Meldung, Erneut versuchen und Neue Version herunterladen", async () => {
        const page = await open({
            update: update({ installing: false, installError: { at: NOW, message: "Download hängt – keine Daten seit 30 s" } }),
        });
        expect(strip(page)).toMatchObject({
            hidden: false, title: "Update fehlgeschlagen", text: "Download hängt – keine Daten seit 30 s",
            btn: "Erneut versuchen", btnDisabled: false, dlHidden: false, err: true,
        });
        // The retry button runs the install again, the other opens the release page.
        expect(page.byId["upd-btn"].textContent).toBe("Erneut versuchen");
    });

    it("hängt nie ewig auf Wird installiert: ohne Bestätigung des Servers endet der Klick nach Sekunden", async () => {
        const page = await open();
        page.run("busy.add('update'); updateClickedAt = Date.now();");
        expect(page.run("isInstallActive()")).toBe(true);
        page.run("updateClickedAt = Date.now() - 6000;");
        expect(page.run("isInstallActive()")).toBe(false);
    });

    it("fragt höchstens einmal pro Sekunde, solange installiert wird", async () => {
        const page = await open({ update: update({ installing: true, progress: { phase: "addon", step: "download", received: 1, total: 2 } }) });
        expect(page.run("pollDelay()")).toBe(1000);
        const idle = await open();
        expect(idle.run("pollDelay()")).toBe(3000);
    });

    it("formatiert MB", async () => {
        const page = await open();
        expect(page.run("progressText({ phase: 'addon', step: 'download', received: 300000, total: 500000 })"))
            .toBe("Lädt herunter … 60 % (0,3 von 0,5 MB)");
        expect(page.run("progressText({ phase: 'exe', step: 'download', received: 3145728, total: 0 })"))
            .toBe("Lädt herunter … 3,0 MB");
    });
});

describe("Isolierte Abschnitte", () => {
    it("ein kaputter Abschnitt zeigt eine kleine Meldung, der Rest wird weiter gezeichnet", async () => {
        const page = await open();
        const rowsBefore = page.byId.rows.innerHTML;
        page.run("tileHtml = () => { throw new Error('boom'); };");
        page.run("lastState = Object.assign({}, lastState, { fileMtime: lastState.fileMtime + 1 }); pickedTab = 'done'; render();");
        // The tiles failed ...
        expect(page.consoleErrors.join("\n")).toMatch(/Kacheln.*boom|boom/);
        const notice = page.byId.tiles._err;
        expect(notice.hidden).toBe(false);
        expect(notice.textContent).toContain("Kacheln");
        expect(notice.textContent).toContain("boom");
        // ... while the raid list, the footer and the update strip still updated.
        expect(page.byId.rows.innerHTML).toContain("Gruul");
        expect(page.byId.rows.innerHTML).not.toBe(rowsBefore);
        expect(page.byId["f-status"].textContent).toMatch(/Addon-Datei geprüft/);
        expect(page.byId["upd-title"].textContent).toContain("1.16.6");
        // A render bug is no connection error.
        expect(page.byId["f-status"].textContent).not.toMatch(/nicht erreichbar/);
    });

    it("die Meldung verschwindet, sobald der Abschnitt wieder klappt", async () => {
        const page = await open();
        page.run("const orig = tileHtml; globalThis.__orig = orig; tileHtml = () => { throw new Error('boom'); }; render();");
        expect(page.byId.tiles._err.hidden).toBe(false);
        page.run("tileHtml = globalThis.__orig; render();");
        expect(page.byId.tiles._err.hidden).toBe(true);
    });

    it("ein Fehler beim Zeichnen landet nicht in der Fusszeile: nur ein Verbindungsfehler", async () => {
        const down = loadPage({ state: state() });
        await down.settle();
        down.ctx.fetch = () => Promise.reject(new Error("Failed to fetch"));
        await down.run("refresh()");
        expect(down.byId["f-status"].textContent).toBe("Oberfläche nicht erreichbar: Failed to fetch");

        const bug = loadPage({ state: state() });
        await bug.settle();
        bug.run("renderChrome = () => { throw new Error('SVG_X is not defined'); };");
        await bug.run("refresh()");
        expect(bug.byId["f-status"].textContent).not.toMatch(/nicht erreichbar/);
    });

    it("render() wirft nie, auch wenn jeder Abschnitt kaputt ist", async () => {
        const page = await open();
        for (const fn of ["renderChrome", "renderUpdate", "renderVersionCard", "renderProblems", "renderDataStrip", "renderTiles",
            "renderRaidNights", "renderMainFooter", "fitWindow"]) {
            page.run(`${fn} = () => { throw new Error('kaputt ${fn}'); };`);
        }
        expect(() => page.run("render()")).not.toThrow();
        expect(page.consoleErrors.length).toBeGreaterThanOrEqual(9);
    });
});

describe("Neustart nach dem Update (Seite)", () => {
    it("Verbindungsabbruch beim Neustart: kein Fehler, das alte Fenster wird geschlossen", async () => {
        const page = await open({ update: update({ progress: { phase: "restart", step: "install", received: 0, total: 0 } }) });
        let closed = 0;
        page.run("window.close = () => { globalThis.__closed = (globalThis.__closed || 0) + 1; };");
        page.ctx.fetch = () => Promise.reject(new Error("Failed to fetch"));
        await page.run("refresh()");
        closed = page.run("globalThis.__closed || 0");
        expect(closed).toBe(1);
        expect(page.byId["f-status"].textContent).toBe("Starte neu …");
    });
});

describe("LevelHelper-Kachel und Modulschalter", () => {
    const lhState = (over = {}) => ({
        show: true, enabled: true, auto: true, found: true, versions: ["forever"], runs: 12, golds: 4, characters: 30, guilds: 1,
        pending: 0, lastUpload: new Date(2020, 2, 7, 21, 5).getTime(), lastResult: null, lastError: null, unsupported: false,
        uploading: false, ...over,
    });
    const tiles = (page) => page.byId.tiles.innerHTML;
    const tile = (over) => open({ levelHelper: lhState(over) });

    it("zeigt Kicker, Wert, letzten Upload und einen grünen Punkt", async () => {
        const page = await tile();
        const html = tiles(page);
        expect(html).toContain(">LevelHelper<");
        expect(html).toContain("12 Runs · 4 Gold");
        expect(html).toContain("Zuletzt hochgeladen 7.3. 21:05");
        expect(html).toMatch(/class="dot good"/);
        expect(html).toContain("data:image/svg+xml;base64,");
        expect(page.consoleErrors).toEqual([]);
        // The other four tiles are still there.
        for (const kicker of ["Loot-Upload", "Loot-Council", "Gildenbank", "Ausgabeliste"]) expect(html).toContain(kicker);
    });

    it("sagt Run im Singular", async () => {
        expect(tiles(await tile({ runs: 1, golds: 0 }))).toContain("1 Run · 0 Gold");
    });

    it("zeigt ohne den Zustand oder bei show: false keine Kachel (älteres Tool, kein LevelHelper)", async () => {
        expect(tiles(await open())).not.toContain("LevelHelper");
        expect(tiles(await tile({ show: false, enabled: false, found: false }))).not.toContain("LevelHelper");
    });

    it("zeigt ausgeschaltet, ohne Daten, wartend, lädt hoch, Fehler und alten Server", async () => {
        expect(tiles(await tile({ enabled: false, auto: false }))).toContain("Ausgeschaltet");
        expect(tiles(await tile({ found: false, auto: false }))).toContain("Keine LevelHelper-Daten");
        const waiting = tiles(await tile({ lastUpload: 0 }));
        expect(waiting).toContain("Wartet auf den ersten Upload");
        expect(waiting).toMatch(/class="dot "/);
        expect(tiles(await tile({ uploading: true }))).toContain("Lädt hoch …");
        const failed = tiles(await tile({ lastError: { at: NOW, message: "Server weg" } }));
        expect(failed).toContain("Server weg");
        expect(failed).toMatch(/class="dot high"/);
        const old = tiles(await tile({ unsupported: true }));
        expect(old).toContain("Server kennt den LevelHelper-Upload noch nicht");
        expect(old).toMatch(/class="dot medium"/);
    });

    it("macht aus dem Zustand eines kaputten Tools keinen Seitenfehler", async () => {
        const page = await tile({ runs: undefined, golds: undefined, versions: undefined, lastUpload: undefined });
        expect(tiles(page)).toContain("0 Runs · 0 Gold");
        expect(page.consoleErrors).toEqual([]);
    });

    describe("Einstellungen", () => {
        const form = (page) => page.byId.settings;

        it("zeigt den Schalter so, wie das Modul gerade steht", async () => {
            let page = await tile();
            page.run("view = 'settings'; render();");
            expect(form(page).lhModule.checked).toBe(true);
            expect(page.byId["lh-hint"].textContent).toContain("automatisch eingeschaltet");
            page = await tile({ enabled: false, auto: false });
            page.run("view = 'settings'; render();");
            expect(form(page).lhModule.checked).toBe(false);
            expect(page.consoleErrors).toEqual([]);
        });

        it("rendert die Einstellungen auch ohne LevelHelper-Zustand", async () => {
            const page = await open();
            page.run("view = 'settings'; render();");
            expect(form(page).lhModule.checked).toBe(false);
            expect(page.byId["lh-hint"].textContent).toBe("");
            expect(page.consoleErrors).toEqual([]);
        });

        async function save(page, touch) {
            if (touch !== undefined) {
                form(page).lhModule.checked = touch;
                const ev = { target: { name: "lhModule" } };
                for (const type of ["input", "change"]) for (const fn of form(page)._listeners[type] || []) fn(ev);
            }
            for (const fn of form(page)._listeners.submit) fn({ preventDefault() {}, target: form(page) });
            await page.settle();
        }

        it("schickt das Modul nur mit, wenn der Schalter bedient wurde (sonst bleibt es automatisch)", async () => {
            const bodies = [];
            const page = await open({ levelHelper: lhState() }, { routes: { "POST /api/settings": (b) => { bodies.push(b); return { ok: true }; } } });
            page.run("view = 'settings'; render();");
            await save(page);
            expect(bodies[0]).not.toHaveProperty("modules");

            page.run("view = 'settings'; render();");
            await save(page, false);
            expect(bodies[1].modules).toEqual({ levelhelper: false });
        });
    });
});
