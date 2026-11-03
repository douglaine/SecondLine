<#
.SYNOPSIS
    Imports the SecondLine version a project approves, before anything else loads SecondLine.

.DESCRIPTION
    SecondLine-Bootstrap: 1

    A loaded module can't choose its own version, so this script chooses it first.
    It reads only data files and imports nothing until it knows the version:

      1. Finds the project standard: -Standard, then SECONDLINE_STANDARD, then the
         nearest secondline.standard.psd1 in -Path or one of its parents.
      2. Follows the file's Extends chain. Relative parents resolve from the file
         that declares them. A cycle, or a chain longer than 64 files, is an error.
         '@development' ends the chain here, because the packaged baseline lives in
         the package that hasn't been chosen yet. That baseline never pins versions.
      3. Gets ModuleVersions from each layer, lowest precedence first: machine
         settings, user settings, then the project chain from its root parent to the
         nearest file. A project value always wins. A user value is ignored where the
         project sets one, and Get-SLSetting shows that it was overridden.
      4. Imports exactly that version with -RequiredVersion. It never installs or
         updates anything. If the version isn't installed, it says how to install it.

    In CI (CI, GITHUB_ACTIONS or TF_BUILD set), or with SECONDLINE_NO_HOST_SETTINGS=1,
    the machine and user settings files are ignored, so the project files alone
    decide the version.

    Copy this file into a consuming repository (for example build/Import-SecondLine.ps1)
    and run it with the call operator. Test-SLPolicyReference reports when the copy
    is older than the bootstrap in the installed SecondLine.

.PARAMETER Path
    The folder where the standard search starts. Default: the current folder.
    Scripts should pass $PSScriptRoot.

.PARAMETER Standard
    An explicit standard file. This overrides SECONDLINE_STANDARD and the search.

.PARAMETER Name
    The module to import. Default: SecondLine.

.PARAMETER AllowUnpinned
    If no layer approves a version, import the highest installed version instead of failing.

.PARAMETER NoHostSettings
    Ignore the machine and user settings files.

.PARAMETER PassThru
    Return the selection: Name, Version, Source and the imported module.

.PARAMETER LibraryOnly
    Only define the functions. SecondLine itself uses this to share one implementation.

.EXAMPLE
    & "$PSScriptRoot\Import-SecondLine.ps1" -Path $PSScriptRoot
#>
[CmdletBinding()]
param(
    [string] $Path,
    [string] $Standard,
    [string] $Name = 'SecondLine',
    [switch] $AllowUnpinned,
    [switch] $NoHostSettings,
    [switch] $PassThru,
    [switch] $LibraryOnly
)

# The bootstrap format, compared by Test-SLPolicyReference with vendored copies.
$script:SLBootstrapVersion = 1

# Nearest secondline.standard.psd1 in Directory or one of its parents, else $null.
function Find-SLStandardPath {
    param([string] $Directory = (Get-Location).ProviderPath)
    $folder = [IO.DirectoryInfo] $Directory
    while ($null -ne $folder) {
        $candidate = Join-Path $folder.FullName 'secondline.standard.psd1'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        $folder = $folder.Parent
    }
    return $null
}

# The standard to use: explicit path, then SECONDLINE_STANDARD, then the nearest parent.
function Resolve-SLStandardLocation {
    param([string] $Path, [string] $Directory)
    if ($Path) { return $Path }
    if ($env:SECONDLINE_STANDARD) { return $env:SECONDLINE_STANDARD }
    if (-not $Directory) { $Directory = (Get-Location).ProviderPath }
    return (Find-SLStandardPath -Directory $Directory)
}

