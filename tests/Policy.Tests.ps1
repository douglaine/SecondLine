#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# The shared policy file, portable references to it, and status checkpoints.

BeforeDiscovery {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'SecondLine\SecondLine.psd1') -Force
    $noGit = -not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)
}
BeforeAll {
    $script:repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:repoRoot 'SecondLine\SecondLine.psd1') -Force
    $script:module = Get-Module SecondLine
    $script:policySource = Join-Path $script:repoRoot 'docs\shared-development-policy.md'
    $script:entry = "# Instructions`n`nSecondLine-Policy: 1 docs/shared-development-policy.md`nSecondLine-Status: docs/status/current.md`n`nLocal rules here.`n"
    $script:status = @(
        '# Status', '', '## Position', '', '- Branch: main', '- Base commit: abc1234 init', '',
        '## Completed', '', '- Things.', '', '## Remaining', '', '- More.', '', '## Changed files', '', '- a.ps1', '',
        '## Verification', '', '- Verified: tests 10/10 (logs/test.txt)', '- Planned: lint', '',
        '## Blockers', '', '- None recorded.', '', '## Next action', '', '- Run lint.'
    ) -join "`n"

    function Set-Text([string] $Path, [string] $Text) {
        New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null
        [IO.File]::WriteAllText($Path, $Text)
    }
    # A git repo that follows the convention, with the reviewed policy copy.
    function New-PolicyRepo {
        $path = Join-Path $TestDrive ("p" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $path | Out-Null
        $null = & { $ErrorActionPreference = 'Continue'; & git -C $path init -q 2>&1 }
        Set-Text (Join-Path $path 'CLAUDE.md') $entry
        Set-Text (Join-Path $path 'AGENTS.md') $entry
        New-Item -ItemType Directory (Join-Path $path 'docs') | Out-Null
        Copy-Item $policySource (Join-Path $path 'docs\shared-development-policy.md')
        Set-Text (Join-Path $path 'docs\status\current.md') $status
        return $path
    }
    function Get-Findings([string] $Repo) { return @((Test-SLPolicyReference -Path $Repo -PassThru -Quiet).Findings) }
}

Describe 'The shared policy file' {
    It 'has a current version header (run build/Update-PolicyHeader.ps1 after editing it)' {
        $info = & $module { param($p) Read-SLPolicyFile -Path $p } $policySource
        $info.HasHeader | Should -BeTrue
        $info.Modified | Should -BeFalse -Because "the header hash must match the text; expected sha256=$($info.ActualHash)"
    }
    It 'verifies the same with CRLF line endings' {
        $crlf = Join-Path $TestDrive 'crlf-policy.md'
        [IO.File]::WriteAllText($crlf, ([IO.File]::ReadAllText($policySource) -replace "`r?`n", "`r`n"))
        (& $module { param($p) Read-SLPolicyFile -Path $p } $crlf).Modified | Should -BeFalse
    }
    It 'describes the status checkpoint convention and keeps approvals local' {
        $text = [IO.File]::ReadAllText($policySource)
        $text | Should -Match 'docs/status/current.md'
        $text | Should -Match 'not authorization'
        $text | Should -Match 'Verified'
        $text | Should -Match 'credentials'
        $text | Should -Not -Match 'C:\\Users'
    }
    It 'ships a status template with every required section' {
        $template = & $module { Get-SLStatusTemplatePath }
        foreach ($section in & $module { $script:SLStatusSections }) {
            [IO.File]::ReadAllText($template) | Should -Match "(?m)^## $([regex]::Escape($section))$"
        }
    }
}

Describe 'A repo set up with the shipped policy' -Skip:$noGit {
    It 'passes the audit with no findings' {
        $repo = New-PolicyRepo
        $check = Test-SLPolicyReference -Path $repo -Depth 0 -PassThru -Quiet
        $check.Findings | Should -BeNullOrEmpty
    }
}

