#Requires -Version 5.1
<#
.SYNOPSIS
    Prueft alle Farming-Simulator-25-Mods eines Verzeichnisses auf fehlerhafte XML-Dateien -
    entpackte Mod-Ordner ebenso wie gezippte Mods.

.DESCRIPTION
    Ohne -Path prueft das Skript das Verzeichnis, in dem es selbst liegt. Fuer den typischen
    Fall "Modupdate-Ordner voller .zip" genuegt es also, das Skript hineinzulegen und zu starten.

    Gefunden werden:
      * entpackte Mod-Ordner direkt unterhalb des Wurzelverzeichnisses
      * .zip-Mods direkt im Wurzelverzeichnis

    Zips werden gelesen, nicht entpackt: jeder XML-Eintrag wird direkt aus dem Archiv geprueft.
    Es wird nichts auf die Platte geschrieben und nichts veraendert.

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

    Zusaetzlich wird gemeldet, wenn ein Mod keine ladbare modDesc.xml hat - beim Zip auch dann,
    wenn sie zwar existiert, aber im Unterordner statt im Archiv-Wurzelverzeichnis liegt (der
    klassische "einmal zu viel gezippt"-Fehler; FS25 laedt so einen Mod gar nicht erst).

    Ueber die reine XML-Syntax hinaus werden bei wohlgeformten Dateien die *Dateiverweise*
    geprueft: zeigt ein <i3dFilename>, <filename>, iconFilename o.ae. auf eine Datei, die im
    Mod nicht existiert (typischer "Error: Failed to open xml file ..."), wird das als Hinweis
    gemeldet - ebenso eine nur in der Gross-/Kleinschreibung abweichende Datei, die im Zip und
    auf Linux-Servern zum Ladefehler wird. Verweise ins Basisspiel ($data, data/) sowie mit
    Platzhaltern ($, %) werden ausgelassen, weil sie sich nicht statisch aufloesen lassen.
    Diese Verweis-Hinweise setzen den Exitcode NICHT auf 1 - nur echte XML-Parserfehler tun das.

    Dateien und Archive werden mit FileShare ReadWrite geoeffnet, der Scan funktioniert also auch
    bei laufendem Server.

.PARAMETER Path
    Wurzelverzeichnis mit den Mod-Ordnern und/oder .zip-Mods.
    Standard: das Verzeichnis, in dem dieses Skript liegt.

.PARAMETER CsvPath
    Optional. Schreibt alle Befunde zusaetzlich als CSV (UTF-8) in diese Datei.

.PARAMETER SavegamePath
    Optional. Prueft zusaetzlich alle XML-Dateien eines Savegame-Verzeichnisses auf
    Wohlgeformtheit (vehicles.xml, items.xml, farms.xml ...). Ein durch einen harten Stopp
    halb geschriebenes Savegame ist eine der Hauptursachen dafuer, dass der Server zwar
    stoppt, aber nicht mehr laedt. Verweispruefung laeuft hier bewusst nicht.

.PARAMETER SkipReferenceCheck
    Optional. Schaltet die Verweispruefung ab (fehlende / falsch geschriebene Dateien).

.PARAMETER IncludeOk
    Optional. Listet am Ende auch die Anzahl der geprueften Dateien auf.

.EXAMPLE
    .\Test-FS25ModXml.ps1

.EXAMPLE
    .\Test-FS25ModXml.ps1 -Path 'D:\FS25\modupdate' -CsvPath '.\xml-fehler.csv'

.NOTES
    Exitcode 0 = keine Fehler, 1 = mindestens eine fehlerhafte XML, 2 = Pfad ungueltig.
    Damit laesst sich das Skript vor dem naechtlichen Reboot als Gate einbauen.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Path,

    [string]$CsvPath,

    # Zusaetzlich das aktive Savegame-Verzeichnis auf wohlgeformte XML pruefen. Ein durch einen
    # harten Stopp korruptes Savegame ist eine der Hauptursachen fuer "stoppt, startet nicht mehr".
    [string]$SavegamePath,

    # Verweise auf fehlende / falsch geschriebene Dateien (i3d, xml, dds ...) nicht pruefen.
    [switch]$SkipReferenceCheck,

    [int]$MaxHints = 6,

    [switch]$IncludeOk,

    # Gibt die Befunde zusaetzlich als Objekte auf die Pipeline (fuer Tests / Weiterverarbeitung).
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'

