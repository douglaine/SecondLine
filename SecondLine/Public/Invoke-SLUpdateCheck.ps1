function Invoke-SLUpdateCheck {
    <#
    .SYNOPSIS
        Explicitly refreshes the shared SecondLine update cache from the PowerShell Gallery.

    .DESCRIPTION
        Looks up the newest stable SecondLine release when the shared cache is due
        (daily by default), or always with -Force. It prints one concise line.

        The cache is per user, per machine, in LocalApplicationData\SecondLine (or
        SECONDLINE_CACHE_DIR). Show-SLHelp, the opt-in profile block and this
        command all share it. A lock file keeps concurrent sessions from repeating a
        lookup. A session that finds the lock taken uses the cached result. Requests
        time out after Updates.TimeoutSeconds (default 3) and are retried
        Updates.Retries times (default 1). A failed lookup is retried after
        Updates.FailureBackoffMinutes (default 60), and is reported as failed, never
        as up to date.

        It queries only the Gallery, only for SecondLine. It never installs or
        approves anything. Installing a release and approving it for a project
        (ModuleVersions in the project standard) are separate, explicit steps.

    .PARAMETER Force
        Look up now, even if the cached result is current or a failure is backing off.

    .PARAMETER NoticeFile
        Leave an actionable notice for the next interactive shell's profile block.

    .PARAMETER Quiet
        Print nothing.

    .PARAMETER PassThru
        Return the status object.

    .PARAMETER Path
        The folder whose project settings apply. Default: the current folder.

    .EXAMPLE
        Invoke-SLUpdateCheck

    .EXAMPLE
        Invoke-SLUpdateCheck -Force -PassThru
    #>
    [CmdletBinding()]
    param(
        [switch] $Force,
        [switch] $NoticeFile,
        [switch] $Quiet,
        [switch] $PassThru,
        [string] $Path
    )
    if (-not $Path) { $Path = (Get-Location).ProviderPath }
    $settings = Get-SLUpdateSettings -Directory $Path
    $options = ConvertTo-SLUpdateOptions $settings
    $state = Update-SLUpdateCache -Options $options -Force:$Force -NoticeFile:$NoticeFile
    if (-not $Quiet) {
        $color = 'Gray'
        if ($state.Update -eq 'UpdateAvailable') { $color = 'Yellow' }
        Write-Host (Format-SLUpdateLine -State $state -DisabledBy $settings['Enabled'].Source) -ForegroundColor $color
    }
    if ($PassThru) { $state }
}
