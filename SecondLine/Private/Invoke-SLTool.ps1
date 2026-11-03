# Runs a command-line tool and returns its combined output, with a timeout.
#
# Why not just `& tool --version`?
#   - Some tools answer and then never exit (a hang on exit kills an audit).
#   - In Windows PowerShell 5.1, stderr from native tools can become terminating errors.
# A Process with redirected streams and WaitForExit(timeout) avoids both.

function Invoke-SLTool {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '',
        Justification = 'Kill after a timeout fails if the process exited meanwhile; that is the outcome we want.')]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string]   $Arguments = '',
        [int]      $TimeoutSeconds = 15
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($ext -eq '.cmd' -or $ext -eq '.bat') {
        $psi.FileName  = $env:ComSpec
        $psi.Arguments = '/d /c ""' + $Path + '" ' + $Arguments + '"'
    }
    else {
        $psi.FileName  = $Path
        $psi.Arguments = $Arguments
    }
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        [void] $proc.Start()
    }
    catch {
        return [pscustomobject]@{ Output = ''; TimedOut = $false; Error = $_.Exception.Message; ExitCode = -1 }
    }

    # Read both streams asynchronously so a full buffer can't deadlock the child.
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()

    $timedOut = -not $proc.WaitForExit($TimeoutSeconds * 1000)
    if ($timedOut) {
        try { $proc.Kill() } catch { }
        [void] $proc.WaitForExit(2000)
    }

    $out = ''
    if ($outTask.Wait(2000)) { $out += $outTask.Result }
    if ($errTask.Wait(2000)) { $out += "`n" + $errTask.Result }
    $code = -1
    if (-not $timedOut) { try { $code = $proc.ExitCode } catch { $code = -1 } }
    $proc.Dispose()

    return [pscustomobject]@{ Output = $out.Trim(); TimedOut = $timedOut; Error = $null; ExitCode = $code }
}
