# Test-FS25ModXml

![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-10%20%7C%2011%20%7C%20Server-0078D6?logo=windows&logoColor=white)
![Ohne externe Module](https://img.shields.io/badge/Abh%C3%A4ngigkeiten-keine-brightgreen)

Findet fehlerhafte XML-Dateien in Farming-Simulator-25-Mods — in entpackten Mod-Ordnern **und
in `.zip`-Mods** — und sagt dabei, **wo der Fehler wirklich anfängt**, nicht nur, wo der Parser
aufgibt.

Entstanden aus einem konkreten Problem: ein einzelner Mod verursachte XML-Parser-Fehler und
blockierte damit den nächtlichen Server-Reboot. Bei 300+ Mods und mehreren tausend XML-Dateien
ist Handarbeit keine Option.

## Warum nicht einfach ein XML-Parser?

Weil der Parser die falsche Zeile meldet. Ein nicht geschlossenes `<!--` verschluckt den
kompletten Rest der Datei — der Parser merkt das erst am Dateiende und zeigt dorthin:

```
Parser   Zeile 8, Spalte 1: Unexpected end of file while parsing Comment
Ursache  Zeile 4: Nicht geschlossener Kommentar
```

Der Parser zeigt auf Zeile 8. Der Fehler steht in Zeile 4. Bei einer 2400-Zeilen-Fahrzeug-XML
ist das der Unterschied zwischen „gefunden" und „eine Stunde gesucht".

## Schnellstart

Skript in den Ordner mit den Mods legen und starten — ohne `-Path` prüft es das Verzeichnis,
in dem es selbst liegt:

```powershell
.\Test-FS25ModXml.ps1
```

Damit ist der wöchentliche Modupdate-Ordner in einem Aufruf durch. Zips und entpackte Ordner
werden gemischt gefunden und gemeinsam geprüft:

```
FS25 XML-Pruefung
Verzeichnis : D:\Modupdate_KW29
Mods        : 5  (1 Ordner, 4 Zip)
```

Zips werden **gelesen, nicht entpackt**: jeder XML-Eintrag wird direkt aus dem Archiv geprüft.
Es wird nichts auf die Platte geschrieben und nichts verändert.

## Was geprüft wird

Jede XML läuft zuerst durch den .NET-`XmlReader` — eine echte Well-Formedness-Prüfung, keine
Heuristik. **Nur** bei Dateien, die dabei durchfallen, startet zusätzlich eine Detailanalyse,
die die Ursache benennt und lokalisiert:

| Befund | Beispiel |
|---|---|
| Nicht geschlossener Kommentar | `<!-- ...` ohne `-->` — meldet die Zeile des `<!--` |
| Verschachtelter Kommentar | `<!-- außen <!-- innen -->` |
| Trennlinien-Kommentar | `<!------- Motor ------->` — `--` ist im Kommentartext verboten |
| Fehlerhafter Kommentarabschluss | `<!-- Motor --->` statt `-->` |
| Nie geschlossenes Tag | `<base>` ohne `</base>` — meldet die Zeile des öffnenden Tags |
| Falsch verschachteltes Tag | `<a><b></a></b>` |
| Nicht geschlossener CDATA-Block | `<![CDATA[` ohne `]]>` |
| Mod ohne `modDesc.xml` | wird von FS25 gar nicht erst als Mod geladen |
| `modDesc.xml` im Unterordner des Zips | einmal zu viel gezippt — FS25 lädt den Mod nicht |
| Defektes Archiv | `.zip` lässt sich nicht öffnen, z.B. abgebrochener Download |

## Benutzung

```powershell
# Prüft das Verzeichnis, in dem das Skript liegt
.\Test-FS25ModXml.ps1

# Anderes Verzeichnis
.\Test-FS25ModXml.ps1 -Path 'C:\FS25\mods'

# Mit CSV-Report (die Konsole deckelt bei 6 Fundstellen pro Datei)
.\Test-FS25ModXml.ps1 -Path 'C:\FS25\mods' -CsvPath '.\xml-fehler.csv'
```

| Parameter | Bedeutung |
|---|---|
| `-Path` | Wurzelverzeichnis mit Mod-Ordnern und/oder `.zip`-Mods (Standard: Ordner des Skripts) |
| `-CsvPath` | schreibt alle Fundstellen als CSV (UTF-8, `;`-getrennt) |
| `-MaxHints` | Fundstellen pro Datei in der Konsole (Standard 6) |
| `-PassThru` | gibt die Befunde als Objekte auf die Pipeline |
| `-IncludeOk` | zeigt zusätzlich die Anzahl geprüfter Dateien |

Geprüft werden Mod-Ordner und `.zip`-Dateien direkt unterhalb des Wurzelverzeichnisses. Zips
*innerhalb* von Mod-Ordnern werden nicht geöffnet — die lädt FS25 auch nicht.

Bei einem Befund in einem Zip ist `Datei` der Pfad innerhalb des Archivs, `VollerPfad` schreibt
beides zusammen als `D:\mods\FS25_Foo.zip!vehicle.xml`, und die Spalte `Typ` unterscheidet
`Ordner` von `Zip`.

## Beispielausgabe

```
FS25 XML-Pruefung
Verzeichnis : C:\FS25\mods
Mods        : 325  (300 Ordner, 25 Zip)

------------------------------------------------------------------------------
Geprueft: 3899 XML-Dateien in 325 Mods  (13 s)
------------------------------------------------------------------------------

5 fehlerhafte XML-Datei(en) in 3 Mod(s):

  FS25_Fendt_800_Vario_TMS
    fendt800.xml
      Parser   Zeile 2348, Spalte 8: An XML comment cannot contain '--' ...
      Ursache  Zeile 2348: Trennlinien-Kommentar
               <!--- Lemken --->  ==> '--' ist im Kommentartext verboten.
               Fix: Bindestrichkette entfernen, z.B. '<!-- Lemken -->'.
      ...      und 4 weitere gleichartige Fundstelle(n) - vollstaendig via -CsvPath

  FS25_ManitouFB1900.zip
    modDesc.xml  [modDesc]
      Parser   Zeile 1, Spalte 16: Version number '1.1' is invalid.

Hinweis: 1 Eintrag/Eintraege ohne ladbare modDesc.xml (werden von FS25 nicht als Mod geladen):
  - FS25_Krone_BigX.zip: modDesc.xml liegt in 'FS25_Krone_BigX/' statt im Zip-Wurzelverzeichnis
```

## Automatisierung

| Exitcode | Bedeutung |
|---|---|
| 0 | keine Fehler |
| 1 | mindestens eine fehlerhafte XML |
| 2 | Pfad ungültig |

Damit lässt sich das Skript als Gate vor einen automatischen Reboot hängen:

```powershell
.\Test-FS25ModXml.ps1 -Path 'C:\FS25\mods' -CsvPath 'D:\logs\xml.csv'
if ($LASTEXITCODE -eq 0) { Restart-Server } else { Send-Alert }
```

Dateien **und** Archive werden mit `FileShare ReadWrite` geöffnet — der Scan funktioniert also
auch bei laufendem Server.

## Wie es funktioniert

Datei und Zip-Eintrag durchlaufen exakt denselben Code: die Prüfung arbeitet auf einem Stream,
die Detailanalyse auf dem eingelesenen Text. Es gibt keinen zweiten Codepfad für Archive, der
auseinanderlaufen könnte. Für die Detailanalyse einer fehlerhaften Datei wird der Zip-Eintrag
einfach ein zweites Mal geöffnet, statt das Archiv im Speicher zu puffern.

Der Kommentarscanner ist eine Zustandsmaschine, kein Regex: ein `<!--` innerhalb eines
CDATA-Blocks ist kein Kommentar und darf keinen Fehlalarm auslösen. Genau dafür gibt es eine
eigene Fixture.

## Tests

```powershell
.\tests\Invoke-Tests.ps1
```

`tests/fixtures/` enthält acht Mini-Mods: sechs mit je einem bekannten Defekt und zwei bewusst
fehlerfreie, darunter der CDATA-Fall. Getestet wird nicht nur, *ob* ein Fehler erkannt wird,
sondern auch dessen Art und Zeilennummer — denn genau die Zeilennummer ist der Mehrwert
gegenüber einem nackten Parser.

Derselbe Erwartungskatalog läuft zweimal: gegen die entpackten Fixture-Ordner und gegen daraus
erzeugte `.zip`-Mods. Die Zips baut der Test zur Laufzeit in einem Temp-Ordner — so liegen keine
Binärdateien im Repo, und beide Pfade liefern nachweislich dieselben Befunde. Dazu kommen zwei
Zip-Sonderfälle: einmal zu viel gezippt und ein defektes Archiv.

## Anforderungen

Windows PowerShell 5.1 oder PowerShell 7+. Keine externen Module. Getestet unter beiden.
