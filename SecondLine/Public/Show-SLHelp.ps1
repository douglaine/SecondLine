function Show-SLHelp {
    <#
    .SYNOPSIS
        Shows SecondLine's configuration, version and automatically discovered commands.
    .DESCRIPTION
        A read-only front door. It lists the module's exports with their own help
        synopses, so a new exported command appears automatically. It reads the
        applicable standard and the version policy, but never audits tools, repairs
        files, installs updates or starts or stops MongoDB.

        Normal use reads the shared per-user update cache (no network). If that
        result isn't current, it starts one background lookup and returns at once.
        A newer-version notice appears when the lookup finishes. The cache, its lock
        and its daily refresh are shared with Invoke-SLUpdateCheck and the opt-in
        profile block (Enable-SLProfileUpdateCheck), so help calls and shell
        sessions don't repeat a lookup. Checks are off in CI.
    .PARAMETER Command
        Show detailed help for one exported SecondLine command. Does not execute it.
    .PARAMETER CheckForUpdates
        Force a background refresh even when the cached result is current.
    .PARAMETER NoUpdateCheck
        Do not start an update check. Useful offline or in automation.
    .PARAMETER PassThru
        Also return structured version, configuration and command information.
    .EXAMPLE
        Show-SLHelp
    .EXAMPLE
        Show-SLHelp -Command Stop-SLMongo
    .EXAMPLE
        Show-SLHelp -CheckForUpdates
    .LINK
        about_SecondLine
    #>
    [CmdletBinding()]
    param(
        [string] $Command,
        [switch] $CheckForUpdates,
        [switch] $NoUpdateCheck,
        [switch] $PassThru
    )
    if ($CheckForUpdates -and $NoUpdateCheck) { throw 'Choose CheckForUpdates or NoUpdateCheck, not both.' }
    $module = $ExecutionContext.SessionState.Module
    $commands = @($module.ExportedCommands.Values | Sort-Object Name)
    if ($Command) {
        $selected = @($commands | Where-Object Name -eq $Command)
        if ($selected.Count -ne 1) { throw "'$Command' is not an exported SecondLine command. Run Show-SLHelp to list commands." }
        Get-Help -Name ("SecondLine\" + $selected[0].Name) -Full
        return
    }
    $update = Get-SLHelpUpdate -Loaded "$($module.Version)" -Refresh:$CheckForUpdates -NoUpdateCheck:$NoUpdateCheck
    $standard = $null
    $configurationNote = ''
    try { $standard = Get-SecondLineStandard }
    catch { $configurationNote = $_.Exception.Message }

    $catalog = @(
        foreach ($item in $commands) {
            $help = Get-Help -Name ("SecondLine\" + $item.Name)
            [pscustomobject]@{ Name = $item.Name; Synopsis = "$($help.Synopsis)".Trim() }
        }
    )
    Write-Host "SecondLine $($module.Version)" -ForegroundColor Cyan
    Write-Host "Loaded from: $($module.ModuleBase)"
    if ($standard) {
        Write-Host "Configuration: $($standard.Path) ($($standard.Name))"
    }
    else { Write-Host "Configuration: $configurationNote" }
    Write-Host 'Lookup order: explicit standard path, SECONDLINE_STANDARD, nearest parent standard.'
    Write-Host 'A standard may inherit another file with Extends; @development uses this installed package.'
    if ($update.Health) {
        $policyColor = 'Gray'
        if ($update.Health.Policy -in 'Mismatch', 'NotInstalled', 'Invalid') { $policyColor = 'Yellow' }
        Write-Host "Version policy: $($update.Health.PolicyNote)" -ForegroundColor $policyColor
    }
    if ($update.Status -eq 'UpdateAvailable') {
        Write-Host "SecondLine $($update.LatestVersion) available; installed $($update.Installed)." -ForegroundColor Yellow
    }
    elseif ($update.Status -eq 'UpToDate') {
        Write-Host "Gallery stable: $($update.LatestVersion); no newer stable version found. $($update.Note)"
    }
    else { Write-Host $update.Note }
    $catalog | Format-Table Name, Synopsis -AutoSize -Wrap | Out-String -Width 120 | Write-Host
    Write-Host 'Details: Show-SLHelp -Command <name> | Guide: Get-Help about_SecondLine'
    Write-Host 'Help only: no listed command was executed and no configuration was changed.'
    if ($PassThru) {
        [pscustomobject]@{ Version = $module.Version; ModulePath = $module.ModuleBase; Standard = $standard; ConfigurationNote = $configurationNote; Update = $update; Commands = $catalog }
    }
}

# The help front door's update line: the cached state, plus a background refresh when
# it isn't current. Status: UpdateAvailable | UpToDate | Checking | Unknown | NotChecked | Disabled.
function Get-SLHelpUpdate {
    param([string] $Loaded, [switch] $Refresh, [switch] $NoUpdateCheck)
    $directory = (Get-Location).ProviderPath
    $settingsNote = ''
    try { $settings = Get-SLUpdateSettings -Directory $directory }
    catch {
        # A broken project file must not break help; use defaults for this answer.
        $settings = Merge-SLSettingLayer -Layers @([pscustomobject]@{ Source = 'default'; Data = @{ Updates = $script:SLUpdateDefaults } }) -Section 'Updates'
        $settingsNote = " Update settings unreadable, defaults used: $($_.Exception.Message)"
    }
    $options = ConvertTo-SLUpdateOptions $settings
    $state = Get-SLCachedUpdateState -Options $options
    $background = 'NotRequested'
    if (-not $NoUpdateCheck) { $background = Start-SLBackgroundUpdateCheck -Options $options -State $state -Directory $directory -Force:$Refresh }

    $status = 'NotChecked'
    $note = 'Version check not requested.'
    if ($state.Update -eq 'UpdateAvailable') { $status = 'UpdateAvailable'; $note = Format-SLUpdateLine -State $state }
    elseif ($state.Update -eq 'UpToDate' -and $state.Lookup -eq 'Current') { $status = 'UpToDate'; $note = "(checked $(Format-SLAge $state.CheckedUtc))" }
    elseif ($background -in 'Started', 'InFlight') { $status = 'Checking'; $note = 'Checking Gallery in the background; help does not wait. A newer-version notice appears when ready.' }
    elseif ($background -eq 'Disabled') { $status = 'Disabled'; $note = Format-SLUpdateLine -State $state -DisabledBy $settings['Enabled'].Source }
    elseif ($state.Lookup -eq 'Failed' -or $background -eq 'Unavailable') {
        $status = 'Unknown'
        $note = 'Background Gallery lookup unavailable; version status unknown. Help is still available.'
        if ($state.Lookup -eq 'Failed') { $note = Format-SLUpdateLine -State $state }
    }
    elseif ($state.Lookup -ne 'NotChecked') { $status = 'Unknown'; $note = Format-SLUpdateLine -State $state }
    if ($background -in 'Started', 'InFlight' -and $status -in 'UpdateAvailable', 'UpToDate') { $note += ' Refreshing in the background.' }

    $health = $null
    try { $health = Get-SLDependencyHealth -State $state -Directory $directory -Loaded $Loaded }
    catch { Write-Verbose "Version policy unavailable: $($_.Exception.Message)" }
    return [pscustomobject]@{
        Status        = $status
        LatestVersion = $state.Latest
        Installed     = $state.Installed
        CheckedUtc    = $state.CheckedUtc
        Lookup        = $state.Lookup
        Background    = $background
        Note          = $note + $settingsNote
        Health        = $health
    }
}
