"use strict";

/**
 * Builds the tool's own window (webview-host/Host.cs, see lib/webviewHost.js)
 * for scripts/build-exe.js.
 *
 * No .NET SDK needed: the C# compiler of the .NET Framework 4 (csc.exe, part
 * of every Windows 10/11 and of the GitHub Windows runners) compiles Host.cs
 * against the WebView2 DLLs from Microsoft's official NuGet package. The
 * package is pinned to one version and its SHA-512 (the hash nuget.org lists
 * for it) and cached in build/cache/, so a rebuild needs no download.
 *
 * Without csc.exe or without the package (offline, other OS) the .exe is
 * built without the window, and the tool falls back to Edge --app as before:
 * buildHost() then returns { skipped: "<reason>" } instead of throwing. Set
 * EHS_REQUIRE_HOST=1 (the release workflow does) to make that an error.
 */
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { execFileSync } = require("child_process");
const { readZip } = require("../lib/updater");
const { HOST_EXE, HOST_FILES, ASSET_PREFIX, MANIFEST_ASSET } = require("../lib/webviewHost");

// Microsoft.Web.WebView2 on nuget.org: a stable release, published 2026-08-28.
// The hash is the package's SHA-512 as nuget.org states it (catalog entry
// "packageHash"). Update both together.
const WEBVIEW2_VERSION = "1.0.4191.47";
const WEBVIEW2_SHA512 = "rfkb2hpx2GDAmM0OQmtaI44Yfqc8aUgy+P3jaAmpFl/aiET8nCufyKhwsNpTzZ65fsFA2aLxBKIoMB/66EHbjA==";
const PACKAGE_URLS = [
    // The NuGet v3 package content endpoint (a CDN, fast) …
    `https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/${WEBVIEW2_VERSION}/microsoft.web.webview2.${WEBVIEW2_VERSION}.nupkg`,
    // … and the classic download link as a second try.
    `https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/${WEBVIEW2_VERSION}`,
];
// Where the three files sit inside the package.
const PACKAGE_FILES = {
    "Microsoft.Web.WebView2.Core.dll": "lib/net462/Microsoft.Web.WebView2.Core.dll",
    "Microsoft.Web.WebView2.WinForms.dll": "lib/net462/Microsoft.Web.WebView2.WinForms.dll",
    "WebView2Loader.dll": "runtimes/win-x64/native/WebView2Loader.dll",
};
// SEA assets (the "assets" field of the SEA config) arrived in Node 20.12.
const MIN_NODE_FOR_ASSETS = [20, 12];

const sha512 = (buf) => crypto.createHash("sha512").update(buf).digest("base64");
const sha256 = (buf) => crypto.createHash("sha256").update(buf).digest("hex");

/** The .NET Framework 4 C# compiler, or null. */
function findCsc(env = process.env, exists = fs.existsSync) {
    const windir = env.WINDIR || env.SystemRoot || "C:\\Windows";
    for (const fw of ["Framework64", "Framework"]) {
        const csc = path.join(windir, "Microsoft.NET", fw, "v4.0.30319", "csc.exe");
        if (exists(csc)) return csc;
    }
    return null;
}

function nodeSupportsAssets(version = process.versions.node) {
    const [major, minor] = version.split(".").map(Number);
    return major > MIN_NODE_FOR_ASSETS[0] || (major === MIN_NODE_FOR_ASSETS[0] && minor >= MIN_NODE_FOR_ASSETS[1]);
}

/**
 * The NuGet package, from the cache or downloaded, checked against the pinned
 * SHA-512. Throws if no copy with the right hash can be had.
 */
async function fetchPackage(cacheDir, { fetchImpl = fetch, urls = PACKAGE_URLS, expected = WEBVIEW2_SHA512, log = () => {} } = {}) {
    const cached = path.join(cacheDir, `microsoft.web.webview2.${WEBVIEW2_VERSION}.nupkg`);
    try {
        const buf = fs.readFileSync(cached);
        if (sha512(buf) === expected) return buf;
    } catch {
        // Not cached yet.
    }
    const errors = [];
    for (const url of urls) {
        try {
            const res = await fetchImpl(url, { redirect: "follow", signal: AbortSignal.timeout(120 * 1000) });
            if (!res.ok) throw new Error(`HTTP ${res.status}`);
            const buf = Buffer.from(await res.arrayBuffer());
            if (sha512(buf) !== expected) throw new Error("SHA-512 stimmt nicht mit dem festgelegten Wert überein");
            fs.mkdirSync(cacheDir, { recursive: true });
            fs.writeFileSync(cached, buf);
            log(`  ${url} (${(buf.length / 1024 / 1024).toFixed(1)} MB, SHA-512 geprüft)`);
            return buf;
        } catch (e) {
            errors.push(`${url}: ${e.message}`);
        }
    }
    throw new Error(`WebView2-Paket ${WEBVIEW2_VERSION} nicht geladen:\n    ${errors.join("\n    ")}`);
}

