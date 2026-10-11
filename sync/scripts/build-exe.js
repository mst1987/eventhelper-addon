#!/usr/bin/env node
"use strict";

/**
 * Baut eine eigenständige EventHelperSync.exe — eine Datei, die ohne
 * installiertes Node.js läuft.
 *
 * Benutzt Nodes eingebaute Single Executable Applications (SEA) statt eines
 * externen Packers: das Verfahren gehört zu Node selbst, funktioniert ab
 * Node 20 und braucht keine Werkzeugkette, die einer eigenen Versionspflege
 * bedarf.
 *
 * Die Schritte:
 *   1. esbuild fasst index.js samt lib/ zu einer einzigen CommonJS-Datei
 *      zusammen. SEA kann nur ein Bündel aufnehmen, keinen Ordner.
 *   1b. The own window (webview-host/Host.cs, scripts/buildHost.js), built
 *      with the .NET Framework csc.exe, travels along as SEA assets. Without
 *      csc/NuGet the .exe is built without it (Edge --app as before), unless
 *      EHS_REQUIRE_HOST=1.
 *   2. `node --experimental-sea-config` macht daraus einen Blob.
 *   3. postject spleisst den Blob in eine Kopie der node.exe.
 *   4. Die .exe bekommt Icon und Versionsinfos (Windows).
 *   5. Das PE-Subsystem wird auf GUI gestellt (Windows): kein
 *      Konsolenfenster beim Doppelklick. Warum: scripts/exeResources.js.
 *
 * Aufruf:  npm run build:exe
 * Ergebnis: dist/EventHelperSync.exe
 */
const { execFileSync } = require("child_process");
const fs = require("fs");
const path = require("path");
const esbuild = require("esbuild");
const { applyResources, setSubsystem, SUBSYSTEM } = require("./exeResources");
const { buildHost, seaAssets } = require("./buildHost");
const { version } = require("../package.json");

const ROOT = path.join(__dirname, "..");
const ICON = path.join(ROOT, "assets", "icon.ico");
const BUILD = path.join(ROOT, "build");
const DIST = path.join(ROOT, "dist");

const BUNDLE = path.join(BUILD, "bundle.js");
const SEA_CONFIG = path.join(BUILD, "sea-config.json");
const BLOB = path.join(BUILD, "sea-prep.blob");

// Der Name, den die fertige Datei trägt. Bewusst derselbe wie der des Addons,
// damit im Download-Ordner erkennbar bleibt, wozu die .exe gehört.
const EXE = path.join(DIST, process.platform === "win32" ? "EventHelperSync.exe" : "EventHelperSync");

// Von Node vorgegeben — postject muss genau diese Marke in der Binärdatei finden.
const FUSE = "NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2";

function step(message) {
    console.log(`\n[36m>[0m ${message}`);
}

function humanSize(file) {
    return `${(fs.statSync(file).size / 1024 / 1024).toFixed(1)} MB`;
}

