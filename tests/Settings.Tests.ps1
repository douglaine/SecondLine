#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# Layered settings, approved module versions and the pre-import bootstrap.
# Bootstrap runs happen in child processes with a module path made only of
# synthetic modules in TestDrive, so the machine's installed modules don't matter.

BeforeDiscovery {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'SecondLine\SecondLine.psd1') -Force
}
BeforeAll {
    $script:repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:repoRoot 'SecondLine\SecondLine.psd1') -Force
    $script:bootstrap = Join-Path $script:repoRoot 'SecondLine\Bootstrap\Import-SecondLine.ps1'
    $script:savedEnv = @{}
    $script:envNames = 'CI', 'GITHUB_ACTIONS', 'TF_BUILD', 'SECONDLINE_STANDARD', 'SECONDLINE_USER_SETTINGS', 'SECONDLINE_MACHINE_SETTINGS', 'SECONDLINE_NO_HOST_SETTINGS'
    foreach ($name in $script:envNames) { $script:savedEnv[$name] = [Environment]::GetEnvironmentVariable($name) }

    function Write-Data([string] $Path, [string] $Body) {
        New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
        [IO.File]::WriteAllText($Path, $Body)
        return $Path
    }

    # Synthetic modules: <root>\<Name>\<Version>\<Name>.psd1, each exporting Get-<Name>Version.
    $script:modules = Join-Path $TestDrive 'modules'
    foreach ($v in '1.0.0', '2.0.0') {
        $dir = Join-Path $script:modules "SLFake\$v"
        Write-Data (Join-Path $dir 'SLFake.psm1') "function Get-SLFakeVersion { '$v' }" | Out-Null
        Write-Data (Join-Path $dir 'SLFake.psd1') "@{ RootModule = 'SLFake.psm1'; ModuleVersion = '$v'; GUID = '6f5b6c0e-1111-4c1d-9a55-0000000000aa'; FunctionsToExport = @('Get-SLFakeVersion') }" | Out-Null
    }

    # Runs the bootstrap in a fresh process. Returns the selected version text or 'ERROR: ...'.
    function Invoke-Bootstrap {
        param([string] $Project, [string[]] $Arguments = @(), [hashtable] $Environment = @{}, [string] $Before = '')
        $runner = Join-Path $TestDrive "run-$([guid]::NewGuid().ToString('N')).ps1"
        $envLines = @(foreach ($k in $Environment.Keys) { "`$env:$k = '$($Environment[$k])'" })
        Set-Content -LiteralPath $runner -Value (@(
                'param($Bootstrap, $Modules, $Project)'
                '$env:PSModulePath = $Modules + [IO.Path]::PathSeparator + $env:PSModulePath'
                'foreach ($n in ''CI'', ''GITHUB_ACTIONS'', ''TF_BUILD'', ''SECONDLINE_STANDARD'', ''SECONDLINE_NO_HOST_SETTINGS'') { [Environment]::SetEnvironmentVariable($n, $null) }'
                '$env:SECONDLINE_USER_SETTINGS = Join-Path $Project ''..\absent-user.psd1'''
                '$env:SECONDLINE_MACHINE_SETTINGS = Join-Path $Project ''..\absent-machine.psd1'''
            ) + $envLines + @(
                $Before
                'try {'
                "    `$r = & `$Bootstrap -Path `$Project -PassThru $($Arguments -join ' ')"
                '    "$($r.Version)|$((Get-Module $r.Name).Version)|$($r.Source)"'
                '} catch { "ERROR: $($_.Exception.Message)" }'
            ))
        $exe = (Get-Process -Id $PID).Path
        $out = & { $ErrorActionPreference = 'Continue'; & $exe -NoProfile -NonInteractive -File $runner $script:bootstrap $script:modules $Project 2>&1 } | ForEach-Object { "$_" }
        return ($out | Where-Object { $_ } | Select-Object -Last 1)
    }
}
AfterAll {
    foreach ($name in $script:savedEnv.Keys) { [Environment]::SetEnvironmentVariable($name, $script:savedEnv[$name]) }
}

