# EventHelper Sync

Bringt den vergebenen Raid-Loot aus **RCLootcouncil** und **Gargul** automatisch in den EventHelper-Bot — ohne nach dem Raid zwei Export-Dialoge durchzuklicken und zwei Formate von Hand einzufügen.

Das Repo enthält zwei Teile:

| Ordner | Was es ist | Wo es läuft |
|---|---|---|
| [`addon/`](addon/) | WoW-Addon (Lua) | im Spiel |
| [`sync/`](sync/) | Sync-Tool (Node.js) | auf dem PC des Raidleaders |

---

## Warum zwei Teile?

**Ein WoW-Addon kann nicht ins Netz.** Blizzards Lua-Sandbox hat keine Sockets, kein HTTP und keinen Dateizugriff ausserhalb der eigenen SavedVariables. Ein Addon allein kann also prinzipiell nichts hochladen. Die Kette sieht deshalb so aus:

```
   im Spiel                          auf dem PC                    Server
   ────────                          ──────────                    ──────
RCLootCouncilLootDB ─┐
                     ├─► EventHelper Sync ─► SavedVariables ─► Sync-Tool ─► POST /api/ingest/loot
GargulDB.AwardHistory┘      (Addon)            (Datei)          (Node)              │
                                                                                    ▼
                                                                          Historie & Loot
                                                                           → Addon-Inbox
                                                                           → 1× bestätigen
```

Was das Addon dabei liefert, das ein normaler Export **nicht** kann:

- **Beide Addons in einem Rutsch.** Wer mit RCLootcouncil arbeitet und nebenbei per Gargul verteilt, bekommt sonst zwei Exporte in zwei Formaten.
- **Eine echte Uhrzeit für Gargul-Loot.** Garguls CSV-Export enthält nur ein Datum. Der Zeitstempel liegt in `GargulDB.AwardHistory[…].timestamp` — das Addon liest ihn direkt und macht damit die automatische Zuordnung zum richtigen Raid-Abend überhaupt erst zuverlässig.
- **Die Instanz für Gargul-Loot.** Gargul speichert nicht, wo ein Item gefallen ist. Das Addon schreibt beim Betreten einer Raid-Instanz eine Zeile mit und beschriftet die Session damit.
- **Raid-Abende statt eines Klumpens.** Der Loot wird über die Zeitstempel in Sessions gebündelt, damit jeder Raid-Abend seinem eigenen Raid-Helper-Event zugeordnet werden kann. Der Name des Abends kommt von der **häufigsten** Instanz seiner Items, nicht von der ersten — sonst gibt ein Zwei-Item-Abstecher nach Gruul einem ganzen SSC-Abend seinen Namen. Fanden zwei Raids in einem Abend statt, heisst er „SSC + Tempest Keep".
- **Bank- und Entzauber-Items bleiben draussen** (siehe unten).

Doppelt importiert wird dabei nichts: Jede Zeile behält die ID ihres Ursprungs-Addons (RCLootcouncils `id`, Garguls `checksum`), und der EventHelper dedupliziert darüber. Ein Upload über dieses Addon und ein von Hand eingefügter Export derselben Vergabe fallen zu einem Item zusammen.

---

## Installation

### 1. Addon

Den Ordner `addon/EventHelperSync` nach

```
<WoW>/<Variante>/Interface/AddOns/EventHelperSync
```

kopieren. `<Variante>` ist der Ordner deines Clients — bei den **TBC-Anniversary-Realms `_anniversary_`**, sonst `_classic_era_`, `_classic_` oder `_retail_`. Danach im Spiel einloggen und einmal `/reload` ausführen.

> Das Sync-Tool sucht die Varianten selbst und erkennt auch künftige Ordner, die Blizzard anlegt — es muss also nicht wissen, welcher es bei dir ist.

Prüfen, ob es etwas sieht:

```
/ehs
```

