# The shared development policy, status checkpoints, and the audit of how a repo
# refers to them (Test-SLPolicyReference).
#
# A reviewed policy copy starts with a header that makes it verifiable offline:
#   <!-- SecondLine-Policy: version=1 sha256=<hex> -->
# The hash covers the lines after the header, joined with LF, so a CRLF checkout of
# the same text verifies too. Entry points (CLAUDE.md, AGENTS.md) name the copy and
# the checkpoint with marker lines:
#   SecondLine-Policy: 1 docs/shared-development-policy.md
#   SecondLine-Status: docs/status/current.md

$script:SLPolicyHeader = '^<!--\s*SecondLine-Policy:\s*version=(?<version>\d+)\s+sha256=(?<hash>[0-9a-fA-F]{64}|PENDING)\s*-->\s*$'
$script:SLPolicyMarker = '(?m)^\s*SecondLine-Policy:\s*(?<version>\S+)\s+(?<path>\S+)\s*$'
$script:SLStatusMarker = '(?m)^\s*SecondLine-Status:\s*(?<path>\S+)\s*$'
$script:SLEntryPoints = @('CLAUDE.md', 'AGENTS.md')
$script:SLStatusSections = @('Position', 'Completed', 'Remaining', 'Changed files', 'Verification', 'Blockers', 'Next action')
# Shapes of real secrets. A match is reported by kind, never echoed.
$script:SLCredentialPatterns = [ordered]@{
    'private key'          = '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    'GitHub token'         = '\b(ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{20,}'
    'NuGet/Gallery key'    = '\boy2[a-z0-9]{43}\b'
    'AWS access key'       = '\bAKIA[0-9A-Z]{16}\b'
    'connection password'  = '(?i)(password|pwd)\s*=\s*[^;\s]{4,}'
    'assigned secret'      = '(?i)\b(api[_-]?key|secret|token)\b\s*[:=]\s*["'']?[A-Za-z0-9+/_\-]{16,}'
    'credentials in a URL' = '(?i)\b[a-z][a-z0-9+.-]*://[^/\s:@]+:[^/\s@]+@'
}

# The policy text shipped with this module: Policy\ in the package, docs\ in a checkout.
function Get-SLShippedPolicyPath {
    $base = Split-Path $PSScriptRoot -Parent
    foreach ($candidate in @((Join-Path $base 'Policy\shared-development-policy.md'), (Join-Path (Split-Path $base -Parent) 'docs\shared-development-policy.md'))) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Get-SLStatusTemplatePath { return (Join-Path (Split-Path $PSScriptRoot -Parent) 'Policy\status-template.md') }

# SHA-256 (lowercase hex) of policy body lines, joined with LF and ending with LF.
function Get-SLPolicyHash {
    param([AllowEmptyCollection()] [string[]] $BodyLines)
    $text = (@($BodyLines) -join "`n") + "`n"
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)) } finally { $sha.Dispose() }
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

# A policy file's Version, declared Hash, ActualHash, HasHeader and Modified.
function Read-SLPolicyFile {
    param([Parameter(Mandatory)] [string] $Path)
    $lines = @(Read-SLTextLines -Path $Path)
    $result = [pscustomobject]@{ Path = $Path; HasHeader = $false; Version = $null; Hash = $null; ActualHash = $null; Modified = $false }
    if ($lines.Count -eq 0 -or $lines[0] -notmatch $script:SLPolicyHeader) { return $result }
    $result.HasHeader = $true
    $result.Version = [int] $Matches['version']
    $result.Hash = $Matches['hash'].ToLowerInvariant()
    $result.ActualHash = Get-SLPolicyHash -BodyLines @($lines | Select-Object -Skip 1)
    $result.Modified = $result.Hash -ne $result.ActualHash
    return $result
}

function New-SLPolicyFinding {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Returns a new in-memory object; changes no state.')]
    param([string] $Severity, [string] $Kind, [string] $File, [string] $Detail)
    return [pscustomobject]@{ Severity = $Severity; Kind = $Kind; File = $File; Detail = $Detail }
}

# True for paths that only work on one machine: rooted, home-relative, or leaving the repo.
function Test-SLNonPortablePath {
    param([string] $Value)
    return ([IO.Path]::IsPathRooted($Value) -or $Value -match '^(~|\$|%)' -or $Value -match '(^|[\\/])\.\.([\\/]|$)' -or $Value -match '^[A-Za-z]:')
}

