# .gitattributes profiles, parsing and comparison, and the git calls behind
# Test-SLRepo and Set-SLGitAttributes.
#
# A .gitattributes file is compared by meaning, not text: each pattern maps to a
# set of attributes, so comments, blank lines, spacing, order and duplicate lines
# don't matter. 'binary' is git's macro for '-diff -merge -text'.

$script:SLProfileDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'Profiles\gitattributes'

# Folders never searched when looking for repos or project files.
$script:SLSkipDirs = @('.git', 'node_modules', 'bin', 'obj', 'packages')

$script:SLGitInstall = 'winget install --id Git.Git -e'

# --------------------------------------------------------------- profiles --

# Built-in profiles: name -> lines, read from Profiles\gitattributes\<name>.gitattributes.
function Get-SLBuiltInProfiles {
    $profiles = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $script:SLProfileDir -Filter '*.gitattributes' -File -ErrorAction SilentlyContinue)) {
        $profiles[$file.BaseName] = @(Read-SLTextLines -Path $file.FullName)
    }
    return $profiles
}

# Built-in profiles, plus or replaced by the standard's GitAttributes.Profiles.
function Get-SLProfiles {
    param($Standard)
    $profiles = Get-SLBuiltInProfiles
    if ($Standard -and $Standard.GitAttributes) {
        foreach ($name in @($Standard.GitAttributes.Profiles.Keys)) {
            $profiles[$name] = @($Standard.GitAttributes.Profiles[$name])
        }
    }
    return $profiles
}

# Reads a text file as UTF-8 (a BOM is dropped) and returns its lines.
function Read-SLTextLines {
    param([Parameter(Mandatory)] [string] $Path)
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    if ($text.Length -gt 0 -and $text[0] -eq [char] 0xFEFF) { $text = $text.Substring(1) }
    $lines = @($text -split "`r?`n")
    # A final newline leaves an empty last element; it isn't a line.
    if ($lines.Count -gt 0 -and $lines[-1] -eq '') { $lines = @($lines | Select-Object -First ($lines.Count - 1)) }
    return $lines
}

# Writes lines as UTF-8 without BOM, LF endings, final newline. Same bytes in 5.1 and 7.
function Write-SLTextLines {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]] $Lines)
    $text = ($Lines -join "`n") + "`n"
    [IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding($false)))
}

# ---------------------------------------------------------------- parsing --

