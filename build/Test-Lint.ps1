<#
.SYNOPSIS
    Runs PSScriptAnalyzer on the module with the repo's settings, the same check CI runs.

.DESCRIPTION
    Analyzes ./SecondLine with ./PSScriptAnalyzerSettings.psd1, prints any findings as a
    table, and exits 1 if there is any Error or Warning. Run it before pushing, in both
    Windows PowerShell 5.1 and PowerShell 7 if you can.

.PARAMETER Path
    What to analyze. Defaults to the module folder.

.EXAMPLE
    .\build\Test-Lint.ps1
#>
[CmdletBinding()]
param(
    [string] $Path
)

$ErrorActionPreference = 'Stop'
$repo     = Split-Path $PSScriptRoot -Parent
$settings = Join-Path $repo 'PSScriptAnalyzerSettings.psd1'
if (-not $Path) { $Path = Join-Path $repo 'SecondLine' }

if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
    Write-Host 'PSScriptAnalyzer is not installed. Install it: Install-Module PSScriptAnalyzer -Scope CurrentUser' -ForegroundColor Red
    exit 1
}
Import-Module PSScriptAnalyzer

$findings = @(Invoke-ScriptAnalyzer -Path $Path -Recurse -Settings $settings)
if ($findings.Count -gt 0) {
    $findings |
        Sort-Object ScriptName, Line |
        Format-Table Severity, RuleName, ScriptName, Line, Message -AutoSize -Wrap |
        Out-String -Width 200 |
        Write-Host
}

$bad = @($findings | Where-Object { 'Error', 'Warning' -contains "$($_.Severity)" })
if ($bad.Count -gt 0) {
    Write-Host "  Lint: $($bad.Count) finding(s). Fix them, or run build\Format-SecondLine.ps1 for layout ones." -ForegroundColor Red
    exit 1
}
Write-Host "  Lint: clean (PowerShell $($PSVersionTable.PSVersion))" -ForegroundColor Green
