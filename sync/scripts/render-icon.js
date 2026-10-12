#!/usr/bin/env node
"use strict";

/**
 * Erzeugt aus assets/icon.svg (der EventHelper-Marke):
 *   - assets/icon.ico — das Icon der .exe
 *   - addon/EventHelperSync/media/logo.tga — das Wappen der Addon-Fenster
 *   - addon/EventHelperSync/media/logo-round.tga — der Minimap-Knopf (rund,
 *     damit er in den runden Rahmen der Minimap passt)
 *
 * Gerendert wird mit dem installierten Edge/Chrome (über puppeteer-core, also
 * ohne einen eigenen Browser herunterzuladen): das kantenglättet die SVG so,
 * wie sie auch im Fenster aussieht. Jede Größe wird einzeln gerendert statt
 * aus 256 px herunterskaliert — das bleibt bei 16 px schärfer.
 *
 * Nur nötig, wenn sich icon.svg ändert. Die Ergebnisse werden eingecheckt; der
 * Release-Build (build-exe.js) liest nur die fertige .ico, das Addon-Zip
 * nimmt die .tga mit.
 *
 * Aufruf:  npm run build:icon
 */
const fs = require("fs");
const path = require("path");
const puppeteer = require("puppeteer-core");
const { findBrowser } = require("../lib/appWindow");
const { buildIco } = require("./exeResources");
const { buildTga } = require("./tga");

const ASSETS = path.join(__dirname, "..", "assets");
const SVG = path.join(ASSETS, "icon.svg");
const ICO = path.join(ASSETS, "icon.ico");
const MEDIA = path.join(__dirname, "..", "..", "addon", "EventHelperSync", "media");

// Was Windows je nach Ansicht und Bildschirmskalierung anfragt: 16/20/24/32
// für Taskleiste und Listen bei 100–200 %, 48+ für die Explorer-Kacheln.
const SIZES = [16, 20, 24, 32, 40, 48, 64, 128, 256];

// Im Spiel erscheint die Marke mit 16–24 px; 64 px lässt der Grafikkarte
// genug zum Verkleinern und bleibt eine Zweierpotenz.
const TGA_SIZE = 64;

/**
 * Die runde Fassung für die Minimap: Kreis statt abgerundetem Quadrat, der
 * Kalender etwas kleiner, damit seine Ecken im Kreis bleiben.
 */
function roundSvg(svg) {
    const out = svg
        .replace(/<rect width="64" height="64" rx="15"([^>]*)\/>/, "<circle cx=\"32\" cy=\"32\" r=\"32\"$1/>")
        .replace("<g fill=\"none\"", "<g transform=\"translate(32 32) scale(.8) translate(-32 -32)\" fill=\"none\"");
    if (out === svg || !out.includes("<circle") || !out.includes("scale(.8)")) {
        throw new Error("icon.svg hat nicht mehr den erwarteten Aufbau — roundSvg() anpassen.");
    }
    return out;
}

function dataUri(svg) {
    return "data:image/svg+xml;base64," + Buffer.from(svg).toString("base64");
}

async function renderPng(page, svg, size) {
    await page.setViewport({ width: size, height: size, deviceScaleFactor: 1 });
    await page.setContent(
        "<html><body style=\"margin:0;background:transparent\">"
        + `<img src="${dataUri(svg)}" width="${size}" height="${size}" style="display:block">`
        + "</body></html>",
    );
    await page.waitForSelector("img");
    const png = await page.screenshot({
        omitBackground: true,
        clip: { x: 0, y: 0, width: size, height: size },
    });
    return Buffer.from(png);
}

/* global Image, document -- die Funktion in page.evaluate läuft im Browser */

/** Die Pixel als RGBA (ohne vormultipliziertes Alpha), über ein Canvas. */
async function renderRgba(page, svg, size) {
    await page.setContent("<html><body></body></html>");
    const bytes = await page.evaluate(async (src, n) => {
        const img = new Image();
        img.src = src;
        await img.decode();
        const canvas = document.createElement("canvas");
        canvas.width = n;
        canvas.height = n;
        const ctx = canvas.getContext("2d");
        ctx.drawImage(img, 0, 0, n, n);
        return Array.from(ctx.getImageData(0, 0, n, n).data);
    }, dataUri(svg), size);
    return Uint8Array.from(bytes);
}

async function main() {
    const browserPath = findBrowser();
    if (!browserPath) throw new Error("Kein Edge/Chrome gefunden — wird zum Rendern gebraucht.");

    const svg = fs.readFileSync(SVG, "utf8");

    const browser = await puppeteer.launch({ executablePath: browserPath, headless: true });
    try {
        const page = await browser.newPage();
        const images = [];
        for (const size of SIZES) images.push({ size, png: await renderPng(page, svg, size) });
        fs.writeFileSync(ICO, buildIco(images));
        console.log(`${path.relative(process.cwd(), ICO)}: ${SIZES.join(", ")} px`);

        fs.mkdirSync(MEDIA, { recursive: true });
        for (const [name, source] of [["logo.tga", svg], ["logo-round.tga", roundSvg(svg)]]) {
            const file = path.join(MEDIA, name);
            fs.writeFileSync(file, buildTga(TGA_SIZE, TGA_SIZE, await renderRgba(page, source, TGA_SIZE)));
            console.log(`${path.relative(process.cwd(), file)}: ${TGA_SIZE} px`);
        }
    } finally {
        await browser.close();
    }
}

main().catch((e) => {
    console.error(e.message);
    process.exit(1);
});
