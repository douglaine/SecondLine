function Disable-SLProfileUpdateCheck {
    <#
    .SYNOPSIS
        Removes the SecondLine update-check block from a PowerShell profile file.

    .DESCRIPTION
        Removes everything from '# >>> SecondLine update check >>>' through
        '# <<< SecondLine update check <<<', including duplicates. Every other byte is
        kept: other lines, encoding, BOM and line endings. A start marker without an
        end marker is reported, and nothing is changed. Use -WhatIf to preview.

    .PARAMETER Path
        The profile file, for example $PROFILE.CurrentUserAllHosts.

    .PARAMETER PassThru
        Return Path, Action (Removed | NotPresent) and Applied.

    .EXAMPLE
        Disable-SLProfileUpdateCheck -Path $PROFILE.CurrentUserAllHosts -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory, Position = 0)] [string] $Path,
        [switch] $PassThru
    )
    $result = [pscustomobject]@{ Path = $Path; Action = 'NotPresent'; Applied = $false }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $file = Read-SLTextFile -Path $Path
        $found = Find-SLProfileBlock -Text $file.Text
        if ($found.Count -gt 0) {
            $result.Action = 'Removed'
            $text = $file.Text
            for ($i = $found.Count - 1; $i -ge 0; $i--) { $text = $text.Remove($found[$i].Start, $found[$i].Length) }
            if ($PSCmdlet.ShouldProcess($Path, 'Remove the SecondLine update-check profile block')) {
                Write-SLTextFile -File $file -Text $text
                $result.Applied = $true
                Write-Host "  Removed the SecondLine update-check block from $Path." -ForegroundColor Green
            }
        }
    }
    if ($result.Action -eq 'NotPresent') { Write-Host "  No SecondLine update-check block in $Path." -ForegroundColor Green }
    if ($PassThru) { $result }
}
