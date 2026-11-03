function Test-SLLineEnding {
    <#
    .SYNOPSIS
        Audits line-ending rules and the actual line endings of files in git repos. Read-only.

    .DESCRIPTION
        For each repo at or under -Path, and each tracked text file (and, by default,
        each untracked file that isn't ignored), it compares:

          rules         effective .gitattributes (as git computes it), the applicable
                        .editorconfig files (local and parent folders, up to
                        root = true) and explicit VS Code files.eol settings
                        (.vscode/settings.json, *.code-workspace, global or
                        per-language)
          working copy  the endings actually in the file
          stored        what git keeps in the index

        Issues:
          Mixed                 both LF and CRLF in one file
          WrongEnding           the file uses another ending than its rule
          EditorConfigConflict  end_of_line disagrees with .gitattributes eol
          VSCodeConflict        files.eol disagrees with the effective rule
          Renormalize           git stores CRLF for a text file

        The rule is .gitattributes eol when set, otherwise .editorconfig end_of_line.
        A file with neither only has to be consistent. Binary files (-text, binary, or
        detected by git) are skipped. CRLF is not assumed wrong: Windows scripts can
        require it.

        Limits: VS Code files.eol only applies to new files, and its user settings
        and files.associations are not read. Editors cannot control scripts or
        generators, which must write the declared endings explicitly. This command
        reports. Repair-SLLineEnding fixes. Set-SLGitAttributes manages
        .gitattributes and renormalizing.

    .PARAMETER Path
        A repo, or a folder of repos. Default: the current folder.

    .PARAMETER Depth
        How many folders below -Path to look for repos. Default: 2.

    .PARAMETER TrackedOnly
        Check only tracked files.

    .PARAMETER PassThru
        Return one result per repo instead of $true/$false.

    .PARAMETER Quiet
        Don't print the report.

    .PARAMETER Strict
        Throw if any repo has an issue. For CI.

    .OUTPUTS
        Without -PassThru: $true if every repo is clean, else $false (also when no repo is found).

    .EXAMPLE
        Test-SLLineEnding -Path . -Strict

    .EXAMPLE
        (Test-SLLineEnding C:\src -PassThru -Quiet).Issues | Group-Object Kind
    #>
    [CmdletBinding()]
    [OutputType([bool], [pscustomobject])]
    param(
        [Parameter(Position = 0)] [string] $Path,
        [ValidateRange(0, 10)] [int] $Depth = 2,
        [switch] $TrackedOnly,
        [switch] $PassThru,
        [switch] $Quiet,
        [switch] $Strict
    )
    [void] (Get-SLGitPath)
    if (-not $Path) { $Path = (Get-Location).ProviderPath }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Folder not found: $Path. Pass a repo, or a folder that contains repos." }
    $Path = (Resolve-Path -LiteralPath $Path).ProviderPath
    $repos = @(Find-SLGitRepo -Path $Path -Depth $Depth)
    if ($repos.Count -eq 0) { Write-Warning "No git repos found in $Path or up to $Depth folder(s) below it." }
    $checks = @(foreach ($repo in $repos) { Get-SLLineEndingAudit -RepoPath $repo -IncludeUntracked:(-not $TrackedOnly) })
    if (-not $Quiet) { Write-SLLineEndingReport -Checks $checks -Path $Path }
    $bad = @($checks | Where-Object { -not $_.Ok })
    if ($Strict -and ($bad.Count -gt 0 -or $checks.Count -eq 0)) {
        $what = 'no repo was checked'
        if ($checks.Count -gt 0) { $what = (@($bad | ForEach-Object { "$($_.Repo) ($(@($_.Issues).Count))" }) -join ', ') }
        throw "SecondLine line endings: $($bad.Count) of $($checks.Count) repos have issues: $what"
    }
    if ($PassThru) { return $checks }
    return ($checks.Count -gt 0 -and $bad.Count -eq 0)
}

function Write-SLLineEndingReport {
    param([object[]] $Checks, [string] $Path)
    Write-Host ''
    Write-Host "  SecondLine - line endings ($Path)" -ForegroundColor White
    foreach ($c in $Checks) {
        Write-Host ''
        $color = 'Green'
        $summary = "OK        $($c.Repo)  $($c.FilesChecked) text file(s), $($c.Binary) binary skipped"
        if (-not $c.Ok) {
            $color = 'Red'
            $kinds = @($c.Issues | Group-Object Kind | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', '
            $summary = "ISSUES    $($c.Repo)  $kinds"
        }
        Write-Host "  $summary" -ForegroundColor $color
        foreach ($group in @($c.Issues | Group-Object Kind)) {
            foreach ($i in @($group.Group | Select-Object -First 8)) {
                $tag = ''
                if (-not $i.Tracked) { $tag = ' (untracked)' }
                Write-Host ("            {0,-21} {1}{2}: {3}" -f $i.Kind, $i.File, $tag, $i.Detail) -ForegroundColor DarkGray
            }
            if ($group.Count -gt 8) { Write-Host "            ... and $($group.Count - 8) more $($group.Name)" -ForegroundColor DarkGray }
        }
        if (-not $c.Ok) { Write-Host "            fix: Repair-SLLineEnding -Path '$($c.Path.Replace("'", "''"))' -WhatIf" -ForegroundColor DarkGray }
        foreach ($n in $c.Notes) { Write-Host "            note: $n" -ForegroundColor DarkGray }
    }
    $ok = @($Checks | Where-Object Ok).Count
    $color = 'Green'
    if ($ok -ne $Checks.Count) { $color = 'Yellow' }
    Write-Host ''
    Write-Host "  $ok of $($Checks.Count) repos OK" -ForegroundColor $color
    Write-Host ''
}
