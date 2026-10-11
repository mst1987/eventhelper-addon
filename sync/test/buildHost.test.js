"use strict";

// Der Bau des eigenen Fensters (scripts/buildHost.js) muss ohne csc.exe oder
// NuGet sauber aussteigen: dann entsteht die .exe ohne Fenster, und das Tool
// öffnet Edge --app wie bisher. Netz und Compiler sind hier Attrappen.
const fs = require("fs");
const os = require("os");
const path = require("path");
const crypto = require("crypto");
const zlib = require("zlib");

const build = require("../scripts/buildHost");
const { HOST_FILES, HOST_EXE, MANIFEST_ASSET, ASSET_PREFIX } = require("../lib/webviewHost");

let tmp;
beforeEach(() => {
    tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ehs-buildhost-"));
});
afterEach(() => {
    fs.rmSync(tmp, { recursive: true, force: true });
});

const sha512 = (buf) => crypto.createHash("sha512").update(buf).digest("base64");

/** A minimal zip (deflate) with the given entries, like a .nupkg. */
function makeZip(entries) {
    const locals = [];
    const centrals = [];
    let offset = 0;
    for (const [name, text] of Object.entries(entries)) {
        const data = Buffer.from(text);
        const comp = zlib.deflateRawSync(data);
        const nameBuf = Buffer.from(name);
        const local = Buffer.alloc(30);
        local.writeUInt32LE(0x04034b50, 0);
        local.writeUInt16LE(8, 8);
        local.writeUInt32LE(comp.length, 18);
        local.writeUInt32LE(data.length, 22);
        local.writeUInt16LE(nameBuf.length, 26);
        const central = Buffer.alloc(46);
        central.writeUInt32LE(0x02014b50, 0);
        central.writeUInt16LE(8, 10);
        central.writeUInt32LE(comp.length, 20);
        central.writeUInt32LE(data.length, 24);
        central.writeUInt16LE(nameBuf.length, 28);
        central.writeUInt32LE(offset, 42);
        locals.push(local, nameBuf, comp);
        centrals.push(central, nameBuf);
        offset += 30 + nameBuf.length + comp.length;
    }
    const cd = Buffer.concat(centrals);
    const eocd = Buffer.alloc(22);
    eocd.writeUInt32LE(0x06054b50, 0);
    eocd.writeUInt16LE(Object.keys(entries).length, 8);
    eocd.writeUInt16LE(Object.keys(entries).length, 10);
    eocd.writeUInt32LE(cd.length, 12);
    eocd.writeUInt32LE(offset, 16);
    return Buffer.concat([...locals, cd, eocd]);
}

const PACKAGE = makeZip(Object.fromEntries(Object.entries(build.PACKAGE_FILES).map(([name, inner]) => [inner, `dll ${name}`])));

function okFetch(buf = PACKAGE) {
    return jest.fn(async () => ({ ok: true, status: 200, arrayBuffer: async () => buf }));
}

// csc attrappe: writes the /out: file like the real compiler.
function fakeCsc() {
    return jest.fn((cmd, args) => {
        const out = args.find((a) => a.startsWith("/out:")).slice(5);
        fs.writeFileSync(out, "MZ fake host");
        return "";
    });
}

const ROOT = path.join(__dirname, "..");
const baseOptions = () => ({
    root: ROOT, buildDir: tmp, version: "1.16.0", platform: "win32", nodeVersion: "20.17.0", csc: "C:/csc.exe",
    expectedSha512: sha512(PACKAGE),
});

describe("buildHost: überspringen statt scheitern", () => {
    it("ohne csc.exe", async () => {
        const fetchImpl = okFetch();
        const result = await build.buildHost({ ...baseOptions(), csc: null, fetchImpl });
        expect(result.skipped).toMatch(/csc\.exe/);
        expect(fetchImpl).not.toHaveBeenCalled();
        expect(build.seaAssets(result)).toEqual({});
    });

    it("auf anderen Plattformen", async () => {
        const result = await build.buildHost({ ...baseOptions(), platform: "linux" });
        expect(result.skipped).toMatch(/Windows/);
    });

    it("mit einem Node ohne SEA-Assets", async () => {
        const result = await build.buildHost({ ...baseOptions(), nodeVersion: "20.11.1" });
        expect(result.skipped).toMatch(/20\.12/);
    });

    it("ohne Netz (NuGet nicht erreichbar)", async () => {
        const fetchImpl = jest.fn(async () => { throw new Error("getaddrinfo ENOTFOUND"); });
        const result = await build.buildHost({ ...baseOptions(), fetchImpl, execImpl: fakeCsc() });
        expect(result.skipped).toMatch(/ENOTFOUND/);
        expect(fetchImpl).toHaveBeenCalledTimes(build.PACKAGE_URLS.length);
    });

    it("mit einem Paket, das nicht zum festgelegten Hash passt", async () => {
        const result = await build.buildHost({
            ...baseOptions(), expectedSha512: build.WEBVIEW2_SHA512, fetchImpl: okFetch(), execImpl: fakeCsc(),
        });
        expect(result.skipped).toMatch(/SHA-512/);
    });

    it("wenn der Compiler Fehler meldet", async () => {
        const execImpl = jest.fn(() => {
            const e = new Error("Command failed");
            e.stdout = "Host.cs(1,1): error CS1002: ; expected";
            throw e;
        });
        const result = await build.buildHost({ ...baseOptions(), execImpl, fetchImpl: okFetch() });
        expect(result.skipped).toMatch(/CS1002/);
        expect(build.seaAssets(result)).toEqual({});
    });
});

