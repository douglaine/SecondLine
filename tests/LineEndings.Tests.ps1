#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# Test-SLLineEnding and Repair-SLLineEnding against throwaway repos in TestDrive,
# each with its own git config. Files are written byte for byte.

BeforeDiscovery {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'SecondLine\SecondLine.psd1') -Force
    $noGit = -not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)
}
BeforeAll {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'SecondLine\SecondLine.psd1') -Force
    # Stop EditorConfig lookups at TestDrive, so files above it on this machine can't matter.
    [IO.File]::WriteAllText((Join-Path $TestDrive '.editorconfig'), "root = true`n")

    function Invoke-TestGit {
        param([string] $Repo, [Parameter(ValueFromRemainingArguments)] [string[]] $Rest)
        $out = & { $ErrorActionPreference = 'Continue'; & git -C $Repo @Rest 2>&1 }
        return @($out | ForEach-Object { "$_" })
    }
    function Set-Bytes([string] $Path, [byte[]] $Bytes) {
        New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null
        [IO.File]::WriteAllBytes($Path, $Bytes)
    }
    function Set-Text([string] $Path, [string] $Text) { Set-Bytes $Path ([Text.Encoding]::UTF8.GetBytes($Text)) }
    # A repo with the given files (name -> text, written as UTF-8 without BOM), committed if -Commit.
    function New-EolRepo {
        param([hashtable] $Files = @{}, [switch] $Commit, [string] $Parent = $TestDrive)
        $path = Join-Path $Parent ("r" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $path | Out-Null
        [void] (Invoke-TestGit $path init -q)
        foreach ($c in @(@('user.name', 'SecondLine Test'), @('user.email', 'test@example.com'), @('core.autocrlf', 'false'), @('commit.gpgsign', 'false'), @('core.hooksPath', '.no-hooks'))) {
            [void] (Invoke-TestGit $path config $c[0] $c[1])
        }
        foreach ($name in $Files.Keys) { Set-Text (Join-Path $path $name) $Files[$name] }
        if ($Commit) { [void] (Invoke-TestGit $path add -A); [void] (Invoke-TestGit $path commit -q -m init) }
        return $path
    }
    function Get-Audit([string] $Repo) { return (Test-SLLineEnding -Path $Repo -PassThru -Quiet) }
    function Get-Kinds($Audit, [string] $File) { return @($Audit.Issues | Where-Object File -eq $File | ForEach-Object Kind) }
    $script:attrs = "* text=auto`n*.md text eol=lf`n*.ps1 text eol=crlf`n*.png binary`n"
}

Describe 'EditorConfig globs' {
    InModuleScope SecondLine {
        It 'matches <glob> against <path>: <expected>' -ForEach @(
            @{ glob = '*'; path = 'a/b/c.txt'; expected = $true }
            @{ glob = '*.md'; path = 'docs/readme.md'; expected = $true }
            @{ glob = '*.md'; path = 'docs/readme.mdx'; expected = $false }
            @{ glob = '*.{ps1,psm1}'; path = 'src/m.psm1'; expected = $true }
            @{ glob = '/root.md'; path = 'root.md'; expected = $true }
            @{ glob = '/root.md'; path = 'sub/root.md'; expected = $false }
            @{ glob = 'lib/**.js'; path = 'lib/a/b/c.js'; expected = $true }
            @{ glob = 'src/**/x.cs'; path = 'src/x.cs'; expected = $true }
            @{ glob = 'file[!0-9].txt'; path = 'filea.txt'; expected = $true }
            @{ glob = 'file[!0-9].txt'; path = 'file1.txt'; expected = $false }
            @{ glob = 'v{1..3}.txt'; path = 'v2.txt'; expected = $true }
            @{ glob = 'v{1..3}.txt'; path = 'v4.txt'; expected = $false }
            @{ glob = 'a?c'; path = 'a/c'; expected = $false }
        ) {
            Test-SLEditorConfigMatch -Compiled (ConvertTo-SLEditorConfigRegex -Glob $glob) -RelativePath $path | Should -Be $expected
        }
    }
}

