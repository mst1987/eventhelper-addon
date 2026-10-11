"use strict";

/**
 * The tool's own window: a small native program (webview-host/Host.cs) that
 * shows the local page in WebView2 without any browser title bar. The page's
 * header is the title bar (lib/webui-page.js).
 *
 * The program and its three WebView2 DLLs travel inside the .exe as SEA assets
 * (scripts/build-exe.js, scripts/buildHost.js). At start they are written
 * once to %LOCALAPPDATA%\EventHelperSync\host\<version>\ — a file whose
 * SHA-256 already matches is left alone — and the window program is started
 * from there. Run with Node.js instead of the .exe, sync/build/host/ from the
 * last `npm run build:exe` is used if present.
 *
 * Everything here may fail without consequence: no host, no WebView2 runtime,
 * no .NET Framework 4.6.2 means lib/appWindow.js falls back to Edge/Chrome
 * --app and then to a browser tab.
 */
const fs = require("fs");
const os = require("os");
const path = require("path");
const crypto = require("crypto");
const { execFileSync, spawn } = require("child_process");

const HOST_EXE = "EventHelperSyncWindow.exe";
const HOST_FILES = [
    HOST_EXE,
    "Microsoft.Web.WebView2.Core.dll",
    "Microsoft.Web.WebView2.WinForms.dll",
    "WebView2Loader.dll",
];
// Names of the SEA assets: "host/<file>" plus a manifest with their hashes.
const ASSET_PREFIX = "host/";
const MANIFEST_ASSET = "host/manifest.json";
// Host.cs's exit codes: WebView2 could not start; a window for this sync
// process was already open and has been brought to the front instead.
const EXIT_WEBVIEW_FAILED = 3;
const EXIT_HANDED_OVER = 4;
// The Evergreen WebView2 runtime's client id (Microsoft's documented way to
// detect an installed runtime).
const WEBVIEW2_CLIENT = "{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}";
const RUNTIME_KEYS = [
    `HKLM\\SOFTWARE\\WOW6432Node\\Microsoft\\EdgeUpdate\\Clients\\${WEBVIEW2_CLIENT}`,
    `HKLM\\SOFTWARE\\Microsoft\\EdgeUpdate\\Clients\\${WEBVIEW2_CLIENT}`,
    `HKCU\\SOFTWARE\\Microsoft\\EdgeUpdate\\Clients\\${WEBVIEW2_CLIENT}`,
];
const NET_FRAMEWORK_KEY = "HKLM\\SOFTWARE\\Microsoft\\NET Framework Setup\\NDP\\v4\\Full";
// .NET Framework 4.6.2: what the WebView2 DLLs (lib/net462) need.
const NET_462_RELEASE = 394802;
// Where the host is extracted to; also where Host.cs keeps window.log and the
// WebView2 profile (…\EventHelperSync\webview2).
const DATA_DIR_NAME = "EventHelperSync";
// How long a failing window start still falls back to Edge: later on a
// crash should not pop up a browser window out of nowhere.
const FALLBACK_WINDOW_MS = 30 * 1000;
// A second start (the .exe double-clicked again) waits this long for the
// window program to fail before it exits itself.
const EARLY_EXIT_WAIT_MS = 10 * 1000;

const sha256 = (buf) => crypto.createHash("sha256").update(buf).digest("hex");

function fileHash(file) {
    try {
        return sha256(fs.readFileSync(file));
    } catch {
        return null;
    }
}

function localAppData(env = process.env) {
    return env.LOCALAPPDATA || path.join(os.homedir(), "AppData", "Local");
}

function hostRoot(env = process.env) {
    return path.join(localAppData(env), DATA_DIR_NAME, "host");
}

/** A value from the registry via reg.exe, or null. */
function regValue(key, name, { execImpl = execFileSync } = {}) {
    try {
        const out = String(execImpl("reg", ["query", key, "/v", name], {
            encoding: "utf8", windowsHide: true, stdio: ["ignore", "pipe", "ignore"],
        }) || "");
        const line = out.split(/\r?\n/).find((l) => l.trim().toLowerCase().startsWith(name.toLowerCase() + " "));
        const m = line && line.trim().match(/^\S+\s+REG_\w+\s+(.*)$/);
        return m ? m[1].trim() : null;
    } catch {
        return null;
    }
}

/** The installed WebView2 runtime's version, or null. */
function webView2Version(options = {}) {
    for (const key of RUNTIME_KEYS) {
        const v = regValue(key, "pv", options);
        // "0.0.0.0" is what an uninstall leaves behind.
        if (v && v !== "0.0.0.0") return v;
    }
    return null;
}

/** Whether .NET Framework 4.6.2 or newer is installed (Windows 10 1607+ has it). */
function hasNetFramework(options = {}) {
    const v = regValue(NET_FRAMEWORK_KEY, "Release", options);
    return Number(v) >= NET_462_RELEASE;
}

/** The SEA asset reader of the packed .exe, or null when run with Node.js. */
function seaAssets() {
    try {
        const sea = require("node:sea");
        if (!sea.isSea()) return null;
        return (key) => Buffer.from(sea.getAsset(key));
    } catch {
        return null;
    }
}

