function Stop-SLMongo {
    <#
    .SYNOPSIS
        Stops the local MongoDB replica set, escalating only as far as needed.

    .DESCRIPTION
        1. 'mlaunch stop --dir <set folder>', bounded by a timeout (it can fail or
           hang on Windows), then wait for the ports to close.
        2. Still up: a clean shutdown command to each node through mongosh,
           secondaries first and the primary last (a primary can refuse to step
           down while secondaries are up, so it gets force:true).
        3. Still up: stop the mongod processes that belong to THIS set, matched
           by their data folder, never by port, so nothing else is touched.
           mongod replays its journal on the next start.

    .PARAMETER Path
        The folder passed to 'mlaunch init --dir'. See Get-SLMongoStatus.

    .PARAMETER NoKill
        Stop after step 2 instead of killing processes.

    .EXAMPLE
        Stop-SLMongo
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Quiet',
        Justification = 'Read by the nested Say function.')]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string] $Path,
        [switch] $NoKill,
        [switch] $Quiet
    )

    $set = Resolve-SLMongoReplicaSet -Path $Path
    function Say([string] $t, [string] $c = 'Gray') { if (-not $Quiet) { Write-Host "  $t" -ForegroundColor $c } }

    if (@(Get-SLOpenPorts $set.Ports).Count -eq 0) {
        Say "Replica set '$($set.Name)' is already stopped." 'Green'
        return [pscustomobject]@{ Name = $set.Name; Stopped = $true; Method = 'already stopped' }
    }
    if (-not $PSCmdlet.ShouldProcess($set.Dir, 'stop replica set')) { return }

    # 1. mlaunch stop
    $method = ''
    $mlaunch = Get-SLMlaunchPath
    if ($mlaunch) {
        Say "Stopping replica set '$($set.Name)' with mlaunch"
        $run = Invoke-SLTool -Path $mlaunch -Arguments "stop --dir `"$($set.Dir)`"" -TimeoutSeconds 30
        # mlaunch stop often fails on Windows (traceback, non-zero exit). When it
        # does, don't spend 20 s waiting on it.
        $wait = 20
        if ($run.TimedOut) { Say 'mlaunch stop did not finish in 30 s.' 'Yellow'; $wait = 3 }
        elseif ($run.ExitCode -ne 0) { Say "mlaunch stop failed (exit code $($run.ExitCode))." 'Yellow'; $wait = 3 }
        if (Wait-SLPorts -Ports $set.Ports -TimeoutSeconds $wait -Closed) { $method = 'mlaunch stop' }
    }
    else {
        Say 'mlaunch not on PATH; skipping to shutdown commands.' 'Yellow'
    }

    # 2. Clean shutdown, secondaries first, primary last.
    if (-not $method) {
        Say 'Still running - sending shutdown through mongosh (secondaries first).' 'Yellow'
        $primary = Get-SLMongoPrimary $set.Ports
        $primaryPort = 0
        if ($primary -match ':(\d+)$') { $primaryPort = [int] $Matches[1] }
        $order = @($set.Ports | Where-Object { $_ -ne $primaryPort } | Sort-Object -Descending)
        if ($primaryPort) { $order += $primaryPort }
        foreach ($p in $order) {
            if (-not (Test-SLPortOpen $p)) { continue }
            $force = if ($p -eq $primaryPort -or -not $primaryPort) { 'true' } else { 'false' }
            Say "  shutdown on port $p"
            [void] (Invoke-SLMongosh -Port $p -Eval "db.adminCommand({ shutdown: 1, force: $force })" -TimeoutSeconds 10)
        }
        if (Wait-SLPorts -Ports $set.Ports -TimeoutSeconds 15 -Closed) { $method = 'shutdown command' }
    }

    # 3. Kill this set's mongod processes only.
    if (-not $method -and -not $NoKill) {
        $procs = @(Get-SLMongodProcess -Set $set)
        if ($procs.Count -gt 0) {
            Say "Still running - stopping mongod processes $(($procs | ForEach-Object Id) -join ', ')" 'Yellow'
            foreach ($proc in $procs) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
            if (Wait-SLPorts -Ports $set.Ports -TimeoutSeconds 10 -Closed) { $method = 'killed' }
        }
        else {
            Say "No mongod process found with this set's data folders; something else holds the ports." 'Yellow'
        }
    }

    $still = @(Get-SLOpenPorts $set.Ports)
    if ($still.Count -gt 0) {
        throw "Replica set '$($set.Name)' still has ports open: $($still -join ', ')."
    }
    Say "Replica set '$($set.Name)' stopped ($method)." 'Green'
    [pscustomobject]@{ Name = $set.Name; Stopped = $true; Method = $method }
}
