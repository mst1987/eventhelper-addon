"use strict";

// Echte Datei und echter HTTP-Server statt Mocks: findRunning() lebt davon,
// dass eine laufende Oberfläche tatsächlich antwortet.
const fs = require("fs");
const os = require("os");
const path = require("path");
const http = require("http");

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ehs-instance-"));
process.env.EVENTHELPER_SYNC_CONFIG = path.join(tmp, "config.json");
const instance = require("../lib/instance");

let server;
let port;

beforeEach(async () => {
    fs.rmSync(instance.RUN_FILE, { force: true });
    server = http.createServer((req, res) => {
        const ok = req.url.startsWith("/api/state") && req.url.includes("key=richtig");
        res.writeHead(ok ? 200 : 403);
        res.end("{}");
    });
    await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
    port = server.address().port;
});

afterEach(async () => {
    await new Promise((resolve) => server.close(resolve));
});

afterAll(() => {
    fs.rmSync(tmp, { recursive: true, force: true });
});

function writeRun(entry) {
    fs.writeFileSync(instance.RUN_FILE, JSON.stringify(entry));
}

describe("findRunning", () => {
    it("liegt neben der Konfiguration", () => {
        expect(instance.RUN_FILE).toBe(path.join(tmp, "config.running.json"));
    });

    it("findet eine laufende Instanz, deren Oberfläche mit dem Schlüssel antwortet", async () => {
        const url = `http://127.0.0.1:${port}/?key=richtig`;
        writeRun({ pid: process.ppid, url });
        expect(await instance.findRunning()).toBe(url);
    });

    it("ignoriert eine Oberfläche, die den Schlüssel nicht mehr kennt", async () => {
        writeRun({ pid: process.ppid, url: `http://127.0.0.1:${port}/?key=alt` });
        expect(await instance.findRunning()).toBeNull();
    });

    it("ignoriert einen beendeten Prozess", async () => {
        writeRun({ pid: 2 ** 22 + 12345, url: `http://127.0.0.1:${port}/?key=richtig` });
        expect(await instance.findRunning()).toBeNull();
    });

    it("ignoriert den eigenen Prozess", async () => {
        writeRun({ pid: process.pid, url: `http://127.0.0.1:${port}/?key=richtig` });
        expect(await instance.findRunning()).toBeNull();
    });

    it("ignoriert eine Adresse, unter der niemand mehr lauscht", async () => {
        const url = `http://127.0.0.1:${port}/?key=richtig`;
        await new Promise((resolve) => server.close(resolve));
        server = http.createServer();
        await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
        writeRun({ pid: process.ppid, url });
        expect(await instance.findRunning({ timeoutMs: 500 })).toBeNull();
    });

    it("liefert null ohne oder mit kaputter Datei", async () => {
        expect(await instance.findRunning()).toBeNull();
        fs.writeFileSync(instance.RUN_FILE, "{kaputt");
        expect(await instance.findRunning()).toBeNull();
    });
});

describe("register / unregister", () => {
    it("hinterlegt PID und Adresse und räumt nur die eigene Datei wieder weg", () => {
        const onSpy = jest.spyOn(process, "on").mockImplementation(() => process);
        try {
            instance.register("http://127.0.0.1:1/?key=k");
            expect(JSON.parse(fs.readFileSync(instance.RUN_FILE, "utf8")))
                .toEqual({ pid: process.pid, url: "http://127.0.0.1:1/?key=k" });
            expect(onSpy).toHaveBeenCalledWith("exit", instance.unregister);

            instance.unregister();
            expect(fs.existsSync(instance.RUN_FILE)).toBe(false);

            // Eine inzwischen gestartete andere Instanz darf nicht verschwinden.
            writeRun({ pid: process.ppid, url: "x" });
            instance.unregister();
            expect(fs.existsSync(instance.RUN_FILE)).toBe(true);
        } finally {
            onSpy.mockRestore();
        }
    });
});
