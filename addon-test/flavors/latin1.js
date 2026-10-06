"use strict";
// The game font only knows Latin-1: anything above U+00FF shows up as a box.
// This finds the string literals in Lua source (comments are skipped - they
// never reach the screen) and reports every character the font cannot draw.

/** The string literals of a Lua file: { text, line, start, end } (end exclusive). */
function luaStrings(code) {
    const out = [];
    let i = 0;
    let line = 1;
    const newlines = (from, to) => {
        let n = 0;
        for (let k = from; k < to; k += 1) if (code[k] === "\n") n += 1;
        return n;
    };
    while (i < code.length) {
        const c = code[i];
        if (c === "\n") {
            line += 1;
            i += 1;
            continue;
        }
        if (c === "-" && code[i + 1] === "-") {
            const block = /^--\[(=*)\[/.exec(code.slice(i, i + 16));
            if (block) {
                const close = `]${block[1]}]`;
                const found = code.indexOf(close, i);
                const stop = found < 0 ? code.length : found + close.length;
                line += newlines(i, stop);
                i = stop;
            } else {
                const nl = code.indexOf("\n", i);
                i = nl < 0 ? code.length : nl;
            }
            continue;
        }
        if (c === '"' || c === "'") {
            const startLine = line;
            let j = i + 1;
            while (j < code.length && code[j] !== c && code[j] !== "\n") {
                j += code[j] === "\\" ? 2 : 1;
            }
            out.push({ text: code.slice(i + 1, j), line: startLine, start: i + 1, end: j });
            i = j + 1;
            continue;
        }
        if (c === "[") {
            const long = /^\[(=*)\[/.exec(code.slice(i, i + 16));
            if (long) {
                const close = `]${long[1]}]`;
                const found = code.indexOf(close, i);
                const stop = found < 0 ? code.length : found;
                out.push({ text: code.slice(i + long[0].length, stop), line, start: i + long[0].length, end: stop });
                line += newlines(i, stop);
                i = stop + close.length;
                continue;
            }
        }
        i += 1;
    }
    return out;
}

/** Every character outside Latin-1 inside a string literal: "file:line 'x' (U+XXXX)". */
function checkLua(file, code) {
    const problems = [];
    for (const s of luaStrings(code)) {
        for (const ch of s.text) {
            const cp = ch.codePointAt(0);
            if (cp > 0xff) {
                problems.push(`${file}:${s.line} '${ch}' (U+${cp.toString(16).toUpperCase().padStart(4, "0")}) in "${s.text}"`);
            }
        }
    }
    return problems;
}

/** The same for the visible .toc fields (## Title, ## Notes). */
function checkToc(file, text) {
    const problems = [];
    text.split(/\r?\n/).forEach((lineText, index) => {
        if (!/^##\s*(Title|Notes)/i.test(lineText)) return;
        for (const ch of lineText) {
            const cp = ch.codePointAt(0);
            if (cp > 0xff) problems.push(`${file}:${index + 1} '${ch}' (U+${cp.toString(16).toUpperCase()})`);
        }
    });
    return problems;
}

module.exports = { luaStrings, checkLua, checkToc };
