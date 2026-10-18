function Get-SLMongoStatus {
    <#
    .SYNOPSIS
        Shows whether the local MongoDB replica set is up, and its PRIMARY.

    .DESCRIPTION
        Read-only. Reports, for the replica set mlaunch created:
          - which node ports accept connections
          - which mongod processes belong to the set (matched by data folder)
          - the PRIMARY, and each member's state

        Status values:
          UP        every node is listening and there is a PRIMARY
          ELECTING  every node is listening, no PRIMARY yet
          UNKNOWN   every node is listening, but mongosh is missing or not
                    responding, so the PRIMARY can't be checked
          PARTIAL   some nodes are listening
          DOWN      no node is listening

    .PARAMETER Path
        The folder passed to 'mlaunch init --dir'. If omitted, uses
        SECONDLINE_MONGO_DIR, else the one usable set Find-SLMongoReplicaSet finds.

    .EXAMPLE
        Get-SLMongoStatus

    .EXAMPLE
        (Get-SLMongoStatus -Quiet).Status -eq 'UP'
    #>
    [CmdletBinding()]
    param(
        [string] $Path,
        [switch] $Quiet
    )

    $set  = Resolve-SLMongoReplicaSet -Path $Path
    $open = @(Get-SLOpenPorts $set.Ports)

    $primary = ''
    $members = @()
    $note = ''
    $script:SLMongoshTimedOut = $false
    $script:SLMongoshAnswered = $false
    if ($open.Count -gt 0) {
        if (-not (Get-Command mongosh -CommandType Application -ErrorAction SilentlyContinue)) {
            $note = 'mongosh is not on PATH, so the PRIMARY and member states are unknown.'
        }
        else {
            $primary = Get-SLMongoPrimary $set.Ports
            if ($script:SLMongoshTimedOut -and -not $script:SLMongoshAnswered) {
                $note = 'mongosh did not respond, so the PRIMARY and member states are unknown.'
            }
            else {
                $members = @(Get-SLMongoMembers $set.Ports)
            }
        }
    }

    $status = 'DOWN'
    if ($open.Count -eq $set.Ports.Count) {
        if ($primary) { $status = 'UP' } elseif ($note) { $status = 'UNKNOWN' } else { $status = 'ELECTING' }
    }
    elseif ($open.Count -gt 0) { $status = 'PARTIAL' }

    $procs = @(Get-SLMongodProcess -Set $set)

    $result = [pscustomobject]@{
        PSTypeName = 'SecondLine.MongoStatus'
        Status     = $status
        Name       = $set.Name
        Dir        = $set.Dir
        Ports      = $set.Ports
        OpenPorts  = $open
        Primary    = $primary
        Members    = $members
        ProcessIds = @($procs | ForEach-Object { $_.Id })
        Note       = $note
    }

    if (-not $Quiet) { Write-SLMongoReport -Result $result -Set $set }
    $result
}

function Write-SLMongoReport {
    param($Result, $Set)
    $colors = @{ UP = 'Green'; ELECTING = 'Yellow'; UNKNOWN = 'Yellow'; PARTIAL = 'Yellow'; DOWN = 'Red' }
    Write-Host ''
    Write-Host ("  SecondLine - MongoDB replica set '{0}'  {1}" -f $Result.Name, $Result.Status) -ForegroundColor $colors[$Result.Status]
    Write-Host "  $($Result.Dir)" -ForegroundColor DarkGray
    Write-Host ''
    foreach ($node in $Set.Nodes) {
        $isOpen = $Result.OpenPorts -contains $node.Port
        $member = $Result.Members | Where-Object { $_.Name -match ":$($node.Port)$" } | Select-Object -First 1
        $state = if ($member) { $member.State } elseif ($isOpen) { 'listening' } else { 'down' }
        $color = if (-not $isOpen) { 'Red' } elseif ($state -eq 'PRIMARY') { 'Green' } else { 'Gray' }
        Write-Host ('  {0,-6} {1,-10} {2}' -f $node.Port, $state, $node.DbPath) -ForegroundColor $color
    }
    if ($Result.Status -eq 'UP') {
        Write-Host ''
        Write-Host "  PRIMARY: $($Result.Primary)" -ForegroundColor Green
    }
    if ($Result.Note) {
        Write-Host ''
        Write-Host "  $($Result.Note)" -ForegroundColor Yellow
    }
    Write-Host ''
}
