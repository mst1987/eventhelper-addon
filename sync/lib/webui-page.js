"use strict";

// Die Oberfläche als eine Zeichenkette — kein Build-Schritt, keine Dateien
// daneben, und beim Packen der .exe landet sie automatisch mit im Bündel.
// Kein Framework: eine Raid-Liste und ein Einstellungen-Panel dahinter.
//
// Layout und Farben sind das abgenommene Mockup (dunkles Steinpanel, goldene
// Fassung, rote Buttons für "bereit", grün/gelb für importiert/kein-Loot,
// https://claude.ai/artifact/DXAy1y1wS2i9jX7hQ6d7kF) — kein Browser-Chrome
// mehr sichtbar, weil appWindow.js die Seite als eigenes Fenster öffnet.

module.exports.PAGE = String.raw`<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>EventHelper Loot-Sync</title>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Cinzel:wght@600;700&family=Spectral:wght@400;500;600&display=swap">
<style>
  :root {
    --gold: #d8b567; --gold-dim: #8a6a2c; --cream: #f2dfa8; --parchment: #cabfa8;
    --ready-bg1: #9a2a2a; --ready-bg2: #6b1414; --ready-bg3: #4a0d0d;
    --done-bg1: #2e3a26; --done-bg2: #1c2417; --done-line: #5a7a3e;
    --empty-bg1: #3a3320; --empty-bg2: #241f13; --empty-line: #8a7a2e;
    --err: #ff8a7a; --warn: #e0c25a;
  }
  * { box-sizing: border-box; }
  html, body { height: 100%; }
  body {
    margin: 0; font-family: "Spectral", Georgia, serif; color: var(--parchment);
    background:
      radial-gradient(38% 30% at 12% 8%, rgba(255,205,120,.18), transparent 70%),
      radial-gradient(55% 42% at 6% 96%, rgba(95,125,55,.22), transparent 70%),
      radial-gradient(60% 50% at 100% 55%, rgba(130,70,45,.18), transparent 70%),
      linear-gradient(150deg, #4a3f2e 0%, #241d15 55%, #171209 100%);
  }
  .outline { text-shadow: 0 1px 0 #000, 0 -1px 0 #000, 1px 0 0 #000, -1px 0 0 #000, 0 2px 3px rgba(0,0,0,.5); }

  .frame {
    position: relative; min-height: 100vh; box-sizing: border-box;
    padding: 30px 20px 16px; display: flex; flex-direction: column; gap: 12px;
    box-shadow: inset 0 0 0 2px var(--gold), inset 0 0 0 5px var(--gold-dim), inset 0 0 0 6px #241a0d;
  }

  .ribbon {
    position: absolute; top: -2px; left: 50%; transform: translateX(-50%);
    background: linear-gradient(180deg, #5a1414 0%, #3c0d0d 100%);
    border: 2px solid var(--gold); border-top: none; border-radius: 0 0 6px 6px;
    padding: 6px 24px 5px;
    font-family: "Cinzel", Georgia, serif; font-size: 13px; letter-spacing: .06em; color: var(--cream);
  }
  .titlebtn {
    position: absolute; top: 6px; width: 22px; height: 22px; border-radius: 4px;
    background: linear-gradient(180deg, #4a3f2e 0%, #241d15 100%); border: 1px solid var(--gold-dim);
    color: var(--parchment); font-size: 12px; line-height: 1; cursor: pointer;
  }
  .titlebtn:hover { filter: brightness(1.25); }
  #btn-close { right: 10px; }
  #btn-settings { right: 38px; }

  .banner {
    border: 1px solid var(--err); background: rgba(255,138,122,.12); color: #ffd9d0;
    border-radius: 6px; padding: 9px 12px; font-size: 12.5px; line-height: 1.5;
  }
  .banner code { background: rgba(0,0,0,.3); padding: 1px 5px; border-radius: 4px; }

  .summary { text-align: center; font-size: 12.5px; color: var(--parchment); }
  .summary b { color: var(--cream); }

  .lists { display: flex; flex-direction: column; gap: 16px; flex-grow: 1; }
  .group-label {
    font-family: "Cinzel", Georgia, serif; font-size: 11px; letter-spacing: .1em;
    color: #b6a077; text-shadow: 0 1px 2px rgba(0,0,0,.6); margin: 0 0 8px;
  }
  .group { display: flex; flex-direction: column; gap: 8px; }

  .row {
    border-radius: 4px; padding: 10px 14px; display: flex; align-items: center; gap: 12px;
    box-sizing: border-box; width: 100%; text-align: left; font: inherit; color: inherit; cursor: default;
  }
  .row.ready {
    background: linear-gradient(180deg, var(--ready-bg1) 0%, var(--ready-bg2) 55%, var(--ready-bg3) 100%);
    border: 1px solid var(--gold);
    box-shadow: inset 0 1px 0 rgba(255,190,150,.35), inset 0 -2px 4px rgba(0,0,0,.35), 0 2px 5px rgba(0,0,0,.35);
    cursor: pointer;
  }
  .row.ready:hover { filter: brightness(1.08); }
  .row.ready:active { filter: brightness(.9); }
  .row.ready:disabled { cursor: default; opacity: .6; filter: none; }
  .row.done { background: linear-gradient(180deg, var(--done-bg1) 0%, var(--done-bg2) 100%); border: 1px solid var(--done-line); }
  .row.empty { background: linear-gradient(180deg, var(--empty-bg1) 0%, var(--empty-bg2) 100%); border: 1px solid var(--empty-line); }

  .row .icon { flex: 0 0 auto; width: 16px; height: 16px; }
  .row .info { flex-grow: 1; min-width: 0; }
  .row .name { font-size: 14px; font-weight: 600; }
  .row.ready .name { color: var(--cream); }
  .row.done .name { color: #bcd4a4; }
  .row.empty .name { color: #d9c988; }
  .row .sub { font-size: 11.5px; }
  .row.ready .sub { color: #e3b8a8; }
  .row.done .sub { color: #7fa066; }
  .row.empty .sub { color: #a89550; }

  .dismiss {
    flex: 0 0 auto; width: 22px; height: 22px; border-radius: 4px; line-height: 1;
    background: rgba(0,0,0,.25); border: 1px solid rgba(255,255,255,.25); color: var(--cream);
    font-size: 12px; cursor: pointer;
  }
  .dismiss:hover { background: rgba(0,0,0,.45); }

  .empty-hint { color: #8a8067; font-size: 12.5px; padding: 4px 2px; }

  .pager {
    display: flex; align-items: center; justify-content: center; gap: 12px;
    padding: 2px 2px 0; font-size: 11.5px; color: #a4916a;
  }
  .pager button {
    background: none; border: 1px solid var(--gold-dim); border-radius: 4px;
    color: var(--parchment); font: inherit; font-size: 12px; width: 24px; height: 22px; cursor: pointer;
  }
  .pager button:hover:not(:disabled) { border-color: var(--gold); color: var(--cream); }
  .pager button:disabled { opacity: .35; cursor: default; }

  .upcoming-toggle {
    background: none; border: none; text-align: left; padding: 2px; width: 100%;
    font: inherit; font-size: 11.5px; color: #a4916a; cursor: pointer;
  }
  .upcoming-toggle:hover { color: var(--cream); }

  .footer {
    display: flex; justify-content: space-between; align-items: center;
    font-size: 11px; color: #a4916a; border-top: 1px solid rgba(216,181,103,.2); padding-top: 10px;
  }
  .linklike { background: none; border: none; font: inherit; font-size: 11px; color: #a4916a; cursor: pointer; padding: 0; }
  .linklike:hover { color: var(--cream); }

  .settings-panel {
    background: rgba(10,8,6,.55); border: 1px solid var(--gold-dim); border-radius: 8px;
    padding: 14px 16px; margin-top: 4px; font-family: "Spectral", Georgia, serif;
  }
  .settings-panel h2 {
    font-family: "Cinzel", Georgia, serif; font-size: 12px; letter-spacing: .08em; color: var(--cream);
    margin: 0 0 12px; text-transform: uppercase;
  }
  .settings-panel label { display: block; margin-bottom: 12px; }
  .settings-panel .lbl { display: block; margin-bottom: 4px; font-weight: 600; color: var(--parchment); font-size: 13px; }
  .settings-panel .hint { display: block; margin-top: 4px; color: #8a8067; font-size: 11.5px; }
  .settings-panel input[type=text], .settings-panel input[type=password], .settings-panel input[type=number], .settings-panel select {
    width: 100%; padding: 7px 9px; border-radius: 5px; border: 1px solid var(--gold-dim);
    background: rgba(0,0,0,.3); color: var(--parchment); font: inherit; font-size: 13px;
  }
  .settings-panel input:focus, .settings-panel select:focus { outline: 1px solid var(--gold); outline-offset: -1px; }
  .settings-panel code { background: rgba(0,0,0,.3); padding: 1px 5px; border-radius: 4px; font-size: 11px; }
  .settings-panel .row2 { display: flex; gap: 10px; flex-wrap: wrap; margin-top: 4px; }
  .btn {
    padding: 7px 14px; border-radius: 5px; border: 1px solid var(--gold-dim); font: inherit; font-size: 13px;
    background: linear-gradient(180deg, #4a3f2e 0%, #241d15 100%); color: var(--parchment); cursor: pointer;
  }
  .btn:hover:not(:disabled) { filter: brightness(1.15); }
  .btn:disabled { opacity: .5; cursor: default; }
  .btn.primary { background: linear-gradient(180deg, var(--ready-bg1) 0%, var(--ready-bg3) 100%); border-color: var(--gold); color: var(--cream); }

  #log {
    background: rgba(0,0,0,.3); border-radius: 6px; padding: 8px 10px; margin-top: 12px;
    max-height: 160px; overflow-y: auto; font: 11.5px/1.6 ui-monospace, Consolas, monospace;
  }
  #log div { white-space: pre-wrap; }
  #log .t { color: #8a8067; }
  #log .ok { color: #9fb888; }
  #log .warn { color: var(--warn); }
  #log .error { color: var(--err); }

  #flash {
    position: fixed; left: 50%; bottom: 18px; transform: translateX(-50%); z-index: 10;
  }
  .flash { padding: 8px 14px; border-radius: 6px; font-weight: 600; font-size: 12.5px; box-shadow: 0 4px 12px rgba(0,0,0,.4); }
  .flash.ok { background: #1c2417; border: 1px solid var(--done-line); color: #bcd4a4; }
  .flash.err { background: #3c1414; border: 1px solid var(--err); color: #ffd9d0; }
</style>
</head>
<body>
<div class="frame">
  <div class="ribbon outline">EVENTHELPER&nbsp;SYNC</div>
  <button type="button" class="titlebtn" id="btn-settings" aria-label="Einstellungen" title="Einstellungen">&#9881;</button>
  <button type="button" class="titlebtn" id="btn-close" aria-label="Fenster schliessen" title="Schliessen">&#10005;</button>

  <div id="banner" class="banner" hidden></div>

  <div class="summary" id="summary">&nbsp;</div>

  <div class="lists" id="lists"></div>

  <div class="footer">
    <div id="f-status">–</div>
    <button type="button" class="linklike" id="btn-refresh">&#8635; jetzt prüfen</button>
  </div>

  <div class="settings-panel" id="settings-panel" hidden>
    <h2>Einstellungen</h2>
    <form id="settings">
      <label>
        <span class="lbl">Adresse des EventHelper</span>
        <input type="text" name="baseUrl" placeholder="https://pulse-gdkp.de:3005" autocomplete="off">
        <span class="hint">Mit https:// und Port, ohne /api.</span>
      </label>
      <label>
        <span class="lbl">API-Token</span>
        <input type="password" name="token" placeholder="unverändert lassen" autocomplete="off">
        <span class="hint" id="token-hint"></span>
      </label>
      <label>
        <span class="lbl">Addon-Datei</span>
        <select name="savedVariablesPath" id="sv-select"></select>
        <span class="hint" id="sv-hint">„Automatisch suchen" überlebt eine Neuinstallation von WoW.</span>
      </label>
      <label>
        <span class="lbl">… oder Pfad selbst angeben</span>
        <input type="text" name="manualPath" id="manual-path" autocomplete="off"
               placeholder="D:\Games\World of Warcraft">
        <span class="hint">
          Nötig, wenn WoW oben nicht gefunden wurde. Es genügt der WoW-Ordner — die Datei
          wird darunter gesucht. Ebenso akzeptiert: der <code>_classic_era_</code>-Ordner,
          der Account-Ordner oder direkt die <code>EventHelperSync.lua</code>.
        </span>
      </label>
      <label>
        <span class="lbl">Prüfintervall (Sekunden)</span>
        <input type="number" name="pollSeconds" min="5" max="600">
        <span class="hint">WoW schreibt die Datei nur beim Ausloggen, bei /reload und über den Upload-Knopf im Spiel — öfter als alle paar Sekunden nachzusehen bringt nichts.</span>
      </label>
      <div class="row2">
        <button type="submit" class="btn primary">Speichern</button>
        <button type="button" class="btn" id="btn-upload-all">Alles hochladen</button>
        <button type="button" class="btn" id="btn-test">Verbindung testen</button>
      </div>
    </form>
    <div id="log"></div>
  </div>
</div>
<div id="flash"></div>

<script>
const KEY = new URLSearchParams(location.search).get("key") || "";
const api = (path, opts) => fetch(path + (path.includes("?") ? "&" : "?") + "key=" + encodeURIComponent(KEY), opts)
  .then(async (r) => {
    const body = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(body.error || ("HTTP " + r.status));
    return body;
  });

const $ = (id) => document.getElementById(id);
const esc = (s) => String(s == null ? "" : s).replace(/[<>&]/g, (c) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;" }[c]));
let editing = false;

function flash(text, kind) {
  const div = document.createElement("div");
  div.className = "flash " + kind;
  div.textContent = text;
  $("flash").innerHTML = "";
  $("flash").appendChild(div);
  setTimeout(() => { if ($("flash").firstChild === div) $("flash").innerHTML = ""; }, 5000);
}

function fmtTime(ms) {
  if (!ms) return "–";
  return new Date(ms).toLocaleString("de-DE");
}
function ago(ms) {
  if (!ms) return "noch nie";
  const s = Math.round((Date.now() - ms) / 1000);
  if (s < 60) return "vor " + s + " s";
  if (s < 3600) return "vor " + Math.round(s / 60) + " min";
  return new Date(ms).toLocaleDateString("de-DE");
}
function fmtDay(ms) {
  const d = new Date(ms);
  const wd = ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"][d.getDay()];
  return wd + ", " + d.toLocaleDateString("de-DE");
}
function sourceLabel(gargul, rclc) {
  if (gargul && rclc) return gargul + " Gargul, " + rclc + " RCLC";
  if (gargul) return gargul + " Items (Gargul)";
  return rclc + " Items (RCLootcouncil)";
}

// Die zwei Datenquellen der Liste: der lokale Stand (/api/state, alle 3s) und
// der Raid-Status vom echten Server (/api/raids, seltener — das ist ein
// Aufruf gegen einen fremden Server, den man nicht unnötig oft machen muss).
let lastState = null;
let lastRaids = null;
let raidsError = null;

// Übrige Raids: höchstens PAGE_SIZE vergangene auf einmal (pastPage zählt
// die Seite), kommende bleiben eingeklappt (upcomingExpanded) — beides bleibt
// über einen Refresh hinweg erhalten, damit ein Klick nicht drei Sekunden
// später vom nächsten Poll wieder zugeklappt wird.
const PAGE_SIZE = 10;
let pastPage = 0;
let upcomingExpanded = false;

async function refresh() {
  try {
    lastState = await api("/api/state");
    render();
  } catch (e) {
    $("f-status").textContent = "Oberfläche nicht erreichbar: " + e.message;
  }
}

async function refreshRaids() {
  try {
    const d = await api("/api/raids");
    lastRaids = d.raids || [];
    raidsError = null;
  } catch (e) {
    raidsError = e.message;
  }
  render();
}

async function setExcluded(ids, excluded) {
  try {
    await api("/api/sessions", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ sessionIds: ids, excluded }),
    });
  } catch (e) {
    flash(e.message, "err");
  }
  refresh();
  refreshRaids();
}

async function uploadOne(sessionId, btn) {
  if (btn) btn.disabled = true;
  try {
    const r = await api("/api/upload-one", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ sessionId }),
    });
    flash(r.results.length ? r.results.length + " Ergebnis(se) verarbeitet." : "Nichts zu tun.", "ok");
  } catch (e) {
    flash(e.message, "err");
  }
  refresh();
  refreshRaids();
}

function rowButton(className, contents, onClick) {
  const btn = document.createElement("button");
  btn.type = "button";
  btn.className = "row " + className;
  btn.innerHTML = contents;
  if (onClick) btn.addEventListener("click", onClick);
  return btn;
}

function rowDiv(className, contents) {
  const div = document.createElement("div");
  div.className = "row " + className;
  div.innerHTML = contents;
  return div;
}

// Raids vom Server + lokale Sessions zu drei Gruppen zusammenführen:
//   1. Bereit zum Hochladen  — der Server kennt den Raid und eine lokale
//      Session passt dazu (Datumsabgleich serverseitig, siehe lib/uploader.js).
//   2. Ohne bekannten Termin — eine lokale Session, die zu keinem Raid der
//      letzten Wochen passt (z.B. Pug-Abend). Trotzdem hochladbar: landet im
//      Menü als unzugeordnete Inbox-Session, wie eh schon immer.
//   3. Übrige Raids — grün (schon importiert) oder gelb (kein Loot gefunden).
function buildGroups() {
  const sessions = (lastState && lastState.sessions) || [];
  const raids = lastRaids || [];
  const matchedIds = new Set(raids.filter((r) => r.matchedSessionId).map((r) => r.matchedSessionId));

  const ready = raids.filter((r) => r.status === "ready");
  const rest = raids.filter((r) => r.status !== "ready");
  const unmatched = sessions.filter((s) => (
    !s.excluded && s.items > 0 && !s.lastUpload && !matchedIds.has(s.sessionId)
  ));

  // Kommende Raids können noch kein Loot haben — die stehen sonst nur im Weg,
  // wenn man sieht will, welche vergangenen Abende noch offen sind. Bleiben
  // ausgeblendet, sind aber über den Umschalter unten jederzeit einblendbar.
  const now = Date.now();
  const pastRest = rest.filter((r) => r.startTime * 1000 <= now);
  const upcomingRest = rest.filter((r) => r.startTime * 1000 > now)
    .sort((a, b) => a.startTime - b.startTime);

  return { ready, unmatched, pastRest, upcomingRest };
}

// Ein bereiter Eintrag ist immer ein Klick-Button (l\u00e4dt genau diese Session
// hoch) plus ein kleines Abwahl-Kreuz daneben \u2014 egal ob der Server ihn einem
// Raid zuordnen konnte oder nicht. Ohne das Kreuz g\u00e4be es f\u00fcr eine bereits
// zugeordnete Zeile keine M\u00f6glichkeit mehr, sie doch nicht zu senden (die alte
// Tabelle konnte jede Session abw\u00e4hlen, das darf hier nicht verlorengehen).
function readyRow(sessionId, innerHtml) {
  const btn = rowButton("ready", innerHtml, () => uploadOne(sessionId, btn));
  btn.style.flexGrow = "1";

  const dismiss = document.createElement("button");
  dismiss.type = "button";
  dismiss.className = "dismiss";
  dismiss.title = "Diesen Abend nicht hochladen";
  dismiss.setAttribute("aria-label", "Diesen Abend nicht hochladen");
  dismiss.textContent = "\u2715";
  dismiss.addEventListener("click", (ev) => { ev.stopPropagation(); setExcluded([sessionId], true); });

  const wrap = document.createElement("div");
  wrap.style.display = "flex";
  wrap.style.gap = "8px";
  wrap.style.alignItems = "stretch";
  wrap.append(btn, dismiss);
  return wrap;
}

function renderReadyRow(r) {
  return readyRow(r.matchedSessionId,
    '<svg class="icon" viewBox="0 0 24 24" fill="none" stroke="#f5e6c8" stroke-width="2.2"><path d="M12 19V5M5 12l7-7 7 7"/></svg>'
    + '<div class="info"><div class="name outline">' + esc(r.title) + '</div>'
    + '<div class="sub">' + fmtDay(r.startTime * 1000) + " &middot; " + sourceLabel(r.gargul, r.rclc) + "</div></div>");
}

function renderUnmatchedRow(s) {
  return readyRow(s.sessionId,
    '<svg class="icon" viewBox="0 0 24 24" fill="none" stroke="#f5e6c8" stroke-width="2.2"><path d="M12 19V5M5 12l7-7 7 7"/></svg>'
    + '<div class="info"><div class="name outline">' + esc(s.instance || "Unbekannter Raid") + '</div>'
    + '<div class="sub">' + fmtDay(s.startedAt) + " &middot; " + sourceLabel(s.gargul, s.rclc) + " &middot; kein Termin gefunden</div></div>");
}

function renderRestRow(r) {
  const isDone = r.status === "done";
  const icon = isDone
    ? '<svg class="icon" viewBox="0 0 24 24" fill="none" stroke="#7fc463" stroke-width="2.4"><path d="M4 12l5 5L20 6"/></svg>'
    : '<svg class="icon" viewBox="0 0 24 24" fill="none" stroke="#d4c05a" stroke-width="2.4"><path d="M6 12h12"/></svg>';
  return rowDiv(isDone ? "done" : "empty",
    icon + '<div class="info"><div class="name">' + esc(r.title) + '</div>'
    + '<div class="sub">' + fmtDay(r.startTime * 1000) + " &middot; " + (isDone ? "Importiert" : "Kein Loot gefunden") + "</div></div>");
}

function render() {
  if (!lastState) return;
  const d = lastState;

  // Fehlerbanner statt eigener Status-Card: nur sichtbar, wenn tatsächlich
  // etwas fehlt oder schiefgeht — sonst nur die Liste.
  const problems = [];
  if (!d.config.baseUrl || !d.config.hasToken) {
    problems.push("Noch nicht eingerichtet — Adresse und Token unten unter Einstellungen eintragen.");
  }
  if (!d.file) {
    const roots = d.searchedRoots || [];
    problems.push(
      "Keine EventHelperSync.lua gefunden. Ist das Addon installiert und war im Spiel schon einmal geladen? "
      + "Falls ja, den WoW-Ordner unten unter „Pfad selbst angeben\" eintragen."
      + (roots.length ? "<br>Durchsucht: " + roots.map((r) => "<code>" + esc(r) + "</code>").join(", ") : ""),
    );
  } else if (d.readError) {
    problems.push("Addon-Datei nicht lesbar: " + esc(d.readError));
  } else if (d.envelopeMissing) {
    problems.push("Die Addon-Datei enthält noch keinen Export. Im Spiel den Upload-Knopf drücken (oder /ehs upload).");
  }
  if (d.lastError) problems.push("Letzter Fehler: " + esc(d.lastError.message));
  if (raidsError) problems.push("Raid-Liste vom Server: " + esc(raidsError));

  if (problems.length) {
    $("banner").innerHTML = problems.join("<br>");
    $("banner").hidden = false;
  } else {
    $("banner").hidden = true;
  }

  const { ready, unmatched, pastRest, upcomingRest } = buildGroups();
  const readyCount = ready.length + unmatched.length;
  const openCount = readyCount + pastRest.filter((r) => r.status === "empty").length;
  $("summary").innerHTML = lastRaids === null
    ? "Raid-Liste wird geladen …"
    : "<b>" + readyCount + "</b> bereit zum Hochladen &middot; " + openCount + " insgesamt offen";

  const lists = $("lists");
  lists.innerHTML = "";
  if (readyCount) {
    const group = document.createElement("div");
    group.className = "group";
    group.innerHTML = '<div class="group-label">BEREIT&nbsp;ZUM&nbsp;HOCHLADEN</div>';
    for (const r of ready) group.appendChild(renderReadyRow(r));
    for (const s of unmatched) group.appendChild(renderUnmatchedRow(s));
    lists.appendChild(group);
  }
  if (pastRest.length || upcomingRest.length) {
    const group = document.createElement("div");
    group.className = "group";
    group.innerHTML = '<div class="group-label">ÜBRIGE&nbsp;RAIDS</div>';

    // Nicht mehr als PAGE_SIZE vergangene Raids auf einmal — ein Konto mit
    // langer Historie würde die Liste sonst endlos lang machen. pastPage
    // bleibt über Refreshes hinweg erhalten, wird aber bei jedem Rendern auf
    // die aktuell gültige Seitenzahl eingeklemmt (die Liste kann schrumpfen,
    // sobald ein Raid importiert oder gesendet wurde).
    const totalPages = Math.max(1, Math.ceil(pastRest.length / PAGE_SIZE));
    pastPage = Math.min(pastPage, totalPages - 1);
    const from = pastPage * PAGE_SIZE;
    for (const r of pastRest.slice(from, from + PAGE_SIZE)) group.appendChild(renderRestRow(r));

    if (pastRest.length > PAGE_SIZE) {
      const pager = document.createElement("div");
      pager.className = "pager";
      const prev = document.createElement("button");
      prev.type = "button";
      prev.textContent = "◀";
      prev.setAttribute("aria-label", "Vorherige Seite");
      prev.disabled = pastPage === 0;
      prev.addEventListener("click", () => { pastPage -= 1; render(); });
      const info = document.createElement("span");
      info.textContent = "Seite " + (pastPage + 1) + " / " + totalPages;
      const next = document.createElement("button");
      next.type = "button";
      next.textContent = "▶";
      next.setAttribute("aria-label", "Nächste Seite");
      next.disabled = pastPage >= totalPages - 1;
      next.addEventListener("click", () => { pastPage += 1; render(); });
      pager.append(prev, info, next);
      group.appendChild(pager);
    }

    if (upcomingRest.length) {
      const toggle = document.createElement("button");
      toggle.type = "button";
      toggle.className = "upcoming-toggle";
      toggle.textContent = (upcomingExpanded ? "▾ " : "▸ ")
        + upcomingRest.length + " kommende" + (upcomingRest.length === 1 ? "r Raid" : " Raids")
        + (upcomingExpanded ? " ausblenden" : " einblenden");
      toggle.addEventListener("click", () => { upcomingExpanded = !upcomingExpanded; render(); });
      group.appendChild(toggle);
      if (upcomingExpanded) {
        for (const r of upcomingRest) group.appendChild(renderRestRow(r));
      }
    }

    lists.appendChild(group);
  }
  if (!readyCount && !pastRest.length && !upcomingRest.length && lastRaids !== null) {
    lists.innerHTML = '<div class="empty-hint">Keine Raid-Termine der letzten Wochen gefunden.</div>';
  }

  $("f-status").textContent = d.file
    ? "Zuletzt geprüft " + ago(d.lastCheck)
    : "Warte auf die Addon-Datei …";

  // Einstellungen — nur füllen, solange niemand darin tippt.
  if (!editing) {
    const f = $("settings");
    f.baseUrl.value = d.config.baseUrl || "";
    f.pollSeconds.value = d.config.pollSeconds || 15;
    $("token-hint").textContent = d.config.hasToken
      ? "Gespeichert (endet auf …" + d.config.tokenHint + "). Leer lassen, um ihn zu behalten."
      : "Steht im Admin-Menü unter Einstellungen → Loot-Sync. Wird dort genau einmal angezeigt.";

    const sel = $("sv-select");
    sel.innerHTML = "";
    const auto = document.createElement("option");
    auto.value = "";
    auto.textContent = "Automatisch suchen";
    sel.appendChild(auto);
    for (const c of d.candidates) {
      const o = document.createElement("option");
      o.value = c.path;
      o.textContent = c.flavor + " / " + c.account;
      sel.appendChild(o);
    }
    if (d.config.savedVariablesPath && !d.candidates.some((c) => c.path === d.config.savedVariablesPath)) {
      const o = document.createElement("option");
      o.value = d.config.savedVariablesPath;
      o.textContent = d.config.savedVariablesPath;
      sel.appendChild(o);
    }
    sel.value = d.config.savedVariablesPath || "";
    $("sv-hint").textContent = d.candidates.length
      ? "„Automatisch suchen\" überlebt eine Neuinstallation von WoW."
      : "Keine WoW-Installation gefunden — bitte den Pfad unten selbst angeben.";
  }

  $("btn-upload-all").disabled = d.uploading || !d.file;
  $("btn-upload-all").textContent = d.uploading ? "Lädt hoch …" : "Alles hochladen";

  // Verlauf
  const log = $("log");
  const atBottom = log.scrollTop + log.clientHeight >= log.scrollHeight - 20;
  log.innerHTML = "";
  for (const e of d.log) {
    const div = document.createElement("div");
    const t = document.createElement("span");
    t.className = "t";
    t.textContent = new Date(e.at).toLocaleTimeString("de-DE") + "  ";
    const s = document.createElement("span");
    s.className = e.level;
    s.textContent = e.text;
    div.append(t, s);
    log.appendChild(div);
  }
  if (atBottom) log.scrollTop = log.scrollHeight;
}

$("btn-settings").addEventListener("click", () => {
  $("settings-panel").hidden = !$("settings-panel").hidden;
});
$("btn-close").addEventListener("click", async () => {
  // Beendet den ganzen Sync-Tool im Hintergrund (die Konsole ist ja
  // versteckt) und schliesst danach dieses Fenster — in dieser Reihenfolge,
  // sonst käme die Anfrage nie an.
  try { await api("/api/quit", { method: "POST" }); } catch { /* egal, Fenster geht trotzdem zu */ }
  window.close();
});
$("btn-refresh").addEventListener("click", () => { refresh(); refreshRaids(); });

$("settings").addEventListener("input", () => { editing = true; });
$("settings").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  const f = ev.target;
  try {
    await api("/api/settings", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        baseUrl: f.baseUrl.value.trim(),
        token: f.token.value,
        savedVariablesPath: f.savedVariablesPath.value,
        manualPath: f.manualPath.value.trim(),
        pollSeconds: Number(f.pollSeconds.value),
      }),
    });
    f.token.value = "";
    f.manualPath.value = "";
    editing = false;
    flash("Gespeichert.", "ok");
    refresh();
    refreshRaids();
  } catch (e) {
    flash(e.message, "err");
  }
});

$("btn-upload-all").addEventListener("click", async () => {
  $("btn-upload-all").disabled = true;
  try {
    const r = await api("/api/upload", { method: "POST" });
    flash(r.results.length ? r.results.length + " Session(s) verarbeitet." : "Nichts hochzuladen.", "ok");
  } catch (e) {
    flash(e.message, "err");
  }
  refresh();
  refreshRaids();
});

$("btn-test").addEventListener("click", async () => {
  try {
    await api("/api/test", { method: "POST" });
    flash("Server erreichbar, Token gültig.", "ok");
  } catch (e) {
    flash(e.message, "err");
  }
});

refresh();
refreshRaids();
setInterval(refresh, 3000);
// Ein fremder Server soll nicht bei jedem der 3s-Zyklen mit angefragt werden.
setInterval(refreshRaids, 12000);
</script>
</body>
</html>`;
