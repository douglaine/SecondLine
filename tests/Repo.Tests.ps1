#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# Test-SLRepo, Set-SLGitAttributes and the .gitattributes parser behind them.
# Git-dependent tests build throwaway repos in TestDrive, each with its own local
# config, so the runner's global git settings can't change the results.

# InModuleScope at Describe level runs during discovery, before BeforeAll.
BeforeDiscovery {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'SecondLine\SecondLine.psd1') -Force
    $noGit = -not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)
}

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'SecondLine\SecondLine.psd1') -Force
    $profileDir = Join-Path $repoRoot 'SecondLine\Profiles\gitattributes'

    # git, with stderr folded into the output so Windows PowerShell 5.1 can't stop on it.
    function Invoke-TestGit {
        param([string] $Repo, [Parameter(ValueFromRemainingArguments)] [string[]] $Rest)
        $out = & { $ErrorActionPreference = 'Continue'; & git -C $Repo @Rest 2>&1 }
        return @($out | ForEach-Object { "$_" })
    }

    # A repo in TestDrive with the given files (written byte for byte, UTF-8 without
    # BOM) and, with -Commit, one commit.
    function New-TestRepo {
        param([string] $Path, [hashtable] $Files = @{}, [switch] $Commit)
        if (-not [IO.Path]::IsPathRooted($Path)) { $Path = Join-Path $TestDrive $Path }
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
        [void] (Invoke-TestGit $Path init -q)
        [void] (Invoke-TestGit $Path config user.name 'SecondLine Test')
        [void] (Invoke-TestGit $Path config user.email 'test@example.com')
        [void] (Invoke-TestGit $Path config core.autocrlf false)
        [void] (Invoke-TestGit $Path config commit.gpgsign false)
        [void] (Invoke-TestGit $Path config core.hooksPath .no-hooks)
        Add-TestFiles -Path $Path -Files $Files
        if ($Commit) {
            [void] (Invoke-TestGit $Path add -A)
            [void] (Invoke-TestGit $Path commit -q -m init)
        }
        return $Path
    }

    function Add-TestFiles {
        param([string] $Path, [hashtable] $Files)
        foreach ($name in $Files.Keys) {
            $f = Join-Path $Path $name
            New-Item -ItemType Directory -Force -Path (Split-Path $f -Parent) | Out-Null
            [IO.File]::WriteAllText($f, $Files[$name], (New-Object Text.UTF8Encoding($false)))
        }
    }

    function Get-TestProfile([string] $Name) {
        return [IO.File]::ReadAllText((Join-Path $profileDir "$Name.gitattributes"))
    }

    function Get-Head([string] $Repo) { return (Invoke-TestGit $Repo rev-parse HEAD) -join '' }

    function New-TestStandard([string] $Body) {
        $p = Join-Path $TestDrive ("std-{0}.psd1" -f [guid]::NewGuid().ToString('N'))
        Set-Content -LiteralPath $p -Value $Body -Encoding UTF8
        return $p
    }

    # No standard from the environment or the current folder leaks into these tests.
    $script:oldStandard = $env:SECONDLINE_STANDARD
    $env:SECONDLINE_STANDARD = $null
    Push-Location $TestDrive
}

AfterAll {
    Pop-Location
    $env:SECONDLINE_STANDARD = $script:oldStandard
}

Describe 'git' {
    It 'is on PATH (the git-dependent tests below are skipped otherwise)' {
        if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'git is not on PATH'
        }
    }
}

Describe 'Help' {
    # A help line starting with '.' (say, '.gitattributes') is read as an unknown
    # keyword, and PowerShell then drops the whole help block without a word.
    It '<Name> has its comment-based help, with examples and every parameter described' -TestCases @(
        @{ Name = 'Test-SLRepo' }
        @{ Name = 'Set-SLGitAttributes' }
        @{ Name = 'Test-SecondLine' }
        @{ Name = 'Get-SecondLineStandard' }
    ) {
        param($Name)
        $help = Get-Help $Name
        $help.Synopsis | Should -Not -Match "^\s*$Name \["
        if ($Name -ne 'Get-SecondLineStandard') {
            @($help.Examples.Example).Count | Should -BeGreaterThan 0
            foreach ($p in @($help.Parameters.Parameter | Where-Object { 'WhatIf', 'Confirm' -notcontains $_.Name })) {
                "$($p.Description.Text)" | Should -Not -BeNullOrEmpty -Because "-$($p.Name) needs a .PARAMETER entry"
            }
        }
    }
}

