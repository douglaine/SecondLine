function Test-SLPolicyReference {
    <#
    .SYNOPSIS
        Audits a repo's agent entry points, shared-policy copy and status checkpoint. Read-only.

    .DESCRIPTION
        Checks, for each repo at or under -Path:

          entry points  CLAUDE.md and AGENTS.md both exist, each has the marker lines
                          SecondLine-Policy: <version> <path>
                          SecondLine-Status: docs/status/current.md
                        and both name the same policy and checkpoint
          policy copy   the path is relative and inside the repo (portable, no
                        developer checkout), the file exists, has a version header,
                        matches the referenced version, is unmodified (hash), and is
                        not older than the policy this SecondLine ships
          checkpoint    exists, has the sections Position (Branch, Base commit),
                        Completed, Remaining, Changed files, Verification (items
                        labelled Verified or Planned), Blockers and Next action, and
                        contains nothing that looks like a credential
          scripts       vendored bootstrap copies are current; no script pins
                        SecondLine with Import-Module -RequiredVersion (or
                        -MinimumVersion)

        Errors make the repo fail. Warnings (modified or outdated copy, outdated
        bootstrap, hardcoded versions) are reported but don't. Nothing is changed.
        A checkpoint is a handoff to verify, never an authorization.

    .PARAMETER Path
        A repo, or a folder of repos. Default: the current folder.

    .PARAMETER Depth
        How many folders below -Path to look for repos. Default: 2.

    .PARAMETER PassThru
        Return one result per repo instead of $true/$false.

    .PARAMETER Quiet
        Don't print the report.

    .PARAMETER Strict
        Throw if any repo has an error. For CI.

    .EXAMPLE
        Test-SLPolicyReference -Path . -Strict
    #>
    [CmdletBinding()]
    [OutputType([bool], [pscustomobject])]
    param(
        [Parameter(Position = 0)] [string] $Path,
        [ValidateRange(0, 10)] [int] $Depth = 2,
        [switch] $PassThru,
        [switch] $Quiet,
        [switch] $Strict
    )
    if (-not $Path) { $Path = (Get-Location).ProviderPath }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Folder not found: $Path." }
    $Path = (Resolve-Path -LiteralPath $Path).ProviderPath
    $repos = @($Path)
    if (Get-Command git -CommandType Application -ErrorAction SilentlyContinue) {
        $found = @(Find-SLGitRepo -Path $Path -Depth $Depth)
        if ($found.Count -gt 0) { $repos = $found }
    }
    $checks = @(foreach ($repo in $repos) { Get-SLPolicyAudit -RepoPath $repo })
    if (-not $Quiet) {
        Write-Host ''
        Write-Host "  SecondLine - shared policy and status references ($Path)" -ForegroundColor White
        foreach ($c in $checks) {
            Write-Host ''
            $errors = @($c.Findings | Where-Object Severity -eq 'Error').Count
            $warnings = @($c.Findings | Where-Object Severity -eq 'Warning').Count
            if ($c.Ok -and $warnings -eq 0) { Write-Host "  OK        $($c.Repo)" -ForegroundColor Green }
            elseif ($c.Ok) { Write-Host "  OK        $($c.Repo)  $warnings warning(s)" -ForegroundColor Yellow }
            else { Write-Host "  ISSUES    $($c.Repo)  $errors error(s), $warnings warning(s)" -ForegroundColor Red }
            foreach ($f in $c.Findings) {
                Write-Host ("            {0,-7} {1,-26} {2}: {3}" -f $f.Severity, $f.Kind, $f.File, $f.Detail) -ForegroundColor DarkGray
            }
        }
        Write-Host ''
    }
    $bad = @($checks | Where-Object { -not $_.Ok })
    if ($Strict -and $bad.Count -gt 0) {
        throw "SecondLine policy references: $($bad.Count) of $($checks.Count) repos have errors: $(($bad | ForEach-Object { $_.Repo }) -join ', ')"
    }
    if ($PassThru) { return $checks }
    return ($bad.Count -eq 0)
}
