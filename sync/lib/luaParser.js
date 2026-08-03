"use strict";

/**
 * Parser für WoW-SavedVariables.
 *
 * Eine SavedVariables-Datei ist gültiges Lua, aber ein stark eingeschränkter
 * Ausschnitt davon: nur Zuweisungen auf oberster Ebene, deren Werte aus
 * Tabellen-Konstruktoren, Strings, Zahlen, Booleans und nil bestehen. Genau das
 * — und nichts darüber hinaus — versteht dieser Parser.
 *
 * Warum nicht einfach eine Lua-Laufzeit einbinden: Die Datei stammt aus einem
 * Verzeichnis, in das jedes beliebige Addon schreibt. Sie als Code auszuführen
 * hiesse, fremden Code auszuführen. Ein Parser kann nur Daten zurückgeben.
 *
 * Beispiel für das, was WoW schreibt:
 *
 *   EventHelperSyncDB = {
 *       ["settings"] = {
 *           ["lookbackDays"] = 21,
 *           ["debug"] = false,
 *       },
 *       ["sessions"] = {
 *           {
 *               ["sessionId"] = "eh-123-ssc",
 *           }, -- [1]
 *       },
 *   }
 */

class LuaParseError extends Error {
    constructor(message, index) {
        super(index === undefined ? message : `${message} (Position ${index})`);
        this.name = "LuaParseError";
        this.index = index;
    }
}

// Lua-Escape-Sequenzen, die WoW tatsächlich schreibt.
const SIMPLE_ESCAPES = {
    n: "\n", t: "\t", r: "\r", a: "\x07", b: "\b", f: "\f", v: "\v",
    "\\": "\\", '"': '"', "'": "'", "\n": "\n",
};

class Parser {
    constructor(text) {
        this.text = String(text);
        this.pos = 0;
    }

    error(message) {
        return new LuaParseError(message, this.pos);
    }

    eof() {
        return this.pos >= this.text.length;
    }

    peek() {
        return this.text[this.pos];
    }

