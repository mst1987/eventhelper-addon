"use strict";

/**
 * Updates ohne Neu-Herunterladen: das Sync-Tool schaut selbst auf GitHub nach,
 * ob es ein neueres Release gibt, und spielt es auf Knopfdruck ein — sich
 * selbst (die .exe) und das Addon in jedem installierten Addon-Ordner.
 *
 * Woher: das öffentliche Repo hat für jede Version genau ein Release
 * (.github/workflows/release.yml) mit zwei Dateien, `EventHelperSync.exe` und
 * `EventHelperSync-<version>.zip`. Addon und Sync-Tool tragen dieselbe
 * Versionsnummer, ein Blick auf `releases/latest` beantwortet also beide
 * Fragen. GitHub erlaubt ohne Anmeldung 60 Abrufe pro Stunde und IP — einer
 * beim Start und dann alle paar Stunden liegt weit darunter.
 *
 * Geprüft wird jede heruntergeladene Datei gegen den SHA-256, den GitHub zu
 * jedem Release-Anhang angibt (`digest`). Stimmt er nicht, wird nichts
 * angefasst.
 *
 * Das Addon: das Zip wird hier selbst gelesen (readZip, nur "stored" und
 * "deflate" — mehr erzeugt Compress-Archive nicht) und Datei für Datei atomar
 * in den Addon-Ordner geschrieben. CouncilData.lua und GuildBankData.lua
 * bleiben stehen: die schreibt das Sync-Tool selbst, im Zip liegen nur leere
 * Platzhalter. Neue Dateien in der .toc und neue Bilder (media/*.tga) lädt
 * WoW erst nach einem Neustart des Spiels, geänderte schon nach /reload —
 * deshalb wird beides unterschieden.
 *
 * Die .exe: eine laufende .exe lässt sich unter Windows nicht überschreiben,
 * wohl aber umbenennen. Also: neue Datei daneben, alte zur Seite
 * (`EventHelperSync.old.exe`), neue an ihren Platz, neu starten, beenden. Die
 * nächste Instanz räumt die alte Datei weg (cleanupOldExe).
 */
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const crypto = require("crypto");
const { spawn } = require("child_process");
const wowPaths = require("./wowPaths");
const { writeAtomic, COUNCIL_FILE } = require("./council");
const { HANDOUTS_FILE } = require("./guildbankHandouts");
const { SYNC_VERSION } = require("./uploader");

const REPO = "mst1987/eventhelper-addon";
const LATEST_URL = `https://api.github.com/repos/${REPO}/releases/latest`;
const RELEASES_PAGE = `https://github.com/${REPO}/releases`;
const EXE_ASSET = "EventHelperSync.exe";
const ZIP_ASSET = /^EventHelperSync-[\w.-]+\.zip$/i;
// Beim Start nicht sofort (die Oberfläche soll zuerst da sein), dann alle 6 Stunden.
const FIRST_CHECK_MS = 10 * 1000;
const CHECK_INTERVAL_MS = 6 * 60 * 60 * 1000;
const SNAPSHOT_TTL_MS = 30 * 1000;
// Die .exe ist ~70 MB; alles weit darüber ist kein Release von uns.
const MAX_DOWNLOAD_BYTES = 200 * 1024 * 1024;
// Diese Dateien schreibt das Sync-Tool; ein Update darf sie nicht leeren.
const PRESERVED_FILES = [COUNCIL_FILE, HANDOUTS_FILE];

class UpdateError extends Error {
    constructor(message) {
        super(message);
        this.name = "UpdateError";
    }
}

// ---------------------------------------------------------------------------
// Release
// ---------------------------------------------------------------------------

/** Ein Release-Anhang in der Form, die hier gebraucht wird. */
function assetInfo(asset) {
    if (!asset) return null;
    const m = /^sha256:([0-9a-f]{64})$/i.exec(String(asset.digest || ""));
    return {
        name: asset.name,
        url: asset.browser_download_url,
        size: Number(asset.size) || 0,
        sha256: m ? m[1].toLowerCase() : "",
    };
}

/**
 * Die Antwort von `releases/latest` auf das Nötige eingedampft.
 * @returns {{ version: string, tag: string, url: string, publishedAt: string,
 *   exe: object|null, zip: object|null }}
 */
