# Helpers for the local MongoDB replica set commands.
#
# An mlaunch replica set is described by a .mlaunch_startup JSON file in the
# folder passed to `mlaunch init --dir`. It records the set name, the ports and,
# under startup_info, the exact mongod command line for each node, including
# --dbpath. We read that instead of guessing folder layouts.

# Folders searched when no -Path is given and SECONDLINE_MONGO_DIR is not set.
function Get-SLMongoSearchRoots {
    if ($env:SECONDLINE_MONGO_ROOT) {
        return @($env:SECONDLINE_MONGO_ROOT -split [IO.Path]::PathSeparator | Where-Object { $_ })
    }
    return @(
        (Join-Path $HOME 'mongo-dev'),
        (Join-Path $HOME 'mlaunch'),
        (Join-Path $HOME 'data')
    )
}

# Reads one .mlaunch_startup and returns a description of the set it defines,
# including whether every node's data folder actually exists.
function Read-SLMongoStartupFile {
    param([Parameter(Mandatory)] [string] $File)

    $dir = Split-Path $File -Parent
    $set = [pscustomobject]@{
        PSTypeName    = 'SecondLine.MongoReplicaSet'
        Name          = ''
        Dir           = $dir
        StartupFile   = $File
        Hostname      = 'localhost'
        Ports         = @()
        Nodes         = @()
        Valid         = $false
        Problem       = ''
        MtoolsVersion = ''
    }

    try {
        $json = Get-Content -LiteralPath $File -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        $set.Problem = "not readable as JSON: $($_.Exception.Message)"
        return $set
    }

    $a = $json.parsed_args
    if ($null -eq $a) { $set.Problem = 'no parsed_args section'; return $set }
    if ($a.name)     { $set.Name = "$($a.name)" }
    if ($a.hostname) { $set.Hostname = "$($a.hostname)" }
    if ($json.mtools_version) { $set.MtoolsVersion = "$($json.mtools_version)" }

    # A copied startup file (e.g. in a backup folder) still records the folder it
    # was created for. If that isn't where it sits, it's a copy, not a set.
    if ($a.dir) {
        $recorded = (ConvertTo-SLLocalPath "$($a.dir)").TrimEnd([IO.Path]::DirectorySeparatorChar)
        $actual   = (ConvertTo-SLLocalPath $dir).TrimEnd([IO.Path]::DirectorySeparatorChar)
        if (-not [string]::Equals($recorded, $actual, [StringComparison]::OrdinalIgnoreCase)) {
            $set.Problem = "copy of the startup file for $recorded (it records that folder, not this one)"
            return $set
        }
    }

    if (-not $a.replicaset) { $set.Problem = 'not a replica set (mlaunch init was run without --replicaset)'; return $set }
    if ($a.sharded)         { $set.Problem = 'sharded clusters are not supported yet'; return $set }

    $nodes = @()
    if ($json.startup_info) {
        foreach ($prop in $json.startup_info.PSObject.Properties) {
            $port = 0
            if (-not [int]::TryParse($prop.Name, [ref] $port)) { continue }
            $cmd = "$($prop.Value)"
            $db = ''; $log = ''
            if ($cmd -match '--dbpath\s+"([^"]+)"')  { $db  = $Matches[1] }
            elseif ($cmd -match '--dbpath\s+(\S+)')  { $db  = $Matches[1] }
            if ($cmd -match '--logpath\s+"([^"]+)"') { $log = $Matches[1] }
            elseif ($cmd -match '--logpath\s+(\S+)') { $log = $Matches[1] }
            $db  = ConvertTo-SLLocalPath $db
            $log = ConvertTo-SLLocalPath $log
            $nodes += [pscustomobject]@{
                Port    = $port
                DbPath  = $db
                LogPath = $log
                Exists  = [bool]($db -and (Test-Path -LiteralPath $db -PathType Container))
            }
        }
    }
    if ($nodes.Count -eq 0 -and $a.port -and $a.nodes) {
        # Older files without startup_info: ports only, data folders unknown.
        for ($i = 0; $i -lt [int] $a.nodes; $i++) {
            $nodes += [pscustomobject]@{ Port = [int] $a.port + $i; DbPath = ''; LogPath = ''; Exists = $false }
        }
    }

    $set.Nodes = @($nodes | Sort-Object Port)
    $set.Ports = @($set.Nodes | ForEach-Object { $_.Port })

    if ($set.Nodes.Count -eq 0) { $set.Problem = 'no nodes recorded'; return $set }
    $missing = @($set.Nodes | Where-Object { -not $_.Exists })
    if ($missing.Count -gt 0) {
        $what = ($missing | ForEach-Object { if ($_.DbPath) { $_.DbPath } else { "port $($_.Port): data folder not recorded" } }) -join '; '
        $set.Problem = "node data folders missing: $what"
        return $set
    }
    $set.Valid = $true
    return $set
}

