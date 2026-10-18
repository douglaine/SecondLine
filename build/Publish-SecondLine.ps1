<#
.SYNOPSIS
    Publishes the SecondLine module to the PowerShell Gallery.

.DESCRIPTION
    Checks everything first, and stops before publishing if anything is off:
      - the manifest is valid
      - CHANGELOG.md has an entry for this version
      - the git working tree is clean and pushed (what you publish is what's on GitHub)
      - this version is not already on the Gallery
      - the Pester tests pass in a fresh PowerShell process

    Then stages ONLY the module folder (plus LICENSE) into a temp folder,
    publishes it, and tags the commit vX.Y.Z on GitHub.

    The API key is asked for at a hidden prompt. It is never written to disk,
    never logged, and never stored in the repo.

.EXAMPLE
    .\build\Publish-SecondLine.ps1 -WhatIf     # all checks, no publish

.EXAMPLE
    .\build\Publish-SecondLine.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Repository = 'PSGallery',
    [switch] $SkipTests
)

$ErrorActionPreference = 'Stop'
$Repo       = Split-Path $PSScriptRoot -Parent
$ModuleDir  = Join-Path $Repo 'SecondLine'
$Manifest   = Join-Path $ModuleDir 'SecondLine.psd1'

# ---------------------------------------------------------------- helpers --

function Write-Step([string] $Text) { Write-Host ''; Write-Host $Text -ForegroundColor Cyan }
function Write-Ok([string] $Text)   { Write-Host "    OK    $Text" -ForegroundColor Green }
function Write-Info([string] $Text) { Write-Host "          $Text" -ForegroundColor DarkGray }
function Stop-Publish([string] $Text) {
    Write-Host "    FAIL  $Text" -ForegroundColor Red
    exit 1
}

# Native calls under 'Continue' so Windows PowerShell 5.1 can't abort on stderr.
function Invoke-Git {
    $out = & { $ErrorActionPreference = 'Continue'; & git @args 2>&1 } @args
    return @{ Output = ($out | Out-String).Trim(); Code = $LASTEXITCODE }
}

# ------------------------------------------------------------------ checks --

