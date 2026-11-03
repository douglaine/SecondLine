# Resolve standards without evaluating code or depending on the caller's folder.
# Discovery and the Extends chain live in Bootstrap\Import-SecondLine.ps1, shared
# with the pre-import bootstrap. This file merges the chain into one standard.

$script:SLDevelopmentStandard = Join-Path (Split-Path $PSScriptRoot -Parent) 'Standards\development.psd1'

# Sections merged by key, child values winning, instead of replaced whole.
$script:SLKeyedSections = @('ModuleVersions', 'Updates')

function Read-SLStandardData {
    param([string] $Path)
    $chain = @(Get-SLStandardChain -Path $Path -DevelopmentPath $script:SLDevelopmentStandard)
    $merged = $chain[$chain.Count - 1].Data
    for ($i = $chain.Count - 2; $i -ge 0; $i--) {
        $merged = Merge-SLStandardData -Base $merged -Data $chain[$i].Data
    }
    return $merged
}

# One inheritance step: Data (the child) over Base (its merged parents).
function Merge-SLStandardData {
    param([Parameter(Mandatory)] [hashtable] $Base, [Parameter(Mandatory)] [hashtable] $Data)
    $merged = @{}
    foreach ($key in $Base.Keys) { $merged[$key] = $Base[$key] }
    foreach ($key in $Data.Keys) {
        if ($key -in @('Tools', 'GitAttributes', 'Extends')) { continue }
        if ($key -in $script:SLKeyedSections -and $Base[$key] -is [hashtable] -and $Data[$key] -is [hashtable]) {
            $values = @{}
            foreach ($entry in $Base[$key].Keys) { $values[$entry] = $Base[$key][$entry] }
            foreach ($entry in $Data[$key].Keys) { $values[$entry] = $Data[$key][$entry] }
            $merged[$key] = $values
        }
        else { $merged[$key] = $Data[$key] }
    }
    # Child entries replace complete tools by Name, preserving distinct inherited tools.
    $tools = @($Base.Tools)
    if ($null -eq $Base.Tools) { $tools = @() }
    foreach ($tool in @($Data.Tools)) {
        if ($null -eq $tool) { continue }
        if ($tool -is [hashtable] -and $tool.Name) {
            $tools = @($tools | Where-Object { $_.Name -ne $tool.Name })
        }
        $tools += $tool
    }
    if ($Base.ContainsKey('Tools') -or $Data.ContainsKey('Tools')) { $merged.Tools = $tools }
    if ($Data.ContainsKey('GitAttributes')) {
        if ($Data.GitAttributes -isnot [hashtable] -or $Base.GitAttributes -isnot [hashtable]) {
            $merged.GitAttributes = $Data.GitAttributes
        }
        else {
            $section = @{}
            foreach ($key in $Base.GitAttributes.Keys) { $section[$key] = $Base.GitAttributes[$key] }
            foreach ($key in $Data.GitAttributes.Keys) {
                if ($section[$key] -is [hashtable] -and $Data.GitAttributes[$key] -is [hashtable]) {
                    $values = @{}
                    foreach ($entry in $section[$key].Keys) { $values[$entry] = $section[$key][$entry] }
                    foreach ($entry in $Data.GitAttributes[$key].Keys) { $values[$entry] = $Data.GitAttributes[$key][$entry] }
                    $section[$key] = $values
                }
                else { $section[$key] = $Data.GitAttributes[$key] }
            }
            $merged.GitAttributes = $section
        }
    }
    return $merged
}
