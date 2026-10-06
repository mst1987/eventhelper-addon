"use strict";
// Loads the WoW API mock, then the addon files in .toc order (each with the
// (addonName, namespace) varargs WoW passes), then every spec in spec/ in a
// fresh Lua state. A spec fails by raising a Lua error.
//
// Taken over from the DuoLevel/ProfessionKit harness. fengari is Lua 5.3, the
// game runs 5.1: no `unpack` global there, no integer division, and "%d" with
// a float raises here but not in the game - write code that runs on both.
const fs = require("fs");
const path = require("path");
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require("fengari");

const ADDON_NAME = "EventHelperSync";
const ADDON_DIR = path.join(__dirname, "..", "addon", ADDON_NAME);

function tocFiles() {
    const toc = fs.readFileSync(path.join(ADDON_DIR, `${ADDON_NAME}.toc`), "utf8");
    return toc.split(/\r?\n/).map((l) => l.trim()).filter((l) => l && !l.startsWith("#"));
}

function runChunk(L, code, name, pushArgs) {
    const status = lauxlib.luaL_loadbuffer(L, to_luastring(code), to_luastring(name));
    if (status !== lua.LUA_OK) throw new Error(`${name}: ${to_jsstring(lua.lua_tostring(L, -1))}`);
    const nargs = pushArgs ? pushArgs() : 0;
    const base = lua.lua_gettop(L) - nargs - 1;
    // message handler for tracebacks
    lua.lua_pushcfunction(L, (L2) => {
        const msg = lua.lua_tostring(L2, 1);
        lauxlib.luaL_traceback(L2, L2, msg, 1);
        return 1;
    });
    lua.lua_insert(L, base + 1);
    const call = lua.lua_pcall(L, nargs, 0, base + 1);
    if (call !== lua.LUA_OK) {
        const message = to_jsstring(lua.lua_tostring(L, -1));
        lua.lua_settop(L, base);
        throw new Error(message);
    }
    lua.lua_settop(L, base);
}

function loadAddon(L) {
    for (const file of tocFiles()) {
        const code = fs.readFileSync(path.join(ADDON_DIR, file), "utf8");
        runChunk(L, code, `${ADDON_NAME}/${file}`, () => {
            lua.lua_pushstring(L, to_luastring(ADDON_NAME));
            lua.lua_newtable(L);
            return 2;
        });
    }
}

// A spec first sets up the client (which events it knows, WOW_PROJECT_ID, ...)
// and then calls loadAddon(), the moment the game would load the addon files.
function newState() {
    const L = lauxlib.luaL_newstate();
    lualib.luaL_openlibs(L);
    runChunk(L, fs.readFileSync(path.join(__dirname, "mock", "wow.lua"), "utf8"), "mock/wow.lua");
    lua.lua_pushcfunction(L, (L2) => {
        try {
            loadAddon(L2);
        } catch (err) {
            lua.lua_pushstring(L2, to_luastring(err.message));
            return lua.lua_error(L2);
        }
        return 0;
    });
    lua.lua_setglobal(L, to_luastring("loadAddon"));
    return L;
}

