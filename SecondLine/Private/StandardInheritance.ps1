# Resolve standards without evaluating code or depending on the caller's folder.
function Find-SLStandardPath {
    param([string] $Directory = (Get-Location).ProviderPath)
    $folder = [IO.DirectoryInfo] $Directory
    while ($null -ne $folder) {
        $candidate = Join-Path $folder.FullName 'secondline.standard.psd1'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        $folder = $folder.Parent
    }
    return $null
}

function Read-SLStandardData {
    param([string] $Path, [string[]] $Stack = @())
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    if ($Stack -contains $resolved) { throw "Circular SecondLine inheritance: $(@($Stack + $resolved) -join ' -> ')" }
    if ($Stack.Count -ge 64) { throw 'SecondLine inheritance exceeds 64 files.' }
    try { $data = Import-PowerShellDataFile -LiteralPath $resolved -ErrorAction Stop }
    catch { throw "Could not read $resolved as a PowerShell data file: $($_.Exception.Message)" }
    if (-not $data.ContainsKey('Extends')) { return $data }
    if ($data.Extends -isnot [string] -or -not $data.Extends.Trim()) {
        throw "SecondLine standard $resolved requires Extends to be a nonempty string."
    }
    $parent = $data.Extends
    if ($parent -eq '@development') {
        $parent = Join-Path (Split-Path $PSScriptRoot -Parent) 'Standards\development.psd1'
    }
    elseif (-not [IO.Path]::IsPathRooted($parent)) {
        $parent = Join-Path (Split-Path $resolved -Parent) $parent
    }
    if (-not (Test-Path -LiteralPath $parent -PathType Leaf)) { throw "SecondLine parent standard not found: $parent (from $resolved)." }
    $base = Read-SLStandardData -Path $parent -Stack @($Stack + $resolved)
    $merged = @{}
    foreach ($key in $base.Keys) { $merged[$key] = $base[$key] }
    foreach ($key in $data.Keys) {
        if ($key -notin @('Tools', 'GitAttributes', 'Extends')) { $merged[$key] = $data[$key] }
    }
    # Child entries replace complete tools by Name, preserving distinct inherited tools.
    $tools = @($base.Tools)
    if ($null -eq $base.Tools) { $tools = @() }
    foreach ($tool in @($data.Tools)) {
        if ($null -eq $tool) { continue }
        if ($tool -is [hashtable] -and $tool.Name) {
            $tools = @($tools | Where-Object { $_.Name -ne $tool.Name })
        }
        $tools += $tool
    }
    if ($base.ContainsKey('Tools') -or $data.ContainsKey('Tools')) { $merged.Tools = $tools }
    if ($data.ContainsKey('GitAttributes')) {
        if ($data.GitAttributes -isnot [hashtable] -or $base.GitAttributes -isnot [hashtable]) {
            $merged.GitAttributes = $data.GitAttributes
        }
        else {
            $section = @{}
            foreach ($key in $base.GitAttributes.Keys) { $section[$key] = $base.GitAttributes[$key] }
            foreach ($key in $data.GitAttributes.Keys) {
                if ($section[$key] -is [hashtable] -and $data.GitAttributes[$key] -is [hashtable]) {
                    $values = @{}
                    foreach ($entry in $section[$key].Keys) { $values[$entry] = $section[$key][$entry] }
                    foreach ($entry in $data.GitAttributes[$key].Keys) { $values[$entry] = $data.GitAttributes[$key][$entry] }
                    $section[$key] = $values
                }
                else { $section[$key] = $data.GitAttributes[$key] }
            }
            $merged.GitAttributes = $section
        }
    }
    return $merged
}