"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const { buildIco, setSubsystem, readSubsystem, SUBSYSTEM } = require("../scripts/exeResources");

/** Der kleinste Kopf, den subsystemOffset() als PE32+ akzeptiert. */
function fakePe({ subsystem = SUBSYSTEM.CONSOLE, magic = 0x20b } = {}) {
    const buf = Buffer.alloc(0x200);
    buf.write("MZ", 0, "latin1");
    const pe = 0x80;
    buf.writeUInt32LE(pe, 0x3c);
    buf.write("PE\0\0", pe, "latin1");
    buf.writeUInt16LE(magic, pe + 24);
    buf.writeUInt16LE(subsystem, pe + 24 + 68);
    return buf;
}

describe("setSubsystem", () => {
    it("stellt ein Konsolenprogramm auf GUI um und nennt den alten Wert", () => {
        const buf = fakePe();
        expect(setSubsystem(buf, SUBSYSTEM.GUI)).toBe(SUBSYSTEM.CONSOLE);
        expect(readSubsystem(buf)).toBe(SUBSYSTEM.GUI);
        // Genau zwei Bytes, sonst nichts.
        const diff = [...buf].filter((b, i) => b !== fakePe()[i]).length;
        expect(diff).toBe(1);
    });

    it("kennt auch PE32 (32-Bit)", () => {
        const buf = fakePe({ magic: 0x10b });
        setSubsystem(buf, SUBSYSTEM.GUI);
        expect(readSubsystem(buf)).toBe(SUBSYSTEM.GUI);
    });

    it("weist alles ab, was keine Windows-Programmdatei ist", () => {
        expect(() => setSubsystem(Buffer.from("#!/bin/sh\n".padEnd(0x100)), 2)).toThrow(/MZ/);
        const noPe = fakePe();
        noPe.write("XX", 0x80, "latin1");
        expect(() => setSubsystem(noPe, 2)).toThrow(/PE-Kopf/);
        expect(() => setSubsystem(fakePe({ magic: 0x1234 }), 2)).toThrow(/Optional-Header/);
    });
});

describe("buildIco", () => {
    const png = (n) => Buffer.alloc(n, 0xab);

    it("schreibt Kopf, Verzeichnis und die Bilder dahinter", () => {
        const ico = buildIco([{ size: 16, png: png(10) }, { size: 256, png: png(20) }]);

        expect(ico.readUInt16LE(0)).toBe(0);
        expect(ico.readUInt16LE(2)).toBe(1);
        expect(ico.readUInt16LE(4)).toBe(2);
        expect(ico.length).toBe(6 + 2 * 16 + 30);

        // Eintrag 1: 16 px, liegt direkt hinter dem Verzeichnis.
        expect(ico[6]).toBe(16);
        expect(ico.readUInt16LE(6 + 6)).toBe(32);
        expect(ico.readUInt32LE(6 + 8)).toBe(10);
        expect(ico.readUInt32LE(6 + 12)).toBe(38);
        // Eintrag 2: 256 px steht als 0 im Byte.
        expect(ico[22]).toBe(0);
        expect(ico[23]).toBe(0);
        expect(ico.readUInt32LE(22 + 12)).toBe(48);
    });

    it("weist leere Listen und unmögliche Größen ab", () => {
        expect(() => buildIco([])).toThrow(/keine Bilder/);
        expect(() => buildIco([{ size: 512, png: png(1) }])).toThrow(/512/);
    });

    it("das eingecheckte assets/icon.ico ist gültig und enthält 16 bis 256 px", () => {
        const ico = fs.readFileSync(path.join(__dirname, "..", "assets", "icon.ico"));
        const count = ico.readUInt16LE(4);
        const sizes = [];
        for (let i = 0; i < count; i++) {
            const at = 6 + i * 16;
            sizes.push(ico[at] || 256);
            const len = ico.readUInt32LE(at + 8);
            const off = ico.readUInt32LE(at + 12);
            expect(off + len).toBeLessThanOrEqual(ico.length);
            // Jeder Eintrag ist ein PNG.
            expect(ico.subarray(off, off + 8).toString("latin1")).toBe("\x89PNG\r\n\x1a\n");
        }
        expect(sizes).toEqual(expect.arrayContaining([16, 32, 48, 256]));
    });
});