/** Remove the folders of other versions; one still in use stays until next time. */
function cleanupOtherVersions(root, keep) {
    let names;
    try {
        names = fs.readdirSync(root);
    } catch {
        return;
    }
    for (const name of names) {
        if (name === keep) continue;
        try {
            fs.rmSync(path.join(root, name), { recursive: true, force: true });
        } catch {
            // The old window may still run for a moment after an update.
        }
    }
}

/**
 * Write the host files from the .exe's assets to <root>/<version>/.
 * @param {{ getAsset: (key: string) => Buffer, version: string, root?: string }} options
 * @returns {string|null}  the window program's path, or null
 */
function extractHost({ getAsset, version, root = hostRoot() }) {
    try {
        const manifest = JSON.parse(getAsset(MANIFEST_ASSET).toString("utf8"));
        const hashes = (manifest && manifest.files) || {};
        const dir = path.join(root, String(version));
        fs.mkdirSync(dir, { recursive: true });
        for (const name of HOST_FILES) {
            const want = hashes[name];
            if (!want) return null;
            const target = path.join(dir, name);
            if (fileHash(target) === want) continue;
            const data = getAsset(ASSET_PREFIX + name);
            if (sha256(data) !== want) return null;
            // Atomic: a half-written DLL must never be loaded.
            const tmp = `${target}.${process.pid}.tmp`;
            fs.writeFileSync(tmp, data);
            fs.renameSync(tmp, target);
        }
        cleanupOtherVersions(root, String(version));
        return path.join(dir, HOST_EXE);
    } catch {
        return null;
    }
}

/** The host from the last `npm run build:exe` (sync/build/host/), or null. */
function devHost(dir = path.join(__dirname, "..", "build", "host")) {
    return HOST_FILES.every((f) => fs.existsSync(path.join(dir, f))) ? path.join(dir, HOST_EXE) : null;
}

/**
 * The window program, ready to start — or null if this machine cannot run it.
 * @param {object} [options]
 * @param {string} [options.version]  folder name under host/
 * @param {Function|null} [options.getAsset]  default: the .exe's SEA assets
 * @param {string} [options.root]
 * @param {Function} [options.execImpl]  for the registry queries (tests)
 */
function findHost(options = {}) {
    if (process.platform !== "win32") return null;
    if (!webView2Version(options) || !hasNetFramework(options)) return null;
    const getAsset = options.getAsset !== undefined ? options.getAsset : seaAssets();
    if (getAsset) {
        return extractHost({ getAsset, version: options.version || "dev", root: options.root || hostRoot() });
    }
    return devHost(options.devDir);
}

/**
 * Start the window program for the page at `url`.
 * @param {string} exe
 * @param {string} url
 * @param {object} options
 * @param {number} options.parentPid  the sync process the window belongs to:
 *   it closes when that process ends
 * @param {number} [options.width]   CSS pixels
 * @param {number} [options.height]  CSS pixels
 * @param {(code: number|null, failedEarly: boolean) => void} [options.onExit]
 * @param {(err: Error) => void} [options.onError]  could not be started at all
 * @returns {object|null}  the child process, or null if spawn threw
 */
function spawnHost(exe, url, { parentPid, width = 560, height = 680, onExit, onError, spawnImpl = spawn } = {}) {
    const started = Date.now();
    let child;
    try {
        child = spawnImpl(exe, [
            "--url", url,
            "--parent-pid", String(parentPid),
            "--width", String(width),
            "--height", String(height),
        ], {
            cwd: path.dirname(exe),
            stdio: "ignore",
            // Not in libuv's kill-on-close job: a second start opens the window
            // for the running instance and exits, the window must stay. It
            // ends with the process given as --parent-pid instead.
            detached: true,
            // Must stay false: SW_HIDE would hide the window's first show.
            windowsHide: false,
        });
    } catch (e) {
        if (onError) onError(e);
        return null;
    }
    let done = false;
    child.on("error", (e) => {
        if (done) return;
        done = true;
        if (onError) onError(e);
    });
    child.on("exit", (code) => {
        if (done) return;
        done = true;
        const failedEarly = code === EXIT_WEBVIEW_FAILED && Date.now() - started < FALLBACK_WINDOW_MS;
        if (onExit) onExit(code, failedEarly);
    });
    // Keep this process alive a little while (a second start exits right
    // after opening the window, and must still be able to fall back), then
    // let it end independently of the window.
    if (child.unref) {
        const t = setTimeout(() => child.unref(), EARLY_EXIT_WAIT_MS);
        if (t.unref) t.unref();
    }
    return child;
}

module.exports = {
    findHost, extractHost, spawnHost, devHost, webView2Version, hasNetFramework, regValue, seaAssets, hostRoot,
    HOST_EXE, HOST_FILES, ASSET_PREFIX, MANIFEST_ASSET, EXIT_WEBVIEW_FAILED, EXIT_HANDED_OVER, RUNTIME_KEYS, NET_FRAMEWORK_KEY,
};
