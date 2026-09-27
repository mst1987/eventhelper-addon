"use strict";

/**
 * Was scripts/build-exe.js an der kopierten node.exe ändert, damit daraus ein
 * eigenes Programm wird und nicht "Node.js" mit fremdem Inhalt:
 *
 *   - Icon und Versionsinfos (Explorer, Taskleiste, Task-Manager zeigen
 *     "EventHelper Sync" statt des Node-Sechsecks),
 *   - das PE-Subsystem: Konsole -> Windows-GUI. Ein Konsolenprogramm bekommt
 *     von Windows beim Doppelklick immer ein Konsolenfenster, bevor auch nur
 *     eine Zeile JavaScript läuft — nachträglich verstecken hiess, es blitzt
 *     trotzdem auf. Als GUI-Programm entsteht gar keins. Node kommt damit
 *     zurecht: fehlen die Standard-Handles, legt es sie beim Start auf NUL.
 *
 * Die reinen Byte-Funktionen (buildIco, setSubsystem) sind ohne Datei und ohne
 * Windows testbar; nur applyResources() braucht resedit.
 */
const fs = require("fs");

const SUBSYSTEM = { GUI: 2, CONSOLE: 3 };

/**
 * Eine .ico-Datei aus fertigen PNG-Bildern zusammensetzen. Seit Windows Vista
 * darf jeder Eintrag ein PNG sein — kein Umrechnen in Bitmaps nötig.
 * @param {{ size: number, png: Buffer }[]} images
 * @returns {Buffer}
 */
function buildIco(images) {
    if (!images.length) throw new Error("buildIco: keine Bilder.");
    const HEADER = 6;
    const ENTRY = 16;
    const header = Buffer.alloc(HEADER);
    header.writeUInt16LE(0, 0); // reserviert
    header.writeUInt16LE(1, 2); // Typ 1 = Icon
    header.writeUInt16LE(images.length, 4);

    const entries = Buffer.alloc(ENTRY * images.length);
    let offset = HEADER + entries.length;
    images.forEach(({ size, png }, i) => {
        if (size < 1 || size > 256) throw new Error(`buildIco: Größe ${size} ausserhalb 1–256.`);
        const at = i * ENTRY;
        // 256 wird im Byte als 0 geschrieben — so will es das Format.
        entries.writeUInt8(size === 256 ? 0 : size, at);
        entries.writeUInt8(size === 256 ? 0 : size, at + 1);
        entries.writeUInt8(0, at + 2); // keine Palette
        entries.writeUInt8(0, at + 3); // reserviert
        entries.writeUInt16LE(1, at + 4); // Farbebenen
        entries.writeUInt16LE(32, at + 6); // Bit pro Pixel
        entries.writeUInt32LE(png.length, at + 8);
        entries.writeUInt32LE(offset, at + 12);
        offset += png.length;
    });
    return Buffer.concat([header, entries, ...images.map((img) => img.png)]);
}

/** Wo im Buffer das Subsystem-Feld des PE-Optional-Headers liegt. */
function subsystemOffset(buf) {
    if (buf.length < 0x40 || buf.toString("latin1", 0, 2) !== "MZ") {
        throw new Error("Keine Windows-Programmdatei (MZ-Kopf fehlt).");
    }
    const pe = buf.readUInt32LE(0x3c);
    if (pe + 24 + 70 > buf.length || buf.toString("latin1", pe, pe + 4) !== "PE\0\0") {
        throw new Error("Keine Windows-Programmdatei (PE-Kopf fehlt).");
    }
    // PE-Signatur (4) + COFF-Kopf (20), dann der Optional Header; das Feld
    // Subsystem steht dort bei PE32 und PE32+ gleichermassen an Stelle 68.
    const optional = pe + 24;
    const magic = buf.readUInt16LE(optional);
    if (magic !== 0x10b && magic !== 0x20b) {
        throw new Error(`Unbekannter Optional-Header (0x${magic.toString(16)}).`);
    }
    return optional + 68;
}

/**
 * Das Subsystem im Buffer umstellen (in place).
 * @returns {number} das bisherige Subsystem
 */
function setSubsystem(buf, subsystem) {
    const at = subsystemOffset(buf);
    const previous = buf.readUInt16LE(at);
    buf.writeUInt16LE(subsystem, at);
    return previous;
}

function readSubsystem(buf) {
    return buf.readUInt16LE(subsystemOffset(buf));
}

/**
 * Icon und Versionsinfos in eine .exe schreiben. Nach postject aufrufen (siehe
 * build-exe.js): resedit baut die Ressourcen-Sektion neu und übernimmt den
 * SEA-Blob dabei als gewöhnliche Ressource.
 * @param {string} exePath
 * @param {{ icoPath: string, version: string }} options
 */
async function applyResources(exePath, { icoPath, version }) {
    // resedit ist ESM; der CJS-Einstieg lädt es per dynamischem import().
    const ResEdit = await require("resedit/cjs").load();
    // ignoreCert: die Signatur der node.exe ist nach jeder Änderung ohnehin
    // ungültig — ohne das Flag weigert sich resedit, eine signierte Datei zu lesen.
    const exe = ResEdit.NtExecutable.from(fs.readFileSync(exePath), { ignoreCert: true });
    const res = ResEdit.NtExecutableResource.from(exe);

    const ico = ResEdit.Data.IconFile.from(fs.readFileSync(icoPath));
    // node.exe trägt ihr Icon unter Gruppe 1; wer diese ersetzt, ersetzt das,
    // was Explorer und Taskleiste zeigen.
    const groups = ResEdit.Resource.IconGroupEntry.fromEntries(res.entries);
    const target = groups.length ? groups[0] : { id: 1, lang: 1033 };
    ResEdit.Resource.IconGroupEntry.replaceIconsForResource(
        res.entries, target.id, target.lang, ico.icons.map((icon) => icon.data),
    );

    const parts = version.split(".").map((n) => Number(n) || 0);
    while (parts.length < 4) parts.push(0);
    const infos = ResEdit.Resource.VersionInfo.fromEntries(res.entries);
    const info = infos.length ? infos[0] : ResEdit.Resource.VersionInfo.createEmpty();
    info.setFileVersion(...parts.slice(0, 4));
    info.setProductVersion(...parts.slice(0, 4));
    // Alle Sprachtabellen der node.exe überschreiben, nicht nur die erste —
    // sonst zeigt Windows je nach Sprache weiter "Node.js".
    const langs = info.getAllLanguagesForStringValues();
    for (const lang of langs.length ? langs : [{ lang: 1033, codepage: 1200 }]) {
        info.setStringValues(lang, {
            FileDescription: "EventHelper Sync",
            ProductName: "EventHelper Sync",
            CompanyName: "EventHelper",
            InternalName: "EventHelperSync",
            OriginalFilename: "EventHelperSync.exe",
            LegalCopyright: "MIT License",
            FileVersion: version,
            ProductVersion: version,
        });
    }
    info.outputToResourceEntries(res.entries);

    res.outputResource(exe);
    fs.writeFileSync(exePath, Buffer.from(exe.generate()));
}

module.exports = { buildIco, setSubsystem, readSubsystem, applyResources, SUBSYSTEM };