// Gegen eine echte node.exe: nur so zeigt sich, dass resedit Icon und
// Versionsinfos dort ersetzt, wo Windows sie liest. Läuft in einem eigenen
// Node-Prozess, weil resedit ESM ist und Jest dessen import() ohne
// --experimental-vm-modules nicht lädt — der Build ruft es genauso ausserhalb
// von Jest auf.
const CHECK = `
const fs = require("fs");
const { applyResources } = require(${JSON.stringify(path.join(__dirname, "..", "scripts", "exeResources.js"))});
(async () => {
    const [exe, ico] = process.argv.slice(1);
    await applyResources(exe, { icoPath: ico, version: "9.8.7" });
    const ResEdit = await require("resedit/cjs").load();
    const res = ResEdit.NtExecutableResource.from(
        ResEdit.NtExecutable.from(fs.readFileSync(exe), { ignoreCert: true }));
    const [info] = ResEdit.Resource.VersionInfo.fromEntries(res.entries);
    const [group] = ResEdit.Resource.IconGroupEntry.fromEntries(res.entries);
    console.log(JSON.stringify({
        strings: info.getAllLanguagesForStringValues().map((l) => info.getStringValues(l)),
        fileVersionMS: info.fixedInfo.fileVersionMS,
        icons: group.icons.length,
    }));
})().catch((e) => { console.error(e.stack); process.exit(1); });
`;

// Dieselbe Reihenfolge wie build-exe.js: erst der SEA-Blob per postject, dann
// die Ressourcen. Am Ende muss die .exe den eingebetteten Code noch ausführen.
const onWindows = process.platform === "win32" ? describe : describe.skip;
onWindows("applyResources nach postject (echte node.exe)", () => {
    it("ersetzt Icon und Versionsinfos, und der eingebettete Code läuft noch", () => {
        const { execFileSync } = require("child_process");
        const root = path.join(__dirname, "..");
        const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ehs-exe-"));
        const exe = path.join(tmp, "node-copy.exe");
        const icoPath = path.join(root, "assets", "icon.ico");
        try {
            fs.writeFileSync(path.join(tmp, "main.js"), "console.log('sea-ok');");
            fs.writeFileSync(path.join(tmp, "sea.json"), JSON.stringify({
                main: path.join(tmp, "main.js"),
                output: path.join(tmp, "sea.blob"),
                disableExperimentalSEAWarning: true,
            }));
            execFileSync(process.execPath, ["--experimental-sea-config", path.join(tmp, "sea.json")], { stdio: "ignore" });
            fs.copyFileSync(process.execPath, exe);
            execFileSync(path.join(root, "node_modules", ".bin", "postject.cmd"), [
                exe, "NODE_SEA_BLOB", path.join(tmp, "sea.blob"),
                "--sentinel-fuse", "NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2",
            ], { stdio: "ignore", shell: true });

            const out = execFileSync(process.execPath, ["-e", CHECK, exe, icoPath], { cwd: root, encoding: "utf8" });
            const result = JSON.parse(out);

            expect(execFileSync(exe, { encoding: "utf8" }).trim()).toBe("sea-ok");
            expect(result.strings.length).toBeGreaterThan(0);
            for (const values of result.strings) {
                expect(values.FileDescription).toBe("EventHelper Sync");
                expect(values.ProductName).toBe("EventHelper Sync");
                expect(values.ProductVersion).toBe("9.8.7");
            }
            expect(result.fileVersionMS).toBe((9 << 16) | 8);
            expect(result.icons).toBe(fs.readFileSync(icoPath).readUInt16LE(4));
        } finally {
            fs.rmSync(tmp, { recursive: true, force: true });
        }
    }, 120000);
});