# Splits one .gitattributes line into pattern and attribute tokens.
# Returns $null for blank lines, comments and [attr] macro definitions.
function Split-SLAttributeLine {
    param([string] $Line)
    $t = $Line.Trim()
    if (-not $t -or $t.StartsWith('#') -or $t.StartsWith('[attr]')) { return $null }

    $pattern = ''
    $rest = ''
    if ($t.StartsWith('"')) {
        # C-style quoted pattern, for names with spaces.
        $sb = New-Object Text.StringBuilder
        $i = 1
        while ($i -lt $t.Length -and $t[$i] -ne '"') {
            if ($t[$i] -eq '\' -and $i + 1 -lt $t.Length) { $i++ }
            [void] $sb.Append($t[$i])
            $i++
        }
        $pattern = $sb.ToString()
        if ($i + 1 -lt $t.Length) { $rest = $t.Substring($i + 1) }
    }
    else {
        $parts = $t -split '\s+', 2
        $pattern = $parts[0]
        if ($parts.Count -gt 1) { $rest = $parts[1] }
    }
    $tokens = @($rest -split '\s+' | Where-Object { $_ })
    return [pscustomobject]@{ Pattern = $pattern; Tokens = $tokens }
}

# Expands tokens into name -> canonical token ('text', '-text', '!text', 'eol=lf').
# Later tokens win, as in git. 'binary' becomes -diff -merge -text.
function Add-SLAttributeTokens {
    param([Parameter(Mandatory)] [hashtable] $Set, [string[]] $Tokens)
    foreach ($tok in $Tokens) {
        if ($tok -eq 'binary') {
            foreach ($b in '-diff', '-merge', '-text') { $Set[$b.Substring(1)] = $b }
            continue
        }
        $name = $tok
        if ($tok.StartsWith('-') -or $tok.StartsWith('!')) { $name = $tok.Substring(1) }
        elseif ($tok.Contains('=')) { $name = $tok.Split('=')[0] }
        if ($name) { $Set[$name] = $tok }
    }
}

# One attribute set as text, in a stable order: text, eol, then the rest by name.
# -diff -merge -text is shown as 'binary', the way it's usually written.
function Format-SLAttributeSet {
    param([hashtable] $Set)
    $s = $Set.Clone()
    $out = @()
    if ($s['diff'] -ceq '-diff' -and $s['merge'] -ceq '-merge' -and $s['text'] -ceq '-text') {
        $out += 'binary'
        foreach ($n in 'diff', 'merge', 'text') { $s.Remove($n) }
    }
    foreach ($n in 'text', 'eol') {
        if ($s.ContainsKey($n)) { $out += $s[$n]; $s.Remove($n) }
    }
    $out += @(@($s.Keys) | Sort-Object | ForEach-Object { $s[$_] })
    return ($out -join ' ')
}

# Parses .gitattributes lines into rules, one per pattern, in first-seen order:
#   Pattern, Attributes (name -> token), Tokens (as written, for writing back), Lines (indexes).
# The same pattern on several lines is merged attribute by attribute, later lines winning.
function ConvertFrom-SLGitAttributes {
    param([AllowEmptyCollection()] [string[]] $Lines)
    $rules = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
    for ($i = 0; $i -lt @($Lines).Count; $i++) {
        $parsed = Split-SLAttributeLine $Lines[$i]
        if (-not $parsed) { continue }
        if (-not $rules.Contains($parsed.Pattern)) {
            $rules[$parsed.Pattern] = [pscustomobject]@{
                Pattern    = $parsed.Pattern
                Attributes = @{}
                Tokens     = @()
                Lines      = @()
            }
        }
        $rule = $rules[$parsed.Pattern]
        Add-SLAttributeTokens -Set $rule.Attributes -Tokens $parsed.Tokens
        foreach ($tok in $parsed.Tokens) { if ($rule.Tokens -notcontains $tok) { $rule.Tokens += $tok } }
        $rule.Lines += $i
    }
    return $rules.Values
}

# A rule as one aligned line, the way the built-in profiles are written.
function Format-SLRuleLine {
    param([string] $Pattern, [string[]] $Tokens)
    $p = $Pattern
    if ($p -match '\s') { $p = '"' + $p.Replace('\', '\\').Replace('"', '\"') + '"' }
    return ('{0,-14} {1}' -f $p, ($Tokens -join ' ')).TrimEnd()
}

# ------------------------------------------------------------- comparison --

# Compares a repo's .gitattributes lines with a profile's.
#   MISSING  no .gitattributes (-FileMissing)
#   MATCHES  every profile rule, same attributes, nothing else
#   EXTENDS  every profile rule, plus extra rules or extra attributes
#   DIFFERS  a profile rule is missing, or a pattern has different attributes
function Compare-SLGitAttributes {
    param(
        [AllowEmptyCollection()] [string[]] $Lines,
        [Parameter(Mandatory)] [AllowEmptyString()] [string[]] $ProfileLines,
        [switch] $FileMissing
    )

    $want = @(ConvertFrom-SLGitAttributes $ProfileLines)
    $have = @()
    if (-not $FileMissing) { $have = @(ConvertFrom-SLGitAttributes $Lines) }
    $haveMap = @{}
    foreach ($r in $have) { $haveMap[$r.Pattern] = $r }
    $wantMap = @{}
    foreach ($r in $want) { $wantMap[$r.Pattern] = $r }

    $missing = @(); $conflicts = @(); $extra = @()
    $missingRules = @(); $conflictRules = @()
    foreach ($w in $want) {
        $h = $null
        if ($haveMap.ContainsKey($w.Pattern)) { $h = $haveMap[$w.Pattern] }
        if (-not $h) {
            $missing += "$($w.Pattern) $($w.Tokens -join ' ')"
            $missingRules += $w
            continue
        }
        $differs = $false
        foreach ($name in $w.Attributes.Keys) {
            if ($h.Attributes[$name] -cne $w.Attributes[$name]) { $differs = $true }
        }
        if ($differs) {
            $conflicts += "$($w.Pattern): profile has '$(Format-SLAttributeSet $w.Attributes)', repo has '$(Format-SLAttributeSet $h.Attributes)'"
            $conflictRules += [pscustomobject]@{ Want = $w; Have = $h }
            continue
        }
        $more = @{}
        foreach ($name in $h.Attributes.Keys) {
            if (-not $w.Attributes.ContainsKey($name)) { $more[$name] = $h.Attributes[$name] }
        }
        if ($more.Count -gt 0) { $extra += "$($w.Pattern) $(Format-SLAttributeSet $more) (extra attribute)" }
    }
    foreach ($h in $have) {
        if (-not $wantMap.ContainsKey($h.Pattern)) { $extra += "$($h.Pattern) $($h.Tokens -join ' ')" }
    }

    $status = 'MATCHES'
    if ($FileMissing) { $status = 'MISSING' }
    elseif ($missing.Count -gt 0 -or $conflicts.Count -gt 0) { $status = 'DIFFERS' }
    elseif ($extra.Count -gt 0) { $status = 'EXTENDS' }

    return [pscustomobject]@{
        Status           = $status
        MissingRules     = $missing
        ConflictingRules = $conflicts
        ExtraRules       = $extra
        Missing          = $missingRules
        Conflicts        = $conflictRules
    }
}

# -------------------------------------------------------------------- git --

# The git executable, or a clear error with how to install it.
function Get-SLGitPath {
    $cmd = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { throw "git is not on PATH. Install it ($script:SLGitInstall), then open a new terminal." }
    return $cmd.Path
}

# Quotes one argument for a Windows command line (CommandLineToArgvW rules).
function ConvertTo-SLArgument {
    param([string] $Value)
    if ($Value -and $Value -notmatch '[\s"]') { return $Value }
    $sb = New-Object Text.StringBuilder
    [void] $sb.Append('"')
    $slashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') { $slashes++; continue }
        if ($ch -eq '"') { [void] $sb.Append('\' * ($slashes * 2 + 1)); [void] $sb.Append('"') }
        else { [void] $sb.Append('\' * $slashes); [void] $sb.Append($ch) }
        $slashes = 0
    }
    [void] $sb.Append('\' * ($slashes * 2))
    [void] $sb.Append('"')
    return $sb.ToString()
}

# Runs 'git -C <repo> <args>' and returns Output (stdout), Errors (stderr) and ExitCode.
# Reads output as UTF-8 so non-ASCII paths survive in Windows PowerShell 5.1, and
# never lets stderr become a terminating error.
function Invoke-SLGit {
    param(
        [Parameter(Mandatory)] [string] $RepoPath,
        [Parameter(Mandatory)] [string[]] $Arguments,
        [int] $TimeoutSeconds = 300
    )
    $all = @('-C', $RepoPath, '-c', 'core.quotepath=off') + $Arguments
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = Get-SLGitPath
    $psi.Arguments              = (($all | ForEach-Object { ConvertTo-SLArgument $_ }) -join ' ')
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    $psi.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $psi.StandardErrorEncoding  = New-Object Text.UTF8Encoding($false)

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void] $proc.Start()
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
        try { $proc.Kill() } catch { Write-Verbose "git already exited: $($_.Exception.Message)" }
        $proc.Dispose()
        throw "git $($Arguments -join ' ') did not finish within $TimeoutSeconds s in $RepoPath."
    }
    $proc.WaitForExit()
    $result = [pscustomobject]@{ Output = $outTask.Result; Errors = $errTask.Result.Trim(); ExitCode = $proc.ExitCode }
    $proc.Dispose()
    return $result
}

# True if the folder is a repo's top level: it has a .git folder, or a .git file
# (worktrees and submodules).
function Test-SLGitRepo {
    param([Parameter(Mandatory)] [string] $Path)
    return (Test-Path -LiteralPath (Join-Path $Path '.git'))
}

# Repos at or under Path, up to Depth folders down. Doesn't look inside a repo
# once found, and skips node_modules, bin, obj and the like.
function Find-SLGitRepo {
    param([Parameter(Mandatory)] [string] $Path, [int] $Depth = 2)
    if (Test-SLGitRepo $Path) { return $Path }
    $found = @()
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue(@($Path, 0))
    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        if ($item[1] -ge $Depth) { continue }
        $dirs = @(Get-ChildItem -LiteralPath $item[0] -Directory -Force -ErrorAction SilentlyContinue)
        foreach ($d in $dirs) {
            if ($script:SLSkipDirs -contains $d.Name) { continue }
            if (Test-SLGitRepo $d.FullName) { $found += $d.FullName; continue }
            $queue.Enqueue(@($d.FullName, ($item[1] + 1)))
        }
    }
    return ($found | Sort-Object)
}

# The shallowest file under Root (Root itself is level 0) whose name matches one of
# Include and, if given, for which Where returns true. Returns its path relative to Root.
function Find-SLRepoFile {
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string[]] $Include,
        [int] $MaxDepth = 3,
        [scriptblock] $Where
    )
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue(@($Root, 0))
    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        $files = @(Get-ChildItem -LiteralPath $item[0] -File -Force -ErrorAction SilentlyContinue | Sort-Object Name)
        foreach ($f in $files) {
            $hit = $false
            foreach ($pattern in $Include) { if ($f.Name -like $pattern) { $hit = $true } }
            if ($hit -and (-not $Where -or (& $Where $f))) {
                return $f.FullName.Substring($Root.TrimEnd('\', '/').Length + 1)
            }
        }
        if ($item[1] -ge $MaxDepth) { continue }
        foreach ($d in @(Get-ChildItem -LiteralPath $item[0] -Directory -Force -ErrorAction SilentlyContinue | Sort-Object Name)) {
            if ($script:SLSkipDirs -contains $d.Name) { continue }
            $queue.Enqueue(@($d.FullName, ($item[1] + 1)))
        }
    }
    return $null
}

# Picks the profile for a repo: -Profile, then a pin in the standard, then detection.
function Resolve-SLRepoProfile {
    param(
        [Parameter(Mandatory)] [string] $RepoPath,
        [Parameter(Mandatory)] [hashtable] $Profiles,
        $Standard,
        [string] $Name
    )
    $known = (@($Profiles.Keys) | Sort-Object) -join ', '
    if ($Name) {
        if (-not $Profiles.ContainsKey($Name)) { throw "Unknown profile '$Name'. Use one of: $known." }
        return [pscustomobject]@{ Name = $Name; Reason = '-Profile' }
    }

    $repoName = Split-Path $RepoPath -Leaf
    if ($Standard -and $Standard.GitAttributes -and $Standard.GitAttributes.Repos.ContainsKey($repoName)) {
        $pinned = $Standard.GitAttributes.Repos[$repoName]
        return [pscustomobject]@{ Name = $pinned; Reason = 'pinned in standard' }
    }

    $net = Find-SLRepoFile -Root $RepoPath -Include '*.sln', '*.slnx', '*.csproj', '*.fsproj' -MaxDepth 3
    if ($net) { return [pscustomobject]@{ Name = 'dotnet'; Reason = "found $net" } }

    $manifest = Find-SLRepoFile -Root $RepoPath -Include '*.psd1' -MaxDepth 2 -Where {
        param($f)
        try { return ([IO.File]::ReadAllText($f.FullName) -match '(?m)^\s*(RootModule|ModuleVersion)\s*=') }
        catch { return $false }
    }
    if ($manifest) { return [pscustomobject]@{ Name = 'powershell'; Reason = "found $manifest" } }

    return [pscustomobject]@{ Name = 'docs'; Reason = 'no .NET project or module manifest found' }
}

# Tracked text files whose committed copy has CRLF or mixed endings: committed
# before the rules applied, so they need 'git add --renormalize .'.
function Get-SLRenormalizeFiles {
    param([Parameter(Mandatory)] [string] $RepoPath)
    $head = Invoke-SLGit -RepoPath $RepoPath -Arguments @('rev-parse', '--verify', '--quiet', 'HEAD')
    if ($head.ExitCode -ne 0) {
        return [pscustomobject]@{ Files = @(); Note = 'no commits yet, renormalize check skipped' }
    }
    $r = Invoke-SLGit -RepoPath $RepoPath -Arguments @('ls-files', '--eol', '-z')
    if ($r.ExitCode -ne 0) {
        return [pscustomobject]@{ Files = @(); Note = "git ls-files failed: $($r.Errors)" }
    }
    $files = @()
    foreach ($entry in ($r.Output -split "`0")) {
        if (-not $entry) { continue }
        $tab = $entry.IndexOf("`t")
        if ($tab -lt 0) { continue }
        $meta = $entry.Substring(0, $tab)
        if ($meta -notmatch '^i/(crlf|mixed)\s') { continue }
        $attr = ''
        if ($meta -match 'attr/(.*)$') { $attr = $Matches[1].Trim() }
        if ($attr -match '(^|\s)(-text|binary)(\s|$)') { continue }
        $files += $entry.Substring($tab + 1)
    }
    return [pscustomobject]@{ Files = $files; Note = '' }
}

# Uncommitted changes to tracked files (staged or not), except .gitattributes.
# Untracked files don't count: 'git add --renormalize' only touches tracked files.
# Neither do unstaged changes that are only line endings: once .gitattributes says
# eol=lf, git can show a CRLF file as modified, and that is what renormalizing fixes.
function Get-SLDirtyFiles {
    param([Parameter(Mandatory)] [string] $RepoPath)
    $r = Invoke-SLGit -RepoPath $RepoPath -Arguments @('status', '--porcelain=v1', '-z', '--untracked-files=no')
    if ($r.ExitCode -ne 0) { throw "git status failed in $($RepoPath): $($r.Errors)" }
    $entries = @(ConvertFrom-SLPorcelain $r.Output | Where-Object { $_.Path -ne '.gitattributes' })
    if ($entries.Count -eq 0) { return }

    $real = @()
    $d = Invoke-SLGit -RepoPath $RepoPath -Arguments @('diff', '--ignore-cr-at-eol', '--name-only', '-z')
    if ($d.ExitCode -eq 0) { $real = @($d.Output -split "`0" | Where-Object { $_ }) }
    foreach ($e in $entries) {
        $eolOnly = $d.ExitCode -eq 0 -and $e.Index -eq ' ' -and $e.WorkTree -eq 'M' -and $real -notcontains $e.Path
        if (-not $eolOnly) { $e }
    }
}

# Parses 'git status --porcelain=v1 -z' into Index, WorkTree, Path.
function ConvertFrom-SLPorcelain {
    param([string] $Text)
    $entries = @($Text -split "`0")
    $out = @()
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $e = $entries[$i]
        if ($e.Length -lt 4) { continue }
        $x = $e.Substring(0, 1)
        $out += [pscustomobject]@{ Index = $x; WorkTree = $e.Substring(1, 1); Path = $e.Substring(3) }
        if ($x -eq 'R' -or $x -eq 'C') { $i++ }   # the original path follows a rename or copy
    }
    return $out
}

# ----------------------------------------------------------- the standard --
# Validates a standard's GitAttributes section, adding any problems to the list.
# Returns @{ Profiles = name -> lines; Repos = folder name -> profile }.
function ConvertTo-SLGitAttributesSection {
    param($Section, [System.Collections.Generic.List[string]] $Problems)

    $profiles = @{}
    $repos = @{}
    if ($Section -isnot [hashtable]) {
        $Problems.Add("'GitAttributes' must be a @{ ... } section with Profiles and/or Repos.")
        return [pscustomobject]@{ Profiles = $profiles; Repos = $repos }
    }
    foreach ($key in $Section.Keys) {
        if (@('Profiles', 'Repos') -notcontains $key) {
            $Problems.Add("GitAttributes has an unknown key '$key'. Use Profiles and/or Repos.")
        }
    }

    if ($Section.ContainsKey('Profiles')) {
        if ($Section.Profiles -isnot [hashtable]) {
            $Problems.Add("GitAttributes.Profiles must be @{ name = @('pattern attributes', ...) }.")
        }
        else {
            foreach ($name in $Section.Profiles.Keys) {
                $label = "GitAttributes.Profiles.$name"
                if ("$name" -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
                    $Problems.Add("$label`: profile names use letters, digits, '.', '_' or '-'.")
                    continue
                }
                $lines = @($Section.Profiles[$name])
                $bad = @($lines | Where-Object { $_ -isnot [string] })
                if ($lines.Count -eq 0 -or $bad.Count -gt 0) {
                    $Problems.Add("$label must be a list of .gitattributes lines, e.g. @('* text=auto', '*.md text eol=lf').")
                    continue
                }
                if (@(ConvertFrom-SLGitAttributes $lines).Count -eq 0) {
                    $Problems.Add("$label has no rules (only comments or blank lines).")
                    continue
                }
                $profiles["$name"] = [string[]] $lines
            }
        }
    }

    if ($Section.ContainsKey('Repos')) {
        if ($Section.Repos -isnot [hashtable]) {
            $Problems.Add("GitAttributes.Repos must be @{ 'repo-folder' = 'profile' }.")
        }
        else {
            $known = @((Get-SLBuiltInProfiles).Keys) + @($profiles.Keys)
            foreach ($repo in $Section.Repos.Keys) {
                $value = $Section.Repos[$repo]
                if ($value -isnot [string] -or -not $value) {
                    $Problems.Add("GitAttributes.Repos.$repo must name a profile, e.g. 'docs'.")
                }
                elseif ($known -notcontains $value) {
                    $Problems.Add("GitAttributes.Repos.$repo uses profile '$value', which doesn't exist. Use one of: $((@($known | Sort-Object -Unique)) -join ', ').")
                }
                else { $repos["$repo"] = $value }
            }
        }
    }

    return [pscustomobject]@{ Profiles = $profiles; Repos = $repos }
}

# --------------------------------------------------------------- the check --

# Loads the standard if one is found; unlike Get-SecondLineStandard, no file is fine.
# An explicit -Path or SECONDLINE_STANDARD that doesn't exist is still an error.
function Get-SLOptionalStandard {
    param([string] $Path)
    if ($Path -or $env:SECONDLINE_STANDARD) { return Get-SecondLineStandard -Path $Path }
    $here = Join-Path (Get-Location).ProviderPath 'secondline.standard.psd1'
    if (Test-Path -LiteralPath $here -PathType Leaf) { return Get-SecondLineStandard -Path $here }
    return $null
}

# Checks one repo against its profile. The object Test-SLRepo -PassThru returns.
function Get-SLRepoCheck {
    param(
        [Parameter(Mandatory)] [string] $RepoPath,
        $Standard,
        [string] $ProfileName,
        [hashtable] $Profiles
    )
    if (-not $Profiles) { $Profiles = Get-SLProfiles -Standard $Standard }
    $pick = Resolve-SLRepoProfile -RepoPath $RepoPath -Profiles $Profiles -Standard $Standard -Name $ProfileName

    $file = Join-Path $RepoPath '.gitattributes'
    $exists = Test-Path -LiteralPath $file -PathType Leaf
    $lines = @()
    if ($exists) { $lines = @(Read-SLTextLines -Path $file) }
    $cmp = Compare-SLGitAttributes -Lines $lines -ProfileLines $Profiles[$pick.Name] -FileMissing:(-not $exists)
    $ren = Get-SLRenormalizeFiles -RepoPath $RepoPath

    [pscustomobject]@{
        PSTypeName         = 'SecondLine.RepoCheck'
        Repo               = Split-Path $RepoPath -Leaf
        Path               = $RepoPath
        Profile            = $pick.Name
        ProfileReason      = $pick.Reason
        Status             = $cmp.Status
        MissingRules       = $cmp.MissingRules
        ConflictingRules   = $cmp.ConflictingRules
        ExtraRules         = $cmp.ExtraRules
        FilesToRenormalize = @($ren.Files).Count
        RenormalizeSample  = @($ren.Files | Select-Object -First 10)
        Note               = $ren.Note
    }
}

# True when a repo needs nothing: its rules match or extend the profile, and no
# committed file needs renormalizing.
function Test-SLRepoOk {
    param($Check)
    return (@('MATCHES', 'EXTENDS') -contains $Check.Status -and $Check.FilesToRenormalize -eq 0)
}

# A command that fixes the repo, for the report.
function Get-SLRepoFixHint {
    param($Check)
    $hint = "Set-SLGitAttributes -Path '$($Check.Path.Replace("'", "''"))'"
    if ($Check.ProfileReason -eq '-Profile') { $hint += " -Profile $($Check.Profile)" }
    if (@($Check.ConflictingRules).Count -gt 0) { $hint += ' -Force   # replaces the conflicting lines' }
    return $hint
}