# Unter Windows PowerShell muessen die Zip-Typen erst geladen werden; unter PowerShell 7 sind
# sie bereits da und Add-Type ist ein No-Op.
try {
    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
}
catch { }

# ------------------------------------------------------------------------------------------------
# Hilfsfunktionen: Lesen
# ------------------------------------------------------------------------------------------------

# Liest einen Stream als Text. Der StreamReader erkennt die Kodierung am BOM und schliesst den
# Stream anschliessend selbst.
function Read-StreamText {
    param([System.IO.Stream]$Stream)

    $sr = New-Object System.IO.StreamReader($Stream, [System.Text.Encoding]::UTF8, $true)
    try { return $sr.ReadToEnd() }
    finally { $sr.Dispose() }
}

# FileShare ReadWrite: blockiert nicht, wenn der Server die Datei offen haelt.
function Open-SharedFile {
    param([string]$FilePath)

    return [System.IO.File]::Open($FilePath, [System.IO.FileMode]::Open,
                                  [System.IO.FileAccess]::Read,
                                  [System.IO.FileShare]::ReadWrite)
}

function Read-FileText {
    param([string]$FilePath)

    try { return (Read-StreamText -Stream (Open-SharedFile -FilePath $FilePath)) }
    catch { return $null }
}

function Read-ZipEntryText {
    param([System.IO.Compression.ZipArchiveEntry]$Entry)

    try { return (Read-StreamText -Stream $Entry.Open()) }
    catch { return $null }
}

# ------------------------------------------------------------------------------------------------
# Hilfsfunktionen: Analyse
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

function New-CheckResult {
    param([bool]$Ok, [int]$Line = 0, [int]$Column = 0, [string]$Message = '')

    [pscustomobject]@{ Ok = $Ok; Line = $Line; Column = $Column; Message = $Message }
}

