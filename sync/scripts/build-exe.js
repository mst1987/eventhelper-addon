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
 * Drei Schritte:
 *   1. esbuild fasst index.js samt lib/ zu einer einzigen CommonJS-Datei
 *      zusammen. SEA kann nur ein Bündel aufnehmen, keinen Ordner.
 *   2. `node --experimental-sea-config` macht daraus einen Blob.
 *   3. postject spleisst den Blob in eine Kopie der node.exe.
 *
 * Aufruf:  npm run build:exe
 * Ergebnis: dist/EventHelperSync.exe
 */
const { execFileSync } = require("child_process");
const fs = require("fs");
const path = require("path");
const esbuild = require("esbuild");

const ROOT = path.join(__dirname, "..");
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

function main() {
    const major = Number(process.versions.node.split(".")[0]);
    if (major < 20) {
        console.error(`Zum Bauen wird Node 20 oder neuer gebraucht (läuft: ${process.version}).`);
        process.exit(1);
    }

    fs.rmSync(BUILD, { recursive: true, force: true });
    fs.mkdirSync(BUILD, { recursive: true });
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

    step("Erzeuge den SEA-Blob …");
    fs.writeFileSync(SEA_CONFIG, JSON.stringify({
        main: BUNDLE,
        output: BLOB,
        disableExperimentalSEAWarning: true,
        // Das Bündel ist bereits vollständig aufgelöst — der Snapshot brächte
        // hier nichts ausser einer weiteren Fehlerquelle.
        useSnapshot: false,
        useCodeCache: false,
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

    console.log(`\n[32mFertig:[0m ${EXE} (${humanSize(EXE)})`);
    console.log("Diese Datei läuft ohne installiertes Node.js.");
    console.log("Hinweis: die Signatur der node.exe geht durch das Einspleissen verloren —");
    console.log("Windows SmartScreen kann beim ersten Start nachfragen.");
}

main();