Describe 'Approved module version policy' {
    BeforeEach {
        foreach ($name in $script:envNames) { [Environment]::SetEnvironmentVariable($name, $null) }
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $env:SECONDLINE_USER_SETTINGS = Join-Path $root 'user.psd1'
        $env:SECONDLINE_MACHINE_SETTINGS = Join-Path $root 'machine.psd1'
    }
    It 'lets the nearest project file win over its parents, and shows the source' {
        Write-Data (Join-Path $root 'secondline.standard.psd1') "@{ ModuleVersions = @{ SecondLine = '0.3.0'; Other = '1.0' } }" | Out-Null
        $child = Write-Data (Join-Path $root 'sub\secondline.standard.psd1') "@{ Extends = '../secondline.standard.psd1'; ModuleVersions = @{ SecondLine = '0.4.0' } }"
        $policy = & (Get-Module SecondLine) { param($d) Resolve-SLModuleVersionPolicy -Directory $d } (Split-Path $child -Parent)
        $policy.SecondLine.Value | Should -Be '0.4.0'
        $policy.SecondLine.Source | Should -Be "project $child"
        $policy.SecondLine.Overridden[0].Value | Should -Be '0.3.0'
        $policy.Other.Value | Should -Be '1.0'
    }
    It 'inherits the parent pin in a subproject that only extends it' {
        $parent = Write-Data (Join-Path $root 'secondline.standard.psd1') "@{ ModuleVersions = @{ SecondLine = '0.4.0' } }"
        Write-Data (Join-Path $root 'sub\secondline.standard.psd1') "@{ Extends = '../secondline.standard.psd1'; Name = 'Sub' }" | Out-Null
        $policy = & (Get-Module SecondLine) { param($d) Resolve-SLModuleVersionPolicy -Directory $d } (Join-Path $root 'sub')
        $policy.SecondLine.Source | Should -Be "project $parent"
    }
    It 'finds the nearest parent standard from a nested folder without its own file' {
        $parent = Write-Data (Join-Path $root 'secondline.standard.psd1') "@{ ModuleVersions = @{ SecondLine = '0.4.0' } }"
        $deep = New-Item -ItemType Directory -Path (Join-Path $root 'a\b\c') -Force
        $policy = & (Get-Module SecondLine) { param($d) Resolve-SLModuleVersionPolicy -Directory $d } $deep.FullName
        $policy.SecondLine.Source | Should -Be "project $parent"
    }
    It 'resolves relative Extends from the declaring file, not the current folder' {
        Write-Data (Join-Path $root 'shared\base.psd1') "@{ ModuleVersions = @{ SecondLine = '0.4.0' } }" | Out-Null
        $child = Write-Data (Join-Path $root 'app\secondline.standard.psd1') "@{ Extends = '..\shared\base.psd1' }"
        Push-Location $TestDrive
        try {
            $policy = & (Get-Module SecondLine) { param($s) Resolve-SLModuleVersionPolicy -Standard $s } $child
            $policy.SecondLine.Value | Should -Be '0.4.0'
        }
        finally { Pop-Location }
    }
    It 'orders machine < user < project, and records what each layer overrode' {
        Write-Data $env:SECONDLINE_MACHINE_SETTINGS "@{ ModuleVersions = @{ SecondLine = '0.2.0'; Tool = '1.0.0' } }" | Out-Null
        Write-Data $env:SECONDLINE_USER_SETTINGS "@{ ModuleVersions = @{ SecondLine = '0.5.0'; Tool = '1.1.0' } }" | Out-Null
        Write-Data (Join-Path $root 'secondline.standard.psd1') "@{ ModuleVersions = @{ SecondLine = '0.4.0' } }" | Out-Null
        $policy = & (Get-Module SecondLine) { param($d) Resolve-SLModuleVersionPolicy -Directory $d } $root
        $policy.SecondLine.Value | Should -Be '0.4.0'
        @($policy.SecondLine.Overridden.Value) | Should -Be @('0.2.0', '0.5.0')
        $policy.Tool.Value | Should -Be '1.1.0'
        $policy.Tool.Source | Should -BeLike 'user *'
    }
    It 'ignores machine and user files in CI and with SECONDLINE_NO_HOST_SETTINGS' {
        Write-Data $env:SECONDLINE_USER_SETTINGS "@{ ModuleVersions = @{ SecondLine = '0.5.0' } }" | Out-Null
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $env:CI = 'true'
        (& (Get-Module SecondLine) { param($d) Resolve-SLModuleVersionPolicy -Directory $d } $root).ContainsKey('SecondLine') | Should -BeFalse
        $env:CI = $null
        $env:SECONDLINE_NO_HOST_SETTINGS = '1'
        (& (Get-Module SecondLine) { param($d) Resolve-SLModuleVersionPolicy -Directory $d } $root).ContainsKey('SecondLine') | Should -BeFalse
    }
    It 'detects inheritance cycles before choosing a version' {
        Write-Data (Join-Path $root 'secondline.standard.psd1') "@{ Extends = 'other.psd1' }" | Out-Null
        Write-Data (Join-Path $root 'other.psd1') "@{ Extends = 'secondline.standard.psd1' }" | Out-Null
        { & (Get-Module SecondLine) { param($d) Resolve-SLModuleVersionPolicy -Directory $d } $root } | Should -Throw '*Circular SecondLine inheritance*'
    }
    It 'rejects versions Import-Module cannot select, naming the file' {
        $file = Write-Data (Join-Path $root 'secondline.standard.psd1') "@{ ModuleVersions = @{ SecondLine = 'latest' } }"
        { & (Get-Module SecondLine) { param($d) Resolve-SLModuleVersionPolicy -Directory $d } $root } | Should -Throw "*'latest' in project $file*"
        { Get-SecondLineStandard -Path $file } | Should -Throw '*not a version like 0.4.0*'
    }
    It 'stops at @development before import, and the packaged baseline pins no versions' {
        Write-Data (Join-Path $root 'secondline.standard.psd1') "@{ Extends = '@development'; ModuleVersions = @{ SecondLine = '0.4.0' } }" | Out-Null
        $policy = & (Get-Module SecondLine) { param($d) Resolve-SLModuleVersionPolicy -Directory $d } $root
        $policy.SecondLine.Value | Should -Be '0.4.0'
        (Import-PowerShellDataFile (Join-Path $repoRoot 'SecondLine\Standards\development.psd1')).ContainsKey('ModuleVersions') | Should -BeFalse
    }
    It 'accepts a standard with only ModuleVersions, merging sections by key through Extends' {
        Write-Data (Join-Path $root 'base.psd1') "@{ Extends = '@development'; ModuleVersions = @{ SecondLine = '0.3.0'; Pester = '5.7.1' }; Updates = @{ RefreshHours = 12 } }" | Out-Null
        $child = Write-Data (Join-Path $root 'secondline.standard.psd1') "@{ Extends = 'base.psd1'; ModuleVersions = @{ SecondLine = '0.4.0' } }"
        $standard = Get-SecondLineStandard -Path $child
        $standard.ModuleVersions.SecondLine | Should -Be '0.4.0'
        $standard.ModuleVersions.Pester | Should -Be '5.7.1'
        $standard.Updates.RefreshHours | Should -Be 12
        $standard.Tools.Count | Should -Be 2
        $only = Write-Data (Join-Path $root 'only.psd1') "@{ ModuleVersions = @{ SecondLine = '0.4.0' } }"
        (Get-SecondLineStandard -Path $only).ModuleVersions.SecondLine | Should -Be '0.4.0'
    }
    It 'Get-SLSetting shows each value with its source, and what CI would see' {
        Write-Data $env:SECONDLINE_USER_SETTINGS "@{ ModuleVersions = @{ SecondLine = '0.5.0' } }" | Out-Null
        Write-Data (Join-Path $root 'secondline.standard.psd1') "@{ ModuleVersions = @{ SecondLine = '0.4.0' } }" | Out-Null
        $rows = @(Get-SLSetting -Path $root)
        $sl = $rows | Where-Object { $_.Section -eq 'ModuleVersions' -and $_.Name -eq 'SecondLine' }
        $sl.Value | Should -Be '0.4.0'
        $sl.Overridden | Should -BeLike '0.5.0 from user *'
        ($rows | Where-Object { $_.Section -eq 'Layer' -and $_.Name -eq 'User' }).Source | Should -Be 'present'
        $ci = @(Get-SLSetting -Path $root -NoHostSettings)
        ($ci | Where-Object { $_.Section -eq 'ModuleVersions' -and $_.Name -eq 'SecondLine' }).Overridden | Should -BeNullOrEmpty
        ($ci | Where-Object { $_.Section -eq 'Layer' -and $_.Name -eq 'User' }).Source | Should -Be 'present, ignored'
    }
}

