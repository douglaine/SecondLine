function Test-SLRepo {
    <#
    .SYNOPSIS
        Checks git repos against the .gitattributes line-ending standard.

    .DESCRIPTION
        Finds git repos at or under -Path and, for each one, compares its
        .gitattributes with the right profile, and counts committed files that
        still need 'git add --renormalize .'.

        Status values:
          MATCHES  every profile rule is there, with the same attributes, nothing else
          EXTENDS  every profile rule is there, plus repo-specific rules (fine)
          DIFFERS  a profile rule is missing, or a pattern has different attributes
          MISSING  no .gitattributes

        A repo is OK when it MATCHES or EXTENDS and no file needs renormalizing.
        Files are compared by meaning: comments, blank lines, spacing and order
        don't matter, and 'binary' equals '-diff -merge -text'.

        Profiles: docs, powershell, dotnet (built in), plus any defined in the
        standard's GitAttributes section. Which one a repo gets, first match wins:
          1. -Profile
          2. the repo's folder name pinned in the standard (GitAttributes.Repos)
          3. dotnet:     a .sln, .slnx, .csproj or .fsproj within 3 folders
          4. powershell: a module manifest (.psd1 with RootModule or ModuleVersion) within 2
          5. docs:       anything else

        The standard is optional here. It is found like Get-SecondLineStandard
        finds it (-Standard, SECONDLINE_STANDARD, secondline.standard.psd1 in the
        current folder); if none is found, the built-in profiles are used.

        Read-only: nothing is changed. Set-SLGitAttributes fixes what this finds.

    .PARAMETER Path
        A repo, or a folder of repos. Default: the current folder.

    .PARAMETER Depth
        How many folders below -Path to look for repos. Default: 2. A repo's own
        subfolders are never searched, and node_modules, bin, obj, packages and
        .git are skipped.

    .PARAMETER Profile
        Use this profile for every repo found (overrides pins and detection).

    .PARAMETER Standard
        The standard file. See Get-SecondLineStandard.

    .PARAMETER PassThru
        Return one result object per repo instead of $true/$false.

    .PARAMETER Quiet
        Don't print the report.

    .OUTPUTS
        Without -PassThru: $true if every repo is OK, else $false (also when no repo is found).
        With -PassThru: one object per repo with Repo, Path, Profile, ProfileReason,
        Status, MissingRules, ConflictingRules, ExtraRules, FilesToRenormalize,
        RenormalizeSample and Note.

    .EXAMPLE
        Test-SLRepo -Path C:\src

        Checks every repo up to two folders under C:\src.

    .EXAMPLE
        Test-SLRepo -Path C:\src\MyApp -Profile dotnet

    .EXAMPLE
        Test-SLRepo C:\src -PassThru -Quiet | Where-Object Status -eq 'DIFFERS'

    .EXAMPLE
        Test-SLRepo C:\src -PassThru -Quiet | Where-Object Status -eq 'MISSING' | Set-SLGitAttributes -WhatIf
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidAssignmentToAutomaticVariable', '',
        Justification = '-Profile is the documented parameter name; it shadows $PROFILE only inside this function, which never uses it.')]
    [CmdletBinding()]
    [OutputType([bool], [pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [string] $Path,
        [ValidateRange(0, 10)]
        [int] $Depth = 2,
        [string] $Profile,
        [string] $Standard,
        [switch] $PassThru,
        [switch] $Quiet
    )

    [void] (Get-SLGitPath)   # fail early, with an install hint, if git is missing

    if (-not $Path) { $Path = (Get-Location).ProviderPath }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Folder not found: $Path. Pass a repo, or a folder that contains repos."
    }
    $Path = (Resolve-Path -LiteralPath $Path).ProviderPath

    $std = Get-SLOptionalStandard -Path $Standard
    $profiles = Get-SLProfiles -Standard $std
    if ($Profile -and -not $profiles.ContainsKey($Profile)) {
        throw "Unknown profile '$Profile'. Use one of: $((@($profiles.Keys) | Sort-Object) -join ', ')."
    }

    $repos = @(Find-SLGitRepo -Path $Path -Depth $Depth)
    if ($repos.Count -eq 0) {
        Write-Warning "No git repos found in $Path or up to $Depth folder(s) below it. Point -Path at a repo or a folder of repos, or raise -Depth."
    }

    $checks = @()
    foreach ($repo in $repos) {
        $checks += Get-SLRepoCheck -RepoPath $repo -Standard $std -ProfileName $Profile -Profiles $profiles
    }

    if (-not $Quiet) { Write-SLRepoReport -Checks $checks -Path $Path -Standard $std }

    if ($PassThru) { return $checks }
    # Nothing checked is not a pass.
    return ($checks.Count -gt 0 -and @($checks | Where-Object { -not (Test-SLRepoOk $_) }).Count -eq 0)
}
