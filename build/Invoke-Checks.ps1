<#
.SYNOPSIS
    Runs SecondLine's checks in the cheapest-first order. CI and the publish script
    both use it, so a local run and a CI run check the same things.

.DESCRIPTION
    Stages, in order, stopping at the first failure:
      Modules      Pester 5.5+ (and PSScriptAnalyzer unless -TestsOnly) are present,
                   installed with -InstallMissing. In CI they come from a cache.
      Lint         PSScriptAnalyzer with the repo settings, which already target
                   Windows PowerShell 5.1 and PowerShell 7, so the result doesn't
                   depend on which shell runs it. Run it once, not once per shell.
      LineEndings  SecondLine's own Test-SLLineEnding on this repo.
      Package      Builds and validates the release package (with -Package, or when
                   named in -Stage).
      Tests        The Pester suite. -StopOnFirstFailure ends it at the first failing
                   test; use it for the first, faster shell.

    -Stage runs only the named stages, so CI can show each one as its own step.
    Without -Stage everything runs, or only Modules and Tests with -TestsOnly.

    In GitHub Actions each stage also records its result and time, and -Stage Summary
    writes them as one table on the run page.

    Works in Windows PowerShell 5.1 and PowerShell 7.

.EXAMPLE
    .\build\Invoke-Checks.ps1 -Package -StopOnFirstFailure

.EXAMPLE
    .\build\Invoke-Checks.ps1 -Stage Lint
#>
[CmdletBinding()]
param(
    [ValidateSet('Modules', 'Lint', 'LineEndings', 'Package', 'Tests', 'Summary')]
    [string[]] $Stage,
    [switch] $TestsOnly,
    [switch] $Package,
    [switch] $StopOnFirstFailure,
    [switch] $InstallMissing
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$shell = "PowerShell $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor)"
$total = [Diagnostics.Stopwatch]::StartNew()

if (-not $Stage) {
    if ($TestsOnly) { $Stage = @('Modules', 'Tests') }
    else {
        $Stage = @('Modules', 'Lint', 'LineEndings')
        if ($Package) { $Stage += 'Package' }
        $Stage += 'Tests'
    }
}
$runLint = $Stage -contains 'Lint' -or (-not $TestsOnly -and $Stage -contains 'Modules' -and $Stage.Count -eq 1)

# Results shared across CI steps, for the summary table.
$resultsFile = $null
if ($env:GITHUB_ACTIONS -eq 'true' -and $env:RUNNER_TEMP) { $resultsFile = Join-Path $env:RUNNER_TEMP 'secondline-checks.tsv' }

function Add-Result([string] $Name, [string] $Result, [double] $Seconds, [string] $Detail) {
    if (-not $resultsFile) { return }
    $line = "{0}`t{1}`t{2}`t{3:n0}`t{4}" -f $shell, $Name, $Result, $Seconds, $Detail
    Add-Content -LiteralPath $resultsFile -Value $line -Encoding UTF8
}

$script:current = $null
$script:stageClock = $null
function Start-Stage([string] $Name) {
    $script:current = $Name
    $script:stageClock = [Diagnostics.Stopwatch]::StartNew()
    Write-Host ''
    Write-Host "== $Name ($shell)" -ForegroundColor Cyan
}
function Complete-Stage([string] $Detail) {
    Add-Result $script:current 'passed' $script:stageClock.Elapsed.TotalSeconds $Detail
    Write-Host ("   {0} passed in {1:n1}s {2}" -f $script:current, $script:stageClock.Elapsed.TotalSeconds, $Detail) -ForegroundColor Green
}
function Stop-Checks([string] $Text) {
    if ($script:current) { Add-Result $script:current 'FAILED' $script:stageClock.Elapsed.TotalSeconds $Text }
    Write-Host "FAILED: $Text" -ForegroundColor Red
    exit 1
}

# CI keeps its modules in one fixed folder (SECONDLINE_MODULE_DIR) that the workflow
# caches, instead of wherever this PowerShell installs for the user. Every stage runs
# in a new process, so each one puts that folder first on the module path.
$moduleDir = $env:SECONDLINE_MODULE_DIR
if ($moduleDir) {
    if (-not (Test-Path -LiteralPath $moduleDir)) { New-Item -ItemType Directory -Path $moduleDir -Force | Out-Null }
    $env:PSModulePath = $moduleDir + [IO.Path]::PathSeparator + $env:PSModulePath
}

# Installs a module: into the cached folder in CI, otherwise for the current user.
function Install-CheckModule([string] $Name, [string] $MinimumVersion) {
    $common = @{ Name = $Name; Force = $true }
    if ($MinimumVersion) { $common.MinimumVersion = $MinimumVersion }
    if ($moduleDir) { Save-Module @common -Path $moduleDir }
    else {
        # Windows ships Pester 3.4 signed by Microsoft; a side-by-side 5.x needs -SkipPublisherCheck.
        Install-Module @common -Scope CurrentUser -SkipPublisherCheck
    }
}

function Test-PesterOk {
    return [bool] (Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge [version] '5.5' } | Select-Object -First 1)
}

