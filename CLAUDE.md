# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Projekt

`Test-FS25ModXml.ps1` ist ein eigenständiges PowerShell-Werkzeug, das Farming-Simulator-25-Mods
(entpackte Ordner **und** `.zip`) auf fehlerhafte XML prüft — primär als Gate vor dem nächtlichen
Server-Reboot. Kein Build, keine externen Module; läuft unter Windows PowerShell 5.1 und
PowerShell 7+. Sprache im Repo (Code-Kommentare, README, Commits) ist Deutsch.

## Befehle

```powershell
# Prüft das Verzeichnis, in dem das Skript liegt (ohne -Path)
.\Test-FS25ModXml.ps1

# Mod-Ordner + aktives Savegame, mit CSV-Report
.\Test-FS25ModXml.ps1 -Path 'C:\FS25\mods' -SavegamePath 'C:\FS25\savegame1' -CsvPath '.\xml.csv'

# Komplette Testsuite (Ordner- und Zip-Durchgang + Savegame-Durchgang)
.\tests\Invoke-Tests.ps1
```

Einen einzelnen Fall prüfen: Es gibt kein Test-Filter-Flag. Entweder eine Fixture direkt scannen
(`.\Test-FS25ModXml.ps1 -Path .\tests\fixtures\FS25_MissingRef`) oder die `$expected`-Tabelle in
`tests/Invoke-Tests.ps1` temporär kürzen.

Exitcodes: `0` sauber, `1` mindestens ein XML-**Parserfehler** (Mods oder Savegame), `2` Pfad
ungültig. **Verweis-Hinweise setzen den Exitcode bewusst NICHT** — nur echte Parserfehler blockieren
den Reboot-Gate.

## Architektur

Alles in einer Datei (`Test-FS25ModXml.ps1`), bewusst ohne Module, damit es auf einem Server ohne
Setup läuft. Dateien und Archive werden mit `FileShare ReadWrite` geöffnet → der Scan funktioniert
auch bei laufendem Server. Zip-Einträge werden gelesen, nie entpackt.

**Zwei-Phasen-Prüfung pro XML:**
1. Well-Formedness über den echten `System.Xml.XmlReader` (`Test-XmlStream`). Schnell, keine Heuristik.
2. Nur bei Durchfallern läuft die **Detailanalyse** (`Get-XmlHint` → `Get-CommentFinding` +
   `Get-TagFinding`). Deren einziger Zweck ist die *Startzeile* des Fehlers: bei einem nicht
   geschlossenen `<!--` meldet der Parser nur das Dateiende, nicht die Zeile des `<!--`. Genau
   diese Zeilennummer ist der Mehrwert des Werkzeugs — und wird in den Tests mitgeprüft.

**Ein gemeinsamer Codepfad für Ordner und Zip:** die Prüf-/Analysefunktionen arbeiten auf einem
Stream bzw. dem eingelesenen Text; `Invoke-FolderScan` und `Invoke-ZipScan` füttern beide denselben
Code. Kein zweiter Codepfad für Archive, der auseinanderlaufen könnte.

**Verweisprüfung** (`Get-ReferenceFinding`) — läuft nur auf *wohlgeformten* Dateien und nur wenn
`modDesc.xml` im Wurzelverzeichnis liegt (sonst ist die Mod-Wurzel unbestimmbar):
- extrahiert per Regex Attribut-/Elementwerte, die auf eine Asset-Endung enden (`$script:RefExtensions`);
- löst gegen **zwei Basen** auf: Mod-Wurzel *und* Ordner der XML selbst — Fahrzeug-/modDesc-XMLs
  verweisen relativ zur Wurzel, Foliage-/Map-XMLs relativ zum eigenen Ordner. `$Present` ist ein
  Dict `lower(relpath)` → Originalpfad (für den Groß-/Kleinschreibungs-Check);
- `.png`/`.dds`/`.grle` und `.wav`/`.ogg` gelten als austauschbar (`$script:InterchangeableGroups`
  + `Get-AltKeys`) — ein neues Paar ist eine Zeile;
- `Hide-XmlCommentsAndCData` blendet auskommentierte und CDATA-Verweise vorher aus (durch
  Leerzeichen ersetzt, Zeilenumbrüche bleiben → Zeichen-Offsets und damit Zeilennummern stimmen);
- `Test-IsResolvableRef` überspringt `$data`/`data/`, Platzhalter, URLs, absolute und `..`-Pfade;
- Funde (`Fehlende Datei`, `Gross-/Kleinschreibung`) sind **Hinweise ohne Exitcode-Einfluss** — im
  realen Serverlog verhinderte eine fehlende referenzierte Datei den Start nicht.

**Ergebnis-Modell:** jede auffällige Datei wird zu einem Result-Objekt mit `ParserFehler`/`Zeile`
(harter Fehler) und/oder `Ursachen` (Liste aus Detailanalyse- und Verweis-Funden). Ausgabe und
Exitcode trennen harte Parserfehler (`ParserFehler` gesetzt oder `Zeile > 0`) von Verweis-Hinweisen.

**Savegame-Modus** (`-SavegamePath`): ruft `Invoke-FolderScan` mit
`-CheckModDesc:$false -CheckReferences:$false -Typ 'Savegame'` — reine Well-Formedness der
Savegame-XMLs; ein Parserfehler dort setzt den Exitcode auf 1. Motivation: ein durch harten Stopp
halb geschriebenes Savegame ist eine Hauptursache für „Server stoppt, startet aber nicht mehr".

## Tests & Fixtures

`tests/fixtures/` enthält Mini-Mods mit je genau einem bekannten Defekt oder bewusst sauber.
`tests/Invoke-Tests.ps1` prüft über die `$expected`-Tabelle **Art und Zeilennummer** jedes Befunds
und läuft zweimal: gegen die Ordner-Fixtures und gegen zur Laufzeit erzeugte `.zip`-Kopien (damit
keine Binärdateien im Repo liegen und beide Pfade nachweislich dieselben Befunde liefern). Neue
Verhaltensweise → Fixture anlegen **und** Zeile in `$expected` ergänzen.

**Zeilenenden sind load-bearing:** die erwarteten Zeilennummern hängen an den Zeilenenden der
Fixtures. `.gitattributes` pinnt deshalb `tests/fixtures/** -text` (nicht normalisieren). Außerdem:
`*.ps1` → `eol=crlf`, `*.md` → `eol=lf`.
