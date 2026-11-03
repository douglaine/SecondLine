function Get-SLSetting {
    <#
    .SYNOPSIS
        Shows effective SecondLine settings, each with the file it came from.

    .DESCRIPTION
        Settings come in layers. Each section has its own documented precedence:

          ModuleVersions (execution policy: the version a project approves)
            machine settings < user settings < project chain (root parent < ... < nearest)
            A project value always wins. A personal value it replaces is listed
            under Overridden, so it is never ignored silently.

          Updates (notification preferences)
            defaults < project chain < machine settings < user settings
            Notices are personal, so the user has the last word. They never change
            an approved version. In CI, or with SECONDLINE_NO_UPDATE_CHECK=1, checks are off.

        Locations:
          machine  CommonApplicationData\SecondLine\settings.psd1 (SECONDLINE_MACHINE_SETTINGS)
          user     ApplicationData\SecondLine\settings.psd1       (SECONDLINE_USER_SETTINGS)
          project  the nearest secondline.standard.psd1 and its Extends parents

        Machine and user files are ignored in CI (CI, GITHUB_ACTIONS or TF_BUILD),
        with SECONDLINE_NO_HOST_SETTINGS=1, or with -NoHostSettings. So a project's
        CI result depends only on files in the repository.

    .PARAMETER Path
        The folder where the standard search starts. Default: the current folder.

    .PARAMETER Standard
        An explicit standard file.

    .PARAMETER NoHostSettings
        Ignore the machine and user settings files, as CI does.

    .EXAMPLE
        Get-SLSetting | Format-Table Section, Name, Value, Source

    .EXAMPLE
        Get-SLSetting -NoHostSettings    # what CI will see
    #>
    [CmdletBinding()]
    param(
        [string] $Path,
        [string] $Standard,
        [switch] $NoHostSettings
    )
    if (-not $Path) { $Path = (Get-Location).ProviderPath }
    $paths = Get-SLHostSettingsPath
    $hostOff = $NoHostSettings -or $env:SECONDLINE_NO_HOST_SETTINGS -eq '1' -or (Test-SLCIEnvironment)
    foreach ($scope in 'Machine', 'User') {
        $state = 'not present'
        if (Test-Path -LiteralPath $paths.$scope -PathType Leaf) { $state = 'present' }
        if ($hostOff) { $state += ', ignored' }
        [pscustomobject]@{ PSTypeName = 'SecondLine.Setting'; Section = 'Layer'; Name = $scope; Value = $paths.$scope; Source = $state; Overridden = '' }
    }
    foreach ($layer in @(Get-SLProjectSettingsLayer -Standard $Standard -Directory $Path -DevelopmentPath $script:SLDevelopmentStandard)) {
        [pscustomobject]@{ PSTypeName = 'SecondLine.Setting'; Section = 'Layer'; Name = 'Project'; Value = $layer.Path; Source = 'present'; Overridden = '' }
    }
    $sections = [ordered]@{
        ModuleVersions = Resolve-SLModuleVersionPolicy -Standard $Standard -Directory $Path -NoHostSettings:$NoHostSettings -DevelopmentPath $script:SLDevelopmentStandard
        Updates        = Get-SLUpdateSettings -Standard $Standard -Directory $Path -NoHostSettings:$NoHostSettings
    }
    foreach ($section in $sections.Keys) {
        $table = $sections[$section]
        foreach ($name in @($table.Keys | Sort-Object)) {
            $entry = $table[$name]
            [pscustomobject]@{
                PSTypeName = 'SecondLine.Setting'
                Section    = $section
                Name       = $entry.Name
                Value      = $entry.Value
                Source     = $entry.Source
                Overridden = (@($entry.Overridden | ForEach-Object { "$($_.Value) from $($_.Source)" }) -join '; ')
            }
        }
    }
}
