#Requires -Version 5.1
<#
.SYNOPSIS
    Prueft Test-FS25ModXml.ps1 gegen die Fixtures in tests/fixtures.

.DESCRIPTION
    Jede Fixture ist ein Mini-Mod mit genau einem bekannten Defekt (oder bewusst fehlerfrei).
    Der Test prueft nicht nur "wurde ein Fehler gefunden", sondern auch Art und Zeilennummer -
    denn genau die Zeilennummer ist der Mehrwert gegenueber einem nackten XML-Parser.

    Derselbe Erwartungskatalog laeuft zweimal: einmal gegen die entpackten Fixture-Ordner und
    einmal gegen daraus erzeugte .zip-Mods. Die Zips werden zur Laufzeit in einem Temp-Ordner
    gebaut, damit keine Binaerdateien im Repo liegen und beide Pfade nachweislich dieselben
    Befunde liefern.

.EXAMPLE
    .\tests\Invoke-Tests.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression.FileSystem

$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script   = Join-Path (Split-Path -Parent $testsDir) 'Test-FS25ModXml.ps1'
$fixtures = Join-Path $testsDir 'fixtures'

# Mod -> erwarteter Befund. Art/Zeile = $null bedeutet: Mod muss sauber sein.
$expected = @(
    @{ Mod = 'FS25_UnclosedComment'; Art = 'Nicht geschlossener Kommentar'; Zeile = 4 }
    @{ Mod = 'FS25_NestedComment';   Art = 'Verschachtelter Kommentar';    Zeile = 4 }
    @{ Mod = 'FS25_DoubleDash';      Art = 'Trennlinien-Kommentar';        Zeile = 3 }
    @{ Mod = 'FS25_BadClose';        Art = 'Trennlinien-Kommentar';        Zeile = 3 }
    @{ Mod = 'FS25_UnclosedTag';     Art = 'Falsch verschachteltes Tag';   Zeile = 6 }
    @{ Mod = 'FS25_MismatchTag';     Art = 'Falsch verschachteltes Tag';   Zeile = 3 }
    @{ Mod = 'FS25_MissingRef';      Art = 'Fehlende Datei';               Zeile = 5 }
    @{ Mod = 'FS25_BadCase';         Art = 'Gross-/Kleinschreibung';       Zeile = 5 }
    @{ Mod = 'FS25_PngDds';          Art = $null;                          Zeile = $null }
    @{ Mod = 'FS25_WavOgg';          Art = $null;                          Zeile = $null }
    @{ Mod = 'FS25_GrlePng';         Art = $null;                          Zeile = $null }
    @{ Mod = 'FS25_MapRelative';     Art = $null;                          Zeile = $null }
    @{ Mod = 'FS25_CommentedRef';    Art = $null;                          Zeile = $null }
    @{ Mod = 'FS25_Good';            Art = $null;                          Zeile = $null }
    @{ Mod = 'FS25_CdataOk';         Art = $null;                          Zeile = $null }
)

$script:pass = 0
$script:fail = 0

function Write-Pass { param([string]$Text) Write-Host "  ok    $Text" -ForegroundColor Green; $script:pass++ }
function Write-Fail { param([string]$Text) Write-Host "  FAIL  $Text" -ForegroundColor Red;   $script:fail++ }

# Prueft einen Erwartungseintrag gegen die -PassThru-Objekte eines Laufs.
# $ModName ist der Name, unter dem der Mod gemeldet wird - beim Zip inkl. '.zip'.
function Assert-Fixture {
    param($Results, $Expected, [string]$ModName)

    $found = @($Results | Where-Object { $_.Mod -eq $ModName })

    if ($null -eq $Expected.Art) {
        if ($found) { Write-Fail "${ModName}: sollte sauber sein, gemeldet wurde '$($found[0].ParserFehler)'" }
        else        { Write-Pass "${ModName}: sauber, wie erwartet" }
        return
    }

    if (-not $found) {
        Write-Fail "${ModName}: Fehler '$($Expected.Art)' wurde NICHT erkannt"
        return
    }

    $hint = $found[0].Ursachen | Where-Object { $_.Kind -eq $Expected.Art } | Select-Object -First 1
    if (-not $hint) {
        $got = ($found[0].Ursachen | ForEach-Object { $_.Kind }) -join ', '
        Write-Fail "${ModName}: erwartet '$($Expected.Art)', bekommen '$got'"
    }
    elseif ($hint.Line -ne $Expected.Zeile) {
        Write-Fail "${ModName}: '$($Expected.Art)' erwartet in Zeile $($Expected.Zeile), gemeldet Zeile $($hint.Line)"
    }
    else {
        Write-Pass "${ModName}: '$($Expected.Art)' in Zeile $($Expected.Zeile)"
    }
}

