#Requires -Version 5.1
<#
.SYNOPSIS
    Prueft Test-FS25ModXml.ps1 gegen die Fixtures in tests/fixtures.

.DESCRIPTION
    Jede Fixture ist ein Mini-Mod mit genau einem bekannten Defekt (oder bewusst fehlerfrei).
    Der Test prueft nicht nur "wurde ein Fehler gefunden", sondern auch Art und Zeilennummer -
    denn genau die Zeilennummer ist der Mehrwert gegenueber einem nackten XML-Parser.

.EXAMPLE
    .\tests\Invoke-Tests.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script   = Join-Path (Split-Path -Parent $testsDir) 'Test-FS25ModXml.ps1'
$fixtures = Join-Path $testsDir 'fixtures'

# Mod -> erwarteter Befund. UrsacheArt/UrsacheZeile = $null bedeutet: Datei muss sauber sein.
$expected = @(
    @{ Mod = 'FS25_UnclosedComment'; Art = 'Nicht geschlossener Kommentar'; Zeile = 4 }
    @{ Mod = 'FS25_NestedComment';   Art = 'Verschachtelter Kommentar';    Zeile = 4 }
    @{ Mod = 'FS25_DoubleDash';      Art = 'Trennlinien-Kommentar';        Zeile = 3 }
    @{ Mod = 'FS25_BadClose';        Art = 'Trennlinien-Kommentar';        Zeile = 3 }
    @{ Mod = 'FS25_UnclosedTag';     Art = 'Falsch verschachteltes Tag';   Zeile = 6 }
    @{ Mod = 'FS25_MismatchTag';     Art = 'Falsch verschachteltes Tag';   Zeile = 3 }
    @{ Mod = 'FS25_Good';            Art = $null;                          Zeile = $null }
    @{ Mod = 'FS25_CdataOk';         Art = $null;                          Zeile = $null }
)

Write-Host ''
Write-Host 'Test-FS25ModXml - Fixture-Tests' -ForegroundColor Cyan
Write-Host ''

# 6>$null verschluckt die Write-Host-Ausgabe des Skripts, uebrig bleiben die -PassThru-Objekte.
$results = @(& $script -Path $fixtures -PassThru 6>$null)

$pass = 0
$fail = 0

foreach ($e in $expected) {
    $found = $results | Where-Object { $_.Mod -eq $e.Mod }

    if ($null -eq $e.Art) {
        if ($found) {
            Write-Host "  FAIL  $($e.Mod): sollte sauber sein, gemeldet wurde '$($found.ParserFehler)'" -ForegroundColor Red
            $fail++
        }
        else {
            Write-Host "  ok    $($e.Mod): sauber, wie erwartet" -ForegroundColor Green
            $pass++
        }
        continue
    }

    if (-not $found) {
        Write-Host "  FAIL  $($e.Mod): Fehler '$($e.Art)' wurde NICHT erkannt" -ForegroundColor Red
        $fail++
        continue
    }

    $hint = $found.Ursachen | Where-Object { $_.Kind -eq $e.Art } | Select-Object -First 1
    if (-not $hint) {
        $got = ($found.Ursachen | ForEach-Object { $_.Kind }) -join ', '
        Write-Host "  FAIL  $($e.Mod): erwartet '$($e.Art)', bekommen '$got'" -ForegroundColor Red
        $fail++
    }
    elseif ($hint.Line -ne $e.Zeile) {
        Write-Host "  FAIL  $($e.Mod): '$($e.Art)' erwartet in Zeile $($e.Zeile), gemeldet Zeile $($hint.Line)" -ForegroundColor Red
        $fail++
    }
    else {
        Write-Host "  ok    $($e.Mod): '$($e.Art)' in Zeile $($e.Zeile)" -ForegroundColor Green
        $pass++
    }
}

Write-Host ''
if ($fail -eq 0) {
    Write-Host "$pass/$($expected.Count) Tests bestanden." -ForegroundColor Green
    exit 0
}
Write-Host "$pass bestanden, $fail fehlgeschlagen." -ForegroundColor Red
exit 1
