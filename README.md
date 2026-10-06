# EventHelper Sync

Bringt den vergebenen Raid-Loot aus **RCLootcouncil** und **Gargul** automatisch in den EventHelper-Bot — ohne nach dem Raid zwei Export-Dialoge durchzuklicken und zwei Formate von Hand einzufügen.

Und in die Gegenrichtung den **Loot-Council ins Spiel**: Bedarf und erhaltener Loot je Raider, als Fenster und direkt im Item-Tooltip beim Verteilen (siehe [Loot-Council im Spiel](#loot-council-im-spiel)).

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

kopieren. `<Variante>` ist der Ordner deines Clients — bei den **TBC-Anniversary-Realms `_anniversary_`**, bei **WoW Forever `_classic_beta_`**, sonst `_classic_era_`, `_classic_` oder `_retail_`. Danach im Spiel einloggen und einmal `/reload` ausführen. Wer auf mehreren Clients spielt, kopiert den Ordner in jeden davon.

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
 ┌─ EventHelper Sync ──────────────────────────────────────────────────────────────────┐
 │ Quellen:  RCLootcouncil gefunden    Gargul gefunden                                 │
 │ 58 Raid-Abende, 1535 Items exportbereit.          [   Jetzt speichern (34)       ]  │
 │ 34 Item(s) liegen noch nicht auf der Platte.      [ Export als Text anzeigen     ]  │
 │                                                                                     │
 │ Filter: [Alle Raids ▾]  ☐ nur ungespeicherte  ☐ nur ausgewählte                     │
 │                                          [ Alle auswählen ] [ Alle abwählen ]      │
 │   Datum         Zeit          Raid                     Items Spieler Bosse Quelle   │
 │  ───────────────────────────────────────────────────────────────────────────────    │
 │ ☑ So 02.08.26   19:39–21:18   unbekannt                   34      19     –  Gargul  │
 │ ☑ Mo 27.07.26   21:05–21:24   Gruul's Lair                35      15     2  RCLC    │
 │ ☐ So 26.07.26   20:03–21:33   unbekannt                   33      17     –  Gargul  │
 │ ☑ Mo 20.07.26   21:03–21:20   Serpentshrine Cavern        41      19     2  RCLC    │
 │  …                                                                                  │
 │ 58 Raid-Abende.                                                                     │
 │                                                                                     │
 │ Einstellungen                                                                       │
 │ Zeitraum (Tage)       [ 21 ]   Neuer Abend ab (Std.)  [ 6 ]                         │
 │ ☑ Bank- und Entzauber-Items weglassen                                               │
 │ ☑ Upload-Knopf anzeigen  ☑ Minimap-Knopf anzeigen  ☑ Gildenbank-Knopf an der Minimap│
 │   Zuletzt 574 Item(s) übersprungen (486 RCLootcouncil, 88 Gargul).                  │
 └─────────────────────────────────────────────────────────────────────────────────────┘
```

Jede Zeile beantwortet für sich, ob dieser Abend hochgehört: **Wochentag** (Raids haben feste Tage), Zeitspanne, Raid, wie viele **Items** an wie viele **Spieler**, wie viele **Bosse**, aus welcher **Quelle** und wie viel davon noch **offen** ist. Mehr steht im Tooltip.

**Filter und Sammelauswahl**, weil eine Gilde nach ein paar Monaten bei fünfzig Abenden landet: nach Raid filtern, nur ungespeicherte zeigen — und „Alle abwählen" wirkt auf *das, was der Filter gerade zeigt*. „Alle Karazhan-Abende abwählen" sind damit zwei Klicks statt fünfzig.

**Bank und Entzaubern fliegen raus.** Items, die gar nicht an einen Raider gingen, gehören nicht in die Loot-Historie. Erkannt wird das nicht am Antworttext — den benennt jede Gilde anders — sondern an dem, was die Addons selbst dazu sagen:

| Addon | Kennzeichen |
|---|---|
| RCLootcouncil | `isAwardReason` — genau das setzt es bei „Banking", „Disenchant" und jedem anderen Award-Reason |
| Gargul | der Pseudo-Empfänger `\|\|de\|\|`, den es für entzauberte Items einträgt |

Ein normaler Wurf mit der Antwort „PvP/Bank" bleibt dabei drin — der ging ja an einen Spieler.

**Abwählen, was nicht interessiert.** Der Pug vom Dienstag, die Runde mit Freunden — Häkchen weg, und der Abend wird nicht hochgeladen. Die Auswahl wird gespeichert und gilt dauerhaft. Abgewählte Abende bleiben sichtbar, nur blass: man muss sie ja wiederfinden können, um sie zurückzuholen.

**Der Minimap-Knopf** zeigt schon von aussen, ob etwas ansteht — goldener Ring heisst ungespeicherter Loot. Linksklick öffnet das Fenster, Shift-Linksklick oder Mittelklick den [Loot-Council](#loot-council-im-spiel), Strg-Linksklick die Gildenbank-Ausgabe, Rechtsklick speichert sofort, Ziehen verschiebt ihn um die Minimap.

**Der Gildenbank-Knopf** (eine Truhe) daneben ist nur für die [Gildenbank-Ausgabe](#gildenbank-ausgabe-im-spiel): goldener Ring und eine kleine Zahl, solange Posten offen sind; Linksklick öffnet/schliesst das Fenster, Rechtsklick das EventHelper-Fenster mit den Einstellungen, Ziehen verschiebt ihn (eigene Position). Der Tooltip zeigt „N Posten offen", ggf. „M abgehakt, wird beim nächsten Sync gemeldet" und den Stand der Liste. Ausblenden: `/ehs bankbutton` oder der Haken „Gildenbank-Knopf an der Minimap".

**Befehle**

| Befehl | Wirkung |
|---|---|
| `/ehs` | das Fenster öffnen |
| `/ehs upload` | jetzt speichern, statt auszuloggen (lädt die UI neu) |
| `/ehs status` | dasselbe kurz im Chat |
| `/ehs diag` | **findet er nichts? Das hier sagt, woran es liegt** |
| `/ehs minimap` | Minimap-Knopf ein-/ausblenden |
| `/ehs bankbutton` | Gildenbank-Knopf an der Minimap ein-/ausblenden |
| `/ehs button` | Upload-Knopf ein-/ausblenden |
| `/ehs export` | Export als JSON in einer Kopierbox (Weg ohne Sync-Tool) |
| `/ehs council` oder `/ehc` | das [Loot-Council-Fenster](#loot-council-im-spiel) öffnen |
| `/ehc <Name>` | Loot-Council: zur Kategorie mit diesem Namen wechseln |
| `/ehs bank` oder `/ehb` | die [Gildenbank-Ausgabe](#gildenbank-ausgabe-im-spiel) öffnen |
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

Die `.exe` aus den [Releases](https://github.com/mst1987/eventhelper-addon/releases) herunterladen und **doppelklicken**. Beim ersten Start sind im Fenster gleich die Einstellungen aufgeklappt (Server-Adresse, Token, WoW-Ordner); nach dem Speichern beobachtet es von selbst. Ab dann genügt ein Doppelklick zum Starten.

Dabei öffnet sich **nur** ein eigenes Fenster — keine Konsole, kein Browser-Tab. Die `.exe` ist als Windows-GUI-Programm gebaut (siehe „Wie die `.exe` gebaut wird"), und `lib/appWindow.js` startet die vorhandene Edge- oder Chrome-Installation mit `--app=…` (weder Adressleiste noch Tabs zu sehen). Das Fenster passt sich an seinen Inhalt an: schmal, und nur so hoch wie nötig. Findet sich kein Edge/Chrome, fällt es auf einen normalen Browser-Tab zurück, technisch bleibt es in beiden Fällen dieselbe lokale Seite auf `127.0.0.1`:

```
 ┌─ EVENTHELPER SYNC ──────────────────────────────── ⚙  ✕ ┐
 │          2 bereit zum Hochladen · 4 insgesamt offen      │
 │                                                            │
 │ BEREIT ZUM HOCHLADEN                                       │
 │  [ Gruul & Magtheridon · Mi 24.09. · 42 Items (Gargul) ]  │
 │  [ SSC + TK · So 21.09. · 12 Items (RCLootcouncil)     ]  │
 │                                                            │
 │ ÜBRIGE RAIDS                                                │
 │  ✓ Karazhan · Mo 22.09. · Importiert                        │
 │  – Hyjal · Do 18.09. · Kein Loot gefunden                   │
 │                                                              │
 │ Zuletzt geprüft vor 8 s                      ↻ jetzt prüfen │
 └────────────────────────────────────────────────────────────┘
```

Ein Klick auf eine bereite Zeile lädt **genau diesen einen Raid** hoch — nicht die ganze Datei. Die Zeile springt danach auf „Importiert". Das Zahnrad oben klappt Einstellungen (Server, Token, Addon-Datei, Loot-Council-Kategorie und -Rolle) und den Verlauf ein; „Alles hochladen" für die ganze Datei auf einmal, „Verbindung testen" und „Council-Daten holen" liegen dort mit drin, nicht in der Hauptansicht. Dort steht vom [Loot-Council](#loot-council-im-spiel) nur eine Zeile: „Council: 24 Raider, Stand 21:30 — nach /reload im Spiel sichtbar".

**Ohne bekannten Raid-Termin** (z.B. ein Pug-Abend ohne Raid-Helper-Event) landet trotzdem in „Bereit zum Hochladen" — nur ohne Raid-Namen, mit einem kleinen ✕ daneben, um genau diesen Abend abzuwählen. Das Fenster darf jederzeit zu — der Upload läuft im Hintergrund weiter. Wieder aufrufen: die `.exe` noch einmal doppelklicken. Sie merkt, dass schon eine läuft, öffnet deren Fenster und beendet sich (`lib/instance.js`) — es laufen nie zwei nebeneinander. Ganz beenden: das ✕ oben rechts im Fenster.

**Die Abwahl ist die letzte Entscheidung vor dem Senden.** Ein abgewählter Abend erreicht den Server gar nicht erst und muss dort auch nicht von Hand verworfen werden.

> Das ist bewusst eine **zweite** Stelle neben der Abwahl im Spiel: dort entscheidet man beim Spielen, hier vor dem Absenden — und hier sieht man, was die bisherigen Uploads bewirkt haben.

> **Absicherung:** Der Server hört nur auf `127.0.0.1` und verlangt einen Schlüssel, der bei jedem Start neu ausgewürfelt wird — eine fremde Webseite, die im Hintergrund auf localhost schiesst, kommt nicht heran. Das Token selbst verlässt den Rechner nie: die Seite sieht nur seine letzten vier Zeichen und kann ein neues setzen.

Ohne Oberfläche (z.B. als Dienst): `EventHelperSync.exe watch --no-ui` — läuft dann ganz unsichtbar. Die übrigen Befehle (`init`, `once`, `status`) schreiben in die Konsole und gibt es deshalb nur mit Node.js (Weg b); die `.exe` antwortet darauf mit einem Hinweisdialog.

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

**Weitere Befehle:**

| Befehl | Wirkung |
|---|---|
| `npm start` | dauerhaft beobachten und hochladen |
| `npm run once` | einmal hochladen und beenden |
| `npm run status` | zeigen, was gefunden wurde, ohne zu senden |
| `npm run init` | Konfiguration (neu) anlegen |
| `npm run council` | Council-Daten einmal holen und in die Addon-Ordner schreiben |
| `npm run handouts` | Gildenbank-Ausgabeliste einmal holen und in die Addon-Ordner schreiben |

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

## Loot-Council im Spiel

Die Council-Seite des EventHelper rechnet aus der Loot-Historie für jeden Raider einen **Bedarf** — wie lange sein letztes Item her ist, wie viel er im Vergleich zum Schnitt bekommen hat, wie viel seiner BiS-Liste noch fehlt. Genau das will man beim Verteilen im Spiel sehen, nicht in einem Browser daneben. Die Daten fliessen dafür in die Gegenrichtung:

```
   Server                              auf dem PC                                   im Spiel
   ──────                              ──────────                                   ────────
GET /api/ingest/council ─► Sync-Tool ─► CouncilData.lua in jedem installierten ─► /reload ─► Fenster (/ehc)
 (Bedarf, erhaltener Loot,  (Node)      Interface/AddOns/EventHelperSync                    + Item-Tooltip
  fehlende BiS-Teile)                   (_anniversary_, _classic_beta_, …)
```

**Warum eine Lua-Datei?** Ein Addon kann nichts aus dem Netz holen und keine fremden Dateien lesen. Was es aber tut: beim Laden jede `.lua`-Datei ausführen, die in seiner `.toc` steht. Das Sync-Tool schreibt die Daten deshalb als `CouncilData.lua` direkt in den Addon-Ordner (im Repo liegt dort ein leerer Platzhalter). WoW liest Addon-Dateien nur beim Einloggen und bei `/reload` — neue Daten sind also **nach dem nächsten `/reload`** im Spiel.

Das sieht nur, wer das Addon hat: es wird nichts an den Raid geschickt.

### Wann geholt wird

- beim Start des Sync-Tools, danach **alle 15 Minuten**,
- nach jedem Upload,
- auf Klick: ⚙ → **„Council-Daten holen"**, oder `npm run council` (mit Node.js).

Geschrieben wird in **jeden** installierten Addon-Ordner, den die Suche findet — wer auf TBC Anniversary und WoW Forever raidet, hat in beiden denselben Stand. Ein fehlender Addon-Ordner wird nie angelegt. Die Datei wird erst daneben geschrieben und dann umbenannt, WoW sieht also nie eine halbe. Zeichen, die die Spielschrift nicht kennt (`–`, `…`, typografische Anführungszeichen, Emoji), werden dabei zu ASCII bzw. `?`; Umlaute bleiben.

Ein Fehler beim Holen (Server nicht erreichbar, Server noch ohne diese Route, Ordner schreibgeschützt) hält den Upload nie an. Er steht im Verlauf und in der Statuszeile der Oberfläche.

**Welche Kategorien, welche Filter?** Das stellt die Webseite ein, nicht das Sync-Tool (ab 1.11.0): geholt wird jede Raid-Kategorie, deren Lootsystem unter *Einstellungen → Kategorien* **Loot-Council** ist — jede genau so, wie die Loot-Council-Seite sie zeigt (Rolle, Tiers/Raids, BiS-Liste; ausgeplante Raider fehlen). Die Statuszeile sagt „Council: N Kategorien, M Raider". Gibt es keine solche Kategorie, sagen das Statuszeile und Fenster. Ein älterer Server (nur Version 1) bekommt weiter die alte Anfrage mit Kategorie/Rolle aus einer älteren Konfiguration; das Ergebnis wird als eine Kategorie geschrieben.

### Das Fenster

`/ehs council`, `/ehc`, Shift-Linksklick oder Mittelklick auf den Minimap-Knopf, oder der Knopf „Loot-Council" im Hauptfenster:

```
 ┌ Loot-Council [SSC/TK Mittwoch (auto)] ────────────────── [Alle][Caster][Heiler] [x] ┐
 │ Stand: 05.10. 21:30, vor 2 Std.                                                      │
 │ SSC/TK Mittwoch · nur Caster · T5 · BiS T5 · 24 Raider                           [?] │
 │ ──────────────────────────────────────────────────────────────────────────────────── │
 │ Neuling             ████████████▓▓▓▓▓▓▓▓▒▒  Bedarf 95   0 Items  BiS -        noch nie │
 │ Gemli Shadow        ██████████▓▓▓▓▓▒        Bedarf 82   2 Items  BiS 9/16 vor 12 Tagen │
 │ Naphfß Resto        ████████▓▓▓▓▒           Bedarf 64   3 Items  BiS 4/16   vor 3 Std. │
 │ …                                                                   (Mausrad scrollt) │
 └──────────────────────────────────────────────────────────────────────────────────────┘
      █ Wartezeit (50 %)   ▓ Loot-Anteil (40 %)   ▒ BiS-Lücke (10 %)
```

Eine kompakte Zeile pro Raider, nach Bedarf sortiert: Name in Klassenfarbe mit Spezialisierung, ein **Balken aus drei Teilen** — jeder Teil ist *Gewicht × Wert*, zusammen ergeben sie den Bedarf —, die Bedarfszahl, wie viele zählende Items er schon hat, sein BiS-Stand und wann er zuletzt etwas bekam. Mehr steht nicht in der Zeile; der **Tooltip** einer Zeile zeigt die drei Teile mit Erklärung, die erhaltenen Items (neueste zuerst, mit Datum, Item-Link, Boss und Grund) und wie viele BiS-Teile noch offen sind. Das `?` erklärt die Farben. Escape schliesst das Fenster, die Position wird gespeichert.

**Kategorie wählen:** der Knopf neben dem Titel (auf WoW Forever ein Menü, sonst schaltet Links-/Rechtsklick weiter) oder `/ehc <Name>` (Anfang des Namens genügt, `/ehc kara`). Die Wahl wird gemerkt. Betritt man eine **Raid-Instanz**, zu der genau eine Kategorie passt (Instanzname/Zone gegen die Instanzen der Raidvorlage der Kategorie), gilt diese von selbst — der Knopf zeigt dann „(auto)"; passen keine oder mehrere, bleibt die eigene Wahl. Ohne Wahl gilt die erste Kategorie. Alle/Caster/Heiler filtern innerhalb der Kategorie; zeigt die Webseite für eine Kategorie nur Caster, bleibt „Heiler" leer und sagt warum. `/ehs status` listet die Kategorien.

### Im Item-Tooltip

Auf jedem Item-Tooltip — Loot-Fenster, RCLootcouncils Abstimmungsfenster, Taschen, Item-Links im Chat — steht, wem das Item als **BiS fehlt**, nach Bedarf sortiert, höchstens fünf — aus der gewählten (oder zur Instanz passenden) Kategorie; ist keine gewählt, aus allen, jeder Raider einmal:

```
Loot-Council:
Gemli (Shadow) Bedarf 82 - 2 Items
Naphfß (Resto) Bedarf 64 - 3 Items
... und 3 weitere
```

Auf WoW Forever hängt das an `TooltipDataProcessor`, auf TBC Anniversary an `OnTooltipSetItem` von `GameTooltip` und `ItemRefTooltip`. Der Abschnitt steht nie doppelt in einem Tooltip.

### Vergaben seit dem letzten Sync

Die Council-Daten sind der Stand des Servers beim letzten Sync (`generatedAt`). Was danach im Raid vergeben wird, steht aber schon in der Historie von RCLootCouncil bzw. Gargul — das Addon liest sie ohnehin für den Upload. Fenster und Item-Tooltip rechnen diese Vergaben deshalb **sofort und ohne Sync oder `/reload`** mit, als vorläufige Werte (ab 1.12.0):

- **Welche Vergaben:** nur die mit Zeitstempel **nach** `generatedAt`, mit denselben Ausnahmen wie der Upload (Award-Reasons wie Bank/Entzaubern, solange *„Bank- und Entzauber-Items weglassen"* an ist; Garguls `||de||`). Dieselbe Vergabe aus RCLootCouncil **und** Gargul (gleicher Spieler, gleiches Item, höchstens 5 Minuten auseinander) zählt einmal. Der Spieler wird über den Namen ohne Realm gefunden, Gross-/Kleinschreibung egal.
- **Wie gezählt wird — wie auf dem Server:** der Grund kommt aus dem Antworttext (dieselben Muster wie `lootReasons.js`: BiS, Mainspec, Upgrade, Kleines Upgrade und Unbekanntes **zählen**; Offspec, PvP, Greed, Entzaubert, Bank nicht). Eine zählende Vergabe: Items +1, letzter Loot = jetzt (Wartezeit 0). Eine nicht zählende: „dazu N Offspec/Bank" +1. Fehlt das Item dem Raider als BiS-Teil, ist es abgehakt (BiS +1, eine Kopie bei doppelten Ringen) — ausser es wurde entzaubert oder ging in die Bank. Danach werden **Schnitt und Bedarf aller Raider** der Kategorie neu gerechnet (`needScore` des Servers: Wartezeit/30 Tage, Anteil gegen den Schnitt, BiS-Lücke, Gewichte aus den Daten) und neu sortiert.
- **Welche Kategorie:** nennt die Vergabe eine Instanz (RCLootCouncil; bei Gargul die eigene Zonen-Zeitleiste), zählt sie in den Kategorien, deren Raidvorlage diese Instanz hat; sonst in jeder Kategorie, in der der Raider steht.
- **Sichtbar:** ein orangenes `*` hinter der Bedarfszahl bei eigenen Vergaben, ein graues, wenn sich nur der Schnitt verschoben hat. Der Zeilen-Tooltip sagt „inkl. N Vergabe(n) seit dem letzten Sync (vorläufig)" und listet sie (mit Grund, „zählt nicht", „BiS"); die Kopfzeile „vorläufig: N Vergaben seit 05.10. 21:30". Der Item-Tooltip zeigt die neuen Zahlen und lässt Raider weg, die das Teil gerade bekommen haben.
- **Wann:** beim Öffnen des Fensters, beim Item-Tooltip (höchstens einmal pro Sekunde nachgesehen) und alle 3 Sekunden bei offenem Fenster. Nachgesehen wird nur, ob die Historien gewachsen sind; gerechnet nur dann. Ohne RCLootCouncil/Gargul ändert sich nichts.
- **Nach dem nächsten Sync** sind diese Vergaben in den Zahlen des Servers; ihr Zeitstempel liegt dann vor dem neuen `generatedAt`, und sie fallen hier von selbst wieder heraus.

Was der Server genauer weiss und das Spiel nicht: ob ein Item im Tier-/Raid-Filter der Kategorie liegt (hier zählt es immer), zu welchem Raid-Event (und damit welcher Kategorie) eine Vergabe gehört, ob jemand ein BiS-Teil wirklich trägt, und Raider, die erst durch diese Vergabe in die Kategorie kämen. Deshalb „vorläufig".

---

## Gildenbank-Ausgabe im Spiel

Raider fragen im EventHelper Gegenstände aus dem Gildenbank-Bestand an, die Orga bestätigt sie. Was bestätigt ist, muss jemand im Spiel aus der Bank holen und weitergeben — die Liste dafür kommt auf demselben Weg wie die Council-Daten ins Spiel, und was dort abgehakt wird, geht zurück:

```
   Server                                         auf dem PC                       im Spiel
   ──────                                         ──────────                       ────────
GET  /api/ingest/guildbank/handouts ─► Sync-Tool ─► GuildBankData.lua ─► /reload ─► Fenster (/ehs bank)
POST /api/ingest/guildbank/handouts ◄─ Sync-Tool ◄─ EventHelperSyncDB.guildBankDone ◄─ abhaken, /ehs upload
```

### Wann geholt und gemeldet wird

- Geholt wird beim Start des Sync-Tools, danach **alle 5 Minuten**, nach jedem Upload, nach jedem hochgeladenen Gildenbank-Scan (der Bestand ändert sich) und nach jeder Meldung. Auf Klick: ⚙ → **„Ausgabeliste holen"**, oder `npm run handouts`.
- Gemeldet wird, sobald die Addon-Datei abgehakte Posten enthält, die noch nicht gemeldet sind — also nach `/ehs upload`, `/reload` oder dem Ausloggen. Höchstens 200 je Anfrage. Gemeldete Posten merkt sich das Tool (30 Tage), sie gehen nicht doppelt raus; danach holt es die Liste sofort neu, und nach dem nächsten `/reload` verschwinden sie im Spiel. Ein Fehler (Server weg, 5xx) wird nach 5 Minuten oder bei der nächsten Änderung der Datei erneut versucht. Doppelt melden schadet nicht: der Server antwortet dann mit „schon ausgegeben".

### Das Fenster

`/ehs bank`, `/ehb`, der eigene Gildenbank-Knopf an der Minimap, Strg-Linksklick auf den EventHelper-Minimap-Knopf, der Knopf „Gildenbank" im Hauptfenster — und **von selbst, wenn die Gildenbank geöffnet wird** und etwas offen ist (abschaltbar im Hauptfenster). Dann schliesst es sich auch mit der Bank.

```
 ┌ Gildenbank-Ausgabe ───────────────────────────────────────────── [Offen][Alle] [x] ┐
 │ Stand: 05.10. 21:30, vor 1 Std. - Pulse (Thunderstrike)                            │
 │ 3 Posten offen - 1 abgehakt, wird beim nächsten Sync gemeldet     Gildenbank offen │
 │ ────────────────────────────────────────────────────────────────────────────────── │
 │ [ ] Anna        [?] 3x Super Healing Potion          Tab 3        4 da             │
 │ [ ] Naphfß      [?] 2x Super Healing Potion          Tab 3        nur 1!           │
 │ [x] Zibbo       [#] 2x Bold Living Ruby  (durchgestrichen)  Tab 1/2      14 da     │
 └────────────────────────────────────────────────────────────────────────────────────┘
```

Das Fenster ist 640 px breit und zeigt 12 Zeilen à 30 px (Mausrad scrollt, der Balken rechts zeigt die Position), Icons 24 px, Name und Gegenstand in normaler Schriftgrösse. Eine Zeile pro Posten, nach Empfänger gruppiert: Häkchen, Name in Klassenfarbe (hat der Raider keinen Charakter hinterlegt, steht sein Discord-Name in Grau), Icon, Menge und Gegenstand in Qualitätsfarbe, der Bank-Tab und wie viele da sind. Reicht der Bestand nicht, steht dort in Gelb **„nur 1!"** — offene Posten desselben Gegenstands teilen sich den Bestand der Reihe nach. Ist die Gildenbank offen und wurde bei diesem Besuch gescannt, zählt der **live** gezählte Bestand, sonst der Stand des letzten hochgeladenen Scans. Gezeigt werden die Posten der Gildenbank dieses Charakters (Client, Realm, Gilde); gibt es die nicht, die Banken dieses Clients bzw. alle, mit Hinweis in der Kopfzeile.

Abhaken legt den Posten unter `EventHelperSyncDB.guildBankDone` ab (`{ id, via = "manual", by = "Name-Realm", at }`), die Zeile wird gedimmt und durchgestrichen, „Offen" blendet sie aus. Haken wieder weg nimmt es zurück, solange es noch nicht gemeldet ist. `/ehs upload` speichert auch, wenn nur abgehakt wurde. Der Tooltip einer Zeile zeigt Zweck, wer angefragt und wer bestätigt hat, den Bestand je Tab und „Abhaken, wenn rausgegeben." bzw. den Hinweis auf die Fehlmenge.

### Aus der Gildenbank nehmen (Klick auf eine Zeile)

Ist die Gildenbank offen, nimmt ein **Klick auf eine Zeile** (nicht auf das Häkchen) den Posten aus der Bank in die Taschen, **Shift-Klick** alle offenen Posten dieses Empfängers. Genommen wird, was in den Taschen noch fehlt (was schon drin ist, zählt wie am Briefkasten mit). Abgehakt wird dabei **nichts** — das passiert beim Senden der Post oder per Häkchen.

- Die Stapel werden live aus den sichtbaren Tabs gelesen; sah der Scan oder der Server den Gegenstand in einem Tab, den der Client gerade nicht zeigt, wird der Tab erst abgefragt (`QueryGuildBankTab`).
- Reihenfolge: ein genau passender Stapel, sonst ganze kleinere Stapel, sonst wird vom kleinsten ausreichenden Stapel abgeteilt. Ganze Stapel gehen mit `AutoStoreGuildBankItem` in die Taschen, Teilmengen mit `SplitGuildBankItem` und `PickupContainerItem` in einen freien Taschenplatz. Jeder Schritt wartet, bis die Gegenstände wirklich in den Taschen sind; der gespeicherte Scan wird für den Tab neu gelesen.
- Das Tageslimit je Tab (`GetGuildBankTabInfo`, verbleibende Entnahmen; -1 = unbegrenzt) wird beachtet: es wird genommen, was geht, der Rest steht im Chat („Super Healing Potion: 1 von 2 nicht genommen - Tageslimit des Tabs erreicht."). Ohne freien Taschenplatz passiert nichts („Kein freier Taschenplatz - erst Platz schaffen."). Nie im Kampf.
- Danach steht in der Zeile in Grün **„in den Taschen"** und im Chat „Aus der Gildenbank genommen: 2x Bold Living Ruby"; solange es läuft, „wird geholt ...". Bei geschlossener Bank tut der Klick nichts, der Tooltip sagt „Klick bei offener Gildenbank: in die Taschen nehmen".
- **Sperrt der Client das** (Fehler, leerer Cursor nach dem Teilen, `ADDON_ACTION_BLOCKED`/`ADDON_ACTION_FORBIDDEN`), hört es auf, leert den Cursor und nennt die Plätze im Chat („Tab 3 Platz 1: 1x Arcane Powder (von 49, Shift-Klick teilt den Stapel)"); im gerade gezeigten Tab sind sie gold umrandet. Das gilt für die Sitzung.

Dieselbe Logik gibt es als API in `GuildBankHandouts.lua`: `EHS:GetHandouts()` (offene Posten dieses Charakters, nach Empfänger gruppiert), `EHS:MarkHandedOut(ids, via, by)`, `EHS:UnmarkHandedOut(ids)`, `EHS:IsHandedOut(id)`, `EHS:HandoutCounts()`, und `EHS:OnGuildBankEvent(fn)` in `GuildBank.lua` meldet „open", „close" und „scan".

### Ausgabe per Post (am Briefkasten)

Am Briefkasten wechselt das Fenster in den **Post-Modus** (und öffnet sich von selbst, wenn etwas offen ist — dieselbe Einstellung wie bei der Bank; es schliesst sich dann auch mit dem Briefkasten):

```
 ┌ Gildenbank-Ausgabe ──────────────────────────────────────────────────────────── [x] ┐
 │ Stand: 06.10. 19:10, vor 5 Min.                                                     │
 │ 4 Spieler offen - Gesendetes wird automatisch abgehakt            Briefkasten offen │
 │ ─────────────────────────────────────────────────────────────────────────────────── │
 │▌Thrall    [#] 2x Bold Living Ruby          in der Post               [Vorbereitet]  │
 │▌          [#] 3x Super Mana Potion                                                  │
 │ Jaina     [#] 5x Flask of Supreme Power    in den Taschen            [   Post    ]  │
 │ Uther     [#] 2x Smooth Dawnstone          fehlt 1 in den Taschen                   │
 │ Anna      [?] 1x Super Healing Potion      kein Charakter                           │
 └─────────────────────────────────────────────────────────────────────────────────────┘
```

Eine Zeile **je Spieler** mit bis zu drei Posten (sonst zwei und „+N weitere"), daneben, ob alles **in den Taschen** ist oder in Gelb **„fehlt N in den Taschen"** (Posten desselben Gegenstands teilen sich den Taschenbestand der Reihe nach). Ohne hinterlegten Charakter („kein Charakter") und bei der anderen Fraktion („andere Fraktion") gibt es keinen Knopf, ebenso wenn etwas fehlt. Der Tooltip zeigt die Posten mit Zweck und das **Porto** (30 Kupfer je Anhang, zahlt der Absender).

**„Post"** (nur ausserhalb des Kampfes):

1. wechselt auf „Nachricht senden" und füllt **Empfänger** (`Name`, auf einem anderen Realm `Name-Realm`), **Betreff** „Gildenbank: N Posten" und **Text** (ein Posten je Zeile mit Zweck, nur Latin-1),
2. hängt genau die vorgemerkten Mengen an, Schritt für Schritt mit kurzen Pausen: ein passender Stapel wird ganz genommen, von einem grösseren wird erst die Menge in einen freien Taschenplatz abgeteilt (`SplitContainerItem`) und dann angehängt (`ClickSendMailItemButton`); jeder Schritt wartet, bis der Anhang wirklich da ist,
3. höchstens **12 Anhänge** pro Brief — passt nicht alles hinein, bleibt der Rest offen und die Zeile bietet nach dem Senden wieder „Post" an.

Danach steht in der Zeile in Gold **„in der Post"** / **„Vorbereitet"**. Das Addon ruft **nie** selbst `SendMail` auf — **Senden klickt der Spieler**. Ein Hook auf `SendMail` (`hooksecurefunc`, ohne Taint) merkt sich Empfänger und Anhänge des abgehenden Briefs; bei `MAIL_SEND_SUCCESS` werden genau die vorbereiteten Posten abgehakt, deren Gegenstände wirklich drin waren (`via = "mail"`), und der Chat meldet „Post an Thrall gesendet: 2 Posten abgehakt.". Bei `MAIL_FAILED` oder wenn der Empfänger vorher geändert wurde, wird nichts abgehakt.

**Wenn der Client das Anhängen sperrt** (offen bei WoW Forever): Wirft ein Aufruf einen Fehler, bleibt der Cursor leer oder meldet der Client `ADDON_ACTION_BLOCKED`/`ADDON_ACTION_FORBIDDEN` für dieses Addon, hört es auf. Empfänger, Betreff und Text bleiben ausgefüllt, der Chat nennt die Plätze („Tasche 1 Platz 4: 2x Bold Living Ruby (von 5, Shift-Klick teilt den Stapel)") und in den offenen Taschen sind sie gold umrandet — hineinziehen, Senden, abgehakt wird trotzdem. Das merkt sich das Addon für die Sitzung und geht beim nächsten Brief gleich so vor.

Was noch in der Gildenbank liegt, holt ein Klick auf die Zeile an der offenen Bank in die Taschen ([siehe oben](#aus-der-gildenbank-nehmen-klick-auf-eine-zeile)). Am Briefkasten hat das Fenster 6 Zeilen à 60 px mit bis zu drei Posten (Icons 18 px).

---

## Fehlersuche

| Symptom | Ursache / Abhilfe |
|---|---|
| `/ehs` meldet „RCLootcouncil nicht geladen" | Das Addon ist im AddOn-Menü deaktiviert, oder es wurde noch nie Loot damit vergeben. |
| **„findet nichts zum Hochladen"** | **`/ehs diag` im Spiel** — die Ausgabe sagt an jeder Stufe, was gefunden wurde (siehe unten). |
| `/ehs` findet 0 Items | Der Loot ist älter als das Export-Fenster. `/ehs days 60` |
| Sync-Tool: „Keine EventHelperSync.lua gefunden" | Erstens: war das Addon im Spiel schon einmal geladen? Falls ja, listet die Oberfläche die durchsuchten Orte auf — ist dein WoW-Ordner nicht dabei, ihn unter **„Pfad selbst angeben"** eintragen. Der blosse WoW-Ordner genügt. |
| Der Upload-Knopf taucht nicht auf | Es liegt nichts Ungespeichertes an — `/ehs` zeigt den Stand. Oder er wurde per `/ehs button` abgeschaltet. |
| Minimap-Knopf ist weg | `/ehs minimap` schaltet ihn wieder ein, den Gildenbank-Knopf `/ehs bankbutton`. |
| Ein Raid-Abend wird nicht hochgeladen | Wurde er per ✕ neben der Zeile abgewählt? Abgewählte Abende bleiben abgewählt und tauchen in „Bereit zum Hochladen" nicht mehr auf. |
| Die Oberfläche öffnet sich nicht | Die `.exe` noch einmal doppelklicken — läuft sie schon, öffnet das ihr Fenster erneut. Die Adresse samt Schlüssel steht außerdem in `~/.eventhelper-sync.running.json` und lässt sich von Hand aufrufen (ohne den Schlüssel antwortet sie mit 403). Kein installierter Edge/Chrome gefunden: das Fenster öffnet sich dann als normaler Browser-Tab statt chromelos — technisch dieselbe Seite. Scheitert der Start ganz, sagt ein Fehlerdialog warum. |
| Knopf ist grau | Du bist im Kampf. Nach dem Kampf wird er wieder klickbar. |
| Loot-Council: „Noch keine Council-Daten" | Läuft das Sync-Tool, und steht in seiner Statuszeile „Council: … Raider"? Danach im Spiel `/reload` — Addon-Dateien liest WoW nur beim Laden. |
| Statuszeile: „kein Addon-Ordner gefunden" | Das Addon liegt nicht unter `<WoW>/<Variante>/Interface/AddOns/EventHelperSync`, oder WoW an einem Ort, den die Suche nicht kennt — unter ⚙ „Pfad selbst angeben". |
| Statuszeile: „Der Server kennt noch keine Council-Daten" | Der EventHelper ist älter als diese Funktion (Route `GET /api/ingest/council` fehlt). |
| Loot-Council: „neuer als dieses Addon" | Sync-Tool und Server sprechen eine neuere Version des Formats — das Addon aktualisieren. |
| SmartScreen blockiert die `.exe` | Die Datei ist nicht signiert. „Weitere Informationen" → „Trotzdem ausführen", oder Weg (b) mit Node benutzen. |
| Sync-Tool: „API-Token unbekannt oder zurückgezogen" | Token wurde im Menü gelöscht, oder falsch kopiert. Neu erstellen und im Fenster unter ⚙ eintragen (mit Node: `npm run init`). |
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
npm test          # Jest: Lua-Parser, Uploader, Council-Daten, Oberfläche
npm run lint

cd ../addon-test
npm install
npm test          # Lua-Specs des Addons (fengari) + Latin-1-Prüfung, danach flavors/ (TBC Anniversary und WoW Forever)
```

`addon-test/` führt die Addon-Dateien in **fengari** (Lua 5.3 in JavaScript) gegen eine nachgebaute WoW-API (`mock/wow.lua`) aus — übernommen aus den Test-Harnessen von DuoLevel und ProfessionKit. Der Ordner ist bewusst eigenständig: er ist weder Abhängigkeit des Sync-Tools noch Teil des Addon-Zips. Jeder Spec in `addon-test/spec/` läuft in einem frischen Lua-Zustand, richtet erst den Client ein (welche Events er kennt, `WOW_PROJECT_ID`, Gildenbank) und ruft dann `loadAddon()` auf. Dazu prüft der Lauf, dass kein Text im Addon Zeichen ausserhalb von Latin-1 enthält (die Spielschrift zeigt dafür nur Kästchen).

Der Lua-Parser (`sync/lib/luaParser.js`) führt die SavedVariables **nicht** als Code aus, sondern liest sie als Daten — in dem Verzeichnis schreibt jedes beliebige Addon.

`addon-test/flavors/` (zweiter Teil von `npm test`) lädt alle Dateien der `.toc` vorab gegen eine eigene nachgebaute WoW-API (`flavors/mock/wow.lua`) — einmal Classic-artig (TBC Anniversary: `GetItemInfo`, `UIDropDownMenu`, `OnTooltipSetItem`) und einmal Retail-artig (WoW Forever: nur `C_Item`/`C_AddOns`, `TooltipDataProcessor`, `MenuUtil`, unbekannte Ereignisse werfen, ohne die Classic-Vorlagen). Die Council-Daten dafür schreibt der echte Serializer aus `sync/lib/council.js`. Vorher prüft `latin1.js`, dass jeder String im Addon nur Zeichen enthält, die die Spielschrift darstellen kann (kein `→`, `–`, `…`, keine typografischen Anführungszeichen). Der Ordner liegt bewusst neben `addon/EventHelperSync`, nicht darin — er kommt nicht ins Release-Zip.

> Ist der Addon-Ordner im Spiel per Junction mit diesem Repo verbunden, überschreibt das Sync-Tool die eingecheckten Platzhalter `CouncilData.lua` und `GuildBankData.lua`. Damit `git status` sauber bleibt: `git update-index --skip-worktree addon/EventHelperSync/CouncilData.lua addon/EventHelperSync/GuildBankData.lua`.

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

#### Gildenbank: `eventhelper-guildbank` Version 1

Öffnet jemand mit dem Addon die Gildenbank, liest `GuildBank.lua` alle sichtbaren Tabs nacheinander aus (der Server drosselt die Abfragen) und legt **nur den letzten Scan** unter `EventHelperSyncDB.guildBank` ab. Im Chat steht danach „Gildenbank gescannt: X Tabs, Y Gegenstände" — auf die Platte kommt der Scan wie der Loot erst mit `/ehs upload`, `/reload` oder dem Ausloggen. Im Kampf wird nicht gescannt.

Das Sync-Tool lädt den Scan per `POST /api/ingest/guildbank` (dasselbe Token) hoch, sobald sein `scannedAt` neuer ist als der zuletzt angenommene Scan **dieser** Gildenbank. Der Schlüssel einer Gildenbank ist `client.project` + `guild.realm` + `guild.name`; den Stand je Schlüssel merkt sich das Tool in `~/.eventhelper-sync.json` (`guildBankUploads`). Schlägt der Upload fehl, steht das im Verlauf und im Fenster, und das Tool versucht es nach 5 Minuten oder bei der nächsten Änderung der Datei erneut — der Loot-Upload läuft davon unberührt weiter.

```jsonc
{
  "format": "eventhelper-guildbank",
  "version": 1,
  "generatedAt": 1784574100,          // Unix-Sekunden
  "client": { "project": "tbc", "build": "2.5.5" },   // project: "tbc" | "forever" | "classic"
  "guild": { "name": "Pulse", "realm": "Thunderstrike", "faction": "Alliance" },
  "scannedBy": "Gemli-Thunderstrike",
  "scannedAt": 1784574100,            // Unix-Sekunden, Ende des Scans
  "money": 123456789,                 // Kupfer
  "tabs": [{
    "index": 1,                       // Tab-Nummer im Spiel; nicht sichtbare Tabs fehlen
    "name": "Mats",
    "items": [{ "itemId": 22445, "count": 20, "slot": 1 }]   // slot 1-98, ein Eintrag je Stapel
  }]
}
```

`client.project` kommt aus `WOW_PROJECT_ID` (5 = TBC, 1 = Forever/Retail, 2 = Classic Era), ersatzweise aus der Interface-Nummer. `build` ist die Versionsnummer aus `GetBuildInfo()`.

### Das Council-Format

Für die Gegenrichtung sprechen Server, Sync-Tool und Addon `eventhelper-council` **Version 2**. Serverseitig liefert es `GET /api/ingest/council?v=2` (ohne `category`) im Repo `d:/programming/eventhelper` (`docs/loot-import.md`, Hülle `{ data }`, Fehler `{ error: { code, message } }`, Token wie beim Upload). Wird es geändert, muss die Version auf **beiden** Seiten mitwachsen — das Sync-Tool lehnt eine höhere Version ab, statt sie halb zu schreiben, und das Addon zeigt dann einen Hinweis statt halber Daten.

Version 2 ist eine Liste von Kategorien (nur die mit Lootsystem Loot-Council, sonst `[]`), jede mit den Filtern der Webseite und einer Raider-Liste in der Form von Version 1 (plus `key`):

```jsonc
{
  "format": "eventhelper-council",
  "version": 2,
  "generatedAt": 1791234567,
  "weights": { "drought": 50, "share": 40, "need": 10 },
  "categories": [{
    "id": "1234567890",                 // im Addon gemerkt: EHS.db.settings.councilCategory
    "name": "SSC/TK Mittwoch",          // das Sync-Tool nimmt Emoji heraus
    "lootSystem": "lootcouncil",
    "filter": { "role": "caster", "tiers": ["t5"], "contents": [], "bisTier": "t5", "bisTierDerived": false, "version": "tbc" },
    "instances": [{ "id": "ssc", "name": "Höhle des Schlangenschreins", "short": "SSC", "zoneNames": [] }],   // für die Auto-Wahl
    "avgLootCount": 3.4,
    "raiders": [{ "key": "gemli", "character": "Gemli", … }]   // wie unten
  }]
}
```

Antwortet ein älterer Server auf `?v=2` mit Version 1 (oder 404), stellt das Sync-Tool die alte Anfrage `?category=&role=` (aus der Konfiguration) und schreibt das Ergebnis als eine Kategorie in der Form von Version 2 (`fromVersion = 1`). Das Addon versteht beides, auch eine Version-1-Datei eines älteren Sync-Tools. Version 1:

```jsonc
{
  "format": "eventhelper-council",
  "version": 1,
  "generatedAt": 1791234567,          // Unix-Sekunden, wie alle Zeiten hier
  "filter": { "category": "", "categoryName": "", "role": "", "bisTier": "t6", "bisTierDerived": true },
  "categories": [{ "id": "123", "name": "SSC/TK Mittwoch" }],   // Auswahl im Sync-Tool
  "weights": { "drought": 50, "share": 40, "need": 10 },        // Gewichte in Prozent
  "avgLootCount": 3.4,
  "raiders": [{                       // Bedarf absteigend, dann Name
    "character": "Gemli",
    "classFile": "PRIEST",            // RAID_CLASS_COLORS-Schlüssel, "" wenn unbekannt
    "specLabel": "Shadow",
    "role": "caster",                 // "caster" | "healer"
    "need": 82,                       // 0..100
    "parts": { "drought": 100, "share": 60, "need": 40 },   // je 0..100, ungewichtet
    "lootCount": 2, "lootTotal": 5, "otherCount": 1,
    "lastAwardAt": 1791000000,        // 0 = noch nie
    "daysSinceLoot": 12,              // -1 = noch nie
    "bis": { "tier": "t6", "source": "wowsims", "owned": 9, "total": 16, "missing": [30000, 30001] },
    "items": [{ "itemId": 30000, "itemName": "…", "awardedAt": 1791000000,
                "boss": "Lady Vashj", "reason": "Main Spec", "event": "SSC/TK Mittwoch" }]   // neueste zuerst, höchstens 25
  }]
}
```

Das Sync-Tool schreibt daraus `CouncilData.lua` — dieselbe Struktur als Lua-Tabelle, Arrays als Sequenzen:

```lua
-- Generated by EventHelper Sync 1.11.0 at 2026-10-05T19:30:00.000Z. Do not edit; it is overwritten.
EventHelperSync_Council = {
  format = "eventhelper-council",
  version = 2,
  categories = { ... },
  ...
}
```

### Das Ausgabe-Format

`eventhelper-guildbank-handouts` Version 1, serverseitig `GET`/`POST /api/ingest/guildbank/handouts` (Repo `d:/programming/eventhelper`, `docs/loot-import.md`, „Ausgabeliste für das Addon"). Auch hier lehnt das Sync-Tool eine höhere Version ab. Das Sync-Tool schreibt die Antwort als `GuildBankData.lua` mit der globalen Variable `EventHelperSync_GuildBankHandouts`:

```jsonc
{
  "format": "eventhelper-guildbank-handouts", "version": 1, "generatedAt": 1791294674,
  "banks": [{                          // auch Banken ohne Posten, damit das Addon die Liste leeren kann
    "key": "tbc:spineshatter:die gilde", "gameVersion": "tbc", "realm": "Spineshatter", "guild": "Die Gilde",
    "faction": "Alliance", "scannedAt": 1791000000,
    "handouts": [{
      "id": "ad8f943938a6", "itemId": 24027, "name": "Bold Living Ruby",
      "icon": "inv_jewelcrafting_livingruby_03",   // "" = unbekannt
      "quality": 3,                                // -1 = unbekannt
      "amount": 2, "purpose": "Gruul",
      "character": { "name": "Zibbo", "realm": "Spineshatter", "faction": "Alliance", "classFile": "PRIEST" },  // null = kein Charakter
      "requestedBy": "Anna", "requestedAt": 1791294665, "confirmedBy": "Arthas", "confirmedAt": 1791294665,
      "inBank": 14,
      "tabs": [{ "index": 1, "name": "Edelsteine", "count": 10 }]
    }]
  }]
}
```

Zurück geht `POST { "done": [{ "id", "via": "manual" | "mail", "by": "Name-Realm", "at": <Unix-Sekunden> }] }` mit höchstens 200 Einträgen; die Antwort teilt jede id in `ok`, `duplicate`, `notConfirmed` oder `unknown` — jede davon gilt als erledigt. Die gemeldeten ids merkt sich das Tool in `~/.eventhelper-sync.json` (`guildBankDoneReported`).

### Aufbau des Addons

| Datei | Aufgabe |
|---|---|
| `Core.lua` | Ereignisse, Slash-Befehle, Neuaufbau des Exports, `FlushAndReload()` |
| `Zones.lua` | Zeitleiste der besuchten Raid-Instanzen (für Gargul-Loot ohne Instanz) |
| `Collect.lua` | beide Historien auslesen und auf eine Zeilenform bringen |
| `Sessions.lua` | Zeilen zu Raid-Abenden bündeln |
| `Export.lua` | Envelope bauen (ohne abgewählte Abende), JSON kodieren |
| `GuildBank.lua` | Gildenbank beim Öffnen scannen (TBC: `GUILDBANKFRAME_OPENED`, Forever: `PLAYER_INTERACTION_MANAGER_FRAME_SHOW`), letzter Scan nach `EventHelperSyncDB.guildBank` |
| `Button.lua` | Upload-Knopf: erscheint bei ungespeichertem Loot, Klick löst den Reload aus |
| `Minimap.lua` | Knopf an der Minimap, mit Hinweisring bei Ungespeichertem; der Gildenbank-Knopf daneben |
| `Options.lua` | das Fenster: Status, Raid-Abende zum Abwählen, Einstellungen |
| `UI.lua` | Kopierbox hinter `/ehs export` |
| `CouncilData.lua` | Platzhalter; das Sync-Tool überschreibt ihn mit den Council-Daten |
| `Council.lua` | Council-Logik ohne Fenster: Daten prüfen, Item → Raider, denen es fehlt, Vergaben seit dem Sync vorläufig dazurechnen (Zählregel und Bedarfsformel des Servers), Texte und Farben |
| `CouncilUI.lua` | Loot-Council-Fenster, Item-Tooltip, `/ehc` |
| `GuildBankData.lua` | Platzhalter; das Sync-Tool überschreibt ihn mit der Gildenbank-Ausgabeliste |
| `GuildBankHandouts.lua` | Ausgabe-Logik ohne Fenster: Daten prüfen, Banken dieses Charakters, Bestand und Fehlmenge, Abhaken (`guildBankDone`), API für die Post-Ausgabe |
| `GuildBankMail.lua` | Ausgabe per Post: Briefkasten erkennen, Taschen zählen, Brief ausfüllen und Anhänge planen/anhängen, Fallback bei gesperrtem Anhängen, Abhaken bei `MAIL_SEND_SUCCESS` |
| `GuildBankWithdraw.lua` | Aus der Gildenbank nehmen (Klick auf eine Zeile): Stapel live lesen, planen (Tageslimit), `AutoStoreGuildBankItem` / `SplitGuildBankItem`, Fallback bei Sperre |
| `GuildBankUI.lua` | Fenster „Gildenbank-Ausgabe", `/ehs bank`, `/ehb`, öffnet sich mit der Gildenbank und am Briefkasten (Post-Modus) |

Und im Sync-Tool:

| Datei | Aufgabe |
|---|---|
| `lib/luaParser.js` | SavedVariables als Daten lesen, nicht als Code ausführen |
| `lib/wowPaths.js` | die Addon-Datei über alle Client-Varianten und Accounts finden, ebenso die installierten Addon-Ordner |
| `lib/uploader.js` | eine Session pro Anfrage hochladen; Gildenbank-Scan lesen und hochladen |
| `lib/council.js` | Council-Daten holen, prüfen, als `CouncilData.lua` in jeden Addon-Ordner schreiben |
| `lib/guildbankHandouts.js` | Ausgabeliste holen, prüfen, als `GuildBankData.lua` schreiben; abgehakte Posten lesen und melden |
| `lib/runner.js` | der laufende Betrieb samt Zustand (letzter Upload, Fehler, Verlauf, Gildenbank, Council, Ausgabeliste) |
| `lib/appWindow.js` | das chromelose Edge/Chrome-Fenster, Hinweisdialoge der `.exe` |
| `lib/instance.js` | höchstens eine laufende Instanz; ein zweiter Start öffnet deren Fenster |
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

`sync/scripts/build-exe.js` nutzt Nodes eingebaute [Single Executable Applications](https://nodejs.org/api/single-executable-applications.html) statt eines externen Packers — das Verfahren gehört zu Node selbst und braucht keine Werkzeugkette mit eigener Versionspflege. Die Schritte: esbuild bündelt `index.js` samt `lib/` zu einer Datei, `node --experimental-sea-config` macht daraus einen Blob, `postject` spleisst ihn in eine Kopie der `node.exe`. Danach wird aus „Node.js" ein eigenes Programm (`scripts/exeResources.js`):

- **Icon und Versionsinfos** per [resedit](https://github.com/jet2jet/resedit-js) — Explorer, Taskleiste und Task-Manager zeigen „EventHelper Sync" mit eigenem Icon. Das geschieht bewusst *nach* postject: auf der unveränderten, signierten `node.exe` hinterlässt resedit eine Relocation-Tabelle, die postjects PE-Parser als beschädigt meldet.
- **PE-Subsystem Konsole → GUI.** Ein Konsolenprogramm bekommt beim Doppelklick immer ein Konsolenfenster, bevor JavaScript überhaupt läuft; nachträglich verstecken hiesse, es blitzt auf. Als GUI-Programm entsteht gar keins. Meldungen, die sonst in der Konsole stünden, zeigt die `.exe` als Dialog.

Das Icon liegt als `sync/assets/icon.svg` (Quelle) und `sync/assets/icon.ico` (eingecheckt, von `npm run build:icon` mit dem installierten Edge/Chrome gerendert). Dasselbe Motiv steckt als Favicon in `lib/webui-page.js` und ist damit das Icon des Fensters — beide gemeinsam ändern.

### Interface-Version

`EventHelperSync.toc` steht auf `## Interface: 20506, 16001` — eine Liste, die beide Clients lesen:

| Zahl | Client | Ordner |
|---|---|---|
| `20506` | TBC Anniversary (2.5.6, Classic-API) | `_anniversary_` |
| `16001` | WoW Forever (Retail/Midnight-Client, `WOW_PROJECT_MAINLINE`) | `_classic_beta_` |

Die TBC-Zahl stammt aus den `_TBC.toc` der aktuell installierten Addons (Gargul, WeakAuras, Details, Questie u.a. stehen dort alle auf `20506`, passend zum Client 2.5.6). Bei einem Client-Update reicht es, die Zahl anzupassen.

WoW Forever ist kein Classic-Client: dort fehlen `GetItemInfo`, `GetAddOnMetadata` und Co. (nur `C_Item`, `C_AddOns`), unbekannte Ereignisse werfen schon bei `RegisterEvent`, und die Schrift kennt nur Latin-1. Das Addon fragt deshalb jede Funktion ab, die es nicht auf beiden Clients gibt, meldet Ereignisse über `EHS:RegisterEvents()` (in `pcall`), nimmt für den Raid-Filter `MenuUtil` statt `UIDropDownMenu` und scrollt die Raid-Tabelle notfalls selbst, falls `FauxScrollFrame` fehlt. RCLootcouncil und Gargul dürfen dort fehlen — dann steht „nicht geladen" im Fenster, mehr passiert nicht.

---

## Lizenz

MIT