# Reads a standard and its Extends parents, nearest first, as objects with Path and Data.
# DevelopmentPath resolves '@development'. Without it, the chain stops there.
function Get-SLStandardChain {
    param([Parameter(Mandatory)] [string] $Path, [string] $DevelopmentPath)
    $chain = @()
    $stack = @()
    $current = $Path
    while ($current) {
        $resolved = (Resolve-Path -LiteralPath $current -ErrorAction Stop).ProviderPath
        if ($stack -contains $resolved) { throw "Circular SecondLine inheritance: $(@($stack + $resolved) -join ' -> ')" }
        if ($stack.Count -ge 64) { throw 'SecondLine inheritance exceeds 64 files.' }
        try { $data = Import-PowerShellDataFile -LiteralPath $resolved -ErrorAction Stop }
        catch { throw "Could not read $resolved as a PowerShell data file: $($_.Exception.Message)" }
        $stack += $resolved
        $chain += [pscustomobject]@{ Path = $resolved; Data = $data }
        $current = $null
        if (-not $data.ContainsKey('Extends')) { break }
        if ($data.Extends -isnot [string] -or -not $data.Extends.Trim()) {
            throw "SecondLine standard $resolved requires Extends to be a nonempty string."
        }
        $parent = $data.Extends
        if ($parent -eq '@development') {
            if (-not $DevelopmentPath) { break }
            $parent = $DevelopmentPath
        }
        elseif (-not [IO.Path]::IsPathRooted($parent)) {
            $parent = Join-Path (Split-Path $resolved -Parent) $parent
        }
        if (-not (Test-Path -LiteralPath $parent -PathType Leaf)) { throw "SecondLine parent standard not found: $parent (from $resolved)." }
        $current = $parent
    }
    return $chain
}

# True when running under a CI service, where personal settings must not apply.
function Test-SLCIEnvironment {
    return [bool] ($env:CI -eq 'true' -or $env:GITHUB_ACTIONS -eq 'true' -or $env:TF_BUILD)
}

# Paths of the machine and user settings files. SECONDLINE_MACHINE_SETTINGS and
# SECONDLINE_USER_SETTINGS override them, for tests and unusual layouts.
function Get-SLHostSettingsPath {
    $machine = $env:SECONDLINE_MACHINE_SETTINGS
    if (-not $machine) { $machine = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'SecondLine\settings.psd1' }
    $user = $env:SECONDLINE_USER_SETTINGS
    if (-not $user) { $user = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'SecondLine\settings.psd1' }
    return [pscustomobject]@{ Machine = $machine; User = $user }
}

# Machine then user settings, as layers: Scope, Path, Data. An unreadable settings
# file is an error, not silently skipped. Returns nothing when host settings are off.
function Get-SLHostSettingsLayer {
    param([switch] $NoHostSettings)
    if ($NoHostSettings -or $env:SECONDLINE_NO_HOST_SETTINGS -eq '1' -or (Test-SLCIEnvironment)) { return }
    $paths = Get-SLHostSettingsPath
    foreach ($scope in 'Machine', 'User') {
        $file = $paths.$scope
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        try { $data = Import-PowerShellDataFile -LiteralPath $file -ErrorAction Stop }
        catch { throw "Could not read SecondLine $($scope.ToLowerInvariant()) settings $($file): $($_.Exception.Message)" }
        [pscustomobject]@{ Scope = $scope; Path = $file; Data = $data }
    }
}

# Folds one hashtable section across layers, lowest precedence first. Returns
# name -> Name, Value, Source, Overridden (lower-precedence values that differed).
function Merge-SLSettingLayer {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Layers, [Parameter(Mandatory)] [string] $Section)
    $effective = @{}
    foreach ($layer in $Layers) {
        if (-not $layer.Data.ContainsKey($Section)) { continue }
        $table = $layer.Data[$Section]
        if ($table -isnot [hashtable]) { throw "$Section in $($layer.Source) must be @{ Name = value }." }
        foreach ($key in $table.Keys) {
            $overridden = @()
            if ($effective.ContainsKey($key)) {
                $previous = $effective[$key]
                $overridden = @($previous.Overridden)
                if ("$($previous.Value)" -ne "$($table[$key])") {
                    $overridden += [pscustomobject]@{ Value = $previous.Value; Source = $previous.Source }
                }
            }
            $effective[$key] = [pscustomobject]@{ Name = "$key"; Value = $table[$key]; Source = $layer.Source; Overridden = $overridden }
        }
    }
    return $effective
}

# The project chain as layers, root parent first, so the nearest file has the highest precedence.
function Get-SLProjectSettingsLayer {
    param([string] $Standard, [string] $Directory, [string] $DevelopmentPath)
    $location = Resolve-SLStandardLocation -Path $Standard -Directory $Directory
    if (-not $location) { return }
    if (-not (Test-Path -LiteralPath $location -PathType Leaf)) { throw "SecondLine standard not found: $location." }
    $chain = @(Get-SLStandardChain -Path $location -DevelopmentPath $DevelopmentPath)
    for ($i = $chain.Count - 1; $i -ge 0; $i--) {
        [pscustomobject]@{ Scope = 'Project'; Path = $chain[$i].Path; Data = $chain[$i].Data; Source = "project $($chain[$i].Path)" }
    }
}