Describe 'Test-SLPolicyReference' -Skip:$noGit {
    It 'passes a repo that follows the convention' {
        $repo = New-PolicyRepo
        Get-Findings $repo | Should -BeNullOrEmpty
        Test-SLPolicyReference -Path $repo -Quiet | Should -BeTrue
    }
    It 'reports a missing entry point and missing markers' {
        $repo = New-PolicyRepo
        Remove-Item (Join-Path $repo 'AGENTS.md')
        Set-Text (Join-Path $repo 'CLAUDE.md') "# Instructions`nRead docs/shared-development-policy.md.`n"
        $kinds = @(Get-Findings $repo | ForEach-Object Kind)
        $kinds | Should -Contain 'EntryMissing'
        $kinds | Should -Contain 'PolicyReferenceMissing'
        $kinds | Should -Contain 'StatusReferenceMissing'
        { Test-SLPolicyReference -Path $repo -Quiet -Strict } | Should -Throw '*have errors*'
    }
    It 'reports entry points that differ' {
        $repo = New-PolicyRepo
        Set-Text (Join-Path $repo 'AGENTS.md') ($entry -replace 'docs/status/current.md', 'STATUS.md')
        @(Get-Findings $repo | ForEach-Object Kind) | Should -Contain 'EntryMismatch'
    }
    It 'reports broken and machine-specific references' {
        $repo = New-PolicyRepo
        Remove-Item (Join-Path $repo 'docs\shared-development-policy.md')
        @(Get-Findings $repo | ForEach-Object Kind) | Should -Contain 'PolicyReferenceBroken'
        $bad = $entry -replace 'SecondLine-Policy: 1 docs/shared-development-policy.md', 'SecondLine-Policy: 1 C:\Users\someone\src\SecondLine\docs\shared-development-policy.md'
        Set-Text (Join-Path $repo 'CLAUDE.md') $bad
        Set-Text (Join-Path $repo 'AGENTS.md') $bad
        @(Get-Findings $repo | ForEach-Object Kind) | Should -Contain 'PolicyReferenceNotPortable'
        Set-Text (Join-Path $repo 'CLAUDE.md') ($entry -replace 'docs/shared', '../SecondLine/docs/shared')
        @(Get-Findings $repo | ForEach-Object Kind) | Should -Contain 'PolicyReferenceNotPortable'
    }
    It 'warns about a locally modified copy, and fails a version mismatch or missing header' {
        $repo = New-PolicyRepo
        $copy = Join-Path $repo 'docs\shared-development-policy.md'
        Add-Content $copy 'Project rule that belongs in CLAUDE.md.'
        $f = Get-Findings $repo
        ($f | Where-Object Kind -eq 'PolicyModified').Severity | Should -Be Warning
        Test-SLPolicyReference -Path $repo -Quiet | Should -BeTrue
        $both = $entry -replace 'SecondLine-Policy: 1', 'SecondLine-Policy: 2'
        Set-Text (Join-Path $repo 'CLAUDE.md') $both
        Set-Text (Join-Path $repo 'AGENTS.md') $both
        @(Get-Findings $repo | ForEach-Object Kind) | Should -Contain 'PolicyVersionMismatch'
        Set-Text $copy "# A policy with no header`n"
        @(Get-Findings $repo | ForEach-Object Kind) | Should -Contain 'PolicyHeaderMissing'
    }
    It 'warns when the copy is older than the policy this SecondLine ships' {
        $repo = New-PolicyRepo
        $newer = Join-Path $TestDrive 'newer-policy.md'
        $lines = @('<!-- SecondLine-Policy: version=9 sha256=PENDING -->', '# newer')
        $hash = & $module { param($b) Get-SLPolicyHash -BodyLines $b } @('# newer')
        Set-Text $newer ("<!-- SecondLine-Policy: version=9 sha256=$hash -->`n# newer`n")
        Mock -ModuleName SecondLine Get-SLShippedPolicyPath { $newer }.GetNewClosure()
        $f = Get-Findings $repo
        ($f | Where-Object Kind -eq 'PolicyOutdated').Detail | Should -Match 'ships version 9'
        $null = $lines
    }
    It 'checks the checkpoint: missing, incomplete, unlabelled' {
        $repo = New-PolicyRepo
        $file = Join-Path $repo 'docs\status\current.md'
        Remove-Item $file
        @(Get-Findings $repo | ForEach-Object Kind) | Should -Contain 'StatusMissing'
        Set-Text $file "# Status`n## Position`n- Branch:`n## Completed`n- x`n"
        $f = Get-Findings $repo
        ($f | Where-Object Kind -eq 'StatusIncomplete').Detail -join ' ' | Should -Match 'Remaining.*Next action'
        ($f | Where-Object Kind -eq 'StatusIncomplete').Detail -join ' ' | Should -Match "no 'Branch:' value"
        @($f | ForEach-Object Kind) | Should -Contain 'StatusUnlabelled'
    }
    It 'rejects credential-like content in the checkpoint without echoing it' {
        $repo = New-PolicyRepo
        $file = Join-Path $repo 'docs\status\current.md'
        $token = 'ghp' + '_' + ('a1B2' * 9)
        Set-Text $file ($status + "`n- Note: used $token`n")
        $finding = Get-Findings $repo | Where-Object Kind -eq 'StatusCredential'
        $finding.Detail | Should -Match 'GitHub token'
        $finding.Detail | Should -Not -Match ([regex]::Escape($token))
        Set-Text $file ($status + "`n- Db: Server=x;User Id=sa;Password=" + ('Q' * 12) + "`n")
        (Get-Findings $repo | Where-Object Kind -eq 'StatusCredential').Detail | Should -Match 'connection password'
    }
    It 'flags hardcoded SecondLine versions and outdated bootstrap copies in tracked scripts' {
        $repo = New-PolicyRepo
        Set-Text (Join-Path $repo 'build\run.ps1') "Import-Module SecondLine -RequiredVersion 0.3.0`n# Import-Module SecondLine -RequiredVersion 0.1.0 (comment, ignored)`n"
        Set-Text (Join-Path $repo 'build\Import-SecondLine.ps1') "# SecondLine-Bootstrap: 0`n"
        $null = & { $ErrorActionPreference = 'Continue'; & git -C $repo add -A 2>&1 }
        $f = Get-Findings $repo
        @($f | Where-Object Kind -eq 'HardcodedVersion').Count | Should -Be 1
        ($f | Where-Object Kind -eq 'BootstrapOutdated').File | Should -Be 'build/Import-SecondLine.ps1'
        Test-SLPolicyReference -Path $repo -Quiet | Should -BeTrue
    }
}