Die Ausgabe nennt beide Quellen und die gefundenen Raid-Sessions:

```
[EventHelper] 2 Raid-Session(s), 5 Item(s) exportbereit.
[EventHelper] Quellen: RCLootcouncil gefunden, Gargul gefunden.
[EventHelper]  · 20.07.2026 21:03 — Serpentshrine Cavern, 3 Item(s)
[EventHelper]  · 21.07.2026 20:40 — Tempest Keep, 2 Item(s)
```

### Das Fenster im Spiel

Der Knopf an der **Minimap** öffnet es — oder `/ehs`. Es beantwortet auf einen Blick, was sonst niemand sieht:

```
 ┌─ EventHelper Sync ───────────────────────────────────────────┐
 │ Quellen:  RCLootcouncil gefunden    Gargul gefunden          │
 │                                                              │
 │ 2 Raid-Abende, 5 Items exportbereit.                         │
 │ 5 Item(s) liegen noch nicht auf der Platte.                  │
 │                                                              │
 │ [ Jetzt speichern (5) ]   [ Export anzeigen ]                │
 │                                                              │
 │ Gefundene Raid-Abende                                        │
 │ Häkchen weg = dieser Abend wird nicht hochgeladen.           │
 │ ┌──────────────────────────────────────────────────────────┐ │
 │ │ ☑ 02.08.2026  20:40–21:10  Tempest Keep        2 Item(s) │ │
 │ │ ☐ 01.08.2026  21:03–22:03  Serpentshrine C.    3 Item(s) │ │
 │ └──────────────────────────────────────────────────────────┘ │
 │                                                              │
 │ Einstellungen                                                │
 │ Zeitraum (Tage)          [ 21 ]                              │
 │ Neuer Abend ab (Std.)    [  6 ]                              │
 │ ☑ Upload-Knopf anzeigen                                      │
 │ ☑ Minimap-Knopf anzeigen                                     │
 │ ☑ Bank- und Entzauber-Items weglassen                        │
 │    Zuletzt 574 Item(s) übersprungen (486 RCLC, 88 Gargul).   │
 └──────────────────────────────────────────────────────────────┘
```

**Bank und Entzaubern fliegen raus.** Items, die gar nicht an einen Raider gingen, gehören nicht in die Loot-Historie. Erkannt wird das nicht am Antworttext — den benennt jede Gilde anders — sondern an dem, was die Addons selbst dazu sagen:

| Addon | Kennzeichen |
|---|---|
| RCLootcouncil | `isAwardReason` — genau das setzt es bei „Banking", „Disenchant" und jedem anderen Award-Reason |
| Gargul | der Pseudo-Empfänger `\|\|de\|\|`, den es für entzauberte Items einträgt |

Ein normaler Wurf mit der Antwort „PvP/Bank" bleibt dabei drin — der ging ja an einen Spieler.

**Abwählen, was nicht interessiert.** Der Pug vom Dienstag, die Runde mit Freunden — Häkchen weg, und der Abend wird nicht hochgeladen. Die Auswahl wird gespeichert und gilt dauerhaft. Abgewählte Abende bleiben sichtbar, nur blass: man muss sie ja wiederfinden können, um sie zurückzuholen.

**Der Minimap-Knopf** zeigt schon von aussen, ob etwas ansteht — goldener Ring heisst ungespeicherter Loot. Linksklick öffnet das Fenster, Rechtsklick speichert sofort, Ziehen verschiebt ihn um die Minimap.

**Befehle**

| Befehl | Wirkung |
|---|---|
| `/ehs` | das Fenster öffnen |
| `/ehs upload` | jetzt speichern, statt auszuloggen (lädt die UI neu) |
| `/ehs status` | dasselbe kurz im Chat |
| `/ehs diag` | **findet er nichts? Das hier sagt, woran es liegt** |
| `/ehs minimap` | Minimap-Knopf ein-/ausblenden |
| `/ehs button` | Upload-Knopf ein-/ausblenden |
| `/ehs export` | Export als JSON in einer Kopierbox (Weg ohne Sync-Tool) |
| `/ehs days <n>` | wie viele Tage zurück exportiert werden (Standard: 21) |
| `/ehs debug` | Debug-Ausgaben umschalten |

