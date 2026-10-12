"use strict";

// The hand-over after a self-update (lib/restart.js): the old instance must
// release the single-instance slot before the new .exe starts, wait until the
// new one answers, and only then close its server and exit - or, if the new
// one never comes up, keep running and say so. Everything is mocked.
const { handOver } = require("../lib/restart");

function setup({ relaunchResult = { ok: true }, appearsAfter = 2, ui = { url: "http://127.0.0.1:47000/?key=old" } } = {}) {
    const calls = [];
    const note = (name) => (...args) => { calls.push(name); return args; };
    let polls = 0;
    const deps = {
        runner: { stop: note("runner.stop"), start: note("runner.start") },
        updater: { stop: note("updater.stop"), start: note("updater.start"), failRestart: jest.fn((m) => calls.push("updater.failRestart:" + m)) },
        ui: ui && { ...ui, stop: note("ui.stop") },
        instance: {
            unregister: note("instance.unregister"),
            register: (url) => calls.push("instance.register:" + url),
            findRunningEntry: async () => {
                polls += 1;
                calls.push("instance.find");
                // The new instance registers itself after a few polls.
                return appearsAfter !== null && polls > appearsAfter ? { url: "http://127.0.0.1:47001/?key=new", pid: 4242 } : null;
            },
        },
        relaunch: jest.fn(async (exe) => { calls.push("relaunch:" + exe); return relaunchResult; }),
        exePath: "C:/x/EventHelperSync.exe",
        exit: jest.fn((code) => calls.push("exit:" + code)),
        notify: jest.fn(() => calls.push("notify")),
        log: jest.fn(),
        sleep: async () => {},
        waitMs: 2000,
        pollMs: 250,
    };
    return { deps, calls };
}

describe("handOver", () => {
    it("Reihenfolge: anhalten, Instanz freigeben, neu starten, auf die neue warten, erst dann Server zu und Ende", async () => {
        const { deps, calls } = setup({ appearsAfter: 2 });
        await expect(handOver(deps)).resolves.toBe(true);

        const at = (name) => calls.indexOf(name);
        // The slot is free before the new .exe starts, otherwise it would only
        // re-open this instance's window and exit.
        expect(at("runner.stop")).toBeLessThan(at("relaunch:C:/x/EventHelperSync.exe"));
        expect(at("updater.stop")).toBeLessThan(at("relaunch:C:/x/EventHelperSync.exe"));
        expect(at("instance.unregister")).toBeLessThan(at("relaunch:C:/x/EventHelperSync.exe"));
        // The old UI keeps answering while the new one starts ...
        expect(at("instance.find")).toBeGreaterThan(at("relaunch:C:/x/EventHelperSync.exe"));
        expect(calls.filter((c) => c === "instance.find")).toHaveLength(3);
        // ... and only goes away once the new one is there.
        expect(at("ui.stop")).toBeGreaterThan(calls.lastIndexOf("instance.find"));
        expect(at("exit:0")).toBeGreaterThan(at("ui.stop"));
        expect(calls).not.toContain("runner.start");
        expect(calls.some((c) => c.startsWith("updater.failRestart"))).toBe(false);
        expect(deps.notify).not.toHaveBeenCalled();
    });

    it("die neue Instanz startet nicht (Spawn-Fehler): die alte macht weiter und meldet es", async () => {
        const { deps, calls } = setup({ relaunchResult: { ok: false, error: "spawn EACCES" } });
        await expect(handOver(deps)).resolves.toBe(false);
        expect(deps.exit).not.toHaveBeenCalled();
        expect(calls).not.toContain("ui.stop");
        // Back in business: registered again, upload and timers running, error on the strip.
        expect(calls).toEqual(expect.arrayContaining([
            "instance.register:http://127.0.0.1:47000/?key=old", "runner.start", "updater.start", "notify",
        ]));
        expect(deps.updater.failRestart).toHaveBeenCalledWith(expect.stringMatching(/Neustart hat nicht geklappt: Start fehlgeschlagen \(spawn EACCES\)/));
        expect(deps.notify).toHaveBeenCalledTimes(1);
    });

    it("die neue Instanz meldet sich nie (stürzt beim Start ab): nach der Wartezeit macht die alte weiter", async () => {
        const { deps, calls } = setup({ appearsAfter: null });
        await expect(handOver(deps)).resolves.toBe(false);
        expect(deps.exit).not.toHaveBeenCalled();
        expect(calls.filter((c) => c === "instance.find").length).toBeGreaterThan(5);
        expect(deps.updater.failRestart).toHaveBeenCalledWith(expect.stringMatching(/meldete sich nicht innerhalb von 2 s/));
        expect(calls).toEqual(expect.arrayContaining(["runner.start", "updater.start"]));
    });

    it("ohne Oberflächen-Server (--no-ui) geht es genauso", async () => {
        const { deps, calls } = setup({ ui: null });
        await expect(handOver(deps)).resolves.toBe(true);
        expect(calls).toContain("exit:0");
        expect(calls).not.toContain("ui.stop");
    });
});
