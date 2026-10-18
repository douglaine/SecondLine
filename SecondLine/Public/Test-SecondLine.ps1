function Test-SecondLine {
    <#
    .SYNOPSIS
        Audits this machine against a SecondLine standard.

    .DESCRIPTION
        For each tool in the standard: finds it on PATH, reads its version,
        and checks it against the expected version and rule.

        Status values:
          OK        found, and the version satisfies the rule
          MISMATCH  found, but the version does not satisfy the rule
          MISSING   not found on PATH
          UNKNOWN   found, but no version could be read from its output

        With -RepoPath, also checks the git repos at or under that folder against
        the .gitattributes line-ending standard (see Test-SLRepo), using the
        standard's GitAttributes section if it has one. Each repo is reported as
        OK, MISMATCH (rules differ, or files need renormalizing) or MISSING (no
        .gitattributes), and counts toward -Strict.

        Read-only: nothing is installed or changed.

    .PARAMETER Path
        The standard file. See Get-SecondLineStandard for where it is looked
        for when omitted.

    .PARAMETER PassThru
        Return one result object per tool (for scripts and CI) in addition to
        the report.

    .PARAMETER Quiet
        Don't print the report. Combine with -PassThru for results only.

    .PARAMETER Strict
        Throw if any tool (or repo, with -RepoPath) is not OK. Useful in CI.

    .PARAMETER RepoPath
        A git repo, or a folder of repos (searched two folders deep), to check
        for line endings after the tools.

    .EXAMPLE
        Test-SecondLine

    .EXAMPLE
        Test-SecondLine -Path .\secondline.standard.psd1 -PassThru -Quiet |
            Where-Object Status -ne 'OK'

    .EXAMPLE
        Test-SecondLine -RepoPath C:\src -Strict
    #>
    [CmdletBinding()]
    param(
        [string] $Path,
        [switch] $PassThru,
        [switch] $Quiet,
        [switch] $Strict,
        [string] $RepoPath
    )

    $standard = Get-SecondLineStandard -Path $Path
    $results  = @()

    foreach ($tool in $standard.Tools) {
        $result = [pscustomobject]@{
            PSTypeName = 'SecondLine.Result'
            Name       = $tool.Name
            Status     = ''
            Found      = ''
            Expect     = $tool.Expect
            Rule       = $tool.Rule
            Path       = ''
            Note       = ''
            Install    = $tool.Install
        }

        $cmd = Get-Command -Name $tool.Command -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1

        if (-not $cmd) {
            $result.Status = 'MISSING'
            $result.Note   = "'$($tool.Command)' is not on PATH."
            $results += $result
            continue
        }
        $result.Path = $cmd.Path

        $run = Invoke-SLTool -Path $cmd.Path -Arguments $tool.Arguments -TimeoutSeconds $tool.TimeoutSeconds
        if ($run.Error) {
            $result.Status = 'UNKNOWN'
            $result.Note   = "Could not run: $($run.Error)"
            $results += $result
            continue
        }

        $notes = @()
        if ($run.TimedOut) { $notes += "did not exit within $($tool.TimeoutSeconds)s and was stopped" }

        $all = @(Get-SLVersionTexts -Text $run.Output -Pattern $tool.VersionPattern)
        if ($all.Count -eq 0) {
            $result.Status = 'UNKNOWN'
            $notes += "no version found in output of '$($tool.Command) $($tool.Arguments)'"
        }
        elseif ($tool.Match -eq 'Any') {
            # Several versions installed side by side (e.g. dotnet --list-sdks).
            # OK if any satisfies the rule; prefer a release over a prerelease,
            # then the highest.
            $passing = @($all | Where-Object { Test-SLVersionRule -Found $_ -Expect $tool.Expect -Rule $tool.Rule })
            $pick = Select-SLBestVersion $passing
            if ($pick) {
                $result.Status = 'OK'
                $result.Found  = $pick
            }
            else {
                $result.Status = 'MISMATCH'
                $result.Found  = Select-SLBestVersion $all
            }
            $notes += "installed: $($all -join ', ')"
        }
        else {
            $result.Found = $all[0]
            if (Test-SLVersionRule -Found $all[0] -Expect $tool.Expect -Rule $tool.Rule) {
                $result.Status = 'OK'
            }
            else {
                $result.Status = 'MISMATCH'
            }
        }

        if ($result.Found -and (Test-SLPrerelease $result.Found)) {
            $notes += 'this is a prerelease build'
        }
        $result.Note = ($notes -join '; ')
        $results += $result
    }

    $toolResults = $results
    $repoChecks = @()
    if ($RepoPath) {
        [void] (Get-SLGitPath)
        if (-not (Test-Path -LiteralPath $RepoPath -PathType Container)) {
            throw "Repo folder not found: $RepoPath. Pass a repo, or a folder that contains repos."
        }
        $RepoPath = (Resolve-Path -LiteralPath $RepoPath).ProviderPath
        $profiles = Get-SLProfiles -Standard $standard
        foreach ($repo in @(Find-SLGitRepo -Path $RepoPath)) {
            $repoChecks += Get-SLRepoCheck -RepoPath $repo -Standard $standard -Profiles $profiles
        }
        # One row per repo, shaped like a tool result, so -PassThru, -Strict and
        # 'Where-Object Status -ne OK' treat them alike.
        foreach ($c in $repoChecks) {
            $status = 'OK'
            if ($c.Status -eq 'MISSING') { $status = 'MISSING' }
            elseif (-not (Test-SLRepoOk $c)) { $status = 'MISMATCH' }
            $notes = @($c.MissingRules | ForEach-Object { "missing $_" }) + @($c.ConflictingRules | ForEach-Object { "conflict $_" })
            if ($c.FilesToRenormalize -gt 0) { $notes += "$($c.FilesToRenormalize) file(s) to renormalize" }
            if ($c.Note) { $notes += $c.Note }
            $install = ''
            if ($status -ne 'OK') { $install = Get-SLRepoFixHint $c }
            $results += [pscustomobject]@{
                PSTypeName = 'SecondLine.Result'
                Name       = "repo $($c.Repo)"
                Status     = $status
                Found      = $c.Status
                Expect     = $c.Profile
                Rule       = 'gitattributes'
                Path       = $c.Path
                Note       = ($notes -join '; ')
                Install    = $install
            }
        }
    }

    if (-not $Quiet) {
        if ($RepoPath) {
            Write-SLReport -Standard $standard -Results $toolResults -Repos $repoChecks -RepoPath $RepoPath
        }
        else {
            Write-SLReport -Standard $standard -Results $results
        }
    }

    if ($PassThru) { $results }

    if ($Strict) {
        $bad = @($results | Where-Object { $_.Status -ne 'OK' })
        if ($bad.Count -gt 0) {
            $what = 'tools'
            if ($RepoPath) { $what = 'checks' }
            throw "SecondLine: $($bad.Count) of $($results.Count) $what are not OK: $(($bad | ForEach-Object { "$($_.Name) ($($_.Status))" }) -join ', ')"
        }
    }
}