# Audits one repo's entry points, policy copy, checkpoint, bootstrap copies and imports.
function Get-SLPolicyAudit {
    param([Parameter(Mandatory)] [string] $RepoPath)
    $findings = New-Object System.Collections.Generic.List[object]
    $shipped = $null
    $shippedPath = Get-SLShippedPolicyPath
    if ($shippedPath) { $shipped = Read-SLPolicyFile -Path $shippedPath }

    $markers = @{}
    foreach ($name in $script:SLEntryPoints) {
        $file = Join-Path $RepoPath $name
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            $findings.Add((New-SLPolicyFinding 'Error' 'EntryMissing' $name "$name is missing; Claude and Codex need equivalent entry points."))
            continue
        }
        $text = (Read-SLTextLines -Path $file) -join "`n"
        $policy = [regex]::Match($text, $script:SLPolicyMarker)
        $status = [regex]::Match($text, $script:SLStatusMarker)
        $markers[$name] = [pscustomobject]@{
            Policy  = $(if ($policy.Success) { "$($policy.Groups['version'].Value) $($policy.Groups['path'].Value)" } else { $null })
            Version = $policy.Groups['version'].Value
            Path    = $policy.Groups['path'].Value
            Status  = $(if ($status.Success) { $status.Groups['path'].Value } else { $null })
        }
        if (-not $policy.Success) { $findings.Add((New-SLPolicyFinding 'Error' 'PolicyReferenceMissing' $name "No 'SecondLine-Policy: <version> <path>' line.")) }
        if (-not $status.Success) { $findings.Add((New-SLPolicyFinding 'Error' 'StatusReferenceMissing' $name "No 'SecondLine-Status: docs/status/current.md' line.")) }
        foreach ($m in [regex]::Matches($text, '(?im)([A-Za-z]:\\|/(Users|home)/)[^\s`"'')]*shared-development-policy[^\s`"'')]*')) {
            $findings.Add((New-SLPolicyFinding 'Error' 'PolicyReferenceNotPortable' $name "Refers to a machine-specific policy path ($($m.Value)); use a reviewed copy in the repo."))
        }
    }
    $present = @($script:SLEntryPoints | Where-Object { $markers.ContainsKey($_) })
    if ($present.Count -eq 2) {
        $a = $markers[$present[0]]; $b = $markers[$present[1]]
        if ($a.Policy -ne $b.Policy -or $a.Status -ne $b.Status) {
            $findings.Add((New-SLPolicyFinding 'Error' 'EntryMismatch' "$($present -join ', ')" "Entry points differ: $($present[0]) has '$($a.Policy)' / '$($a.Status)', $($present[1]) has '$($b.Policy)' / '$($b.Status)'."))
        }
    }

    # The policy copy each distinct reference points at.
    foreach ($ref in @($markers.Values | Where-Object Policy | Group-Object Policy)) {
        $m = $ref.Group[0]
        if (Test-SLNonPortablePath $m.Path) {
            $findings.Add((New-SLPolicyFinding 'Error' 'PolicyReferenceNotPortable' $m.Path 'The policy path must be relative and inside the repo, so CI and other machines can read it.'))
            continue
        }
        $copy = Join-Path $RepoPath $m.Path
        if (-not (Test-Path -LiteralPath $copy -PathType Leaf)) {
            $findings.Add((New-SLPolicyFinding 'Error' 'PolicyReferenceBroken' $m.Path 'The referenced policy file does not exist. Export a reviewed copy with Export-SLPolicy.'))
            continue
        }
        $info = Read-SLPolicyFile -Path $copy
        if (-not $info.HasHeader) {
            $findings.Add((New-SLPolicyFinding 'Error' 'PolicyHeaderMissing' $m.Path 'No SecondLine-Policy version header; it cannot be verified. Export it with Export-SLPolicy.'))
            continue
        }
        if ("$($info.Version)" -ne $m.Version) {
            $findings.Add((New-SLPolicyFinding 'Error' 'PolicyVersionMismatch' $m.Path "Entry points reference version $($m.Version); the copy is version $($info.Version)."))
        }
        if ($info.Modified) {
            $findings.Add((New-SLPolicyFinding 'Warning' 'PolicyModified' $m.Path 'The copy differs from its reviewed text (hash mismatch). Put local rules in the entry points, not the shared policy.'))
        }
        if ($shipped -and $shipped.HasHeader -and $info.Version -lt $shipped.Version) {
            $findings.Add((New-SLPolicyFinding 'Warning' 'PolicyOutdated' $m.Path "Version $($info.Version); this SecondLine ships version $($shipped.Version). Review it, then update with Export-SLPolicy."))
        }
    }

    # The checkpoint.
    foreach ($statusPath in @($markers.Values | Where-Object Status | ForEach-Object { $_.Status } | Sort-Object -Unique)) {
        if (Test-SLNonPortablePath $statusPath) {
            $findings.Add((New-SLPolicyFinding 'Error' 'StatusReferenceNotPortable' $statusPath 'The checkpoint path must be relative and inside the repo.'))
            continue
        }
        $file = Join-Path $RepoPath $statusPath
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            $findings.Add((New-SLPolicyFinding 'Error' 'StatusMissing' $statusPath 'The checkpoint does not exist. Create it with New-SLStatusCheckpoint.'))
            continue
        }
        foreach ($f in @(Test-SLStatusCheckpoint -Path $file -Label $statusPath)) { $findings.Add($f) }
    }

    # Bootstrap copies and hardcoded imports, in tracked PowerShell and CI files.
    $tracked = @()
    if (Test-SLGitRepo $RepoPath) {
        $r = Invoke-SLGit -RepoPath $RepoPath -Arguments @('ls-files', '-z', '--', '*.ps1', '*.psm1', '*.yml', '*.yaml')
        if ($r.ExitCode -eq 0) { $tracked = @($r.Output -split "`0" | Where-Object { $_ }) }
    }
    foreach ($rel in $tracked) {
        $full = Join-Path $RepoPath $rel
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        $text = [IO.File]::ReadAllText($full)
        $boot = [regex]::Match($text, 'SecondLine-Bootstrap:\s*(\d+)')
        if ($boot.Success -and [int] $boot.Groups[1].Value -lt $script:SLBootstrapVersion) {
            $findings.Add((New-SLPolicyFinding 'Warning' 'BootstrapOutdated' $rel "Bootstrap format $($boot.Groups[1].Value); this SecondLine ships $script:SLBootstrapVersion."))
        }
        foreach ($m in [regex]::Matches($text, '(?im)^[^#\r\n]*Import-Module\s+(-Name\s+)?[''"]?SecondLine\b[^\r\n]*-(RequiredVersion|MinimumVersion|MaximumVersion)\b[^\r\n]*')) {
            $findings.Add((New-SLPolicyFinding 'Warning' 'HardcodedVersion' $rel "Pins SecondLine in the script ($($m.Value.Trim())). Move the version to ModuleVersions in the standard and import with the bootstrap."))
        }
    }

    $list = $findings.ToArray()
    return [pscustomobject]@{
        PSTypeName = 'SecondLine.PolicyCheck'
        Repo       = Split-Path $RepoPath -Leaf
        Path       = $RepoPath
        Findings   = $list
        Ok         = @($list | Where-Object Severity -eq 'Error').Count -eq 0
    }
}

