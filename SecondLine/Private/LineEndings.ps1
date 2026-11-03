# The line-ending audit behind Test-SLLineEnding and Repair-SLLineEnding.
#
# Three layers are kept apart:
#   rules        what .gitattributes (effective, as git computes it), .editorconfig
#                (local and parent files up to root = true) and VS Code workspace
#                settings (.vscode/settings.json, *.code-workspace) ask for
#   working copy the endings actually in each file (git ls-files --eol, w/)
#   stored       what git keeps in the index (i/); CRLF there needs renormalizing
#
# Git decides what a checkout writes, so an explicit .gitattributes eol is the
# expected ending. Without one, an .editorconfig end_of_line is. Without either, a
# file only has to be consistent (not mixed). VS Code settings only choose endings
# for new files, so they are checked for conflicts, never used as the rule.

$script:SLVSCodeLanguages = @{
    '.ps1' = 'powershell'; '.psm1' = 'powershell'; '.psd1' = 'powershell'
    '.md' = 'markdown'; '.markdown' = 'markdown'
    '.json' = 'json'; '.jsonc' = 'jsonc'
    '.yml' = 'yaml'; '.yaml' = 'yaml'
    '.cs' = 'csharp'; '.fs' = 'fsharp'; '.vb' = 'vb'
    '.xml' = 'xml'; '.csproj' = 'xml'; '.props' = 'xml'; '.targets' = 'xml'
    '.bat' = 'bat'; '.cmd' = 'bat'
    '.sh' = 'shellscript'; '.bash' = 'shellscript'
    '.js' = 'javascript'; '.mjs' = 'javascript'; '.cjs' = 'javascript'; '.ts' = 'typescript'
    '.html' = 'html'; '.htm' = 'html'; '.css' = 'css'; '.py' = 'python'
    '.sql' = 'sql'; '.txt' = 'plaintext'
}

# ------------------------------------------------------------- git entries --

# Tracked and (optionally) untracked, not ignored files with git's view of them:
# Path (repo-relative, '/'), Tracked, Index, Worktree, Attr.
function Get-SLGitEolEntry {
    param([Parameter(Mandatory)] [string] $RepoPath, [switch] $IncludeUntracked)
    $sets = @(@{ Tracked = $true; Args = @('ls-files', '--eol', '-z') })
    if ($IncludeUntracked) { $sets += @{ Tracked = $false; Args = @('ls-files', '--others', '--exclude-standard', '--eol', '-z') } }
    foreach ($set in $sets) {
        $r = Invoke-SLGit -RepoPath $RepoPath -Arguments $set.Args
        if ($r.ExitCode -ne 0) { throw "git ls-files failed in $($RepoPath): $($r.Errors)" }
        foreach ($entry in ($r.Output -split "`0")) {
            if (-not $entry) { continue }
            $tab = $entry.IndexOf("`t")
            if ($tab -lt 0) { continue }
            $meta = $entry.Substring(0, $tab)
            if ($meta -notmatch '^i/(?<i>\S*)\s+w/(?<w>\S*)\s+attr/(?<a>.*)$') { continue }
            [pscustomobject]@{
                Path     = $entry.Substring($tab + 1)
                Tracked  = $set.Tracked
                Index    = $Matches['i']
                Worktree = $Matches['w']
                Attr     = $Matches['a'].Trim()
            }
        }
    }
}

# The eol a git attribute string asks for ('lf', 'crlf' or $null), and whether it is binary.
function ConvertFrom-SLGitAttr {
    param([string] $Attr)
    $tokens = @($Attr -split '\s+' | Where-Object { $_ })
    $binary = $tokens -contains '-text'
    $eol = $null
    foreach ($t in $tokens) { if ($t -match '^eol=(lf|crlf)$') { $eol = $Matches[1] } }
    $text = @($tokens | Where-Object { $_ -eq 'text' -or $_ -like 'text=*' -or $_ -like 'eol=*' }).Count -gt 0
    return [pscustomobject]@{ Eol = $eol; Binary = $binary; Text = $text }
}

