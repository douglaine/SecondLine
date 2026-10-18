function Find-SLMongoReplicaSet {
    <#
    .SYNOPSIS
        Finds local mlaunch replica sets and says which ones are usable.

    .DESCRIPTION
        Searches for .mlaunch_startup files (written by 'mlaunch init --dir <folder>')
        and reads each one: set name, ports, and the data folder of every node.
        A set is Valid only if every node's data folder exists, so a stale startup
        file left behind by an old or moved set is reported, not used.

        Search order:
          1. -Path (a folder, or the .mlaunch_startup file itself)
          2. SECONDLINE_MONGO_ROOT (folders separated by ';' on Windows, ':' elsewhere)
          3. ~/mongo-dev, ~/mlaunch, ~/data

    .EXAMPLE
        Find-SLMongoReplicaSet

    .EXAMPLE
        Find-SLMongoReplicaSet -Path D:\mongo
    #>
    [CmdletBinding()]
    param(
        [string[]] $Path,
        [int] $Depth = 4
    )

    $roots = $Path
    if (-not $roots) { $roots = Get-SLMongoSearchRoots }

    $files = @()
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        if (Test-Path -LiteralPath $root -PathType Leaf) { $files += (Resolve-Path -LiteralPath $root).ProviderPath; continue }
        $direct = Join-Path $root '.mlaunch_startup'
        if (Test-Path -LiteralPath $direct -PathType Leaf) { $files += (Resolve-Path -LiteralPath $direct).ProviderPath }
        $files += @(Get-ChildItem -LiteralPath $root -Filter '.mlaunch_startup' -Recurse -Depth $Depth -Force -File -ErrorAction SilentlyContinue |
            ForEach-Object { $_.FullName })
    }

    foreach ($f in ($files | Sort-Object -Unique)) {
        Read-SLMongoStartupFile -File $f
    }
}