Describe 'git not on PATH' {
    It 'is one clear error with an install hint' {
        Mock Get-Command { } -ModuleName SecondLine -ParameterFilter { $Name -eq 'git' }
        { Test-SLRepo -Path $TestDrive -Quiet } | Should -Throw '*git is not on PATH*winget install --id Git.Git -e*'
        { Set-SLGitAttributes -Path $TestDrive } | Should -Throw '*git is not on PATH*'
    }
}

Describe 'Parsing .gitattributes' {
    InModuleScope SecondLine {
        It 'ignores comments, blank lines, spacing, order and duplicate lines' {
            $a = @('# header', '* text=auto', '', '*.md   text   eol=lf', '*.png binary')
            $b = @('*.png binary', '*.md text eol=lf', '*.md text eol=lf', '   # other comment', '* text=auto')
            (Compare-SLGitAttributes -Lines $a -ProfileLines $b).Status | Should -Be 'MATCHES'
        }

        It 'treats binary as -diff -merge -text' {
            (Compare-SLGitAttributes -Lines @('*.png -text -merge -diff') -ProfileLines @('*.png binary')).Status | Should -Be 'MATCHES'
            (Compare-SLGitAttributes -Lines @('*.png binary') -ProfileLines @('*.png -diff -merge -text')).Status | Should -Be 'MATCHES'
        }

        It 'treats -text alone as different from binary' {
            (Compare-SLGitAttributes -Lines @('*.png -text') -ProfileLines @('*.png binary')).Status | Should -Be 'DIFFERS'
        }

        It 'normalizes attribute order' {
            (Compare-SLGitAttributes -Lines @('*.md eol=lf text') -ProfileLines @('*.md text eol=lf')).Status | Should -Be 'MATCHES'
        }

        It 'same pattern with different attributes is a conflict' {
            $r = Compare-SLGitAttributes -Lines @('*.md text eol=crlf') -ProfileLines @('*.md text eol=lf')
            $r.Status | Should -Be 'DIFFERS'
            $r.ConflictingRules | Should -HaveCount 1
            $r.ConflictingRules[0] | Should -Match "^\*\.md: profile has 'text eol=lf', repo has 'text eol=crlf'"
        }

        It 'text, text=auto and -text are all different' {
            (Compare-SLGitAttributes -Lines @('* text') -ProfileLines @('* text=auto')).Status | Should -Be 'DIFFERS'
            (Compare-SLGitAttributes -Lines @('* -text') -ProfileLines @('* text=auto')).Status | Should -Be 'DIFFERS'
        }

        It 'merges a pattern repeated on several lines, later lines winning' {
            $rules = @(ConvertFrom-SLGitAttributes @('*.md text', '*.md eol=crlf', '*.md eol=lf'))
            $rules | Should -HaveCount 1
            Format-SLAttributeSet $rules[0].Attributes | Should -Be 'text eol=lf'
            $rules[0].Lines -join ',' | Should -Be '0,1,2'
        }

        It 'reads quoted patterns and skips [attr] macro lines' {
            $rules = @(ConvertFrom-SLGitAttributes @('"my file.txt" text', '[attr]mine text eol=lf'))
            $rules | Should -HaveCount 1
            $rules[0].Pattern | Should -Be 'my file.txt'
        }

        It 'drops a UTF-8 BOM when reading' {
            $f = Join-Path $TestDrive 'bom.gitattributes'
            [IO.File]::WriteAllText($f, "* text=auto`r`n*.md text eol=lf`r`n", (New-Object Text.UTF8Encoding($true)))
            $lines = @(Read-SLTextLines -Path $f)
            $lines[0] | Should -Be '* text=auto'
            $lines | Should -HaveCount 2
        }
    }
}