function parseRelease(json) {
    if (!json || typeof json !== "object" || !json.tag_name) {
        throw new UpdateError("Unerwartete Antwort von GitHub (kein Release).");
    }
    const assets = Array.isArray(json.assets) ? json.assets : [];
    return {
        version: String(json.tag_name).replace(/^v/i, ""),
        tag: String(json.tag_name),
        url: json.html_url || RELEASES_PAGE,
        publishedAt: json.published_at || "",
        exe: assetInfo(assets.find((a) => a && a.name === EXE_ASSET)),
        zip: assetInfo(assets.find((a) => a && ZIP_ASSET.test(String(a.name || "")))),
    };
}

async function fetchLatestRelease({ fetchImpl = fetch, timeoutMs = 15000 } = {}) {
    let res;
    try {
        res = await fetchImpl(LATEST_URL, {
            headers: {
                Accept: "application/vnd.github+json",
                "User-Agent": `EventHelperSync/${SYNC_VERSION}`,
            },
            signal: AbortSignal.timeout(timeoutMs),
        });
    } catch (e) {
        throw new UpdateError(`GitHub nicht erreichbar: ${e.message}`);
    }
    if (!res.ok) {
        throw new UpdateError(res.status === 403 || res.status === 429
            ? "GitHub hat zu viele Abfragen gezählt — später noch einmal versuchen."
            : `GitHub antwortet mit HTTP ${res.status}.`);
    }
    return parseRelease(await res.json());
}

/** Eine Release-Datei laden und gegen Grösse und SHA-256 prüfen. */
async function download(asset, { fetchImpl = fetch, timeoutMs = 10 * 60 * 1000 } = {}) {
    if (!asset || !asset.url) throw new UpdateError("Die Datei fehlt im Release.");
    let res;
    try {
        res = await fetchImpl(asset.url, {
            headers: { "User-Agent": `EventHelperSync/${SYNC_VERSION}` },
            signal: AbortSignal.timeout(timeoutMs),
        });
    } catch (e) {
        throw new UpdateError(`${asset.name} nicht geladen: ${e.message}`);
    }
    if (!res.ok) throw new UpdateError(`${asset.name} nicht geladen: HTTP ${res.status}.`);
    const buf = Buffer.from(await res.arrayBuffer());
    if (buf.length > MAX_DOWNLOAD_BYTES) throw new UpdateError(`${asset.name} ist unerwartet gross.`);
    if (asset.size && buf.length !== asset.size) {
        throw new UpdateError(`${asset.name} ist unvollständig (${buf.length} statt ${asset.size} Bytes).`);
    }
    if (asset.sha256) {
        const got = crypto.createHash("sha256").update(buf).digest("hex");
        if (got !== asset.sha256) throw new UpdateError(`${asset.name}: Prüfsumme stimmt nicht — nichts installiert.`);
    }
    return buf;
}

// ---------------------------------------------------------------------------
// Zip
// ---------------------------------------------------------------------------

/**
 * Die Dateien eines Zip-Archivs. Liest das zentrale Verzeichnis am Ende der
 * Datei (die lokalen Köpfe können bei Streaming-Zips falsche Grössen tragen).
 * @param {Buffer} buf
 * @returns {{ name: string, data: Buffer }[]}  nur Dateien, keine Ordner
 */
function readZip(buf) {
    // End of central directory: Signatur 0x06054b50, höchstens 64 KiB Kommentar dahinter.
    let eocd = -1;
    for (let i = buf.length - 22; i >= Math.max(0, buf.length - 22 - 0xffff); i -= 1) {
        if (buf.readUInt32LE(i) === 0x06054b50) {
            eocd = i;
            break;
        }
    }
    if (eocd < 0) throw new UpdateError("Kein gültiges Zip-Archiv.");
    const count = buf.readUInt16LE(eocd + 10);
    let p = buf.readUInt32LE(eocd + 16);
    const entries = [];
    for (let n = 0; n < count; n += 1) {
        if (buf.readUInt32LE(p) !== 0x02014b50) throw new UpdateError("Zip-Verzeichnis beschädigt.");
        const method = buf.readUInt16LE(p + 10);
        const compressedSize = buf.readUInt32LE(p + 20);
        const nameLen = buf.readUInt16LE(p + 28);
        const extraLen = buf.readUInt16LE(p + 30);
        const commentLen = buf.readUInt16LE(p + 32);
        const localOffset = buf.readUInt32LE(p + 42);
        const name = buf.toString("utf8", p + 46, p + 46 + nameLen).replace(/\\/g, "/");
        p += 46 + nameLen + extraLen + commentLen;
        if (name.endsWith("/")) continue;

        if (buf.readUInt32LE(localOffset) !== 0x04034b50) throw new UpdateError(`Zip-Eintrag ${name} beschädigt.`);
        const start = localOffset + 30 + buf.readUInt16LE(localOffset + 26) + buf.readUInt16LE(localOffset + 28);
        const raw = buf.subarray(start, start + compressedSize);
        let data;
        if (method === 0) data = Buffer.from(raw);
        else if (method === 8) data = zlib.inflateRawSync(raw);
        else throw new UpdateError(`Zip-Eintrag ${name}: Packverfahren ${method} wird nicht unterstützt.`);
        entries.push({ name, data });
    }
    return entries;
}

