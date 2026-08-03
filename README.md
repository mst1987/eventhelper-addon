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
- **Raid-Abende statt eines Klumpens.** Der Loot wird über die Zeitstempel in Sessions gebündelt, damit jeder Raid-Abend seinem eigenen Raid-Helper-Event zugeordnet werden kann.

Doppelt importiert wird dabei nichts: Jede Zeile behält die ID ihres Ursprungs-Addons (RCLootcouncils `id`, Garguls `checksum`), und der EventHelper dedupliziert darüber. Ein Upload über dieses Addon und ein von Hand eingefügter Export derselben Vergabe fallen zu einem Item zusammen.

---

## Installation

### 1. Addon

Den Ordner `addon/EventHelperSync` nach

```
<WoW>/_classic_era_/Interface/AddOns/EventHelperSync
```

kopieren (bei einem anderen Client entsprechend `_classic_`). Danach im Spiel einloggen und einmal `/reload` ausführen.

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

**Befehle**

| Befehl | Wirkung |
|---|---|
| `/ehs` | Status und gefundene Raid-Sessions |
| `/ehs upload` | jetzt speichern, statt auszuloggen (lädt die UI neu) |
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
| `/ehs` findet 0 Items | Der Loot ist älter als das Export-Fenster. `/ehs days 60` |
| Sync-Tool: „Keine EventHelperSync.lua gefunden" | Das Addon war noch nie geladen. Einmal einloggen und `/reload` (oder den Upload-Knopf drücken). |
| Der Upload-Knopf taucht nicht auf | Es liegt nichts Ungespeichertes an — `/ehs` zeigt den Stand. Oder er wurde per `/ehs button` abgeschaltet. |
| Knopf ist grau | Du bist im Kampf. Nach dem Kampf wird er wieder klickbar. |
| SmartScreen blockiert die `.exe` | Die Datei ist nicht signiert. „Weitere Informationen" → „Trotzdem ausführen", oder Weg (b) mit Node benutzen. |
| Sync-Tool: „API-Token unbekannt oder zurückgezogen" | Token wurde im Menü gelöscht, oder falsch kopiert. Neu erstellen und `npm run init`. |
| Sync-Tool: „… nicht erreichbar" | `baseUrl` prüfen (mit `https://` und Port), Server erreichbar? |
| WoW an einem ungewöhnlichen Ort installiert | In `~/.eventhelper-sync.json` `savedVariablesPath` direkt auf die Datei zeigen lassen. |
| In der Inbox steht „mehrere Raids an diesem Tag" | Zwei Raid-Helper-Events am selben Tag — das Event in der Auswahlliste selbst wählen. |

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
| `Export.lua` | Envelope bauen, JSON kodieren (nur für die Kopierbox) |
| `Button.lua` | Upload-Knopf: erscheint bei ungespeichertem Loot, Klick löst den Reload aus |
| `UI.lua` | Kopierbox hinter `/ehs export` |

### Wie die `.exe` gebaut wird

`sync/scripts/build-exe.js` nutzt Nodes eingebaute [Single Executable Applications](https://nodejs.org/api/single-executable-applications.html) statt eines externen Packers — das Verfahren gehört zu Node selbst und braucht keine Werkzeugkette mit eigener Versionspflege. Drei Schritte: esbuild bündelt `index.js` samt `lib/` zu einer Datei, `node --experimental-sea-config` macht daraus einen Blob, `postject` spleisst ihn in eine Kopie der `node.exe`.

### Interface-Version

`EventHelperSync.toc` steht auf `20504` (TBC 2.5.x). Bei einem Client-Update reicht es, die Zahl anzupassen — Loot-Historien-Zugriff und SavedVariables sind seit Jahren stabil.

---

## Lizenz

MIT
