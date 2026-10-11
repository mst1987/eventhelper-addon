"use strict";

// Die Seite (lib/webui-page.js) im eigenen Fenster (WebView2): Kopfzeile als
// Titelleiste, Minimieren, Grösse per Nachricht. Im Edge-/Tab-Rückfall muss
// alles wie bisher bleiben; der WebView-Teil hängt an window.chrome.webview.
const { PAGE } = require("../lib/webui-page");

const script = PAGE.slice(PAGE.indexOf("<script>") + "<script>".length, PAGE.lastIndexOf("</script>"));

describe("Seite im eigenen Fenster (WebView2)", () => {
    it("ist gültiges JavaScript", () => {
        // Nur übersetzen, nicht ausführen.
        expect(() => new Function(script)).not.toThrow();
    });

    it("erkennt das eigene Fenster an window.chrome.webview", () => {
        expect(script).toMatch(/const HOST = window\.chrome && window\.chrome\.webview \? window\.chrome\.webview : null;/);
        expect(script).toMatch(/if \(HOST\) \{\s*const root = document\.documentElement;\s*root\.classList\.add\("in-host"\);/);
    });

    it("schickt drag, edge, minimize, close und resize als Nachrichten", () => {
        expect(script).toContain('hostPost({ type: "drag" })');
        expect(script).toContain('hostPost({ type: "edge", edge: edge })');
        expect(script).toContain('hostPost({ type: "minimize" })');
        expect(script).toContain('hostPost({ type: "close" })');
        expect(script).toContain('hostPost({ type: "resize", width: APP_WIDTH, height: height })');
        expect(script).toContain("HOST.postMessage(msg)");
    });

    it("zieht nur an der Kopfzeile, nicht an ihren Knöpfen", () => {
        expect(script).toContain('e.target.closest(".hdr")');
        expect(script).toContain('!e.target.closest("button, a, input, select, textarea, label, [data-act]")');
    });

    it("nimmt resizeTo nur ausserhalb des eigenen Fensters", () => {
        const fit = script.slice(script.indexOf("function fitWindow()"));
        expect(fit.indexOf("if (HOST)")).toBeGreaterThan(-1);
        expect(fit.indexOf("if (HOST)")).toBeLessThan(fit.indexOf("window.resizeTo("));
    });

    it("✕ beendet den Sync und schliesst danach das Fenster", () => {
        expect(script).toContain('post("/api/quit").catch(() => {}).finally(closeWindow);');
        // Im Rückfall wie bisher window.close().
        expect(script).toMatch(/function closeWindow\(\) \{\s*if \(!hostPost\(\{ type: "close" \}\)\) window\.close\(\);/);
    });

    it("hat den Minimieren-Knopf neben Verlauf/Einstellungen, nur im eigenen Fenster sichtbar", () => {
        expect(PAGE).toContain('class="ibtn host-only" data-act="minimize" aria-label="Minimieren" title="Minimieren"');
        expect(PAGE).toContain(".host-only { display: none; }");
        expect(PAGE).toContain(".in-host .host-only { display: grid; }");
        // Übersicht und Einrichtung: vor dem ✕.
        expect(PAGE.match(/data-act="minimize"[^]*?data-act="quit"/g)).toHaveLength(2);
    });

    it("hat einen 1-px-Rahmen nur im eigenen Fenster", () => {
        expect(PAGE).toMatch(/\.in-host body::after \{[^}]*border: 1px solid var\(--line\)[^}]*pointer-events: none/);
    });

    it("färbt im Edge-Rückfall die Titelleiste in der Farbe der Kopfzeile", () => {
        expect(PAGE).toContain('<meta name="theme-color" content="#1f232b">');
        expect(PAGE).toContain("--panel: #1f232b");
    });
});
