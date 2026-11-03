function Repair-SLLineEnding {
    <#
    .SYNOPSIS
        Fixes the line-ending issues Test-SLLineEnding reports in one repo, explicitly and safely.

    .DESCRIPTION
        Two kinds of repair, both previewable with -WhatIf:

          Files   converts each file with WrongEnding or Mixed endings to its rule's
                  ending. Only line endings change: the bytes are converted directly,
                  so encoding, BOM, content and a missing final newline are kept, and
                  the result is checked before it is written (atomically).
                  Mixed files without any rule are skipped.
          Config  makes .editorconfig and VS Code settings agree with .gitattributes:
                  - an end_of_line line is changed in place when every file it decides
                    already has that eol in .gitattributes
                  - otherwise a per-extension section is appended, only where every
                    file it would decide has that eol in .gitattributes
                  - a VS Code files.eol is set to the agreed value, or "auto" when the
                    files it governs need different endings
                  Anything else is reported as manual.

        It never stages, commits or renormalizes. Git's stored copy (Renormalize
        issues) is left to Set-SLGitAttributes or 'git add --renormalize <file>'.
        Tracked files with uncommitted content changes are skipped unless
        -AllowModified, so a line-ending change doesn't mix into your edits unasked.
        Read-only files and files outside the repo are never touched.

    .PARAMETER Path
        The repo's top folder.

    .PARAMETER File
        Repair only these repo-relative paths (as Test-SLLineEnding lists them).

    .PARAMETER Scope
        Files, Config or All (default).

    .PARAMETER AllowModified
        Also convert tracked files that have uncommitted content changes.

    .PARAMETER PassThru
        Return one object per planned change: Target, Kind, Action, Detail, Applied.

    .EXAMPLE
        Repair-SLLineEnding -Path C:\src\MyApp -WhatIf

    .EXAMPLE
        Repair-SLLineEnding -Path . -File 'build/Run.ps1' -Scope Files
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)] [string] $Path,
        [string[]] $File,
        [ValidateSet('All', 'Files', 'Config')] [string] $Scope = 'All',
        [switch] $AllowModified,
        [switch] $PassThru
    )
    process {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) { Write-Error "Folder not found: $Path."; return }
        $repo = (Resolve-Path -LiteralPath $Path).ProviderPath
        if (-not (Test-SLGitRepo $repo)) { Write-Error "$repo is not the top folder of a git repo."; return }
        $audit = Get-SLLineEndingAudit -RepoPath $repo -IncludeUntracked
        $results = New-Object System.Collections.Generic.List[object]

        if ($Scope -in 'All', 'Files') {
            $modified = @()
            $d = Invoke-SLGit -RepoPath $repo -Arguments @('diff', 'HEAD', '--ignore-cr-at-eol', '--name-only', '-z')
            if ($d.ExitCode -eq 0) { $modified = @($d.Output -split "`0" | Where-Object { $_ }) }
            $targets = @($audit.Issues | Where-Object { $_.Kind -in 'WrongEnding', 'Mixed' } | Group-Object File)
            foreach ($t in $targets) {
                if ($File -and $File -notcontains $t.Name) { continue }
                $record = $audit.Files | Where-Object Path -eq $t.Name | Select-Object -First 1
                $change = [pscustomobject]@{ Target = $t.Name; Kind = 'File'; Action = 'Convert'; Detail = ''; Applied = $false }
                $results.Add($change)
                if (-not $record.Expected) { $change.Action = 'Skipped'; $change.Detail = 'mixed endings but no .gitattributes eol or .editorconfig end_of_line rule; add one first'; continue }
                $info = Get-Item -LiteralPath $record.FullPath
                if ($info.IsReadOnly -or ($info.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $change.Action = 'Skipped'; $change.Detail = 'read-only or a link'; continue }
                if ($record.Tracked -and $modified -contains $record.Path -and -not $AllowModified) {
                    $change.Action = 'Skipped'; $change.Detail = 'has uncommitted content changes; commit them first or pass -AllowModified'; continue
                }
                $change.Detail = "$($record.Worktree) -> $($record.Expected) ($($record.ExpectedSource))"
                if (-not $PSCmdlet.ShouldProcess($record.FullPath, "Convert line endings to $($record.Expected.ToUpperInvariant())")) { continue }
                $text = Read-SLTextFile -Path $record.FullPath
                $converted = ConvertTo-SLLineEnding -Text $text.Text -Ending $record.Expected
                # Only endings may differ; anything else means the conversion is wrong.
                if (($converted -replace "`r`n", "`n") -cne ($text.Text -replace "`r`n", "`n")) { throw "Line-ending conversion would change content in $($record.FullPath); nothing was written." }
                Write-SLTextFile -File $text -Text $converted
                $change.Applied = $true
            }
        }

        if ($Scope -in 'All', 'Config') {
            $plans = @(Get-SLConfigRepairPlan -Audit $audit)
            foreach ($group in @($plans | Group-Object File)) {
                $doc = Read-SLTextFile -Path $group.Name
                $textValue = $doc.Text
                $applied = @()
                # Later offsets first, so earlier ones stay valid.
                $ordered = @($group.Group | Sort-Object @{ Expression = { if ($_.Kind -eq 'VSCode') { $_.Start } else { $_.Line } } } -Descending)
                foreach ($plan in $ordered) {
                    $change = [pscustomobject]@{ Target = $plan.File; Kind = $plan.Kind; Action = $plan.Action; Detail = $plan.Description; Applied = $false }
                    $results.Add($change)
                    if ($plan.Action -eq 'Manual') { continue }
                    if (-not $PSCmdlet.ShouldProcess($plan.File, $plan.Description)) { continue }
                    if ($plan.Kind -eq 'VSCode') {
                        $textValue = $textValue.Remove($plan.Start, $plan.Length).Insert($plan.Start, $plan.Value)
                    }
                    elseif ($plan.Action -eq 'Replace') {
                        $lines = [regex]::Split($textValue, '(?<=\n)')
                        $index = $plan.Line - 1
                        $lines[$index] = [regex]::Replace($lines[$index], '(?i)^(\s*end_of_line\s*=\s*)\S+', ('${1}' + $plan.Value))
                        $textValue = $lines -join ''
                    }
                    else {
                        if ($textValue.Length -gt 0 -and -not $textValue.EndsWith("`n")) { $textValue += $doc.Newline }
                        $textValue += (@($plan.Section) -join $doc.Newline) + $doc.Newline
                    }
                    $applied += $change
                }
                if ($applied.Count -gt 0) {
                    Write-SLTextFile -File $doc -Text $textValue
                    foreach ($a in $applied) { $a.Applied = $true }
                }
            }
        }

        Write-Host ''
        Write-Host "  SecondLine - line-ending repair for $($audit.Repo)" -ForegroundColor White
        if ($results.Count -eq 0) { Write-Host '  Nothing to repair in files or editor settings.' -ForegroundColor Green }
        foreach ($r in $results) {
            $state = 'planned'
            if ($r.Applied) { $state = 'done' } elseif ($r.Action -in 'Skipped', 'Manual') { $state = $r.Action.ToLowerInvariant() }
            $color = @{ done = 'Green'; planned = 'Yellow'; skipped = 'DarkYellow'; manual = 'DarkYellow' }[$state]
            Write-Host ("  {0,-8} {1,-12} {2}: {3}" -f $state, $r.Kind, $r.Target, $r.Detail) -ForegroundColor $color
        }
        $renormalize = @($audit.Issues | Where-Object Kind -eq 'Renormalize').Count
        if ($renormalize -gt 0) {
            Write-Host "  $renormalize file(s) are stored with CRLF in git; that needs staging, which this command never does: Set-SLGitAttributes -Path '$($repo.Replace("'", "''"))'" -ForegroundColor DarkGray
        }
        Write-Host '  Nothing was staged or committed.' -ForegroundColor DarkGray
        Write-Host ''
        if ($PassThru) { $results.ToArray() }
    }
}
