function Enable-SLProfileUpdateCheck {
    <#
    .SYNOPSIS
        Adds the marked SecondLine update-check block to a PowerShell profile file (opt-in).

    .DESCRIPTION
        Writes one block between these markers:
          # >>> SecondLine update check >>>
          # <<< SecondLine update check <<<

        In an interactive shell the block shows a pending update notice once, and
        when the shared cache is due (daily by default) it starts one hidden,
        no-profile PowerShell process that runs Invoke-SLUpdateCheck and exits.
        Startup reads two small files and never waits on the network. The block
        imports nothing into the shell, so a project bootstrap can still select its
        approved SecondLine version. It installs nothing.

        Run once more to update an existing block in place. A second block is never
        added. Every other line, the file's encoding, its BOM and its line endings are
        kept. Disable-SLProfileUpdateCheck removes the block again.

        -Path is required, so nothing is written to a profile by accident.
        Use -WhatIf to preview.

    .PARAMETER Path
        The profile file, for example $PROFILE.CurrentUserAllHosts. It is created if missing.

    .PARAMETER PassThru
        Return Path, Action (Added | Updated | Unchanged) and Applied.

    .EXAMPLE
        Enable-SLProfileUpdateCheck -Path $PROFILE.CurrentUserAllHosts -WhatIf

    .EXAMPLE
        Enable-SLProfileUpdateCheck -Path $PROFILE.CurrentUserAllHosts
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory, Position = 0)] [string] $Path,
        [switch] $PassThru
    )
    $exists = Test-Path -LiteralPath $Path -PathType Leaf
    if ($exists) { $file = Read-SLTextFile -Path $Path } else { $file = New-SLTextFile -Path $Path }
    $nl = $file.Newline
    $block = (Get-SLProfileBlock) -join $nl
    $found = Find-SLProfileBlock -Text $file.Text
    $action = 'Added'
    if ($found.Count -gt 0) {
        $first = $found[0]
        $text = $file.Text
        # Replace the first block and drop any later duplicates, working from the end.
        for ($i = $found.Count - 1; $i -ge 1; $i--) { $text = $text.Remove($found[$i].Start, $found[$i].Length) }
        $current = $text.Substring($first.Start, $first.BlockLength)
        $text = $text.Remove($first.Start, $first.BlockLength).Insert($first.Start, $block)
        $action = 'Updated'
        if ($current -ceq $block -and $found.Count -eq 1) { $action = 'Unchanged' }
    }
    else {
        $text = $file.Text
        if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { $text += $nl }
        $text += $block + $nl
    }
    $result = [pscustomobject]@{ Path = $Path; Action = $action; Applied = $false }
    if ($action -eq 'Unchanged') {
        Write-Host "  SecondLine update-check block is already current in $Path." -ForegroundColor Green
    }
    elseif ($PSCmdlet.ShouldProcess($Path, "$action the SecondLine update-check profile block")) {
        $dir = Split-Path $Path -Parent
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void] (New-Item -ItemType Directory -Path $dir -Force) }
        Write-SLTextFile -File $file -Text $text -Path $Path
        $result.Applied = $true
        Write-Host "  $action the SecondLine update-check block in $Path. Remove it with: Disable-SLProfileUpdateCheck -Path '$($Path.Replace("'", "''"))'" -ForegroundColor Green
    }
    if ($PassThru) { $result }
}

