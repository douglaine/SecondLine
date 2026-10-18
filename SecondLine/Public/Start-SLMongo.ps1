function Start-SLMongo {
    <#
    .SYNOPSIS
        Starts the local MongoDB replica set and waits until it can take writes.

    .DESCRIPTION
        1. If every node is already listening, does nothing to the processes.
        2. Otherwise runs 'mlaunch start --dir <set folder>'.
        3. Waits for every node's port (mlaunch staggers nodes, and a node can
           take 20s+ to open its port on a cold start).
        4. Waits for a PRIMARY. Freshly started members are all SECONDARY until
           they elect one, and apps that connect before that can't write.

        Returns the final status (see Get-SLMongoStatus). Throws if the ports
        never open; warns if no PRIMARY appears in time.

    .PARAMETER Path
        The folder passed to 'mlaunch init --dir'. See Get-SLMongoStatus.

    .EXAMPLE
        Start-SLMongo
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string] $Path,
        [int] $PortTimeoutSeconds = 60,
        [int] $PrimaryTimeoutSeconds = 60,
        [switch] $Quiet
    )

    $set = Resolve-SLMongoReplicaSet -Path $Path
    function Say([string] $t, [string] $c = 'Gray') { if (-not $Quiet) { Write-Host "  $t" -ForegroundColor $c } }

    $open = @(Get-SLOpenPorts $set.Ports)
    if ($open.Count -eq $set.Ports.Count) {
        Say "Replica set '$($set.Name)' is already running." 'Green'
    }
    else {
        $mlaunch = Get-SLMlaunchPath
        if (-not $mlaunch) { throw "mlaunch is not on PATH. Install it with: pip install mtools" }
        if (-not $PSCmdlet.ShouldProcess($set.Dir, 'mlaunch start')) { return }

        Say "Starting replica set '$($set.Name)' from $($set.Dir)"
        $run = Invoke-SLTool -Path $mlaunch -Arguments "start --dir `"$($set.Dir)`"" -TimeoutSeconds ($PortTimeoutSeconds + 30)
        if ($run.Error) { throw "Could not run mlaunch: $($run.Error)" }

        Say "Waiting for ports $($set.Ports -join ', ') (up to $PortTimeoutSeconds s)"
        if (-not (Wait-SLPorts -Ports $set.Ports -TimeoutSeconds $PortTimeoutSeconds)) {
            $still = @($set.Ports | Where-Object { -not (Test-SLPortOpen $_) })
            $logs = ($set.Nodes | Where-Object { $still -contains $_.Port } | ForEach-Object { $_.LogPath }) -join ', '
            $msg = "Timed out waiting for ports: $($still -join ', ')."
            if ($logs) { $msg += " Check: $logs" }
            if ($run.Output) { $msg += "`nmlaunch said: $($run.Output)" }
            throw $msg
        }
    }

    Say "Waiting for a PRIMARY (up to $PrimaryTimeoutSeconds s)"
    $deadline = (Get-Date).AddSeconds($PrimaryTimeoutSeconds)
    $primary = ''
    while (-not $primary -and (Get-Date) -lt $deadline) {
        $primary = Get-SLMongoPrimary $set.Ports
        if (-not $primary) { Start-Sleep -Seconds 2 }
    }
    if (-not $primary) {
        Write-Warning "No PRIMARY after $PrimaryTimeoutSeconds s. The set may still be electing; check with Get-SLMongoStatus."
    }

    Get-SLMongoStatus -Path $set.StartupFile -Quiet:$Quiet
}
