# Prints the human-readable audit report. Plain ASCII so it renders the same
# in Windows PowerShell 5.1, PowerShell 7, and a CI log.

function Write-SLReport {
    param(
        [Parameter(Mandatory)] $Standard,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Results
    )

    $colors = @{ OK = 'Green'; MISMATCH = 'Red'; MISSING = 'Red'; UNKNOWN = 'Yellow' }

    $title = $Standard.Name
    if ($Standard.Version) { $title = "$title v$($Standard.Version)" }

    Write-Host ''
    Write-Host "  SecondLine - $title" -ForegroundColor White
    Write-Host "  $($Standard.Path)" -ForegroundColor DarkGray
    Write-Host ''

    $nameWidth = 4
    foreach ($r in $Results) { if ($r.Name.Length -gt $nameWidth) { $nameWidth = $r.Name.Length } }

    foreach ($r in $Results) {
        $found = $r.Found
        if (-not $found) { $found = '-' }
        $line = '  {0,-9} {1} {2,-12} expect {3} ({4})' -f $r.Status, $r.Name.PadRight($nameWidth), $found, $r.Expect, $r.Rule
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
    Write-Host ''
    Write-Host ("  {0} of {1} tools OK" -f $ok, $Results.Count) -ForegroundColor $summaryColor
    Write-Host ''
}
