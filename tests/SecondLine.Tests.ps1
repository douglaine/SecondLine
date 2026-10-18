#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo 'SecondLine\SecondLine.psd1') -Force

    # Writes a standard file to TestDrive and returns its path.
    function New-TestStandard([string] $Body) {
        $p = Join-Path $TestDrive ("std-{0}.psd1" -f [guid]::NewGuid().ToString('N'))
        Set-Content -LiteralPath $p -Value $Body -Encoding UTF8
        return $p
    }
}

Describe 'Version rules' {
    InModuleScope SecondLine {
        It '<Rule>: <Found> vs <Expect> -> <Pass>' -TestCases @(
            @{ Rule = 'Exact';   Found = '8.0.34'; Expect = '8.0.34'; Pass = $true  }
            @{ Rule = 'Exact';   Found = '8.0.12'; Expect = '8.0.34'; Pass = $false }
            @{ Rule = 'Exact';   Found = '8.0.12'; Expect = '8.0';    Pass = $true  }
            @{ Rule = 'Exact';   Found = '8.0';    Expect = '8.0.34'; Pass = $false }
            @{ Rule = 'Minor';   Found = '8.0.12'; Expect = '8.0';    Pass = $true  }
            @{ Rule = 'Minor';   Found = '8.2.3';  Expect = '8.0';    Pass = $false }
            @{ Rule = 'Minor';   Found = '8.0.1';  Expect = '8.0.34'; Pass = $true  }
            @{ Rule = 'Major';   Found = '2.13.0'; Expect = '2';      Pass = $true  }
            @{ Rule = 'Major';   Found = '3.0.0';  Expect = '2.13';   Pass = $false }
            @{ Rule = 'Minimum'; Found = '2.45.1'; Expect = '2.40';   Pass = $true  }
            @{ Rule = 'Minimum'; Found = '2.40';   Expect = '2.40.0'; Pass = $true  }
            @{ Rule = 'Minimum'; Found = '2.9.9';  Expect = '2.40';   Pass = $false }
            @{ Rule = 'Minimum'; Found = '10.0.1'; Expect = '9.9';    Pass = $true  }
        ) {
            param($Rule, $Found, $Expect, $Pass)
            Test-SLVersionRule -Found $Found -Expect $Expect -Rule $Rule | Should -Be $Pass
        }

        It 'compares numerically, not as text (10 > 9)' {
            Compare-SLVersionParts @(10, 0) @(9, 9) | Should -Be 1
        }

        It 'rejects a non-numeric version' {
            Test-SLVersionRule -Found 'abc' -Expect '1.0' -Rule 'Minimum' | Should -BeFalse
        }

        It 'throws on an unknown rule' {
            { Test-SLVersionRule -Found '1.0' -Expect '1.0' -Rule 'Bogus' } | Should -Throw '*Unknown rule*'
        }
    }
}

Describe 'Version text extraction' {
    InModuleScope SecondLine {
        It 'finds a version in typical --version output' {
            Get-SLVersionText -Text 'git version 2.45.1.windows.1' | Should -Be '2.45.1'
        }
        It 'uses a (?<version>) group when the pattern has one' {
            $out = "db version v8.0.34`nBuild Info: {...}"
            Get-SLVersionText -Text $out -Pattern 'db version v(?<version>\d+\.\d+\.\d+)' | Should -Be '8.0.34'
        }
        It 'returns null when nothing looks like a version' {
            Get-SLVersionText -Text 'no numbers here' | Should -BeNullOrEmpty
        }
        It 'keeps a prerelease tag instead of reporting a preview as a release' {
            Get-SLVersionText -Text '11.0.100-rc.2.26504.105' | Should -Be '11.0.100-rc.2.26504.105'
            Test-SLPrerelease '11.0.100-rc.2.26504.105' | Should -BeTrue
            Test-SLPrerelease '10.0.401' | Should -BeFalse
        }
        It 'compares a prerelease by its numbers' {
            Test-SLVersionRule -Found '11.0.100-rc.2' -Expect '10.0' -Rule 'Minor' | Should -BeFalse
            Test-SLVersionRule -Found '11.0.100-rc.2' -Expect '11.0' -Rule 'Minor' | Should -BeTrue
        }
        It 'reads every version from a list' {
            $list = "8.0.414 [C:\sdk]`n10.0.103 [C:\sdk]`n10.0.401 [C:\sdk]`n11.0.100-rc.2.26504.105 [C:\sdk]"
            (Get-SLVersionTexts -Text $list) -join ',' | Should -Be '8.0.414,10.0.103,10.0.401,11.0.100-rc.2.26504.105'
        }
        It 'picks the highest release over a newer prerelease' {
            Select-SLBestVersion @('10.0.103', '11.0.100-rc.2', '10.0.401') | Should -Be '10.0.401'
            Select-SLBestVersion @('11.0.100-rc.1', '11.0.100-rc.2') | Should -Be '11.0.100-rc.2'
        }
    }
}