/**
 * Die Dateien des Addon-Ordners aus dem Zip: relativ zu `EventHelperSync/`,
 * ohne alles, was aus dem Ordner herausführen könnte.
 * @returns {{ rel: string, data: Buffer }[]}
 */
function addonFiles(entries) {
    const prefix = `${wowPaths.ADDON_FOLDER}/`;
    const files = [];
    for (const { name, data } of entries) {
        if (!name.startsWith(prefix)) continue;
        const rel = name.slice(prefix.length);
        const parts = rel.split("/");
        if (!rel || path.isAbsolute(rel) || parts.some((s) => !s || s === "." || s === ".." || s.includes(":"))) continue;
        files.push({ rel, data });
    }
    if (!files.some((f) => f.rel === `${wowPaths.ADDON_FOLDER}.toc`)) {
        throw new UpdateError("Im Zip fehlt EventHelperSync.toc — das ist kein Addon-Paket.");
    }
    return files;
}

/** Die Dateizeilen einer .toc (ohne Kommentare und ## Metadaten). */
function tocFiles(text) {
    return String(text || "").split(/\r?\n/)
        .map((l) => l.trim())
        .filter((l) => l && !l.startsWith("#"))
        .map((l) => l.toLowerCase());
}

/**
 * Das Addon aus dem Zip in einen Addon-Ordner schreiben.
 * @returns {{ files: number, restartNeeded: boolean }}  restartNeeded: die
 *   .toc nennt andere Dateien als vorher oder ein Bild ist neu — WoW liest
 *   beides erst nach einem Neustart des Spiels, /reload reicht dafür nicht.
 */
function installAddonFiles(files, dir) {
    const tocPath = path.join(dir, `${wowPaths.ADDON_FOLDER}.toc`);
    let oldToc = "";
    try {
        oldToc = fs.readFileSync(tocPath, "utf8");
    } catch {
        // keine .toc — dann ist ein Neustart ohnehin fällig
    }
    let written = 0;
    let newMedia = false;
    for (const { rel, data } of files) {
        const target = path.join(dir, ...rel.split("/"));
        if (PRESERVED_FILES.includes(rel) && fs.existsSync(target)) continue;
        // .lua und .toc deckt der Vergleich der .toc ab; alles andere (Bilder)
        // kennt das Spiel nur, wenn es beim Start schon da war.
        if (!/\.(lua|toc)$/i.test(rel) && !fs.existsSync(target)) newMedia = true;
        fs.mkdirSync(path.dirname(target), { recursive: true });
        writeAtomic(target, data);
        written += 1;
    }
    const newToc = files.find((f) => f.rel === `${wowPaths.ADDON_FOLDER}.toc`).data.toString("utf8");
    const before = tocFiles(oldToc).join("\n");
    return { files: written, restartNeeded: newMedia || before !== tocFiles(newToc).join("\n") };
}

// ---------------------------------------------------------------------------
// Die .exe
// ---------------------------------------------------------------------------

/** Wohin die alte .exe beim Austausch wandert. */
function oldExePath(exePath) {
    return exePath.replace(/\.exe$/i, "") + ".old.exe";
}

/**
 * Die laufende .exe durch `data` ersetzen. Gibt es dabei ein Problem, bleibt
 * die alte an ihrem Platz.
 */