describe("fetchPackage", () => {
    it("prüft den SHA-512 und legt das Paket in den Cache", async () => {
        const cache = path.join(tmp, "cache");
        const fetchImpl = okFetch();
        const buf = await build.fetchPackage(cache, { fetchImpl, expected: sha512(PACKAGE) });
        expect(buf.equals(PACKAGE)).toBe(true);
        expect(fs.readdirSync(cache)).toEqual([`microsoft.web.webview2.${build.WEBVIEW2_VERSION}.nupkg`]);

        // Second build: from the cache, no download.
        const again = okFetch();
        await build.fetchPackage(cache, { fetchImpl: again, expected: sha512(PACKAGE) });
        expect(again).not.toHaveBeenCalled();
    });

    it("weist ein Paket mit falschem Hash zurück und speichert es nicht", async () => {
        const cache = path.join(tmp, "cache");
        await expect(build.fetchPackage(cache, { fetchImpl: okFetch(Buffer.from("untergeschoben")) }))
            .rejects.toThrow(/SHA-512/);
        expect(fs.existsSync(cache)).toBe(false);
    });

    it("nimmt die zweite Adresse, wenn die erste scheitert", async () => {
        const fetchImpl = jest.fn()
            .mockResolvedValueOnce({ ok: false, status: 503 })
            .mockResolvedValueOnce({ ok: true, status: 200, arrayBuffer: async () => PACKAGE });
        await build.fetchPackage(path.join(tmp, "cache"), { fetchImpl, expected: sha512(PACKAGE) });
        expect(fetchImpl.mock.calls.map((c) => c[0])).toEqual(build.PACKAGE_URLS);
    });

    it("hat Version und SHA-512 fest eingetragen", () => {
        expect(build.WEBVIEW2_VERSION).toMatch(/^\d+\.\d+\.\d+\.\d+$/);
        expect(Buffer.from(build.WEBVIEW2_SHA512, "base64")).toHaveLength(64);
        for (const url of build.PACKAGE_URLS) expect(url).toContain(build.WEBVIEW2_VERSION);
    });
});

describe("buildHost mit Paket und Compiler", () => {
    const buildWithFakePackage = () => build.buildHost({ ...baseOptions(), execImpl: fakeCsc(), fetchImpl: okFetch() });

    it("packt die DLLs aus, ruft csc mit Icon, Manifest und Referenzen und schreibt das Manifest", async () => {
        const execImpl = fakeCsc();
        const result = await build.buildHost({ ...baseOptions(), execImpl, fetchImpl: okFetch() });
        expect(result.skipped).toBeUndefined();
        for (const name of HOST_FILES) expect(fs.existsSync(result.files[name])).toBe(true);
        expect(fs.readFileSync(result.files["WebView2Loader.dll"], "utf8")).toBe("dll WebView2Loader.dll");

        const [cmd, args] = execImpl.mock.calls[0];
        expect(cmd).toBe("C:/csc.exe");
        expect(args).toEqual(expect.arrayContaining(["/target:winexe", "/platform:x64", "/reference:System.Windows.Forms.dll"]));
        expect(args.some((a) => a.startsWith("/win32icon:") && a.endsWith("icon.ico"))).toBe(true);
        expect(args.some((a) => a.startsWith("/win32manifest:") && a.endsWith("app.manifest"))).toBe(true);
        expect(args.some((a) => a.endsWith("Microsoft.Web.WebView2.WinForms.dll") && a.startsWith("/reference:"))).toBe(true);
        expect(args.some((a) => a.endsWith("Host.cs"))).toBe(true);

        const manifest = JSON.parse(fs.readFileSync(result.manifest, "utf8"));
        expect(Object.keys(manifest.files).sort()).toEqual([...HOST_FILES].sort());
        expect(manifest.version).toBe("1.16.0");
    });

    it("liefert die SEA-Assets unter den Namen, die lib/webviewHost.js liest", async () => {
        const result = await buildWithFakePackage();
        const assets = build.seaAssets(result);
        expect(assets[MANIFEST_ASSET]).toBe(result.manifest);
        expect(assets[ASSET_PREFIX + HOST_EXE]).toBe(result.files[HOST_EXE]);
        expect(Object.keys(assets)).toHaveLength(HOST_FILES.length + 1);
    });
});

describe("findCsc / assemblyInfo", () => {
    it("sucht csc.exe zuerst im 64-Bit-Framework", () => {
        const seen = [];
        const csc = build.findCsc({ WINDIR: "C:\\Windows" }, (p) => { seen.push(p); return p.includes("Framework64"); });
        expect(csc).toBe(path.join("C:\\Windows", "Microsoft.NET", "Framework64", "v4.0.30319", "csc.exe"));
        expect(build.findCsc({ WINDIR: "C:\\Windows" }, () => false)).toBeNull();
    });

    it("schreibt die Version vierteilig in die Dateieigenschaften", () => {
        const info = build.assemblyInfo("1.16.0");
        expect(info).toContain('AssemblyVersion("1.16.0.0")');
        expect(info).toContain('AssemblyInformationalVersion("1.16.0")');
    });
});