Describe 'Export-SLPolicy and New-SLStatusCheckpoint' -Skip:$noGit {
    BeforeEach { Mock -ModuleName SecondLine Write-Host {} }
    It 'exports a verifiable copy, leaves entry points alone, and is idempotent' {
        $repo = Join-Path $TestDrive ("e" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory $repo | Out-Null
        Set-Text (Join-Path $repo 'CLAUDE.md') "# mine`n"
        (Export-SLPolicy -Path $repo -PassThru).Action | Should -Be Created
        (& $module { param($p) Read-SLPolicyFile -Path $p } (Join-Path $repo 'docs\shared-development-policy.md')).Modified | Should -BeFalse
        [IO.File]::ReadAllText((Join-Path $repo 'CLAUDE.md')) | Should -BeExactly "# mine`n"
        (Export-SLPolicy -Path $repo -PassThru).Action | Should -Be Unchanged
    }
    It 'refuses to overwrite a modified copy unless -Force, and previews with -WhatIf' {
        $repo = Join-Path $TestDrive ("e" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory $repo | Out-Null
        $null = Export-SLPolicy -Path $repo
        $copy = Join-Path $repo 'docs\shared-development-policy.md'
        Add-Content $copy 'local edit'
        $before = [IO.File]::ReadAllBytes($copy)
        (Export-SLPolicy -Path $repo -PassThru -WarningAction SilentlyContinue).Action | Should -Be Refused
        [IO.File]::ReadAllBytes($copy) | Should -Be $before
        $null = Export-SLPolicy -Path $repo -Force -WhatIf
        [IO.File]::ReadAllBytes($copy) | Should -Be $before
        (Export-SLPolicy -Path $repo -Force -PassThru).Applied | Should -BeTrue
        { Export-SLPolicy -Path $repo -Destination 'C:\elsewhere\policy.md' } | Should -Throw '*relative path inside the repo*'
    }
    It 'creates a checkpoint that passes the audit, and never overwrites one' {
        $repo = Join-Path $TestDrive ("s" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory $repo | Out-Null
        $null = & { $ErrorActionPreference = 'Continue'; & git -C $repo init -q 2>&1; & git -C $repo -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false commit -q --allow-empty -m first 2>&1 }
        New-SLStatusCheckpoint -Path $repo
        $file = Join-Path $repo 'docs\status\current.md'
        [IO.File]::ReadAllText($file) | Should -Match '(?m)^- Base commit: [0-9a-f]+ first$'
        @(& $module { param($p) Test-SLStatusCheckpoint -Path $p } $file | Where-Object Severity -eq 'Error') | Should -BeNullOrEmpty
        { New-SLStatusCheckpoint -Path $repo } | Should -Throw '*already exists*'
    }
}