# Schritt 1: Well-Formedness-Pruefung durch den echten XML-Parser.
# Arbeitet auf einem Stream, damit Datei und Zip-Eintrag denselben Code benutzen.
function Test-XmlStream {
    param([System.IO.Stream]$Stream, [System.Xml.XmlReaderSettings]$Settings)

    $reader = $null
    try {
        $reader = [System.Xml.XmlReader]::Create($Stream, $Settings)
        while ($reader.Read()) { }
        return (New-CheckResult -Ok $true)
    }
    catch [System.Xml.XmlException] {
        $ex = $_.Exception
        return (New-CheckResult -Ok $false -Line $ex.LineNumber -Column $ex.LinePosition `
                                -Message (($ex.Message -replace '\s+', ' ').Trim()))
    }
    catch {
        return (New-CheckResult -Ok $false -Message "Nicht lesbar: $($_.Exception.Message)")
    }
    finally {
        if ($reader) { $reader.Dispose() }
    }
}

function Test-XmlFile {
    param([string]$FilePath, [System.Xml.XmlReaderSettings]$Settings)

    $stream = $null
    try {
        $stream = Open-SharedFile -FilePath $FilePath
        return (Test-XmlStream -Stream $stream -Settings $Settings)
    }
    catch {
        return (New-CheckResult -Ok $false -Message "Datei nicht lesbar: $($_.Exception.Message)")
    }
    finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Test-XmlZipEntry {
    param([System.IO.Compression.ZipArchiveEntry]$Entry, [System.Xml.XmlReaderSettings]$Settings)

    $stream = $null
    try {
        # Im Read-Modus laesst sich derselbe Eintrag spaeter fuer die Detailanalyse erneut
        # oeffnen - deshalb muss das Archiv nicht im Speicher gepuffert werden.
        $stream = $Entry.Open()
        return (Test-XmlStream -Stream $stream -Settings $Settings)
    }
    catch {
        return (New-CheckResult -Ok $false -Message "Zip-Eintrag nicht lesbar: $($_.Exception.Message)")
    }
    finally {
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

# Klammert 2a + 2b. Arbeitet auf dem bereits eingelesenen Text, damit Datei und Zip-Eintrag
# denselben Code benutzen.
function Get-XmlHint {
    param([string]$Text)

    $findings = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrEmpty($Text)) { return $findings }

    $lineStarts = Get-LineStartIndex -Text $Text

    $commentFindings = Get-CommentFinding -Text $Text -LineStarts $lineStarts
    foreach ($f in $commentFindings) { $findings.Add($f) }

    $commentBroken = $commentFindings | Where-Object { $_.Kind -like 'Nicht geschlossener*' }
    if (-not $commentBroken) {
        foreach ($f in (Get-TagFinding -Text $Text -LineStarts $lineStarts) ) { $findings.Add($f) }
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
# Hilfsfunktionen: Verweispruefung (fehlende / falsch geschriebene Dateien)
# ------------------------------------------------------------------------------------------------

# Bekannte Asset-Endungen. Nur Werte, die auf eine davon enden, gelten als Dateiverweis - so
# fallen Node-Pfade ("0>1|2"), Zahlen und normaler Text von selbst raus.
$script:RefExtensions = @('i3d','xml','dds','png','grle','gdm','cache','shapes','lua','wav','ogg','anim','gls')

# Laesst sich ein Verweis ueberhaupt statisch gegen den Mod aufloesen? Basisspiel-, Platzhalter-,
# URL- und absolute Pfade werden ausgelassen, damit keine Fehlalarme entstehen.
function Test-IsResolvableRef {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($Path -match '[\$%*?<>|]')        { return $false }   # Variablen / Platzhalter / Wildcards
    if ($Path -match '://')               { return $false }   # URL
    if ($Path -match '^[A-Za-z]:[\\/]')   { return $false }   # C:\...
    if ($Path -match '^[\\/]')            { return $false }   # /... (absolut)
    if ($Path -match '^data/')            { return $false }   # zeigt ins Basisspiel, nicht in den Mod
    if ($Path -match '(^|/)\.\.(/|$)')    { return $false }   # ../ laesst sich nicht sicher aufloesen

    return $true
}

# Endungen, die die Engine als austauschbar behandelt: Mods referenzieren oft die eine, liefern
# aber die andere aus (die Engine loest das automatisch auf). Innerhalb einer Gruppe gilt jede
# Endung als gleichwertig.
$script:InterchangeableGroups = @(
    @('png', 'dds', 'grle'),   # Texturen / Icons / Masken
    @('wav', 'ogg')            # Sounds
)

# Liefert zu einem kleingeschriebenen Schluessel alle gleichwertigen Alternativen (gleicher Pfad,
# andere Endung derselben Gruppe).
function Get-AltKeys {
    param([string]$Key)

    $alts = New-Object System.Collections.Generic.List[string]
    $dot  = $Key.LastIndexOf('.')
    if ($dot -lt 0) { return $alts }

    $base = $Key.Substring(0, $dot)
    $ext  = $Key.Substring($dot + 1)

    foreach ($group in $script:InterchangeableGroups) {
        if ($group -contains $ext) {
            foreach ($other in $group) {
                if ($other -ne $ext) { $alts.Add("$base.$other") }
            }
        }
    }
    return $alts
}

# Blendet Kommentare und CDATA aus, indem ihr Inhalt durch Leerzeichen ersetzt wird (Zeilen-
# umbrueche bleiben erhalten). So zaehlen auskommentierte Verweise nicht als Datei, und weil die
# Zeichen-Offsets unveraendert bleiben, stimmen die gemeldeten Zeilennummern weiterhin.
# Laeuft nur auf wohlgeformten Dateien - dort sind Kommentare/CDATA immer sauber geschlossen.
function Hide-XmlCommentsAndCData {
    param([string]$Text)

    $rx = [regex]'(?s)<!--.*?-->|<!\[CDATA\[.*?\]\]>'
    $ev = [System.Text.RegularExpressions.MatchEvaluator] { param($m) $m.Value -replace '[^\r\n]', ' ' }
    return $rx.Replace($Text, $ev)
}

# Prueft die Dateiverweise einer wohlgeformten XML gegen die tatsaechlich vorhandenen Dateien
# des Mods. $Present: Schluessel = kleingeschriebener Relativpfad (mit '/'), Wert = Originalpfad.
function Get-ReferenceFinding {
    param(
        [string]$Text, [int[]]$LineStarts,
        [System.Collections.Generic.Dictionary[string, string]]$Present,
        [string]$BaseDir = ''
    )

    $findings = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrEmpty($Text) -or $null -eq $Present -or $Present.Count -eq 0) { return $findings }

    # Verweise werden gegen zwei Basen aufgeloest: die Mod-Wurzel ('') und den Ordner der XML
    # selbst. Foliage-/Map-XMLs (z.B. maps/foliage/soybean/soybean.xml) referenzieren i3d und
    # Texturen relativ zu ihrem eigenen Ordner, Fahrzeug-/modDesc-XMLs relativ zur Mod-Wurzel.
    $baseLower = ($BaseDir -replace '\\', '/').ToLowerInvariant()
    $bases     = if ($baseLower) { @('', $baseLower) } else { @('') }

    # Attributwerte ("..." / '...') und Elementtext (>...<) in einem Durchgang.
    $refRegex = [regex]'"([^"]*)"|''([^'']*)''|>([^<>]+)<'
    $endsWith = '\.(' + ($script:RefExtensions -join '|') + ')$'

    # Auskommentierte und in CDATA stehende Verweise ausblenden (Offsets bleiben erhalten).
    $scan = Hide-XmlCommentsAndCData -Text $Text

    $seen = New-Object System.Collections.Generic.HashSet[string]

    foreach ($m in $refRegex.Matches($scan)) {
        $raw = if     ($m.Groups[1].Success) { $m.Groups[1].Value }
               elseif ($m.Groups[2].Success) { $m.Groups[2].Value }
               else                          { $m.Groups[3].Value }

        $norm = ((($raw.Trim()) -replace '\\', '/') -replace '^\./', '')
        if ($norm -notmatch $endsWith)               { continue }   # kein Dateiname mit Asset-Endung
        if (-not (Test-IsResolvableRef -Path $norm)) { continue }

        $key = $norm.ToLowerInvariant()
        if (-not $seen.Add($key)) { continue }                      # jeden Verweis nur einmal melden

        $line = ConvertTo-LineNumber -LineStarts $LineStarts -CharIndex $m.Index

        # An welcher Basis existiert die Datei? Gleiche Endung zuerst, dann austauschbare
        # (.png/.dds/.grle, .wav/.ogg). Der Case-Check laeuft nur beim exakten Wurzel-Treffer.
        $resolved      = $false
        $exactRootOrig = $null
        foreach ($base in $bases) {
            $exact = $base + $key
            if ($Present.ContainsKey($exact)) {
                $resolved = $true
                if ($base -eq '') { $exactRootOrig = $Present[$exact] }
                break
            }
            $altHit = $false
            foreach ($a in (Get-AltKeys -Key $exact)) {
                if ($Present.ContainsKey($a)) { $altHit = $true; break }
            }
            if ($altHit) { $resolved = $true; break }
        }

        if ($resolved) {
            # Nur beim exakten Wurzel-Treffer (gleiche Endung) auf Gross-/Kleinschreibung pruefen.
            if ($exactRootOrig -and ($exactRootOrig -cne $norm)) {
                $findings.Add((New-Finding 'Gross-/Kleinschreibung' $line `
                    "Verweis '$norm' - die Datei heisst tatsaechlich '$exactRootOrig'. Im Zip und auf Linux-Servern ist das ein Ladefehler."))
            }
            continue
        }

        $findings.Add((New-Finding 'Fehlende Datei' $line `
            "Verweis auf '$norm' - Datei fehlt im Mod. FS25 meldet dazu 'Error: Failed to open ...' und laedt sie nicht."))
    }

    return $findings
}

# ------------------------------------------------------------------------------------------------
# Scanner pro Mod
# ------------------------------------------------------------------------------------------------

function New-XmlResult {
    param(
        [string]$Mod, [string]$Typ, [string]$Datei, [bool]$IstModDesc,
        $Check, $Hints, [string]$VollerPfad
    )

    [pscustomobject]@{
        Mod          = $Mod
        Typ          = $Typ
        Datei        = $Datei
        IstModDesc   = $IstModDesc
        Zeile        = $Check.Line
        Spalte       = $Check.Column
        ParserFehler = $Check.Message
        Ursachen     = $Hints
        VollerPfad   = $VollerPfad
    }
}

# Rueckgabe: Results = auffaellige Dateien, FileCount = geprueft, ModDesc = 'Ok' | Klartextgrund.
function Invoke-FolderScan {
    param(
        [string]$Name, [string]$FolderPath, [System.Xml.XmlReaderSettings]$Settings,
        [string]$Typ = 'Ordner', [bool]$CheckModDesc = $true, [bool]$CheckReferences = $true
    )

    $results = New-Object System.Collections.Generic.List[object]
    $count   = 0

    # Einmal alle Dateien einlesen: daraus entstehen sowohl die XML-Liste als auch der Index der
    # tatsaechlich vorhandenen Dateien fuer die Verweispruefung.
    $allFiles = @(Get-ChildItem -LiteralPath $FolderPath -Recurse -File -ErrorAction SilentlyContinue)

    $present = New-Object 'System.Collections.Generic.Dictionary[string, string]'
    foreach ($f in $allFiles) {
        $rel = ($f.FullName.Substring($FolderPath.Length + 1)) -replace '\\', '/'
        $present[$rel.ToLowerInvariant()] = $rel
    }

    $modDescAtRoot = $present.ContainsKey('moddesc.xml')
    # Verweise nur pruefen, wenn der Mod normal gepackt ist - sonst laesst sich die Mod-Wurzel
    # nicht bestimmen und jeder Verweis waere ein Fehlalarm (der Mod laedt ohnehin nicht).
    $doRefs = $CheckReferences -and $modDescAtRoot

    # 8.3-Kurznamen koennen ueber den Vorfilter auch '.xmlbak' hereinlassen - Extension exakt pruefen.
    $xmlFiles = @($allFiles | Where-Object { $_.Extension -eq '.xml' })

    foreach ($file in $xmlFiles) {
        $count++
        $check = Test-XmlFile -FilePath $file.FullName -Settings $Settings

        $hints = New-Object System.Collections.Generic.List[object]
        if (-not $check.Ok) {
            $hints = Get-XmlHint -Text (Read-FileText -FilePath $file.FullName)
        }
        elseif ($doRefs) {
            $text = Read-FileText -FilePath $file.FullName
            if ($text) {
                $rel     = ($file.FullName.Substring($FolderPath.Length + 1)) -replace '\\', '/'
                $baseDir = if ($rel -match '/') { $rel.Substring(0, $rel.LastIndexOf('/') + 1) } else { '' }
                $hints   = Get-ReferenceFinding -Text $text -LineStarts (Get-LineStartIndex -Text $text) -Present $present -BaseDir $baseDir
            }
        }

        if ($check.Ok -and $hints.Count -eq 0) { continue }   # wohlgeformt und ohne Verweisproblem

        $results.Add((New-XmlResult -Mod $Name -Typ $Typ `
            -Datei $file.FullName.Substring($FolderPath.Length + 1) `
            -IstModDesc ($file.Name -eq 'modDesc.xml') `
            -Check $check -Hints $hints -VollerPfad $file.FullName))
    }

    $modDesc = if     (-not $CheckModDesc) { 'Ok' }
               elseif ($modDescAtRoot)     { 'Ok' }
               else                        { 'keine modDesc.xml gefunden' }

    return [pscustomobject]@{ Results = $results; FileCount = $count; ModDesc = $modDesc }
}

