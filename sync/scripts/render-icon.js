#!/usr/bin/env node
"use strict";

/**
 * Erzeugt assets/icon.ico aus assets/icon.svg — das Icon der .exe.
 *
 * Gerendert wird mit dem installierten Edge/Chrome (über puppeteer-core, also
 * ohne einen eigenen Browser herunterzuladen): das kantenglättet die SVG so,
 * wie sie auch im Fenster aussieht. Jede Größe wird einzeln gerendert statt
 * aus 256 px herunterskaliert — das bleibt bei 16 px schärfer.
 *
 * Nur nötig, wenn sich icon.svg ändert. Das Ergebnis wird eingecheckt; der
 * Release-Build (build-exe.js) liest nur die fertige .ico.
 *
 * Aufruf:  npm run build:icon
 */
const fs = require("fs");
const path = require("path");
const puppeteer = require("puppeteer-core");
const { findBrowser } = require("../lib/appWindow");
const { buildIco } = require("./exeResources");

const ASSETS = path.join(__dirname, "..", "assets");
const SVG = path.join(ASSETS, "icon.svg");
const ICO = path.join(ASSETS, "icon.ico");

// Was Windows je nach Ansicht und Bildschirmskalierung anfragt: 16/20/24/32
// für Taskleiste und Listen bei 100–200 %, 48+ für die Explorer-Kacheln.
const SIZES = [16, 20, 24, 32, 40, 48, 64, 128, 256];

async function main() {
    const browserPath = findBrowser();
    if (!browserPath) throw new Error("Kein Edge/Chrome gefunden — wird zum Rendern gebraucht.");

    const svg = fs.readFileSync(SVG, "utf8");
    const dataUri = "data:image/svg+xml;base64," + Buffer.from(svg).toString("base64");

    const browser = await puppeteer.launch({ executablePath: browserPath, headless: true });
    try {
        const page = await browser.newPage();
        const images = [];
        for (const size of SIZES) {
            await page.setViewport({ width: size, height: size, deviceScaleFactor: 1 });
            await page.setContent(
                "<html><body style=\"margin:0;background:transparent\">"
                + `<img src="${dataUri}" width="${size}" height="${size}" style="display:block">`
                + "</body></html>",
            );
            await page.waitForSelector("img");
            const png = await page.screenshot({
                omitBackground: true,
                clip: { x: 0, y: 0, width: size, height: size },
            });
            images.push({ size, png: Buffer.from(png) });
        }
        fs.writeFileSync(ICO, buildIco(images));
        console.log(`${path.relative(process.cwd(), ICO)}: ${SIZES.join(", ")} px`);
    } finally {
        await browser.close();
    }
}

main().catch((e) => {
    console.error(e.message);
    process.exit(1);
});
