"use strict";

const { buildTga } = require("../scripts/tga");

describe("buildTga", () => {
    it("schreibt Kopf und Pixel als BGRA von unten nach oben", () => {
        // 2x2: oben rot, grün; unten blau, halbdurchsichtiges Weiß
        const rgba = [
            255, 0, 0, 255, 0, 255, 0, 255,
            0, 0, 255, 255, 255, 255, 255, 128,
        ];
        const tga = buildTga(2, 2, rgba);

        expect(tga.length).toBe(18 + 16);
        expect(tga[2]).toBe(2);
        expect(tga.readUInt16LE(12)).toBe(2);
        expect(tga.readUInt16LE(14)).toBe(2);
        expect(tga[16]).toBe(32);
        expect(tga[17]).toBe(8);
        // erste gespeicherte Zeile ist die untere des Bildes
        expect([...tga.subarray(18)]).toEqual([
            255, 0, 0, 255, 255, 255, 255, 128,
            0, 0, 255, 255, 0, 255, 0, 255,
        ]);
    });

    it("lehnt Seiten ab, die keine Zweierpotenz sind", () => {
        expect(() => buildTga(3, 4, new Uint8Array(48))).toThrow(/Zweierpotenzen/);
    });

    it("lehnt zu wenige Pixel ab", () => {
        expect(() => buildTga(4, 4, new Uint8Array(10))).toThrow(/statt 64 Bytes/);
    });
});
