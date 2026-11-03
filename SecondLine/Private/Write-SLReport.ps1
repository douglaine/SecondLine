# Prints the human-readable audit report. Plain ASCII so it renders the same
# in Windows PowerShell 5.1, PowerShell 7, and a CI log.

function Write-SLReport {
    param(
        [Parameter(Mandatory)] $Standard,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Results,
        # Test-SecondLine -RepoPath: repo checks (Get-SLRepoCheck) shown after the tools.
        [object[]] $Repos,
        [string] $RepoPath
    )

    $colors = @{ OK = 'Green'; MISMATCH = 'Red'; MISSING = 'Red'; UNKNOWN = 'Yellow' }

    $title = $Standard.Name
    if ($Standard.Version) { $title = "$title v$($Standard.Version)" }

    Write-Host ''
    Write-Host "  SecondLine - $title" -ForegroundColor White
    Write-Host "  $($Standard.Path)" -ForegroundColor DarkGray
    Write-Host ''

    $nameWidth = 4
    $foundWidth = 8
    foreach ($r in $Results) {
        if ($r.Name.Length -gt $nameWidth) { $nameWidth = $r.Name.Length }
        if ("$($r.Found)".Length -gt $foundWidth) { $foundWidth = "$($r.Found)".Length }
    }

    foreach ($r in $Results) {
        $found = $r.Found
        if (-not $found) { $found = '-' }
        $line = '  {0,-9} {1}  {2}  expect {3} ({4})' -f $r.Status, $r.Name.PadRight($nameWidth), $found.PadRight($foundWidth), $r.Expect, $r.Rule
        Write-Host $line -ForegroundColor $colors[$r.Status]
        if ($r.Note) {
            Write-Host ('            ' + $r.Note) -ForegroundColor DarkGray
        }
        if ($r.Status -ne 'OK' -and $r.Install) {
            Write-Host ('            fix: ' + $r.Install) -ForegroundColor DarkGray
        }
    }

    $ok = @($Results | Where-Object { $_.Status -eq 'OK' }).Count
    $summaryColor = 'Green'
    if ($ok -ne $Results.Count) { $summaryColor = 'Yellow' }
    $summary = "{0} of {1} tools OK" -f $ok, $Results.Count

    if ($PSBoundParameters.ContainsKey('Repos')) {
        if ($Results.Count -gt 0) { Write-Host '' }
        Write-Host "  Repos: line endings ($RepoPath)" -ForegroundColor White
        Write-SLRepoLines -Checks $Repos
        $repoOk = @($Repos | Where-Object { Test-SLRepoOk $_ }).Count
        if ($repoOk -ne @($Repos).Count) { $summaryColor = 'Yellow' }
        $repoSummary = '{0} of {1} repos OK' -f $repoOk, @($Repos).Count
        if ($Results.Count -gt 0) { $summary = "$summary, $repoSummary" } else { $summary = $repoSummary }
    }

    Write-Host ''
    Write-Host "  $summary" -ForegroundColor $summaryColor
    Write-Host ''
}

# Groups 'pattern attributes' strings by their attributes, so a long list of
# missing rules reads as a few lines: 'text eol=lf: *.cs *.css *.js'.
function Format-SLRuleGroups {
    param([string[]] $Rules)
    $groups = New-Object System.Collections.Specialized.OrderedDictionary
    foreach ($r in $Rules) {
        $parts = $r -split ' ', 2
        $attrs = ''
        if ($parts.Count -gt 1) { $attrs = $parts[1] }
        if (-not $groups.Contains($attrs)) { $groups[$attrs] = New-Object System.Collections.Generic.List[string] }
        $groups[$attrs].Add($parts[0])
    }
    foreach ($attrs in $groups.Keys) {
        $line = "${attrs}:"
        foreach ($p in $groups[$attrs]) {
            if ($line.Length + $p.Length -gt 90) { "$line"; $line = (' ' * ($attrs.Length + 1)) }
            $line += " $p"
        }
        $line
    }
}

