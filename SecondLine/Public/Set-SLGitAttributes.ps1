function Set-SLGitAttributes {
    <#
    .SYNOPSIS
        Writes or completes a repo's .gitattributes from a profile, then renormalizes.

    .DESCRIPTION
        Compares the repo's .gitattributes with its profile (see Test-SLRepo for
        how the profile is chosen), then:

          MISSING           writes the profile as .gitattributes
          DIFFERS, missing  appends the missing rules under '# Added by SecondLine',
                            keeping every existing line and comment (a missing '*'
                            catch-all goes at the top, so it can't override the
                            rules after it)
          DIFFERS, conflict refuses, unless -Force: then replaces the conflicting
                            lines in place (keeping any extra attributes on them)
          MATCHES/EXTENDS   writes nothing

        The file is written as UTF-8 without BOM, with LF line endings. A repo's
        extra rules are never removed.

        Then, unless -SkipRenormalize, runs
          git -C <repo> add .gitattributes
          git -C <repo> add --renormalize .
        and shows what is staged. It NEVER commits: review the staged changes and
        commit them yourself, on their own, so the line-ending change doesn't hide
        inside a real diff.

        Before renormalizing it refuses to run on a repo with uncommitted changes
        to tracked files (unless -AllowDirty), because the line-ending changes
        would be mixed into them. Untracked files don't count.

    .PARAMETER Path
        The repo's top folder. Accepts Test-SLRepo -PassThru objects from the pipeline.

    .PARAMETER Profile
        The profile to apply. Default: as Test-SLRepo picks it.

    .PARAMETER Standard
        The standard file, for its GitAttributes section. See Get-SecondLineStandard.

    .PARAMETER Force
        Replace lines whose attributes conflict with the profile.

    .PARAMETER AllowDirty
        Renormalize even with uncommitted changes to tracked files.

    .PARAMETER SkipRenormalize
        Only write .gitattributes; run no git commands.

    .EXAMPLE
        Set-SLGitAttributes -Path C:\src\MyApp -WhatIf

        Shows the rules it would write and the git commands it would run.

    .EXAMPLE
        Set-SLGitAttributes C:\src\Contoso.Api -Profile dotnet -Force

    .EXAMPLE
        Test-SLRepo C:\src -PassThru -Quiet | Where-Object Status -eq 'MISSING' | Set-SLGitAttributes
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidAssignmentToAutomaticVariable', '',
        Justification = '-Profile is the documented parameter name; it shadows $PROFILE only inside this function, which never uses it.')]
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
        [string] $Path,
        [Parameter(ValueFromPipelineByPropertyName)]
        [string] $Profile,
        [string] $Standard,
        [switch] $Force,
        [switch] $AllowDirty,
        [switch] $SkipRenormalize
    )

    begin {
        [void] (Get-SLGitPath)   # fail early, with an install hint, if git is missing
        $std = Get-SLOptionalStandard -Path $Standard
        $profiles = Get-SLProfiles -Standard $std
    }

    process {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            Write-Error "Folder not found: $Path."
            return
        }
        $repo = (Resolve-Path -LiteralPath $Path).ProviderPath
        if (-not (Test-SLGitRepo $repo)) {
            Write-Error "$repo is not the top folder of a git repo (no .git in it). Point -Path at a repo; Test-SLRepo finds them."
            return
        }

        try { $check = Get-SLRepoCheck -RepoPath $repo -Standard $std -ProfileName $Profile -Profiles $profiles }
        catch { Write-Error $_.Exception.Message; return }

        $file = Join-Path $repo '.gitattributes'
        $lines = @()
        if ($check.Status -ne 'MISSING') { $lines = @(Read-SLTextLines -Path $file) }
        $cmp = Compare-SLGitAttributes -Lines $lines -ProfileLines $profiles[$check.Profile] -FileMissing:($check.Status -eq 'MISSING')
        $quoted = "'" + $repo.Replace("'", "''") + "'"

        # ------------------------------------------------------ the plan --
        $action = 'Unchanged'
        $newLines = $null
        $added = @()
        $replaced = @()

        if ($cmp.Status -eq 'MISSING') {
            $action = 'Created'
            $newLines = @($profiles[$check.Profile])
            $added = @($cmp.MissingRules)
        }
        elseif ($cmp.Status -eq 'DIFFERS') {
            if (@($cmp.Conflicts).Count -gt 0 -and -not $Force) {
                Write-Error ("$repo`: .gitattributes conflicts with profile '$($check.Profile)':`n  " +
                    (@($cmp.ConflictingRules) -join "`n  ") +
                    "`nNothing was changed. Re-run with -Force to replace those lines (every other line is kept), or choose another -Profile.")
                return
            }
            $list = New-Object System.Collections.Generic.List[string]
            foreach ($l in $lines) { $list.Add($l) }

            foreach ($c in @($cmp.Conflicts)) {
                # Keep attributes the repo adds that the profile doesn't mention.
                $keep = @(@($c.Have.Attributes.Keys) | Sort-Object |
                        Where-Object { -not $c.Want.Attributes.ContainsKey($_) } |
                        ForEach-Object { $c.Have.Attributes[$_] })
                $ruleLine = Format-SLRuleLine -Pattern $c.Want.Pattern -Tokens (@($c.Want.Tokens) + $keep)
                foreach ($idx in $c.Have.Lines) {
                    $replaced += "$($list[$idx].Trim()) -> $ruleLine"
                    $list[$idx] = $ruleLine
                }
            }

            $top = @($cmp.Missing | Where-Object { $_.Pattern -eq '*' })
            $bottom = @($cmp.Missing | Where-Object { $_.Pattern -ne '*' })
            if ($bottom.Count -gt 0) {
                if ($list.Count -gt 0 -and $list[$list.Count - 1].Trim()) { $list.Add('') }
                $list.Add("# Added by SecondLine (profile '$($check.Profile)')")
                foreach ($r in $bottom) { $list.Add((Format-SLRuleLine -Pattern $r.Pattern -Tokens $r.Tokens)) }
            }
            if ($top.Count -gt 0) {
                # Later lines win in git, so a catch-all must come first.
                $head = @("# Added by SecondLine (profile '$($check.Profile)')")
                foreach ($r in $top) { $head += (Format-SLRuleLine -Pattern $r.Pattern -Tokens $r.Tokens) }
                $head += ''
                $list.InsertRange(0, [string[]] $head)
            }
            foreach ($r in @($cmp.Missing)) { $added += "$($r.Pattern) $($r.Tokens -join ' ')" }

            $newLines = $list.ToArray()
            if ($replaced.Count -gt 0) { $action = 'Replaced' } else { $action = 'Appended' }
        }

        $renormalize = -not $SkipRenormalize -and ($action -ne 'Unchanged' -or $check.FilesToRenormalize -gt 0)

        $result = [pscustomobject]@{
            PSTypeName    = 'SecondLine.GitAttributesChange'
            Repo          = $check.Repo
            Path          = $repo
            Profile       = $check.Profile
            ProfileReason = $check.ProfileReason
            Action        = $action
            RulesAdded    = $added
            RulesReplaced = $replaced
            FilesStaged   = @()
            Applied       = $false
        }

        Write-Host ''
        Write-Host "  SecondLine - .gitattributes for $($check.Repo)" -ForegroundColor White
        Write-Host "  $repo  (profile $($check.Profile): $($check.ProfileReason))" -ForegroundColor DarkGray
        Write-Host ''

        if ($action -eq 'Unchanged' -and -not $renormalize) {
            $msg = "  .gitattributes $($check.Status.ToLowerInvariant()) the profile"
            if ($check.FilesToRenormalize -gt 0) { $msg += "; $($check.FilesToRenormalize) file(s) need renormalizing (-SkipRenormalize given)." }
            else { $msg += ' and no file needs renormalizing. Nothing to do.' }
            Write-Host $msg -ForegroundColor Green
            Write-Host ''
            return $result
        }

        # Check before changing anything, so a refusal leaves the repo as it was.
        if ($renormalize -and -not $AllowDirty) {
            $dirty = @(Get-SLDirtyFiles -RepoPath $repo)
            if ($dirty.Count -gt 0) {
                $names = (@($dirty | Select-Object -First 5 | ForEach-Object { $_.Path }) -join ', ')
                if ($dirty.Count -gt 5) { $names += ', ...' }
                Write-Error ("$repo has uncommitted changes to $($dirty.Count) tracked file(s): $names. " +
                    'Renormalizing now would mix line-ending changes into them. Commit or stash them first, so the ' +
                    'line-ending change is a commit of its own, or pass -AllowDirty. Nothing was changed.')
                return
            }
        }

        switch ($action) {
            'Created' {
                Write-Host "  Create .gitattributes from profile '$($check.Profile)' ($($added.Count) rules)" -ForegroundColor Yellow
                if ($WhatIfPreference) { foreach ($l in $newLines) { Write-Host "    | $l" -ForegroundColor DarkGray } }
            }
            'Unchanged' {
                Write-Host "  .gitattributes $($check.Status.ToLowerInvariant()) the profile; $($check.FilesToRenormalize) file(s) need renormalizing." -ForegroundColor Green
            }
            default {
                foreach ($r in $replaced) { Write-Host "  replace: $r" -ForegroundColor Yellow }
                foreach ($line in @(Format-SLRuleGroups -Rules $added)) {
                    $label = 'add:     '
                    if ($line.StartsWith(' ')) { $label = '         ' }   # continuation
                    Write-Host "  $label$line" -ForegroundColor Yellow
                }
            }
        }

        $gitCommands = "git -C $quoted add .gitattributes; git -C $quoted add --renormalize ."
        if ($renormalize) {
            Write-Host "  then:    git -C $quoted add .gitattributes" -ForegroundColor DarkGray
            Write-Host "           git -C $quoted add --renormalize ." -ForegroundColor DarkGray
        }
        Write-Host ''

        if ($action -ne 'Unchanged') {
            $verbs = @{ Created = 'Create'; Appended = 'Append missing rules to'; Replaced = 'Replace conflicting rules in (and complete)' }
            $what = "$($verbs[$action]) .gitattributes (profile '$($check.Profile)')"
            if (-not $PSCmdlet.ShouldProcess($file, $what)) { return $result }
            Write-SLTextLines -Path $file -Lines $newLines
            $result.Applied = $true
            Write-Host "  OK      $action .gitattributes" -ForegroundColor Green
        }

        if (-not $renormalize) {
            Write-Host ''
            return $result
        }
        if (-not $PSCmdlet.ShouldProcess($repo, $gitCommands)) { return $result }

        foreach ($gitArgs in @(@('add', '--', '.gitattributes'), @('add', '--renormalize', '.'))) {
            if ($gitArgs[-1] -eq '.gitattributes' -and -not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
            $r = Invoke-SLGit -RepoPath $repo -Arguments $gitArgs
            if ($r.ExitCode -ne 0) {
                Write-Error "git $($gitArgs -join ' ') failed in $($repo): $($r.Errors)"
                return $result
            }
        }
        $result.Applied = $true

        $status = Invoke-SLGit -RepoPath $repo -Arguments @('status', '--porcelain=v1', '-z', '--untracked-files=no')
        $staged = @(ConvertFrom-SLPorcelain $status.Output | Where-Object { $_.Index -ne ' ' -and $_.Index -ne '?' })
        $result.FilesStaged = @($staged | ForEach-Object { $_.Path })

        Write-Host "  OK      Staged $($staged.Count) file(s) (git status --short):" -ForegroundColor Green
        foreach ($s in @($staged | Select-Object -First 20)) {
            Write-Host "          $($s.Index)$($s.WorkTree) $($s.Path)" -ForegroundColor DarkGray
        }
        if ($staged.Count -gt 20) { Write-Host "          ... and $($staged.Count - 20) more" -ForegroundColor DarkGray }

        $message = 'Renormalize line endings'
        if ($action -eq 'Created') { $message = 'Add .gitattributes (line-ending standard) and renormalize' }
        elseif ($action -ne 'Unchanged') { $message = 'Update .gitattributes (line-ending standard) and renormalize' }
        Write-Host ''
        Write-Host '  Nothing was committed. Review, then commit on its own:' -ForegroundColor White
        Write-Host "    git -C $quoted diff --cached --stat" -ForegroundColor Gray
        Write-Host "    git -C $quoted commit -m `"$message`"" -ForegroundColor Gray
        Write-Host ''

        return $result
    }
}