# mlaunch on Windows records paths with mixed separators ("...\replset/rs1\db").
function ConvertTo-SLLocalPath {
    param([string] $Path)
    if (-not $Path) { return '' }
    $sep = [IO.Path]::DirectorySeparatorChar
    $p = $Path -replace '\\\\', '\'
    return ($p -replace '[\\/]', $sep)
}

# Picks the one replica set to act on, or throws a message that says exactly why not.
function Resolve-SLMongoReplicaSet {
    param([string] $Path)

    if (-not $Path -and $env:SECONDLINE_MONGO_DIR) { $Path = $env:SECONDLINE_MONGO_DIR }

    if ($Path) {
        $file = $Path
        if (Test-Path -LiteralPath $Path -PathType Container) { $file = Join-Path $Path '.mlaunch_startup' }
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            throw "No .mlaunch_startup found at $Path. Point -Path (or SECONDLINE_MONGO_DIR) at the folder you passed to 'mlaunch init --dir'."
        }
        $set = Read-SLMongoStartupFile -File (Resolve-Path -LiteralPath $file).ProviderPath
        if (-not $set.Valid) { throw "Replica set at $($set.Dir) can't be used: $($set.Problem)" }
        return $set
    }

    $all = @(Find-SLMongoReplicaSet)
    $valid = @($all | Where-Object Valid)
    if ($valid.Count -eq 1) { return $valid[0] }

    $roots = (Get-SLMongoSearchRoots) -join ', '
    if ($all.Count -eq 0) {
        throw "No .mlaunch_startup found under: $roots. Pass -Path, or set SECONDLINE_MONGO_DIR to the folder you passed to 'mlaunch init --dir'."
    }
    $lines = foreach ($s in $all) {
        $state = if ($s.Valid) { 'valid' } else { "invalid: $($s.Problem)" }
        "  - $($s.Dir) ($state)"
    }
    $list = $lines -join "`n"
    if ($valid.Count -eq 0) {
        throw "Found .mlaunch_startup files, but none describe a usable replica set:`n$list"
    }
    throw "Found more than one usable replica set. Pass -Path (or set SECONDLINE_MONGO_DIR) to pick one:`n$list"
}

# True if something accepts TCP connections on 127.0.0.1:Port.
function Test-SLPortOpen {
    param([Parameter(Mandatory)] [int] $Port, [int] $TimeoutMs = 500)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync('127.0.0.1', $Port)
        if (-not $task.Wait($TimeoutMs)) { return $false }
        return $client.Connected
    }
    catch { return $false }
    finally { $client.Dispose() }
}

function Get-SLOpenPorts {
    param([int[]] $Ports)
    return @($Ports | Where-Object { Test-SLPortOpen -Port $_ })
}

# Waits until every port is open (or, with -Closed, every port is closed).
function Wait-SLPorts {
    param([int[]] $Ports, [int] $TimeoutSeconds, [switch] $Closed)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $open = @(Get-SLOpenPorts $Ports)
        if ($Closed -and $open.Count -eq 0) { return $true }
        if (-not $Closed -and $open.Count -eq $Ports.Count) { return $true }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return $false
}

