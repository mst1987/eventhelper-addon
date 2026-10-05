"use strict";
// Loads the WoW API mock, then the addon files in .toc order (with the
// (addonName, namespace) varargs WoW passes), then runs every spec in spec/ -
// once per client flavour (TBC Anniversary and WoW Forever), each in a fresh
// Lua state. A spec fails by raising a Lua error.
//
// Before that: every visible string in the addon must be drawable by the game
// font (Latin-1, see latin1.js).
//
// The council fixture is written by the sync tool's own serializer
// (sync/lib/council.js), so the specs read exactly what the tool writes.
const fs = require("fs");
const path = require("path");
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require("fengari");
const { checkLua, checkToc } = require("./latin1");
const { buildCouncilFile } = require("../../sync/lib/council");

const ADDON_NAME = "EventHelperSync";
const ADDON_DIR = path.join(__dirname, "..", ADDON_NAME);
const FLAVORS = ["anniversary", "forever"];

function tocText() {
    return fs.readFileSync(path.join(ADDON_DIR, `${ADDON_NAME}.toc`), "utf8");
}

function tocFiles() {
    return tocText().split(/\r?\n/).map((l) => l.trim()).filter((l) => l && !l.startsWith("#"));
}

function tocVersion() {
    const match = /^## Version:\s*(.+)$/m.exec(tocText());
    return match ? match[1].trim() : "";
}

