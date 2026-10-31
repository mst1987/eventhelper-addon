"use strict";

// Die Oberfläche als eine Zeichenkette — kein Build-Schritt, keine Dateien
// daneben, und beim Packen der .exe landet sie automatisch mit im Bündel.
// Kein Framework: vier Ansichten (Einrichtung, Übersicht, Einstellungen,
// Verlauf) in einer Seite, umgeschaltet ohne Neuladen.
//
// Look: plain dark panels, design Canvas A of issue #51 (servers in a
// sidebar, version colours as the only accent, status as words). No
// external fonts or scripts: the window must work offline. The WoW icons of
// the tiles come from webui-icons.js as data URIs.
//
// The page script avoids template literals on purpose: the whole page is one
// String.raw template, and a dollar-brace in it would be interpolated here.

const ICONS = require("./webui-icons");

// Shared SVG snippets (24-unit viewBox, stroke icons).
// The EventHelper mark (calendar with a check), the same lines as the web's BrandIcon.
const SVG_LOGO = '<svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3.5" y="5" width="17" height="15.5" rx="2.5"/><path d="M8 2.5V7M16 2.5V7M3.5 9.5h17"/><path d="m8.5 14.5 2.5 2.5 4.5-4.5"/></svg>';
const SVG_CLOCK = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></svg>';
const SVG_GEAR = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/></svg>';
const SVG_X = '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18"/></svg>';
const SVG_MIN = '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" aria-hidden="true"><path d="M6 12h12"/></svg>';
const SVG_BACK ='<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M15 18l-6-6 6-6"/></svg>';
const SVG_RELOAD = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M21 12a9 9 0 1 1-3-6.7L21 8"/><path d="M21 3v5h-5"/></svg>';
const SVG_UP = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 20V8M7 13l5-5 5 5M5 4h14"/></svg>';
const SVG_DOWNLOAD = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 4v11M7 10l5 5 5-5M5 20h14"/></svg>';

const CREST = '<span class="crest" aria-hidden="true">' + SVG_LOGO + "</span>";
const BRAND = '<span class="brand"><b>EventHelper Sync</b><small class="js-ver">&nbsp;</small></span>';
const PILL = '<span class="pill off js-pill" role="status"><span class="pdot"></span><span class="ptext">…</span></span>';
const BTN_LOG = '<button type="button" class="ibtn" data-act="nav" data-arg="log" aria-label="Verlauf" title="Verlauf">' + SVG_CLOCK + "</button>";
const BTN_SETTINGS = '<button type="button" class="ibtn" data-act="nav" data-arg="settings" aria-label="Einstellungen" title="Einstellungen">' + SVG_GEAR + "</button>";
const BTN_QUIT = '<button type="button" class="ibtn" data-act="quit" aria-label="Sync beenden" title="Sync beenden">' + SVG_X + "</button>";
// Only in the tool's own window (WebView2): Edge --app has its own title bar.
const BTN_MIN = '<button type="button" class="ibtn host-only" data-act="minimize" aria-label="Minimieren" title="Minimieren">' + SVG_MIN + "</button>";
const BTN_BACK = '<button type="button" class="back" data-act="nav" data-arg="main">' + SVG_BACK + "Übersicht</button>";

// Fenster-/Taskleisten-Icon: Edge/Chrome übernehmen im --app=-Modus das
// Favicon der Seite. Dasselbe Motiv wie assets/icon.svg, das Icon der .exe —
// beide gemeinsam ändern (danach npm run build:icon).
const FAVICON = "data:image/svg+xml,"
    + "%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'%3E"
    + "%3Cdefs%3E%3ClinearGradient id='g' x1='.15' y1='0' x2='.85' y2='1'%3E"
    + "%3Cstop offset='0' stop-color='%238a7cff'/%3E%3Cstop offset='1' stop-color='%2335d6c4'/%3E"
    + "%3C/linearGradient%3E%3C/defs%3E"
    + "%3Crect width='64' height='64' rx='15' fill='url(%23g)'/%3E"
    + "%3Cg fill='none' stroke='%23130f26' stroke-width='5.5' stroke-linecap='round' stroke-linejoin='round'%3E"
    + "%3Crect x='12' y='17' width='40' height='36' rx='6'/%3E"
    + "%3Cpath d='M23 11 V21 M41 11 V21 M12 28 H52'/%3E"
    + "%3Cpath d='M23.5 40.5 L29 46 L40.5 34.5'/%3E"
    + "%3C/g%3E%3C/svg%3E";