# Runs one mongosh --eval against a single node, bounded by a timeout.
# mongosh can print its answer and then never exit; Invoke-SLTool keeps the
# output and stops the process.
function Invoke-SLMongosh {
    param(
        [Parameter(Mandatory)] [int] $Port,
        [Parameter(Mandatory)] [string] $Eval,
        [int] $TimeoutSeconds = 8
    )
    $cmd = Get-Command mongosh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { return $null }
    $uri = "mongodb://127.0.0.1:$Port/?directConnection=true&serverSelectionTimeoutMS=2000&connectTimeoutMS=2000"
    if ($Eval.Contains('"')) { throw 'Invoke-SLMongosh: use single quotes inside -Eval.' }
    $r = Invoke-SLTool -Path $cmd.Path -Arguments "`"$uri`" --quiet --norc --eval `"$Eval`"" -TimeoutSeconds $TimeoutSeconds
    $script:SLMongoshTimedOut = [bool] $r.TimedOut
    if ($r.Error) { return $null }
    return $r.Output
}

# Returns the PRIMARY's host:port, or '' if none (yet).
function Get-SLMongoPrimary {
    param([int[]] $Ports)
    foreach ($p in $Ports) {
        if (-not (Test-SLPortOpen -Port $p)) { continue }
        $out = Invoke-SLMongosh -Port $p -Eval "db.hello().primary || ''"
        $script:SLMongoshAnswered = [bool]$out
        if ($out) {
            $line = @($out -split "`r?`n" | Where-Object { $_ -match '^\S+:\d+$' }) | Select-Object -First 1
            if ($line) { return $line.Trim() }
        }
        return ''   # one reachable member is enough to ask
    }
    return ''
}

# Returns @(@{ Name; State }) for each member, or @() if it can't be read.
function Get-SLMongoMembers {
    param([int[]] $Ports)
    # mongosh just timed out without an answer: don't wait on it a second time.
    if ($script:SLMongoshTimedOut -and -not $script:SLMongoshAnswered) { return @() }
    foreach ($p in $Ports) {
        if (-not (Test-SLPortOpen -Port $p)) { continue }
        $out = Invoke-SLMongosh -Port $p -Eval "JSON.stringify(rs.status().members.map(m => ({ Name: m.name, State: m.stateStr })))" -TimeoutSeconds 10
        if (-not $out) { return @() }
        $line = @($out -split "`r?`n" | Where-Object { $_.TrimStart().StartsWith('[') }) | Select-Object -First 1
        if (-not $line) { return @() }
        try { return @($line | ConvertFrom-Json) } catch { return @() }
    }
    return @()
}

# mongod processes belonging to THIS set: matched by --dbpath, so nothing else
# listening on these ports is ever touched.
function Get-SLMongodProcess {
    param($Set)
    $dbPaths = @($Set.Nodes | ForEach-Object { $_.DbPath } | Where-Object { $_ })
    if ($dbPaths.Count -eq 0) { return @() }

    $procs = @()
    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
        try {
            $procs = @(Get-CimInstance Win32_Process -Filter "Name = 'mongod.exe'" -ErrorAction Stop |
                ForEach-Object { [pscustomobject]@{ Id = [int] $_.ProcessId; CommandLine = "$($_.CommandLine)" } })
        }
        catch { $procs = @() }
    }
    if ($procs.Count -eq 0) {
        $procs = @(Get-Process -Name mongod -ErrorAction SilentlyContinue |
            ForEach-Object { [pscustomobject]@{ Id = $_.Id; CommandLine = "$($_.CommandLine)" } })
    }

    $mine = @()
    foreach ($proc in $procs) {
        $line = ConvertTo-SLLocalPath $proc.CommandLine
        foreach ($db in $dbPaths) {
            if ($line.IndexOf($db, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $mine += $proc; break }
        }
    }
    return $mine
}

function Get-SLMlaunchPath {
    $cmd = Get-Command mlaunch -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Path }
    return $null
}