function assemblyInfo(version) {
    // Four-part version for the file properties; "1.16.0" -> "1.16.0.0".
    const parts = String(version).split(/[.-]/).map((p) => parseInt(p, 10)).filter((n) => Number.isFinite(n));
    while (parts.length < 4) parts.push(0);
    const v = parts.slice(0, 4).join(".");
    return [
        "using System.Reflection;",
        "[assembly: AssemblyTitle(\"EventHelper Sync\")]",
        "[assembly: AssemblyProduct(\"EventHelper Sync\")]",
        "[assembly: AssemblyDescription(\"EventHelper Sync window\")]",
        `[assembly: AssemblyVersion("${v}")]`,
        `[assembly: AssemblyFileVersion("${v}")]`,
        `[assembly: AssemblyInformationalVersion("${version}")]`,
        "",
    ].join("\r\n");
}

/**
 * @param {object} options
 * @param {string} options.root      sync/
 * @param {string} options.buildDir  sync/build/ (output in build/host/)
 * @param {string} options.version   the tool's version
 * @param {(line: string) => void} [options.log]
 * @param {string|null} [options.csc]   default: findCsc()
 * @param {Function} [options.fetchImpl]
 * @param {Function} [options.execImpl]
 * @param {string} [options.platform]
 * @param {string} [options.nodeVersion]
 * @param {string} [options.expectedSha512]  default: the pinned WEBVIEW2_SHA512 (tests)
 * @returns {Promise<{ dir: string, files: Object<string,string>, manifest: string } | { skipped: string }>}
 */
async function buildHost(options) {
    const {
        root, buildDir, version, log = () => {}, fetchImpl = fetch, execImpl = execFileSync,
        platform = process.platform, nodeVersion = process.versions.node, expectedSha512 = WEBVIEW2_SHA512,
    } = options;
    if (platform !== "win32") return { skipped: "nur unter Windows" };
    if (!nodeSupportsAssets(nodeVersion)) return { skipped: `Node ${nodeVersion} kann keine SEA-Assets (ab 20.12)` };
    const csc = options.csc !== undefined ? options.csc : findCsc();
    if (!csc) return { skipped: "csc.exe (.NET Framework 4) nicht gefunden" };

    let pkg;
    try {
        pkg = await fetchPackage(path.join(buildDir, "cache"), { fetchImpl, log, expected: expectedSha512 });
    } catch (e) {
        return { skipped: e.message };
    }

    const dir = path.join(buildDir, "host");
    fs.rmSync(dir, { recursive: true, force: true });
    fs.mkdirSync(dir, { recursive: true });
    let entries;
    try {
        entries = readZip(pkg);
    } catch (e) {
        return { skipped: `WebView2-Paket nicht lesbar: ${e.message}` };
    }
    for (const [name, inner] of Object.entries(PACKAGE_FILES)) {
        const entry = entries.find((e) => e.name === inner);
        if (!entry) return { skipped: `${inner} fehlt im WebView2-Paket` };
        fs.writeFileSync(path.join(dir, name), entry.data);
    }

    const src = path.join(root, "webview-host");
    const info = path.join(buildDir, "HostAssemblyInfo.cs");
    fs.writeFileSync(info, assemblyInfo(version));
    const exe = path.join(dir, HOST_EXE);
    try {
        execImpl(csc, [
            "/nologo", "/target:winexe", "/platform:x64", "/optimize+",
            `/win32icon:${path.join(root, "assets", "icon.ico")}`,
            `/win32manifest:${path.join(src, "app.manifest")}`,
            `/out:${exe}`,
            "/reference:System.Windows.Forms.dll",
            "/reference:System.Drawing.dll",
            "/reference:System.Web.Extensions.dll",
            `/reference:${path.join(dir, "Microsoft.Web.WebView2.Core.dll")}`,
            `/reference:${path.join(dir, "Microsoft.Web.WebView2.WinForms.dll")}`,
            path.join(src, "Host.cs"),
            info,
        ], { stdio: ["ignore", "pipe", "pipe"], encoding: "utf8" });
    } catch (e) {
        const out = `${e.stdout || ""}${e.stderr || ""}`.trim();
        return { skipped: `csc.exe meldet Fehler${out ? `:\n${out}` : `: ${e.message}`}` };
    }
    if (!fs.existsSync(exe)) return { skipped: "csc.exe hat keine .exe erzeugt" };

    // What lib/webviewHost.js checks before and after extracting.
    const files = {};
    const hashes = {};
    for (const name of HOST_FILES) {
        files[name] = path.join(dir, name);
        hashes[name] = sha256(fs.readFileSync(files[name]));
    }
    const manifest = path.join(buildDir, "host-manifest.json");
    fs.writeFileSync(manifest, JSON.stringify({ version, webview2: WEBVIEW2_VERSION, files: hashes }, null, 2));
    return { dir, files, manifest };
}

/** The "assets" field of the SEA config: empty when the host was skipped. */
function seaAssets(result) {
    if (!result || result.skipped) return {};
    const assets = { [MANIFEST_ASSET]: result.manifest };
    for (const [name, file] of Object.entries(result.files)) assets[ASSET_PREFIX + name] = file;
    return assets;
}

module.exports = {
    buildHost, seaAssets, findCsc, fetchPackage, nodeSupportsAssets, assemblyInfo,
    WEBVIEW2_VERSION, WEBVIEW2_SHA512, PACKAGE_URLS, PACKAGE_FILES,
};
