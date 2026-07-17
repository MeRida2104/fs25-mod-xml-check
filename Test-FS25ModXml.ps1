#Requires -Version 5.1
<#
.SYNOPSIS
    Prueft alle entpackten Farming-Simulator-25-Mods eines Verzeichnisses auf fehlerhafte XML-Dateien.

.DESCRIPTION
    Jede XML-Datei wird zuerst mit dem .NET-XmlReader auf Well-Formedness geprueft. Der Reader
    liefert Zeile, Spalte und Fehlermeldung.

    Schlaegt eine Datei fehl, laeuft zusaetzlich eine Detailanalyse, die die typischen Ursachen
    benennt und - das ist der eigentliche Mehrwert - die *Startzeile* des Problems findet:

      * Ein nicht geschlossenes "<!--" verschluckt den Rest der Datei. Der Parser meldet dann nur
        "unerwartetes Dateiende" in der letzten Zeile. Die Detailanalyse meldet stattdessen die
        Zeile, in der der Kommentar geoeffnet wurde.
      * Verschachtelte Kommentare ("<!--" innerhalb eines Kommentars).
      * "--" innerhalb eines Kommentars und Abschluesse wie "--->" (laut XML-Spezifikation verboten).
      * Nie geschlossene bzw. falsch verschachtelte Tags inklusive Zeile des oeffnenden Tags.

    Dateien werden mit FileShare ReadWrite geoeffnet, der Scan funktioniert also auch bei
    laufendem Server.

.PARAMETER Path
    Wurzelverzeichnis mit den entpackten Mod-Ordnern.

.PARAMETER CsvPath
    Optional. Schreibt alle Befunde zusaetzlich als CSV (UTF-8) in diese Datei.

.PARAMETER IncludeOk
    Optional. Listet am Ende auch die Anzahl der geprueften Dateien pro Mod auf.

.EXAMPLE
    .\Test-FS25ModXml.ps1

.EXAMPLE
    .\Test-FS25ModXml.ps1 -Path 'D:\FS25\mods' -CsvPath '.\xml-fehler.csv'

.NOTES
    Exitcode 0 = keine Fehler, 1 = mindestens eine fehlerhafte XML, 2 = Pfad ungueltig.
    Damit laesst sich das Skript vor dem naechtlichen Reboot als Gate einbauen.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Path = 'C:\Work_Dir\Mod_Script',

    [string]$CsvPath,

    [int]$MaxHints = 6,

    [switch]$IncludeOk,

    # Gibt die Befunde zusaetzlich als Objekte auf die Pipeline (fuer Tests / Weiterverarbeitung).
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------------------------------------
# Hilfsfunktionen
# ------------------------------------------------------------------------------------------------

# Index aller Zeilenanfaenge, um aus einem Zeichen-Offset eine Zeilennummer zu machen.
function Get-LineStartIndex {
    param([string]$Text)

    $starts = New-Object System.Collections.Generic.List[int]
    $starts.Add(0)
    $i = $Text.IndexOf("`n")
    while ($i -ge 0) {
        $starts.Add($i + 1)
        $i = $Text.IndexOf("`n", $i + 1)
    }
    return $starts.ToArray()
}

function ConvertTo-LineNumber {
    param([int[]]$LineStarts, [int]$CharIndex)

    $i = [Array]::BinarySearch($LineStarts, $CharIndex)
    if ($i -lt 0) { $i = (-$i) - 2 }
    return $i + 1
}

function New-Finding {
    param([string]$Kind, [int]$Line, [string]$Text)

    [pscustomobject]@{ Kind = $Kind; Line = $Line; Text = $Text }
}

# Schritt 1: Well-Formedness-Pruefung durch den echten XML-Parser.
function Test-XmlDocument {
    param([string]$FilePath, [System.Xml.XmlReaderSettings]$Settings)

    $stream = $null
    $reader = $null
    try {
        # FileShare ReadWrite: blockiert nicht, wenn der Server die Datei offen haelt.
        $stream = [System.IO.File]::Open($FilePath, [System.IO.FileMode]::Open,
                                         [System.IO.FileAccess]::Read,
                                         [System.IO.FileShare]::ReadWrite)
        $reader = [System.Xml.XmlReader]::Create($stream, $Settings)
        while ($reader.Read()) { }
        return [pscustomobject]@{ Ok = $true; Line = 0; Column = 0; Message = '' }
    }
    catch [System.Xml.XmlException] {
        $ex = $_.Exception
        return [pscustomobject]@{
            Ok      = $false
            Line    = $ex.LineNumber
            Column  = $ex.LinePosition
            Message = ($ex.Message -replace '\s+', ' ').Trim()
        }
    }
    catch {
        return [pscustomobject]@{
            Ok      = $false
            Line    = 0
            Column  = 0
            Message = "Datei nicht lesbar: $($_.Exception.Message)"
        }
    }
    finally {
        if ($reader) { $reader.Dispose() }
        if ($stream) { $stream.Dispose() }
    }
}

