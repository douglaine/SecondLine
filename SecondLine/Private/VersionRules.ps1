# Version parsing and rule matching.
#
# Rules:
#   Exact    every component given in Expect must match ('8.0.34' -> only 8.0.34; '8.0' -> 8.0.x)
#   Minor    same major.minor                          ('8.0' -> 8.0.x, not 8.2)
#   Major    same major                                ('2' or '2.13' -> 2.x)
#   Minimum  found >= expected                         ('2.40' -> 2.40 or newer)

$script:SLRules = @('Exact', 'Minor', 'Major', 'Minimum')

# A version: 1.2, 1.2.3 or 1.2.3.4, optionally followed by a prerelease tag
# like -rc.2.26504.105 or -preview.7. The tag is kept so previews are never
# reported as releases.
$script:SLDefaultPattern = '\d+(\.\d+){1,3}(-[0-9A-Za-z][0-9A-Za-z.]*)?'

# Pulls every version-looking string out of text, in order.
function Get-SLVersionTexts {
    param([string] $Text, [string] $Pattern)
    if (-not $Text) { return @() }
    if (-not $Pattern) { $Pattern = $script:SLDefaultPattern }
    $found = @()
    foreach ($m in [regex]::Matches($Text, $Pattern)) {
        # A custom pattern may use a 'version' named group; otherwise take the whole match.
        if ($m.Groups['version'].Success) { $found += $m.Groups['version'].Value }
        else { $found += $m.Value }
    }
    # Emitted one per item; callers wrap in @() to always get an array.
    return $found
}

# Pulls the first version-looking string out of text.
function Get-SLVersionText {
    param([string] $Text, [string] $Pattern)
    $all = @(Get-SLVersionTexts -Text $Text -Pattern $Pattern)
    if ($all.Count -eq 0) { return $null }
    return $all[0]
}

# True if the version carries a prerelease tag (-rc, -preview, -beta ...).
function Test-SLPrerelease {
    param([string] $Version)
    return ($Version -match '^\D*\d+(\.\d+)*-')
}

# Splits '8.0.34' into an int array @(8,0,34). Any prerelease tag is ignored
# for comparison. Returns $null if not numeric.
function ConvertTo-SLVersionParts {
    param([string] $Version)
    if (-not $Version) { return $null }
    $core = $Version.Trim().TrimStart('v', 'V').Split('-')[0]
    $parts = @()
    foreach ($p in $core.Split('.')) {
        $n = 0
        if (-not [int]::TryParse($p, [ref] $n)) { return $null }
        $parts += $n
    }
    return , $parts
}

# Compares two part arrays component by component, padding the shorter with zeros.
# Returns -1, 0 or 1.
function Compare-SLVersionParts {
    param([int[]] $A, [int[]] $B)
    $len = [Math]::Max($A.Count, $B.Count)
    for ($i = 0; $i -lt $len; $i++) {
        $x = 0; if ($i -lt $A.Count) { $x = $A[$i] }
        $y = 0; if ($i -lt $B.Count) { $y = $B[$i] }
        if ($x -lt $y) { return -1 }
        if ($x -gt $y) { return 1 }
    }
    return 0
}

# From a list of versions, picks the highest release; falls back to the highest
# prerelease only if there is no release. Returns $null for an empty list.
function Select-SLBestVersion {
    param([string[]] $Versions)
    $list = @($Versions | Where-Object { $_ -and $null -ne (ConvertTo-SLVersionParts $_) })
    if ($list.Count -eq 0) { return $null }
    $releases = @($list | Where-Object { -not (Test-SLPrerelease $_) })
    if ($releases.Count -gt 0) { $list = $releases }
    $best = $list[0]
    foreach ($v in $list) {
        if ((Compare-SLVersion $v $best) -gt 0) { $best = $v }
    }
    return $best
}

# Full comparison including prerelease tags: 11.0.100 > 11.0.100-rc.2 > 11.0.100-rc.1.
# Returns -1, 0 or 1.
function Compare-SLVersion {
    param([string] $A, [string] $B)
    $c = Compare-SLVersionParts (ConvertTo-SLVersionParts $A) (ConvertTo-SLVersionParts $B)
    if ($c -ne 0) { return $c }
    $preA = Test-SLPrerelease $A
    $preB = Test-SLPrerelease $B
    if (-not $preA -and -not $preB) { return 0 }
    if (-not $preA) { return 1 }      # a release beats its own prerelease
    if (-not $preB) { return -1 }
    # Both prerelease: compare the numbers inside the tags (rc.2 > rc.1).
    $numsA = @([regex]::Matches(($A -split '-', 2)[1], '\d+') | ForEach-Object { [int] $_.Value })
    $numsB = @([regex]::Matches(($B -split '-', 2)[1], '\d+') | ForEach-Object { [int] $_.Value })
    return (Compare-SLVersionParts $numsA $numsB)
}

# True if Found satisfies Expect under Rule.
function Test-SLVersionRule {
    param(
        [Parameter(Mandatory)] [string] $Found,
        [Parameter(Mandatory)] [string] $Expect,
        [Parameter(Mandatory)] [string] $Rule
    )
    $f = ConvertTo-SLVersionParts $Found
    $e = ConvertTo-SLVersionParts $Expect
    if ($null -eq $f -or $null -eq $e) { return $false }

    switch ($Rule) {
        'Exact' {
            if ($f.Count -lt $e.Count) { return $false }
            for ($i = 0; $i -lt $e.Count; $i++) { if ($f[$i] -ne $e[$i]) { return $false } }
            return $true
        }
        'Minor' {
            if ($e.Count -lt 2 -or $f.Count -lt 2) { return $false }
            return ($f[0] -eq $e[0] -and $f[1] -eq $e[1])
        }
        'Major' {
            return ($f[0] -eq $e[0])
        }
        'Minimum' {
            return ((Compare-SLVersionParts $f $e) -ge 0)
        }
        default {
            throw "Unknown rule '$Rule'. Use one of: $($script:SLRules -join ', ')."
        }
    }
}