Describe 'Classification against a profile' {
    InModuleScope SecondLine {
        BeforeAll {
            $prof = @('* text=auto', '*.md text eol=lf', '*.ps1 text eol=crlf', '*.png binary')
        }

        It 'MISSING when there is no .gitattributes' {
            (Compare-SLGitAttributes -Lines @() -ProfileLines $prof -FileMissing).Status | Should -Be 'MISSING'
        }

        It 'MATCHES the profile itself' {
            $r = Compare-SLGitAttributes -Lines $prof -ProfileLines $prof
            $r.Status | Should -Be 'MATCHES'
            $r.MissingRules + $r.ConflictingRules + $r.ExtraRules | Should -BeNullOrEmpty
        }

        It 'EXTENDS with a repo-specific rule, and reports it' {
            $r = Compare-SLGitAttributes -Lines ($prof + 'tools/git-hooks/* text eol=lf') -ProfileLines $prof
            $r.Status | Should -Be 'EXTENDS'
            $r.ExtraRules | Should -Be @('tools/git-hooks/* text eol=lf')
        }

        It 'EXTENDS with an extra attribute on a profile pattern' {
            $lines = @('* text=auto', '*.md text eol=lf diff=markdown', '*.ps1 text eol=crlf', '*.png binary')
            $r = Compare-SLGitAttributes -Lines $lines -ProfileLines $prof
            $r.Status | Should -Be 'EXTENDS'
            $r.ExtraRules[0] | Should -Match 'diff=markdown'
        }

        It 'DIFFERS when a profile rule is missing, and lists it' {
            $r = Compare-SLGitAttributes -Lines @('* text=auto', '*.md text eol=lf', '*.png binary') -ProfileLines $prof
            $r.Status | Should -Be 'DIFFERS'
            $r.MissingRules | Should -Be @('*.ps1 text eol=crlf')
        }

        It 'DIFFERS on a conflict, and lists it' {
            $r = Compare-SLGitAttributes -Lines @('* text=auto', '*.md text eol=lf', '*.ps1 text eol=lf', '*.png binary') -ProfileLines $prof
            $r.Status | Should -Be 'DIFFERS'
            $r.ConflictingRules | Should -HaveCount 1
            $r.MissingRules | Should -BeNullOrEmpty
        }
    }
}

Describe 'Built-in profiles' {
    It 'ships docs, powershell and dotnet' {
        foreach ($name in 'docs', 'powershell', 'dotnet') {
            Join-Path $profileDir "$name.gitattributes" | Should -Exist
        }
    }

    It "the powershell profile equals this repo's .gitattributes" {
        InModuleScope SecondLine -Parameters @{ Root = $repoRoot; Dir = $profileDir } {
            param($Root, $Dir)
            $mine = @(Read-SLTextLines -Path (Join-Path $Root '.gitattributes'))
            $prof = @(Read-SLTextLines -Path (Join-Path $Dir 'powershell.gitattributes'))
            (Compare-SLGitAttributes -Lines $mine -ProfileLines $prof).Status | Should -Be 'MATCHES'
        }
    }

    It 'dotnet keeps *.sln CRLF (Visual Studio writes it that way)' {
        InModuleScope SecondLine {
            $rules = @(ConvertFrom-SLGitAttributes (Get-SLBuiltInProfiles)['dotnet'])
            Format-SLAttributeSet ($rules | Where-Object Pattern -eq '*.sln').Attributes | Should -Be 'text eol=crlf'
        }
    }
}

