"use strict";

// createRunner()'s stateful uploadOne() — the click on a single ready raid row
// in the redesigned UI, as opposed to uploadNow()/uploadFile() which sends the
// whole SavedVariables file — plus one regression test for uploadNow() itself
// (see below). runner.test.js keeps testing the pure helpers (whyNothing/
// describe) without any mocking; this is the one place the stateful runner
// itself gets exercised, so config/wowPaths/uploader/fs are all mocked here.
jest.mock("../lib/config");
jest.mock("../lib/wowPaths");
jest.mock("../lib/uploader");
jest.mock("fs");

const fs = require("fs");
const config = require("../lib/config");
const wowPaths = require("../lib/wowPaths");
const uploader = require("../lib/uploader");
const { createRunner } = require("../lib/runner");

const CFG = {
    baseUrl: "https://example.test", token: "ehl_secret", savedVariablesPath: "x.lua",
    extraRoots: [], excludedSessions: [], uploadLog: {},
};

beforeEach(() => {
    jest.clearAllMocks();
    config.load.mockReturnValue(CFG);
    config.save.mockImplementation((c) => c);
    wowPaths.discover.mockReturnValue([]);
    fs.existsSync.mockReturnValue(true);
    fs.statSync.mockReturnValue({ mtimeMs: 1 });
    uploader.readEnvelope.mockReturnValue({
        sessions: [{ sessionId: "s1", startedAt: 1, endedAt: 2, instance: "SSC", items: [{ source: "gargul" }] }],
    });
});

describe("createRunner — uploadOne", () => {
    it("lädt genau die angegebene Session hoch und merkt sich das Ergebnis", async () => {
        uploader.uploadOneSession.mockResolvedValue({ results: [{ sessionId: "s1", status: "pending", added: 1 }] });
        const runner = createRunner();
        runner.readState();

        const results = await runner.uploadOne("s1");

        expect(uploader.uploadOneSession).toHaveBeenCalledWith(CFG, "x.lua", "s1");
        expect(results).toEqual([{ sessionId: "s1", status: "pending", added: 1 }]);
        expect(runner.state.lastUpload.results).toEqual(results);
        expect(runner.state.uploading).toBe(false);
        // rememberResults() persists what the server said, for "lastUpload" per Raid-Zeile.
        expect(config.save).toHaveBeenCalledWith(expect.objectContaining({
            uploadLog: expect.objectContaining({ s1: expect.objectContaining({ status: "pending", added: 1 }) }),
        }));
    });

    it("lässt eine unbekannte sessionId ohne Fehler leer laufen", async () => {
        uploader.uploadOneSession.mockResolvedValue({ results: [] });
        const runner = createRunner();
        runner.readState();

        const results = await runner.uploadOne("gibts-nicht");

        expect(results).toEqual([]);
        expect(runner.state.lastUpload).toBeNull();
    });

    it("wirft, wenn keine Addon-Datei gefunden wurde", async () => {
        fs.existsSync.mockReturnValue(false);
        const runner = createRunner();
        runner.readState();

        await expect(runner.uploadOne("s1")).rejects.toThrow(/Keine EventHelperSync\.lua gefunden/);
        expect(uploader.uploadOneSession).not.toHaveBeenCalled();
    });

    it("reicht einen Serverfehler weiter und merkt ihn sich für die Oberfläche", async () => {
        uploader.uploadOneSession.mockRejectedValue(new Error("Server nicht erreichbar"));
        const runner = createRunner();
        runner.readState();

        await expect(runner.uploadOne("s1")).rejects.toThrow("Server nicht erreichbar");
        expect(runner.state.lastError).toMatchObject({ message: "Server nicht erreichbar" });
        expect(runner.state.uploading).toBe(false);
    });
});

// Regression: state.sessions[].lastUpload used to stay stale until the next
// poll tick, because uploadNow() never re-read the file it had just changed
// uploadLog for. The raid list (and the "Alles hochladen" button) should
// reflect a bulk upload's result immediately too, same as uploadOne() above.
describe("createRunner — uploadNow refreshes state.sessions afterwards", () => {
    it("aktualisiert lastUpload der Session sofort nach dem Hochladen", async () => {
        uploader.uploadFile.mockResolvedValue({
            sessions: 1, skipped: 0, results: [{ sessionId: "s1", status: "pending", added: 1 }],
        });
        const runner = createRunner();
        runner.readState();
        expect(runner.state.sessions[0].lastUpload).toBeNull();

        await runner.uploadNow();

        expect(runner.state.sessions[0].lastUpload).toMatchObject({ status: "pending", added: 1 });
    });
});
