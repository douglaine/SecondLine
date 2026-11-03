<#
.SYNOPSIS
    Builds the real release package and validates its contents and behaviour. Publishes nothing.

.DESCRIPTION
    1. Stages the package with Build-SecondLinePackage.ps1.
    2. Checks required assets: manifest, loader, every exported command's file, help
       topic, bootstrap, policy (with a header that verifies), status template,
       baseline standard, line-ending profiles, LICENSE.
    3. Checks that development-only files are absent: tests, build scripts, tasks,
       docs, agent instructions, CI and git files, logs.
    4. Test-ModuleManifest; FunctionsToExport must equal Public\*.ps1.
    5. If Compress-PSResource (PSResourceGet 1.1+) is available, builds the actual
       .nupkg, extracts it, and checks it holds exactly the staged files.
    6. In a fresh process, imports the extracted package (or the stage) and smoke-tests
       it: exports, about_SecondLine, Show-SLHelp -NoUpdateCheck, the packaged policy
       path, and Export-SLPolicy into a temporary folder.

    Nothing is published, installed, or registered. A repository is never registered.
    Exits 1 on any failure.

.PARAMETER OutputPath
    Where to put the stage, the .nupkg and the extracted copy. Default: a new temp folder.

.PARAMETER Keep
    Keep the output folder (it is printed).

.EXAMPLE
    .\build\Test-SecondLinePackage.ps1 -Keep
#>
[CmdletBinding()]
param([string] $OutputPath, [switch] $Keep)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
if (-not $OutputPath) { $OutputPath = Join-Path ([IO.Path]::GetTempPath()) ('SecondLine-package-' + [guid]::NewGuid().ToString('N')) }
$failures = New-Object System.Collections.Generic.List[string]
function Test-Item([bool] $Ok, [string] $Text) {
    if ($Ok) { Write-Host "    OK    $Text" -ForegroundColor Green } else { Write-Host "    FAIL  $Text" -ForegroundColor Red; $failures.Add($Text) }
}