Describe 'Standard file: GitAttributes section' {
    It 'a GitAttributes-only standard is valid' {
        $p = New-TestStandard @'
@{
    GitAttributes = @{
        Profiles = @{ web = @('* text=auto', '*.ts text eol=lf', '*.png binary') }
        Repos    = @{ 'docs-site' = 'docs'; 'Contoso.Web' = 'web' }
    }
}
'@
        $s = Get-SecondLineStandard -Path $p
        @($s.Tools) | Should -HaveCount 0
        $s.GitAttributes.Profiles['web'] | Should -HaveCount 3
        $s.GitAttributes.Repos['docs-site'] | Should -Be 'docs'
    }

    It 'still accepts a Tools-only standard' {
        $p = New-TestStandard "@{ Tools = @( @{ Name='g'; Command='g'; Expect='1'; Rule='Major' } ) }"
        $s = Get-SecondLineStandard -Path $p
        $s.Tools | Should -HaveCount 1
        $s.GitAttributes | Should -BeNullOrEmpty
    }

    It 'needs Tools or GitAttributes' {
        $p = New-TestStandard "@{ Name = 'empty' }"
        { Get-SecondLineStandard -Path $p } | Should -Throw "*'Tools' is missing or empty*GitAttributes*"
    }

    It 'reports every problem in a malformed section' {
        $p = New-TestStandard @'
@{
    GitAttributes = @{
        Profiles = @{ web = 'not a list of strings but fine'; 'bad name' = @('* text=auto'); empty = @('# only a comment') }
        Repos    = @{ 'docs-site' = 'nope' }
        Extra    = 1
    }
}
'@
        $err = $null
        try { Get-SecondLineStandard -Path $p } catch { $err = $_.Exception.Message }
        $err | Should -Match "unknown key 'Extra'"
        $err | Should -Match "Profiles.bad name"
        $err | Should -Match "Profiles.empty has no rules"
        $err | Should -Match "Repos.docs-site uses profile 'nope', which doesn't exist"
    }

    It 'rejects a section that is not a hashtable' {
        $p = New-TestStandard "@{ GitAttributes = 'docs' }"
        { Get-SecondLineStandard -Path $p } | Should -Throw "*'GitAttributes' must be*"
    }

    It 'accepts the shipped example' {
        { Get-SecondLineStandard -Path (Join-Path $repoRoot 'examples\secondline.standard.psd1') } | Should -Not -Throw
    }
}

Describe 'Profile detection' -Skip:$noGit {
    It 'a .slnx means dotnet, and says which file' {
        $r = New-TestRepo 'det-slnx' @{ 'MyApp.slnx' = "<Solution />`n" }
        $c = Test-SLRepo -Path $r -PassThru -Quiet
        $c.Profile | Should -Be 'dotnet'
        $c.ProfileReason | Should -Be 'found MyApp.slnx'
    }

    It 'finds a project up to 3 folders down' {
        $r = New-TestRepo 'det-deep' @{ 'src\apps\MyApp\MyApp.csproj' = "<Project />`n" }
        (Test-SLRepo -Path $r -PassThru -Quiet).Profile | Should -Be 'dotnet'
    }

    It 'ignores projects under bin, obj and node_modules' {
        $r = New-TestRepo 'det-skip' @{ 'node_modules\x\x.csproj' = "<Project />`n"; 'bin\y.sln' = "`n"; 'README.md' = "hi`n" }
        (Test-SLRepo -Path $r -PassThru -Quiet).Profile | Should -Be 'docs'
    }

    It 'a module manifest means powershell' {
        $r = New-TestRepo 'det-psd1' @{ 'MyModule\MyModule.psd1' = "@{`r`n    RootModule = 'MyModule.psm1'`r`n    ModuleVersion = '1.0.0'`r`n}`r`n" }
        $c = Test-SLRepo -Path $r -PassThru -Quiet
        $c.Profile | Should -Be 'powershell'
        $c.ProfileReason | Should -Be 'found MyModule\MyModule.psd1'
    }

    It 'a .psd1 data file is not a module' {
        $r = New-TestRepo 'det-data' @{ 'settings.psd1' = "@{ Port = 1 }`r`n" }
        (Test-SLRepo -Path $r -PassThru -Quiet).Profile | Should -Be 'docs'
    }

    It 'plain markdown means docs' {
        $c = Test-SLRepo -Path (New-TestRepo 'det-md' @{ 'README.md' = "# Notes`n" }) -PassThru -Quiet
        $c.Profile | Should -Be 'docs'
        $c.ProfileReason | Should -Match 'no .NET project'
    }

    It 'a pin in the standard wins over detection' {
        $r = New-TestRepo 'pinned-app' @{ 'MyApp.slnx' = "<Solution />`n" }
        $std = New-TestStandard "@{ GitAttributes = @{ Repos = @{ 'pinned-app' = 'docs' } } }"
        $c = Test-SLRepo -Path $r -Standard $std -PassThru -Quiet
        $c.Profile | Should -Be 'docs'
        $c.ProfileReason | Should -Be 'pinned in standard'
    }

    It '-Profile wins over everything' {
        $r = New-TestRepo 'pinned-app2' @{ 'MyApp.slnx' = "<Solution />`n" }
        $std = New-TestStandard "@{ GitAttributes = @{ Repos = @{ 'pinned-app2' = 'docs' } } }"
        $c = Test-SLRepo -Path $r -Standard $std -Profile powershell -PassThru -Quiet
        $c.Profile | Should -Be 'powershell'
        $c.ProfileReason | Should -Be '-Profile'
    }

    It 'uses a profile defined in the standard' {
        $r = New-TestRepo 'custom' @{ '.gitattributes' = "* text=auto`n*.ts text eol=lf`n" }
        $std = New-TestStandard "@{ GitAttributes = @{ Profiles = @{ web = @('* text=auto', '*.ts text eol=lf') }; Repos = @{ custom = 'web' } } }"
        (Test-SLRepo -Path $r -Standard $std -PassThru -Quiet).Status | Should -Be 'MATCHES'
    }

    It 'an unknown -Profile is a clear error' {
        $r = New-TestRepo 'det-unknown'
        { Test-SLRepo -Path $r -Profile nope -Quiet } | Should -Throw "*Unknown profile 'nope'*docs*"
    }
}