Push-Location $Repo
try {
    Write-Host ''
    Write-Host '  SecondLine - publish' -ForegroundColor White

    Write-Step '[1] Manifest'
    try { $info = Test-ModuleManifest -Path $Manifest -ErrorAction Stop }
    catch { Stop-Publish "Manifest is not valid: $($_.Exception.Message)" }
    $Version = $info.Version.ToString()
    Write-Ok "SecondLine $Version"
    foreach ($key in 'ProjectUri', 'LicenseUri') {
        if (-not $info.PrivateData.PSData[$key]) { Stop-Publish "Manifest PSData is missing $key." }
    }
    Write-Ok 'ProjectUri and LicenseUri set'

    Write-Step '[2] Changelog'
    $changelog = Join-Path $Repo 'CHANGELOG.md'
    if (-not (Test-Path $changelog)) { Stop-Publish 'CHANGELOG.md not found.' }
    if (-not (Select-String -Path $changelog -Pattern ("^## " + [regex]::Escape($Version) + "\b") -Quiet)) {
        Stop-Publish "CHANGELOG.md has no '## $Version' entry. Add one first."
    }
    Write-Ok "CHANGELOG.md has an entry for $Version"

    Write-Step '[3] Git'
    $dirty = Invoke-Git status --porcelain
    if ($dirty.Output) {
        Write-Info $dirty.Output
        Stop-Publish 'Working tree has uncommitted changes. Commit or stash them first.'
    }
    Write-Ok 'Working tree clean'
    [void] (Invoke-Git fetch --quiet)
    $local  = (Invoke-Git rev-parse HEAD).Output
    $remote = (Invoke-Git rev-parse '@{u}').Output
    if ($local -ne $remote) { Stop-Publish 'Local main and origin/main differ. Push (or pull) first.' }
    Write-Ok "HEAD $($local.Substring(0,7)) matches origin"
    $tag = "v$Version"
    if ((Invoke-Git tag --list $tag).Output) { Stop-Publish "Tag $tag already exists. Bump ModuleVersion first." }
    Write-Ok "Tag $tag is free"

    Write-Step '[4] PowerShell Gallery'
    $publishCmd = Get-Command Publish-PSResource -ErrorAction SilentlyContinue
    $findCmd    = Get-Command Find-PSResource -ErrorAction SilentlyContinue
    if (-not $publishCmd) {
        Stop-Publish 'Publish-PSResource not found. Use PowerShell 7.4+, or: Install-Module Microsoft.PowerShell.PSResourceGet -Scope CurrentUser'
    }
    $existing = $null
    try { $existing = Find-PSResource -Name SecondLine -Version $Version -Repository $Repository -ErrorAction Stop }
    catch { $existing = $null }
    if ($existing) { Stop-Publish "SecondLine $Version is already on $Repository. Bump ModuleVersion first." }
    Write-Ok "$Version is not on $Repository yet"

    Write-Step '[5] Tests'
    if ($SkipTests) {
        Write-Info 'Skipped (-SkipTests).'
    }
    else {
        if (-not (Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge [version]'5.5' })) {
            Stop-Publish 'Pester 5.5+ not installed. Run: Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser'
        }
        # Fresh process, so a module already loaded in this session can't hide a missing import.
        $exe = (Get-Process -Id $PID).Path
        $testCmd = "Import-Module Pester -MinimumVersion 5.5; `$c = New-PesterConfiguration; `$c.Run.Path = 'tests'; `$c.Run.Exit = `$true; `$c.Output.Verbosity = 'Normal'; Invoke-Pester -Configuration `$c"
        & $exe -NoProfile -Command $testCmd
        if ($LASTEXITCODE -ne 0) { Stop-Publish 'Tests failed.' }
        Write-Ok 'All tests pass'
    }

    Write-Step '[6] Package contents'
    $stage = Join-Path ([IO.Path]::GetTempPath()) ("SecondLine-publish-" + [guid]::NewGuid().ToString('N'))
    $stageModule = Join-Path $stage 'SecondLine'
    New-Item -ItemType Directory -Path $stageModule -WhatIf:$false | Out-Null
    Copy-Item -Path (Join-Path $ModuleDir '*') -Destination $stageModule -Recurse -WhatIf:$false
    Copy-Item -Path (Join-Path $Repo 'LICENSE') -Destination $stageModule -WhatIf:$false
    Get-ChildItem $stageModule -Recurse -File | ForEach-Object {
        Write-Info $_.FullName.Substring($stageModule.Length + 1)
    }

    if (-not $PSCmdlet.ShouldProcess("SecondLine $Version", "Publish to $Repository and tag $tag")) {
        Write-Host ''
        Write-Host '  Dry run only - all checks passed, nothing was published.' -ForegroundColor Yellow
        Remove-Item $stage -Recurse -Force -WhatIf:$false
        exit 0
    }

    Write-Step '[7] Publish'
    $secure = Read-Host -Prompt '  PowerShell Gallery API key (input hidden)' -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        $key = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        if (-not $key) { Stop-Publish 'No key entered.' }
        Publish-PSResource -Path $stageModule -Repository $Repository -ApiKey $key -ErrorAction Stop
    }
    catch {
        Stop-Publish "Publish failed: $($_.Exception.Message)"
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        $key = $null
        Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false
    }
    Write-Ok "Published SecondLine $Version"

    Write-Step '[8] Tag'
    $t = Invoke-Git tag -a $tag -m "SecondLine $Version"
    if ($t.Code -ne 0) { Write-Info $t.Output; Stop-Publish "Published, but creating tag $tag failed. Create it by hand." }
    $p = Invoke-Git push origin $tag
    if ($p.Code -ne 0) { Write-Info $p.Output; Stop-Publish "Published and tagged, but pushing $tag failed. Run: git push origin $tag" }
    Write-Ok "Tagged and pushed $tag"

    Write-Host ''
    Write-Host "  Done. https://www.powershellgallery.com/packages/SecondLine/$Version" -ForegroundColor Green
    Write-Info 'The Gallery takes a few minutes to index a new package before Install-PSResource finds it.'
    Write-Host ''
}
finally {
    Pop-Location
}
