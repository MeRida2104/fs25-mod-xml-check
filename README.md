# Test-FS25ModXml

PowerShell-Skript, das einen Farming-Simulator-25-Mod-Ordner nach fehlerhaften XML-Dateien
durchsucht — und dabei sagt, **wo** der Fehler wirklich anfängt, nicht nur wo der Parser
aufgibt.

Entstanden aus einem konkreten Problem: ein Mod verursachte XML-Parser-Fehler und blockierte
damit den nächtlichen Server-Reboot. Bei 300+ entpackten Mods und mehreren tausend XML-Dateien
ist Handarbeit keine Option.

## Das eigentliche Problem

Ein nicht geschlossenes `<!--` verschluckt den kompletten Rest der Datei. Der Parser meldet
deshalb nur ein „unerwartetes Dateiende" — in der **letzten** Zeile:

```
Parser   Zeile 8, Spalte 1: Unexpected end of file while parsing Comment
Ursache  Zeile 4: Nicht geschlossener Kommentar
```

Die Parser-Meldung zeigt auf Zeile 8. Der Fehler steht in Zeile 4. Bei einer 2400-Zeilen-
Fahrzeug-XML ist das der Unterschied zwischen „gefunden" und „eine Stunde gesucht".

## Was geprüft wird

Zuerst läuft jede XML durch den .NET-`XmlReader` (echte Well-Formedness-Prüfung, keine
Heuristik). **Nur** bei Dateien, die dabei durchfallen, startet zusätzlich eine Detailanalyse,
die die Ursache benennt und lokalisiert:

| Befund | Beispiel |
|---|---|
| Nicht geschlossener Kommentar | `<!-- ...` ohne `-->` — meldet die Zeile des `<!--` |
| Verschachtelter Kommentar | `<!-- außen <!-- innen --> ` |
| Trennlinien-Kommentar | `<!------- Motor ------->` — `--` ist im Kommentartext verboten |
| Fehlerhafter Kommentarabschluss | `<!-- Motor --->` statt `-->` |
| Nie geschlossenes Tag | `<base>` ohne `</base>` — meldet die Zeile des öffnenden Tags |
| Falsch verschachteltes Tag | `<a><b></a></b>` |
| Nicht geschlossener CDATA-Block | `<![CDATA[` ohne `]]>` |
| Ordner ohne `modDesc.xml` | wird von FS25 gar nicht erst als Mod geladen |

Der Kommentarscanner ist eine Zustandsmaschine, kein Regex: ein `<!--` innerhalb eines
CDATA-Blocks ist kein Kommentar und darf keinen Fehlalarm auslösen. Genau dafür gibt es
eine Fixture.

## Benutzung

```powershell
# Standardlauf
.\Test-FS25ModXml.ps1 -Path 'C:\FS25\mods'

# Mit CSV-Report (die Konsole deckelt bei 6 Fundstellen pro Datei)
.\Test-FS25ModXml.ps1 -Path 'C:\FS25\mods' -CsvPath '.\xml-fehler.csv'
```

| Parameter | Bedeutung |
|---|---|
| `-Path` | Wurzelverzeichnis mit den entpackten Mod-Ordnern |
| `-CsvPath` | schreibt alle Fundstellen als CSV (UTF-8, `;`-getrennt) |
| `-MaxHints` | Fundstellen pro Datei in der Konsole (Standard 6) |
| `-PassThru` | gibt die Befunde als Objekte auf die Pipeline |
| `-IncludeOk` | zeigt zusätzlich die Anzahl geprüfter Dateien |

Nur entpackte Ordner werden gescannt, keine `.zip`-Mods.

## Exitcodes

| Code | Bedeutung |
|---|---|
| 0 | keine Fehler |
| 1 | mindestens eine fehlerhafte XML |
| 2 | Pfad ungültig |

Damit lässt sich das Skript als Gate vor einen automatischen Reboot hängen:

```powershell
.\Test-FS25ModXml.ps1 -Path 'C:\FS25\mods' -CsvPath 'D:\logs\xml.csv'
if ($LASTEXITCODE -eq 0) { Restart-Server } else { Send-Alert }
```

Die Dateien werden mit `FileShare ReadWrite` geöffnet — der Scan funktioniert also auch bei
laufendem Server.

## Beispielausgabe

```
FS25 XML-Pruefung
Verzeichnis : C:\FS25\mods
Mod-Ordner  : 325

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

  FS25_ManitouFB1900
    modDesc.xml  [modDesc]
      Parser   Zeile 1, Spalte 16: Version number '1.1' is invalid.
```

## Tests

```powershell
.\tests\Invoke-Tests.ps1
```

`tests/fixtures/` enthält acht Mini-Mods mit je einem bekannten Defekt — plus zwei bewusst
fehlerfreie, darunter der CDATA-Fall. Getestet wird nicht nur *ob* ein Fehler erkannt wird,
sondern auch dessen Art und Zeilennummer.

## Anforderungen

PowerShell 5.1 oder neuer. Keine externen Module.
