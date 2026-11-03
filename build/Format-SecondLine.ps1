<#
.SYNOPSIS
    Reformats the module's .ps1/.psm1/.psd1 files with the repo's PSScriptAnalyzer settings.

.DESCRIPTION
    Runs Invoke-Formatter with ./PSScriptAnalyzerSettings.psd1 on every PowerShell file
    under ./SecondLine and rewrites only the files that change. Files keep CRLF line
    endings and their existing BOM (or lack of one). Review the diff before committing.

.EXAMPLE
    .\build\Format-SecondLine.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Path
)

$ErrorActionPreference = 'Stop'
$repo     = Split-Path $PSScriptRoot -Parent
$settings = Join-Path $repo 'PSScriptAnalyzerSettings.psd1'
if (-not $Path) { $Path = Join-Path $repo 'SecondLine' }
Import-Module PSScriptAnalyzer

$files = Get-ChildItem -LiteralPath $Path -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1'
foreach ($file in $files) {
    $bytes  = [IO.File]::ReadAllBytes($file.FullName)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text   = [IO.File]::ReadAllText($file.FullName)
    $new    = Invoke-Formatter -ScriptDefinition $text -Settings $settings
    $new    = ($new -replace "`r?`n", "`r`n")
    if ($new -ceq $text) { continue }
    if ($PSCmdlet.ShouldProcess($file.FullName, 'Reformat')) {
        [IO.File]::WriteAllText($file.FullName, $new, (New-Object Text.UTF8Encoding($hasBom)))
        Write-Host "  formatted $($file.FullName.Substring($repo.Length + 1))"
    }
}