function replaceExe(data, exePath) {
    const next = `${exePath}.new`;
    const old = oldExePath(exePath);
    try {
        fs.writeFileSync(next, data);
    } catch (e) {
        throw new UpdateError(`Kann im Ordner ${path.dirname(exePath)} nicht schreiben (${e.code || e.message}). `
            + "Bitte die neue Version von Hand herunterladen.");
    }
    try {
        fs.rmSync(old, { force: true });
        fs.renameSync(exePath, old);
    } catch (e) {
        fs.rmSync(next, { force: true });
        throw new UpdateError(`Die laufende .exe liess sich nicht zur Seite legen (${e.code || e.message}).`);
    }
    try {
        fs.renameSync(next, exePath);
    } catch (e) {
        fs.renameSync(old, exePath);
        fs.rmSync(next, { force: true });
        throw new UpdateError(`Die neue .exe liess sich nicht einsetzen (${e.code || e.message}).`);
    }
}

/** Die nach einem Update liegengebliebene alte .exe entfernen (best effort). */
function cleanupOldExe(exePath) {
    for (const file of [oldExePath(exePath), `${exePath}.new`]) {
        try {
            fs.rmSync(file, { force: true });
        } catch {
            // Läuft der alte Prozess noch, klappt es beim nächsten Mal.
        }
    }
}

/** Die (neue) .exe starten, losgelöst von diesem Prozess. */
function relaunch(exePath, { spawnImpl = spawn } = {}) {
    const child = spawnImpl(exePath, [], { detached: true, stdio: "ignore" });
    if (child && child.on) child.on("error", () => {});
    if (child && child.unref) child.unref();
}

// ---------------------------------------------------------------------------
// Der laufende Betrieb
// ---------------------------------------------------------------------------

/**
 * @param {object} options
 * @param {() => object} options.getConfig  die aktuelle Konfiguration (für die Addon-Ordner)
 * @param {(level: string, text: string) => void} [options.log]
 * @param {boolean} [options.canSelfUpdate]  nur die gepackte .exe kann sich selbst ersetzen
 * @param {string} [options.exePath]
 * @param {() => void} [options.onRestart]  nach dem Austausch der .exe: alles beenden
 *   und die neue starten (index.js)
 * @param {string} [options.toolVersion]
 * @param {Function} [options.fetchImpl]
 * @param {Function} [options.addonDirs]  nur für Tests
 */