# Fasst einen kompletten, fehlerhaften Kommentar zu genau einem Befund zusammen.
# Ohne das meldet eine Trennlinie wie "<!----- Lemken ----->" ein halbes Dutzend Tokenfehler.
function New-CommentSummary {
    param(
        [string]$Text, [int[]]$LineStarts,
        [int]$Start, [int]$End,
        [int]$NestedLine, [int]$DashLine, [bool]$BadClose
    )

    if ($NestedLine -lt 0 -and $DashLine -lt 0 -and -not $BadClose) { return $null }

    $openLine = ConvertTo-LineNumber -LineStarts $LineStarts -CharIndex $Start
    $raw      = $Text.Substring($Start, $End - $Start)

    # Vorschau: Whitespace und lange Bindestrichketten zusammenfalten, sonst sprengt eine
    # 120 Zeichen lange Trennlinie die Ausgabe.
    $preview = [regex]::Replace(($raw -replace '\s+', ' '), '-{3,}', '---')
    if ($preview.Length -gt 60) { $preview = $preview.Substring(0, 60) + '...' }

    if ($NestedLine -ge 0) {
        return (New-Finding 'Verschachtelter Kommentar' $NestedLine `
            "Weiteres '<!--' innerhalb des in Zeile $openLine geoeffneten Kommentars. XML erlaubt keine Verschachtelung - der erste '-->' beendet bereits den ganzen Block.")
    }

    $line = if ($DashLine -ge 0) { $DashLine } else { $openLine }

    if ($raw -match '-{3,}') {
        return (New-Finding 'Trennlinien-Kommentar' $line `
            "$preview  ==> '--' ist im Kommentartext verboten. Fix: Bindestrichkette entfernen, z.B. '<!-- Lemken -->'.")
    }
    if ($BadClose) {
        return (New-Finding 'Fehlerhafter Kommentarabschluss' $line `
            "$preview  ==> endet mit '--->' statt '-->'. Ein '-' direkt vor dem Abschluss ist verboten.")
    }
    return (New-Finding 'Doppelter Bindestrich im Kommentar' $line `
        "$preview  ==> '--' innerhalb eines Kommentars ist laut XML-Spezifikation verboten.")
}

# Schritt 2a: Kommentar-Analyse ueber eine Zustandsmaschine.
# Erkennt Tokens statt blind zu regexen, damit "<!--" innerhalb von CDATA nicht falsch
# als Kommentarbeginn gewertet wird.
function Get-CommentFinding {
    param([string]$Text, [int[]]$LineStarts)

    $findings = New-Object System.Collections.Generic.List[object]

    # Reihenfolge ist wichtig: "-{2,}>" muss vor "--" stehen, damit "--->" als (fehlerhafter)
    # Kommentarabschluss erkannt wird und nicht als einzelnes "--".
    $tokenRegex = [regex]'<!--|-{2,}>|<!\[CDATA\[|\]\]>|--'

    $state        = 'Text'      # Text | Comment | CData
    $commentStart = -1
    $cdataStart   = -1
    $nestedLine   = -1
    $dashLine     = -1
    $badClose     = $false

    foreach ($m in $tokenRegex.Matches($Text)) {
        $tok = $m.Value

        switch ($state) {
            'Text' {
                if ($tok -eq '<!--') {
                    $state = 'Comment'; $commentStart = $m.Index
                    $nestedLine = -1; $dashLine = -1; $badClose = $false
                }
                elseif ($tok -eq '<![CDATA[') { $state = 'CData'; $cdataStart = $m.Index }
                # "-->", "--" und "]]>" ausserhalb eines Kommentars sind hier ohne Bedeutung.
            }

            'Comment' {
                if ($tok -eq '<!--') {
                    if ($nestedLine -lt 0) {
                        $nestedLine = ConvertTo-LineNumber -LineStarts $LineStarts -CharIndex $m.Index
                    }
                }
                elseif ($tok -match '^-{2,}>$') {
                    if ($tok.Length -gt 3) { $badClose = $true }
                    $summary = New-CommentSummary -Text $Text -LineStarts $LineStarts `
                                   -Start $commentStart -End ($m.Index + $m.Length) `
                                   -NestedLine $nestedLine -DashLine $dashLine -BadClose $badClose
                    if ($summary) { $findings.Add($summary) }
                    $state = 'Text'; $commentStart = -1
                }
                elseif ($tok -eq '--') {
                    if ($dashLine -lt 0) {
                        $dashLine = ConvertTo-LineNumber -LineStarts $LineStarts -CharIndex $m.Index
                    }
                }
                # CDATA-Marker innerhalb eines Kommentars sind reiner Text.
            }

            'CData' {
                if ($tok -eq ']]>') { $state = 'Text'; $cdataStart = -1 }
            }
        }
    }

    if ($state -eq 'Comment') {
        $findings.Add((New-Finding 'Nicht geschlossener Kommentar' `
            (ConvertTo-LineNumber -LineStarts $LineStarts -CharIndex $commentStart) `
            "'<!--' wird bis zum Dateiende nie durch '-->' geschlossen. Alles ab dieser Zeile wird vom Parser verschluckt."))
    }
    if ($state -eq 'CData') {
        $findings.Add((New-Finding 'Nicht geschlossener CDATA-Block' `
            (ConvertTo-LineNumber -LineStarts $LineStarts -CharIndex $cdataStart) `
            "'<![CDATA[' wird nie durch ']]>' geschlossen."))
    }

    return $findings
}

# Schritt 2b: Tag-Balance. Laeuft nur, wenn die Kommentarstruktur intakt ist - sonst wuerde
# der Scanner Tags innerhalb eines offenen Kommentars mitzaehlen und Unsinn melden.
function Get-TagFinding {
    param([string]$Text, [int[]]$LineStarts)

    $findings = New-Object System.Collections.Generic.List[object]

    # Kommentare / CDATA / PIs / DOCTYPE werden als Ganzes geschluckt, damit darin enthaltene
    # spitze Klammern nicht als Tags zaehlen. Attributwerte in Anfuehrungszeichen ebenso.
    $structRegex = [regex]'(?s)<!--.*?-->|<!\[CDATA\[.*?\]\]>|<\?.*?\?>|<!DOCTYPE[^>]*>|<(?<close>/?)(?<name>[A-Za-z_][A-Za-z0-9_.\-:]*)(?<attrs>(?:"[^"]*"|''[^'']*''|/(?!>)|[^>"''/])*)(?<self>/?)>'

    $stack = New-Object System.Collections.Generic.List[object]

    foreach ($m in $structRegex.Matches($Text)) {
        if (-not $m.Groups['name'].Success) { continue }   # Kommentar / CDATA / PI / DOCTYPE

        $name = $m.Groups['name'].Value
        $line = ConvertTo-LineNumber -LineStarts $LineStarts -CharIndex $m.Index

        if ($m.Groups['close'].Value -eq '/') {
            if ($stack.Count -eq 0) {
                $findings.Add((New-Finding 'Schliessendes Tag ohne oeffnendes' $line `
                    "</$name> geschlossen, aber kein passendes <$name> offen."))
            }
            else {
                $top = $stack[$stack.Count - 1]
                if ($top.Name -ne $name) {
                    $findings.Add((New-Finding 'Falsch verschachteltes Tag' $line `
                        "</$name> gefunden, erwartet wurde </$($top.Name)> (geoeffnet in Zeile $($top.Line))."))
                    return $findings   # ab hier ist der Stack unbrauchbar, Folgefehler waeren Rauschen
                }
                $stack.RemoveAt($stack.Count - 1)
            }
        }
        elseif ($m.Groups['self'].Value -ne '/') {
            $stack.Add([pscustomobject]@{ Name = $name; Line = $line })
        }
    }

    foreach ($open in $stack) {
        $findings.Add((New-Finding 'Nie geschlossenes Tag' $open.Line `
            "<$($open.Name)> wird bis zum Dateiende nie geschlossen."))
    }

    return $findings
}

# Klammert 2a + 2b und liest die Datei als Text ein.
function Get-XmlHint {
    param([string]$FilePath)

    $findings = New-Object System.Collections.Generic.List[object]
    try {
        $stream = [System.IO.File]::Open($FilePath, [System.IO.FileMode]::Open,
                                         [System.IO.FileAccess]::Read,
                                         [System.IO.FileShare]::ReadWrite)
        try {
            $sr   = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
            $text = $sr.ReadToEnd()
            $sr.Dispose()
        }
        finally { $stream.Dispose() }
    }
    catch {
        return $findings
    }

    $lineStarts = Get-LineStartIndex -Text $text

    $commentFindings = Get-CommentFinding -Text $text -LineStarts $lineStarts
    foreach ($f in $commentFindings) { $findings.Add($f) }

    $commentBroken = $commentFindings | Where-Object { $_.Kind -like 'Nicht geschlossener*' }
    if (-not $commentBroken) {
        foreach ($f in (Get-TagFinding -Text $text -LineStarts $lineStarts) ) { $findings.Add($f) }
    }

    # Entprellen: eine Trennlinie wie "<!-- ---- Motor ---- -->" wuerde denselben Befund
    # sonst mehrfach pro Zeile melden.
    $seen  = New-Object System.Collections.Generic.HashSet[string]
    $uniq  = New-Object System.Collections.Generic.List[object]
    foreach ($f in $findings) {
        if ($seen.Add("$($f.Kind)|$($f.Line)")) { $uniq.Add($f) }
    }

    return $uniq
}

# ------------------------------------------------------------------------------------------------
# Hauptlauf
# ------------------------------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    Write-Host "Verzeichnis nicht gefunden: $Path" -ForegroundColor Red
    exit 2
}
$root = (Resolve-Path -LiteralPath $Path).ProviderPath

$settings = New-Object System.Xml.XmlReaderSettings
$settings.DtdProcessing    = [System.Xml.DtdProcessing]::Ignore   # keine externen DTDs nachladen
$settings.XmlResolver      = $null                                # keine Netzwerkzugriffe
$settings.IgnoreComments   = $false                               # Kommentarfehler sollen auffallen
$settings.IgnoreWhitespace = $true
$settings.CheckCharacters  = $true
$settings.ConformanceLevel = [System.Xml.ConformanceLevel]::Document

$modDirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name)

Write-Host ''
Write-Host "FS25 XML-Pruefung" -ForegroundColor Cyan
Write-Host "Verzeichnis : $root"
Write-Host "Mod-Ordner  : $($modDirs.Count)"
Write-Host ''

$results   = New-Object System.Collections.Generic.List[object]
$noModDesc = New-Object System.Collections.Generic.List[string]
$fileCount = 0
$modIndex  = 0
$sw        = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($mod in $modDirs) {
    $modIndex++
    Write-Progress -Activity 'XML-Pruefung' -Status "$($mod.Name)  ($modIndex/$($modDirs.Count))" `
                   -PercentComplete (($modIndex / [Math]::Max($modDirs.Count, 1)) * 100)

    $xmlFiles = @(Get-ChildItem -LiteralPath $mod.FullName -Recurse -File -Filter '*.xml' -ErrorAction SilentlyContinue)

    if (-not (Test-Path -LiteralPath (Join-Path $mod.FullName 'modDesc.xml'))) {
        $noModDesc.Add($mod.Name)
    }

    foreach ($file in $xmlFiles) {
        $fileCount++
        $check = Test-XmlDocument -FilePath $file.FullName -Settings $settings
        if ($check.Ok) { continue }

        $hints = Get-XmlHint -FilePath $file.FullName

        $results.Add([pscustomobject]@{
            Mod           = $mod.Name
            Datei         = $file.FullName.Substring($mod.FullName.Length + 1)
            IstModDesc    = ($file.Name -eq 'modDesc.xml')
            Zeile         = $check.Line
            Spalte        = $check.Column
            ParserFehler  = $check.Message
            Ursachen      = $hints
            VollerPfad    = $file.FullName
        })
    }
}

Write-Progress -Activity 'XML-Pruefung' -Completed
$sw.Stop()

# ------------------------------------------------------------------------------------------------
# Ausgabe
# ------------------------------------------------------------------------------------------------

Write-Host ("-" * 96) -ForegroundColor DarkGray
Write-Host "Geprueft: $fileCount XML-Dateien in $($modDirs.Count) Mods  ($([math]::Round($sw.Elapsed.TotalSeconds,1)) s)"
Write-Host ("-" * 96) -ForegroundColor DarkGray
Write-Host ''

if ($results.Count -eq 0) {
    Write-Host "Keine XML-Fehler gefunden. Alle Dateien sind well-formed." -ForegroundColor Green
}
else {
    $brokenMods = $results | Group-Object Mod | Sort-Object Name

    Write-Host "$($results.Count) fehlerhafte XML-Datei(en) in $($brokenMods.Count) Mod(s):" -ForegroundColor Red
    Write-Host ''

    foreach ($group in $brokenMods) {
        Write-Host "  $($group.Name)" -ForegroundColor Yellow

        foreach ($r in $group.Group) {
            $tag = if ($r.IstModDesc) { '  [modDesc]' } else { '' }
            Write-Host "    $($r.Datei)$tag" -ForegroundColor White

            if ($r.Zeile -gt 0) {
                Write-Host "      Parser   Zeile $($r.Zeile), Spalte $($r.Spalte): $($r.ParserFehler)" -ForegroundColor Red
            }
            else {
                Write-Host "      Parser   $($r.ParserFehler)" -ForegroundColor Red
            }

            $shown = 0
            foreach ($h in $r.Ursachen) {
                if ($shown -ge $MaxHints) {
                    $rest = $r.Ursachen.Count - $MaxHints
                    Write-Host "      ...      und $rest weitere gleichartige Fundstelle(n) - vollstaendig via -CsvPath" -ForegroundColor DarkGray
                    break
                }
                Write-Host "      Ursache  Zeile $($h.Line): $($h.Kind)" -ForegroundColor Magenta
                Write-Host "               $($h.Text)" -ForegroundColor DarkGray
                $shown++
            }
            Write-Host ''
        }
    }

    Write-Host ("-" * 96) -ForegroundColor DarkGray
    Write-Host 'Kompakt:' -ForegroundColor Cyan

    # Bewusst ueber Write-Host statt Out-Host: so laesst sich die komplette Konsolenausgabe
    # einheitlich per 6>$null unterdruecken, waehrend -PassThru nur die Objekte liefert.
    $table = $results |
        Select-Object Mod,
                      Datei,
                      Zeile,
                      @{ n = 'Ursache'; e = {
                            if ($_.Ursachen.Count -gt 0) {
                                "$($_.Ursachen[0].Kind) (Zeile $($_.Ursachen[0].Line))"
                            } else { $_.ParserFehler }
                      } } |
        Format-Table -AutoSize -Wrap |
        Out-String
    Write-Host $table
}

if ($noModDesc.Count -gt 0) {
    Write-Host ''
    Write-Host "Hinweis: $($noModDesc.Count) Ordner ohne modDesc.xml (werden von FS25 nicht als Mod geladen):" -ForegroundColor DarkYellow
    foreach ($n in $noModDesc) { Write-Host "  - $n" -ForegroundColor DarkGray }
}

if ($CsvPath) {
    $flat = foreach ($r in $results) {
        if ($r.Ursachen.Count -eq 0) {
            [pscustomobject]@{
                Mod = $r.Mod; Datei = $r.Datei; ParserZeile = $r.Zeile; ParserSpalte = $r.Spalte
                ParserFehler = $r.ParserFehler; UrsacheArt = ''; UrsacheZeile = ''; UrsacheText = ''
                VollerPfad = $r.VollerPfad
            }
        }
        else {
            foreach ($h in $r.Ursachen) {
                [pscustomobject]@{
                    Mod = $r.Mod; Datei = $r.Datei; ParserZeile = $r.Zeile; ParserSpalte = $r.Spalte
                    ParserFehler = $r.ParserFehler; UrsacheArt = $h.Kind; UrsacheZeile = $h.Line
                    UrsacheText = $h.Text; VollerPfad = $r.VollerPfad
                }
            }
        }
    }
    $flat | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8 -Delimiter ';'
    Write-Host ''
    Write-Host "CSV geschrieben: $CsvPath" -ForegroundColor Cyan
}

if ($IncludeOk) {
    Write-Host ''
    Write-Host "Gepruefte Dateien gesamt: $fileCount" -ForegroundColor DarkGray
}

if ($PassThru) { $results }

exit $(if ($results.Count -gt 0) { 1 } else { 0 })