Describe 'Repo discovery' -Skip:$noGit {
    BeforeAll {
        $root = Join-Path $TestDrive 'discover'
        [void] (New-TestRepo (Join-Path $root 'top'))
        [void] (New-TestRepo (Join-Path $root 'group\inner'))
        [void] (New-TestRepo (Join-Path $root 'a\b\deep'))
        [void] (New-TestRepo (Join-Path $root 'top\nested-inside-top'))
        [void] (New-TestRepo (Join-Path $root 'node_modules\pkg'))
        [void] (New-TestRepo (Join-Path $root 'my répo with spaces'))
        # A worktree has a .git file, not a folder.
        $main = New-TestRepo (Join-Path $root 'wt-main') @{ 'README.md' = "x`n" } -Commit
        [void] (Invoke-TestGit $main worktree add -q (Join-Path $root 'wt-linked'))
    }

    It 'finds repos to -Depth, skips node_modules, and stays out of a found repo' {
        $names = @(Test-SLRepo -Path $root -PassThru -Quiet | ForEach-Object Repo) | Sort-Object
        $names | Should -Contain 'top'
        $names | Should -Contain 'inner'
        $names | Should -Not -Contain 'deep'
        $names | Should -Not -Contain 'nested-inside-top'
        $names | Should -Not -Contain 'pkg'
    }

    It 'goes deeper with -Depth' {
        $names = @(Test-SLRepo -Path $root -Depth 3 -PassThru -Quiet | ForEach-Object Repo)
        $names | Should -Contain 'deep'
    }

    It 'recognises a worktree (.git file)' {
        Join-Path $root 'wt-linked\.git' | Should -Exist
        (Get-Item -LiteralPath (Join-Path $root 'wt-linked\.git') -Force).PSIsContainer | Should -BeFalse
        $names = @(Test-SLRepo -Path $root -PassThru -Quiet | ForEach-Object Repo)
        $names | Should -Contain 'wt-linked'
    }

    It 'handles spaces and non-ASCII characters in paths' {
        $c = @(Test-SLRepo -Path $root -PassThru -Quiet | Where-Object Repo -eq 'my répo with spaces')
        $c | Should -HaveCount 1
        $c[0].Status | Should -Be 'MISSING'
    }

    It 'a repo as -Path checks just that repo' {
        @(Test-SLRepo -Path (Join-Path $root 'top') -PassThru -Quiet) | Should -HaveCount 1
    }

    It 'returns $false and warns when nothing is found' {
        $empty = Join-Path $TestDrive 'no-repos-here'
        New-Item -ItemType Directory -Force -Path $empty | Out-Null
        Test-SLRepo -Path $empty -Quiet -WarningVariable w -WarningAction SilentlyContinue | Should -BeFalse
        "$w" | Should -Match 'No git repos found'
    }

    It 'returns $true only when every repo is OK' {
        $ok = New-TestRepo 'ok-only\one' @{ '.gitattributes' = (Get-TestProfile 'docs') } -Commit
        Test-SLRepo -Path (Split-Path $ok -Parent) -Quiet | Should -BeTrue
        Test-SLRepo -Path $root -Quiet | Should -BeFalse
    }
}