# -------------------------------------------------------------- editorconfig --

# Converts an EditorConfig section glob to a regex over a '/'-separated path relative
# to the .editorconfig folder. Supports * ** ? [set] [!set] {a,b} {n1..n2} and '\'.
# Number ranges become (?<rN>...) groups, checked by Test-SLEditorConfigMatch.
function ConvertTo-SLEditorConfigRegex {
    param([Parameter(Mandatory)] [string] $Glob)
    $ranges = New-Object System.Collections.Generic.List[object]
    $pattern = $Glob
    $anchored = $pattern.Contains('/')
    if ($pattern.StartsWith('/')) { $pattern = $pattern.Substring(1) }
    $body = ConvertFrom-SLGlobPart -Glob $pattern -Ranges $ranges
    $prefix = '^'
    if (-not $anchored) { $prefix = '^(?:.*/)?' }
    return [pscustomobject]@{ Regex = New-Object regex ($prefix + $body + '$'), ([Text.RegularExpressions.RegexOptions]::CultureInvariant); Ranges = $ranges.ToArray() }
}

function ConvertFrom-SLGlobPart {
    param([string] $Glob, [System.Collections.Generic.List[object]] $Ranges)
    $sb = New-Object Text.StringBuilder
    $i = 0
    while ($i -lt $Glob.Length) {
        $c = $Glob[$i]
        if ($c -eq '\' -and $i + 1 -lt $Glob.Length) { [void] $sb.Append([regex]::Escape([string] $Glob[$i + 1])); $i += 2; continue }
        if ($c -eq '*') {
            if ($i + 1 -lt $Glob.Length -and $Glob[$i + 1] -eq '*') {
                # '**/' also matches no folder at all.
                if ($i + 2 -lt $Glob.Length -and $Glob[$i + 2] -eq '/') { [void] $sb.Append('(?:.*/)?'); $i += 3 }
                else { [void] $sb.Append('.*'); $i += 2 }
            }
            else { [void] $sb.Append('[^/]*'); $i++ }
            continue
        }
        if ($c -eq '?') { [void] $sb.Append('[^/]'); $i++; continue }
        if ($c -eq '[') {
            $close = $Glob.IndexOf(']', $i + 1)
            if ($close -gt $i + 1) {
                $set = $Glob.Substring($i + 1, $close - $i - 1)
                $negate = $set.StartsWith('!')
                if ($negate) { $set = $set.Substring(1) }
                $escaped = ($set.ToCharArray() | ForEach-Object { if ($_ -eq '-') { '-' } else { [regex]::Escape([string] $_).Replace(']', '\]') } }) -join ''
                if ($negate) { [void] $sb.Append("[^/$escaped]") } else { [void] $sb.Append("[$escaped]") }
                $i = $close + 1
                continue
            }
            [void] $sb.Append('\['); $i++; continue
        }
        if ($c -eq '{') {
            # Find the matching close brace, allowing nesting.
            $depth = 0; $close = -1
            for ($j = $i; $j -lt $Glob.Length; $j++) {
                if ($Glob[$j] -eq '\') { $j++; continue }
                if ($Glob[$j] -eq '{') { $depth++ }
                elseif ($Glob[$j] -eq '}') { $depth--; if ($depth -eq 0) { $close = $j; break } }
            }
            if ($close -lt 0) { [void] $sb.Append('\{'); $i++; continue }
            $inner = $Glob.Substring($i + 1, $close - $i - 1)
            if ($inner -match '^([+-]?\d+)\.\.([+-]?\d+)$') {
                $name = "r$($Ranges.Count)"
                $Ranges.Add([pscustomobject]@{ Name = $name; Low = [Math]::Min([int] $Matches[1], [int] $Matches[2]); High = [Math]::Max([int] $Matches[1], [int] $Matches[2]) })
                [void] $sb.Append("(?<$name>[+-]?\d+)")
            }
            else {
                $items = Split-SLBraceItem $inner
                if ($items.Count -lt 2) { [void] $sb.Append('\{' + (ConvertFrom-SLGlobPart -Glob $inner -Ranges $Ranges) + '\}') }
                else { [void] $sb.Append('(?:' + ((@($items | ForEach-Object { ConvertFrom-SLGlobPart -Glob $_ -Ranges $Ranges })) -join '|') + ')') }
            }
            $i = $close + 1
            continue
        }
        [void] $sb.Append([regex]::Escape([string] $c))
        $i++
    }
    return $sb.ToString()
}

# Splits brace contents on top-level commas.
function Split-SLBraceItem {
    param([string] $Text)
    $items = New-Object System.Collections.Generic.List[string]
    $depth = 0; $start = 0
    for ($j = 0; $j -lt $Text.Length; $j++) {
        if ($Text[$j] -eq '\') { $j++; continue }
        if ($Text[$j] -eq '{') { $depth++ }
        elseif ($Text[$j] -eq '}') { $depth-- }
        elseif ($Text[$j] -eq ',' -and $depth -eq 0) { $items.Add($Text.Substring($start, $j - $start)); $start = $j + 1 }
    }
    $items.Add($Text.Substring($start))
    return , $items.ToArray()
}

function Test-SLEditorConfigMatch {
    param($Compiled, [string] $RelativePath)
    $m = $Compiled.Regex.Match($RelativePath)
    if (-not $m.Success) { return $false }
    foreach ($r in $Compiled.Ranges) {
        $n = [int] $m.Groups[$r.Name].Value
        if ($n -lt $r.Low -or $n -gt $r.High) { return $false }
    }
    return $true
}

# Parses one .editorconfig: Root, and Sections with Glob, Compiled, Properties
# (name -> Value, Line). Keys are case-insensitive, values for end_of_line lowercased.
function Read-SLEditorConfig {
    param([Parameter(Mandatory)] [string] $Path)
    $lines = @(Read-SLTextLines -Path $Path)
    $root = $false
    $sections = New-Object System.Collections.Generic.List[object]
    $current = $null
    for ($n = 0; $n -lt $lines.Count; $n++) {
        $t = $lines[$n].Trim()
        if (-not $t -or $t.StartsWith('#') -or $t.StartsWith(';')) { continue }
        if ($t.StartsWith('[') -and $t.EndsWith(']')) {
            $glob = $t.Substring(1, $t.Length - 2)
            $current = [pscustomobject]@{ Glob = $glob; Compiled = (ConvertTo-SLEditorConfigRegex -Glob $glob); Properties = @{}; Line = $n + 1 }
            $sections.Add($current)
            continue
        }
        $eq = $t.IndexOf('=')
        if ($eq -lt 1) { continue }
        $key = $t.Substring(0, $eq).Trim().ToLowerInvariant()
        $value = $t.Substring($eq + 1).Trim()
        if ($null -eq $current) {
            if ($key -eq 'root' -and $value -eq 'true') { $root = $true }
            continue
        }
        $current.Properties[$key] = [pscustomobject]@{ Value = $value.ToLowerInvariant(); Line = $n + 1 }
    }
    return [pscustomobject]@{ Path = $Path; Directory = (Split-Path $Path -Parent); Root = $root; Sections = $sections.ToArray() }
}

# Resolves end_of_line for absolute file paths, caching parsed files and folder chains.
function New-SLEditorConfigResolver {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Returns a new in-memory cache; changes no state.')]
    param()
    return @{ Files = @{}; Chains = @{} }
}

# The applicable .editorconfig files for a folder, farthest first, stopping at root = true.
function Get-SLEditorConfigChain {
    param([Parameter(Mandatory)] [hashtable] $Resolver, [Parameter(Mandatory)] [string] $Directory)
    if ($Resolver.Chains.ContainsKey($Directory)) { return , $Resolver.Chains[$Directory] }
    $chain = @()
    $dir = $Directory
    while ($dir) {
        $file = Join-Path $dir '.editorconfig'
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            if (-not $Resolver.Files.ContainsKey($file)) { $Resolver.Files[$file] = Read-SLEditorConfig -Path $file }
            $parsed = $Resolver.Files[$file]
            $chain = @($parsed) + $chain
            if ($parsed.Root) { break }
        }
        $parent = Split-Path $dir -Parent
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    $Resolver.Chains[$Directory] = $chain
    return , $chain
}

# end_of_line for one file: Value (lf | crlf | cr | $null), File, Line, Chain (paths).
# 'unset' clears an earlier value, as the specification says.
function Resolve-SLEditorConfigEol {
    param([Parameter(Mandatory)] [hashtable] $Resolver, [Parameter(Mandatory)] [string] $FullPath)
    $chain = Get-SLEditorConfigChain -Resolver $Resolver -Directory (Split-Path $FullPath -Parent)
    $value = $null; $file = $null; $line = 0
    foreach ($config in $chain) {
        $relative = $FullPath.Substring($config.Directory.TrimEnd('\', '/').Length + 1).Replace('\', '/')
        foreach ($section in $config.Sections) {
            if (-not $section.Properties.ContainsKey('end_of_line')) { continue }
            if (-not (Test-SLEditorConfigMatch -Compiled $section.Compiled -RelativePath $relative)) { continue }
            $p = $section.Properties['end_of_line']
            if ($p.Value -eq 'unset') { $value = $null; $file = $null; $line = 0 }
            else { $value = $p.Value; $file = $config.Path; $line = $p.Line }
        }
    }
    return [pscustomobject]@{ Value = $value; File = $file; Line = $line; Chain = @($chain | ForEach-Object { $_.Path }) }
}

# ------------------------------------------------------------------ vs code --

# Replaces // and /* */ comments outside strings with spaces, keeping every offset.
function Clear-SLJsonComment {
    param([string] $Text)
    $chars = $Text.ToCharArray()
    $i = 0
    while ($i -lt $chars.Length) {
        $c = $chars[$i]
        if ($c -eq '"') {
            $i++
            while ($i -lt $chars.Length -and $chars[$i] -ne '"') { if ($chars[$i] -eq '\') { $i++ }; $i++ }
            $i++
            continue
        }
        if ($c -eq '/' -and $i + 1 -lt $chars.Length -and $chars[$i + 1] -eq '/') {
            while ($i -lt $chars.Length -and $chars[$i] -ne "`n") { if ($chars[$i] -ne "`r") { $chars[$i] = ' ' }; $i++ }
            continue
        }
        if ($c -eq '/' -and $i + 1 -lt $chars.Length -and $chars[$i + 1] -eq '*') {
            while ($i -lt $chars.Length -and -not ($chars[$i] -eq '*' -and $i + 1 -lt $chars.Length -and $chars[$i + 1] -eq '/')) {
                if ($chars[$i] -ne "`r" -and $chars[$i] -ne "`n") { $chars[$i] = ' ' }
                $i++
            }
            if ($i -lt $chars.Length) { $chars[$i] = ' '; if ($i + 1 -lt $chars.Length) { $chars[$i + 1] = ' ' } }
            $i += 2
            continue
        }
        $i++
    }
    return (New-Object string (, $chars))
}

# Every "files.eol" string value in a VS Code settings or workspace file:
# Context (the enclosing object keys), Raw (as written, e.g. \n), Eol (lf | crlf | auto),
# Start and Length (of the raw value, for an in-place edit).
function Find-SLVSCodeEolSetting {
    param([Parameter(Mandatory)] [string] $Text)
    $clean = Clear-SLJsonComment $Text
    $stack = New-Object System.Collections.Generic.List[string]
    $pendingKey = $null
    $i = 0
    while ($i -lt $clean.Length) {
        $c = $clean[$i]
        if ($c -eq '"') {
            $j = $i + 1
            while ($j -lt $clean.Length -and $clean[$j] -ne '"') { if ($clean[$j] -eq '\') { $j++ }; $j++ }
            $raw = $clean.Substring($i + 1, $j - $i - 1)
            $k = $j + 1
            while ($k -lt $clean.Length -and [char]::IsWhiteSpace($clean[$k])) { $k++ }
            if ($k -lt $clean.Length -and $clean[$k] -eq ':') { $pendingKey = $raw; $i = $k + 1; continue }
            if ($pendingKey -eq 'files.eol') {
                $eol = switch ($raw) { '\n' { 'lf' } '\r\n' { 'crlf' } default { 'auto' } }
                [pscustomobject]@{ Context = @($stack.ToArray() | Select-Object -Skip 1); Raw = $raw; Eol = $eol; Start = $i + 1; Length = $raw.Length }
            }
            $pendingKey = $null
            $i = $j + 1
            continue
        }
        if ($c -eq '{') { $key = ''; if ($pendingKey) { $key = $pendingKey }; $stack.Add($key); $pendingKey = $null }
        elseif ($c -eq '[') { $stack.Add(''); $pendingKey = $null }
        elseif ($c -eq '}' -or $c -eq ']') { if ($stack.Count -gt 0) { $stack.RemoveAt($stack.Count - 1) } }
        elseif ($c -eq ',') { $pendingKey = $null }
        $i++
    }
}

# The repo's VS Code sources: .vscode/settings.json and root *.code-workspace files.
# Each: Path, Kind (Folder | Workspace), Settings (from Find-SLVSCodeEolSetting).
function Get-SLVSCodeSource {
    param([Parameter(Mandatory)] [string] $RepoPath)
    $files = @()
    $folder = Join-Path $RepoPath '.vscode\settings.json'
    if (Test-Path -LiteralPath $folder -PathType Leaf) { $files += [pscustomobject]@{ Path = $folder; Kind = 'Folder' } }
    foreach ($w in @(Get-ChildItem -LiteralPath $RepoPath -Filter '*.code-workspace' -File -ErrorAction SilentlyContinue)) {
        $files += [pscustomobject]@{ Path = $w.FullName; Kind = 'Workspace' }
    }
    foreach ($f in $files) {
        $all = @(Find-SLVSCodeEolSetting -Text (Read-SLTextFile -Path $f.Path).Text)
        # A workspace file keeps its settings under "settings"; a folder file at the top.
        $settings = @(foreach ($s in $all) {
                $ctx = @($s.Context)
                if ($f.Kind -eq 'Workspace') {
                    if ($ctx.Count -eq 0 -or $ctx[0] -ne 'settings') { continue }
                    $ctx = @($ctx | Select-Object -Skip 1)
                }
                if ($ctx.Count -gt 1) { continue }
                $language = $null
                if ($ctx.Count -eq 1) {
                    if ($ctx[0] -notmatch '^(\[[^\]]+\])+$') { continue }
                    $language = @([regex]::Matches($ctx[0], '\[([^\]]+)\]') | ForEach-Object { $_.Groups[1].Value })
                }
                $s | Add-Member -NotePropertyName Languages -NotePropertyValue $language -PassThru
            })
        [pscustomobject]@{ Path = $f.Path; Kind = $f.Kind; Settings = $settings }
    }
}

# The files.eol that decides new files of this language in one source: language-specific first, then global.
function Resolve-SLVSCodeEol {
    param($Source, [string] $Language)
    if ($Language) {
        $specific = @($Source.Settings | Where-Object { $_.Languages -and $_.Languages -contains $Language })
        if ($specific.Count -gt 0) { return $specific[-1] }
    }
    $global = @($Source.Settings | Where-Object { -not $_.Languages })
    if ($global.Count -gt 0) { return $global[-1] }
    return $null
}

# -------------------------------------------------------------------- audit --

# Audits one repo. Returns Repo, Path, Files (one record per file), Issues, Notes
# and Ok. Kinds of issue:
#   Mixed                 the working copy has both LF and CRLF
#   WrongEnding           the working copy uses a different ending than the rule
#   Renormalize           git stores CRLF for a text file (stored normalization)
#   EditorConfigConflict  .editorconfig end_of_line disagrees with .gitattributes eol
#   VSCodeConflict        an explicit files.eol disagrees with the effective rule
function Get-SLLineEndingAudit {
    param([Parameter(Mandatory)] [string] $RepoPath, [switch] $IncludeUntracked)
    $resolver = New-SLEditorConfigResolver
    $vscode = @(Get-SLVSCodeSource -RepoPath $RepoPath)
    $records = New-Object System.Collections.Generic.List[object]
    $issues = New-Object System.Collections.Generic.List[object]
    $autoOnly = 0
    foreach ($e in @(Get-SLGitEolEntry -RepoPath $RepoPath -IncludeUntracked:$IncludeUntracked)) {
        $full = Join-Path $RepoPath ($e.Path.Replace('/', [IO.Path]::DirectorySeparatorChar))
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }   # deleted, or a submodule
        $git = ConvertFrom-SLGitAttr $e.Attr
        $binary = $git.Binary -or $e.Worktree -eq '-text'
        $record = [pscustomobject]@{
            Path = $e.Path; FullPath = $full; Tracked = $e.Tracked; Index = $e.Index; Worktree = $e.Worktree; Attr = $e.Attr
            Binary = $binary; GitEol = $git.Eol; EditorConfig = $null; VSCode = @(); Expected = $null; ExpectedSource = $null
            Extension = [IO.Path]::GetExtension($e.Path).ToLowerInvariant(); Language = $null
        }
        $records.Add($record)
        if ($binary) { continue }

        $ec = Resolve-SLEditorConfigEol -Resolver $resolver -FullPath $full
        $record.EditorConfig = $ec
        if ($git.Eol) { $record.Expected = $git.Eol; $record.ExpectedSource = ".gitattributes ($($e.Attr))" }
        elseif ($ec.Value -in 'lf', 'crlf') { $record.Expected = $ec.Value; $record.ExpectedSource = "$($ec.File):$($ec.Line)" }
        elseif ($git.Text) { $autoOnly++ }

        if ($git.Eol -and $ec.Value -and $ec.Value -ne $git.Eol) {
            $issues.Add((New-SLLineIssue $record 'EditorConfigConflict' $git.Eol $ec.Value "$($ec.File):$($ec.Line)" "end_of_line = $($ec.Value), but .gitattributes says eol=$($git.Eol)"))
        }
        if ($script:SLVSCodeLanguages.ContainsKey($record.Extension)) { $record.Language = $script:SLVSCodeLanguages[$record.Extension] }
        foreach ($source in $vscode) {
            $setting = Resolve-SLVSCodeEol -Source $source -Language $record.Language
            if (-not $setting) { continue }
            $record.VSCode += [pscustomobject]@{ Source = $source; Setting = $setting }
            if ($record.Expected -and $setting.Eol -ne 'auto' -and $setting.Eol -ne $record.Expected) {
                $key = 'files.eol'
                if ($setting.Languages) { $key = "[$($setting.Languages -join '][')] files.eol" }
                $issues.Add((New-SLLineIssue $record 'VSCodeConflict' $record.Expected $setting.Eol $source.Path "$key = `"$($setting.Raw)`", but the rule is $($record.Expected) ($($record.ExpectedSource))"))
            }
        }

        if ($e.Worktree -eq 'mixed') {
            $issues.Add((New-SLLineIssue $record 'Mixed' $record.Expected 'mixed' $record.ExpectedSource 'both LF and CRLF line endings'))
        }
        elseif ($record.Expected -and $e.Worktree -in 'lf', 'crlf' -and $e.Worktree -ne $record.Expected) {
            $issues.Add((New-SLLineIssue $record 'WrongEnding' $record.Expected $e.Worktree $record.ExpectedSource "working copy is $($e.Worktree.ToUpperInvariant())"))
        }
        if ($e.Tracked -and $git.Text -and $e.Index -in 'crlf', 'mixed') {
            $issues.Add((New-SLLineIssue $record 'Renormalize' 'lf' $e.Index 'git index' "stored with $($e.Index.ToUpperInvariant()); renormalize with Set-SLGitAttributes or 'git add --renormalize'"))
        }
    }
    $notes = @()
    if ($autoOnly -gt 0) { $notes += "$autoOnly text file(s) have no explicit eol rule (text=auto or text); their checkout ending depends on each machine's core.autocrlf / core.eol, so only mixed endings are flagged." }
    if ($vscode.Count -gt 0) { $notes += 'VS Code files.eol applies to new files only; files.associations and user-level settings are not evaluated.' }
    $notes += 'Editor settings cannot control scripts or generators: they must write the declared endings themselves.'
    $repoIssues = $issues.ToArray()
    return [pscustomobject]@{
        PSTypeName   = 'SecondLine.LineEndingCheck'
        Repo         = Split-Path $RepoPath -Leaf
        Path         = $RepoPath
        FilesChecked = @($records | Where-Object { -not $_.Binary }).Count
        Binary       = @($records | Where-Object { $_.Binary }).Count
        Issues       = $repoIssues
        Ok           = $repoIssues.Count -eq 0
        Notes        = $notes
        Files        = $records.ToArray()
        VSCode       = $vscode
        EditorConfig = @($resolver.Files.Values)
    }
}

function New-SLLineIssue {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Returns a new in-memory object; changes no state.')]
    param($Record, [string] $Kind, [string] $Expected, [string] $Actual, [string] $Source, [string] $Detail)
    return [pscustomobject]@{ File = $Record.Path; Kind = $Kind; Expected = $Expected; Actual = $Actual; Source = $Source; Detail = $Detail; Tracked = $Record.Tracked }
}

# ---------------------------------------------------------------- repairs --

# Converts every line ending in Text to Ending ('lf' or 'crlf'). Lone CRs are kept.
function ConvertTo-SLLineEnding {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text, [Parameter(Mandatory)] [ValidateSet('lf', 'crlf')] [string] $Ending)
    $lfOnly = $Text -replace "`r`n", "`n"
    if ($Ending -eq 'lf') { return $lfOnly }
    return ($lfOnly -replace "`n", "`r`n")
}

# The config edits that make .editorconfig and VS Code settings agree with
# .gitattributes, each with File, Kind, Description and either an in-place edit
# (Start, Length, Replacement in a text-file read) or an Append, or Manual guidance.
function Get-SLConfigRepairPlan {
    param([Parameter(Mandatory)] $Audit)
    $plans = @()
    $text = @($Audit.Files | Where-Object { -not $_.Binary -and $_.EditorConfig })

    # EditorConfig: group conflicts by the line that decided them.
    $conflicts = @($Audit.Issues | Where-Object Kind -eq 'EditorConfigConflict')
    foreach ($group in @($conflicts | Group-Object Source)) {
        $file, $lineText = $group.Name -split ':(?=\d+$)'
        $line = [int] $lineText
        $governed = @($text | Where-Object { $_.EditorConfig.File -eq $file -and $_.EditorConfig.Line -eq $line })
        $wanted = @($governed | ForEach-Object { $_.GitEol } | Sort-Object -Unique)
        $soleRule = @($governed | Where-Object { -not $_.GitEol })
        if ($wanted.Count -eq 1 -and $soleRule.Count -eq 0) {
            $plans += [pscustomobject]@{ File = $file; Kind = 'EditorConfig'; Action = 'Replace'; Line = $line; Value = $wanted[0]
                Description = "$($file):$line end_of_line -> $($wanted[0]) (every file it governs has .gitattributes eol=$($wanted[0]))"
            }
            continue
        }
        # Otherwise add a section per extension, where that is safe: every file the new
        # section would decide must already have that eol in .gitattributes.
        $byExt = @{}
        foreach ($issue in @($group.Group)) {
            $record = $text | Where-Object Path -eq $issue.File | Select-Object -First 1
            $ext = $record.Extension
            if (-not $ext -or $ext -notmatch '^\.[A-Za-z0-9_+-]+$') { continue }
            $byExt[$ext] = $issue.Expected
        }
        $safe = @{}
        foreach ($ext in $byExt.Keys) {
            $affected = @($text | Where-Object { $_.Extension -eq $ext -and $_.EditorConfig.Chain -contains $file -and (-not $_.EditorConfig.File -or $_.EditorConfig.File -eq $file) })
            if (@($affected | Where-Object { $_.GitEol -ne $byExt[$ext] }).Count -eq 0) { $safe[$ext] = $byExt[$ext] }
        }
        foreach ($value in @($safe.Values | Sort-Object -Unique)) {
            $exts = @($safe.Keys | Where-Object { $safe[$_] -eq $value } | Sort-Object | ForEach-Object { $_.Substring(1) })
            $glob = "*.$($exts[0])"
            if ($exts.Count -gt 1) { $glob = "*.{$($exts -join ',')}" }
            $plans += [pscustomobject]@{ File = $file; Kind = 'EditorConfig'; Action = 'Append'; Line = 0; Value = $value
                Section = @('', '# Added by SecondLine: match .gitattributes', "[$glob]", "end_of_line = $value")
                Description = "$file append [$glob] end_of_line = $value (overrides line $line for these files only)"
            }
        }
        $left = @($byExt.Keys | Where-Object { -not $safe.ContainsKey($_) })
        if ($left.Count -gt 0 -or $byExt.Count -eq 0) {
            $plans += [pscustomobject]@{ File = $file; Kind = 'EditorConfig'; Action = 'Manual'; Line = $line; Value = $null
                Description = "$($file):$line governs files with different or no .gitattributes eol rules ($((@($left) -join ', '))); add narrower sections by hand."
            }
        }
    }

    # VS Code: per setting, the value every governed file's rule agrees on, else "auto".
    foreach ($group in @($Audit.Issues | Where-Object Kind -eq 'VSCodeConflict' | Group-Object Source)) {
        $source = $Audit.VSCode | Where-Object Path -eq $group.Name | Select-Object -First 1
        foreach ($setting in @($source.Settings)) {
            $governed = @($Audit.Files | Where-Object { $_.Expected -and @($_.VSCode | Where-Object { $_.Setting -eq $setting }).Count -gt 0 })
            $wanted = @($governed | ForEach-Object { $_.Expected } | Sort-Object -Unique)
            if ($wanted.Count -eq 0 -or ($wanted.Count -eq 1 -and $wanted[0] -eq $setting.Eol)) { continue }
            $value = 'auto'
            if ($wanted.Count -eq 1) { $value = $wanted[0] }
            $raw = @{ lf = '\n'; crlf = '\r\n'; auto = 'auto' }[$value]
            $key = 'files.eol'
            if ($setting.Languages) { $key = "[$($setting.Languages -join '][')] files.eol" }
            $plans += [pscustomobject]@{ File = $source.Path; Kind = 'VSCode'; Action = 'Replace'; Start = $setting.Start; Length = $setting.Length; Value = $raw
                Description = "$($source.Path) $key `"$($setting.Raw)`" -> `"$raw`""
            }
        }
    }
    return $plans
}