# ------------------------------------------------------------ summary --
if ($Stage -contains 'Summary') {
    $rows = @()
    if ($resultsFile -and (Test-Path -LiteralPath $resultsFile)) { $rows = @(Get-Content -LiteralPath $resultsFile -Encoding UTF8) }
    $md = @('| Shell | Stage | Result | Seconds | Detail |', '|---|---|---|---:|---|')
    foreach ($r in $rows) {
        $p = $r -split "`t"
        $mark = if ($p[2] -eq 'passed') { 'passed' } else { '**FAILED**' }
        $md += "| $($p[0]) | $($p[1]) | $mark | $($p[3]) | $($p[4]) |"
    }
    if ($rows.Count -eq 0) { $md += '| | (no stages recorded) | | | |' }
    if ($env:GITHUB_STEP_SUMMARY) { Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value ($md -join "`n") -Encoding UTF8 }
    $md | ForEach-Object { Write-Host $_ }
    exit 0
}

# ------------------------------------------------------------ modules --
if ($Stage -contains 'Modules') {
    Start-Stage 'Modules'
    $installed = @()
    # In CI these normally come from the module cache, so nothing is installed.
    $needPssa = $runLint -and -not (Get-Module -ListAvailable PSScriptAnalyzer)
    if ($InstallMissing -and ($needPssa -or -not (Test-PesterOk))) {
        # Trusting the Gallery for this user avoids an untrusted-repository prompt,
        # which would hang an unattended run.
        Set-PSRepository PSGallery -InstallationPolicy Trusted
    }
    if (-not (Test-PesterOk)) {
        if (-not $InstallMissing) { Stop-Checks "Pester 5.5+ is not installed for $shell. Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force -SkipPublisherCheck" }
        Install-CheckModule Pester '5.5'
        $installed += 'Pester'
    }
    if ($needPssa) {
        if (-not $InstallMissing) { Stop-Checks "PSScriptAnalyzer is not installed for $shell. Install-Module PSScriptAnalyzer -Scope CurrentUser" }
        Install-CheckModule PSScriptAnalyzer
        $installed += 'PSScriptAnalyzer'
    }
    if ($installed.Count -gt 0) { Complete-Stage "(installed $($installed -join ', '))" } else { Complete-Stage '(already present)' }
}

# --------------------------------------------------------------- lint --
if ($Stage -contains 'Lint') {
    Start-Stage 'Lint'
    # Child scripts only set an exit code on failure; clear any leftover code first.
    $global:LASTEXITCODE = 0
    & (Join-Path $PSScriptRoot 'Test-Lint.ps1')
    if ($LASTEXITCODE -ne 0) { Stop-Checks 'lint findings (listed above)' }
    Complete-Stage ''
}

# ------------------------------------------------------- line endings --
if ($Stage -contains 'LineEndings') {
    Start-Stage 'LineEndings'
    Import-Module (Join-Path $repo 'SecondLine\SecondLine.psd1') -Force
    try { $null = Test-SLLineEnding -Path $repo -Depth 0 -Strict }
    catch { Stop-Checks "line endings: $($_.Exception.Message)" }
    finally { Remove-Module SecondLine -ErrorAction SilentlyContinue }
    Complete-Stage ''
}

# ------------------------------------------------------------ package --
if ($Stage -contains 'Package') {
    Start-Stage 'Package'
    $global:LASTEXITCODE = 0
    try { & (Join-Path $PSScriptRoot 'Test-SecondLinePackage.ps1') }
    catch { Stop-Checks "package: $($_.Exception.Message)" }
    if ($LASTEXITCODE -ne 0) { Stop-Checks 'package validation (listed above)' }
    Complete-Stage ''
}

# -------------------------------------------------------------- tests --
if ($Stage -contains 'Tests') {
    Start-Stage 'Tests'
    Import-Module Pester -MinimumVersion 5.5
    $cfg = New-PesterConfiguration
    $cfg.Run.Path = (Join-Path $repo 'tests')
    $cfg.Run.PassThru = $true
    $cfg.Output.Verbosity = 'Detailed'
    if ($StopOnFirstFailure) { $cfg.Run.SkipRemainingOnFailure = 'Run' }
    $result = Invoke-Pester -Configuration $cfg
    $detail = "$($result.PassedCount) passed, $($result.FailedCount) failed, $($result.SkippedCount) skipped"
    if ($result.FailedCount -gt 0 -or $result.Result -ne 'Passed') { Stop-Checks $detail }
    Complete-Stage "($detail)"
}

Write-Host ''
Write-Host ("Done in {0:n0}s ({1}): {2}" -f $total.Elapsed.TotalSeconds, $shell, ($Stage -join ', ')) -ForegroundColor Green
exit 0