module.exports.PAGE = String.raw`<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="theme-color" content="#1f232b">
<title>EventHelper Sync</title>
<link rel="icon" type="image/svg+xml" href="${FAVICON}">
<style>
  :root {
    --bg: #16181d; --panel: #1f232b; --panel2: #272c36; --line: #2c313b; --line2: #23272f;
    --text: #e6e6e6; --muted: #9aa0aa; --faint: #6f7682;
    /* Version colours are the only accent (Canvas A, issue #51); status words
       carry the rest. No gradients, glows or tinted chips. */
    --tbc: #9bd45a; --fe: #4da3ff; --era: #8fa3b8;
    --good: #7fd17f; --bad: #e0524f; --wait: #d9a441; --high: #e0524f; --medium: #d9a441; --pending: #9aa0aa;
    --mono: ui-monospace, "Cascadia Code", Consolas, monospace;
    color-scheme: dark;
  }
  * { box-sizing: border-box; }
  html, body { height: 100%; }
  body {
    margin: 0; background: var(--bg); color: var(--text); overflow: hidden;
    font: 14px/1.45 "Segoe UI", -apple-system, Helvetica, Arial, sans-serif;
  }
  button, input, select { font: inherit; color: inherit; }
  button { cursor: pointer; }
  button:disabled { cursor: default; opacity: .55; }
  :focus-visible { outline: 2px solid var(--muted); outline-offset: 2px; }
  code { font: 12px var(--mono); background: var(--bg); border: 1px solid var(--line); border-radius: 4px; padding: 0 4px; }
  [hidden] { display: none !important; }

  .view { height: 100vh; display: flex; flex-direction: column; }
  .grow { flex: 1; min-height: 0; }
  .scroll { overflow: auto; }
  /* fitWindow(): natural height of the view, without inner scrolling */
  .view.measure { height: auto; }
  .view.measure .grow { flex: none; }
  .view.measure .scroll { overflow: visible; }

  /* Header */
  .hdr { display: flex; align-items: center; gap: 10px; min-height: 48px; padding: 0 12px 0 16px; background: var(--panel); border-bottom: 1px solid var(--line); flex: none; }
  .crest { width: 22px; height: 22px; flex: none; display: grid; place-items: center; color: var(--muted); }
  .crest svg { width: 22px; height: 22px; }
  .brand { display: flex; align-items: baseline; gap: 8px; line-height: 1.2; min-width: 0; white-space: nowrap; }
  .brand b { font-weight: 600; font-size: 15px; }
  .brand small { font-size: 12px; color: var(--faint); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .hdr-title { font-size: 15px; font-weight: 600; }
  .who { margin-left: auto; font-size: 13px; color: var(--muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; min-width: 0; }
  .who b { color: var(--text); font-weight: 600; }
  .who.err { color: var(--bad); }
  /* Connection state as plain text: the colour of the word is the only signal. */
  .pill { margin-left: auto; display: inline-flex; align-items: center; font-size: 13px; white-space: nowrap; color: var(--muted); }
  .pill .pdot { display: none; }
  .pill.ok { color: var(--good); }
  .pill.err { color: var(--bad); }
  .ibtn, .ib { width: 30px; height: 30px; border-radius: 4px; border: 0; background: none; color: var(--muted); display: grid; place-items: center; flex: none; padding: 0; }
  .ibtn:hover, .ib:hover:not(:disabled) { color: var(--text); background: var(--panel2); }
  .back { display: inline-flex; align-items: center; gap: 6px; min-height: 30px; padding: 0 10px 0 6px; border-radius: 4px; border: 1px solid var(--line); background: var(--panel2); color: var(--text); font-weight: 600; font-size: 13px; }
  .back:hover { background: #2d3340; }
  .hdr-right { margin-left: auto; display: flex; align-items: center; gap: 6px; }

  /* The tool's own window (WebView2, lib/webviewHost.js): no OS title bar, so
     the header is one (moves the window), the edges resize it, and a 1 px
     frame keeps it apart from dark backgrounds. Edge --app and tabs: unchanged. */
  .host-only { display: none; }
  .in-host .host-only { display: grid; }
  .in-host .hdr { user-select: none; }
  .in-host body::after { content: ""; position: fixed; inset: 0; border: 1px solid var(--line); pointer-events: none; z-index: 1000; }
  html[data-edge="left"], html[data-edge="left"] *, html[data-edge="right"], html[data-edge="right"] * { cursor: ew-resize !important; }
  html[data-edge="top"], html[data-edge="top"] *, html[data-edge="bottom"], html[data-edge="bottom"] * { cursor: ns-resize !important; }
  html[data-edge="top-left"], html[data-edge="top-left"] *, html[data-edge="bottom-right"], html[data-edge="bottom-right"] * { cursor: nwse-resize !important; }
  html[data-edge="top-right"], html[data-edge="top-right"] *, html[data-edge="bottom-left"], html[data-edge="bottom-left"] * { cursor: nesw-resize !important; }

  /* Buttons */
  .btn { display: inline-flex; align-items: center; justify-content: center; gap: 6px; min-height: 30px; padding: 0 12px; border-radius: 4px; border: 1px solid var(--line); background: var(--panel2); color: var(--text); font-size: 13px; font-weight: 600; }
  .btn:hover:not(:disabled) { border-color: #3a404c; background: #2d3340; }
  .btn.sm { min-height: 28px; padding: 0 10px; }
  .btn.lg { min-height: 36px; padding: 0 16px; font-size: 14px; }
  .btn.primary, .btn.go { border-color: #3d723d; background: #2f5a2f; color: #eaf6e6; }
  .btn.primary:hover:not(:disabled), .btn.go:hover:not(:disabled) { background: #376a37; border-color: #4a864a; }
  .btn.go.big { min-height: 40px; padding: 0 18px; font-size: 15px; font-weight: 600; }
  .btn.blue { }
  .btn.link, .linkbtn { border: 0; background: none; min-height: 0; padding: 4px 0; color: var(--text); font-size: 13px; font-weight: 400; text-decoration: underline; text-underline-offset: 3px; text-decoration-color: var(--faint); }
  .btn.link:hover, .linkbtn:hover { text-decoration-color: var(--text); }
  .sq { width: 30px; height: 30px; border-radius: 4px; border: 0; background: none; color: var(--muted); display: grid; place-items: center; flex: none; padding: 0; }
  .sq:hover:not(:disabled) { color: var(--text); background: var(--panel2); }

  .kicker { font-size: 13px; font-weight: 600; color: var(--muted); }
  .hint { font-size: 12px; color: var(--muted); }
  .err-text { color: var(--bad); }
  .ok-text { color: var(--good); }

  /* Übersicht */
  /* Notices: neutral panel, a 3 px edge in the status colour, no tint. */
  .problems, .strip, .sec-err, .notice { padding: 8px 12px; border-radius: 4px; background: var(--panel2); border: 0; border-left: 3px solid var(--muted); color: var(--text); font-size: 13px; line-height: 1.45; word-break: break-word; }
  .problems { border-left-color: var(--bad); display: flex; flex-direction: column; gap: 4px; }
  .problems .linkbtn { align-self: flex-start; padding: 0; font-size: 13px; }
  .strip { display: flex; align-items: center; gap: 10px; color: var(--muted); }
  .strip span { display: flex; flex-direction: column; line-height: 1.3; }
  .strip b { font-size: 13.5px; font-weight: 600; color: var(--text); }
  .strip small { font-size: 12.5px; color: var(--muted); }
  .strip.upd { border-left-color: var(--good); }
  .strip.upd.err { border-left-color: var(--bad); }
  .strip.upd.err small { word-break: break-word; }
  .sec-err { border-left-color: var(--bad); font-size: 12px; }
  .notice { border-left-color: var(--wait); }
  .notice b { font-weight: 600; }
  .strip .upd-text { flex: 1; min-width: 0; }
  .strip .btn, .strip .linkbtn { flex: none; }
  .banners { display: flex; flex-direction: column; gap: 8px; padding: 10px 16px 0; flex: none; }
  .banners:empty, .banners.none { display: none; }

  /* Übersicht: servers on the left, the picked version on the right (Canvas A) */
  .split { display: flex; min-height: 0; }
  .side { width: 220px; flex: none; background: #1a1d23; border-right: 1px solid var(--line); padding: 8px 0 12px; display: flex; flex-direction: column; }
  .srv { display: flex; align-items: center; gap: 10px; padding: 10px 16px 4px; }
  .srv-ini { width: 28px; height: 28px; border-radius: 6px; flex: none; display: grid; place-items: center; background: var(--panel2); color: var(--muted); font-size: 12px; font-weight: 700; }
  .srv-name { font-weight: 600; font-size: 13.5px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .srv.none .srv-name { color: var(--muted); font-weight: 400; }
  .sv { display: flex; flex-direction: column; width: 100%; padding: 7px 16px 7px 54px; border: 0; background: none; text-align: left; line-height: 1.3; }
  .sv:hover { background: #20242b; }
  .sv[aria-current="true"] { background: #272c36; box-shadow: inset 3px 0 0 var(--vc, var(--muted)); }
  .sv-name { font-size: 13.5px; font-weight: 600; color: var(--vc, var(--text)); }
  .sv-sub { font-size: 12px; color: var(--faint); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .side-foot { margin-top: auto; padding: 12px 16px 0; font-size: 12px; color: var(--faint); }

  .detail { padding: 16px 22px; display: flex; flex-direction: column; gap: 4px; min-width: 0; }
  .ver-title { display: flex; align-items: baseline; gap: 10px; flex-wrap: wrap; margin-bottom: 8px; }
  .ver-title b { font-size: 24px; font-weight: 700; line-height: 1.2; color: var(--vc, var(--text)); }
  .ver-title span { color: var(--muted); font-size: 13px; }
  .sec { font-size: 13px; font-weight: 600; color: var(--muted); padding: 12px 0 6px; border-bottom: 1px solid var(--line); }

  .tiles { display: flex; flex-direction: column; }
  .tile { display: grid; grid-template-columns: 126px minmax(0, 1fr) auto; align-items: center; gap: 4px 12px; padding: 9px 0; border: 0; border-bottom: 1px solid var(--line2); background: none; text-align: left; min-width: 0; width: 100%; }
  button.tile:hover, div.tile[data-act]:hover { background: #1c1f26; }
  div.tile[data-act] { cursor: pointer; }
  .tile-head { display: flex; align-items: center; gap: 8px; min-width: 0; }
  .tile-head img { display: none; }
  .tile-head .kicker { flex: 1; min-width: 0; }
  .tile-body { display: flex; flex-direction: column; line-height: 1.3; min-width: 0; }
  .tile-val { font-weight: 600; font-size: 14px; overflow-wrap: anywhere; }
  .tile-head .tbtn { width: 24px; height: 24px; border-radius: 4px; border: 0; background: none; color: var(--muted); display: grid; place-items: center; flex: none; padding: 0; }
  .tile-head .tbtn:hover:not(:disabled) { color: var(--text); background: var(--panel2); }
  .tile-head .tbtn.spin svg { animation: tile-spin .9s linear infinite; }
  @keyframes tile-spin { to { transform: rotate(360deg); } }
  .tile-sub { font-size: 12.5px; color: var(--faint); overflow-wrap: anywhere; }
  .tile-sub.err-text { color: var(--bad); }
  .tile .btn { justify-self: end; }
  .tile .sec-err { grid-column: 1 / -1; }
  .dot { width: 7px; height: 7px; border-radius: 50%; flex: none; background: var(--faint); }
  .dot.good { background: var(--good); }
  .dot.high { background: var(--bad); }
  .dot.medium { background: var(--wait); }
  .dot.pending { background: var(--muted); }

  .rows { display: flex; flex-direction: column; }
  .row { display: flex; align-items: center; gap: 12px; padding: 9px 0; border-bottom: 1px solid var(--line2); }
  .state { width: 150px; flex: none; font-size: 13px; font-weight: 600; color: var(--muted); }
  .state.ready { color: var(--wait); }
  .state.wait { color: var(--wait); }
  .state.done { color: var(--good); }
  .state.empty { color: var(--faint); font-weight: 400; }
  .state.upcoming { color: var(--faint); font-weight: 400; }
  .row-text { display: flex; flex-direction: column; flex: 1; min-width: 0; line-height: 1.3; }
  .row-title { font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .row-sub { font-size: 12.5px; color: var(--faint); }
  .row .btn { flex: none; }
  .rows-empty { padding: 12px 0; color: var(--muted); font-size: 13px; }
  .more { margin: 8px 0; align-self: flex-start; }

  .ftr { display: flex; align-items: center; justify-content: space-between; gap: 10px; padding: 10px 14px; border-top: 1px solid var(--line); background: var(--panel); font-size: 12.5px; color: var(--muted); flex: none; }
  .ftr.end { justify-content: flex-end; gap: 8px; padding: 12px 14px; }
  .ftr.main { min-height: 64px; padding: 0 12px 0 16px; justify-content: flex-start; gap: 14px; }
  .f-ready { display: flex; flex-direction: column; line-height: 1.3; min-width: 0; flex: 1; }
  .f-ready b { font-size: 13.5px; font-weight: 600; color: var(--text); }
  .f-ready small { font-size: 12px; color: var(--faint); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .f-check { display: flex; align-items: center; gap: 4px; white-space: nowrap; color: var(--faint); font-size: 12.5px; }

  /* Einstellungen / Einrichtung */
  .form-body { display: flex; flex-direction: column; gap: 12px; padding: 14px; }
  .card { display: flex; flex-direction: column; gap: 12px; padding: 14px; border-radius: 10px; background: var(--panel); border: 1px solid var(--line); }
  .field { display: flex; flex-direction: column; gap: 6px; }
  .field > .lbl { font-size: 13px; font-weight: 600; color: var(--muted); }
  .input { width: 100%; min-height: 38px; padding: 8px 12px; border-radius: 8px; border: 1px solid var(--line); background: var(--bg); color: var(--text); }
  .input:focus { outline: none; border-color: var(--muted); }
  select.input { appearance: none; padding-right: 34px; background-image: linear-gradient(45deg, transparent 50%, #9aa0aa 50%), linear-gradient(135deg, #9aa0aa 50%, transparent 50%); background-position: calc(100% - 17px) 17px, calc(100% - 12px) 17px; background-size: 5px 5px; background-repeat: no-repeat; }
  .inline { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
  .result { display: inline-flex; align-items: center; gap: 6px; font-size: 12.5px; }
  .dirs { display: flex; flex-direction: column; border: 1px solid var(--line); border-radius: 8px; overflow: hidden; }
  .dir { display: flex; align-items: center; gap: 8px; padding: 8px 12px; border-bottom: 1px solid var(--line2); font-size: 13px; }
  .dir:last-child { border-bottom: 0; }
  .dir .where { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .dir .ver { margin-left: auto; color: var(--muted); font: 12px var(--mono); white-space: nowrap; }
  .dir .ver.old { color: var(--medium); }
  .dir .sdot { width: 8px; height: 8px; border-radius: 50%; flex: none; background: var(--good); }
  .dir .sdot.old { background: var(--medium); }
  .dir .sdot.unknown { background: var(--muted); }
  details { font-size: 13px; color: var(--muted); }
  details summary { cursor: pointer; font-weight: 600; }
  details .input { margin-top: 8px; }
  details .hint { display: block; margin-top: 6px; }
  .poll { display: flex; align-items: center; gap: 12px; }
  .poll-text { flex: 1; display: flex; flex-direction: column; line-height: 1.3; }
  .poll-text b { font-size: 13.5px; font-weight: 600; }
  .poll input[type="checkbox"] { width: 20px; height: 20px; flex: none; accent-color: #3d723d; cursor: pointer; }
  .poll .input { width: 74px; min-height: 34px; padding: 6px 10px; text-align: right; }
  .static-lines { display: flex; flex-direction: column; gap: 4px; font-size: 12.5px; color: var(--muted); }
  .actions { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 8px; }
  .action { display: flex; flex-direction: column; align-items: center; gap: 6px; padding: 10px 6px; border-radius: 8px; border: 1px solid var(--line); background: var(--panel2); color: var(--text); font-size: 12.5px; font-weight: 700; }
  .action:hover:not(:disabled) { border-color: #3a404c; background: #2d3340; }
  .action img { width: 24px; height: 24px; border-radius: 5px; }

  .setup-body { display: flex; flex-direction: column; gap: 14px; padding: 18px 16px; }
  .setup-body h1 { margin: 0; font-size: 20px; font-weight: 800; }
  .lead { color: var(--muted); font-size: 13.5px; }
  .step { display: flex; gap: 12px; padding: 14px; border-radius: 10px; background: var(--panel); border: 1px solid var(--line); }
  .step-no { width: 26px; height: 26px; border-radius: 50%; flex: none; display: grid; place-items: center; background: var(--panel2); border: 1px solid var(--line); color: var(--muted); font-weight: 800; font-size: 13px; }
  .step-no.active { background: var(--panel2); border-color: var(--muted); color: var(--text); }
  .step-no.done { border-color: transparent; color: var(--good); }
  .step-no.warn { border-color: transparent; color: var(--medium); }
  .step-main { flex: 1; display: flex; flex-direction: column; gap: 6px; min-width: 0; }
  .step-main .linkbtn { align-self: flex-start; padding: 0; font-size: 12.5px; }

  /* Verlauf */
  .seg { margin-left: auto; display: inline-flex; border: 1px solid var(--line); border-radius: 8px; overflow: hidden; background: var(--panel2); }
  .seg button { min-height: 30px; padding: 0 11px; border: 0; background: none; color: var(--muted); font-size: 12.5px; font-weight: 700; }
  .seg button + button { border-left: 1px solid var(--line); }
  .seg button[aria-pressed="true"] { background: #323845; color: var(--text); }
  .log { padding: 6px 0; }
  .line { display: grid; grid-template-columns: 64px 18px minmax(0, 1fr); gap: 8px; align-items: start; padding: 6px 14px; border-bottom: 1px solid #1d2027; }
  .line time { font: 12px var(--mono); color: var(--faint); padding-top: 1px; }
  .line .ldot { width: 8px; height: 8px; border-radius: 50%; margin-top: 6px; background: var(--muted); }
  .line .ltext { font-size: 13px; line-height: 1.45; word-break: break-word; color: #d5d8de; }
  .line.ok .ldot { background: var(--good); }
  .line.warn .ldot { background: var(--medium); }
  .line.warn .ltext { color: #e8c27a; }
  .line.error .ldot { background: var(--high); }
  .line.error .ltext { color: #ff9b8f; }
  .log-empty { padding: 14px; color: var(--muted); font-size: 13px; }

  /* Toasts */
  #flash { position: fixed; left: 50%; bottom: 62px; transform: translateX(-50%); z-index: 10; width: max-content; max-width: calc(100% - 32px); }
  .toast { padding: 9px 14px; border-radius: 8px; font-weight: 600; font-size: 13px; background: var(--panel2); border: 1px solid var(--line); border-left: 3px solid var(--good); color: var(--text); box-shadow: 0 8px 24px rgba(0,0,0,.45); }
  .toast.err { border-left-color: var(--high); color: #ffc9c4; }
</style>
</head>
<body>

<!-- Einrichtung: erster Start, Adresse oder Token fehlen -->
<section class="view" id="v-setup" hidden>
  <header class="hdr">${CREST}<span class="brand"><b>EventHelper Sync</b></span><span class="hdr-right">${PILL}${BTN_LOG}${BTN_MIN}${BTN_QUIT}</span></header>
  <div class="setup-body grow scroll">
    <div>
      <h1>Einmal einrichten</h1>
      <div class="lead">Danach läuft alles von selbst: Loot hochladen, Council-Daten und Ausgabeliste ins Spiel bringen.</div>
    </div>
    <div class="step">
      <span class="step-no" id="su-no1">1</span>
      <label class="step-main">
        <b>Adresse des EventHelper</b>
        <input class="input" type="text" id="su-base" placeholder="https://pulse-gdkp.de:3005" autocomplete="off" spellcheck="false">
        <span class="hint">Mit https:// und Port, ohne /api.</span>
      </label>
    </div>
    <div class="step">
      <span class="step-no" id="su-no2">2</span>
      <label class="step-main">
        <b>API-Token</b>
        <input class="input" type="password" id="su-token" placeholder="ehl_…" autocomplete="off">
        <span class="hint" id="su-token-hint">Auf der Webseite unter Einstellungen → Loot-Sync erstellen. Er wird dort genau einmal angezeigt.</span>
      </label>
    </div>
    <div class="step">
      <span class="step-no" id="su-no3">3</span>
      <div class="step-main">
        <b id="su-wow-title">World of Warcraft</b>
        <span class="hint" id="su-wow-text" style="font-size:13px"></span>
        <button type="button" class="linkbtn" data-act="setup-path" id="su-other">Anderen Ordner wählen</button>
        <input class="input" type="text" id="su-path" placeholder="D:\Games\World of Warcraft" autocomplete="off" spellcheck="false" hidden>
      </div>
    </div>
  </div>
  <footer class="ftr end">
    <span id="su-status" style="margin-right:auto">Prüft die Verbindung vor dem Speichern</span>
    <button type="button" class="btn lg primary" data-act="setup-connect" id="su-connect">Verbinden</button>
  </footer>
</section>

<!-- Übersicht -->
<section class="view" id="v-main" hidden>
  <header class="hdr">${CREST}${BRAND}<span class="who" id="who" role="status">&nbsp;</span>${BTN_LOG}${BTN_SETTINGS}${BTN_MIN}${BTN_QUIT}</header>
  <div class="banners" id="banners">
    <div class="strip upd" id="upd" role="status" hidden>${SVG_DOWNLOAD}<span class="upd-text"><b id="upd-title">Update verfügbar</b><small id="upd-text"></small></span><button type="button" class="linkbtn" data-act="update-notes" id="upd-notes">Was ist neu?</button><button type="button" class="btn sm" data-act="update-notes" id="upd-dl" hidden>Neue Version herunterladen</button><button type="button" class="btn sm primary" data-act="update-install" id="upd-btn">Installieren</button></div>
    <div class="problems" id="problems" role="alert" hidden></div>
    <div class="notice" id="legacy" role="note" hidden></div>
    <div class="strip" id="strip" hidden>${SVG_RELOAD.replace(/14/g, "18")}<span><b>Neue Daten fürs Spiel</b><small id="strip-text"></small></span></div>
  </div>
  <div class="split grow">
    <nav class="side scroll" id="side" aria-label="Server und Versionen"></nav>
    <main class="detail grow scroll" id="detail">
      <div class="ver-title" id="ver-title"></div>
      <div class="sec">Raids · letzte 14 Tage</div>
      <div class="rows" id="rows"></div>
      <div class="sec">Weiteres</div>
      <div class="tiles" id="tiles"></div>
    </main>
  </div>
  <footer class="ftr main">
    <button type="button" class="btn go big" data-act="upload-all" id="btn-upload">${SVG_UP}Hochladen</button>
    <span class="f-ready"><b id="f-ready">&nbsp;</b><small id="f-ready-sub">&nbsp;</small></span>
    <span class="f-check"><span id="f-status">&nbsp;</span><button type="button" class="ib" data-act="check" id="btn-check" aria-label="Jetzt prüfen" title="Jetzt prüfen">${SVG_RELOAD}</button></span>
  </footer>
</section>

<!-- Einstellungen -->
<section class="view" id="v-settings" hidden>
  <header class="hdr">${BTN_BACK}<span class="hdr-title">Einstellungen</span><span class="hdr-right">${PILL}</span></header>
  <form id="settings" class="grow scroll" autocomplete="off">
    <div class="form-body">
      <section class="card">
        <span class="kicker">Verbindung</span>
        <label class="field">
          <span class="lbl">Adresse des EventHelper</span>
          <input class="input" type="text" name="baseUrl" placeholder="https://pulse-gdkp.de:3005" spellcheck="false">
          <span class="hint">Mit https:// und Port, ohne /api.</span>
        </label>
        <label class="field">
          <span class="lbl">API-Token</span>
          <input class="input" type="password" name="token" placeholder="unverändert lassen">
          <span class="hint" id="token-hint"></span>
        </label>
        <div class="inline">
          <button type="button" class="btn" data-act="test" id="btn-test">Verbindung testen</button>
          <span class="result" id="test-result" role="status"></span>
        </div>
      </section>

      <section class="card">
        <span class="kicker">World of Warcraft</span>
        <label class="field">
          <span class="lbl">Addon-Datei</span>
          <select class="input" name="savedVariablesPath" id="sv-select"></select>
          <span class="hint" id="sv-hint"></span>
        </label>
        <div class="field">
          <span class="lbl">Gefundene Addon-Ordner</span>
          <div class="dirs" id="addon-dirs"></div>
          <span class="hint">Dorthin schreibt das Tool Council-Daten und Ausgabeliste.</span>
        </div>
        <details id="manual-details">
          <summary>Pfad selbst angeben</summary>
          <input class="input" type="text" name="manualPath" id="manual-path" placeholder="D:\Games\World of Warcraft" spellcheck="false">
          <span class="hint">Nötig, wenn WoW oben nicht gefunden wurde. Es genügt der WoW-Ordner, die Datei wird darunter gesucht. Ebenso: der <code>_classic_era_</code>-Ordner, der Account-Ordner oder direkt die <code>EventHelperSync.lua</code>.</span>
        </details>
      </section>

      <section class="card">
        <span class="kicker">Automatik</span>
        <label class="poll">
          <span class="poll-text"><b>Addon-Datei prüfen alle</b><span class="hint">WoW schreibt sie beim Ausloggen, bei /reload und über den Upload-Knopf im Spiel. Neuer Loot wird danach sofort hochgeladen.</span></span>
          <input class="input" type="number" name="pollSeconds" min="5" max="600">
          <span class="hint" style="font-size:13px">Sek.</span>
        </label>
        <div class="static-lines">
          <span id="auto-council">Council-Daten: alle 15 Minuten und nach jedem Upload</span>
          <span id="auto-handouts">Ausgabeliste: alle 5 Minuten und nach jedem Upload</span>
          <span>Council-Kategorien und Filter stellt die Webseite ein; im Spiel sichtbar nach /reload (<code>/ehc</code>, <code>/ehs bank</code>).</span>
        </div>
      </section>

      <section class="card">
        <span class="kicker">Module</span>
        <label class="poll">
          <span class="poll-text"><b>LevelHelper-Bestzeiten hochladen</b><span class="hint" id="lh-hint">Dungeon-Läufe und Erfolge der Gilde aus den SavedVariables des LevelHelper-Addons.</span></span>
          <input type="checkbox" name="lhModule" id="lh-module">
        </label>
      </section>

      <section class="card">
        <span class="kicker">Jetzt ausführen</span>
        <div class="actions">
          <button type="button" class="action" data-act="upload-all" id="act-upload"><img src="${ICONS.upload}" alt="">Loot hochladen</button>
          <button type="button" class="action" data-act="council" id="act-council"><img src="${ICONS.council}" alt="">Council holen</button>
          <button type="button" class="action" data-act="handouts" id="act-handouts"><img src="${ICONS.handouts}" alt="">Ausgabeliste holen</button>
        </div>
      </section>

      <section class="card">
        <span class="kicker">Version</span>
        <div class="static-lines" id="ver-lines"></div>
        <div class="inline">
          <button type="button" class="btn" data-act="update-check" id="btn-update-check">Nach Updates suchen</button>
          <button type="button" class="btn primary" data-act="update-install" id="btn-update-install" hidden>Update installieren</button>
        </div>
      </section>
    </div>
  </form>
  <footer class="ftr end">
    <button type="button" class="btn lg" data-act="cancel">Abbrechen</button>
    <button type="submit" class="btn lg primary" form="settings" id="btn-save">Speichern</button>
  </footer>
</section>

<!-- Verlauf -->
<section class="view" id="v-log" hidden>
  <header class="hdr">${BTN_BACK}<span class="hdr-title">Verlauf</span>
    <div class="seg" role="group" aria-label="Filter">
      <button type="button" data-act="filter" data-arg="all" aria-pressed="true">Alles</button>
      <button type="button" data-act="filter" data-arg="ok" aria-pressed="false">Erfolge</button>
      <button type="button" data-act="filter" data-arg="problems" aria-pressed="false">Probleme</button>
    </div>
  </header>
  <div class="log grow scroll" id="log"></div>
  <footer class="ftr">
    <span id="log-count">&nbsp;</span>
    <button type="button" class="btn sm" data-act="copy">Kopieren</button>
  </footer>
</section>

<div id="flash" aria-live="polite"></div>

<script>
const KEY = new URLSearchParams(location.search).get("key") || "";
const api = (path, opts) => fetch(path + (path.includes("?") ? "&" : "?") + "key=" + encodeURIComponent(KEY), opts)
  .then(async (r) => {
    const body = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(body.error || ("HTTP " + r.status));
    return body;
  });
const post = (path, body) => api(path, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify(body || {}),
});

// The tool's own window (WebView2) answers messages; see "Eigenes Fenster" below.
const HOST = window.chrome && window.chrome.webview ? window.chrome.webview : null;
function hostPost(msg) {
  if (!HOST) return false;
  try {
    HOST.postMessage(msg);
    return true;
  } catch {
    return false;
  }
}
function closeWindow() {
  if (!hostPost({ type: "close" })) window.close();
}

const $ = (id) => document.getElementById(id);
const esc = (s) => String(s == null ? "" : s).replace(/[<>&"]/g, (c) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;", '"': "&quot;" }[c]));
const ICON = {
  upload: "${ICONS.upload}",
  council: "${ICONS.council}",
  guildbank: "${ICONS.guildbank}",
  handouts: "${ICONS.handouts}",
  levelhelper: "${ICONS.levelhelper}",
};
// Die SVG_*-Konstanten oben leben nur in Node; was das Seiten-Skript selbst
// braucht, muss hier hinein (sonst "SVG_RELOAD is not defined", 1.16.4).
const SVG_RELOAD = ${JSON.stringify(SVG_RELOAD)};
const SVG = {
  ready: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 19V5M5 12l7-7 7 7"/></svg>',
  wait: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" aria-hidden="true"><path d="M6 3h12M6 21h12M7 3c0 5 10 5 10 9s-10 4-10 9M17 3c0 5-10 5-10 9s10 4 10 9"/></svg>',
  done: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 12l5 5 9-10"/></svg>',
  empty: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" aria-hidden="true"><path d="M6 12h12"/></svg>',
  upcoming: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><rect x="4" y="5" width="16" height="15" rx="2"/><path d="M4 10h16M9 3v4M15 3v4"/></svg>',
  ext: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5"/></svg>',
  x: '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18"/></svg>',
  check: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 12l5 5 9-10"/></svg>',
  warn: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" aria-hidden="true"><path d="M12 6v8M12 18v.5"/></svg>',
};
const SVG_UP = ${JSON.stringify(SVG_UP)};
// The status of a raid as a word (Canvas A): the word carries the state.
const STATE_WORDS = {
  ready: "Aus dem Spiel bereit",
  wait: "Wartet in der Inbox",
  done: "Importiert",
  empty: "Ohne Loot",
  upcoming: "Kommend",
};

// Die zwei Datenquellen: der lokale Stand (/api/state, alle 3 s) und der
// Raid-Status vom echten Server (/api/raids, alle 12 s — ein Aufruf gegen
// einen fremden Server, den man nicht unnötig oft machen muss).
let lastState = null;
let lastRaids = null;
let raidsError = null;

// Ansicht: "main", "settings" oder "log". Ohne Adresse/Token wird aus
// "main" und "settings" die Einrichtung.
let view = "main";
// Welche Listen "Weitere anzeigen" aufgeklappt haben (je Version) und die
// gewählte Version — beides übersteht den Poll.
// Sidebar selection "<guildId>:<version>" (null: the first version with work,
// else the one of the addon file).
let pickedVersion = null;
const expanded = {};
const ROW_LIMIT = 8;
let logFilter = "all";
// Formulare nur füllen, solange niemand darin tippt.
let editing = false;
let setupEditing = false;
let setupPathOpen = false;
// When "Installieren" was clicked: until the server confirms (state.installing)
// the click counts as running, but never longer than a few seconds, so a lost
// answer cannot keep the strip on "Wird installiert …" forever.
let updateClickedAt = 0;
// Laufende Aktionen (Knöpfe gesperrt): "upload", "one:<id>", "council", ...
const busy = new Set();

// --- Hilfen -----------------------------------------------------------------

function flash(text, kind) {
  const div = document.createElement("div");
  div.className = "toast" + (kind === "err" ? " err" : "");
  div.setAttribute("role", kind === "err" ? "alert" : "status");
  div.textContent = text;
  $("flash").innerHTML = "";
  $("flash").appendChild(div);
  setTimeout(() => { if ($("flash").firstChild === div) $("flash").innerHTML = ""; }, 5000);
}

// innerHTML nur tauschen, wenn sich etwas geändert hat: sonst verlöre ein
// Knopf alle 3 s den Tastaturfokus.
function setHtml(el, html) {
  if (el._html === html) return;
  el._html = html;
  el.innerHTML = html;
}

const pad = (n) => String(n).padStart(2, "0");
function hhmm(ms) {
  const d = new Date(ms);
  return pad(d.getHours()) + ":" + pad(d.getMinutes());
}
function hhmmss(ms) {
  const d = new Date(ms);
  return hhmm(ms) + ":" + pad(d.getSeconds());
}
// Heute nur die Uhrzeit, sonst mit Datum.
function stamp(ms) {
  if (!ms) return "–";
  const d = new Date(ms);
  if (d.toDateString() === new Date().toDateString()) return hhmm(ms);
  return d.getDate() + "." + (d.getMonth() + 1) + ". " + hhmm(ms);
}
function ago(ms) {
  if (!ms) return "noch nie";
  const s = Math.max(0, Math.round((Date.now() - ms) / 1000));
  if (s < 60) return "vor " + s + " s";
  if (s < 3600) return "vor " + Math.round(s / 60) + " min";
  return "um " + stamp(ms);
}
function fmtDay(ms) {
  const d = new Date(ms);
  return ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"][d.getDay()] + ", " + d.toLocaleDateString("de-DE");
}
const plural = (n, one, many) => n + " " + (n === 1 ? one : many);
function sourceLabel(gargul, rclc) {
  if (gargul && rclc) return "Gargul + RCLootCouncil";
  return gargul ? "Gargul" : "RCLootCouncil";
}

const configured = () => !!(lastState && lastState.config.baseUrl && lastState.config.hasToken);
const base = () => ((lastState && lastState.config.baseUrl) || "").replace(/\/+$/, "");
const siteUrl = (path) => (base() ? base() + path : "");
function eventUrl(eventId, path) {
  if (!base() || !eventId) return "";
  return base() + path + "?event=" + encodeURIComponent(eventId);
}
function hostOf(url) {
  try { return new URL(url).host; } catch { return ""; }
}

// --- Daten holen ------------------------------------------------------------

// Only a failed request is a connection problem; render() never throws (every
// section is isolated, see safely()), so a render bug cannot show up here.
async function refresh() {
  let state;
  try {
    state = await api("/api/state");
  } catch (e) {
    onConnectionLost(e);
    return;
  }
  lastState = state;
  render();
}

// While the tool restarts after an update the old instance goes away on
// purpose: not an error, and the old window has nothing left to show.
let restartingSince = 0;
function onConnectionLost(e) {
  const f = $("f-status");
  if (restartingSince) {
    if (f) f.textContent = "Starte neu …";
    closeWindow();
    return;
  }
  if (f) f.textContent = "Oberfläche nicht erreichbar: " + e.message;
}

// Poll the state every 3 s, once per second while an update installs (that is
// when the progress changes). One timer chain: calls never overlap.
function pollDelay() {
  return isInstallActive() ? 1000 : 3000;
}
function schedulePoll() {
  setTimeout(async () => {
    try { await refresh(); } finally { schedulePoll(); }
  }, pollDelay());
}

async function refreshRaids() {
  // Ohne Adresse und Token gibt es keinen Server zu fragen.
  if (lastState && !configured()) {
    lastRaids = null;
    raidsError = null;
    render();
    return;
  }
  try {
    const d = await api("/api/raids");
    lastRaids = d.raids || [];
    raidsError = null;
  } catch (e) {
    raidsError = e.message;
  }
  render();
}

const reloadAll = () => { refresh(); refreshRaids(); };

async function run(key, fn) {
  if (busy.has(key)) return;
  busy.add(key);
  render();
  try {
    await fn();
  } catch (e) {
    flash(e.message, "err");
  } finally {
    busy.delete(key);
    render();
  }
}

// --- Aktionen ---------------------------------------------------------------

function openExternal(url) {
  // Im echten Browser, nicht im eigenen App-Fenster (siehe webui.js).
  post("/api/open-external", { url }).catch((e) => flash(e.message, "err"));
}

const actions = {
  nav(arg) {
    if (arg === "settings") { editing = false; $("test-result").innerHTML = ""; }
    view = arg;
    render();
    const v = activeView();
    const first = v && v.querySelector(".back, [data-act]");
    if (first && arg !== "main") first.focus();
  },
  quit() {
    // Beendet das ganze Sync-Tool (die .exe hat keine Konsole) und schliesst
    // danach das Fenster — in dieser Reihenfolge, sonst käme die Anfrage nie an.
    post("/api/quit").catch(() => {}).finally(closeWindow);
  },
  minimize() { hostPost({ type: "minimize" }); },
  // Sidebar: a version of a server ("<guildId>:<version>").
  pick(arg) { pickedVersion = arg; render(); },
  more(arg) { expanded[arg] = true; render(); },
  open(arg) { if (arg) openExternal(arg); },
  "upload-all"() {
    run("upload", async () => {
      const r = await post("/api/upload");
      flash(r.results.length ? plural(r.results.length, "Abend", "Abende") + " hochgeladen." : "Nichts hochzuladen.", "ok");
      reloadAll();
    });
  },
  "upload-one"(arg) {
    run("one:" + arg, async () => {
      const r = await post("/api/upload-one", { sessionId: arg });
      flash(r.results.length ? "Hochgeladen, wartet in der Inbox." : "Nichts zu tun.", "ok");
      reloadAll();
    });
  },
  skip(arg) {
    run("skip:" + arg, async () => {
      await post("/api/sessions", { sessionIds: [arg], excluded: true });
      flash("Wird nicht hochgeladen.", "ok");
      reloadAll();
    });
  },
  check() {
    run("check", async () => {
      await post("/api/check");
      reloadAll();
    });
  },
  council() {
    run("council", async () => {
      const r = await post("/api/council");
      const files = (r.council.files || []).length;
      flash(files
        ? councilSummary(r.council) + " in " + files + " Addon-Ordner geschrieben – im Spiel /reload."
        : "Council-Daten geholt, aber kein Addon-Ordner gefunden.", files ? "ok" : "err");
      refresh();
    });
  },
  handouts() {
    run("handouts", async () => {
      const r = await post("/api/handouts");
      const files = (r.handouts.files || []).length;
      flash(files
        ? plural(r.handouts.handouts, "Posten", "Posten") + " in " + files + " Addon-Ordner geschrieben – im Spiel /reload."
        : "Ausgabeliste geholt, aber kein Addon-Ordner gefunden.", files ? "ok" : "err");
      refresh();
    });
  },
  test() {
    const f = $("settings");
    const out = $("test-result");
    run("test", async () => {
      out.innerHTML = '<span class="hint">Prüfe …</span>';
      try {
        await post("/api/test", { baseUrl: f.baseUrl.value.trim(), token: f.token.value.trim() });
        out.innerHTML = '<span class="result ok-text">' + SVG.check + "Server erreichbar, Token gültig</span>";
      } catch (e) {
        out.innerHTML = '<span class="result err-text">' + SVG.x + esc(e.message) + "</span>";
      }
      refresh();
    });
  },
  cancel() {
    editing = false;
    lhTouched = false;
    const f = $("settings");
    f.token.value = "";
    f.manualPath.value = "";
    actions.nav("main");
  },
  filter(arg) { logFilter = arg; render(); },
  copy() {
    const text = filteredLog().map((e) => hhmmss(e.at) + "  " + e.text).join("\n");
    const done = () => flash("Verlauf in die Zwischenablage kopiert.", "ok");
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done, () => copyFallback(text) && done());
    } else if (copyFallback(text)) {
      done();
    }
  },
  "setup-path"() {
    setupPathOpen = !setupPathOpen;
    render();
    if (setupPathOpen) $("su-path").focus();
  },
  "setup-connect"() { setupConnect(); },
  "update-install"() {
    const u = lastState && lastState.update;
    // Started with Node.js the tool cannot replace itself: only the link.
    if (u && !canInstall(u)) { actions["update-notes"](); return; }
    updateClickedAt = Date.now();
    run("update", async () => {
      const r = await post("/api/update/install");
      if (r.restarting) {
        // The new version opens its own window and this old process exits,
        // which closes this window. Until then the strip says "Starte neu …";
        // if the new one does not come up, the error shows there instead.
        restartingSince = Date.now();
        refresh();
        return;
      }
      const addons = r.addons || [];
      const restart = addons.some((a) => a.restartNeeded);
      flash(addons.length
        ? "Addon aktualisiert – " + (restart ? "WoW neu starten, damit es die neuen Dateien lädt." : "im Spiel /reload.")
        : "Schon alles aktuell.", "ok");
      refresh();
    });
  },
  "update-check"() {
    run("update-check", async () => {
      const u = (await post("/api/update/check")).update;
      if (u.lastError) flash(u.lastError.message, "err");
      else flash(u.available ? "Update auf v" + u.latest.version + " verfügbar." : "Alles aktuell.", "ok");
      refresh();
    });
  },
  "update-notes"() {
    const u = lastState && lastState.update;
    if (u) openExternal((u.latest && u.latest.url) || u.releasesPage);
  },
  "open-path"() {
    view = "settings";
    editing = false;
    render();
    $("manual-details").open = true;
    $("manual-path").focus();
  },
};

function copyFallback(text) {
  const ta = document.createElement("textarea");
  ta.value = text;
  document.body.appendChild(ta);
  ta.select();
  let ok = false;
  try { ok = document.execCommand("copy"); } catch { ok = false; }
  ta.remove();
  if (!ok) flash("Kopieren nicht möglich.", "err");
  return ok;
}

document.addEventListener("click", (ev) => {
  const el = ev.target.closest("[data-act]");
  if (!el || el.disabled) return;
  const fn = actions[el.dataset.act];
  if (!fn) return;
  ev.preventDefault();
  fn(el.dataset.arg);
});

document.addEventListener("keydown", (ev) => {
  const tile = ev.target.closest && ev.target.closest('div.tile[data-act="open"]');
  if (tile && tile === ev.target && (ev.key === "Enter" || ev.key === " ")) { ev.preventDefault(); actions.open(tile.dataset.arg); return; }
  if (ev.key === "Escape" && (view === "settings" || view === "log") && activeView() && activeView().id !== "v-setup") {
    if (view === "settings") actions.cancel(); else actions.nav("main");
  }
});

let lhTouched = false;
$("settings").addEventListener("input", () => { editing = true; });
$("settings").addEventListener("change", (ev) => { if (ev.target && ev.target.name === "lhModule") lhTouched = true; });
$("settings").addEventListener("submit", (ev) => {
  ev.preventDefault();
  const f = ev.target;
  run("save", async () => {
    await post("/api/settings", {
      baseUrl: f.baseUrl.value.trim(),
      token: f.token.value,
      savedVariablesPath: f.savedVariablesPath.value,
      manualPath: f.manualPath.value.trim(),
      pollSeconds: Number(f.pollSeconds.value),
      // Only when the switch was touched: untouched stays "automatic".
      ...(lhTouched ? { modules: { levelhelper: !!f.lhModule.checked } } : {}),
    });
    f.token.value = "";
    f.manualPath.value = "";
    editing = false;
    lhTouched = false;
    flash("Gespeichert.", "ok");
    view = "main";
    reloadAll();
  });
});

["su-base", "su-token", "su-path"].forEach((id) => $(id).addEventListener("input", () => {
  setupEditing = true;
  renderSetupSteps();
}));
["su-base", "su-token", "su-path"].forEach((id) => $(id).addEventListener("keydown", (ev) => {
  if (ev.key === "Enter") setupConnect();
}));

// Einrichtung: erst prüfen, dann speichern — ein falsches Token landet so
// gar nicht erst in der Konfiguration.
function setupConnect() {
  const baseUrl = $("su-base").value.trim();
  const token = $("su-token").value.trim();
  const status = $("su-status");
  if (!baseUrl) { status.innerHTML = '<span class="err-text">Bitte die Adresse angeben.</span>'; $("su-base").focus(); return; }
  if (!token && !(lastState && lastState.config.hasToken)) {
    status.innerHTML = '<span class="err-text">Bitte das API-Token angeben.</span>';
    $("su-token").focus();
    return;
  }
  run("connect", async () => {
    status.textContent = "Prüfe die Verbindung …";
    try {
      await post("/api/test", { baseUrl, token });
    } catch (e) {
      status.innerHTML = '<span class="err-text">' + esc(e.message) + "</span>";
      return;
    }
    try {
      await post("/api/settings", {
        baseUrl,
        token,
        savedVariablesPath: (lastState && lastState.config.savedVariablesPath) || "",
        manualPath: setupPathOpen ? $("su-path").value.trim() : "",
        pollSeconds: (lastState && lastState.config.pollSeconds) || 15,
      });
    } catch (e) {
      status.innerHTML = '<span class="err-text">' + esc(e.message) + "</span>";
      return;
    }
    setupEditing = false;
    $("su-token").value = "";
    status.textContent = "Prüft die Verbindung vor dem Speichern";
    flash("Verbunden – läuft.", "ok");
    view = "main";
    await refresh();
    refreshRaids();
  });
}

// --- Darstellung ------------------------------------------------------------

function activeView() {
  return document.querySelector(".view:not([hidden])");
}

function viewId() {
  if (!lastState) return null;
  if (!configured() && view !== "log") return "v-setup";
  return "v-" + view;
}

// One broken section must not freeze the page: every render function runs on
// its own. A failure goes to the console and shows a small notice next to that
// section only; everything else keeps updating.
function safely(name, getEl, fn) {
  let el = null;
  try { el = getEl ? getEl() : null; } catch { el = null; }
  try {
    fn();
    if (el && el._err) el._err.hidden = true;
  } catch (e) {
    console.error("Abschnitt „" + name + "“ lässt sich nicht darstellen:", e);
    try {
      if (!el || !el.parentNode) return;
      if (!el._err) {
        el._err = document.createElement("div");
        el._err.className = "sec-err";
        el._err.setAttribute("role", "alert");
        el.parentNode.insertBefore(el._err, el);
      }
      el._err.textContent = "„" + name + "“ lässt sich gerade nicht anzeigen (" + (e && e.message ? e.message : e) + ").";
      el._err.hidden = false;
    } catch (e2) {
      console.error("Fehleranzeige fehlgeschlagen:", e2);
    }
  }
}

function render() {
  if (!lastState) return;
  let id = null;
  safely("Ansicht", null, () => {
    id = viewId();
    for (const v of document.querySelectorAll(".view")) v.hidden = v.id !== id;
  });
  const headerOf = () => document.querySelector(".view:not([hidden]) .hdr");
  safely("Kopfzeile", headerOf, renderChrome);
  if (id === "v-main") safely("Verbindung", () => $("who"), () => renderWho(lastState));
  safely("Update", () => $("upd"), renderUpdate);
  safely("Version", () => $("ver-lines"), renderVersionCard);
  if (id === "v-setup") safely("Einrichtung", () => $("su-connect"), renderSetup);
  else if (id === "v-main") renderMain();
  else if (id === "v-settings") safely("Einstellungen", () => $("settings"), renderSettings);
  else if (id === "v-log") safely("Verlauf", () => $("log"), renderLog);
  safely("Fenstergrösse", null, fitWindow);
}

// Kopfzeile: Version, Host und die Verbindungs-Pille (Einrichtung und
// Einstellungen; die Hauptansicht zeigt stattdessen "Verbunden als").
function renderChrome() {
  const d = lastState;
  const host = hostOf(d.config.baseUrl);
  for (const el of document.querySelectorAll(".js-ver")) {
    el.textContent = "V" + d.version + (host ? " · " + host : "");
  }
  let cls = "off";
  let text = "Nicht eingerichtet";
  let title = "Adresse und Token fehlen";
  const c = d.connection;
  if (configured()) {
    if (c && c.ok === true) { cls = "ok"; text = "Verbunden"; title = "Server erreichbar, Token gültig"; }
    else if (c && c.ok === false) { cls = "err"; text = "Keine Verbindung"; title = c.message || ""; }
    else { text = "Verbinde …"; title = "Noch keine Antwort vom Server"; }
  }
  for (const el of document.querySelectorAll(".js-pill")) {
    el.className = "pill js-pill " + cls;
    el.title = title;
    el.querySelector(".ptext").textContent = text;
  }
}

// --- Updates (lib/updater.js) -----------------------------------------------

// Whether "Installieren" can do anything here: addon folders can always be
// updated, the tool itself only as the packed .exe.
function canInstall(u) {
  return !!u && ((u.addons || []).length > 0 || (u.toolOutdated && u.canSelfUpdate));
}

// "Sync-Tool 1.13.0 · Addon TBC Anniversary 1.12.0" — what is outdated.
function updateParts(u) {
  const parts = [];
  if (u.toolOutdated) parts.push("Sync-Tool " + u.toolVersion + (u.canSelfUpdate ? "" : " (von Hand laden)"));
  for (const a of u.addons || []) parts.push("Addon " + a.label + " " + (a.version || "?"));
  return parts;
}

// MB with a decimal only for small files: "25 von 74 MB", "0,3 von 0,5 MB".
function mb(bytes, ref) {
  const m = bytes / 1048576;
  return (ref < 10 * 1048576 ? m.toFixed(1) : String(Math.round(m))).replace(".", ",");
}

// What the update is doing right now (u.progress from lib/updater.js).
function progressText(p) {
  if (!p) return "Wird installiert …";
  if (p.phase === "restart") return "Starte neu …";
  if (p.step === "verify") return "Prüfe …";
  if (p.step === "install") return "Installiere …";
  if (p.total > 0) {
    const pct = Math.min(100, Math.floor((p.received / p.total) * 100));
    return "Lädt herunter … " + pct + " % (" + mb(p.received, p.total) + " von " + mb(p.total, p.total) + " MB)";
  }
  return p.received ? "Lädt herunter … " + mb(p.received, p.received) + " MB" : "Lädt herunter …";
}

// Whether an update is being installed (or restarting) right now.
function isInstallActive() {
  const u = lastState && lastState.update;
  if (u && (u.installing || (u.progress && u.progress.phase === "restart"))) return true;
  return busy.has("update") && Date.now() - updateClickedAt < 5000;
}

// The green strip on the overview: update available, progress, or the error.
function renderUpdate() {
  const u = lastState.update;
  const show = !!(u && u.available && u.latest);
  const working = isInstallActive();
  if (u && u.progress && u.progress.phase === "restart" && !restartingSince) restartingSince = Date.now();
  if (u && !working && !(u.progress && u.progress.phase === "restart")) restartingSince = 0;
  const err = !working && u && u.installError ? u.installError : null;
  const strip = $("upd");

  strip.hidden = !(show || err || working);
  strip.classList.toggle("err", !!err);
  if (!strip.hidden) {
    const version = u && u.latest ? "v" + u.latest.version : "";
    if (err) {
      $("upd-title").textContent = "Update fehlgeschlagen";
      $("upd-text").textContent = err.message;
    } else if (working) {
      $("upd-title").textContent = "Update" + (version ? " auf " + version : "") + " wird installiert";
      $("upd-text").textContent = progressText(u && u.progress);
    } else {
      $("upd-title").textContent = "Update auf " + version + " verfügbar";
      $("upd-text").textContent = "Installiert: " + updateParts(u).join(" · ");
    }
    $("upd-notes").hidden = !!err || working;
    $("upd-dl").hidden = !err;
    $("upd-btn").hidden = working && !!(u && u.progress && u.progress.phase === "restart");
    $("upd-btn").textContent = working ? "Wird installiert …" : err ? "Erneut versuchen" : canInstall(u) ? "Installieren" : "Herunterladen";
    $("upd-btn").disabled = working;
  }
}

// The version card in the settings.
function renderVersionCard() {
  const u = lastState.update;
  const show = !!(u && u.available && u.latest);
  const working = isInstallActive();
  const err = !working && u && u.installError ? u.installError : null;

  const lines = ["Sync-Tool v" + lastState.version];
  if (u) {
    if (u.latest) lines.push("Neueste Version: v" + u.latest.version + (show ? "" : " – alles aktuell"));
    if (show) lines.push("Veraltet: " + updateParts(u).join(" · "));
    lines.push(u.checking ? "Prüfe gerade …" : "Zuletzt geprüft: " + ago(u.checkedAt) + " (alle 6 Stunden von selbst)");
    if (working) lines.push(progressText(u.progress));
    else if (err) lines.push("Update fehlgeschlagen: " + err.message);
    else if (u.lastError) lines.push("Fehler: " + u.lastError.message);
  }
  setHtml($("ver-lines"), lines.map((l) => "<span>" + esc(l) + "</span>").join(""));
  $("btn-update-check").hidden = !u;
  $("btn-update-check").disabled = busy.has("update-check") || !!(u && u.checking) || working;
  $("btn-update-install").hidden = !(show || err);
  $("btn-update-install").textContent = working ? "Wird installiert …" : err ? "Erneut versuchen" : canInstall(u) ? "Update installieren" : "Neue Version herunterladen";
  $("btn-update-install").disabled = working;
}

// Raids vom Server + lokale Sessions in die vier Reiter sortieren:
//   Bereit   — der Server kennt den Raid und eine lokale Session passt dazu,
//              dazu lokale Sessions ohne passenden Termin (trotzdem hochladbar,
//              landen als unzugeordnete Inbox-Session).
//   Wartet   — hochgeladen, liegt unbestätigt in der Addon-Inbox.
//   Erledigt — vergangene Raids: importiert oder kein Loot gefunden.
//   Kommend  — Raids in der Zukunft.
function buildGroups() {
  const sessions = (lastState && lastState.sessions) || [];
  const raids = lastRaids || [];
  const matchedIds = new Set(raids.filter((r) => r.matchedSessionId).map((r) => r.matchedSessionId));
  const unmatched = sessions.filter((s) => (
    !s.excluded && s.items > 0 && !s.lastUpload && !matchedIds.has(s.sessionId)
  ));
  return splitRaids(raids, unmatched);
}

function splitRaids(raids, unmatched) {
  const ready = raids.filter((r) => r.status === "ready");
  const pending = raids.filter((r) => r.status === "pending");
  const rest = raids.filter((r) => r.status !== "ready" && r.status !== "pending");
  const now = Date.now();
  const pastRest = rest.filter((r) => r.startTime * 1000 <= now);
  const upcomingRest = rest.filter((r) => r.startTime * 1000 > now).sort((a, b) => a.startTime - b.startTime);
  return { ready, unmatched, pending, pastRest, upcomingRest };
}

// --- Servers and their versions (issue #51, Canvas A) ------------------------

// The version colour is the only accent of the overview.
const VERSION_INFO = {
  tbc: { label: "TBC Anniversary", color: "var(--tbc)" },
  forever: { label: "WoW Forever", color: "var(--fe)" },
  classic: { label: "Classic Era", color: "var(--era)" },
  era: { label: "Classic Era", color: "var(--era)" },
};
function versionInfo(id, short) {
  return VERSION_INFO[id] || { label: short || id || "Unbekannte Version", color: "var(--muted)" };
}
function initials(name) {
  const words = String(name || "").trim().split(/\s+/).filter(Boolean);
  if (!words.length) return "?";
  return (words[0][0] + (words[1] ? words[1][0] : words[0].slice(1, 2))).toUpperCase();
}

// Sidebar model from /api/ingest/me (state.me): servers with their versions,
// every raid sorted to the version of its server (guildId + gameVersion).
// Raids no listed version takes go to "Ohne Server". Local sessions without a
// raid date carry no server: they go to the one version of the addon file's
// game version, else to "Ohne Server". Without the server list (older server,
// not fetched yet) a single version of the addon file takes everything.
function groupServers(me, raids, sessions, fileVersion) {
  const known = me && !me.unsupported && Array.isArray(me.servers) ? me.servers : [];
  const mk = (guildId, id, short, realm) => {
    const info = versionInfo(id, short);
    return { key: guildId + ":" + id, guildId, id, label: info.label, short: short || "", realm: realm || "", color: info.color, raids: [], sessions: [] };
  };
  let servers = known.map((s) => {
    const guildId = String(s.guildId || "");
    const name = s.label || s.name || "Server";
    return { guildId, name, initials: initials(name), versions: (s.versions || []).map((v) => mk(guildId, String(v.id || ""), v.short, v.realm)) };
  }).filter((s) => s.versions.length);
  const fallback = !servers.length;
  if (fallback) servers = [{ guildId: "", name: "Dein Server", initials: "", fallback: true, versions: [mk("", fileVersion || "", "", "")] }];
  const versions = [].concat(...servers.map((s) => s.versions));
  const none = mk("", "", "", "");
  none.key = "none";
  none.label = "Ohne Server";
  for (const r of raids || []) {
    const v = fallback ? versions[0] : versions.find((x) => x.guildId === String(r.guildId || "") && x.id === String(r.gameVersion || ""));
    (v || none).raids.push(r);
  }
  const same = versions.filter((x) => x.id === fileVersion);
  const home = fallback ? versions[0] : same.length === 1 ? same[0] : none;
  for (const s of sessions || []) home.sessions.push(s);
  for (const v of versions.concat(none)) {
    v.ready = v.raids.filter((r) => r.status === "ready").length + v.sessions.length;
    v.pending = v.raids.filter((r) => r.status === "pending").length;
  }
  return { servers, versions, none: none.raids.length || none.sessions.length ? none : null };
}

// The picked version, else the first with something to upload, else the one
// of the addon file, else the first.
function pickVersion(model, fileVersion) {
  if (!model) return null;
  const all = model.versions.concat(model.none ? [model.none] : []);
  return all.find((v) => v.key === pickedVersion)
    || all.find((v) => v.ready)
    || all.find((v) => v.pending)
    || all.find((v) => v.id === fileVersion)
    || all[0] || null;
}

function versionSub(v) {
  const parts = [];
  if (v.realm) parts.push(v.realm);
  if (v.ready) parts.push(v.ready + " bereit");
  else if (v.pending) parts.push(v.pending + " im Web offen");
  return parts.join(" · ");
}

function versionButton(v, picked) {
  return '<button type="button" class="sv" data-act="pick" data-arg="' + esc(v.key) + '" style="--vc:' + v.color + '"'
    + ' aria-current="' + (!!picked && picked.key === v.key) + '"><span class="sv-name">' + esc(v.label) + "</span>"
    + '<span class="sv-sub">' + (esc(versionSub(v)) || "&nbsp;") + "</span></button>";
}

function renderSide(model, picked) {
  let html = "";
  for (const s of model.servers) {
    html += '<div class="srv">' + (s.initials ? '<span class="srv-ini" aria-hidden="true">' + esc(s.initials) + "</span>" : "")
      + '<span class="srv-name" title="' + esc(s.name) + '">' + esc(s.name) + "</span></div>"
      + s.versions.map((v) => versionButton(v, picked)).join("");
  }
  if (model.none) {
    html += '<div class="side-foot">Raids ohne passenden Server</div>' + versionButton(model.none, picked);
  }
  setHtml($("side"), html);
}

function renderVersionTitle(model, v) {
  if (!v) { setHtml($("ver-title"), ""); return; }
  const server = model.servers.find((s) => s.versions.indexOf(v) >= 0);
  const where = [server && !server.fallback ? server.name : "", v.realm].filter(Boolean).join(" · ");
  setHtml($("ver-title"), '<b style="--vc:' + v.color + '">' + esc(v.label) + "</b>" + (where ? "<span>" + esc(where) + "</span>" : ""));
}

// "Verbunden als Marc · gilt für 2 Server" in the overview header.
function renderWho(d) {
  const el = $("who");
  const c = d.connection;
  const me = d.me;
  let html = "Nicht eingerichtet";
  let err = false;
  let title = "Adresse und Token fehlen";
  if (configured()) {
    if (c && c.ok === false) { html = "Keine Verbindung"; err = true; title = c.message || ""; }
    else if (c && c.ok === true) {
      const n = me && Array.isArray(me.servers) ? me.servers.length : 0;
      const name = me && me.owner && me.owner.name;
      html = (name ? "Verbunden als <b>" + esc(name) + "</b>" : "Verbunden") + (n ? " · gilt für " + plural(n, "Server", "Server") : "");
      title = hostOf(d.config.baseUrl);
    } else { html = "Verbinde …"; title = "Noch keine Antwort vom Server"; }
  }
  el.classList.toggle("err", err);
  el.title = title;
  setHtml(el, html);
}

// An old server key still works, but only for its one server: say so, no
// forced switch.
function renderLegacy(d) {
  const legacy = d.me && d.me.legacy;
  const el = $("legacy");
  el.hidden = !legacy;
  if (!legacy) return;
  const server = ((d.me && d.me.servers) || []).find((s) => String(s.guildId) === String(legacy.guildId));
  const name = server ? server.label || server.name : "einen Server";
  setHtml(el, "Alter Server-Schlüssel: gilt nur für <b>" + esc(name) + "</b>. Er läuft weiter; für alle deine Server "
    + "auf der Webseite unter Mein Profil einen eigenen Schlüssel anlegen.");
}

// The notice area takes no space when every notice in it is hidden.
function renderBanners() {
  const shown = ["upd", "problems", "legacy", "strip"].some((id) => $(id) && !$(id).hidden);
  $("banners").classList.toggle("none", !shown);
}

// Council categories and handout banks of the picked version. Data without
// server tags (older web server) shows everywhere.
function councilFor(c, v) {
  if (!c || !v || !v.guildId) return c;
  const cats = (c.categories || []).filter((k) => !k.guildId || (k.guildId === v.guildId && (!k.gameVersion || k.gameVersion === v.id)));
  return { ...c, categories: cats, raiders: cats.reduce((sum, k) => sum + (k.raiders || 0), 0) };
}
function handoutsFor(h, v) {
  if (!h || !v || !v.guildId || !Array.isArray(h.perBank) || !h.perBank.length) return h;
  const banks = h.perBank.filter((b) => b.guildId === v.guildId && (!b.gameVersion || b.gameVersion === v.id));
  return { ...h, banks: banks.length, handouts: banks.reduce((sum, b) => sum + (b.handouts || 0), 0) };
}

function councilSummary(c) {
  return plural((c.categories || []).length, "Kategorie", "Kategorien") + " · " + c.raiders + " Raider";
}

function tileHtml(t) {
  const head = '<span class="tile-head"><img src="' + t.icon + '" alt="" width="30" height="30">'
    + '<span class="kicker">' + esc(t.kicker) + "</span>"
    + (t.fetchAct
      ? '<button type="button" class="tbtn' + (t.fetching ? " spin" : "") + '" data-act="' + t.fetchAct + '" aria-label="' + esc(t.fetchLabel)
        + '" title="' + esc(t.fetchLabel) + '"' + (t.fetching ? " disabled" : "") + ">" + SVG_RELOAD + "</button>"
      : "")
    + '<span class="dot ' + (t.dot || "") + '" title="' + esc(t.dotTitle || "") + '"></span></span>';
  const body = '<span class="tile-body"><span class="tile-val">' + esc(t.value) + "</span>"
    + '<span class="tile-sub' + (t.subErr ? " err-text" : "") + '"' + (t.subTitle ? ' title="' + esc(t.subTitle) + '"' : "")
    + ">" + esc(t.sub || "") + "</span></span>";
  if (t.link && t.fetchAct) {
    // Ein Knopf darf nicht in einem Knopf stehen: die Kachel wird zum Link-Feld.
    return '<div class="tile" role="link" tabindex="0" data-act="open" data-arg="' + esc(t.link) + '" title="'
      + esc((t.title ? t.title + "\n\n" : "") + "Auf der Website öffnen") + '">' + head + body + "</div>";
  }
  if (t.link) {
    return '<button type="button" class="tile" data-act="open" data-arg="' + esc(t.link) + '" title="'
      + esc((t.title ? t.title + "\n\n" : "") + "Auf der Website öffnen") + '">' + head + body + "</button>";
  }
  return '<div class="tile"' + (t.title ? ' title="' + esc(t.title) + '"' : "") + ">" + head + body + (t.action || "") + "</div>";
}

// Abfrage-Knopf in der Kachel; während des Holens gesperrt, Unterzeile "wird geholt …".
function withFetch(t, act, label, isBusy) {
  const r = { ...t, fetchAct: act, fetchLabel: label, fetching: isBusy };
  if (isBusy) { r.sub = "wird geholt …"; r.subErr = false; r.subTitle = ""; }
  return r;
}

function councilTile(c) {
  return withFetch(councilTileBase(c), "council", "Council jetzt holen", busy.has("council") || !!(c && c.fetching));
}

function councilTileBase(c) {
  const t = { kicker: "Loot-Council", icon: ICON.council, link: siteUrl("/lootcouncil") };
  if (!c || (!c.lastFetch && !c.lastError && !c.fetching)) {
    return { ...t, value: "Noch nicht geholt", sub: configured() ? "Wird gleich geholt" : "Nach der Einrichtung", dot: "", dotTitle: "Noch nichts" };
  }
  const cats = c.categories || [];
  if (c.lastError && (!c.lastFetch || c.lastError.at >= c.lastFetch)) {
    return { ...t, value: c.lastFetch ? councilSummary(c) : "Nicht geholt", sub: c.lastError.message, subErr: true, dot: "high", dotTitle: "Fehler" };
  }
  if (!c.lastFetch) return { ...t, value: "Wird geholt …", sub: "", dot: "", dotTitle: "" };
  // No council here is a normal state (a version without loot council), not an error: grey.
  if (!cats.length) {
    return {
      ...t, value: "Keine Kategorie", dot: "", dotTitle: "Keine Kategorie mit Loot-Council",
      sub: "Auf der Webseite unter Einstellungen › Kategorien das Lootsystem auf Loot-Council stellen.",
    };
  }
  const noDir = !(c.files || []).length;
  return {
    ...t,
    value: councilSummary(c),
    sub: cats.map((k) => k.name).join(", ") + " · Stand " + stamp(c.generatedAt ? c.generatedAt * 1000 : c.lastFetch)
      + (noDir ? " · kein Addon-Ordner gefunden" : ""),
    subErr: noDir,
    dot: noDir ? "high" : "good",
    dotTitle: noDir ? "Kein Addon-Ordner gefunden" : "Aktuell",
    title: cats.map((k) => k.name + ": " + k.raiders + " Raider").join("\n")
      + (c.fallback ? "\n(älterer Server: nur die Kategorie aus der Konfiguration)" : ""),
  };
}

function guildBankTile(gb) {
  const t = { kicker: "Gildenbank", icon: ICON.guildbank, link: siteUrl("/guildbank") };
  if (!gb) {
    return { ...t, value: "Noch kein Scan", sub: "Kommt mit dem nächsten Besuch der Gildenbank im Spiel", dot: "", dotTitle: "Kein Scan" };
  }
  let status = "wird hochgeladen";
  let dot = "medium";
  let subErr = false;
  let subTitle = "";
  if (gb.uploaded) { status = "hochgeladen"; dot = "good"; }
  else if (gb.lastError) { status = "Upload fehlgeschlagen"; dot = "high"; subErr = true; subTitle = gb.lastError.message + " – neuer Versuch folgt"; }
  return {
    ...t,
    value: (gb.guild || "?") + " · " + gb.items + " Stapel",
    sub: "Scan " + stamp(gb.scannedAt) + " · " + plural(gb.tabs, "Tab", "Tabs") + " · " + status,
    subErr, subTitle, dot,
    dotTitle: gb.uploaded ? "Hochgeladen" : status,
  };
}

// LevelHelper dungeon runs and achievements (lib/levelhelper.js). Shown when
// the module is on or LevelHelper data exists; null state (older fixtures,
// tool without the module) shows nothing.
function levelHelperTile(lh) {
  const t = { kicker: "LevelHelper", icon: ICON.levelhelper };
  if (!lh.enabled) {
    return { ...t, value: "Ausgeschaltet", sub: "In den Einstellungen unter Module einschalten", dot: "", dotTitle: "Aus" };
  }
  if (!lh.found) {
    return { ...t, value: "Keine LevelHelper-Daten", sub: "Im Spiel einloggen, dann erscheinen sie hier", dot: "", dotTitle: "Noch nichts" };
  }
  const t2 = { ...t, value: plural(lh.runs || 0, "Run", "Runs") + " · " + (lh.golds || 0) + " Gold" };
  const title = plural(lh.characters || 0, "Charakter", "Charaktere") + " in " + plural(lh.guilds || 0, "Gilde", "Gilden")
    + ((lh.versions || []).length ? " · " + lh.versions.join(", ") : "");
  if (lh.unsupported) {
    return { ...t2, title, sub: "Server kennt den LevelHelper-Upload noch nicht", subErr: true, dot: "medium", dotTitle: "Server zu alt" };
  }
  if (lh.lastError) {
    return { ...t2, title, sub: lh.lastError.message, subErr: true, dot: "high", dotTitle: "Upload fehlgeschlagen – neuer Versuch folgt" };
  }
  if (lh.uploading) return { ...t2, title, sub: "Lädt hoch …", dot: "pending", dotTitle: "Lädt hoch" };
  if (lh.lastUpload) {
    return { ...t2, title, sub: "Zuletzt hochgeladen " + stamp(lh.lastUpload), dot: "good", dotTitle: "Hochgeladen" };
  }
  return { ...t2, title, sub: configured() ? "Wartet auf den ersten Upload" : "Nach der Einrichtung", dot: "", dotTitle: "Noch nichts hochgeladen" };
}

function handoutsTile(h) {
  return withFetch(handoutsTileBase(h), "handouts", "Ausgabeliste jetzt abfragen", busy.has("handouts") || !!(h && h.fetching));
}

function handoutsTileBase(h) {
  const t = { kicker: "Ausgabeliste", icon: ICON.handouts };
  if (!h || (!h.lastFetch && !h.lastError && !h.fetching && !h.done && !h.reportError)) {
    return { ...t, value: "Noch nicht geholt", sub: configured() ? "Wird gleich geholt" : "Nach der Einrichtung", dot: "", dotTitle: "Noch nichts" };
  }
  const fetchFailed = h.lastError && (!h.lastFetch || h.lastError.at >= h.lastFetch);
  let value;
  let sub;
  let dot = "";
  let dotTitle = "Nichts zu tun";
  let subErr = false;
  if (fetchFailed) {
    value = h.lastFetch ? (h.handouts ? h.handouts + " offen" : "Nichts offen") : "Nicht geholt";
    sub = h.lastError.message;
    subErr = true;
    dot = "high";
    dotTitle = "Fehler";
  } else if (!h.lastFetch) {
    value = "Wird geholt …";
    sub = "";
  } else if (!h.banks) {
    value = "Keine Gildenbank";
    sub = "Auf der Webseite ist keine Gildenbank eingerichtet";
  } else {
    value = h.handouts ? h.handouts + " offen" : "Nichts offen";
    sub = "Stand " + stamp(h.generatedAt ? h.generatedAt * 1000 : h.lastFetch);
    if (!(h.files || []).length) { sub += " · kein Addon-Ordner gefunden"; subErr = true; dot = "high"; dotTitle = "Kein Addon-Ordner"; }
    else if (h.handouts) { dot = "medium"; dotTitle = "Im Spiel mit /ehs bank ausgeben"; }
  }
  let subTitle = "";
  if (h.reportError) {
    sub += " · Melden fehlgeschlagen";
    subErr = true;
    subTitle = h.reportError.message;
    dot = "high";
  } else if (h.done) {
    sub += " · " + h.done + " abgehakt, wird gemeldet";
  }
  return { ...t, value, sub, subErr, subTitle, dot, dotTitle };
}

function rowHtml(r) {
  let html = '<div class="row"><span class="state ' + r.kind + '">' + esc(STATE_WORDS[r.kind]) + "</span>"
    + '<span class="row-text"><span class="row-title" title="' + esc(r.title) + '">' + esc(r.title) + "</span>"
    + '<span class="row-sub">' + esc(r.sub) + "</span></span>";
  if (r.primary) {
    html += '<button type="button" class="btn sm ' + r.primary.cls + '" data-act="' + r.primary.act + '" data-arg="' + esc(r.primary.arg)
      + '"' + (r.primary.disabled ? " disabled" : "") + (r.primary.title ? ' title="' + esc(r.primary.title) + '"' : "") + ">"
      + esc(r.primary.label) + "</button>";
  }
  if (r.link) {
    html += '<button type="button" class="sq" data-act="open" data-arg="' + esc(r.link) + '" aria-label="Auf der Website öffnen" title="Auf der Website öffnen">' + SVG.ext + "</button>";
  }
  if (r.skip) {
    html += '<button type="button" class="sq" data-act="skip" data-arg="' + esc(r.skip) + '" aria-label="Diesen Abend nicht hochladen" title="Diesen Abend nicht hochladen"'
      + (busy.has("skip:" + r.skip) ? " disabled" : "") + ">" + SVG.x + "</button>";
  }
  return html + "</div>";
}

function itemsLabel(gargul, rclc) {
  const n = (gargul || 0) + (rclc || 0);
  return plural(n, "Item", "Items") + " · " + sourceLabel(gargul, rclc);
}

function readyButton(sessionId, d) {
  const working = busy.has("one:" + sessionId) || d.uploading;
  return { label: working ? "Lädt …" : "Hochladen", act: "upload-one", arg: sessionId, cls: "primary", disabled: working };
}

function buildRows(d, g) {
  const ready = g.ready.map((r) => ({
    kind: "ready",
    title: r.title,
    sub: fmtDay(r.startTime * 1000) + " · " + itemsLabel(r.gargul, r.rclc),
    primary: readyButton(r.matchedSessionId, d),
    // Noch kein Loot importiert: zum Event selbst, nicht zur Historie.
    link: eventUrl(r.eventId, "/raids/detail"),
    skip: r.matchedSessionId,
  })).concat(g.unmatched.map((s) => ({
    kind: "ready",
    title: s.instance || "Unbekannter Raid",
    sub: fmtDay(s.startedAt) + " · " + itemsLabel(s.gargul, s.rclc) + " · kein Termin gefunden",
    primary: readyButton(s.sessionId, d),
    // Keine Server-eventId für eine lokale, unzugeordnete Session: kein Link.
    skip: s.sessionId,
  })));
  const inbox = siteUrl("/history/inbox");
  const wait = g.pending.map((r) => ({
    kind: "wait",
    title: r.title,
    sub: fmtDay(r.startTime * 1000) + " · " + (r.inboxItems ? plural(r.inboxItems, "Item wartet", "Items warten") + " in der Inbox" : "Hochgeladen, wartet in der Inbox"),
    // Bestätigt wird in der Addon-Inbox, nicht am Event.
    primary: inbox ? { label: "Im Web zuordnen", act: "open", arg: inbox, cls: "link", title: "In der Addon-Inbox auf der Website bestätigen" } : null,
  }));
  const done = g.pastRest.map((r) => {
    const isDone = r.status === "done";
    return {
      kind: isDone ? "done" : "empty",
      title: r.title,
      sub: fmtDay(r.startTime * 1000) + (isDone && r.itemCount ? " · " + plural(r.itemCount, "Item", "Items") : ""),
      // Mit Loot dahin, wo der Loot steht (Historie); ohne Loot zum Event.
      link: eventUrl(r.eventId, isDone ? "/history/event" : "/raids/detail"),
    };
  });
  const upcoming = g.upcomingRest.map((r) => ({
    kind: "upcoming",
    title: r.title,
    sub: fmtDay(r.startTime * 1000) + " · " + hhmm(r.startTime * 1000),
    link: eventUrl(r.eventId, "/raids/detail"),
  }));
  return { ready, wait, done, upcoming };
}

function renderMain() {
  const d = lastState;
  let g = null;
  let model = null;
  let picked = null;
  safely("Raid-Daten", () => $("rows"), () => {
    g = buildGroups();
    model = groupServers(d.me, lastRaids || [], g.unmatched, d.fileVersion || "");
    picked = pickVersion(model, d.fileVersion || "");
  });
  safely("Hinweise", () => $("problems"), () => renderProblems(d));
  safely("Alter Schlüssel", () => $("legacy"), () => renderLegacy(d));
  safely("Neue Daten", () => $("strip"), () => renderDataStrip(d));
  safely("Server", () => $("side"), () => renderSide(model, picked));
  safely("Auswahl", () => $("ver-title"), () => renderVersionTitle(model, picked));
  safely("Raid-Abende", () => $("rows"), () => renderRaidNights(d, picked));
  safely("Kacheln", () => $("tiles"), () => renderTiles(d, picked));
  safely("Fusszeile", () => $("btn-check"), () => renderMainFooter(d, g));
  safely("Hinweisleiste", () => $("banners"), renderBanners);
}

function renderProblems(d) {
  // Probleme als Kasten oben — nur sichtbar, wenn wirklich etwas fehlt.
  const problems = [];
  if (!d.file) {
    const roots = d.searchedRoots || [];
    problems.push("Keine EventHelperSync.lua gefunden. Ist das Addon installiert und war es im Spiel schon einmal geladen?"
      + (roots.length ? " Durchsucht: " + roots.map((r) => "<code>" + esc(r) + "</code>").join(", ") : "")
      + '<button type="button" class="linkbtn" data-act="open-path">WoW-Ordner selbst angeben</button>');
  } else if (d.readError) {
    problems.push("Addon-Datei nicht lesbar: " + esc(d.readError));
  } else if (d.envelopeMissing) {
    problems.push("Die Addon-Datei enthält noch keinen Export. Im Spiel den Upload-Knopf drücken (oder /ehs upload).");
  }
  if (d.lastError) problems.push("Letzter Fehler: " + esc(d.lastError.message));
  if (raidsError) problems.push("Raid-Liste vom Server: " + esc(raidsError));
  $("problems").hidden = !problems.length;
  setHtml($("problems"), problems.map((p) => "<div>" + p + "</div>").join(""));
}

function renderDataStrip(d) {
  // Neue Daten fürs Spiel: Council/Ausgabeliste nach dem letzten Schreiben
  // der SavedVariables geschrieben — also seitdem kein /reload im Spiel.
  const sv = d.file ? d.fileMtime : 0;
  const parts = [];
  let newest = 0;
  if (sv && d.council && d.council.changedAt > sv) { parts.push("Council"); newest = Math.max(newest, d.council.changedAt); }
  if (sv && d.handouts && d.handouts.changedAt > sv) { parts.push("Ausgabeliste"); newest = Math.max(newest, d.handouts.changedAt); }
  $("strip").hidden = !parts.length;
  if (parts.length) $("strip-text").textContent = parts.join(" und ") + " von " + stamp(newest) + " · im Spiel /reload";

}

// "Weiteres" of the picked version: Council and handouts of its server, the
// guild bank scan when the addon file is of this game version, Bestzeiten.
function renderTiles(d, v) {
  const tiles = [councilTile(councilFor(d.council, v))];
  if (!v || !v.id || v.id === d.fileVersion) tiles.push(guildBankTile(d.guildBank));
  tiles.push(handoutsTile(handoutsFor(d.handouts, v)));
  if (d.levelHelper && d.levelHelper.show) tiles.push(levelHelperTile(d.levelHelper));
  setHtml($("tiles"), tiles.map(tileHtml).join(""));
}

// One list per version, no tabs: ready, waiting, past, upcoming.
function renderRaidNights(d, v) {
  const key = v ? v.key : "";
  const rows = v ? buildRows(d, splitRaids(v.raids, v.sessions)) : { ready: [], wait: [], done: [], upcoming: [] };
  const list = rows.ready.concat(rows.wait, rows.done, rows.upcoming);
  let html;
  const loading = lastRaids === null && configured();
  if (!list.length) {
    html = '<div class="rows-empty">' + (loading ? (raidsError ? "Raid-Liste nicht geladen." : "Raid-Liste wird geladen …")
      : "Keine Raid-Termine der letzten Wochen gefunden.") + "</div>";
  } else {
    const shown = expanded[key] ? list : list.slice(0, ROW_LIMIT);
    html = shown.map(rowHtml).join("");
    if (shown.length < list.length) {
      html += '<button type="button" class="linkbtn more" data-act="more" data-arg="' + esc(key) + '">Weitere ' + (list.length - shown.length) + " anzeigen</button>";
    }
  }
  setHtml($("rows"), html);
}

// Footer: one "Hochladen" for every server, what it would upload, the check.
function renderMainFooter(d, g) {
  const count = g ? g.ready.length + g.unmatched.length : 0;
  const working = busy.has("upload") || !!d.uploading;
  const loading = lastRaids === null && !raidsError && configured();
  let title;
  let sub;
  if (!d.file) { title = "Keine Addon-Datei"; sub = "Siehe Hinweis oben"; }
  else if (working) { title = "Lädt hoch …"; sub = count ? plural(count, "Abend", "Abende") + " für alle Server" : ""; }
  else if (count) {
    title = plural(count, "Abend", "Abende") + " aus dem Spiel bereit";
    sub = g.ready.map((r) => r.title).concat(g.unmatched.map((s) => s.instance || "Unbekannter Raid")).join(", ") + " · für alle Server";
  } else if (loading) { title = "Raid-Liste wird geladen …"; sub = ""; }
  else {
    title = "Nichts hochzuladen";
    sub = d.lastUpload ? "Zuletzt hochgeladen " + stamp(d.lastUpload.at) : "Wartet auf neuen Loot";
  }
  $("f-ready").textContent = title;
  $("f-ready-sub").textContent = sub || " ";
  const btn = $("btn-upload");
  btn.disabled = working || !count;
  setHtml(btn, SVG_UP + (working ? "Lädt hoch …" : "Hochladen"));
  btn.title = count ? "Lädt alle bereiten Abende hoch, für alle Server" : "Nichts hochzuladen";
  $("f-status").textContent = d.file ? "Addon-Datei geprüft " + ago(d.lastCheck) : "Warte auf die Addon-Datei …";
  $("btn-check").disabled = busy.has("check");
}

function renderSettings() {
  const d = lastState;
  const f = $("settings");
  if (!editing) {
    f.baseUrl.value = d.config.baseUrl || "";
    f.pollSeconds.value = d.config.pollSeconds || 15;
    const lh = d.levelHelper;
    f.lhModule.checked = !!(lh && lh.enabled);
    lhTouched = false;
    $("lh-hint").textContent = !lh ? "" : lh.found
      ? "Dungeon-Läufe und Erfolge der Gilde aus den SavedVariables des LevelHelper-Addons" + (lh.auto ? " (automatisch eingeschaltet)." : ".")
      : "Kein LevelHelper gefunden (WoW Forever); einschalten lädt erst hoch, wenn Daten da sind.";
    f.token.placeholder = d.config.hasToken ? "unverändert lassen" : "ehl_…";
    $("token-hint").textContent = d.config.hasToken
      ? "Gespeichert, endet auf …" + d.config.tokenHint + ". Leer lassen, um ihn zu behalten."
      : "Auf der Webseite unter Einstellungen → Loot-Sync erstellen. Er wird dort genau einmal angezeigt.";

    const sel = $("sv-select");
    const opts = [{ value: "", text: "Automatisch suchen" }].concat(d.candidates.map((c) => ({
      value: c.path, text: (c.label || c.flavor) + " · " + c.account,
    })));
    if (d.config.savedVariablesPath && !d.candidates.some((c) => c.path === d.config.savedVariablesPath)) {
      opts.push({ value: d.config.savedVariablesPath, text: d.config.savedVariablesPath });
    }
    setHtml(sel, opts.map((o) => '<option value="' + esc(o.value) + '">' + esc(o.text) + "</option>").join(""));
    sel.value = d.config.savedVariablesPath || "";
    $("sv-hint").textContent = d.candidates.length
      ? "„Automatisch suchen“ nimmt die zuletzt geschriebene Datei und überlebt eine Neuinstallation von WoW."
      : "Keine WoW-Installation gefunden – bitte den Pfad unten selbst angeben.";
    if (!d.candidates.length) $("manual-details").open = true;
  }

  const dirs = d.addonDirs || [];
  // Two installations with the same flavor (e.g. on two drives): name the
  // WoW folder, else the rows look identical.
  const labelCount = {};
  for (const x of dirs) labelCount[x.label || x.flavor] = (labelCount[x.label || x.flavor] || 0) + 1;
  setHtml($("addon-dirs"), dirs.length
    ? dirs.map((x) => {
      const state = !x.version ? "unknown" : x.outdated ? "old" : "";
      const label = x.label || x.flavor;
      const where = labelCount[label] > 1
        ? '<span class="hint where">' + esc(x.dir.replace(/[\\/][^\\/]+[\\/]Interface[\\/]AddOns[\\/][^\\/]+$/i, "")) + "</span>"
        : "";
      return '<div class="dir" title="' + esc(x.dir) + '"><span class="sdot ' + state + '"></span><b>' + esc(label) + "</b>" + where
        + '<span class="ver' + (x.outdated ? " old" : "") + '">' + (x.version ? "v" + esc(x.version) + (x.outdated ? " · veraltet" : "") : "Version unbekannt") + "</span></div>";
    }).join("")
    : '<div class="dir"><span class="hint">Kein installierter Addon-Ordner EventHelperSync gefunden.</span></div>');

  const iv = d.intervals || {};
  const mins = (ms, def) => Math.round((ms || def * 60000) / 60000);
  $("auto-council").textContent = "Council-Daten: alle " + mins(iv.councilMs, 15) + " Minuten und nach jedem Upload";
  $("auto-handouts").textContent = "Ausgabeliste: alle " + mins(iv.handoutsMs, 5) + " Minuten und nach jedem Upload";

  const up = $("act-upload");
  up.disabled = busy.has("upload") || d.uploading || !d.file;
  up.title = d.file ? "Alles aus der Addon-Datei hochladen" : "Keine Addon-Datei gefunden";
  $("act-council").disabled = busy.has("council");
  $("act-handouts").disabled = busy.has("handouts");
  $("btn-test").disabled = busy.has("test");
  $("btn-save").disabled = busy.has("save");
}

function filteredLog() {
  const log = lastState.log || [];
  if (logFilter === "ok") return log.filter((e) => e.level === "ok");
  if (logFilter === "problems") return log.filter((e) => e.level === "warn" || e.level === "error");
  return log;
}

function renderLog() {
  const d = lastState;
  for (const b of document.querySelectorAll(".seg button")) b.setAttribute("aria-pressed", String(b.dataset.arg === logFilter));
  const lines = filteredLog().slice().reverse();
  setHtml($("log"), lines.length
    ? lines.map((e) => '<div class="line ' + esc(e.level) + '"><time>' + hhmmss(e.at) + '</time><span class="ldot"></span><span class="ltext">'
      + esc(e.text) + "</span></div>").join("")
    : '<div class="log-empty">Keine Einträge.</div>');
  const n = (d.log || []).length;
  $("log-count").textContent = n >= (d.logLimit || Infinity)
    ? "Die letzten " + n + " Einträge seit dem Start"
    : plural(n, "Eintrag", "Einträge") + " seit dem Start";
}

function renderSetup() {
  const d = lastState;
  if (!setupEditing) {
    if (!$("su-base").value) $("su-base").value = d.config.baseUrl || "";
    $("su-token").placeholder = d.config.hasToken ? "gespeichert, endet auf …" + d.config.tokenHint : "ehl_…";
  }
  const c = d.candidates[0];
  const found = !!c;
  const dirs = d.addonDirs || [];
  if (found) {
    const installed = dirs.some((x) => x.flavor === c.flavor);
    $("su-wow-title").textContent = "World of Warcraft gefunden";
    $("su-wow-text").textContent = (c.label || c.flavor) + " · Konto " + c.account + " · "
      + (installed ? "Addon EventHelperSync installiert" : "Addon-Ordner EventHelperSync nicht gefunden");
  } else {
    $("su-wow-title").textContent = "World of Warcraft nicht gefunden";
    $("su-wow-text").textContent = "Den WoW-Ordner angeben, z.B. D:\\Games\\World of Warcraft. Das Addon muss im Spiel schon einmal geladen gewesen sein.";
  }
  $("su-other").hidden = !found;
  $("su-other").textContent = setupPathOpen ? "Doch automatisch suchen" : "Anderen Ordner wählen";
  $("su-path").hidden = found && !setupPathOpen;
  if (!found) setupPathOpen = true;
  $("su-connect").disabled = busy.has("connect");
  $("su-connect").textContent = busy.has("connect") ? "Verbinde …" : "Verbinden";
  renderSetupSteps();
}

function renderSetupSteps() {
  if (!lastState) return;
  const hasBase = !!$("su-base").value.trim();
  const hasToken = !!$("su-token").value.trim() || lastState.config.hasToken;
  const found = !!lastState.candidates[0];
  const step = (el, done, active, label) => {
    el.className = "step-no" + (done ? " done" : active ? " active" : "");
    el.innerHTML = done ? SVG.check : label;
  };
  step($("su-no1"), hasBase, true, "1");
  step($("su-no2"), hasToken, hasBase, "2");
  const no3 = $("su-no3");
  no3.className = "step-no " + (found ? "done" : "warn");
  no3.innerHTML = found ? SVG.check : SVG.warn;
}

// Das Fenster auf den Inhalt zuschneiden: feste Breite, Höhe nach Inhalt der
// gerade sichtbaren Ansicht (höchstens 90 % des Bildschirms, darüber scrollt
// es innen). Die Seite muss das selbst tun — --window-size (lib/appWindow.js)
// greift nur, wenn Edge nicht schon läuft. Nachgezogen wird nur, wenn sich die
// Höhe des Inhalts ändert (Ansicht, Reiter, Raid-Liste geladen), damit eine
// eigene Grösse nicht bei jedem 3-s-Poll überschrieben wird. Im normalen
// Browser-Tab (Fallback) ignoriert der Browser resizeTo() ohnehin.
// 760: links die Server-Leiste, rechts eine Raid-Zeile mit Status-Wort und
// Knöpfen, ohne dass die Unterzeile umbricht (Canvas-Variante A).
const APP_WIDTH = 760;
let fittedHeight = 0;
function fitWindow() {
  const v = activeView();
  if (!v) return;
  v.classList.add("measure");
  const content = v.offsetHeight;
  v.classList.remove("measure");
  if (!content || content === fittedHeight) return;
  fittedHeight = content;
  // The own window has no frame around the page; it sizes itself from CSS
  // pixels (DPI-correct, lib/webviewHost.js) instead of window.resizeTo.
  const extraW = HOST ? 0 : window.outerWidth - window.innerWidth;
  const extraH = HOST ? 0 : window.outerHeight - window.innerHeight;
  const height = Math.max(360, Math.min(content + extraH, Math.round(screen.availHeight * 0.9)));
  if (HOST) {
    hostPost({ type: "resize", width: APP_WIDTH, height: height });
    return;
  }
  try {
    window.resizeTo(APP_WIDTH + extraW, height);
  } catch {
    // Nicht erlaubt (normaler Tab) — dann bleibt es, wie es ist.
  }
}

// --- Eigenes Fenster (WebView2) ----------------------------------------------
// In the tool's own window (lib/webviewHost.js, webview-host/Host.cs) there is
// no OS title bar: the header moves the window, the outer 5 px resize it, and
// minimize/close/resize are messages to the window program. In Edge --app or
// a browser tab window.chrome.webview does not exist and none of this runs.
const EDGE_PX = 5;
function edgeAt(x, y) {
  const v = y < EDGE_PX ? "top" : y >= window.innerHeight - EDGE_PX ? "bottom" : "";
  const h = x < EDGE_PX ? "left" : x >= window.innerWidth - EDGE_PX ? "right" : "";
  return v && h ? v + "-" + h : v || h;
}
if (HOST) {
  const root = document.documentElement;
  root.classList.add("in-host");
  let dragFrom = null;
  const setEdge = (edge) => { if ((root.dataset.edge || "") !== edge) root.dataset.edge = edge; };
  document.addEventListener("mousedown", (e) => {
    if (e.button !== 0) return;
    const edge = edgeAt(e.clientX, e.clientY);
    if (edge) {
      e.preventDefault();
      hostPost({ type: "edge", edge: edge });
      return;
    }
    // The header is the title bar, except for its buttons and the filter.
    if (e.target.closest(".hdr") && !e.target.closest("button, a, input, select, textarea, label, [data-act]")) {
      e.preventDefault();
      dragFrom = { x: e.screenX, y: e.screenY };
    }
  });
  document.addEventListener("mousemove", (e) => {
    if (dragFrom && (e.buttons & 1)) {
      // A few pixels first, so a plain click on the header stays a click.
      if (Math.abs(e.screenX - dragFrom.x) + Math.abs(e.screenY - dragFrom.y) > 3) {
        dragFrom = null;
        hostPost({ type: "drag" });
      }
      return;
    }
    dragFrom = null;
    // While a button is down (resizing) the cursor keeps its shape.
    if (!e.buttons) setEdge(edgeAt(e.clientX, e.clientY));
  });
  document.addEventListener("mouseup", () => { dragFrom = null; });
  root.addEventListener("mouseleave", () => setEdge(""));
}

refresh().then(refreshRaids);
schedulePoll();
// Ein fremder Server soll nicht bei jedem der 3-s-Zyklen mit angefragt werden.
setInterval(refreshRaids, 12000);
</script>
</body>
</html>`;