Describe 'Test-SLLineEnding' -Skip:$noGit {
    It 'accepts intentional per-type LF and CRLF, and skips binaries' {
        $repo = New-EolRepo -Files @{ '.gitattributes' = $attrs; 'a.md' = "x`n"; 'b.ps1' = "x`r`n"; 'c.txt' = "x`r`n" }
        Set-Bytes (Join-Path $repo 'logo.png') ([byte[]] @(137, 80, 78, 71, 13, 10, 26, 10, 0, 13, 10))
        Set-Bytes (Join-Path $repo 'blob.dat') ([byte[]] @(1, 0, 13, 10, 10, 0, 2))
        [void] (Invoke-TestGit $repo add -A); [void] (Invoke-TestGit $repo commit -q -m init)
        $audit = Get-Audit $repo
        $audit.Issues | Should -BeNullOrEmpty
        $audit.Binary | Should -Be 2
        Test-SLLineEnding -Path $repo -Quiet | Should -BeTrue
    }
    It 'reports LF where CRLF is declared, CRLF where LF is declared, and mixed files' {
        $repo = New-EolRepo -Files @{ '.gitattributes' = $attrs; 'a.md' = "x`r`ny`r`n"; 'b.ps1' = "x`ny`n"; 'c.txt' = "x`r`ny`n" } -Commit
        $audit = Get-Audit $repo
        Get-Kinds $audit 'a.md' | Should -Contain 'WrongEnding'
        Get-Kinds $audit 'b.ps1' | Should -Contain 'WrongEnding'
        Get-Kinds $audit 'c.txt' | Should -Be @('Mixed')
        ($audit.Issues | Where-Object File -eq 'b.ps1').Expected | Should -Be 'crlf'
        Test-SLLineEnding -Path $repo -Quiet | Should -BeFalse
        { Test-SLLineEnding -Path $repo -Quiet -Strict } | Should -Throw '*1 of 1 repos have issues*'
    }
    It 'distinguishes git''s stored normalization from the working copy' {
        $repo = New-EolRepo -Files @{ 'old.txt' = "x`r`ny`r`n" } -Commit
        Set-Text (Join-Path $repo '.gitattributes') "*.txt text eol=crlf`n"
        $audit = Get-Audit $repo
        Get-Kinds $audit 'old.txt' | Should -Be @('Renormalize')
        ($audit.Issues | Where-Object Kind -eq 'Renormalize').Actual | Should -Be 'crlf'
    }
    It 'checks untracked files by default, and only tracked ones with -TrackedOnly' {
        $repo = New-EolRepo -Files @{ '.gitattributes' = $attrs } -Commit
        Set-Text (Join-Path $repo 'new.ps1') "x`n"
        $issue = (Get-Audit $repo).Issues | Where-Object File -eq 'new.ps1'
        $issue.Kind | Should -Be WrongEnding
        $issue.Tracked | Should -BeFalse
        (Test-SLLineEnding -Path $repo -TrackedOnly -PassThru -Quiet).Issues | Should -BeNullOrEmpty
    }
    It 'uses a parent .editorconfig when .gitattributes has no eol rule' {
        $parent = Join-Path $TestDrive ("ec" + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Path $parent | Out-Null
        Set-Text (Join-Path $parent '.editorconfig') "root = true`n[*.cs]`nend_of_line = crlf`n"
        $repo = New-EolRepo -Parent $parent -Files @{ '.gitattributes' = "* text=auto`n"; 'a.cs' = "x`n"; 'b.txt' = "x`n" } -Commit
        $audit = Get-Audit $repo
        $issue = $audit.Issues | Where-Object File -eq 'a.cs'
        $issue.Kind | Should -Be WrongEnding
        $issue.Source | Should -BeLike '*.editorconfig:3'
        Get-Kinds $audit 'b.txt' | Should -BeNullOrEmpty
    }
    It 'lets a nearer .editorconfig override a parent, and stops at root = true' {
        $repo = New-EolRepo -Files @{ '.gitattributes' = "* text=auto`n"; 'sub/a.cs' = "x`r`n" } -Commit
        Set-Text (Join-Path $repo '.editorconfig') "root = true`n[*]`nend_of_line = lf`n"
        Set-Text (Join-Path $repo 'sub\.editorconfig') "[*.cs]`nend_of_line = crlf`n"
        (Get-Audit $repo).Issues | Should -BeNullOrEmpty
    }
    It 'reports .editorconfig that conflicts with .gitattributes' {
        $repo = New-EolRepo -Files @{ '.gitattributes' = $attrs; 'a.md' = "x`n"; 'b.ps1' = "x`r`n" } -Commit
        Set-Text (Join-Path $repo '.editorconfig') "root = true`n[*]`nend_of_line = lf`n"
        $audit = Get-Audit $repo
        Get-Kinds $audit 'b.ps1' | Should -Be @('EditorConfigConflict')
        Get-Kinds $audit 'a.md' | Should -BeNullOrEmpty
    }
    It 'reports explicit VS Code files.eol conflicts, reading comments and per-language settings' {
        $repo = New-EolRepo -Files @{ '.gitattributes' = $attrs; 'a.md' = "x`n"; 'b.ps1' = "x`r`n" } -Commit
        Set-Text (Join-Path $repo '.vscode\settings.json') "{`n  // team default`n  `"files.eol`": `"\r\n`", /* trailing */`n  `"[markdown]`": { `"files.eol`": `"\n`" },`n}`n"
        (Get-Audit $repo).Issues | Should -BeNullOrEmpty
        Set-Text (Join-Path $repo '.vscode\settings.json') "{ `"files.eol`": `"\r\n`" }"
        $audit = Get-Audit $repo
        Get-Kinds $audit 'a.md' | Should -Be @('VSCodeConflict')
        Get-Kinds $audit 'b.ps1' | Should -BeNullOrEmpty
    }
    It 'reads settings inside a .code-workspace file' {
        $repo = New-EolRepo -Files @{ '.gitattributes' = $attrs; 'b.ps1' = "x`r`n" } -Commit
        Set-Text (Join-Path $repo 'team.code-workspace') "{ `"folders`": [ { `"path`": `".`" } ], `"settings`": { `"[powershell]`": { `"files.eol`": `"\n`" } } }"
        Get-Kinds (Get-Audit $repo) 'b.ps1' | Should -Be @('VSCodeConflict')
    }
    It 'notes the files whose ending depends on each machine' {
        $repo = New-EolRepo -Files @{ '.gitattributes' = "* text=auto`n"; 'a.txt' = "x`n" } -Commit
        (Get-Audit $repo).Notes -join ' ' | Should -Match 'core.autocrlf'
    }
}

Describe 'Repair-SLLineEnding' -Skip:$noGit {
    BeforeEach { Mock -ModuleName SecondLine Write-Host {} }
    It 'converts only endings, keeping BOM, non-ASCII bytes and a missing final newline' {
        $repo = New-EolRepo -Files @{ '.gitattributes' = $attrs } -Commit
        $file = Join-Path $repo 'tool.ps1'
        $utf8Bom = New-Object Text.UTF8Encoding($true)
        [IO.File]::WriteAllText($file, "# Gr$([char]0xFC)$([char]0xDF)e`n`$x = 'na$([char]0xEF)ve'`nWrite-Output `$x", $utf8Bom)
        $result = @(Repair-SLLineEnding -Path $repo -PassThru)
        ($result | Where-Object Target -eq 'tool.ps1').Applied | Should -BeTrue
        $expected = [byte[]] (@(0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes("# Gr$([char]0xFC)$([char]0xDF)e`r`n`$x = 'na$([char]0xEF)ve'`r`nWrite-Output `$x"))
        [IO.File]::ReadAllBytes($file) | Should -Be $expected
        (Get-Audit $repo).Issues | Should -BeNullOrEmpty
    }
    It 'repairs mixed files that have a rule and skips those that have none' {
        $repo = New-EolRepo -Files @{ '.gitattributes' = $attrs; 'a.md' = "1`r`n2`n3`r`n"; 'free.txt' = "1`r`n2`n" } -Commit
        $result = @(Repair-SLLineEnding -Path $repo -PassThru)
        [IO.File]::ReadAllText((Join-Path $repo 'a.md')) | Should -BeExactly "1`n2`n3`n"
        ($result | Where-Object Target -eq 'free.txt').Action | Should -Be Skipped
        [IO.File]::ReadAllText((Join-Path $repo 'free.txt')) | Should -BeExactly "1`r`n2`n"
    }
    It 'previews with -WhatIf and writes nothing' {
        $repo = New-EolRepo -Files @{ '.gitattributes' = $attrs; 'b.ps1' = "x`n" } -Commit
        $before = [IO.File]::ReadAllBytes((Join-Path $repo 'b.ps1'))
        $null = Repair-SLLineEnding -Path $repo -WhatIf
        [IO.File]::ReadAllBytes((Join-Path $repo 'b.ps1')) | Should -Be $before
    }
    It 'skips tracked files with uncommitted edits unless -AllowModified, and keeps the edits' {
        $repo = New-EolRepo -Files @{ '.gitattributes' = $attrs; 'b.ps1' = "one`r`n" } -Commit
        Set-Text (Join-Path $repo 'b.ps1') "one`ntwo`n"
        $first = @(Repair-SLLineEnding -Path $repo -PassThru)
        $first[0].Action | Should -Be Skipped
        [IO.File]::ReadAllText((Join-Path $repo 'b.ps1')) | Should -BeExactly "one`ntwo`n"
        $null = Repair-SLLineEnding -Path $repo -AllowModified
        [IO.File]::ReadAllText((Join-Path $repo 'b.ps1')) | Should -BeExactly "one`r`ntwo`r`n"
    }
    It 'never stages anything' {
        $repo = New-EolRepo -Files @{ '.gitattributes' = $attrs; 'b.ps1' = "x`n" } -Commit
        $null = Repair-SLLineEnding -Path $repo
        (Invoke-TestGit $repo diff --cached --name-only) | Where-Object { $_ } | Should -BeNullOrEmpty
    }
    It 'limits the repair to -File' {
        $repo = New-EolRepo -Files @{ '.gitattributes' = $attrs; 'a.ps1' = "x`n"; 'b.ps1' = "x`n" } -Commit
        $null = Repair-SLLineEnding -Path $repo -File 'a.ps1' -Scope Files
        [IO.File]::ReadAllText((Join-Path $repo 'a.ps1')) | Should -BeExactly "x`r`n"
        [IO.File]::ReadAllText((Join-Path $repo 'b.ps1')) | Should -BeExactly "x`n"
    }
    It 'changes an end_of_line in place when every file it governs agrees' {
        $repo = New-EolRepo -Files @{ '.gitattributes' = "*.txt text eol=crlf`n"; 'a.txt' = "x`r`n" } -Commit
        $ec = Join-Path $repo '.editorconfig'
        Set-Text $ec "root = true`n# keep this comment`n[*.txt]`nindent_style = space`nend_of_line = lf`n"
        $null = Repair-SLLineEnding -Path $repo -Scope Config
        [IO.File]::ReadAllText($ec) | Should -BeExactly "root = true`n# keep this comment`n[*.txt]`nindent_style = space`nend_of_line = crlf`n"
        (Get-Audit $repo).Issues | Should -BeNullOrEmpty
    }
    It 'appends a narrow section when one line governs files needing different endings' {
        $repo = New-EolRepo -Files @{ '.gitattributes' = $attrs; 'a.md' = "x`n"; 'b.ps1' = "x`r`n" } -Commit
        $ec = Join-Path $repo '.editorconfig'
        Set-Text $ec "root = true`n[*]`nend_of_line = lf`n"
        $null = Repair-SLLineEnding -Path $repo -Scope Config
        $text = [IO.File]::ReadAllText($ec)
        $text | Should -BeExactly "root = true`n[*]`nend_of_line = lf`n`n# Added by SecondLine: match .gitattributes`n[*.ps1]`nend_of_line = crlf`n"
        (Get-Audit $repo).Issues | Should -BeNullOrEmpty
    }
    It 'reports manual work instead of guessing when a section would change unrelated files' {
        $repo = New-EolRepo -Files @{ '.gitattributes' = "* text=auto`n*.ps1 text eol=crlf`n"; 'a.ps1' = "x`r`n"; 'b.txt' = "x`n" } -Commit
        $ec = Join-Path $repo '.editorconfig'
        Set-Text $ec "root = true`n[*.{ps1,txt}]`nend_of_line = lf`n"
        Set-Text (Join-Path $repo 'tool.ps1') "x`r`n"
        Set-Text (Join-Path $repo 'sub\.editorconfig') "[*.ps1]`nend_of_line = lf`n"
        Set-Text (Join-Path $repo 'sub\c.ps1') "x`r`n"
        $before = [IO.File]::ReadAllText($ec)
        $result = @(Repair-SLLineEnding -Path $repo -Scope Config -PassThru)
        $result.Action | Should -Contain 'Append'
        # The nearer sub/.editorconfig decides sub/c.ps1; the root file's new section can't fix it.
        ($result | Where-Object { $_.Target -like '*sub*' }).Action | Should -Contain 'Replace'
        [IO.File]::ReadAllText($ec) | Should -Not -BeExactly $before
    }
    It 'sets a VS Code files.eol to the agreed value, or auto, keeping comments' {
        $repo = New-EolRepo -Files @{ '.gitattributes' = $attrs; 'a.md' = "x`n"; 'b.ps1' = "x`r`n" } -Commit
        $vs = Join-Path $repo '.vscode\settings.json'
        Set-Text $vs "{`n  // ours`n  `"files.eol`": `"\n`",`n  `"editor.tabSize`": 4`n}`n"
        $null = Repair-SLLineEnding -Path $repo -Scope Config
        [IO.File]::ReadAllText($vs) | Should -BeExactly "{`n  // ours`n  `"files.eol`": `"auto`",`n  `"editor.tabSize`": 4`n}`n"
        Set-Text $vs "{ `"[powershell]`": { `"files.eol`": `"\n`" } }"
        $null = Repair-SLLineEnding -Path $repo -Scope Config
        [IO.File]::ReadAllText($vs) | Should -BeExactly "{ `"[powershell]`": { `"files.eol`": `"\r\n`" } }"
        (Get-Audit $repo).Issues | Should -BeNullOrEmpty
    }
}
