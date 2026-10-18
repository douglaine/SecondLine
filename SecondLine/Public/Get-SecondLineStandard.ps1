function Get-SecondLineStandard {
    <#
    .SYNOPSIS
        Loads and validates a SecondLine standard file.

    .DESCRIPTION
        A standard is a .psd1 file listing the tools every machine should have,
        the version each should be at, and the rule used to compare versions.

        Where the file is looked for, in order:
          1. -Path
          2. the SECONDLINE_STANDARD environment variable
          3. secondline.standard.psd1 in the current folder

    .EXAMPLE
        Get-SecondLineStandard -Path .\secondline.standard.psd1
    #>
    [CmdletBinding()]
    param(
        [string] $Path
    )

    if (-not $Path) { $Path = $env:SECONDLINE_STANDARD }
    if (-not $Path) { $Path = Join-Path (Get-Location) 'secondline.standard.psd1' }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "SecondLine standard not found: $Path. Pass -Path, set SECONDLINE_STANDARD, or put secondline.standard.psd1 in the current folder."
    }
    $Path = (Resolve-Path -LiteralPath $Path).ProviderPath

    try {
        $data = Import-PowerShellDataFile -LiteralPath $Path
    }
    catch {
        throw "Could not read $Path as a PowerShell data file: $($_.Exception.Message)"
    }

    $problems = New-Object System.Collections.Generic.List[string]
    if (-not $data.ContainsKey('Tools') -or @($data.Tools).Count -eq 0) {
        $problems.Add("'Tools' is missing or empty.")
    }

    $tools = @()
    $i = 0
    foreach ($t in @($data.Tools)) {
        $i++
        $label = "Tools[$i]"
        if ($t -isnot [hashtable]) { $problems.Add("$label is not a @{ ... } entry."); continue }
        if ($t.Name) { $label = "Tools[$i] ($($t.Name))" }

        foreach ($key in 'Name', 'Command', 'Expect', 'Rule') {
            if (-not $t.ContainsKey($key) -or -not "$($t[$key])") { $problems.Add("$label is missing '$key'.") }
        }
        if ($t.Rule -and $script:SLRules -notcontains $t.Rule) {
            $problems.Add("$label has Rule '$($t.Rule)'. Use one of: $($script:SLRules -join ', ').")
        }
        if ($t.Expect -and $null -eq (ConvertTo-SLVersionParts "$($t.Expect)")) {
            $problems.Add("$label has Expect '$($t.Expect)', which is not a version number like 8.0 or 2.13.1.")
        }

        $arguments = '--version'
        if ($t.ContainsKey('Arguments')) { $arguments = "$($t.Arguments)" }
        $timeout = 15
        if ($t.ContainsKey('TimeoutSeconds')) { $timeout = [int] $t.TimeoutSeconds }

        $tools += [pscustomobject]@{
            Name           = "$($t.Name)"
            Command        = "$($t.Command)"
            Arguments      = $arguments
            Expect         = "$($t.Expect)"
            Rule           = "$($t.Rule)"
            VersionPattern = "$($t.VersionPattern)"
            Install        = "$($t.Install)"
            TimeoutSeconds = $timeout
        }
    }

    if ($problems.Count -gt 0) {
        throw ("SecondLine standard $Path has problems:`n  - " + ($problems -join "`n  - "))
    }

    $name = 'SecondLine standard'
    if ($data.Name) { $name = "$($data.Name)" }
    $version = ''
    if ($data.Version) { $version = "$($data.Version)" }

    [pscustomobject]@{
        Name    = $name
        Version = $version
        Path    = $Path
        Tools   = $tools
    }
}