Describe 'Files needing renormalization' -Skip:$noGit {
    BeforeAll {
        Mock Write-Host { } -ModuleName SecondLine
    }

    It 'reports a CRLF file committed before the rules, and Set-SLGitAttributes fixes the index' {
        $r = New-TestRepo 'renorm' @{ 'notes.md' = "line one`r`nline two`r`n"; 'plain.md' = "lf only`n" } -Commit
        Add-TestFiles -Path $r -Files @{ '.gitattributes' = (Get-TestProfile 'docs') }
        $head = Get-Head $r

        $c = Test-SLRepo -Path $r -PassThru -Quiet
        $c.Status | Should -Be 'MATCHES'
        $c.FilesToRenormalize | Should -Be 1
        $c.RenormalizeSample | Should -Be @('notes.md')
        Test-SLRepo -Path $r -Quiet | Should -BeFalse

        $out = Set-SLGitAttributes -Path $r
        $out.Action | Should -Be 'Unchanged'
        $out.FilesStaged | Should -Contain 'notes.md'
        ((Invoke-TestGit $r ls-files --eol notes.md) -join '') | Should -Match '^i/lf\s'
        (Test-SLRepo -Path $r -PassThru -Quiet).FilesToRenormalize | Should -Be 0
        Get-Head $r | Should -Be $head
    }

    It 'skips the check, with a note, in a repo with no commits' {
        $r = New-TestRepo 'no-commits' @{ 'a.md' = "x`r`n" }
        $c = Test-SLRepo -Path $r -PassThru -Quiet
        $c.FilesToRenormalize | Should -Be 0
        $c.Note | Should -Match 'no commits'
    }

    It 'does not count binary files' {
        $r = New-TestRepo 'renorm-bin' @{ '.gitattributes' = (Get-TestProfile 'docs') } -Commit
        [IO.File]::WriteAllBytes((Join-Path $r 'img.png'), [byte[]](0x89, 0x50, 0x0D, 0x0A, 0x00, 0x0D, 0x0A))
        [void] (Invoke-TestGit $r add img.png)
        [void] (Invoke-TestGit $r commit -q -m png)
        (Test-SLRepo -Path $r -PassThru -Quiet).FilesToRenormalize | Should -Be 0
    }
}

