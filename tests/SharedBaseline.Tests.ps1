BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo 'SecondLine\SecondLine.psd1') -Force
    $baselinePath = Join-Path $repo 'SecondLine\Standards\development.psd1'
}
Describe 'Shared developer baseline' {
    It 'ships a valid standard with Git and selected .NET requirements' {
        $standard = Get-SecondLineStandard -Path $baselinePath
        $standard.Tools.Count | Should -Be 2
        $git = $standard.Tools | Where-Object Command -eq 'git'
        $git.Rule | Should -Be 'Minimum'
        $dotnet = $standard.Tools | Where-Object Command -eq 'dotnet'
        $dotnet.Arguments | Should -Be '--version'
        $dotnet.Expect | Should -Be '10.0'
        $dotnet.Rule | Should -Be 'Minor'
    }
}
