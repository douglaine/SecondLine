function Export-SLPolicy {
    <#
    .SYNOPSIS
        Writes the reviewed shared development policy from this SecondLine release into a repo.

    .DESCRIPTION
        Copies the policy shipped with the loaded SecondLine, version header included,
        to -Destination (default docs/shared-development-policy.md under -Path). The
        copy can be verified offline by its header hash, so consumers don't need the
        SecondLine checkout.

        Overwrites an existing copy only if that copy is unmodified (its hash
        verifies). A locally modified copy, or a file without a header, is left alone
        unless -Force. It never edits CLAUDE.md or AGENTS.md: it prints the marker
        lines for you to add to them by hand, beside each project's own instructions.

    .PARAMETER Path
        The repo. Default: the current folder.

    .PARAMETER Destination
        Repo-relative path of the copy. Default: docs/shared-development-policy.md.

    .PARAMETER Force
        Overwrite a modified copy or a file without a header.

    .PARAMETER PassThru
        Return Path, Version, Action (Created | Updated | Unchanged | Refused) and Applied.

    .EXAMPLE
        Export-SLPolicy -Path C:\src\MyApp -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [string] $Path,
        [string] $Destination = 'docs/shared-development-policy.md',
        [switch] $Force,
        [switch] $PassThru
    )
    if (-not $Path) { $Path = (Get-Location).ProviderPath }
    if (Test-SLNonPortablePath $Destination) { throw "Destination must be a relative path inside the repo, for example docs/shared-development-policy.md." }
    $source = Get-SLShippedPolicyPath
    if (-not $source) { throw 'This SecondLine package has no shared policy file.' }
    $shipped = Read-SLPolicyFile -Path $source
    if (-not $shipped.HasHeader -or $shipped.Modified) { throw "The shipped policy $source does not verify; it was changed after review. Nothing was written." }
    $target = Join-Path (Resolve-Path -LiteralPath $Path).ProviderPath $Destination
    $result = [pscustomobject]@{ Path = $target; Version = $shipped.Version; Action = 'Created'; Applied = $false }
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        $existing = Read-SLPolicyFile -Path $target
        $result.Action = 'Updated'
        if ($existing.HasHeader -and -not $existing.Modified -and $existing.Hash -eq $shipped.Hash) { $result.Action = 'Unchanged' }
        elseif ((-not $existing.HasHeader -or $existing.Modified) -and -not $Force) {
            $result.Action = 'Refused'
            Write-Warning "$target is locally modified or has no SecondLine-Policy header; nothing was written. Move local rules into CLAUDE.md/AGENTS.md, then rerun, or pass -Force."
        }
    }
    if ($result.Action -in 'Created', 'Updated' -and $PSCmdlet.ShouldProcess($target, "$($result.Action) shared development policy version $($shipped.Version)")) {
        $dir = Split-Path $target -Parent
        if (-not (Test-Path -LiteralPath $dir)) { [void] (New-Item -ItemType Directory -Path $dir -Force) }
        # Text, not bytes: the repo's own .gitattributes decides the checkout ending; write LF.
        Write-SLTextLines -Path $target -Lines @(Read-SLTextLines -Path $source)
        $result.Applied = $true
    }
    $relative = $Destination.Replace('\', '/')
    Write-Host "  Shared policy version $($shipped.Version): $($result.Action) $target" -ForegroundColor Green
    Write-Host '  Add these lines to both CLAUDE.md and AGENTS.md (by hand; this command never edits them):' -ForegroundColor Gray
    Write-Host "    SecondLine-Policy: $($shipped.Version) $relative" -ForegroundColor Gray
    Write-Host '    SecondLine-Status: docs/status/current.md' -ForegroundColor Gray
    if ($PassThru) { $result }
}
