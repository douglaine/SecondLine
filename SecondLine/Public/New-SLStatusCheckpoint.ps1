function New-SLStatusCheckpoint {
    <#
    .SYNOPSIS
        Creates docs/status/current.md, the per-project status checkpoint, from the shipped template.

    .DESCRIPTION
        The checkpoint records branch and base commit, completed and remaining work,
        changed files, verification (Verified vs Planned, with evidence paths),
        blockers and the exact next action. Agents read it when resuming and update it
        after each meaningful unit of work and before stopping. It is a handoff that
        must be verified against the repository, not an authorization, and it never
        holds credentials.

        Creates the file only. An existing checkpoint is never overwritten.

    .PARAMETER Path
        The repo. Default: the current folder.

    .PARAMETER Branch
        Prefill the Branch line. Default: the repo's current branch, if git can tell.

    .EXAMPLE
        New-SLStatusCheckpoint -Path C:\src\MyApp -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string] $Path,
        [string] $Branch
    )
    if (-not $Path) { $Path = (Get-Location).ProviderPath }
    $repo = (Resolve-Path -LiteralPath $Path).ProviderPath
    $target = Join-Path $repo 'docs\status\current.md'
    if (Test-Path -LiteralPath $target) { throw "$target already exists; it was not changed. Edit it instead." }
    $lines = @(Read-SLTextLines -Path (Get-SLStatusTemplatePath))
    $base = ''
    if ((Test-SLGitRepo $repo) -and (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
        if (-not $Branch) { $Branch = (Invoke-SLGit -RepoPath $repo -Arguments @('branch', '--show-current')).Output.Trim() }
        $base = (Invoke-SLGit -RepoPath $repo -Arguments @('log', '-1', '--format=%h %s')).Output.Trim()
    }
    $lines = @($lines | ForEach-Object {
            if ($_ -eq '- Branch:' -and $Branch) { "- Branch: $Branch" }
            elseif ($_ -eq '- Base commit:' -and $base) { "- Base commit: $base" }
            else { $_ }
        })
    if ($PSCmdlet.ShouldProcess($target, 'Create status checkpoint')) {
        $dir = Split-Path $target -Parent
        if (-not (Test-Path -LiteralPath $dir)) { [void] (New-Item -ItemType Directory -Path $dir -Force) }
        Write-SLTextLines -Path $target -Lines $lines
        Write-Host "  Created $target. Fill it in; keep it free of credentials." -ForegroundColor Green
    }
}
