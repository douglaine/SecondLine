BeforeDiscovery {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'SecondLine\SecondLine.psd1') -Force
}
BeforeAll {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'SecondLine\SecondLine.psd1') -Force
    # Every test gets its own cache and no CI or opt-out variables, so the runner's
    # environment and the real per-user cache can't affect results.
    $script:savedEnv = @{}
    foreach ($name in 'SECONDLINE_CACHE_DIR', 'SECONDLINE_NO_UPDATE_CHECK', 'CI', 'GITHUB_ACTIONS', 'TF_BUILD', 'SECONDLINE_STANDARD', 'SECONDLINE_USER_SETTINGS', 'SECONDLINE_MACHINE_SETTINGS') {
        $script:savedEnv[$name] = [Environment]::GetEnvironmentVariable($name)
    }
}
AfterAll {
    foreach ($name in $script:savedEnv.Keys) { [Environment]::SetEnvironmentVariable($name, $script:savedEnv[$name]) }
}
Describe 'Help front door' {
    InModuleScope SecondLine {
        BeforeEach {
            $env:SECONDLINE_CACHE_DIR = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            foreach ($name in 'SECONDLINE_NO_UPDATE_CHECK', 'CI', 'GITHUB_ACTIONS', 'TF_BUILD') { [Environment]::SetEnvironmentVariable($name, $null) }
            $env:SECONDLINE_USER_SETTINGS = Join-Path $TestDrive 'no-user.psd1'
            $env:SECONDLINE_MACHINE_SETTINGS = Join-Path $TestDrive 'no-machine.psd1'
            Mock Get-SLGalleryVersion { throw 'Unexpected network access' }
            Mock Start-SLBackgroundUpdateCheck { 'Started' }
            Mock Get-SLInstalledVersion { '0.3.0' }
            Mock Start-SLMongo { throw 'Help must not start MongoDB' }
            Mock Stop-SLMongo { throw 'Help must not stop MongoDB' }
            Mock Test-SecondLine { throw 'Help must not run audits' }
            Mock Write-Host {}
        }
        It 'discovers all exports and requests a background check without synchronous network access' {
            Mock Get-SecondLineStandard { [pscustomobject]@{ Path = 'example.psd1'; Name = 'Example' } }
            $result = Show-SLHelp -PassThru
            ($result.Commands.Name -join ',') | Should -Be (((Get-Module SecondLine).ExportedCommands.Keys | Sort-Object) -join ',')
            $result.Standard.Name | Should -Be Example
            $result.Update.Status | Should -Be Checking
            Should -Invoke Start-SLBackgroundUpdateCheck -Times 1
            Should -Invoke Get-SLGalleryVersion -Times 0
            Should -Invoke Start-SLMongo -Times 0
            Should -Invoke Stop-SLMongo -Times 0
            Should -Invoke Test-SecondLine -Times 0
        }
        It 'lists the new commands automatically, with their synopses' {
            Mock Get-SecondLineStandard { throw 'none' }
            $result = Show-SLHelp -PassThru
            foreach ($name in 'Test-SLLineEnding', 'Get-SLSetting', 'Invoke-SLUpdateCheck', 'Enable-SLProfileUpdateCheck', 'Test-SLPolicyReference') {
                ($result.Commands | Where-Object Name -eq $name).Synopsis | Should -Not -BeNullOrEmpty
            }
        }
        It 'does not start a check with -NoUpdateCheck' {
            Mock Get-SecondLineStandard { throw 'none' }
            $result = Show-SLHelp -NoUpdateCheck -PassThru
            $result.Update.Status | Should -Be NotChecked
            Should -Invoke Start-SLBackgroundUpdateCheck -Times 0
        }
        It 'passes -CheckForUpdates through as a forced background refresh' {
            Mock Get-SecondLineStandard { throw 'none' }
            $null = Show-SLHelp -CheckForUpdates -PassThru
            Should -Invoke Start-SLBackgroundUpdateCheck -Times 1 -ParameterFilter { $Force }
        }
        It 'still shows commands when configuration cannot be loaded' {
            Mock Get-SecondLineStandard { throw 'Bad standard' }
            $result = Show-SLHelp -PassThru
            $result.ConfigurationNote | Should -Match 'Bad standard'
            $result.Commands.Count | Should -BeGreaterThan 0
        }
        It 'reads detailed command help without running the command' {
            Mock Get-Help { [pscustomobject]@{ Name = 'Stop-SLMongo' } }

            $help = Show-SLHelp -Command Stop-SLMongo
            $help.Name | Should -Be Stop-SLMongo
            Should -Invoke Get-Help -Times 1 -ParameterFilter { $Name -eq 'SecondLine\Stop-SLMongo' -and $Full }
            Should -Invoke Stop-SLMongo -Times 0
        }
        It 'rejects commands outside this module' {
            { Show-SLHelp -Command Remove-Item } | Should -Throw '*not an exported SecondLine command*'
        }
        It 'reports an available version and reuses the shared cached lookup' {
            Mock Get-SLGalleryVersion { '99.0.0' }
            $options = $script:SLUpdateDefaults.Clone()
            $checked = Update-SLUpdateCache -Options $options
            $cached = Update-SLUpdateCache -Options $options
            $checked.Update | Should -Be UpdateAvailable
            $checked.Message | Should -Be 'SecondLine 99.0.0 available; installed 0.3.0.'
            $cached.Latest | Should -Be '99.0.0'
            $cached.Ran | Should -BeFalse
            Should -Invoke Get-SLGalleryVersion -Times 1
        }
        It 'shows the cached update in help without another lookup' {
            Mock Get-SLGalleryVersion { '99.0.0' }
            Mock Get-SecondLineStandard { throw 'none' }
            $null = Update-SLUpdateCache -Options $script:SLUpdateDefaults.Clone()
            $result = Show-SLHelp -PassThru
            $result.Update.Status | Should -Be UpdateAvailable
            Should -Invoke Start-SLBackgroundUpdateCheck -Times 1
            Should -Invoke Get-SLGalleryVersion -Times 1
        }
        It 'reports no newer release for equal or older Gallery versions' {
            Mock Get-SLGalleryVersion { '0.3.0' }
            (Update-SLUpdateCache -Options $script:SLUpdateDefaults.Clone()).Update | Should -Be UpToDate
            Mock Get-SLInstalledVersion { '0.4.0' }
            (Get-SLCachedUpdateState -Options $script:SLUpdateDefaults.Clone()).Update | Should -Be UpToDate
        }
        It 'does not report lookup failure as up-to-date' {
            $state = Update-SLUpdateCache -Options $script:SLUpdateDefaults.Clone()
            $state.Lookup | Should -Be Failed
            $state.Update | Should -Be Unknown
            Format-SLUpdateLine -State $state | Should -Match 'not up to date'
        }
        It 'reports an expired cache as stale during ordinary help, without a synchronous refresh' {
            $cache = Read-SLUpdateCache
            $old = [DateTime]::UtcNow.AddDays(-2).Ticks
            $cache.Entries | Add-Member 'PSGallery/SecondLine/stable' ([pscustomobject]@{ Latest = '99.0.0'; CheckedTicks = $old; AttemptTicks = $old; LastError = $null; NextCheckTicks = $old })
            Write-SLUpdateCache -Cache $cache
            (Get-SLCachedUpdateState -Options $script:SLUpdateDefaults.Clone()).Lookup | Should -Be Stale
            Should -Invoke Get-SLGalleryVersion -Times 0
        }
    }
    It 'ships a discoverable about topic' {
        (Get-Help about_SecondLine | Out-String) | Should -Match 'CONFIGURATION'
    }
}
Describe 'Background help updates' {
    InModuleScope SecondLine {
        BeforeEach {
            Remove-Variable SLUpdateJobState -Scope Script -ErrorAction SilentlyContinue
            Mock Start-Job { [pscustomobject]@{ State = 'Running'; Id = 123 } }
            Mock Register-ObjectEvent {}
            Mock Remove-Job {}
            $script:enabled = $script:SLUpdateDefaults.Clone()
            $script:notChecked = [pscustomobject]@{ Lookup = 'NotChecked'; NextDueUtc = $null }
        }
        It 'starts one background lookup and does not duplicate an active lookup' {
            Start-SLBackgroundUpdateCheck -Options $enabled -State $notChecked | Should -Be Started
            Start-SLBackgroundUpdateCheck -Options $enabled -State $notChecked | Should -Be InFlight
            Should -Invoke Start-Job -Times 1
            Should -Invoke Register-ObjectEvent -Times 1
        }
        It 'does not launch anything when checks are disabled' {
            $off = $script:SLUpdateDefaults.Clone(); $off.Enabled = $false
            Start-SLBackgroundUpdateCheck -Options $off -State $notChecked | Should -Be Disabled
            Should -Invoke Start-Job -Times 0
        }
        It 'reuses fresh shared results without a new job' {
            Start-SLBackgroundUpdateCheck -Options $enabled -State ([pscustomobject]@{ Lookup = 'Current' }) | Should -Be NotNeeded
            Should -Invoke Start-Job -Times 0
        }
        It 'respects the shared failure backoff' {
            $failed = [pscustomobject]@{ Lookup = 'Failed'; NextDueUtc = [DateTime]::UtcNow.AddMinutes(30) }
            Start-SLBackgroundUpdateCheck -Options $enabled -State $failed | Should -Be NotNeeded
            Should -Invoke Start-Job -Times 0
        }
        It 'forces a refresh of cached results only when requested' {
            Start-SLBackgroundUpdateCheck -Options $enabled -State ([pscustomobject]@{ Lookup = 'Current' }) -Force | Should -Be Started
            Should -Invoke Start-Job -Times 1
        }
        It 'reports job startup failure as unavailable and backs off' {
            Mock Start-Job { throw 'Jobs unavailable' }
            Start-SLBackgroundUpdateCheck -Options $enabled -State $notChecked | Should -Be Unavailable
            Start-SLBackgroundUpdateCheck -Options $enabled -State $notChecked | Should -Be Unavailable
            Should -Invoke Start-Job -Times 1
        }
        It 'registers a completion action that announces a newer version and cleans up' {
            Mock Register-ObjectEvent { $script:HelpCompletionAction = $Action }
            Mock Receive-Job { [pscustomobject]@{ Notice = 'SecondLine 99.0.0 available; installed 0.3.0.' } }
            Mock Unregister-Event {}
            Mock Write-Host {}
            $null = Start-SLBackgroundUpdateCheck -Options $enabled -State $notChecked
            $startJobCommand = Get-Command Start-Job -CommandType Cmdlet
            $realJob = & $startJobCommand -ScriptBlock { }
            $null = Wait-Job -Job $realJob -Timeout 15
            $script:SLUpdateJobState.Job = $realJob
            $event = [pscustomobject]@{ MessageData = $script:SLUpdateJobState }
            $eventSubscriber = [pscustomobject]@{ SourceIdentifier = 'SecondLine.UpdateCheck.test' }
            try { & $script:HelpCompletionAction } finally { & (Get-Command Remove-Job -CommandType Cmdlet) -Job $realJob -Force }
            $script:SLUpdateJobState.Job | Should -BeNullOrEmpty
            Should -Invoke Write-Host -Times 1 -ParameterFilter { $Object -eq 'SecondLine 99.0.0 available; installed 0.3.0.' }
            Should -Invoke Remove-Job -Times 1
            Should -Invoke Unregister-Event -Times 1
        }
        It 'stays quiet when the completed lookup has nothing new to say' {
            Mock Register-ObjectEvent { $script:HelpCompletionAction = $Action }
            Mock Receive-Job { [pscustomobject]@{ Notice = $null } }
            Mock Unregister-Event {}
            Mock Write-Host {}
            $null = Start-SLBackgroundUpdateCheck -Options $enabled -State $notChecked
            $realJob = & (Get-Command Start-Job -CommandType Cmdlet) -ScriptBlock { }
            $null = Wait-Job -Job $realJob -Timeout 15
            $script:SLUpdateJobState.Job = $realJob
            $event = [pscustomobject]@{ MessageData = $script:SLUpdateJobState }
            $eventSubscriber = [pscustomobject]@{ SourceIdentifier = 'SecondLine.UpdateCheck.test' }
            try { & $script:HelpCompletionAction } finally { & (Get-Command Remove-Job -CommandType Cmdlet) -Job $realJob -Force }
            Should -Invoke Write-Host -Times 0
        }
    }
}
