"use strict";

// Die Oberfläche als eine Zeichenkette — kein Build-Schritt, keine Dateien
// daneben, und beim Packen der .exe landet sie automatisch mit im Bündel.
// Kein Framework: die Seite zeigt eine Handvoll Werte und ein Formular.

module.exports.PAGE = String.raw`<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>EventHelper Loot-Sync</title>
<style>
  :root {
    --bg: #12131a; --panel: #1a1c26; --panel2: #21243040; --line: #2b2f3d;
    --text: #e6e8f0; --dim: #9aa0b4; --accent: #7c6cff; --accent2: #35d6d0;
    --ok: #3ecf7e; --warn: #ffc94d; --err: #ff6b6b;
  }
  @media (prefers-color-scheme: light) {
    :root {
      --bg: #f4f5fa; --panel: #ffffff; --panel2: #f0f1f7; --line: #e0e2ec;
      --text: #1a1c26; --dim: #616780; --accent: #5b46e5; --accent2: #10a8a2;
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; background: var(--bg); color: var(--text);
    font: 14px/1.5 "Segoe UI", system-ui, sans-serif;
  }
  .wrap { max-width: 900px; margin: 0 auto; padding: 24px 18px 60px; }
  header { display: flex; align-items: baseline; gap: 12px; margin-bottom: 4px; }
  h1 { font-size: 20px; margin: 0; letter-spacing: .2px; }
  .ver { color: var(--dim); font-size: 12px; }
  .sub { color: var(--dim); font-size: 13px; margin: 0 0 20px; }

  .card {
    background: var(--panel); border: 1px solid var(--line);
    border-radius: 10px; padding: 16px 18px; margin-bottom: 16px;
  }
  .card h2 {
    font-size: 13px; text-transform: uppercase; letter-spacing: .8px;
    color: var(--dim); margin: 0 0 12px; font-weight: 600;
  }

  .grid { display: grid; grid-template-columns: 150px 1fr; gap: 8px 14px; }
  .grid dt { color: var(--dim); }
  .grid dd { margin: 0; word-break: break-all; }

  .pill {
    display: inline-block; padding: 1px 9px; border-radius: 99px;
    font-size: 12px; font-weight: 600;
  }
  .pill.ok   { background: color-mix(in srgb, var(--ok) 18%, transparent);   color: var(--ok); }
  .pill.warn { background: color-mix(in srgb, var(--warn) 18%, transparent); color: var(--warn); }
  .pill.err  { background: color-mix(in srgb, var(--err) 18%, transparent);  color: var(--err); }
  .pill.dim  { background: var(--panel2); color: var(--dim); }

  table { width: 100%; border-collapse: collapse; }
  th, td { text-align: left; padding: 7px 10px; border-bottom: 1px solid var(--line); }
  th { color: var(--dim); font-weight: 600; font-size: 12px; text-transform: uppercase; letter-spacing: .5px; }
  tr:last-child td { border-bottom: none; }
  td.num, th.num { text-align: right; }
  .tablewrap { overflow-x: auto; }

  label { display: block; margin-bottom: 14px; }
  label .lbl { display: block; margin-bottom: 4px; font-weight: 600; }
  label .hint { display: block; margin-top: 4px; color: var(--dim); font-size: 12px; }
  input[type=text], input[type=password], input[type=number], select {
    width: 100%; padding: 8px 10px; border-radius: 7px;
    border: 1px solid var(--line); background: var(--panel2); color: var(--text);
    font: inherit;
  }
  input:focus, select:focus { outline: 2px solid var(--accent); outline-offset: -1px; }

  .row { display: flex; gap: 10px; flex-wrap: wrap; margin-top: 4px; }
  button {
    padding: 8px 16px; border-radius: 7px; border: 1px solid transparent;
    background: var(--accent); color: #fff; font: inherit; font-weight: 600;
    cursor: pointer;
  }
  button.ghost { background: transparent; border-color: var(--line); color: var(--text); }
  button:disabled { opacity: .5; cursor: default; }
  button:hover:not(:disabled) { filter: brightness(1.12); }

  #log {
    background: var(--panel2); border-radius: 8px; padding: 10px 12px;
    max-height: 260px; overflow-y: auto;
    font: 12px/1.6 ui-monospace, Consolas, monospace;
  }
  #log div { white-space: pre-wrap; }
  #log .t { color: var(--dim); }
  #log .ok { color: var(--ok); }
  #log .warn { color: var(--warn); }
  #log .error { color: var(--err); }

  .flash { padding: 9px 12px; border-radius: 7px; margin-bottom: 12px; font-weight: 600; }
  .flash.ok  { background: color-mix(in srgb, var(--ok) 15%, transparent);  color: var(--ok); }
  .flash.err { background: color-mix(in srgb, var(--err) 15%, transparent); color: var(--err); }
  .empty { color: var(--dim); padding: 6px 0; }
  .muted { color: var(--dim); font-size: 12px; }
  code {
    font: 12px ui-monospace, Consolas, monospace;
    background: var(--panel2); padding: 1px 5px; border-radius: 4px;
  }
</style>
</head>
<body>
<div class="wrap">
  <header>
    <h1>EventHelper Loot-Sync</h1>
    <span class="ver" id="version"></span>
  </header>
  <p class="sub">Läuft im Hintergrund und lädt den Loot hoch, sobald WoW ihn geschrieben hat. Dieses Fenster darf zu.</p>

  <div id="flash"></div>

  <div class="card">
    <h2>Status</h2>
    <dl class="grid">
      <dt>Verbindung</dt>      <dd id="s-conn">–</dd>
      <dt>Server</dt>          <dd id="s-server">–</dd>
      <dt>Addon-Datei</dt>     <dd id="s-file">–</dd>
      <dt>Zuletzt geprüft</dt> <dd id="s-check">–</dd>
      <dt>Letzter Upload</dt>  <dd id="s-upload">–</dd>
    </dl>
    <div class="row">
      <button id="btn-upload">Jetzt hochladen</button>
      <button id="btn-test" class="ghost">Verbindung testen</button>
    </div>
  </div>

  <div class="card">
    <h2>Was in der Datei steht</h2>
    <div class="tablewrap">
      <table id="sessions">
        <thead><tr><th>Datum</th><th>Zeit</th><th>Instanz</th><th class="num">Items</th></tr></thead>
        <tbody></tbody>
      </table>
    </div>
    <div class="empty" id="sessions-empty" hidden></div>
  </div>

  <div class="card">
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
      <div class="row">
        <button type="submit">Speichern</button>
      </div>
    </form>
  </div>

  <div class="card">
    <h2>Verlauf</h2>
    <div id="log"></div>
  </div>
</div>

<script>
const KEY = new URLSearchParams(location.search).get("key") || "";
const api = (path, opts) => fetch(path + (path.includes("?") ? "&" : "?") + "key=" + encodeURIComponent(KEY), opts)
  .then(async (r) => {
    const body = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(body.error || ("HTTP " + r.status));
    return body;
  });

const $ = (id) => document.getElementById(id);
let editing = false;

function flash(text, kind) {
  $("flash").innerHTML = '<div class="flash ' + kind + '"></div>';
  $("flash").firstChild.textContent = text;
  setTimeout(() => { $("flash").innerHTML = ""; }, 6000);
}

function fmtTime(ms) {
  if (!ms) return "–";
  return new Date(ms).toLocaleString("de-DE");
}
function ago(ms) {
  if (!ms) return "–";
  const s = Math.round((Date.now() - ms) / 1000);
  if (s < 60) return "vor " + s + " s";
  if (s < 3600) return "vor " + Math.round(s / 60) + " min";
  return fmtTime(ms);
}
function pill(text, kind) {
  return '<span class="pill ' + kind + '">' + text + "</span>";
}

function render(d) {
  $("version").textContent = "v" + d.version;

  // Verbindung
  if (!d.config.baseUrl || !d.config.hasToken) {
    $("s-conn").innerHTML = pill("nicht eingerichtet", "warn");
  } else if (d.lastError) {
    $("s-conn").innerHTML = pill("Fehler", "err") + " " + d.lastError.message;
  } else if (d.lastUpload) {
    $("s-conn").innerHTML = pill("verbunden", "ok");
  } else {
    $("s-conn").innerHTML = pill("noch nichts gesendet", "dim");
  }

  $("s-server").textContent = d.config.baseUrl || "– nicht gesetzt –";

  if (!d.file) {
    // "Nicht gefunden" ohne "wo wurde gesucht" ist eine Sackgasse — mit der
    // Liste sieht man sofort, ob der eigene WoW-Ordner überhaupt dabei war.
    const roots = d.searchedRoots || [];
    const list = roots.length
      ? "<br><span class=\"muted\">Durchsucht wurden:</span><br>" +
        roots.map((r) => "<code>" + r.replace(/[<>&]/g, "") + "</code>").join("<br>")
      : "";
    $("s-file").innerHTML = pill("nicht gefunden", "err")
      + " Ist das Addon installiert und war im Spiel schon einmal geladen? "
      + "Falls ja: den WoW-Ordner unten unter „Pfad selbst angeben\" eintragen."
      + list;
  } else if (d.readError) {
    $("s-file").innerHTML = pill("nicht lesbar", "err") + " " + d.readError;
  } else if (d.envelopeMissing) {
    $("s-file").innerHTML = pill("noch kein Export", "warn")
      + " Im Spiel den Upload-Knopf drücken oder /reload.";
  } else {
    $("s-file").textContent = d.file + "  (geschrieben " + fmtTime(d.fileMtime) + ")";
  }

  $("s-check").textContent = ago(d.lastCheck);

  if (d.lastUpload) {
    const rs = d.lastUpload.results;
    $("s-upload").textContent = ago(d.lastUpload.at)
      + (rs.length ? " — " + rs.length + " Session(s)" : " — nichts zu tun");
  } else {
    $("s-upload").textContent = "–";
  }

  $("btn-upload").disabled = d.uploading || !d.file;
  $("btn-upload").textContent = d.uploading ? "Lädt hoch …" : "Jetzt hochladen";

  // Sessions
  const tbody = document.querySelector("#sessions tbody");
  tbody.innerHTML = "";
  if (!d.sessions.length) {
    $("sessions").hidden = true;
    $("sessions-empty").hidden = false;
    $("sessions-empty").textContent = d.file
      ? "Keine Raid-Abende in der Datei. Im Spiel unter /ehs prüfen, ob etwas gefunden wird."
      : "Noch keine Datei gefunden.";
  } else {
    $("sessions").hidden = false;
    $("sessions-empty").hidden = true;
    for (const s of d.sessions) {
      const tr = document.createElement("tr");
      const day = new Date(s.startedAt).toLocaleDateString("de-DE");
      const from = new Date(s.startedAt).toLocaleTimeString("de-DE", { hour: "2-digit", minute: "2-digit" });
      const to = new Date(s.endedAt).toLocaleTimeString("de-DE", { hour: "2-digit", minute: "2-digit" });
      for (const v of [day, from + "–" + to, s.instance || "unbekannt"]) {
        const td = document.createElement("td");
        td.textContent = v;
        tr.appendChild(td);
      }
      const td = document.createElement("td");
      td.className = "num";
      td.textContent = s.items;
      tr.appendChild(td);
      tbody.appendChild(tr);
    }
  }

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

async function refresh() {
  try {
    render(await api("/api/state"));
  } catch (e) {
    $("s-conn").textContent = "Oberfläche nicht erreichbar: " + e.message;
  }
}

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
    // Der eingetippte Pfad ist nach dem Speichern in der Auswahl oben gelandet.
    f.manualPath.value = "";
    editing = false;
    flash("Gespeichert.", "ok");
    refresh();
  } catch (e) {
    flash(e.message, "err");
  }
});

$("btn-upload").addEventListener("click", async () => {
  $("btn-upload").disabled = true;
  try {
    const r = await api("/api/upload", { method: "POST" });
    flash(r.results.length ? r.results.length + " Session(s) verarbeitet." : "Nichts hochzuladen.", "ok");
  } catch (e) {
    flash(e.message, "err");
  }
  refresh();
});

$("btn-test").addEventListener("click", async () => {
  try {
    await api("/api/test", { method: "POST" });
    flash("Server erreichbar, Token gültig.", "ok");
  } catch (e) {
    flash(e.message, "err");
  }
  refresh();
});

refresh();
setInterval(refresh, 3000);
</script>
</body>
</html>`;