Write-Host ''
Write-Host 'Test-FS25ModXml - Fixture-Tests' -ForegroundColor Cyan

# ------------------------------------------------------------------------------------------------
# Durchgang 1: entpackte Mod-Ordner
# ------------------------------------------------------------------------------------------------

Write-Host ''
Write-Host 'Entpackte Mod-Ordner' -ForegroundColor Cyan

# 6>$null verschluckt die Write-Host-Ausgabe des Skripts, uebrig bleiben die -PassThru-Objekte.
$folderResults = @(& $script -Path $fixtures -PassThru 6>$null)

foreach ($e in $expected) { Assert-Fixture -Results $folderResults -Expected $e -ModName $e.Mod }

if (@($folderResults | Where-Object { $_.Typ -ne 'Ordner' }).Count -gt 0) {
    Write-Fail "Typ: Ordner-Lauf hat Befunde mit Typ != 'Ordner' gemeldet"
}
else {
    Write-Pass "Typ: alle Befunde als 'Ordner' gemeldet"
}

# ------------------------------------------------------------------------------------------------
# Durchgang 2: dieselben Fixtures als .zip
# ------------------------------------------------------------------------------------------------

Write-Host ''
Write-Host 'Gezippte Mods' -ForegroundColor Cyan

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("fs25xmltest_" + [guid]::NewGuid().ToString('N'))
$zipDir   = Join-Path $tempRoot 'zips'
$null = New-Item -ItemType Directory -Path $zipDir -Force

