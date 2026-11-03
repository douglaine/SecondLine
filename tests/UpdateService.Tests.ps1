#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# The shared update service, its settings, and opt-in profile integration.
# Remote lookups are always mocked. Profiles are temporary files in TestDrive; the
# real $PROFILE is never read or written.

BeforeDiscovery {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'SecondLine\SecondLine.psd1') -Force
}
BeforeAll {
    $script:manifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'SecondLine\SecondLine.psd1'
    Import-Module $script:manifest -Force
    $script:savedEnv = @{}
    $script:envNames = 'SECONDLINE_CACHE_DIR', 'SECONDLINE_NO_UPDATE_CHECK', 'CI', 'GITHUB_ACTIONS', 'TF_BUILD', 'SECONDLINE_STANDARD', 'SECONDLINE_USER_SETTINGS', 'SECONDLINE_MACHINE_SETTINGS', 'SECONDLINE_NO_HOST_SETTINGS'
    foreach ($name in $script:envNames) { $script:savedEnv[$name] = [Environment]::GetEnvironmentVariable($name) }
    $script:realProfile = $PROFILE
    $script:realProfileStamp = @()
    foreach ($p in @($PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost)) {
        if ($p -and (Test-Path -LiteralPath $p)) { $script:realProfileStamp += (Get-FileHash -LiteralPath $p).Hash } else { $script:realProfileStamp += 'absent' }
    }
}
AfterAll {
    foreach ($name in $script:savedEnv.Keys) { [Environment]::SetEnvironmentVariable($name, $script:savedEnv[$name]) }
}