function Invoke-ZipScan {
    param(
        [string]$Name, [string]$ZipPath, [System.Xml.XmlReaderSettings]$Settings,
        [bool]$CheckReferences = $true
    )

    $results = New-Object System.Collections.Generic.List[object]
    $count   = 0

    $stream  = $null
    $archive = $null
    try {
        # Eigener FileStream statt ZipFile::OpenRead, damit auch hier FileShare ReadWrite gilt.
        $stream  = Open-SharedFile -FilePath $ZipPath
        $archive = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Read, $false)
    }
    catch {
        if ($archive) { $archive.Dispose() }
        if ($stream)  { $stream.Dispose() }

        $check = New-CheckResult -Ok $false -Message "Archiv nicht lesbar: $($_.Exception.Message)"
        $results.Add((New-XmlResult -Mod $Name -Typ 'Zip' -Datei '(Archiv)' -IstModDesc $false `
            -Check $check -Hints (New-Object System.Collections.Generic.List[object]) -VollerPfad $ZipPath))

        return [pscustomobject]@{ Results = $results; FileCount = 0; ModDesc = 'Ok' }
    }

    try {
        # Erst den Datei-Index (fuer die Verweispruefung) und den modDesc-Status bestimmen; im
        # Zip trennt immer '/', unabhaengig vom Betriebssystem des Packers.
        $present = New-Object 'System.Collections.Generic.Dictionary[string, string]'
        $modDesc = 'keine modDesc.xml gefunden'

        foreach ($entry in $archive.Entries) {
            if ([string]::IsNullOrEmpty($entry.Name)) { continue }   # Ordnereintraege

            $present[$entry.FullName.ToLowerInvariant()] = $entry.FullName

            if ($entry.Name -ieq 'modDesc.xml') {
                if ($entry.FullName -ieq 'modDesc.xml') {
                    $modDesc = 'Ok'
                }
                elseif ($modDesc -ne 'Ok') {
                    $sub = $entry.FullName.Substring(0, $entry.FullName.LastIndexOf('/') + 1)
                    $modDesc = "modDesc.xml liegt in '$sub' statt im Zip-Wurzelverzeichnis - einmal zu viel gezippt"
                }
            }
        }

        # Verweise nur bei normal gepacktem Mod pruefen (modDesc.xml im Wurzelverzeichnis).
        $doRefs = $CheckReferences -and ($modDesc -eq 'Ok')

        foreach ($entry in $archive.Entries) {
            if ([string]::IsNullOrEmpty($entry.Name)) { continue }
            if (-not $entry.Name.EndsWith('.xml', [System.StringComparison]::OrdinalIgnoreCase)) { continue }

            $count++
            $check = Test-XmlZipEntry -Entry $entry -Settings $Settings

            $hints = New-Object System.Collections.Generic.List[object]
            if (-not $check.Ok) {
                $hints = Get-XmlHint -Text (Read-ZipEntryText -Entry $entry)
            }
            elseif ($doRefs) {
                $text = Read-ZipEntryText -Entry $entry
                if ($text) {
                    $baseDir = if ($entry.FullName -match '/') { $entry.FullName.Substring(0, $entry.FullName.LastIndexOf('/') + 1) } else { '' }
                    $hints   = Get-ReferenceFinding -Text $text -LineStarts (Get-LineStartIndex -Text $text) -Present $present -BaseDir $baseDir
                }
            }

            if ($check.Ok -and $hints.Count -eq 0) { continue }

            $results.Add((New-XmlResult -Mod $Name -Typ 'Zip' -Datei $entry.FullName `
                -IstModDesc ($entry.Name -ieq 'modDesc.xml') `
                -Check $check -Hints $hints -VollerPfad "$ZipPath!$($entry.FullName)"))
        }

        return [pscustomobject]@{ Results = $results; FileCount = $count; ModDesc = $modDesc }
    }
    finally {
        if ($archive) { $archive.Dispose() }
        if ($stream)  { $stream.Dispose() }
    }
}

# ------------------------------------------------------------------------------------------------
# Hauptlauf
# ------------------------------------------------------------------------------------------------

# Ohne -Path das eigene Verzeichnis pruefen: Skript in den Modupdate-Ordner legen und starten.
if (-not $Path) {
    $Path = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).ProviderPath }
}

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

# Ordner und Zips landen in einer gemeinsamen Liste, damit der Rest des Skripts nicht mehr
# zwischen beiden unterscheiden muss.
$modItems = New-Object System.Collections.Generic.List[object]

foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
    $modItems.Add([pscustomobject]@{ Name = $d.Name; Typ = 'Ordner'; Path = $d.FullName })
}
foreach ($z in @(Get-ChildItem -LiteralPath $root -File -Filter '*.zip' -ErrorAction SilentlyContinue |
                 Where-Object { $_.Extension -eq '.zip' })) {
    $modItems.Add([pscustomobject]@{ Name = $z.Name; Typ = 'Zip'; Path = $z.FullName })
}
$modItems = @($modItems | Sort-Object Name)

$folderCount = @($modItems | Where-Object { $_.Typ -eq 'Ordner' }).Count
$zipCount    = @($modItems | Where-Object { $_.Typ -eq 'Zip' }).Count

Write-Host ''
Write-Host "FS25 XML-Pruefung" -ForegroundColor Cyan
Write-Host "Verzeichnis : $root"
Write-Host "Mods        : $($modItems.Count)  ($folderCount Ordner, $zipCount Zip)"
Write-Host ''

$results   = New-Object System.Collections.Generic.List[object]
$noModDesc = New-Object System.Collections.Generic.List[object]
$fileCount = 0
$modIndex  = 0
$sw        = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($mod in $modItems) {
    $modIndex++
    Write-Progress -Activity 'XML-Pruefung' -Status "$($mod.Name)  ($modIndex/$($modItems.Count))" `
                   -PercentComplete (($modIndex / [Math]::Max($modItems.Count, 1)) * 100)

    $scan = if ($mod.Typ -eq 'Zip') {
        Invoke-ZipScan -Name $mod.Name -ZipPath $mod.Path -Settings $settings -CheckReferences (-not $SkipReferenceCheck)
    }
    else {
        Invoke-FolderScan -Name $mod.Name -FolderPath $mod.Path -Settings $settings -CheckReferences (-not $SkipReferenceCheck)
    }

    foreach ($r in $scan.Results) { $results.Add($r) }
    $fileCount += $scan.FileCount

    if ($scan.ModDesc -ne 'Ok') {
        $noModDesc.Add([pscustomobject]@{ Name = $mod.Name; Grund = $scan.ModDesc })
    }
}

Write-Progress -Activity 'XML-Pruefung' -Completed

# Optional: das aktive Savegame mitpruefen. Reine Wohlgeformtheit - keine Verweise, keine modDesc.
$savegameFileCount = 0
if ($SavegamePath) {
    if (Test-Path -LiteralPath $SavegamePath -PathType Container) {
        $saveRoot = (Resolve-Path -LiteralPath $SavegamePath).ProviderPath
        $saveScan = Invoke-FolderScan -Name '(Savegame)' -FolderPath $saveRoot -Settings $settings `
                        -Typ 'Savegame' -CheckModDesc $false -CheckReferences $false
        foreach ($r in $saveScan.Results) { $results.Add($r) }
        $fileCount        += $saveScan.FileCount
        $savegameFileCount = $saveScan.FileCount
    }
    else {
        Write-Host "Savegame-Verzeichnis nicht gefunden: $SavegamePath" -ForegroundColor Red
    }
}

$sw.Stop()

# ------------------------------------------------------------------------------------------------
# Ausgabe
# ------------------------------------------------------------------------------------------------

# Harte Fehler = echte XML-Parserfehler (setzen den Exitcode). Verweis-Funde sind Hinweise:
# eine fehlende .dds blockiert den Serverstart in aller Regel nicht.
$hardErrors = @($results | Where-Object { $_.ParserFehler -or $_.Zeile -gt 0 })
$advisories = @($results | Where-Object { -not ($_.ParserFehler -or $_.Zeile -gt 0) })

Write-Host ("-" * 96) -ForegroundColor DarkGray
$geprueft = "Geprueft: $fileCount XML-Dateien in $($modItems.Count) Mods"
if ($savegameFileCount -gt 0) { $geprueft += " (davon $savegameFileCount im Savegame)" }
Write-Host "$geprueft  ($([math]::Round($sw.Elapsed.TotalSeconds,1)) s)"
Write-Host ("-" * 96) -ForegroundColor DarkGray
Write-Host ''

if ($results.Count -eq 0) {
    Write-Host "Keine XML-Fehler gefunden. Alle Dateien sind well-formed." -ForegroundColor Green
}
else {
    $brokenMods = $results | Group-Object Mod | Sort-Object Name

    if ($hardErrors.Count -gt 0) {
        Write-Host "$($hardErrors.Count) fehlerhafte XML-Datei(en) (Parserfehler):" -ForegroundColor Red
    }
    if ($advisories.Count -gt 0) {
        Write-Host "$($advisories.Count) Datei(en) mit Verweis-Hinweisen (kein Parserfehler, blockiert den Exitcode nicht)." -ForegroundColor DarkYellow
    }
    Write-Host ''

    foreach ($group in $brokenMods) {
        Write-Host "  $($group.Name)" -ForegroundColor Yellow

        foreach ($r in $group.Group) {
            $tag = if ($r.IstModDesc) { '  [modDesc]' } else { '' }
            Write-Host "    $($r.Datei)$tag" -ForegroundColor White

            if ($r.Zeile -gt 0) {
                Write-Host "      Parser   Zeile $($r.Zeile), Spalte $($r.Spalte): $($r.ParserFehler)" -ForegroundColor Red
            }
            elseif ($r.ParserFehler) {
                Write-Host "      Parser   $($r.ParserFehler)" -ForegroundColor Red
            }

            $shown = 0
            foreach ($h in $r.Ursachen) {
                if ($shown -ge $MaxHints) {
                    $rest = $r.Ursachen.Count - $MaxHints
                    Write-Host "      ...      und $rest weitere gleichartige Fundstelle(n) - vollstaendig via -CsvPath" -ForegroundColor DarkGray
                    break
                }
                $ort = if ($h.Line -gt 0) { "Zeile $($h.Line): " } else { '' }
                Write-Host "      Ursache  $ort$($h.Kind)" -ForegroundColor Magenta
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
    Write-Host "Hinweis: $($noModDesc.Count) Eintrag/Eintraege ohne ladbare modDesc.xml (werden von FS25 nicht als Mod geladen):" -ForegroundColor DarkYellow
    foreach ($n in $noModDesc) { Write-Host "  - $($n.Name): $($n.Grund)" -ForegroundColor DarkGray }
}

if ($CsvPath) {
    $flat = foreach ($r in $results) {
        if ($r.Ursachen.Count -eq 0) {
            [pscustomobject]@{
                Mod = $r.Mod; Typ = $r.Typ; Datei = $r.Datei; ParserZeile = $r.Zeile; ParserSpalte = $r.Spalte
                ParserFehler = $r.ParserFehler; UrsacheArt = ''; UrsacheZeile = ''; UrsacheText = ''
                VollerPfad = $r.VollerPfad
            }
        }
        else {
            foreach ($h in $r.Ursachen) {
                [pscustomobject]@{
                    Mod = $r.Mod; Typ = $r.Typ; Datei = $r.Datei; ParserZeile = $r.Zeile; ParserSpalte = $r.Spalte
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

# Nur echte Parserfehler blockieren den Reboot-Gate; Verweis-Hinweise werden nur gemeldet.
exit $(if ($hardErrors.Count -gt 0) { 1 } else { 0 })
