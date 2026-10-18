<#
.SYNOPSIS
    Publishes the SecondLine module to the PowerShell Gallery, start to finish.

.DESCRIPTION
    One command for a release:

      0. Prerequisites  installs what's missing (PSResourceGet, Pester 5.5+)
      1. Manifest       valid, with ProjectUri and LicenseUri
      2. Changelog      has an entry for this version
      3. Git            clean, pushed, tag free
      4. Gallery        this version isn't already published
      5. Tests          pass in a fresh PowerShell process
      6. Package        stages ONLY the module folder plus LICENSE
      7. Publish        asks for the API key at a hidden prompt
      8. Tag            creates and pushes vX.Y.Z
      9. Visibility     offers to make the GitHub repo public (asks first)

    Nothing is published unless every check passes. The API key is never
    written to disk, logged, or stored in the repo.

.PARAMETER WhatIf
    Run every check and show the package, but publish nothing.

.PARAMETER SkipTests
    Skip step 5. Not recommended.

.PARAMETER MakePublic
    Step 9: make the GitHub repo public without asking.

.PARAMETER KeepPrivate
    Step 9: leave the GitHub repo private without asking.

.NOTES
    The API key is read from the SECONDLINE_GALLERY_KEY environment variable if
    it is set (for automation); otherwise it is asked for at a hidden prompt.

.EXAMPLE
    .\build\Publish-SecondLine.ps1 -WhatIf

.EXAMPLE
    .\build\Publish-SecondLine.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Repository = 'PSGallery',
    [string] $GitHubRepo = 'douglaine/SecondLine',
    [switch] $SkipTests,
    [switch] $MakePublic,
    [switch] $KeepPrivate
)

$ErrorActionPreference = 'Stop'
$Repo      = Split-Path $PSScriptRoot -Parent
$ModuleDir = Join-Path $Repo 'SecondLine'
$Manifest  = Join-Path $ModuleDir 'SecondLine.psd1'
$stage     = $null

# ---------------------------------------------------------------- helpers --

function Write-Step([string] $Text) { Write-Host ''; Write-Host $Text -ForegroundColor Cyan }
function Write-Ok([string] $Text)   { Write-Host "    OK    $Text" -ForegroundColor Green }
function Write-Do([string] $Text)   { Write-Host "    ...   $Text" -ForegroundColor Yellow }
function Write-Info([string] $Text) { Write-Host "          $Text" -ForegroundColor DarkGray }
function Stop-Publish([string] $Text) {
    Write-Host "    FAIL  $Text" -ForegroundColor Red
    if ($script:stage -and (Test-Path $script:stage)) {
        Remove-Item $script:stage -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false
    }
    exit 1
}

# Runs a native command under 'Continue' (so Windows PowerShell 5.1 can't abort
# on stderr) and returns its output and exit code.
function Invoke-Native([string] $Exe, [string[]] $Arguments) {
    $out = & { $ErrorActionPreference = 'Continue'; & $Exe @Arguments 2>&1 }
    return [pscustomobject]@{ Output = ($out | Out-String).Trim(); Code = $LASTEXITCODE }
}

function Get-PesterOk {
    return [bool](Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge [version]'5.5' })
}

# --------------------------------------------------------------- the run --