function runChunk(L, code, name, pushArgs) {
    const status = lauxlib.luaL_loadbuffer(L, to_luastring(code), null, to_luastring(name));
    if (status !== lua.LUA_OK) throw new Error(`${name}: ${to_jsstring(lua.lua_tostring(L, -1))}`);
    const nargs = pushArgs ? pushArgs() : 0;
    const base = lua.lua_gettop(L) - nargs - 1;
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

function setGlobalString(L, name, value) {
    lua.lua_pushstring(L, to_luastring(value));
    lua.lua_setglobal(L, to_luastring(name));
}

/** A council payload as the server sends it: 18 raiders (more than the
 * window shows at once), tricky strings, two raiders missing the same item. */
function fixturePayload() {
    const raiders = [
        {
            character: "Gemli", classFile: "PRIEST", specLabel: "Shadow", role: "caster", need: 82,
            parts: { drought: 100, share: 60, need: 40 }, lootCount: 2, lootTotal: 5, otherCount: 1,
            lastAwardAt: 1791240000 - 12 * 86400, daysSinceLoot: 12,
            bis: { tier: "t6", source: "wowsims", owned: 9, total: 16, missing: [30000, 30001, 30001] },
            items: [
                { itemId: 30100, itemName: "Robe – „Neu“ …", awardedAt: 1791240000 - 12 * 86400, boss: "Lady Vashj", reason: "Main Spec", event: "SSC/TK Mittwoch" },
                { itemId: 30101, itemName: 'Ring "alt"\nzweite Zeile 🐉', awardedAt: 1791240000 - 30 * 86400, boss: "Kael'thas", reason: "", event: "" },
            ],
        },
        {
            character: "Naphfß", classFile: "SHAMAN", specLabel: "Resto – Totem", role: "healer", need: 64,
            parts: { drought: 80, share: 50, need: 40 }, lootCount: 3, lootTotal: 3, otherCount: 0,
            lastAwardAt: 1791240000 - 3 * 3600, daysSinceLoot: 0,
            bis: { tier: "t6", source: "wowhead", owned: 4, total: 16, missing: [30000] },
            items: [],
        },
        {
            character: "Neuling", classFile: "", specLabel: "", role: "caster", need: 95,
            parts: { drought: 100, share: 100, need: 50 }, lootCount: 0, lootTotal: 0, otherCount: 0,
            lastAwardAt: 0, daysSinceLoot: -1,
            bis: { tier: "t6", source: "", owned: 0, total: 0, missing: [] },
            items: [],
        },
    ];
    for (let i = 1; i <= 15; i += 1) {
        raiders.push({
            character: `Raider${String(i).padStart(2, "0")}`, classFile: "MAGE", specLabel: "Fire",
            role: i % 3 === 0 ? "healer" : "caster", need: 50 - i,
            parts: { drought: 50, share: 50, need: 50 }, lootCount: i, lootTotal: i, otherCount: 0,
            lastAwardAt: 1791240000 - i * 86400, daysSinceLoot: i,
            bis: { tier: "t6", source: "wowsims", owned: 10, total: 16, missing: [30000] },
            items: [],
        });
    }
    return {
        format: "eventhelper-council",
        version: 1,
        generatedAt: 1791240000 - 2 * 3600,
        filter: { category: "123", categoryName: "SSC/TK Mittwoch", role: "", bisTier: "t6", bisTierDerived: true },
        categories: [{ id: "123", name: "SSC/TK Mittwoch" }],
        weights: { drought: 50, share: 40, need: 10 },
        avgLootCount: 3.4,
        raiders,
    };
}

function newState(flavor, fixture) {
    const L = lauxlib.luaL_newstate();
    lualib.luaL_openlibs(L);
    setGlobalString(L, "__FLAVOR", flavor);
    setGlobalString(L, "__TOC_VERSION", tocVersion());
    setGlobalString(L, "__COUNCIL_FIXTURE", fixture);
    runChunk(L, fs.readFileSync(path.join(__dirname, "mock", "wow.lua"), "utf8"), "mock/wow.lua");
    lua.lua_newtable(L);
    lua.lua_setglobal(L, to_luastring("__EHS_NS"));
    for (const file of tocFiles()) {
        const code = fs.readFileSync(path.join(ADDON_DIR, file), "utf8");
        runChunk(L, code, `${ADDON_NAME}/${file}`, () => {
            lua.lua_pushstring(L, to_luastring(ADDON_NAME));
            lua.lua_getglobal(L, to_luastring("__EHS_NS"));
            return 2;
        });
    }
    return L;
}

function checkLatin1() {
    const problems = checkToc(`${ADDON_NAME}.toc`, tocText());
    for (const file of fs.readdirSync(ADDON_DIR).filter((f) => f.endsWith(".lua"))) {
        problems.push(...checkLua(file, fs.readFileSync(path.join(ADDON_DIR, file), "utf8")));
    }
    if (problems.length) {
        console.log(`FAIL latin-1: ${problems.length} character(s) the game font cannot draw\n  ${problems.join("\n  ")}\n`);
        return 1;
    }
    console.log("ok   latin-1 (every string literal and the .toc title/notes)");
    return 0;
}

function main() {
    const only = process.argv[2];
    const fixture = buildCouncilFile(fixturePayload(), { syncVersion: "test", now: new Date(0) });
    const specDir = path.join(__dirname, "spec");
    const specs = fs.readdirSync(specDir).filter((f) => f.endsWith(".lua") && (!only || f.includes(only))).sort();
    let failed = only ? 0 : checkLatin1();
    let runs = 0;
    for (const spec of specs) {
        for (const flavor of FLAVORS) {
            runs += 1;
            try {
                const L = newState(flavor, fixture);
                runChunk(L, fs.readFileSync(path.join(specDir, spec), "utf8"), `spec/${spec}`);
                lua.lua_getglobal(L, to_luastring("__ASSERTIONS"));
                const count = lua.lua_tointeger(L, -1);
                console.log(`ok   ${spec} [${flavor}] (${count} assertions)`);
            } catch (err) {
                failed += 1;
                console.log(`FAIL ${spec} [${flavor}]\n${err.message}\n`);
            }
        }
    }
    console.log(failed ? `${failed} failed (${runs} spec runs)` : `${runs} spec runs passed`);
    process.exit(failed ? 1 : 0);
}

main();
