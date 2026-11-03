BeforeAll {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'SecondLine\SecondLine.psd1') -Force
    function Write-Standard([string] $Name, [string] $Body) {
        $path = Join-Path $TestDrive $Name
        [IO.File]::WriteAllText($path, $Body)
        return $path
    }
}
Describe 'Standard inheritance' {
    It 'inherits the packaged baseline and replaces a complete named tool' {
        $path = Write-Standard 'child.psd1' "@{ Extends='@development'; Name='Child'; Tools=@(@{Name='.NET SDK selected by this repository'; Command='dotnet'; Expect='10.0.401'; Rule='Exact'}) }"
        $standard = Get-SecondLineStandard $path
        $standard.Name | Should -Be 'Child'
        $standard.Tools.Count | Should -Be 2
        ($standard.Tools | Where-Object Command -eq dotnet).Rule | Should -Be Exact
        ($standard.Tools | Where-Object Command -eq git).Rule | Should -Be Minimum
    }
    It 'resolves relative parents through multiple levels and supports inheritance only' {
        $null = Write-Standard 'base.psd1' "@{Extends='@development'; Name='Base'}"
        $path = Write-Standard 'middle.psd1' "@{Extends='base.psd1'}"
        $standard = Get-SecondLineStandard $path
        $standard.Name | Should -Be Base
        $standard.Tools.Count | Should -Be 2
    }
    It 'discovers the nearest standard from a subfolder' {
        $null = Write-Standard 'secondline.standard.psd1' "@{Extends='@development';Name='Parent'}"
        $nested = New-Item -ItemType Directory (Join-Path $TestDrive 'nested\deep') -Force
        $saved = $env:SECONDLINE_STANDARD
        try {
            $env:SECONDLINE_STANDARD = $null
            Push-Location $nested.FullName
            (Get-SecondLineStandard).Name | Should -Be Parent
        } finally { Pop-Location; $env:SECONDLINE_STANDARD = $saved }
    }
    It 'prefers explicit path over the environment standard' {
        $path = Write-Standard 'explicit.psd1' "@{Extends='@development';Name='Explicit'}"
        $saved = $env:SECONDLINE_STANDARD
        try {
            $env:SECONDLINE_STANDARD = Join-Path $TestDrive 'missing.psd1'
            (Get-SecondLineStandard $path).Name | Should -Be Explicit
        } finally { $env:SECONDLINE_STANDARD = $saved }
    }
    It 'rejects a missing parent' {
        $path = Write-Standard 'missing-parent.psd1' "@{Extends='absent.psd1'}"
        { Get-SecondLineStandard $path } | Should -Throw '*parent standard not found*'
    }
    It 'rejects circular inheritance' {
        $path = Write-Standard 'a.psd1' "@{Extends='b.psd1'}"
        $null = Write-Standard 'b.psd1' "@{Extends='a.psd1'}"
        { Get-SecondLineStandard $path } | Should -Throw '*Circular SecondLine inheritance*'
    }
    It 'rejects malformed parent declarations' {
        $path = Write-Standard 'invalid-parent.psd1' "@{Extends=@('a','b')}"
        { Get-SecondLineStandard $path } | Should -Throw '*nonempty string*'
    }
    It 'validates overridden tools after merging' {
        $path = Write-Standard 'invalid-tool.psd1' "@{Extends='@development';Tools=@(@{Name='Git';Command='git';Expect='2.0';Rule='Bogus'})}"
        { Get-SecondLineStandard $path } | Should -Throw '*Bogus*'
    }
    It 'merges git profiles and repo mappings with child precedence' {
        $null = Write-Standard 'git-base.psd1' "@{GitAttributes=@{Profiles=@{custom=@('* text=auto');other=@('* text=auto')};Repos=@{one='custom';two='other'}}}"
        $path = Write-Standard 'git-child.psd1' "@{Extends='git-base.psd1';GitAttributes=@{Profiles=@{custom=@('* text eol=lf')};Repos=@{one='other'}}}"
        $standard = Get-SecondLineStandard $path
        $standard.GitAttributes.Profiles.custom | Should -Contain '* text eol=lf'
        $standard.GitAttributes.Profiles.ContainsKey('other') | Should -BeTrue
        $standard.GitAttributes.Repos.one | Should -Be other
        $standard.GitAttributes.Repos.two | Should -Be other
    }
}