Describe 'Shared update cache' {
    InModuleScope SecondLine {
        BeforeEach {
            foreach ($name in 'SECONDLINE_NO_UPDATE_CHECK', 'CI', 'GITHUB_ACTIONS', 'TF_BUILD', 'SECONDLINE_STANDARD', 'SECONDLINE_NO_HOST_SETTINGS') { [Environment]::SetEnvironmentVariable($name, $null) }
            $env:SECONDLINE_CACHE_DIR = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $env:SECONDLINE_USER_SETTINGS = Join-Path $TestDrive 'absent-user.psd1'
            $env:SECONDLINE_MACHINE_SETTINGS = Join-Path $TestDrive 'absent-machine.psd1'
            Mock Get-SLInstalledVersion { '0.4.0' }
            $script:opts = $script:SLUpdateDefaults.Clone()
        }
        It 'writes the cache atomically, leaving no temporary files' {
            Mock Get-SLGalleryVersion { '0.4.1' }
            $null = Update-SLUpdateCache -Options $opts
            $files = @(Get-ChildItem -LiteralPath $env:SECONDLINE_CACHE_DIR -Force | ForEach-Object Name | Sort-Object)
            $files | Should -Be @('next-check.txt', 'update-cache.json')
            [long] (Get-Content (Join-Path $env:SECONDLINE_CACHE_DIR 'next-check.txt') -Raw) | Should -BeGreaterThan ([DateTime]::UtcNow.AddHours(23).Ticks)
        }
        It 'treats a corrupt cache as empty and repairs it' {
            New-Item -ItemType Directory -Path $env:SECONDLINE_CACHE_DIR -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $env:SECONDLINE_CACHE_DIR 'update-cache.json') -Value '{ not json'
            (Get-SLCachedUpdateState -Options $opts).Lookup | Should -Be NotChecked
            Mock Get-SLGalleryVersion { '0.4.0' }
            (Update-SLUpdateCache -Options $opts).Lookup | Should -Be Current
        }
        It 'skips the lookup while another session holds the lock, and reports it' {
            Mock Get-SLGalleryVersion { '0.4.1' }
            $held = Enter-SLUpdateLock
            try {
                $held | Should -Not -BeNullOrEmpty
                Enter-SLUpdateLock | Should -BeNullOrEmpty
                $state = Update-SLUpdateCache -Options $opts
                $state.Busy | Should -BeTrue
                $state.Ran | Should -BeFalse
                Format-SLUpdateLine -State $state | Should -Match 'Another session is checking'
            }
            finally { $held.Dispose() }
            Should -Invoke Get-SLGalleryVersion -Times 0
            Test-Path (Join-Path $env:SECONDLINE_CACHE_DIR 'update-cache.lock') | Should -BeFalse
        }
        It 'takes over a lock left behind by a process that died' {
            New-Item -ItemType Directory -Path $env:SECONDLINE_CACHE_DIR -Force | Out-Null
            $lockFile = Join-Path $env:SECONDLINE_CACHE_DIR 'update-cache.lock'
            Set-Content -LiteralPath $lockFile -Value 'stale'
            (Get-Item $lockFile).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-10)
            $lock = Enter-SLUpdateLock
            try { $lock | Should -Not -BeNullOrEmpty } finally { if ($lock) { $lock.Dispose() } }
        }
        It 'shares one cache across module reloads (new sessions) without another request' {
            Mock Get-SLGalleryVersion { '0.4.1' }
            $null = Update-SLUpdateCache -Options $opts
            $cacheDir = $env:SECONDLINE_CACHE_DIR
            # A child process is a separate session; it must read the cache, never the network.
            $exe = (Get-Process -Id $PID).Path
            $script = Join-Path $TestDrive 'other-session.ps1'
            Set-Content -LiteralPath $script -Value @(
                'param($Manifest, $CacheDir)'
                '$env:SECONDLINE_CACHE_DIR = $CacheDir'
                '$m = Import-Module $Manifest -Force -PassThru'
                '& $m {'
                '    Set-Item function:script:Get-SLGalleryVersion { throw "network" }'
                '    Set-Item function:script:Get-SLInstalledVersion { "0.4.0" }'
                '    $s = Update-SLUpdateCache -Options $script:SLUpdateDefaults.Clone()'
                '    "$($s.Ran)|$($s.Latest)|$($s.Lookup)"'
                '}'
            )
            $out = & { $ErrorActionPreference = 'Continue'; & $exe -NoProfile -NonInteractive -File $script (Join-Path (Get-Module SecondLine).ModuleBase 'SecondLine.psd1') $cacheDir 2>&1 } | ForEach-Object { "$_" }
            ($out | Select-Object -Last 1) | Should -Be 'False|0.4.1|Current'
        }
        It 'distinguishes an offline failure from up to date and backs off without retrying' {
            Mock Get-SLGalleryVersion { throw 'No such host is known.' }
            $first = Update-SLUpdateCache -Options $opts
            $second = Update-SLUpdateCache -Options $opts
            $first.Lookup | Should -Be Failed
            $first.Update | Should -Be Unknown
            $first.LastError | Should -Match 'No such host'
            $second.Ran | Should -BeFalse
            Should -Invoke Get-SLGalleryVersion -Times 1
            $first.NextDueUtc | Should -BeGreaterThan ([DateTime]::UtcNow.AddMinutes(50))
        }
        It 'keeps the last good answer when a later lookup fails' {
            Mock Get-SLGalleryVersion { '0.4.1' }
            $null = Update-SLUpdateCache -Options $opts
            Mock Get-SLGalleryVersion { throw 'timeout' }
            $state = Update-SLUpdateCache -Options $opts -Force
            $state.Lookup | Should -Be Failed
            $state.Latest | Should -Be '0.4.1'
            Format-SLUpdateLine -State $state | Should -Match '^SecondLine 0.4.1 available; installed 0.4.0\. Gallery lookup failed'
        }
        It 'refreshes a stale entry after RefreshHours' {
            Mock Get-SLGalleryVersion { '0.4.0' }
            $null = Update-SLUpdateCache -Options $opts
            $cache = Read-SLUpdateCache
            $old = [DateTime]::UtcNow.AddHours(-30).Ticks
            $entry = $cache.Entries.'PSGallery/SecondLine/stable'
            $entry.CheckedTicks = $old; $entry.AttemptTicks = $old; $entry.NextCheckTicks = $old
            Write-SLUpdateCache -Cache $cache
            (Get-SLCachedUpdateState -Options $opts).Lookup | Should -Be Stale
            (Update-SLUpdateCache -Options $opts).Ran | Should -BeTrue
        }
        It 'shows an actionable notice once, then again only for a new version' {
            Mock Get-SLGalleryVersion { '0.4.1' }
            (Update-SLUpdateCache -Options $opts).Notice | Should -Be 'SecondLine 0.4.1 available; installed 0.4.0.'
            (Update-SLUpdateCache -Options $opts -Force).Notice | Should -BeNullOrEmpty
            Mock Get-SLGalleryVersion { '0.4.2' }
            (Update-SLUpdateCache -Options $opts -Force).Notice | Should -Be 'SecondLine 0.4.2 available; installed 0.4.0.'
        }
        It 'says what it knows when SecondLine is not installed for this PowerShell' {
            Mock Get-SLGalleryVersion { '0.4.1' }
            Mock Get-SLInstalledVersion { $null }
            $state = Update-SLUpdateCache -Options $opts
            $state.Update | Should -Be Unknown
            $state.Message | Should -Be 'Newest stable SecondLine is 0.4.1; no installed SecondLine found to compare.'
            $state.Notice | Should -BeNullOrEmpty
        }
        It 'gives no notice when nothing is actionable' {
            Mock Get-SLGalleryVersion { '0.4.0' }
            (Update-SLUpdateCache -Options $opts).Notice | Should -BeNullOrEmpty
        }
        It 'leaves the notice for the next shell with -NoticeFile' {
            Mock Get-SLGalleryVersion { '0.4.1' }
            $null = Update-SLUpdateCache -Options $opts -NoticeFile
            Get-Content (Join-Path $env:SECONDLINE_CACHE_DIR 'notice.txt') -Raw | Should -Be 'SecondLine 0.4.1 available; installed 0.4.0.'
        }
        It 'makes no request when checks are disabled, and pushes the next profile check out' {
            Mock Get-SLGalleryVersion { throw 'network' }
            $opts.Enabled = $false
            $state = Update-SLUpdateCache -Options $opts
            $state.Lookup | Should -Be Disabled
            $state.Ran | Should -BeFalse
            [long] (Get-Content (Join-Path $env:SECONDLINE_CACHE_DIR 'next-check.txt') -Raw) | Should -BeGreaterThan ([DateTime]::UtcNow.Ticks)
            Should -Invoke Get-SLGalleryVersion -Times 0
        }
        It 'bounds retries and waits briefly between them' {
            Mock Invoke-SLGalleryRequest { throw 'timeout' }
            Mock Start-Sleep {}
            { Get-SLGalleryVersion -Retries 2 -TimeoutSeconds 1 } | Should -Throw '*after 3 attempt(s)*'
            Should -Invoke Invoke-SLGalleryRequest -Times 3 -Exactly
            Should -Invoke Start-Sleep -Times 2 -Exactly
        }
        It 'rejects module names that would change the query' {
            { Get-SLGalleryVersion -Name "x'or'1" } | Should -Throw '*Invalid module name*'
        }
        It 'reads stable versions only by default, and refuses DTDs' {
            $feed = '<feed xmlns:m="m" xmlns:d="d"><entry><m:properties><d:Version>0.4.0</d:Version></m:properties></entry>' +
            '<entry><m:properties><d:Version>0.5.0-beta1</d:Version></m:properties></entry>' +
            '<entry><m:properties><d:Version>0.3.9</d:Version></m:properties></entry></feed>'
            Select-SLGalleryFeedVersion -Xml $feed | Should -Be '0.4.0'
            Select-SLGalleryFeedVersion -Xml $feed -IncludePrerelease | Should -Be '0.5.0-beta1'
            { Select-SLGalleryFeedVersion -Xml '<!DOCTYPE x [<!ENTITY e "boom">]><feed>&e;</feed>' } | Should -Throw
        }
        It 'prints one concise line from Invoke-SLUpdateCheck' {
            Mock Get-SLGalleryVersion { '0.4.1' }
            Mock Write-Host {}
            Invoke-SLUpdateCheck -Path $TestDrive
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -like 'SecondLine 0.4.1 available; installed 0.4.0. (checked*' }
        }
        It 'Get-SLUpdateStatus keeps update, policy and advisory separate and never uses the network' {
            Mock Get-SLGalleryVersion { throw 'network' }
            $health = Get-SLUpdateStatus -Path $TestDrive
            $health.Lookup | Should -Be NotChecked
            $health.Update | Should -Be Unknown
            $health.Advisory | Should -Be NotConfigured
            $health.Policy | Should -BeIn @('NotPinned', 'Match', 'Mismatch', 'NotInstalled')
            Should -Invoke Get-SLGalleryVersion -Times 0
        }
        It 'reports a version-policy mismatch between the loaded and the approved version' {
            $project = Join-Path $TestDrive 'policy-project'
            New-Item -ItemType Directory -Path $project -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $project 'secondline.standard.psd1') -Value "@{ ModuleVersions = @{ SecondLine = '9.9.9' } }"
            $state = Get-SLCachedUpdateState -Options $opts
            $health = Get-SLDependencyHealth -State $state -Directory $project -Loaded '0.4.0'
            $health.Policy | Should -Be NotInstalled
            $health.Approved | Should -Be '9.9.9'
            $health.Notices | Should -Contain $health.PolicyNote
        }
    }
}