    /** Whitespace und Kommentare überspringen (auch --[[ ... ]]). */
    skip() {
        for (;;) {
            while (!this.eof() && /\s/.test(this.text[this.pos])) this.pos += 1;
            if (this.text.startsWith("--", this.pos)) {
                // Blockkommentar --[[ ... ]] bzw. --[=[ ... ]=]
                const block = /^--\[(=*)\[/.exec(this.text.slice(this.pos));
                if (block) {
                    const close = `]${block[1]}]`;
                    const end = this.text.indexOf(close, this.pos + block[0].length);
                    this.pos = end === -1 ? this.text.length : end + close.length;
                    continue;
                }
                const nl = this.text.indexOf("\n", this.pos);
                this.pos = nl === -1 ? this.text.length : nl + 1;
                continue;
            }
            return;
        }
    }

    expect(char) {
        this.skip();
        if (this.text[this.pos] !== char) {
            throw this.error(`Erwartet wurde „${char}", gefunden „${this.text[this.pos] || "<Dateiende>"}"`);
        }
        this.pos += 1;
    }

    parseString() {
        const quote = this.text[this.pos];
        this.pos += 1;
        let out = "";
        while (!this.eof()) {
            const ch = this.text[this.pos];
            if (ch === quote) {
                this.pos += 1;
                return out;
            }
            if (ch === "\\") {
                this.pos += 1;
                const esc = this.text[this.pos];
                if (esc === undefined) throw this.error("Zeichenkette endet mitten in einer Escape-Sequenz");
                if (esc === "x") {
                    // \xHH
                    const hex = this.text.substr(this.pos + 1, 2);
                    if (!/^[0-9a-fA-F]{2}$/.test(hex)) throw this.error("Ungültige \\x-Escape-Sequenz");
                    out += String.fromCharCode(parseInt(hex, 16));
                    this.pos += 3;
                    continue;
                }
                if (/[0-9]/.test(esc)) {
                    // \d, \dd, \ddd — WoW nutzt das für Sonderzeichen.
                    const digits = /^[0-9]{1,3}/.exec(this.text.slice(this.pos))[0];
                    out += String.fromCharCode(parseInt(digits, 10));
                    this.pos += digits.length;
                    continue;
                }
                out += SIMPLE_ESCAPES[esc] !== undefined ? SIMPLE_ESCAPES[esc] : esc;
                this.pos += 1;
                continue;
            }
            out += ch;
            this.pos += 1;
        }
        throw this.error("Nicht abgeschlossene Zeichenkette");
    }

    parseNumber() {
        const rest = this.text.slice(this.pos);
        const match = /^-?(0[xX][0-9a-fA-F]+|(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?)/.exec(rest);
        if (!match) throw this.error("Ungültige Zahl");
        this.pos += match[0].length;
        return Number(match[0]);
    }

    /**
     * Tabellen-Konstruktor. Ergibt ein Array, wenn ausschliesslich positionelle
     * Einträge vorkommen (so schreibt WoW Listen), sonst ein Objekt.
     */
    parseTable() {
        this.expect("{");
        const map = new Map();
        let nextIndex = 1;
        let positionalOnly = true;

        for (;;) {
            this.skip();
            if (this.eof()) throw this.error("Nicht abgeschlossene Tabelle");
            if (this.peek() === "}") {
                this.pos += 1;
                break;
            }

            let key = null;
            if (this.peek() === "[") {
                // ["name"] = ... oder [3] = ...
                this.pos += 1;
                this.skip();
                key = this.parseValue();
                this.skip();
                this.expect("]");
                this.expect("=");
                positionalOnly = false;
            } else {
                // Nackter Bezeichner als Schlüssel (name = ...) — nur wenn ein
                // "=" folgt, sonst ist es ein positioneller Wert.
                const ident = /^[A-Za-z_][A-Za-z0-9_]*/.exec(this.text.slice(this.pos));
                if (ident) {
                    const after = this.pos + ident[0].length;
                    const probe = this.text.slice(after).match(/^\s*=(?!=)/);
                    if (probe) {
                        key = ident[0];
                        this.pos = after + probe[0].length;
                        positionalOnly = false;
                    }
                }
            }

            const value = key === null ? this.parseValue() : this.parseValue();
            if (key === null) {
                map.set(nextIndex, value);
                nextIndex += 1;
            } else {
                map.set(key, value);
            }

            this.skip();
            if (this.peek() === "," || this.peek() === ";") {
                this.pos += 1;
                continue;
            }
            this.skip();
            if (this.peek() === "}") {
                this.pos += 1;
                break;
            }
            if (this.eof()) throw this.error("Nicht abgeschlossene Tabelle");
            throw this.error(`Unerwartetes Zeichen „${this.peek()}" in einer Tabelle`);
        }

        if (positionalOnly) {
            const arr = [];
            for (let i = 1; map.has(i); i += 1) arr.push(map.get(i));
            // Nur dann ein echtes Array, wenn die Indizes lückenlos bei 1 beginnen.
            if (arr.length === map.size) return arr;
        }
        const obj = {};
        for (const [key, value] of map) obj[String(key)] = value;
        return obj;
    }

    parseValue() {
        this.skip();
        if (this.eof()) throw this.error("Wert erwartet, Datei zu Ende");
        const ch = this.peek();

        if (ch === "{") return this.parseTable();
        if (ch === '"' || ch === "'") return this.parseString();
        if (ch === "-" && !this.text.startsWith("--", this.pos)) return this.parseNumber();
        if (/[0-9.]/.test(ch)) return this.parseNumber();

        if (this.text.startsWith("true", this.pos)) { this.pos += 4; return true; }
        if (this.text.startsWith("false", this.pos)) { this.pos += 5; return false; }
        if (this.text.startsWith("nil", this.pos)) { this.pos += 3; return null; }

        // [[ ... ]] — lange Zeichenkette.
        const long = /^\[(=*)\[/.exec(this.text.slice(this.pos));
        if (long) {
            const close = `]${long[1]}]`;
            const start = this.pos + long[0].length;
            const end = this.text.indexOf(close, start);
            if (end === -1) throw this.error("Nicht abgeschlossene lange Zeichenkette");
            this.pos = end + close.length;
            return this.text.slice(start, end).replace(/^\r?\n/, "");
        }

        throw this.error(`Unerwarteter Wert bei „${this.text.slice(this.pos, this.pos + 12)}…"`);
    }
}

/**
 * Alle Zuweisungen auf oberster Ebene einer SavedVariables-Datei.
 * @param {string} text Dateiinhalt
 * @returns {Record<string, unknown>} z.B. { EventHelperSyncDB: { … } }
 */
function parseSavedVariables(text) {
    const parser = new Parser(text);
    const out = {};

    for (;;) {
        parser.skip();
        if (parser.eof()) break;

        const ident = /^[A-Za-z_][A-Za-z0-9_]*/.exec(parser.text.slice(parser.pos));
        if (!ident) throw parser.error("Variablenname erwartet");
        parser.pos += ident[0].length;
        parser.expect("=");
        out[ident[0]] = parser.parseValue();

        parser.skip();
        // WoW schreibt keine Semikolons, aber sie wären gültig.
        if (parser.peek() === ";") parser.pos += 1;
    }

    return out;
}

module.exports = { parseSavedVariables, LuaParseError };