### Der Upload-Knopf

Sobald Loot vergeben wurde, der noch nicht auf der Platte liegt, erscheint ein verschiebbarer Knopf **„Loot hochladen (n)"**. Ein Klick speichert und lädt die UI neu — danach holt das Sync-Tool die Daten binnen Sekunden ab. Kein Ausloggen nötig.

Der Knopf verschwindet wieder, sobald nichts mehr offen ist, und ist im Kampf gesperrt (ein Reload mitten im Bosskill wäre schlecht). Wer ihn gar nicht sehen will: `/ehs button`, dann tut es `/ehs upload`.

> **Warum ein Knopf und keine Automatik?**
> WoW schreibt SavedVariables nur beim Ausloggen oder bei einem Reload — [eine API, die das Schreiben erzwingt, gibt es nicht](https://warcraft.wiki.gg/wiki/Saving_variables_between_game_sessions). Ein Reload ließe sich auslösen, aber [`ReloadUI()` ist von Blizzard auf Hardware-Events beschränkt](https://warcraft.wiki.gg/wiki/API_ReloadUI): es muss von einem echten Klick oder Tastendruck kommen. Ein automatischer Reload nach jedem Bosskill wäre also blockiert. Der Knopf ist die Bauform, die diese Beschränkung zulässt — er meldet sich von allein, gedrückt wird er von Hand.

### 2. Token im Admin-Menü erzeugen

Im EventHelper unter **Einstellungen → Loot-Sync → Token erstellen**. Pro Rechner ein eigenes Token, damit sich ein einzelnes gezielt zurückziehen lässt.

> Das Token wird **genau einmal** angezeigt. Der Server speichert nur einen Hash — es lässt sich später nicht erneut abrufen. Geht es verloren, einfach ein neues erstellen und das alte zurückziehen.

Nur Voll-Admins sehen diesen Tab: ein Token meldet sich ohne Discord-Login an.

### 3. Sync-Tool

Es gibt zwei Wege — der erste braucht **kein** installiertes Node.js.

#### a) Als fertige `EventHelperSync.exe`

Die `.exe` aus den [Releases](https://github.com/mst1987/eventhelper-addon/releases) herunterladen und **doppelklicken**. Beim ersten Start führt sie durch die Einrichtung (Server-Adresse, Token, WoW-Ordner) und geht danach direkt in den Beobachten-Modus über. Ab dann genügt ein Doppelklick zum Starten.

Dabei öffnet sich die **Oberfläche im Browser**:

```
 ┌─ EventHelper Loot-Sync ──────────────────────────────────────┐
 │ STATUS                                                       │
 │   Verbindung       [verbunden]                               │
 │   Server           https://pulse-gdkp.de:3005                │
 │   Addon-Datei      …\SavedVariables\EventHelperSync.lua      │
 │                    (geschrieben 03.08.2026, 22:31)           │
 │   Zuletzt geprüft  vor 8 s                                   │
 │   Letzter Upload   vor 3 min — 2 Session(s)                  │
 │   [ Jetzt hochladen ]  [ Verbindung testen ]                 │
 │                                                              │
 │ WAS IN DER DATEI STEHT                                       │
 │   02.08.2026  20:40–21:10  Tempest Keep              2       │
 │   01.08.2026  21:03–22:03  Serpentshrine Cavern      3       │
 │                                                              │
 │ EINSTELLUNGEN                                                │
 │   Adresse des EventHelper  [https://pulse-gdkp.de:3005 ]     │
 │   API-Token                [ unverändert lassen        ]     │
 │   Addon-Datei              [ Automatisch suchen      ▾ ]     │
 │   Prüfintervall (Sek.)     [ 15 ]                            │
 │   [ Speichern ]                                              │
 │                                                              │
 │ VERLAUF                                                      │
 │   22:31:06  eh-…-ssc: neu in der Inbox — 12 Item(s)          │
 └──────────────────────────────────────────────────────────────┘
```

Das Fenster darf jederzeit zu — der Upload läuft im Hintergrund weiter. Wieder aufrufen: die Adresse steht in der Konsole.

> **Absicherung:** Der Server hört nur auf `127.0.0.1` und verlangt einen Schlüssel, der bei jedem Start neu ausgewürfelt wird — eine fremde Webseite, die im Hintergrund auf localhost schiesst, kommt nicht heran. Das Token selbst verlässt den Rechner nie: die Seite sieht nur seine letzten vier Zeichen und kann ein neues setzen.

Ohne Oberfläche (z.B. als Dienst): `EventHelperSync.exe watch --no-ui`.

> Die Datei enthält die Node-Laufzeit und ist deshalb ~66 MB gross. Sie ist nicht signiert — Windows SmartScreen fragt beim ersten Start nach („Weitere Informationen" → „Trotzdem ausführen").

Selbst bauen: `cd sync && npm install && npm run build:exe` (braucht Node 20+), Ergebnis liegt in `sync/dist/`.

#### b) Mit Node.js

Braucht **Node.js 18 oder neuer** ([nodejs.org](https://nodejs.org)).

```bash
cd sync
npm install
npm run init      # fragt nach Server-Adresse, Token und WoW-Ordner
npm start         # beobachtet die Datei und lädt hoch
```

`npm run init` sucht die WoW-Installation selbst und listet die gefundenen Accounts zur Auswahl. Die Konfiguration landet in `~/.eventhelper-sync.json` (nicht im Programmordner — sie enthält das Token).

**Weitere Befehle** — als `.exe` genauso, nur ohne `npm run` davor (`EventHelperSync.exe status`):

| Befehl | Wirkung |
|---|---|
| `npm start` | dauerhaft beobachten und hochladen |
| `npm run once` | einmal hochladen und beenden |
| `npm run status` | zeigen, was gefunden wurde, ohne zu senden |
| `npm run init` | Konfiguration (neu) anlegen |

---

## Wie es sich im Betrieb anfühlt

**WoW schreibt die SavedVariables nur beim Ausloggen oder bei einem Reload.** Das ist die einzige Stelle, an der etwas von Hand passieren muss — und dafür gibt es den Upload-Knopf: ein Klick in der Raidpause, und der bisherige Abend ist hochgeladen.

Das Sync-Tool darf ruhig dauerhaft laufen. Es lädt bei jeder Änderung der Datei erneut hoch, und das ist Absicht:

- Eine Session, die schon in der Inbox liegt, **wächst** dort — sie stapelt sich nicht zu mehreren Karten.
- Eine Session, die im Menü **übernommen** wurde, bekommt späteren Loot desselben Abends **automatisch** ins gleiche Event angehängt. Nach dem einen Klick muss niemand mehr etwas tun.
- Eine **verworfene** Session kommt nicht zurück.

Typische Ausgabe:

```
[21:47:12] EventHelper Loot-Sync 1.0.0 — Ziel: https://pulse-gdkp.de:3005
[21:47:12] Beobachte C:\...\WTF\Account\PULSE\SavedVariables\EventHelperSync.lua
[21:47:12] WoW schreibt die Datei erst beim Ausloggen oder nach /reload.
[22:31:05] Datei hat sich geändert — lade hoch.
[22:31:06] eh-1784574000-serpentshrine-cavern: neu in der Inbox — 12 Item(s), vorgeschlagen: SSC/TK Mittwoch
[22:31:06] 1 Session(s) warten im Admin-Menü unter Historie & Loot -> Addon-Inbox auf Bestätigung.
[23:58:41] Datei hat sich geändert — lade hoch.
[23:58:42] eh-1784574000-serpentshrine-cavern: 7 Item(s) direkt zu „SSC/TK Mittwoch" ergänzt (12 bereits vorhanden)
```

### Ohne Sync-Tool

Wenn auf dem Rechner nichts laufen soll: `/ehs export` im Spiel, **Strg+A / Strg+C**, und im Admin-Menü unter **Historie & Loot → Import** einfügen. Der Server erkennt das Format von selbst.

---

## Fehlersuche

| Symptom | Ursache / Abhilfe |
|---|---|
| `/ehs` meldet „RCLootcouncil nicht geladen" | Das Addon ist im AddOn-Menü deaktiviert, oder es wurde noch nie Loot damit vergeben. |
| **„findet nichts zum Hochladen"** | **`/ehs diag` im Spiel** — die Ausgabe sagt an jeder Stufe, was gefunden wurde (siehe unten). |
| `/ehs` findet 0 Items | Der Loot ist älter als das Export-Fenster. `/ehs days 60` |
| Sync-Tool: „Keine EventHelperSync.lua gefunden" | Erstens: war das Addon im Spiel schon einmal geladen? Falls ja, listet die Oberfläche die durchsuchten Orte auf — ist dein WoW-Ordner nicht dabei, ihn unter **„Pfad selbst angeben"** eintragen. Der blosse WoW-Ordner genügt. |
| Der Upload-Knopf taucht nicht auf | Es liegt nichts Ungespeichertes an — `/ehs` zeigt den Stand. Oder er wurde per `/ehs button` abgeschaltet. |
| Minimap-Knopf ist weg | `/ehs minimap` schaltet ihn wieder ein. |
| Ein Raid-Abend wird nicht hochgeladen | Im Fenster prüfen, ob sein Häkchen gesetzt ist — abgewählte Abende bleiben abgewählt. |
| Die Oberfläche öffnet sich nicht | Die Adresse steht in der Konsole (`http://127.0.0.1:…/?key=…`) und lässt sich von Hand aufrufen. Ohne den Schlüssel in der Adresse antwortet sie mit 403. |
| Knopf ist grau | Du bist im Kampf. Nach dem Kampf wird er wieder klickbar. |
| SmartScreen blockiert die `.exe` | Die Datei ist nicht signiert. „Weitere Informationen" → „Trotzdem ausführen", oder Weg (b) mit Node benutzen. |
| Sync-Tool: „API-Token unbekannt oder zurückgezogen" | Token wurde im Menü gelöscht, oder falsch kopiert. Neu erstellen und `npm run init`. |
| Sync-Tool: „… nicht erreichbar" | `baseUrl` prüfen (mit `https://` und Port), Server erreichbar? |
| WoW an einem ungewöhnlichen Ort installiert | In `~/.eventhelper-sync.json` `savedVariablesPath` direkt auf die Datei zeigen lassen. |
| In der Inbox steht „mehrere Raids an diesem Tag" | Zwei Raid-Helper-Events am selben Tag — das Event in der Auswahlliste selbst wählen. |

### `/ehs diag` — warum findet er nichts?

„Nichts zum Hochladen" hat mehrere mögliche Ursachen, die von aussen gleich aussehen. Der Befehl geht die Kette Stufe für Stufe durch und zählt, statt zu raten:

```
[EventHelper] --- Diagnose ---  (Addon 1.1.1)
[EventHelper] RCLootcouncil
[EventHelper]   LibStub/Ace:      da
[EventHelper]   Addon geladen:    ja
[EventHelper]   Quelle:           GetHistoryDB()
[EventHelper]   Spieler/Einträge: 12 / 143
[EventHelper]   ältester/jüngster: 04.06.2026 20:41  bis  02.08.2026 22:58
[EventHelper] Gargul
[EventHelper]   GargulDB:         da
[EventHelper]   Tabellen:         AwardHistory(37), GDKP(2), Settings(0)
[EventHelper]   AwardHistory:     da
[EventHelper]   Einträge:         37  davon mit Zeitstempel: 37
[EventHelper] Zeitraum
[EventHelper]   eingestellt:      21 Tage, also alles ab 13.07.2026 15:32
[EventHelper]   im Zeitraum:      18 Vergabe(n)
[EventHelper]   davon RCLC/Gargul: 11 / 7
[EventHelper] Raid-Abende
[EventHelper]   gebildet:         3
[EventHelper]   [dabei]     02.08.2026 — Tempest Keep, 7 Item(s)
[EventHelper]   [abgewählt] 30.07.2026 — Karazhan, 4 Item(s)
[EventHelper] Export
[EventHelper]   landet in der Datei: 2 Session(s), 14 Item(s)
```

Woran man was erkennt:

| Zeile | Bedeutung |
|---|---|
| `Addon geladen: nein` / `GargulDB: fehlt` | Das Loot-Addon ist im AddOn-Menü nicht aktiv. |
| `vorhanden: … <- passt nicht` | RCLootcouncils Historie liegt unter einem anderen Fraktion/Realm-Schlüssel als erwartet — die tatsächlich vorhandenen werden mit ausgegeben. |
| `AwardHistory: fehlt`, aber `Tabellen:` zeigt andere | Gargul legt seine Historie in dieser Version woanders ab. |
| `Einträge: 0` | Die Historie ist leer (frisch geleert?). |
| `im Zeitraum: 0 Vergaben`, obwohl Einträge da sind | Der Loot ist älter als der eingestellte Zeitraum → `/ehs days 60`. |
| `[abgewählt]` | Dieser Abend wurde im Fenster abgewählt und wird nicht hochgeladen. |
| `landet in der Datei: nichts` | Am Ende bleibt nichts übrig — die Zeile darüber sagt, warum. |

---

## Entwicklung

```bash
cd sync
npm test          # Jest: Lua-Parser und Uploader
npm run lint
```

Der Lua-Parser (`sync/lib/luaParser.js`) führt die SavedVariables **nicht** als Code aus, sondern liest sie als Daten — in dem Verzeichnis schreibt jedes beliebige Addon.

### Das Format

Addon, Sync-Tool und Server sprechen `eventhelper-loot` Version 1. Serverseitig liegt es in `src/utils/lootImport.js` (`parseEventHelperSessions`). Wird es geändert, muss die Version auf **beiden** Seiten mitwachsen — der Server lehnt einen Payload mit höherer Version ab, statt ihn halb zu lesen.

```jsonc
{
  "format": "eventhelper-loot",
  "version": 1,
  "generatedAt": 1784581200,      // Unix-Sekunden
  "realm": "Thunderstrike",
  "reporter": "Gemli-Thunderstrike",
  "client": { "addon": "1.0.0", "sync": "1.0.0" },
  "sessions": [{
    "sessionId": "eh-1784574000-serpentshrine-cavern",  // stabil über Re-Uploads
    "startedAt": 1784574000,
    "endedAt": 1784581200,
    "instance": "Serpentshrine Cavern",
    "items": [{
      "source": "rclc",            // "rclc" | "gargul" — bleibt der Dedup-Schlüssel
      "rawId": "1784574268-1",     // RCLootcouncils id bzw. Garguls checksum
      "itemId": 29920,
      "itemName": "Phoenix-Ring of Rebirth",
      "player": "Naphfß-Thunderstrike",
      "class": "SHAMAN",
      "response": "Off Spec",
      "offspec": true,
      "boss": "Lady Vashj",
      "instance": "Serpentshrine Cavern",
      "note": "",
      "replacedGear": ["Ancestral Ring of Conquest"],
      "awardedAt": 1784574268,
      "awardedBy": "Gemli-Thunderstrike",
      "gdkpCost": 15000            // nur Gargul; reist mit, wird noch nicht ausgewertet
    }]
  }]
}
```

### Aufbau des Addons

| Datei | Aufgabe |
|---|---|
| `Core.lua` | Ereignisse, Slash-Befehle, Neuaufbau des Exports, `FlushAndReload()` |
| `Zones.lua` | Zeitleiste der besuchten Raid-Instanzen (für Gargul-Loot ohne Instanz) |
| `Collect.lua` | beide Historien auslesen und auf eine Zeilenform bringen |
| `Sessions.lua` | Zeilen zu Raid-Abenden bündeln |
| `Export.lua` | Envelope bauen (ohne abgewählte Abende), JSON kodieren |
| `Button.lua` | Upload-Knopf: erscheint bei ungespeichertem Loot, Klick löst den Reload aus |
| `Minimap.lua` | Knopf an der Minimap, mit Hinweisring bei Ungespeichertem |
| `Options.lua` | das Fenster: Status, Raid-Abende zum Abwählen, Einstellungen |
| `UI.lua` | Kopierbox hinter `/ehs export` |

Und im Sync-Tool:

| Datei | Aufgabe |
|---|---|
| `lib/luaParser.js` | SavedVariables als Daten lesen, nicht als Code ausführen |
| `lib/wowPaths.js` | die Addon-Datei über alle Client-Varianten und Accounts finden |
| `lib/uploader.js` | eine Session pro Anfrage hochladen |
| `lib/runner.js` | der laufende Betrieb samt Zustand (letzter Upload, Fehler, Verlauf) |
| `lib/webui.js` | der lokale HTTP-Server hinter der Oberfläche |
| `lib/webui-page.js` | die Seite als eine Zeichenkette — kein Build-Schritt, packt sich mit |

### Ein Release bauen

Ein Release entsteht durch einen Tag — den Rest macht [`.github/workflows/release.yml`](.github/workflows/release.yml):

```bash
# 1. Version in beiden Dateien angleichen:
#    addon/EventHelperSync/EventHelperSync.toc   ## Version: 1.1.0
#    sync/package.json                           "version": "1.1.0"
# 2. committen, dann taggen:
git tag v1.1.0
git push origin v1.1.0
```

Der Workflow läuft auf einem Windows-Runner (die `.exe` braucht eine Windows-`node.exe` als Grundlage), prüft Tests und Lint, baut beides und hängt es an das Release:

| Datei | Inhalt |
|---|---|
| `EventHelperSync-1.1.0.zip` | der Ordner `EventHelperSync`, direkt nach `Interface/AddOns/` entpackbar |
| `EventHelperSync.exe` | das Sync-Tool, ohne Node.js lauffähig |

Stimmt die Version im Tag nicht mit der in der `.toc` überein, bricht der Workflow ab — ein Zip, dessen `.toc` etwas anderes behauptet als das Release, klärt später niemand mehr auf.

Zum Ausprobieren ohne Release: **Actions → Release → Run workflow**. Dann werden beide Dateien gebaut und als Artefakt angehängt, aber kein Release angelegt.

### Wie die `.exe` gebaut wird

`sync/scripts/build-exe.js` nutzt Nodes eingebaute [Single Executable Applications](https://nodejs.org/api/single-executable-applications.html) statt eines externen Packers — das Verfahren gehört zu Node selbst und braucht keine Werkzeugkette mit eigener Versionspflege. Drei Schritte: esbuild bündelt `index.js` samt `lib/` zu einer Datei, `node --experimental-sea-config` macht daraus einen Blob, `postject` spleisst ihn in eine Kopie der `node.exe`.

### Interface-Version

`EventHelperSync.toc` steht auf `20504` (TBC 2.5.x). Bei einem Client-Update reicht es, die Zahl anzupassen — Loot-Historien-Zugriff und SavedVariables sind seit Jahren stabil.

---

## Lizenz

MIT