Describe 'Update settings precedence' {
    InModuleScope SecondLine {
        BeforeEach {
            foreach ($name in 'SECONDLINE_NO_UPDATE_CHECK', 'CI', 'GITHUB_ACTIONS', 'TF_BUILD', 'SECONDLINE_STANDARD', 'SECONDLINE_NO_HOST_SETTINGS') { [Environment]::SetEnvironmentVariable($name, $null) }
            $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $root | Out-Null
            $env:SECONDLINE_USER_SETTINGS = Join-Path $root 'user.psd1'
            $env:SECONDLINE_MACHINE_SETTINGS = Join-Path $root 'machine.psd1'
        }
        It 'uses defaults < project < machine < user, with sources' {
            Set-Content (Join-Path $root 'secondline.standard.psd1') "@{ Updates = @{ RefreshHours = 12; Retries = 0; TimeoutSeconds = 5 } }"
            Set-Content $env:SECONDLINE_MACHINE_SETTINGS "@{ Updates = @{ RefreshHours = 6; Retries = 2 } }"
            Set-Content $env:SECONDLINE_USER_SETTINGS "@{ Updates = @{ RefreshHours = 48 } }"
            $s = Get-SLUpdateSettings -Directory $root
            $s.RefreshHours.Value | Should -Be 48
            $s.RefreshHours.Source | Should -BeLike 'user *'
            @($s.RefreshHours.Overridden).Count | Should -Be 3
            $s.Retries.Value | Should -Be 2
            $s.Retries.Source | Should -BeLike 'machine *'
            $s.TimeoutSeconds.Value | Should -Be 5
            $s.TimeoutSeconds.Source | Should -BeLike 'project *'
            $s.FailureBackoffMinutes.Source | Should -Be 'default'
        }
        It 'turns checks off in CI and with SECONDLINE_NO_UPDATE_CHECK, whatever the files say' {
            Set-Content $env:SECONDLINE_USER_SETTINGS "@{ Updates = @{ Enabled = `$true } }"
            $env:GITHUB_ACTIONS = 'true'
            (Get-SLUpdateSettings -Directory $root).Enabled.Value | Should -BeFalse
            $env:GITHUB_ACTIONS = $null
            $env:SECONDLINE_NO_UPDATE_CHECK = '1'
            $s = Get-SLUpdateSettings -Directory $root
            $s.Enabled.Value | Should -BeFalse
            $s.Enabled.Source | Should -Be 'SECONDLINE_NO_UPDATE_CHECK=1'
        }
        It 'rejects out-of-range or unknown settings, naming the file' {
            Set-Content $env:SECONDLINE_USER_SETTINGS "@{ Updates = @{ TimeoutSeconds = 600 } }"
            { Get-SLUpdateSettings -Directory $root } | Should -Throw '*TimeoutSeconds must be a whole number from 1 to 30*'
            Set-Content $env:SECONDLINE_USER_SETTINGS "@{ Updates = @{ Repository = 'Other' } }"
            { Get-SLUpdateSettings -Directory $root } | Should -Throw "*unknown key 'Repository'*"
        }
        It 'never lets update preferences change the approved version' {
            Set-Content (Join-Path $root 'secondline.standard.psd1') "@{ ModuleVersions = @{ SecondLine = '0.4.0' } }"
            Set-Content $env:SECONDLINE_USER_SETTINGS "@{ Updates = @{ IncludePrerelease = `$true }; ModuleVersions = @{ SecondLine = '0.5.0' } }"
            $policy = Resolve-SLModuleVersionPolicy -Directory $root
            $policy.SecondLine.Value | Should -Be '0.4.0'
            $policy.SecondLine.Overridden[0].Value | Should -Be '0.5.0'
        }
    }
}