# Checks a checkpoint's structure and looks for credentials.
function Test-SLStatusCheckpoint {
    param([Parameter(Mandatory)] [string] $Path, [string] $Label)
    if (-not $Label) { $Label = $Path }
    $lines = @(Read-SLTextLines -Path $Path)
    $text = $lines -join "`n"
    $headings = @($lines | Where-Object { $_ -match '^##\s+' } | ForEach-Object { ($_ -replace '^##\s+', '').Trim() })
    $missing = @($script:SLStatusSections | Where-Object { $headings -notcontains $_ })
    if ($missing.Count -gt 0) {
        New-SLPolicyFinding 'Error' 'StatusIncomplete' $Label "Missing section(s): $($missing -join ', ')."
    }
    foreach ($field in 'Branch', 'Base commit') {
        if ($text -notmatch "(?im)^[ \t]*-[ \t]*$([regex]::Escape($field)):[ \t]*\S") {
            New-SLPolicyFinding 'Error' 'StatusIncomplete' $Label "Position has no '$($field):' value."
        }
    }
    if ($text -notmatch '(?im)^\s*-\s*(Verified|Planned)\b') {
        New-SLPolicyFinding 'Warning' 'StatusUnlabelled' $Label "Verification items should start with 'Verified' or 'Planned', so results and plans aren't confused."
    }
    foreach ($kind in $script:SLCredentialPatterns.Keys) {
        if ($text -match $script:SLCredentialPatterns[$kind]) {
            New-SLPolicyFinding 'Error' 'StatusCredential' $Label "Looks like it contains a $kind. Remove it; checkpoints must never hold credentials."
        }
    }
}