Push-Location $Repo
try {
    Write-Host ''
    Write-Host '  SecondLine - publish' -ForegroundColor White
    Write-Info "PowerShell $($PSVersionTable.PSVersion) | repo $Repo"

    # -------------------------------------------------------- 0. prereqs --
    Write-Step '[0] Prerequisites'

    foreach ($tool in 'git', 'gh') {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            Stop-Publish "'$tool' is not on PATH. Install it: winget install --id $(if ($tool -eq 'git') {'Git.Git'} else {'GitHub.cli'}) -e"
        }
    }
    Write-Ok 'git and gh found'

    # PSResourceGet ships with PowerShell 7.4+. On older shells, install it.
    if (-not (Get-Command Publish-PSResource -ErrorAction SilentlyContinue)) {
        Write-Do 'Installing Microsoft.PowerShell.PSResourceGet (one time)'
        try {
            Install-Module Microsoft.PowerShell.PSResourceGet -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            Import-Module Microsoft.PowerShell.PSResourceGet -ErrorAction Stop
        }
        catch { Stop-Publish "Could not install PSResourceGet: $($_.Exception.Message)" }
    }
    Write-Ok 'PSResourceGet available'

    # Windows ships Pester 3.4 signed by Microsoft; a side-by-side 5.x needs
    # -Force and -SkipPublisherCheck. (See GOTCHAS.md.)
    if (-not $SkipTests -and -not (Get-PesterOk)) {
        Write-Do 'Installing Pester 5.5+ (one time)'
        try {
            Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force -SkipPublisherCheck -ErrorAction Stop
        }
        catch { Stop-Publish "Could not install Pester: $($_.Exception.Message)" }
        if (-not (Get-PesterOk)) { Stop-Publish 'Pester 5.5+ still not found after install.' }
    }
    if (-not $SkipTests) { Write-Ok 'Pester 5.5+ available' }

    # ------------------------------------------------------- 1. manifest --
    Write-Step '[1] Manifest'
    try { $info = Test-ModuleManifest -Path $Manifest -ErrorAction Stop }
    catch { Stop-Publish "Manifest is not valid: $($_.Exception.Message)" }
    $Version = $info.Version.ToString()
    Write-Ok "SecondLine $Version"
    foreach ($key in 'ProjectUri', 'LicenseUri') {
        if (-not $info.PrivateData.PSData[$key]) { Stop-Publish "Manifest PSData is missing $key." }
    }
    Write-Ok 'ProjectUri and LicenseUri set'

    # ------------------------------------------------------ 2. changelog --
    Write-Step '[2] Changelog'
    $changelog = Join-Path $Repo 'CHANGELOG.md'
    if (-not (Test-Path $changelog)) { Stop-Publish 'CHANGELOG.md not found.' }
    if (-not (Select-String -Path $changelog -Pattern ('^## ' + [regex]::Escape($Version) + '\b') -Quiet)) {
        Stop-Publish "CHANGELOG.md has no '## $Version' entry. Add one first."
    }
    Write-Ok "CHANGELOG.md has an entry for $Version"

    # ------------------------------------------------------------ 3. git --
    Write-Step '[3] Git'
    $dirty = Invoke-Native git @('status', '--porcelain')
    if ($dirty.Output) {
        Write-Info $dirty.Output
        Stop-Publish 'Working tree has uncommitted changes. Commit or stash them first.'
    }
    Write-Ok 'Working tree clean'
    [void] (Invoke-Native git @('fetch', '--quiet', '--tags'))
    $local  = (Invoke-Native git @('rev-parse', 'HEAD')).Output
    $remote = (Invoke-Native git @('rev-parse', '@{u}')).Output
    if ($local -ne $remote) { Stop-Publish 'Local branch and its upstream differ. Push (or pull) first.' }
    Write-Ok "HEAD $($local.Substring(0, 7)) matches origin"
    $tag = "v$Version"
    if ((Invoke-Native git @('tag', '--list', $tag)).Output) { Stop-Publish "Tag $tag already exists. Bump ModuleVersion first." }
    Write-Ok "Tag $tag is free"

    # -------------------------------------------------------- 4. gallery --
    Write-Step '[4] PowerShell Gallery'
    $existing = $null
    # Run from temp: on machines without a user settings folder, PSResourceGet
    # writes NuGet/NuGet.Config into the current directory.
    Push-Location ([IO.Path]::GetTempPath())
    try { $existing = Find-PSResource -Name SecondLine -Version $Version -Repository $Repository -ErrorAction Stop }
    catch { $existing = $null }   # "not found" throws; that's the answer we want
    finally { Pop-Location }
    if ($existing) { Stop-Publish "SecondLine $Version is already on $Repository. Bump ModuleVersion first." }
    Write-Ok "$Version is not on $Repository yet"

    # ---------------------------------------------------------- 5. tests --
    Write-Step '[5] Tests'
    if ($SkipTests) {
        Write-Info 'Skipped (-SkipTests).'
    }
    else {
        # Fresh process, so a module already loaded here can't hide a missing import.
        $exe = (Get-Process -Id $PID).Path
        $testCmd = "Import-Module Pester -MinimumVersion 5.5; " +
                   "`$c = New-PesterConfiguration; `$c.Run.Path = 'tests'; `$c.Run.Exit = `$true; " +
                   "`$c.Output.Verbosity = 'Normal'; Invoke-Pester -Configuration `$c"
        & $exe -NoProfile -Command $testCmd
        if ($LASTEXITCODE -ne 0) { Stop-Publish 'Tests failed.' }
        Write-Ok 'All tests pass'
    }

    # -------------------------------------------------------- 6. package --
    Write-Step '[6] Package contents'
    $stage = Join-Path ([IO.Path]::GetTempPath()) ('SecondLine-publish-' + [guid]::NewGuid().ToString('N'))
    $stageModule = Join-Path $stage 'SecondLine'
    New-Item -ItemType Directory -Path $stageModule -WhatIf:$false | Out-Null
    Copy-Item -Path (Join-Path $ModuleDir '*') -Destination $stageModule -Recurse -WhatIf:$false
    Copy-Item -Path (Join-Path $Repo 'LICENSE') -Destination $stageModule -WhatIf:$false
    Get-ChildItem $stageModule -Recurse -File | ForEach-Object {
        Write-Info $_.FullName.Substring($stageModule.Length + 1)
    }

    if (-not $PSCmdlet.ShouldProcess("SecondLine $Version", "Publish to $Repository and tag $tag")) {
        Remove-Item $stage -Recurse -Force -WhatIf:$false
        Write-Host ''
        Write-Host '  Dry run only - all checks passed, nothing was published.' -ForegroundColor Yellow
        Write-Host ''
        exit 0
    }

    # -------------------------------------------------------- 7. publish --
    Write-Step '[7] Publish'
    $bstr = [IntPtr]::Zero
    if ($env:SECONDLINE_GALLERY_KEY) {
        Write-Info 'Using the API key from SECONDLINE_GALLERY_KEY.'
        $key = $env:SECONDLINE_GALLERY_KEY
    }
    else {
        Write-Info 'Paste your PowerShell Gallery API key. Nothing will show as you paste; that is normal.'
        $secure = Read-Host -Prompt '  API key' -AsSecureString
        if (-not $secure -or $secure.Length -eq 0) { Stop-Publish 'No key entered. Nothing was published.' }
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        $key = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    try {
        # Run from the staging folder so any file the publisher writes to the
        # current directory lands in temp and is deleted, never in the repo.
        Push-Location $stage
        try { Publish-PSResource -Path $stageModule -Repository $Repository -ApiKey $key -ErrorAction Stop }
        finally { Pop-Location }
    }
    catch {
        $msg = $_.Exception.Message
        if ($msg -match '403|Forbidden|API key') {
            $msg += ' (Check the key: scope "Push new packages", glob "SecondLine", not expired.)'
        }
        Stop-Publish "Publish failed: $msg"
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        $key = $null
    }
    Write-Ok "Published SecondLine $Version"
    Write-Info "https://www.powershellgallery.com/packages/SecondLine/$Version"

    # ------------------------------------------------------------ 8. tag --
    Write-Step '[8] Tag'
    $t = Invoke-Native git @('tag', '-a', $tag, '-m', "SecondLine $Version")
    if ($t.Code -ne 0) {
        Write-Info $t.Output
        Write-Host "    WARN  Published, but creating tag $tag failed. Run: git tag -a $tag -m ""SecondLine $Version""; git push origin $tag" -ForegroundColor Yellow
    }
    else {
        $p = Invoke-Native git @('push', 'origin', $tag)
        if ($p.Code -ne 0) {
            Write-Info $p.Output
            Write-Host "    WARN  Published and tagged, but pushing the tag failed. Run: git push origin $tag" -ForegroundColor Yellow
        }
        else { Write-Ok "Tagged and pushed $tag" }
    }

    # ----------------------------------------------------- 9. visibility --
    Write-Step '[9] GitHub visibility'
    $vis = Invoke-Native gh @('repo', 'view', $GitHubRepo, '--json', 'visibility', '-q', '.visibility')
    if ($vis.Code -ne 0) {
        Write-Info $vis.Output
        Write-Host '    WARN  Could not read repo visibility. Make it public by hand when ready.' -ForegroundColor Yellow
    }
    elseif ($vis.Output -eq 'PUBLIC') {
        Write-Ok 'Repo is already public'
    }
    else {
        Write-Info "The repo is $($vis.Output). The Gallery page links to it, so it 404s for others until it's public."
        Write-Info 'Going public exposes all files and full commit history, including commit author emails.'
        if ($MakePublic)       { $answer = 'y' }
        elseif ($KeepPrivate)  { $answer = 'n' }
        else                   { $answer = Read-Host '  Make the GitHub repo public now? [y/N]' }
        if ($answer -match '^(y|yes)$') {
            $r = Invoke-Native gh @('repo', 'edit', $GitHubRepo, '--visibility', 'public', '--accept-visibility-change-consequences')
            if ($r.Code -ne 0) {
                Write-Info $r.Output
                Write-Host "    WARN  Could not change visibility. Run: gh repo edit $GitHubRepo --visibility public --accept-visibility-change-consequences" -ForegroundColor Yellow
            }
            else { Write-Ok "Repo is now public: https://github.com/$GitHubRepo" }
        }
        else {
            Write-Info "Left private. When ready: gh repo edit $GitHubRepo --visibility public --accept-visibility-change-consequences"
        }
    }

    Write-Host ''
    Write-Host "  Done. SecondLine $Version is on the PowerShell Gallery." -ForegroundColor Green
    Write-Info 'New packages take a few minutes to index before Install-PSResource finds them.'
    Write-Host ''
}
finally {
    # Always remove the staging folder, even if the run was interrupted.
    if ($stage -and (Test-Path $stage)) {
        Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false
    }
    Pop-Location
}
