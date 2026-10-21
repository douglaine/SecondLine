function Get-SecondLineStandard {
    <#
    .SYNOPSIS
        Loads and validates a SecondLine standard file.

    .DESCRIPTION
        A standard is a .psd1 file listing the tools every machine should have,
        the version each should be at, and the rule used to compare versions.

        It can also have a GitAttributes section, used by Test-SLRepo and
        Set-SLGitAttributes, to add or replace line-ending profiles and pin repos
        to a profile:

          GitAttributes = @{
              Profiles = @{ web = @('* text=auto', '*.ts text eol=lf', '*.png binary') }
              Repos    = @{ 'docs-site' = 'docs' }
          }

        A standard needs Tools, GitAttributes, or both.

        Where the file is looked for, in order:
          1. -Path
          2. the SECONDLINE_STANDARD environment variable
          3. nearest secondline.standard.psd1 in the current folder or its parents

    .EXAMPLE
        Get-SecondLineStandard -Path .\secondline.standard.psd1
    #>
    [CmdletBinding()]
    param(
        [string] $Path
    )

    if (-not $Path) { $Path = $env:SECONDLINE_STANDARD }
    if (-not $Path) { $Path = Find-SLStandardPath }
    if (-not $Path) { throw 'SecondLine standard not found in the current folder or its parents.' }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "SecondLine standard not found: $Path. Pass -Path, set SECONDLINE_STANDARD, or put secondline.standard.psd1 in the current folder."
    }
    $Path = (Resolve-Path -LiteralPath $Path).ProviderPath

    try {
        $data = Read-SLStandardData -Path $Path
    }
    catch {
        throw "Could not read $Path as a PowerShell data file: $($_.Exception.Message)"
    }

    $problems = New-Object System.Collections.Generic.List[string]
    $hasTools = $data.ContainsKey('Tools') -and $null -ne $data.Tools -and @($data.Tools).Count -gt 0
    if (-not $hasTools -and -not $data.ContainsKey('GitAttributes')) {
        $problems.Add("'Tools' is missing or empty. Add at least one tool, or a GitAttributes section.")
    }

    $tools = @()
    $toolEntries = @()
    if ($hasTools) { $toolEntries = @($data.Tools) }
    $i = 0
    foreach ($t in $toolEntries) {
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

        $match = 'First'
        if ($t.ContainsKey('Match')) { $match = "$($t.Match)" }
        if (@('First', 'Any') -notcontains $match) {
            $problems.Add("$label has Match '$match'. Use First (default) or Any.")
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
            Match          = $match
            VersionPattern = "$($t.VersionPattern)"
            Install        = "$($t.Install)"
            TimeoutSeconds = $timeout
        }
    }

    $gitAttributes = $null
    if ($data.ContainsKey('GitAttributes')) {
        $gitAttributes = ConvertTo-SLGitAttributesSection -Section $data.GitAttributes -Problems $problems
    }

    if ($problems.Count -gt 0) {
        throw ("SecondLine standard $Path has problems:`n  - " + ($problems -join "`n  - "))
    }

    $name = 'SecondLine standard'
    if ($data.Name) { $name = "$($data.Name)" }
    $version = ''
    if ($data.Version) { $version = "$($data.Version)" }

    [pscustomobject]@{
        Name          = $name
        Version       = $version
        Path          = $Path
        Tools         = $tools
        GitAttributes = $gitAttributes
    }
}
