# Version parsing and rule matching.
#
# Rules:
#   Exact    every component given in Expect must match ('8.0.34' -> only 8.0.34; '8.0' -> 8.0.x)
#   Minor    same major.minor                          ('8.0' -> 8.0.x, not 8.2)
#   Major    same major                                ('2' or '2.13' -> 2.x)
#   Minimum  found >= expected                         ('2.40' -> 2.40 or newer)

$script:SLRules = @('Exact', 'Minor', 'Major', 'Minimum')

# Pulls the first version-looking string (1.2, 1.2.3, 1.2.3.4) out of text.
function Get-SLVersionText {
    param([string] $Text, [string] $Pattern)
    if (-not $Text) { return $null }
    if (-not $Pattern) { $Pattern = '\d+(\.\d+){1,3}' }
    $m = [regex]::Match($Text, $Pattern)
    if (-not $m.Success) { return $null }
    # A custom pattern may use a 'version' named group; otherwise take the whole match.
    if ($m.Groups['version'].Success) { return $m.Groups['version'].Value }
    return $m.Value
}

# Splits '8.0.34' into an int array @(8,0,34). Returns $null if not numeric.
function ConvertTo-SLVersionParts {
    param([string] $Version)
    if (-not $Version) { return $null }
    $parts = @()
    foreach ($p in $Version.Trim().TrimStart('v', 'V').Split('.')) {
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