Describe 'Bootstrap: selecting the version before import' {
    BeforeEach {
        $script:project = Join-Path $TestDrive "p-$([guid]::NewGuid().ToString('N'))\repo"
        New-Item -ItemType Directory -Path $project -Force | Out-Null
    }
    It 'imports exactly the approved version, not the highest installed' {
        Write-Data (Join-Path $project 'secondline.standard.psd1') "@{ ModuleVersions = @{ SLFake = '1.0.0' } }" | Out-Null
        Invoke-Bootstrap -Project $project -Arguments @('-Name', 'SLFake') | Should -BeLike '1.0.0|1.0.0|project *'
    }
    It 'follows an inherited pin from a parent project' {
        Write-Data (Join-Path $project 'secondline.standard.psd1') "@{ ModuleVersions = @{ SLFake = '2.0.0' } }" | Out-Null
        $sub = Join-Path $project 'services\api'
        Write-Data (Join-Path $sub 'secondline.standard.psd1') "@{ Extends = '..\..\secondline.standard.psd1' }" | Out-Null
        Invoke-Bootstrap -Project $sub -Arguments @('-Name', 'SLFake') | Should -BeLike '2.0.0|2.0.0|*'
    }
    It 'refuses to swap a different version that is already loaded' {
        Write-Data (Join-Path $project 'secondline.standard.psd1') "@{ ModuleVersions = @{ SLFake = '1.0.0' } }" | Out-Null
        $result = Invoke-Bootstrap -Project $project -Arguments @('-Name', 'SLFake') -Before 'Import-Module SLFake -RequiredVersion 2.0.0'
        $result | Should -BeLike 'ERROR: SLFake 2.0.0 is already loaded*approves 1.0.0*new PowerShell session*'
    }
    It 'accepts the approved version when it is already loaded' {
        Write-Data (Join-Path $project 'secondline.standard.psd1') "@{ ModuleVersions = @{ SLFake = '1.0.0' } }" | Out-Null
        Invoke-Bootstrap -Project $project -Arguments @('-Name', 'SLFake') -Before 'Import-Module SLFake -RequiredVersion 1.0.0' | Should -BeLike '1.0.0|1.0.0|*'
    }
    It 'never installs a missing approved version; it says how' {
        Write-Data (Join-Path $project 'secondline.standard.psd1') "@{ ModuleVersions = @{ SLFake = '3.0.0' } }" | Out-Null
        $result = Invoke-Bootstrap -Project $project -Arguments @('-Name', 'SLFake')
        $result | Should -BeLike 'ERROR: SLFake 3.0.0 is approved by project*not installed (installed: 2.0.0, 1.0.0). Nothing was installed.*Install-PSResource SLFake -Version 3.0.0*'
        Test-Path (Join-Path $modules 'SLFake\3.0.0') | Should -BeFalse
    }
    It 'fails without a pin unless -AllowUnpinned, which takes the highest installed' {
        Invoke-Bootstrap -Project $project -Arguments @('-Name', 'SLFake') | Should -BeLike 'ERROR: No approved SLFake version*'
        Invoke-Bootstrap -Project $project -Arguments @('-Name', 'SLFake', '-AllowUnpinned') | Should -BeLike '2.0.0|2.0.0|highest installed*'
    }
    It 'is reproducible in CI: personal settings cannot choose the version' {
        $user = Join-Path (Split-Path $project -Parent) 'personal.psd1'
        Write-Data $user "@{ ModuleVersions = @{ SLFake = '2.0.0' } }" | Out-Null
        Write-Data (Join-Path $project 'secondline.standard.psd1') "@{ ModuleVersions = @{ SLFake = '1.0.0' } }" | Out-Null
        Invoke-Bootstrap -Project $project -Arguments @('-Name', 'SLFake') -Environment @{ SECONDLINE_USER_SETTINGS = $user } | Should -BeLike '1.0.0|*'
        Remove-Item (Join-Path $project 'secondline.standard.psd1')
        Invoke-Bootstrap -Project $project -Arguments @('-Name', 'SLFake') -Environment @{ SECONDLINE_USER_SETTINGS = $user } | Should -BeLike '2.0.0|2.0.0|user *'
        Invoke-Bootstrap -Project $project -Arguments @('-Name', 'SLFake') -Environment @{ SECONDLINE_USER_SETTINGS = $user; GITHUB_ACTIONS = 'true' } | Should -BeLike 'ERROR: No approved SLFake version*'
    }
    It 'selects this SecondLine package by its approved version before import' {
        $version = (Import-PowerShellDataFile (Join-Path $repoRoot 'SecondLine\SecondLine.psd1')).ModuleVersion
        $target = Join-Path $modules "SecondLine\$version"
        if (-not (Test-Path $target)) { Copy-Item -Path (Join-Path $repoRoot 'SecondLine') -Destination $target -Recurse }
        Write-Data (Join-Path $project 'secondline.standard.psd1') "@{ ModuleVersions = @{ SecondLine = '$version' } }" | Out-Null
        Invoke-Bootstrap -Project $project | Should -BeLike "$version|$version|project *"
    }
    It 'defines functions only, importing nothing, with -LibraryOnly' {
        $before = @(Get-Module).Count
        . $bootstrap -LibraryOnly
        @(Get-Module).Count | Should -Be $before
        Get-Command Resolve-SLModuleVersionPolicy -CommandType Function | Should -Not -BeNullOrEmpty
    }
}
