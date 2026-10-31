"use strict";

// Runs the page's client script (lib/webui-page.js) in a node `vm` context
// with a small hand-written DOM stub. Not a browser, but the script really
// executes: an undefined name (1.16.4: "SVG_RELOAD is not defined"), a missing
// element id or a typo in a render function throws here like it would in the
// window.
const vm = require("vm");
const { PAGE } = require("../lib/webui-page");

const SCRIPT = PAGE.slice(PAGE.indexOf("<script>") + "<script>".length, PAGE.lastIndexOf("</script>"));

/** All ids that exist in the page's HTML, with the class list of their element. */
function pageIds() {
    const html = PAGE.slice(0, PAGE.indexOf("<script>"));
    const ids = [];
    for (const m of html.matchAll(/<([a-z0-9]+)\b[^>]*\bid="([^"]+)"[^>]*>/gi)) {
        const cls = /\bclass="([^"]*)"/.exec(m[0]);
        ids.push({ tag: m[1], id: m[2], classes: cls ? cls[1].split(/\s+/) : [], hidden: /\bhidden\b/.test(m[0]) });
    }
    return ids;
}

function makeElement(tag = "div", id = "", classes = []) {
    const cls = new Set(classes);
    const attrs = {};
    const children = [];
    const listeners = {};
    const el = {
        tagName: tag.toUpperCase(),
        id,
        _innerHTML: "",
        textContent: "",
        value: "",
        placeholder: "",
        title: "",
        hidden: false,
        disabled: false,
        open: false,
        checked: false,
        offsetHeight: 600,
        dataset: {},
        style: {},
        parentNode: null,
        children,
        classList: {
            add: (c) => cls.add(c),
            remove: (c) => cls.delete(c),
            toggle: (c, force) => ((force === undefined ? !cls.has(c) : force) ? cls.add(c) : cls.delete(c)),
            contains: (c) => cls.has(c),
        },
        setAttribute: (k, v) => { attrs[k] = String(v); },
        getAttribute: (k) => (k in attrs ? attrs[k] : null),
        addEventListener: (type, fn) => { (listeners[type] = listeners[type] || []).push(fn); },
        focus() {},
        select() {},
        click() {},
        remove() {},
        appendChild(child) { child.parentNode = el; children.push(child); el.firstChild = children[0]; return child; },
        insertBefore(child, ref) {
            child.parentNode = el;
            const i = children.indexOf(ref);
            children.splice(i < 0 ? children.length : i, 0, child);
            return child;
        },
        querySelector: () => makeElement("span"),
        querySelectorAll: () => [],
        closest: () => null,
        firstChild: null,
        _listeners: listeners,
        _attrs: attrs,
        get className() { return [...cls].join(" "); },
        set className(v) { cls.clear(); String(v).split(/\s+/).filter(Boolean).forEach((c) => cls.add(c)); },
        get innerHTML() { return el._innerHTML; },
        set innerHTML(v) { el._innerHTML = String(v); if (v === "") { children.length = 0; el.firstChild = null; } },
    };
    return el;
}

/**
 * @param {object} fixtures
 * @param {object} fixtures.state   what /api/state answers
 * @param {object[]} [fixtures.raids]  what /api/raids answers
 * @param {object} [fixtures.routes]  extra { "POST /api/x": body | (body) => body }
 */
function loadPage({ state, raids = [], routes = {} }) {
    const byId = {};
    const elements = [];
    for (const { tag, id, classes, hidden } of pageIds()) {
        const el = makeElement(tag, id, classes);
        el.hidden = hidden;
        byId[id] = el;
        elements.push(el);
    }
    // Parents, so that safely() can put a notice in front of a section.
    for (const el of elements) {
        el.parentNode = makeElement("div");
        el.parentNode.children.push(el);
    }
    // The settings form exposes its fields as properties.
    const form = byId.settings;
    for (const name of ["baseUrl", "pollSeconds", "token", "manualPath", "savedVariablesPath", "lhModule"]) form[name] = makeElement("input", name);

    const views = elements.filter((e) => e.classList.contains("view"));
    const pills = elements.filter((e) => e.classList.contains("js-pill"));
    const consoleErrors = [];
    const requests = [];
    const timers = [];

    const doc = makeElement("document");
    Object.assign(doc, {
        documentElement: makeElement("html"),
        body: makeElement("body"),
        getElementById: (id) => byId[id] || null,
        createElement: (tag) => makeElement(tag),
        querySelectorAll: (sel) => {
            if (sel === ".view") return views;
            if (sel === ".js-pill") return pills.length ? pills : [];
            return [];
        },
        querySelector: (sel) => {
            if (sel.startsWith(".view:not([hidden])")) {
                const v = views.find((x) => !x.hidden);
                return v ? Object.assign(makeElement("div"), { classList: v.classList, offsetHeight: 600 }) : null;
            }
            return null;
        },
        execCommand: () => true,
    });

    const respond = (status, body) => ({ ok: status < 300, status, json: async () => body });
    const fetchStub = async (url, opts = {}) => {
        const [pathname] = String(url).split("?");
        const key = `${opts.method || "GET"} ${pathname}`;
        requests.push(key);
        if (routes[key]) {
            const r = routes[key];
            return respond(200, typeof r === "function" ? await r(opts.body ? JSON.parse(opts.body) : {}) : r);
        }
        if (key === "GET /api/state") return respond(200, typeof state === "function" ? state() : state);
        if (key === "GET /api/raids") return respond(200, { raids });
        return respond(404, { error: "kein Stub für " + key });
    };

    const sandbox = {
        document: doc,
        window: { outerWidth: 800, innerWidth: 760, outerHeight: 700, innerHeight: 680, resizeTo() {}, close() {} },
        screen: { availHeight: 1000 },
        navigator: {},
        location: { search: "?key=test" },
        fetch: fetchStub,
        console: { log() {}, warn() {}, error: (...a) => consoleErrors.push(a.map(String).join(" ")) },
        setTimeout: (fn, ms) => { timers.push({ fn, ms, type: "timeout" }); return timers.length; },
        setInterval: (fn, ms) => { timers.push({ fn, ms, type: "interval" }); return timers.length; },
        clearTimeout() {},
        clearInterval() {},
        URL, URLSearchParams, Date, Math, JSON, Set, Map, Promise,
    };
    sandbox.window.document = doc;
    const ctx = vm.createContext(sandbox);
    vm.runInContext(SCRIPT, ctx, { filename: "webui-page-script.js" });

    return {
        ctx,
        byId,
        views,
        consoleErrors,
        requests,
        timers,
        /** Evaluate in the page's global scope (functions, `let` state). */
        run: (code) => vm.runInContext(code, ctx),
        /** Let pending promises (fetch stubs) finish. */
        settle: async () => { for (let i = 0; i < 10; i += 1) await new Promise((r) => setImmediate(r)); },
    };
}

module.exports = { loadPage, SCRIPT };