try {
    Write-Host ''
    Write-Host "  SecondLine - package validation (PowerShell $($PSVersionTable.PSVersion))" -ForegroundColor White
    $stage = & (Join-Path $PSScriptRoot 'Build-SecondLinePackage.ps1') -OutputPath (Join-Path $OutputPath 'stage')
    $files = @(Get-ChildItem -LiteralPath $stage -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($stage.Length + 1).Replace('\', '/') } | Sort-Object)

    Write-Host ''
    Write-Host '  [1] Required assets' -ForegroundColor Cyan
    $manifestData = Import-PowerShellDataFile (Join-Path $stage 'SecondLine.psd1')
    $required = @('SecondLine.psd1', 'SecondLine.psm1', 'LICENSE', 'en-US/about_SecondLine.help.txt', 'Bootstrap/Import-SecondLine.ps1',
        'Policy/shared-development-policy.md', 'Policy/status-template.md', 'Standards/development.psd1',
        'Profiles/gitattributes/docs.gitattributes', 'Profiles/gitattributes/dotnet.gitattributes', 'Profiles/gitattributes/powershell.gitattributes')
    $required += @($manifestData.FunctionsToExport | ForEach-Object { "Public/$_.ps1" })
    foreach ($r in $required) { Test-Item ($files -contains $r) $r }

    Write-Host ''
    Write-Host '  [2] Development-only files excluded' -ForegroundColor Cyan
    $forbidden = @($files | Where-Object { $_ -match '(^|/)(tests|build|tasks|docs|\.github|\.vscode)/' -or $_ -match '(^|/)(CLAUDE|AGENTS|GOTCHAS|README|CHANGELOG)\.md$' -or $_ -match '\.Tests\.ps1$|\.log$|\.tmp$|(^|/)\.git' })
    Test-Item ($forbidden.Count -eq 0) "no development-only files ($(@($forbidden) -join ', '))"

    Write-Host ''
    Write-Host '  [3] Manifest' -ForegroundColor Cyan
    $info = Test-ModuleManifest -Path (Join-Path $stage 'SecondLine.psd1')
    Test-Item $true "Test-ModuleManifest: SecondLine $($info.Version)"
    $public = @($files | Where-Object { $_ -like 'Public/*.ps1' } | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_) } | Sort-Object)
    $exported = @($manifestData.FunctionsToExport | Sort-Object)
    Test-Item (($public -join ',') -eq ($exported -join ',')) 'FunctionsToExport matches Public\*.ps1'
    $changelog = Join-Path $repo 'CHANGELOG.md'
    Test-Item ([bool] (Select-String -Path $changelog -Pattern ('^## ' + [regex]::Escape("$($info.Version)") + '\b') -Quiet)) "CHANGELOG.md has a '## $($info.Version)' entry"

    $importFrom = $stage
    Write-Host ''
    Write-Host '  [4] Actual .nupkg' -ForegroundColor Cyan
    if (Get-Command Compress-PSResource -ErrorAction SilentlyContinue) {
        $nupkgDir = Join-Path $OutputPath 'nupkg'
        New-Item -ItemType Directory -Path $nupkgDir | Out-Null
        Push-Location $OutputPath
        try { Compress-PSResource -Path $stage -DestinationPath $nupkgDir } finally { Pop-Location }
        $nupkg = Get-ChildItem -LiteralPath $nupkgDir -Filter '*.nupkg' | Select-Object -First 1
        Test-Item ([bool] $nupkg) "built $($nupkg.Name) ($([math]::Round($nupkg.Length / 1KB)) KB)"
        $extract = Join-Path $OutputPath "extract\SecondLine\$($info.Version)"
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($nupkg.FullName, $extract)
        $metadata = '^(\[Content_Types\]\.xml|_rels/.*|package/.*|SecondLine\.nuspec)$'
        $inPackage = @(Get-ChildItem -LiteralPath $extract -Recurse -File -Force | ForEach-Object { [Uri]::UnescapeDataString($_.FullName.Substring($extract.Length + 1).Replace('\', '/')) } | Where-Object { $_ -notmatch $metadata } | Sort-Object)
        $missing = @($files | Where-Object { $inPackage -notcontains $_ })
        $extra = @($inPackage | Where-Object { $files -notcontains $_ })
        Test-Item ($missing.Count -eq 0 -and $extra.Count -eq 0) "nupkg holds exactly the staged files ($($inPackage.Count)); missing: $($missing -join ', '); extra: $($extra -join ', ')"
        $importFrom = $extract
    }
    else { Write-Host '    SKIP  Compress-PSResource is not available in this PowerShell; validated the stage only.' -ForegroundColor Yellow }

    Write-Host ''
    Write-Host "  [5] Import and smoke test (fresh process, from $importFrom)" -ForegroundColor Cyan
    $smoke = Join-Path $OutputPath 'smoke.ps1'
    $work = Join-Path $OutputPath 'smoke-work'
    New-Item -ItemType Directory -Path $work | Out-Null
    Set-Content -LiteralPath $smoke -Value @(
        'param($Module, $Work)'
        '$ErrorActionPreference = "Stop"'
        '$env:SECONDLINE_NO_UPDATE_CHECK = "1"; $env:SECONDLINE_CACHE_DIR = Join-Path $Work "cache"; $env:SECONDLINE_NO_HOST_SETTINGS = "1"'
        'Set-Location $Work'
        '$m = Import-Module (Join-Path $Module "SecondLine.psd1") -PassThru'
        '"exports=" + (@($m.ExportedCommands.Keys | Sort-Object) -join ",")'
        '"about=" + [bool] ((Get-Help about_SecondLine | Out-String) -match "CONFIGURATION")'
        '$h = Show-SLHelp -NoUpdateCheck -PassThru 6> $null'
        '"help=" + $h.Commands.Count'
        '"policy=" + (& $m { Get-SLShippedPolicyPath })'
        '$e = Export-SLPolicy -Path $Work -PassThru 6> $null'
        '"export=" + $e.Action'
        '"verify=" + (-not (& $m { param($p) (Read-SLPolicyFile -Path $p).Modified } (Join-Path $Work "docs/shared-development-policy.md")))'
    )
    $exe = (Get-Process -Id $PID).Path
    $out = @(& $exe -NoProfile -NonInteractive -File $smoke $importFrom $work 2>&1 | ForEach-Object { "$_" })
    $values = @{}
    foreach ($line in $out) { if ($line -match '^(\w+)=(.*)$') { $values[$Matches[1]] = $Matches[2] } }
    Test-Item ($values['exports'] -eq (($exported | Sort-Object) -join ',')) "imports with $(@($exported).Count) exported commands"
    Test-Item ($values['about'] -eq 'True') 'about_SecondLine help is found'
    Test-Item ([int] $values['help'] -eq @($exported).Count) 'Show-SLHelp lists every export (no update check)'
    Test-Item ("$($values['policy'])" -like "$importFrom*Policy*shared-development-policy.md") "uses the packaged policy ($($values['policy']))"
    Test-Item ($values['export'] -eq 'Created' -and $values['verify'] -eq 'True') 'Export-SLPolicy writes a copy that verifies'
    if ($failures.Count -gt 0) { $out | ForEach-Object { Write-Host "          $_" -ForegroundColor DarkGray } }

    Write-Host ''
    Write-Host '  Package files:' -ForegroundColor White
    foreach ($f in $files) { Write-Host "          $f" -ForegroundColor DarkGray }
    Write-Host ''
    if ($failures.Count -gt 0) { Write-Host "  Package validation FAILED: $($failures.Count) check(s)." -ForegroundColor Red; exit 1 }
    Write-Host "  Package validation passed: $($files.Count) files. Nothing was published." -ForegroundColor Green
}
finally {
    if ($Keep) { Write-Host "  Output kept: $OutputPath" -ForegroundColor DarkGray }
    elseif (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Recurse -Force -ErrorAction SilentlyContinue }
}