async function main() {
    const major = Number(process.versions.node.split(".")[0]);
    if (major < 20) {
        console.error(`Zum Bauen wird Node 20 oder neuer gebraucht (läuft: ${process.version}).`);
        process.exit(1);
    }

    // Everything but build/cache/ (the WebView2 NuGet package, scripts/buildHost.js).
    fs.mkdirSync(BUILD, { recursive: true });
    for (const name of fs.readdirSync(BUILD)) {
        if (name !== "cache") fs.rmSync(path.join(BUILD, name), { recursive: true, force: true });
    }
    fs.mkdirSync(DIST, { recursive: true });

    step("Bündele den Quelltext …");
    esbuild.buildSync({
        entryPoints: [path.join(ROOT, "scripts", "sea-entry.js")],
        bundle: true,
        platform: "node",
        format: "cjs",
        target: `node${major}`,
        outfile: BUNDLE,
        // package.json wird von uploader.js für die Versionsnummer eingelesen;
        // esbuild bettet die JSON-Datei beim Bündeln direkt ein.
        logLevel: "warning",
    });
    console.log(`  ${path.relative(ROOT, BUNDLE)} (${humanSize(BUNDLE)})`);

    step("Baue das eigene Fenster (WebView2) …");
    const host = await buildHost({ root: ROOT, buildDir: BUILD, version, log: (line) => console.log(line) });
    if (host.skipped) {
        if (process.env.EHS_REQUIRE_HOST === "1") {
            throw new Error(`Fenster nicht gebaut: ${host.skipped}`);
        }
        console.log(`  übersprungen: ${host.skipped}`);
        console.log("  Die .exe öffnet ihre Oberfläche dann wie bisher mit Edge/Chrome --app.");
    } else {
        for (const file of Object.values(host.files)) console.log(`  ${path.relative(ROOT, file)} (${humanSize(file)})`);
    }

    step("Erzeuge den SEA-Blob …");
    fs.writeFileSync(SEA_CONFIG, JSON.stringify({
        main: BUNDLE,
        output: BLOB,
        disableExperimentalSEAWarning: true,
        // Das Bündel ist bereits vollständig aufgelöst — der Snapshot brächte
        // hier nichts ausser einer weiteren Fehlerquelle.
        useSnapshot: false,
        useCodeCache: false,
        // The window program and its DLLs (lib/webviewHost.js extracts them).
        assets: seaAssets(host),
    }, null, 2));
    execFileSync(process.execPath, ["--experimental-sea-config", SEA_CONFIG], { stdio: "inherit" });
    console.log(`  ${path.relative(ROOT, BLOB)} (${humanSize(BLOB)})`);

    step("Kopiere die Node-Laufzeit …");
    fs.copyFileSync(process.execPath, EXE);
    console.log(`  ${path.relative(ROOT, EXE)} (${humanSize(EXE)})`);

    step("Spleisse den Blob ein …");
    // postject wird als Programm aufgerufen, nicht als Bibliothek: seine API ist
    // ESM, und dieses Projekt ist durchgehend CommonJS.
    const postject = path.join(ROOT, "node_modules", ".bin", process.platform === "win32" ? "postject.cmd" : "postject");
    execFileSync(postject, [
        EXE, "NODE_SEA_BLOB", BLOB,
        "--sentinel-fuse", FUSE,
        ...(process.platform === "darwin" ? ["--macho-segment-name", "NODE_SEA"] : []),
    ], { stdio: "inherit", shell: process.platform === "win32" });

    if (process.platform === "win32") {
        // Erst nach postject: resedit auf der unveränderten, signierten
        // node.exe hinterlässt eine Relocation-Tabelle, die postjects
        // PE-Parser (LIEF) als beschädigt meldet. Auf postjects Ergebnis
        // angewandt ist sie sauber, und der Blob überlebt als gewöhnliche
        // Ressource (test/exeResources.test.js prüft genau diese Reihenfolge
        // bis zum Start der fertigen .exe).
        step("Setze Icon und Versionsinfos …");
        await applyResources(EXE, { icoPath: ICON, version });
        console.log(`  ${path.relative(ROOT, ICON)}, EventHelper Sync ${version}`);

        step("Stelle auf Windows-GUI-Programm um …");
        const buf = fs.readFileSync(EXE);
        const previous = setSubsystem(buf, SUBSYSTEM.GUI);
        fs.writeFileSync(EXE, buf);
        console.log(`  Subsystem ${previous} -> ${SUBSYSTEM.GUI} (kein Konsolenfenster)`);
    }

    console.log(`\n[32mFertig:[0m ${EXE} (${humanSize(EXE)})`);
    console.log("Diese Datei läuft ohne installiertes Node.js.");
    console.log("Hinweis: die Signatur der node.exe geht durch das Einspleissen verloren —");
    console.log("Windows SmartScreen kann beim ersten Start nachfragen.");
}

main().catch((e) => {
    console.error(e.stack || e.message);
    process.exit(1);
});