function createUpdater(options) {
    const {
        getConfig, log = () => {}, canSelfUpdate = false, exePath = process.execPath, onRestart,
        toolVersion = SYNC_VERSION, fetchImpl = (...args) => fetch(...args),
    } = options;
    const listAddonDirs = options.addonDirs || (() => {
        const cfg = getConfig() || {};
        return wowPaths.describeAddonDirs(cfg.extraRoots || [], { savedVariablesPath: cfg.savedVariablesPath || "" });
    });

    const state = {
        toolVersion,
        canSelfUpdate,
        releasesPage: RELEASES_PAGE,
        checking: false,
        checkedAt: 0,
        /** Das neueste Release: { version, url, publishedAt }, oder null. */
        latest: null,
        toolOutdated: false,
        /** Installierte Addon-Ordner, die älter sind als das Release. */
        addons: [],
        available: false,
        installing: false,
        lastError: null,
        /** { at, addons: [{ label, dir, files, restartNeeded }], restarting } */
        lastInstall: null,
    };
    let release = null;
    let firstTimer = null;
    let timer = null;
    let announced = "";
    let lastLoggedError = "";
    let evaluatedAt = 0;

    function evaluate() {
        if (!release) return;
        evaluatedAt = Date.now();
        const latest = release.version;
        state.toolOutdated = wowPaths.compareVersions(toolVersion, latest) < 0;
        let dirs = [];
        try {
            dirs = listAddonDirs() || [];
        } catch {
            dirs = [];
        }
        state.addons = dirs
            .filter((d) => !d.version || wowPaths.compareVersions(d.version, latest) < 0)
            .map((d) => ({ label: d.label || d.flavor, dir: d.dir, version: d.version || "" }));
        state.available = state.toolOutdated || state.addons.length > 0;
    }

    async function check() {
        if (state.checking) return state;
        state.checking = true;
        try {
            release = await fetchLatestRelease({ fetchImpl });
            state.latest = { version: release.version, url: release.url, publishedAt: release.publishedAt };
            state.lastError = null;
            lastLoggedError = "";
            evaluate();
            if (state.available && announced !== release.version) {
                announced = release.version;
                const parts = [];
                if (state.toolOutdated) parts.push(`Sync-Tool ${toolVersion}`);
                for (const a of state.addons) parts.push(`Addon ${a.label} ${a.version || "?"}`);
                log("info", `Update verfügbar: ${release.version} (installiert: ${parts.join(", ")}).`);
            }
        } catch (e) {
            state.lastError = { at: Date.now(), message: e.message };
            // Offline oder gedrosselt: einmal sagen, nicht alle sechs Stunden.
            if (lastLoggedError !== e.message) log("warn", `Update-Prüfung: ${e.message}`);
            lastLoggedError = e.message;
        } finally {
            state.checkedAt = Date.now();
            state.checking = false;
        }
        return state;
    }

    /**
     * Alles Veraltete einspielen: erst das Addon in jedem Ordner, dann — falls
     * nötig und möglich — die .exe samt Neustart.
     * @returns {Promise<{ addons: object[], restarting: boolean }>}
     */
    async function install() {
        if (state.installing) throw new UpdateError("Ein Update läuft bereits.");
        state.installing = true;
        try {
            await check();
            if (!release) throw new UpdateError(state.lastError ? state.lastError.message : "Kein Release gefunden.");
            if (!state.available) return { addons: [], restarting: false };

            const addons = [];
            if (state.addons.length) {
                const files = addonFiles(readZip(await download(release.zip, { fetchImpl })));
                for (const a of state.addons) {
                    try {
                        const r = installAddonFiles(files, a.dir);
                        addons.push({ label: a.label, dir: a.dir, files: r.files, restartNeeded: r.restartNeeded });
                        log("info", `Addon ${a.label} auf ${release.version} aktualisiert`
                            + `${r.restartNeeded ? " — WoW neu starten (neue Dateien)" : " — im Spiel /reload"}.`);
                    } catch (e) {
                        addons.push({ label: a.label, dir: a.dir, error: e.message });
                        log("error", `Addon ${a.label} nicht aktualisiert: ${e.message}`);
                    }
                }
            }

            let restarting = false;
            if (state.toolOutdated && canSelfUpdate) {
                replaceExe(await download(release.exe, { fetchImpl }), exePath);
                log("info", `Sync-Tool auf ${release.version} aktualisiert — starte neu.`);
                restarting = true;
            }

            state.lastInstall = { at: Date.now(), version: release.version, addons, restarting };
            evaluate();
            if (restarting && onRestart) setTimeout(onRestart, 300);
            const failed = addons.find((a) => a.error);
            if (failed && !restarting) throw new UpdateError(`Addon ${failed.label}: ${failed.error}`);
            return { addons, restarting };
        } catch (e) {
            state.lastError = { at: Date.now(), message: e.message };
            throw e;
        } finally {
            state.installing = false;
        }
    }

    function start() {
        if (canSelfUpdate) cleanupOldExe(exePath);
        firstTimer = setTimeout(() => {
            if (canSelfUpdate) cleanupOldExe(exePath);
            check();
        }, FIRST_CHECK_MS);
        timer = setInterval(check, CHECK_INTERVAL_MS);
    }

    function stop() {
        if (firstTimer) clearTimeout(firstTimer);
        if (timer) clearInterval(timer);
        firstTimer = null;
        timer = null;
    }

    /**
     * Für /api/state (alle 3 s): ab und zu neu bewerten, damit ein von Hand
     * aktualisierter Addon-Ordner aus der Liste fällt — aber nicht bei jedem
     * Abruf alle Laufwerke durchsuchen.
     */
    function snapshot() {
        if (release && !state.installing && Date.now() - evaluatedAt > SNAPSHOT_TTL_MS) evaluate();
        return state;
    }

    return { state, check, install, start, stop, snapshot };
}

module.exports = {
    createUpdater, fetchLatestRelease, parseRelease, download, readZip, addonFiles, tocFiles, installAddonFiles,
    replaceExe, cleanupOldExe, oldExePath, relaunch, UpdateError,
    REPO, LATEST_URL, RELEASES_PAGE, CHECK_INTERVAL_MS, FIRST_CHECK_MS, PRESERVED_FILES,
};