Describe 'Get-SecondLineStandard' {
    It 'loads a valid standard and fills defaults' {
        $p = New-TestStandard @'
@{
    Name = 'T'
    Version = '1.2.3'
    Tools = @(
        @{ Name = 'git'; Command = 'git'; Expect = '2.40'; Rule = 'Minimum' }
    )
}
'@
        $s = Get-SecondLineStandard -Path $p
        $s.Name | Should -Be 'T'
        $s.Version | Should -Be '1.2.3'
        $s.Tools.Count | Should -Be 1
        $s.Tools[0].Arguments | Should -Be '--version'
        $s.Tools[0].TimeoutSeconds | Should -Be 15
    }

    It 'reports every problem at once' {
        $p = New-TestStandard @'
@{
    Tools = @(
        @{ Name = 'a'; Command = 'a'; Expect = 'x.y'; Rule = 'Minimum' }
        @{ Name = 'b'; Expect = '1.0'; Rule = 'Sometimes' }
    )
}
'@
        $err = $null
        try { Get-SecondLineStandard -Path $p } catch { $err = $_.Exception.Message }
        $err | Should -Match "not a version number"
        $err | Should -Match "missing 'Command'"
        $err | Should -Match "Rule 'Sometimes'"
    }

    It 'throws a helpful message when the file is missing' {
        { Get-SecondLineStandard -Path (Join-Path $TestDrive 'nope.psd1') } | Should -Throw '*not found*'
    }

    It 'falls back to SECONDLINE_STANDARD' {
        $p = New-TestStandard "@{ Tools = @( @{ Name='g'; Command='g'; Expect='1'; Rule='Major' } ) }"
        $old = $env:SECONDLINE_STANDARD
        try {
            $env:SECONDLINE_STANDARD = $p
            (Get-SecondLineStandard).Path | Should -Be (Resolve-Path $p).ProviderPath
        }
        finally { $env:SECONDLINE_STANDARD = $old }
    }

    It 'accepts the shipped example' {
        $example = Join-Path (Split-Path $PSScriptRoot -Parent) 'examples\secondline.standard.psd1'
        { Get-SecondLineStandard -Path $example } | Should -Not -Throw
    }
}

Describe 'Test-SecondLine' {
    BeforeAll {
        # A real executable that is on every machine running these tests.
        $pwshPath = (Get-Process -Id $PID).Path
        $self     = $PSVersionTable.PSVersion
        $tool     = [IO.Path]::GetFileNameWithoutExtension($pwshPath)
        $args5    = "-NoProfile -Command `$PSVersionTable.PSVersion.ToString()"
    }

    It 'reports OK for a tool at the expected version' {
        $p = New-TestStandard @"
@{ Tools = @( @{ Name='shell'; Command='$tool'; Arguments='$args5'; Expect='$($self.Major).$($self.Minor)'; Rule='Minor' } ) }
"@
        $r = Test-SecondLine -Path $p -PassThru -Quiet
        $r.Status | Should -Be 'OK'
        $r.Found  | Should -Match "^$($self.Major)\.$($self.Minor)"
    }

    It 'reports MISMATCH when the rule fails' {
        $p = New-TestStandard @"
@{ Tools = @( @{ Name='shell'; Command='$tool'; Arguments='$args5'; Expect='99.0'; Rule='Minimum'; Install='get a newer one' } ) }
"@
        $r = Test-SecondLine -Path $p -PassThru -Quiet
        $r.Status  | Should -Be 'MISMATCH'
        $r.Install | Should -Be 'get a newer one'
    }

    It 'reports MISSING for a tool not on PATH' {
        $p = New-TestStandard "@{ Tools = @( @{ Name='ghost'; Command='secondline-no-such-tool'; Expect='1.0'; Rule='Minimum' } ) }"
        (Test-SecondLine -Path $p -PassThru -Quiet).Status | Should -Be 'MISSING'
    }

    It 'reports UNKNOWN when no version is in the output' {
        $p = New-TestStandard @"
@{ Tools = @( @{ Name='shell'; Command='$tool'; Arguments='-NoProfile -Command "Write-Output hello"'; Expect='1.0'; Rule='Minimum' } ) }
"@
        (Test-SecondLine -Path $p -PassThru -Quiet).Status | Should -Be 'UNKNOWN'
    }

    It 'stops a tool that does not exit, and says so' {
        $p = New-TestStandard @"
@{ Tools = @( @{ Name='hang'; Command='$tool'; Arguments='-NoProfile -Command "Write-Output 1.2.3; Start-Sleep 30"'; Expect='1.2'; Rule='Minor'; TimeoutSeconds=3 } ) }
"@
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Test-SecondLine -Path $p -PassThru -Quiet
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 15
        $r.Note | Should -Match 'did not exit'
    }

    It 'Match = Any passes if any listed version satisfies the rule' {
        $p = New-TestStandard @"
@{ Tools = @( @{ Name='sdks'; Command='$tool'; Arguments='-NoProfile -Command "''8.0.414 [x]'',''10.0.401 [x]'',''11.0.100-rc.2 [x]''"'; Match='Any'; Expect='10.0'; Rule='Minor' } ) }
"@
        $r = Test-SecondLine -Path $p -PassThru -Quiet
        $r.Status | Should -Be 'OK'
        $r.Found  | Should -Be '10.0.401'
        $r.Note   | Should -Match 'installed: 8.0.414, 10.0.401, 11.0.100-rc.2'
    }

    It 'flags a prerelease in the report' {
        $p = New-TestStandard @"
@{ Tools = @( @{ Name='pre'; Command='$tool'; Arguments='-NoProfile -Command "''11.0.100-rc.2''"'; Expect='11.0'; Rule='Minor' } ) }
"@
        $r = Test-SecondLine -Path $p -PassThru -Quiet
        $r.Found | Should -Be '11.0.100-rc.2'
        $r.Note  | Should -Match 'prerelease'
    }

    It 'rejects an unknown Match value' {
        $p = New-TestStandard "@{ Tools = @( @{ Name='x'; Command='x'; Expect='1.0'; Rule='Minimum'; Match='Some' } ) }"
        { Get-SecondLineStandard -Path $p } | Should -Throw "*Match 'Some'*"
    }

    It '-Strict throws when anything is not OK' {
        $p = New-TestStandard "@{ Tools = @( @{ Name='ghost'; Command='secondline-no-such-tool'; Expect='1.0'; Rule='Minimum' } ) }"
        { Test-SecondLine -Path $p -Quiet -Strict } | Should -Throw '*not OK*'
    }
}