# Test-SLRepo's report.
function Write-SLRepoReport {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Checks,
        [Parameter(Mandatory)] [string] $Path,
        $Standard
    )
    $source = 'built-in profiles'
    if ($Standard) { $source = "profiles: built-in + $($Standard.Path)" }

    Write-Host ''
    Write-Host '  SecondLine - repo line endings' -ForegroundColor White
    Write-Host "  $Path  ($source)" -ForegroundColor DarkGray

    Write-SLRepoLines -Checks $Checks

    $ok = @($Checks | Where-Object { Test-SLRepoOk $_ }).Count
    $color = 'Green'
    if ($ok -ne $Checks.Count) { $color = 'Yellow' }
    Write-Host ''
    Write-Host ('  {0} of {1} repos OK' -f $ok, $Checks.Count) -ForegroundColor $color
    Write-Host ''
}

# One line per repo (status, name, profile and why, files to renormalize), then
# what's wrong and how to fix it. Shared by both reports.
function Write-SLRepoLines {
    param([AllowEmptyCollection()] [object[]] $Checks)
    $colors = @{ MATCHES = 'Green'; EXTENDS = 'Green'; DIFFERS = 'Red'; MISSING = 'Red' }

    $nameWidth = 4
    $profileWidth = 8
    foreach ($c in $Checks) {
        if ($c.Repo.Length -gt $nameWidth) { $nameWidth = $c.Repo.Length }
        $p = "$($c.Profile) ($($c.ProfileReason))"
        if ($p.Length -gt $profileWidth) { $profileWidth = $p.Length }
    }

    Write-Host ''
    foreach ($c in $Checks) {
        $renorm = '-'
        if ($c.FilesToRenormalize -gt 0) { $renorm = "$($c.FilesToRenormalize) to renormalize" }
        $color = $colors[$c.Status]
        if ($color -eq 'Green' -and $c.FilesToRenormalize -gt 0) { $color = 'Yellow' }
        $line = '  {0,-9} {1}  {2}  {3}' -f $c.Status, $c.Repo.PadRight($nameWidth), "$($c.Profile) ($($c.ProfileReason))".PadRight($profileWidth), $renorm
        Write-Host $line.TrimEnd() -ForegroundColor $color

        $pad = '            '
        if ($c.Status -eq 'MISSING') { Write-Host "${pad}no .gitattributes" -ForegroundColor DarkGray }
        if ($c.Status -ne 'MISSING') {
            foreach ($line in @(Format-SLRuleGroups -Rules $c.MissingRules)) {
                $label = 'missing:  '
                if ($line.StartsWith(' ')) { $label = '          ' }   # continuation
                Write-Host "${pad}$label$line" -ForegroundColor DarkGray
            }
        }
        foreach ($r in @($c.ConflictingRules)) { Write-Host "${pad}conflict: $r" -ForegroundColor DarkGray }
        foreach ($r in @($c.ExtraRules)) { Write-Host "${pad}extra:    $r" -ForegroundColor DarkGray }
        if ($c.FilesToRenormalize -gt 0) {
            Write-Host "${pad}committed with CRLF or mixed endings:" -ForegroundColor DarkGray
            foreach ($f in @($c.RenormalizeSample)) { Write-Host "${pad}  $f" -ForegroundColor DarkGray }
            $more = $c.FilesToRenormalize - @($c.RenormalizeSample).Count
            if ($more -gt 0) { Write-Host "${pad}  ... and $more more" -ForegroundColor DarkGray }
        }
        if ($c.Note) { Write-Host "${pad}$($c.Note)" -ForegroundColor DarkGray }
        if (-not (Test-SLRepoOk $c)) {
            Write-Host "${pad}fix: $(Get-SLRepoFixHint $c)" -ForegroundColor DarkGray
        }
    }
}
