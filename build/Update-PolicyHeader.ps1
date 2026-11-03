<#
.SYNOPSIS
    Recomputes the version header of docs/shared-development-policy.md after a reviewed edit.

.DESCRIPTION
    The first line of the shared policy records its version and the SHA-256 of the rest
    of the file:  <!-- SecondLine-Policy: version=N sha256=... -->
    Consumers' reviewed copies are verified against that hash (Test-SLPolicyReference).
    Run this after changing the policy text, and raise -Version when the change is one
    that consumers should review and adopt. Tests fail while the header is stale.

.PARAMETER Version
    The policy version to record. Default: keep the current one.

.EXAMPLE
    .\build\Update-PolicyHeader.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param([int] $Version)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$policy = Join-Path $repo 'docs\shared-development-policy.md'
Import-Module (Join-Path $repo 'SecondLine\SecondLine.psd1') -Force
$module = Get-Module SecondLine
$lines = @(& $module { param($p) Read-SLTextLines -Path $p } $policy)
$current = & $module { param($p) Read-SLPolicyFile -Path $p } $policy
if (-not $current.HasHeader) { throw "$policy has no SecondLine-Policy header line." }
if (-not $Version) { $Version = $current.Version }
$body = @($lines | Select-Object -Skip 1)
$hash = & $module { param($b) Get-SLPolicyHash -BodyLines $b } $body
$header = "<!-- SecondLine-Policy: version=$Version sha256=$hash -->"
if ($lines[0] -ceq $header) { Write-Host "  Policy header is current (version $Version)." -ForegroundColor Green; return }
if ($PSCmdlet.ShouldProcess($policy, "Set header to version $Version, sha256 $hash")) {
    & $module { param($p, $l) Write-SLTextLines -Path $p -Lines $l } $policy (@($header) + $body)
    Write-Host "  Updated $policy header: version $Version, sha256 $hash" -ForegroundColor Green
}
