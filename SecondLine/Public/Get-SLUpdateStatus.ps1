function Get-SLUpdateStatus {
    <#
    .SYNOPSIS
        Reports SecondLine update availability and version policy from the shared cache, offline.

    .DESCRIPTION
        Reads only local files. It never contacts the network, so it is safe in
        scripts and CI. Use Invoke-SLUpdateCheck to refresh the cache.

        Three separate categories:
          Update    UpdateAvailable | UpToDate | Unknown: the newest Gallery release
                    in the cache vs the highest installed version
          Policy    Match | Mismatch | NotInstalled | NotPinned | Invalid: the loaded
                    version vs ModuleVersions.SecondLine in the project standard
          Advisory  NotConfigured. SecondLine has no security-advisory source, so
                    it reports none rather than guess

        Lookup says how fresh the update answer is: Current, Stale (older than
        Updates.RefreshHours), Failed (the last lookup failed, for example offline),
        NotChecked or Disabled. Failed and NotChecked are never reported as up to date.

    .PARAMETER Path
        The folder whose project standard and settings apply. Default: the current folder.

    .PARAMETER Standard
        An explicit standard file.

    .EXAMPLE
        Get-SLUpdateStatus

    .EXAMPLE
        (Get-SLUpdateStatus).Notices
    #>
    [CmdletBinding()]
    param(
        [string] $Path,
        [string] $Standard
    )
    if (-not $Path) { $Path = (Get-Location).ProviderPath }
    $options = ConvertTo-SLUpdateOptions (Get-SLUpdateSettings -Standard $Standard -Directory $Path)
    $state = Get-SLCachedUpdateState -Options $options
    return (Get-SLDependencyHealth -State $state -Standard $Standard -Directory $Path)
}