try {
    # Jede Fixture wird so gezippt, wie ein Mod-Zip aussehen muss: modDesc.xml im Wurzelverzeichnis
    # des Archivs, nicht in einem Unterordner.
    foreach ($e in $expected) {
        [System.IO.Compression.ZipFile]::CreateFromDirectory(
            (Join-Path $fixtures $e.Mod),
            (Join-Path $zipDir "$($e.Mod).zip"))
    }

    # Sonderfall 1: einmal zu viel gezippt - modDesc.xml liegt im Unterordner.
    $stage = Join-Path $tempRoot 'stage'
    $null  = New-Item -ItemType Directory -Path (Join-Path $stage 'FS25_Good') -Force
    Copy-Item -Path (Join-Path $fixtures 'FS25_Good\modDesc.xml') -Destination (Join-Path $stage 'FS25_Good')
    [System.IO.Compression.ZipFile]::CreateFromDirectory($stage, (Join-Path $zipDir 'FS25_DoubleZipped.zip'))

    # Sonderfall 2: kaputtes Archiv - haeufig ein abgebrochener Download im Modupdate-Ordner.
    Set-Content -LiteralPath (Join-Path $zipDir 'FS25_Corrupt.zip') -Value 'kein zip' -Encoding Ascii

    # 6>&1 leitet die Write-Host-Ausgabe in die Pipeline um, damit auch die Hinweise
    # (modDesc) pruefbar sind. Die -PassThru-Objekte kommen im selben Strom mit.
    $zipOutput  = @(& $script -Path $zipDir -PassThru 6>&1)
    $zipResults = @($zipOutput | Where-Object { $_ -is [System.Management.Automation.PSCustomObject] -and $_.PSObject.Properties['Ursachen'] })
    $zipText    = ($zipOutput | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { $_.ToString() }) -join "`n"

    foreach ($e in $expected) { Assert-Fixture -Results $zipResults -Expected $e -ModName "$($e.Mod).zip" }

    if (@($zipResults | Where-Object { $_.Typ -ne 'Zip' }).Count -gt 0) {
        Write-Fail "Typ: Zip-Lauf hat Befunde mit Typ != 'Zip' gemeldet"
    }
    else {
        Write-Pass "Typ: alle Befunde als 'Zip' gemeldet"
    }

    # Der Dateipfad im Zip muss der Eintragspfad sein, nicht ein ausgepackter Temp-Pfad.
    $unclosed = $zipResults | Where-Object { $_.Mod -eq 'FS25_UnclosedComment.zip' } | Select-Object -First 1
    if ($unclosed -and $unclosed.Datei -eq 'modDesc.xml' -and $unclosed.VollerPfad -like '*.zip!modDesc.xml') {
        Write-Pass "Zip-Pfad: 'modDesc.xml' mit VollerPfad '<archiv>.zip!modDesc.xml'"
    }
    else {
        Write-Fail "Zip-Pfad: erwartet Datei 'modDesc.xml' und VollerPfad '<archiv>.zip!modDesc.xml', bekommen '$($unclosed.Datei)' / '$($unclosed.VollerPfad)'"
    }

    if ($zipText -match 'FS25_DoubleZipped\.zip.*Zip-Wurzelverzeichnis') {
        Write-Pass "FS25_DoubleZipped.zip: modDesc.xml im Unterordner gemeldet"
    }
    else {
        Write-Fail "FS25_DoubleZipped.zip: Hinweis auf modDesc.xml im Unterordner fehlt"
    }

    $corrupt = $zipResults | Where-Object { $_.Mod -eq 'FS25_Corrupt.zip' } | Select-Object -First 1
    if ($corrupt -and $corrupt.ParserFehler -like 'Archiv nicht lesbar*') {
        Write-Pass "FS25_Corrupt.zip: kaputtes Archiv als Fehler gemeldet"
    }
    else {
        Write-Fail "FS25_Corrupt.zip: kaputtes Archiv wurde nicht als Fehler gemeldet"
    }
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------------------------------------
# Durchgang 3: Savegame-Pruefung (-SavegamePath)
# ------------------------------------------------------------------------------------------------

Write-Host ''
Write-Host 'Savegame-Pruefung' -ForegroundColor Cyan

$saveRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("fs25xmlsave_" + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $saveRoot -Force

try {
    # Ein sauberes und ein kaputtes (Tag nicht geschlossen) Savegame-XML.
    Set-Content -LiteralPath (Join-Path $saveRoot 'farms.xml') `
                -Value "<?xml version=`"1.0`"?><farms></farms>" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $saveRoot 'vehicles.xml') `
                -Value "<?xml version=`"1.0`"?>`n<vehicles>`n  <vehicle>`n</vehicles>" -Encoding UTF8

    $saveResults = @(& $script -Path $fixtures -SavegamePath $saveRoot -PassThru 6>$null)

    $saveHit = $saveResults | Where-Object { $_.Typ -eq 'Savegame' -and $_.Datei -eq 'vehicles.xml' } | Select-Object -First 1
    if ($saveHit) {
        Write-Pass "Savegame: kaputte vehicles.xml als Typ 'Savegame' gemeldet"
    }
    else {
        Write-Fail "Savegame: kaputte vehicles.xml wurde nicht gemeldet"
    }

    if (@($saveResults | Where-Object { $_.Typ -eq 'Savegame' -and $_.Datei -eq 'farms.xml' }).Count -eq 0) {
        Write-Pass "Savegame: saubere farms.xml korrekt nicht gemeldet"
    }
    else {
        Write-Fail "Savegame: saubere farms.xml faelschlich gemeldet"
    }
}
finally {
    Remove-Item -LiteralPath $saveRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------------------------------------

$total = $script:pass + $script:fail

Write-Host ''
if ($script:fail -eq 0) {
    Write-Host "$($script:pass)/$total Tests bestanden." -ForegroundColor Green
    exit 0
}
Write-Host "$($script:pass) bestanden, $($script:fail) fehlgeschlagen." -ForegroundColor Red
exit 1