Describe 'Profile integration' {
    BeforeAll {
        $script:module = Get-Module SecondLine
        $script:blockLines = & $script:module { Get-SLProfileBlock }
    }
    BeforeEach {
        Mock -ModuleName SecondLine Write-Host {}
        $script:profilePath = Join-Path $TestDrive "profile-$([guid]::NewGuid().ToString('N')).ps1"
    }
    It 'requires an explicit -Path, so a real profile is never assumed' {
        (Get-Command Enable-SLProfileUpdateCheck).Parameters['Path'].Attributes.Mandatory | Should -Contain $true
        (Get-Command Disable-SLProfileUpdateCheck).Parameters['Path'].Attributes.Mandatory | Should -Contain $true
    }
    It 'adds one marked block, keeps other bytes, encoding and endings, and removes it cleanly' {
        $utf8Bom = New-Object Text.UTF8Encoding($true)
        $original = "# my profile`r`nSet-Alias ll Get-ChildItem`r`n`$greeting = 'Gr$([char]0xFC)$([char]0xDF)e'`r`n"
        [IO.File]::WriteAllText($profilePath, $original, $utf8Bom)
        $before = [IO.File]::ReadAllBytes($profilePath)

        (Enable-SLProfileUpdateCheck -Path $profilePath -PassThru).Action | Should -Be Added
        $after = [IO.File]::ReadAllBytes($profilePath)
        $after[0..($before.Length - 1)] | Should -Be $before
        $text = [IO.File]::ReadAllText($profilePath)
        ([regex]::Matches($text, [regex]::Escape('# >>> SecondLine update check >>>'))).Count | Should -Be 1
        ([regex]::Matches($text, "(?<!`r)`n")).Count | Should -Be 0

        (Enable-SLProfileUpdateCheck -Path $profilePath -PassThru).Action | Should -Be Unchanged
        ([regex]::Matches([IO.File]::ReadAllText($profilePath), [regex]::Escape('# >>> SecondLine update check >>>'))).Count | Should -Be 1

        (Disable-SLProfileUpdateCheck -Path $profilePath -PassThru).Action | Should -Be Removed
        [IO.File]::ReadAllBytes($profilePath) | Should -Be $before
    }
    It 'preserves a UTF-16 profile' {
        [IO.File]::WriteAllText($profilePath, "Write-Output '$([char]0xE9)'`r`n", [Text.Encoding]::Unicode)
        $before = [IO.File]::ReadAllBytes($profilePath)
        $null = Enable-SLProfileUpdateCheck -Path $profilePath
        [IO.File]::ReadAllText($profilePath) | Should -Match 'SecondLine update check'
        $null = Disable-SLProfileUpdateCheck -Path $profilePath
        [IO.File]::ReadAllBytes($profilePath) | Should -Be $before
    }
    It 'creates a missing profile, and appends after content without a final newline' {
        $null = Enable-SLProfileUpdateCheck -Path $profilePath
        Test-Path $profilePath | Should -BeTrue
        $other = Join-Path $TestDrive 'nofinal.ps1'
        [IO.File]::WriteAllText($other, "Write-Output 'last line'")
        $null = Enable-SLProfileUpdateCheck -Path $other
        [IO.File]::ReadAllText($other) | Should -Match "(?m)^Write-Output 'last line'\r?\n# >>> SecondLine update check >>>"
    }
    It 'previews with -WhatIf and changes nothing' {
        [IO.File]::WriteAllText($profilePath, "# keep`n")
        $before = [IO.File]::ReadAllBytes($profilePath)
        $null = Enable-SLProfileUpdateCheck -Path $profilePath -WhatIf
        [IO.File]::ReadAllBytes($profilePath) | Should -Be $before
        $null = Enable-SLProfileUpdateCheck -Path $profilePath
        $withBlock = [IO.File]::ReadAllBytes($profilePath)
        $null = Disable-SLProfileUpdateCheck -Path $profilePath -WhatIf
        [IO.File]::ReadAllBytes($profilePath) | Should -Be $withBlock
    }
    It 'replaces an outdated block in place and collapses duplicates' {
        $old = "# a`n# >>> SecondLine update check >>>`nold`n# <<< SecondLine update check <<<`n# b`n# >>> SecondLine update check >>>`nold2`n# <<< SecondLine update check <<<`n"
        [IO.File]::WriteAllText($profilePath, $old)
        (Enable-SLProfileUpdateCheck -Path $profilePath -PassThru).Action | Should -Be Updated
        $text = [IO.File]::ReadAllText($profilePath)
        ([regex]::Matches($text, '>>> SecondLine update check >>>')).Count | Should -Be 1
        $text | Should -Match "^# a`n# >>> SecondLine update check >>>"
        $text | Should -Match "# <<< SecondLine update check <<<`n# b`n$"
        $text | Should -Not -Match '(?m)^old2?$'
    }
    It 'refuses a block without an end marker and changes nothing' {
        [IO.File]::WriteAllText($profilePath, "# >>> SecondLine update check >>>`nhalf`n")
        $before = [IO.File]::ReadAllBytes($profilePath)
        { Enable-SLProfileUpdateCheck -Path $profilePath } | Should -Throw '*no end marker*'
        { Disable-SLProfileUpdateCheck -Path $profilePath } | Should -Throw '*no end marker*'
        [IO.File]::ReadAllBytes($profilePath) | Should -Be $before
    }
    It 'reports NotPresent when there is nothing to remove' {
        [IO.File]::WriteAllText($profilePath, "# only mine`n")
        (Disable-SLProfileUpdateCheck -Path $profilePath -PassThru).Action | Should -Be NotPresent
    }
    It 'is valid PowerShell that imports nothing and only runs in interactive shells' {
        $text = $blockLines -join "`n"
        $errors = $null
        [void] [Management.Automation.Language.Parser]::ParseInput($text, [ref] $null, [ref] $errors)
        $errors | Should -BeNullOrEmpty
        $text | Should -Not -Match '(?m)^\s*Import-Module'
        $text | Should -Match 'UserInteractive'
        $text | Should -Match 'NonI'
        $text | Should -Match 'SECONDLINE_NO_UPDATE_CHECK'
    }
    It 'shows a pending notice once and starts no check while the cache is current' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        Set-Content (Join-Path $dir 'notice.txt') 'SecondLine 0.4.1 available; installed 0.4.0.'
        Set-Content (Join-Path $dir 'next-check.txt') ([DateTime]::UtcNow.AddHours(5).Ticks)
        $saved = $env:SECONDLINE_CACHE_DIR
        $env:SECONDLINE_CACHE_DIR = $dir
        try {
            # The guard depends on how the test host was started; exercise the body.
            $body = ($blockLines -join "`n") -replace '(?m)^if \(\[Environment\]::UserInteractive.*\{$', 'if ($true) {'
            Mock Write-Host {}
            Mock Start-Process {}
            & ([scriptblock]::Create($body))
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -eq 'SecondLine 0.4.1 available; installed 0.4.0.' }
            Should -Invoke Start-Process -Times 0
            Test-Path (Join-Path $dir 'notice.txt') | Should -BeFalse
            & ([scriptblock]::Create($body))
            Should -Invoke Write-Host -Times 1 -Exactly
        }
        finally { $env:SECONDLINE_CACHE_DIR = $saved }
    }
    It 'starts one hidden no-profile check when due, without waiting' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        $saved = $env:SECONDLINE_CACHE_DIR
        $env:SECONDLINE_CACHE_DIR = $dir
        try {
            $body = ($blockLines -join "`n") -replace '(?m)^if \(\[Environment\]::UserInteractive.*\{$', 'if ($true) {'
            Mock Start-Process {}
            & ([scriptblock]::Create($body))
            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
                $WindowStyle -eq 'Hidden' -and $ArgumentList -contains '-NoProfile' -and ($ArgumentList -join ' ') -match 'Invoke-SLUpdateCheck -NoticeFile -Quiet' -and -not $Wait
            }
        }
        finally { $env:SECONDLINE_CACHE_DIR = $saved }
    }
    It 'never touched the real profile' {
        $now = @()
        foreach ($p in @($script:realProfile.CurrentUserAllHosts, $script:realProfile.CurrentUserCurrentHost)) {
            if ($p -and (Test-Path -LiteralPath $p)) { $now += (Get-FileHash -LiteralPath $p).Hash } else { $now += 'absent' }
        }
        $now | Should -Be $script:realProfileStamp
    }
}
