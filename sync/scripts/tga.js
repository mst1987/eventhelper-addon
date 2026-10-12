"use strict";

/**
 * Ein Bild als TGA, wie WoW es für Addon-Texturen liest: unkomprimiert,
 * 32 Bit mit Alphakanal, Zeilen von unten nach oben (der Ursprung, den jeder
 * TGA-Leser kennt). Seitenlängen müssen Zweierpotenzen sein, sonst zeigt das
 * Spiel nur ein grünes Viereck.
 *
 * @param {number} width
 * @param {number} height
 * @param {Uint8Array|Buffer|number[]} rgba  width*height*4 Bytes, Zeile für
 *   Zeile von oben, je Pixel R, G, B, A (wie canvas getImageData)
 * @returns {Buffer}
 */
function buildTga(width, height, rgba) {
    const pow2 = (n) => Number.isInteger(n) && n > 0 && (n & (n - 1)) === 0;
    if (!pow2(width) || !pow2(height)) throw new Error(`TGA ${width}x${height}: Seiten müssen Zweierpotenzen sein.`);
    if (!rgba || rgba.length !== width * height * 4) throw new Error(`TGA ${width}x${height}: ${rgba ? rgba.length : 0} statt ${width * height * 4} Bytes.`);

    const header = Buffer.alloc(18);
    header[2] = 2;                       // unkomprimiertes Echtfarbbild
    header.writeUInt16LE(width, 12);
    header.writeUInt16LE(height, 14);
    header[16] = 32;                     // Bit je Pixel
    header[17] = 8;                      // 8 Bit Alpha, Ursprung unten links

    const pixels = Buffer.alloc(width * height * 4);
    for (let y = 0; y < height; y++) {
        const src = y * width * 4;
        const dst = (height - 1 - y) * width * 4;
        for (let x = 0; x < width * 4; x += 4) {
            pixels[dst + x] = rgba[src + x + 2];     // B
            pixels[dst + x + 1] = rgba[src + x + 1]; // G
            pixels[dst + x + 2] = rgba[src + x];     // R
            pixels[dst + x + 3] = rgba[src + x + 3]; // A
        }
    }
    return Buffer.concat([header, pixels]);
}

module.exports = { buildTga };