Describe 'Set-SLGitAttributes' -Skip:$noGit {
    BeforeAll {
        Mock Write-Host { } -ModuleName SecondLine
    }

    It 'creates .gitattributes as UTF-8 without BOM, LF only, and never commits' {
        $r = New-TestRepo 'set-create' @{ 'README.md' = "# Hi`n" } -Commit
        $head = Get-Head $r
        $out = Set-SLGitAttributes -Path $r
        $out.Action | Should -Be 'Created'
        $out.Profile | Should -Be 'docs'
        $out.FilesStaged | Should -Contain '.gitattributes'

        $bytes = [IO.File]::ReadAllBytes((Join-Path $r '.gitattributes'))
        $bytes[0] | Should -Not -Be 0xEF
        $bytes | Should -Not -Contain ([byte] 13)
        $bytes[-1] | Should -Be 10
        (Test-SLRepo -Path $r -PassThru -Quiet).Status | Should -Be 'MATCHES'
        Get-Head $r | Should -Be $head
    }

    It 'appends missing rules, keeping comments and extra rules' {
        $existing = "# Our own header`n*.md text eol=lf`ntools/git-hooks/* text eol=lf`n"
        $r = New-TestRepo 'set-append' @{ '.gitattributes' = $existing } -Commit
        $out = Set-SLGitAttributes -Path $r
        $out.Action | Should -Be 'Appended'
        $out.RulesAdded | Should -Contain '*.png binary'

        $text = [IO.File]::ReadAllText((Join-Path $r '.gitattributes'))
        $text | Should -Match '# Our own header'
        $text | Should -Match 'tools/git-hooks/\* text eol=lf'
        $text | Should -Match '# Added by SecondLine'
        (Test-SLRepo -Path $r -PassThru -Quiet).Status | Should -Be 'EXTENDS'
    }

    It 'puts a missing * catch-all first, so it cannot override later rules' {
        $r = New-TestRepo 'set-star' @{ '.gitattributes' = "*.png binary`n" } -Commit
        [void] (Set-SLGitAttributes -Path $r -Profile docs)
        $rules = @([IO.File]::ReadAllLines((Join-Path $r '.gitattributes')) | Where-Object { $_ -and -not $_.StartsWith('#') })
        $rules[0] | Should -Match '^\*\s+text=auto$'
    }

    It 'refuses conflicting rules without -Force and changes nothing' {
        $existing = "* text=auto`n*.md text eol=crlf diff=markdown`n"
        $r = New-TestRepo 'set-conflict' @{ '.gitattributes' = $existing } -Commit
        { Set-SLGitAttributes -Path $r -ErrorAction Stop } | Should -Throw '*conflicts with profile*-Force*'
        [IO.File]::ReadAllText((Join-Path $r '.gitattributes')) | Should -Be $existing
    }

    It '-Force replaces the conflicting line in place and keeps extra attributes' {
        $existing = "# keep me`n* text=auto`n*.md text eol=crlf diff=markdown`nextra/* -text`n"
        $r = New-TestRepo 'set-force' @{ '.gitattributes' = $existing } -Commit
        $out = Set-SLGitAttributes -Path $r -Force
        $out.Action | Should -Be 'Replaced'
        $lines = [IO.File]::ReadAllLines((Join-Path $r '.gitattributes'))
        $lines[0] | Should -Be '# keep me'
        $lines[2] | Should -Match '^\*\.md\s+text eol=lf diff=markdown$'
        $lines[3] | Should -Be 'extra/* -text'
        (Test-SLRepo -Path $r -PassThru -Quiet).Status | Should -Be 'EXTENDS'
    }

    It 'refuses a dirty working tree without -AllowDirty, and explains why' {
        $r = New-TestRepo 'set-dirty' @{ 'README.md' = "one`n" } -Commit
        Add-TestFiles -Path $r -Files @{ 'README.md' = "two`n" }
        { Set-SLGitAttributes -Path $r -ErrorAction Stop } | Should -Throw '*uncommitted changes*mix line-ending changes*-AllowDirty*'
        Join-Path $r '.gitattributes' | Should -Not -Exist

        $out = Set-SLGitAttributes -Path $r -AllowDirty
        $out.Action | Should -Be 'Created'
    }

    It 'a file that only shows as modified because of its line endings is not dirty' {
        $r = New-TestRepo 'set-eol-only' @{ 'notes.md' = "a`r`nb`r`n" } -Commit
        Add-TestFiles -Path $r -Files @{ '.gitattributes' = (Get-TestProfile 'docs'); 'notes.md' = "a`r`nb`r`n" }
        ((Invoke-TestGit $r status --porcelain notes.md) -join '') | Should -Match '^ M'
        $out = Set-SLGitAttributes -Path $r
        $out.FilesStaged | Should -Contain 'notes.md'
    }

    It 'untracked files do not count as dirty' {
        $r = New-TestRepo 'set-untracked' @{ 'README.md' = "one`n" } -Commit
        Add-TestFiles -Path $r -Files @{ 'scratch.txt' = "not tracked`n" }
        (Set-SLGitAttributes -Path $r).Action | Should -Be 'Created'
        ((Invoke-TestGit $r status --porcelain scratch.txt) -join '') | Should -Match '^\?\?'
    }

    It '-WhatIf changes nothing' {
        $r = New-TestRepo 'set-whatif' @{ 'notes.md' = "a`r`nb`r`n" } -Commit
        $head = Get-Head $r
        $out = Set-SLGitAttributes -Path $r -WhatIf
        $out.Action | Should -Be 'Created'
        $out.Applied | Should -BeFalse
        Join-Path $r '.gitattributes' | Should -Not -Exist
        (Invoke-TestGit $r status --porcelain) | Should -BeNullOrEmpty
        Get-Head $r | Should -Be $head
    }

    It '-SkipRenormalize writes the file and stages nothing' {
        $r = New-TestRepo 'set-skip' @{ 'notes.md' = "a`r`n" } -Commit
        $out = Set-SLGitAttributes -Path $r -SkipRenormalize
        $out.Action | Should -Be 'Created'
        $out.FilesStaged | Should -BeNullOrEmpty
        ((Invoke-TestGit $r status --porcelain) -join "`n") | Should -Match '\?\? \.gitattributes'
    }

    It 'does nothing when the repo already matches' {
        $r = New-TestRepo 'set-noop' @{ '.gitattributes' = (Get-TestProfile 'docs') } -Commit
        $out = Set-SLGitAttributes -Path $r
        $out.Action | Should -Be 'Unchanged'
        $out.Applied | Should -BeFalse
        (Invoke-TestGit $r status --porcelain) | Should -BeNullOrEmpty
    }

    It 'takes Test-SLRepo -PassThru objects from the pipeline' {
        $parent = Join-Path $TestDrive 'pipe'
        $a = New-TestRepo (Join-Path $parent 'needs-it') @{ 'README.md' = "x`n" } -Commit
        [void] (New-TestRepo (Join-Path $parent 'fine') @{ '.gitattributes' = (Get-TestProfile 'docs') } -Commit)
        $out = @(Test-SLRepo -Path $parent -PassThru -Quiet | Where-Object Status -eq 'MISSING' | Set-SLGitAttributes)
        $out | Should -HaveCount 1
        $out[0].Path | Should -Be $a
        Join-Path $a '.gitattributes' | Should -Exist
    }

    It 'says so when -Path is not a repo' {
        $d = Join-Path $TestDrive 'not-a-repo'
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        { Set-SLGitAttributes -Path $d -ErrorAction Stop } | Should -Throw '*not the top folder of a git repo*'
    }
}

