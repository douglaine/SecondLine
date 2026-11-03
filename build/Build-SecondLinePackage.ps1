<#
.SYNOPSIS
    Stages the SecondLine release package: exactly the files that ship.

.DESCRIPTION
    Copies the module folder, LICENSE, and the shared development policy (whose one
    source is docs/shared-development-policy.md) into <OutputPath>\SecondLine, ready
    for Publish-PSResource or Compress-PSResource. Nothing else from the repo goes in:
    no tests, build scripts, tasks, docs, agent instructions or CI files.
    Publish-SecondLine.ps1 and Test-SecondLinePackage.ps1 both use this.

.PARAMETER OutputPath
    An empty or missing folder to stage into.

.OUTPUTS
    The staged module folder.

.EXAMPLE
    .\build\Build-SecondLinePackage.ps1 -OutputPath $env:TEMP\sl-stage
#>
[CmdletBinding()]
param([Parameter(Mandatory)] [string] $OutputPath)

$ErrorActionPreference = 'Stop'
# Staging is a dry run's input too: Publish-SecondLine.ps1 -WhatIf must still stage real files.
$WhatIfPreference = $false
$repo = Split-Path $PSScriptRoot -Parent
$source = Join-Path $repo 'SecondLine'
if ((Test-Path -LiteralPath $OutputPath) -and @(Get-ChildItem -LiteralPath $OutputPath -Force).Count -gt 0) {
    throw "$OutputPath is not empty. Stage into a new folder."
}
$stage = Join-Path $OutputPath 'SecondLine'
New-Item -ItemType Directory -Path $stage -Force | Out-Null
Copy-Item -Path (Join-Path $source '*') -Destination $stage -Recurse
Copy-Item -LiteralPath (Join-Path $repo 'LICENSE') -Destination $stage
$policyDir = Join-Path $stage 'Policy'
New-Item -ItemType Directory -Path $policyDir -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'docs\shared-development-policy.md') -Destination $policyDir
# Editor and OS leftovers never ship.
Get-ChildItem -LiteralPath $stage -Recurse -Force -File |
    Where-Object { $_.Name -like '*.tmp' -or $_.Name -like '*.log' -or $_.Name -like '*.Tests.ps1' -or $_.Name -in 'Thumbs.db', '.DS_Store' } |
    Remove-Item -Force
return $stage
