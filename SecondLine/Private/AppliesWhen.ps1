# AppliesWhen: a tool that only makes sense in some folders (the .NET SDK in a
# .NET repo, say) lists file patterns, and is checked only where one matches.

# The git repo that contains Path (walking up), or $null outside a repo.
function Get-SLRepoRoot {
    param([Parameter(Mandatory)] [string] $Path)
    $dir = $Path
    while ($dir) {
        if (Test-SLGitRepo $dir) { return $dir }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}

# Whether a tool with these AppliesWhen patterns applies at Path.
#   Inside a git repo: a matching file anywhere in the repo (bin, obj,
#   node_modules and the like skipped; up to MaxDepth folders down).
#   Outside a repo: a matching file in Path itself.
# Returns @{ Applies = $bool; Where = <where it looked> }.
function Test-SLToolApplies {
    param(
        [Parameter(Mandatory)] [string[]] $Patterns,
        [Parameter(Mandatory)] [string] $Path,
        [int] $MaxDepth = 5
    )
    $repoRoot = Get-SLRepoRoot -Path $Path
    if ($repoRoot) {
        $hit = Find-SLRepoFile -Root $repoRoot -Include $Patterns -MaxDepth $MaxDepth
        return @{ Applies = [bool] $hit; Where = "this repo ($repoRoot)" }
    }
    $hit = Find-SLRepoFile -Root $Path -Include $Patterns -MaxDepth 0
    return @{ Applies = [bool] $hit; Where = "this folder ($Path)" }
}