Describe 'Test-SecondLine -RepoPath' -Skip:$noGit {
    BeforeAll {
        $pwshPath = (Get-Process -Id $PID).Path
        $self     = $PSVersionTable.PSVersion
        $tool     = [IO.Path]::GetFileNameWithoutExtension($pwshPath)
        $toolLine = "@{ Name='shell'; Command='$tool'; Arguments='-NoProfile -Command `$PSVersionTable.PSVersion.ToString()'; Expect='$($self.Major).$($self.Minor)'; Rule='Minor' }"
        $parent   = Join-Path $TestDrive 'tsl'
        [void] (New-TestRepo (Join-Path $parent 'good') @{ '.gitattributes' = (Get-TestProfile 'docs') } -Commit)
        [void] (New-TestRepo (Join-Path $parent 'bare') @{ 'README.md' = "x`n" } -Commit)
    }

    It 'without -RepoPath behaves as before: tool results only, same shape' {
        $p = New-TestStandard "@{ Tools = @( $toolLine ); GitAttributes = @{ Repos = @{ good = 'docs' } } }"
        $r = @(Test-SecondLine -Path $p -PassThru -Quiet)
        $r | Should -HaveCount 1
        $r[0].Status | Should -Be 'OK'
        ($r[0].PSObject.Properties.Name -join ',') | Should -Be 'Name,Status,Found,Expect,Rule,Path,Note,Install'
    }

    It 'adds one row per repo, shaped like a tool result' {
        $p = New-TestStandard "@{ Tools = @( $toolLine ) }"
        $r = @(Test-SecondLine -Path $p -RepoPath $parent -PassThru -Quiet)
        $r | Should -HaveCount 3
        ($r | Where-Object Name -eq 'repo good').Status | Should -Be 'OK'
        $bare = $r | Where-Object Name -eq 'repo bare'
        $bare.Status | Should -Be 'MISSING'
        $bare.Install | Should -Match 'Set-SLGitAttributes'
    }

    It '-Strict counts repos' {
        $p = New-TestStandard "@{ Tools = @( $toolLine ) }"
        { Test-SecondLine -Path $p -RepoPath $parent -Quiet -Strict } | Should -Throw '*repo bare (MISSING)*'
        { Test-SecondLine -Path $p -RepoPath (Join-Path $parent 'good') -Quiet -Strict } | Should -Not -Throw
    }

    It 'works with a GitAttributes-only standard' {
        $p = New-TestStandard "@{ GitAttributes = @{ Repos = @{ bare = 'docs' } } }"
        $r = @(Test-SecondLine -Path $p -RepoPath $parent -PassThru -Quiet)
        $r | Should -HaveCount 2
    }

    It 'prints the report without errors' {
        Mock Write-Host { } -ModuleName SecondLine
        $p = New-TestStandard "@{ Tools = @( $toolLine ) }"
        { Test-SecondLine -Path $p -RepoPath $parent } | Should -Not -Throw
        Should -Invoke Write-Host -ModuleName SecondLine -ParameterFilter { "$Object" -match 'of 1 tools OK, 1 of 2 repos OK' }
    }
}