# The approved version of each module: machine < user < project chain (nearest wins).
# Every value must be a plain numeric version, because Import-Module -RequiredVersion needs one.
function Resolve-SLModuleVersionPolicy {
    param([string] $Standard, [string] $Directory, [switch] $NoHostSettings, [string] $DevelopmentPath)
    $layers = @()
    foreach ($h in @(Get-SLHostSettingsLayer -NoHostSettings:$NoHostSettings)) {
        $layers += [pscustomobject]@{ Scope = $h.Scope; Path = $h.Path; Data = $h.Data; Source = "$($h.Scope.ToLowerInvariant()) $($h.Path)" }
    }
    $layers += @(Get-SLProjectSettingsLayer -Standard $Standard -Directory $Directory -DevelopmentPath $DevelopmentPath)
    $policy = Merge-SLSettingLayer -Layers $layers -Section 'ModuleVersions'
    foreach ($entry in $policy.Values) {
        if ("$($entry.Value)" -notmatch '^\d+(\.\d+){1,3}$') {
            throw "ModuleVersions.$($entry.Name) = '$($entry.Value)' in $($entry.Source) is not a version like 0.4.0."
        }
    }
    return $policy
}

# Picks and imports the approved version. Never installs anything.
function Import-SLApprovedModule {
    param(
        [string] $Name = 'SecondLine',
        [string] $Standard,
        [string] $Directory,
        [switch] $AllowUnpinned,
        [switch] $NoHostSettings
    )
    $policy = Resolve-SLModuleVersionPolicy -Standard $Standard -Directory $Directory -NoHostSettings:$NoHostSettings
    $installed = @(Get-Module -ListAvailable -Name $Name | Sort-Object Version -Descending)
    $entry = $null
    if ($policy.ContainsKey($Name)) { $entry = $policy[$Name] }
    if ($entry) {
        $version = [version] "$($entry.Value)"
        $source = $entry.Source
    }
    elseif ($AllowUnpinned -and $installed.Count -gt 0) {
        $version = $installed[0].Version
        $source = 'highest installed (-AllowUnpinned)'
    }
    else {
        throw "No approved $Name version. Add ModuleVersions = @{ $Name = '<version>' } to the project's secondline.standard.psd1, or pass -AllowUnpinned."
    }

    $loaded = @(Get-Module -Name $Name)
    if ($loaded.Count -gt 0) {
        if (@($loaded | Where-Object { $_.Version -ne $version }).Count -eq 0) {
            return [pscustomobject]@{ Name = $Name; Version = $version; Source = $source; Module = $loaded[0]; AlreadyLoaded = $true }
        }
        throw ("$Name $(($loaded.Version | ForEach-Object { "$_" }) -join ', ') is already loaded in this session, but $source approves $version. " +
            "A loaded module can't be swapped reliably. Open a new PowerShell session and run the bootstrap before anything imports $Name.")
    }
    if (-not ($installed | Where-Object { $_.Version -eq $version })) {
        $have = 'none'
        if ($installed.Count -gt 0) { $have = ($installed.Version | ForEach-Object { "$_" }) -join ', ' }
        throw ("$Name $version is approved by $source but is not installed (installed: $have). Nothing was installed. " +
            "To install it, review and run: Install-PSResource $Name -Version $version   (Windows PowerShell 5.1: Install-Module $Name -RequiredVersion $version -Scope CurrentUser)")
    }
    $module = Import-Module -Name $Name -RequiredVersion $version -Global -PassThru -ErrorAction Stop
    return [pscustomobject]@{ Name = $Name; Version = $version; Source = $source; Module = $module; AlreadyLoaded = $false }
}

if ($LibraryOnly) { return }

$ErrorActionPreference = 'Stop'
if (-not $Path) { $Path = (Get-Location).ProviderPath }
$selection = Import-SLApprovedModule -Name $Name -Standard $Standard -Directory $Path -AllowUnpinned:$AllowUnpinned -NoHostSettings:$NoHostSettings
Write-Verbose "$($selection.Name) $($selection.Version) selected by $($selection.Source)."
if ($PassThru) { $selection }