// The string literals of a Lua file (comments skipped) as raw byte arrays:
// "..." and '...' with their escapes decoded, [[...]] / [==[...]==] verbatim.
function luaStrings(code) {
    const out = [];
    const bytes = (text) => [...Buffer.from(text, "utf8")];
    let i = 0;
    const longBracket = (at) => {
        const m = /^\[(=*)\[/.exec(code.slice(at, at + 64));
        return m ? m[1].length : -1;
    };
    while (i < code.length) {
        const c = code[i];
        if (c === "-" && code[i + 1] === "-") {
            const level = longBracket(i + 2);
            if (level >= 0) {
                const close = "]" + "=".repeat(level) + "]";
                const end = code.indexOf(close, i + 4 + level);
                i = end < 0 ? code.length : end + close.length;
            } else {
                const end = code.indexOf("\n", i);
                i = end < 0 ? code.length : end + 1;
            }
            continue;
        }
        if (c === "[" && longBracket(i) >= 0) {
            const level = longBracket(i);
            const close = "]" + "=".repeat(level) + "]";
            const start = i + 2 + level;
            const end = code.indexOf(close, start);
            out.push({ line: code.slice(0, i).split("\n").length, bytes: bytes(code.slice(start, end < 0 ? code.length : end)) });
            i = end < 0 ? code.length : end + close.length;
            continue;
        }
        if (c === "\"" || c === "'") {
            const line = code.slice(0, i).split("\n").length;
            const value = [];
            let j = i + 1;
            while (j < code.length && code[j] !== c && code[j] !== "\n") {
                if (code[j] === "\\") {
                    const rest = code.slice(j + 1);
                    let m;
                    if ((m = /^\d{1,3}/.exec(rest))) {
                        value.push(Number(m[0]));
                        j += 1 + m[0].length;
                    } else if ((m = /^x([0-9a-fA-F]{2})/.exec(rest))) {
                        value.push(parseInt(m[1], 16));
                        j += 1 + m[0].length;
                    } else {
                        value.push(rest.charCodeAt(0) < 128 ? rest.charCodeAt(0) : 63);
                        j += 2;
                    }
                } else {
                    const ch = String.fromCodePoint(code.codePointAt(j));
                    value.push(...bytes(ch));
                    j += ch.length;
                }
            }
            out.push({ line, bytes: value });
            i = j + 1;
            continue;
        }
        i += 1;
    }
    return out;
}

// Files allowed to keep strings outside Latin-1 (reported, not failing). Empty
// since the council change replaced the last "—"/"–" in visible strings: every
// file must stay within Latin-1 (flavors/latin1.js checks the .toc as well).
const LEGACY_GLYPH_FILES = new Set([]);

// The game fonts (Friz Quadrata, ARIALN) draw Latin-1 only: an arrow, a dash,
// typographic quotes or an ellipsis show as an empty box. Every string the
// addon can show stays within U+0000-U+00FF (umlauts and "·" are fine).
function checkGlyphs() {
    const bad = [];
    let legacy = 0;
    for (const file of tocFiles()) {
        if (!file.endsWith(".lua")) continue;
        const code = fs.readFileSync(path.join(ADDON_DIR, file), "utf8");
        for (const literal of luaStrings(code)) {
            const text = Buffer.from(literal.bytes).toString("utf8");
            const chars = [...text].filter((ch) => ch.codePointAt(0) > 0xff);
            if (!chars.length) continue;
            if (LEGACY_GLYPH_FILES.has(file)) {
                legacy += 1;
                continue;
            }
            const codes = chars.map((ch) => "U+" + ch.codePointAt(0).toString(16).toUpperCase().padStart(4, "0"));
            bad.push(`${file}:${literal.line}: ${codes.join(" ")} in ${JSON.stringify(text).slice(0, 80)}`);
        }
    }
    if (bad.length) {
        console.log(`FAIL glyphs: ${bad.length} strings with characters the game font lacks\n  ${bad.join("\n  ")}\n`);
        return 1;
    }
    console.log(`ok   glyphs (no new string outside Latin-1; ${legacy} older ones in legacy files)`);
    return 0;
}

function main() {
    const only = process.argv[2];
    const specDir = path.join(__dirname, "spec");
    const specs = fs.readdirSync(specDir).filter((f) => f.endsWith(".lua") && (!only || f.includes(only))).sort();
    let failed = only ? 0 : checkGlyphs();
    for (const spec of specs) {
        try {
            const L = newState();
            runChunk(L, fs.readFileSync(path.join(specDir, spec), "utf8"), `spec/${spec}`);
            lua.lua_getglobal(L, to_luastring("__ASSERTIONS"));
            const count = lua.lua_tointeger(L, -1);
            lua.lua_pop(L, 1);
            console.log(`ok   ${spec} (${count} assertions)`);
        } catch (err) {
            failed += 1;
            console.log(`FAIL ${spec}\n${err.message}\n`);
        }
    }
    console.log(failed ? `${failed} check(s) failed` : `${specs.length} spec files passed`);
    process.exit(failed ? 1 : 0);
}

main();
