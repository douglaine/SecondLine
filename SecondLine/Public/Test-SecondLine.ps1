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
        Throw if any tool is not OK. Useful in CI.

    .EXAMPLE
        Test-SecondLine

    .EXAMPLE
        Test-SecondLine -Path .\standard.psd1 -PassThru -Quiet |
            Where-Object Status -ne 'OK'
    #>
    [CmdletBinding()]
    param(
        [string] $Path,
        [switch] $PassThru,
        [switch] $Quiet,
        [switch] $Strict
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

        $found = Get-SLVersionText -Text $run.Output -Pattern $tool.VersionPattern
        $notes = @()
        if ($run.TimedOut) { $notes += "did not exit within $($tool.TimeoutSeconds)s and was stopped" }

        if (-not $found) {
            $result.Status = 'UNKNOWN'
            $notes += "no version found in output of '$($tool.Command) $($tool.Arguments)'"
        }
        else {
            $result.Found = $found
            if (Test-SLVersionRule -Found $found -Expect $tool.Expect -Rule $tool.Rule) {
                $result.Status = 'OK'
            }
            else {
                $result.Status = 'MISMATCH'
            }
        }
        $result.Note = ($notes -join '; ')
        $results += $result
    }

    if (-not $Quiet) {
        Write-SLReport -Standard $standard -Results $results
    }

    if ($PassThru) { $results }

    if ($Strict) {
        $bad = @($results | Where-Object { $_.Status -ne 'OK' })
        if ($bad.Count -gt 0) {
            throw "SecondLine: $($bad.Count) of $($results.Count) tools are not OK: $(($bad | ForEach-Object { "$($_.Name) ($($_.Status))" }) -join ', ')"
        }
    }
}
