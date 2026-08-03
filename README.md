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
| `/ehs export` | Export als JSON in einer Kopierbox (Weg ohne Sync-Tool) |
| `/ehs days <n>` | wie viele Tage zurück exportiert werden (Standard: 21) |
| `/ehs debug` | Debug-Ausgaben umschalten |

### 2. Token im Admin-Menü erzeugen

Im EventHelper unter **Einstellungen → Loot-Sync → Token erstellen**. Pro Rechner ein eigenes Token, damit sich ein einzelnes gezielt zurückziehen lässt.

> Das Token wird **genau einmal** angezeigt. Der Server speichert nur einen Hash — es lässt sich später nicht erneut abrufen. Geht es verloren, einfach ein neues erstellen und das alte zurückziehen.

Nur Voll-Admins sehen diesen Tab: ein Token meldet sich ohne Discord-Login an.

### 3. Sync-Tool

Braucht **Node.js 18 oder neuer** ([nodejs.org](https://nodejs.org)).

```bash
cd sync
npm install
npm run init      # fragt nach Server-Adresse, Token und WoW-Ordner
npm start         # beobachtet die Datei und lädt hoch
```

`npm run init` sucht die WoW-Installation selbst und listet die gefundenen Accounts zur Auswahl. Die Konfiguration landet in `~/.eventhelper-sync.json` (nicht im Programmordner — sie enthält das Token).

**Weitere Befehle**

| Befehl | Wirkung |
|---|---|
| `npm start` | dauerhaft beobachten und hochladen |
| `npm run once` | einmal hochladen und beenden |
| `npm run status` | zeigen, was gefunden wurde, ohne zu senden |
| `npm run init` | Konfiguration (neu) anlegen |

---

## Wie es sich im Betrieb anfühlt

**WoW schreibt die SavedVariables nur beim Ausloggen oder nach `/reload`.** Das ist die einzige Stelle, an der etwas manuell nötig ist — und ein `/reload` in der Raidpause genügt, um den bisherigen Abend hochzuladen.

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
| Sync-Tool: „Keine EventHelperSync.lua gefunden" | Das Addon war noch nie geladen. Einmal einloggen und `/reload`. |
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
| `Core.lua` | Ereignisse, Slash-Befehle, Neuaufbau des Exports beim Ausloggen |
| `Zones.lua` | Zeitleiste der besuchten Raid-Instanzen (für Gargul-Loot ohne Instanz) |
| `Collect.lua` | beide Historien auslesen und auf eine Zeilenform bringen |
| `Sessions.lua` | Zeilen zu Raid-Abenden bündeln |
| `Export.lua` | Envelope bauen, JSON kodieren (nur für die Kopierbox) |
| `UI.lua` | Kopierbox hinter `/ehs export` |

### Interface-Version

`EventHelperSync.toc` steht auf `20504` (TBC 2.5.x). Bei einem Client-Update reicht es, die Zahl anzupassen — Loot-Historien-Zugriff und SavedVariables sind seit Jahren stabil.

---

## Lizenz

MIT
