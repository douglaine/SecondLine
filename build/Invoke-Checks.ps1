<#
.SYNOPSIS
    Runs SecondLine's checks in the cheapest-first order. CI and the publish script
    both use it, so a local run and a CI run check the same things.

.DESCRIPTION
    Order, stopping at the first failing stage:
      1. Lint (PSScriptAnalyzer). Seconds. Static analysis with the repo settings,
         which already target Windows PowerShell 5.1 and PowerShell 7, so its result
         doesn't depend on which shell runs it. Run it once, not once per shell.
      2. Repository line endings (SecondLine's own Test-SLLineEnding).
      3. Release package build and validation (-Package).
      4. The Pester suite.

    -TestsOnly runs just stage 4: the second shell only needs the tests.
    -StopOnFirstFailure ends the test run at the first failing test. Use it for the
    first, faster shell, so a broken build is reported in seconds.

    Works in Windows PowerShell 5.1 and PowerShell 7.

.PARAMETER InstallMissing
    Install Pester 5.5+ (and PSScriptAnalyzer, unless -TestsOnly) for the current user
    when they're missing. CI uses it; on a cache hit nothing is installed.

.EXAMPLE
    .\build\Invoke-Checks.ps1 -Package -StopOnFirstFailure

.EXAMPLE
    .\build\Invoke-Checks.ps1 -TestsOnly
#>
[CmdletBinding()]
param(
    [switch] $TestsOnly,
    [switch] $Package,
    [switch] $StopOnFirstFailure,
    [switch] $InstallMissing
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$shell = "PowerShell $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor)"
$sw = [Diagnostics.Stopwatch]::StartNew()

function Write-Stage([string] $Text) { Write-Host ''; Write-Host "== $Text ($shell)" -ForegroundColor Cyan }
function Stop-Checks([string] $Text) {
    Write-Host "FAILED: $Text" -ForegroundColor Red
    exit 1
}

function Test-PesterOk {
    return [bool] (Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge [version] '5.5' } | Select-Object -First 1)
}

# ------------------------------------------------------------ modules --
$needPssa = -not $TestsOnly -and -not (Get-Module -ListAvailable PSScriptAnalyzer)
if ($InstallMissing -and ($needPssa -or -not (Test-PesterOk))) {
    # Trusting the Gallery for this user avoids an untrusted-repository prompt,
    # which would hang an unattended run.
    Set-PSRepository PSGallery -InstallationPolicy Trusted
}
if (-not (Test-PesterOk)) {
    if (-not $InstallMissing) { Stop-Checks "Pester 5.5+ is not installed for $shell. Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force -SkipPublisherCheck" }
    Write-Host 'Installing Pester 5.5+' -ForegroundColor DarkGray
    # Windows ships Pester 3.4 signed by Microsoft; a side-by-side 5.x needs -SkipPublisherCheck.
    Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force -SkipPublisherCheck
}
if ($needPssa) {
    if (-not $InstallMissing) { Stop-Checks "PSScriptAnalyzer is not installed for $shell. Install-Module PSScriptAnalyzer -Scope CurrentUser" }
    Write-Host 'Installing PSScriptAnalyzer' -ForegroundColor DarkGray
    Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
}

if (-not $TestsOnly) {
    # ------------------------------------------------------------ 1. lint --
    Write-Stage 'Lint'
    & (Join-Path $PSScriptRoot 'Test-Lint.ps1')
    if ($LASTEXITCODE -ne 0) { Stop-Checks 'lint' }

    # ---------------------------------------------------- 2. line endings --
    Write-Stage 'Repository line endings'
    Import-Module (Join-Path $repo 'SecondLine\SecondLine.psd1') -Force
    Test-SLLineEnding -Path $repo -Depth 0 -Strict
    Remove-Module SecondLine -ErrorAction SilentlyContinue

    # --------------------------------------------------------- 3. package --
    if ($Package) {
        Write-Stage 'Release package'
        & (Join-Path $PSScriptRoot 'Test-SecondLinePackage.ps1')
        if ($LASTEXITCODE -ne 0) { Stop-Checks 'package' }
    }
}

# --------------------------------------------------------------- 4. tests --
Write-Stage 'Tests'
Import-Module Pester -MinimumVersion 5.5
$cfg = New-PesterConfiguration
$cfg.Run.Path = (Join-Path $repo 'tests')
$cfg.Run.PassThru = $true
$cfg.Output.Verbosity = 'Detailed'
if ($StopOnFirstFailure) { $cfg.Run.SkipRemainingOnFailure = 'Run' }
$result = Invoke-Pester -Configuration $cfg
if ($result.FailedCount -gt 0 -or $result.Result -ne 'Passed') {
    Stop-Checks "$($result.FailedCount) test(s) failed"
}

Write-Host ''
Write-Host ("All checks passed in {0:n0}s ({1})" -f $sw.Elapsed.TotalSeconds, $shell) -ForegroundColor Green
exit 0
