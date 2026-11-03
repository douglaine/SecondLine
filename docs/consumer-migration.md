# Migrating a consumer repository to SecondLine 0.4.0

This procedure is for review. Running it in a repository needs that repository's own authorization. Fenceline and DurableEventEngine are on hold: do not migrate them until their owners approve it.

Publishing, installing, being notified, and approving are separate steps. Publishing 0.4.0 changes nothing in a consumer. Each consumer opts in with a reviewed change on its own branch.

## 0. Before you start

- SecondLine 0.4.0 has been reviewed and published, and is installed on the machine doing the migration:
  - Windows PowerShell 5.1: `Install-Module SecondLine -RequiredVersion 0.4.0 -Scope CurrentUser`
  - PowerShell 7.4+: `Install-PSResource SecondLine -Version 0.4.0`
- You are on a new branch in the consumer repo, with a clean working tree.
- Read the consumer's CLAUDE.md or AGENTS.md and its current task. Local business rules and approvals stay there.

## 1. Audit (read-only)

```powershell
Import-Module SecondLine -RequiredVersion 0.4.0     # an interactive session for the audit only
Test-SLPolicyReference -Path C:\src\Consumer        # entry points, policy, checkpoint, hardcoded versions
Test-SLLineEnding -Path C:\src\Consumer             # line-ending rules and working copies
Test-SLRepo -Path C:\src\Consumer                   # .gitattributes profile and stored normalization
```

Record the findings in the consumer's checkpoint once it exists (step 5).

## 2. Approve the SecondLine version in the project standard

Before, each script pins a version:

```powershell
# build/Check.ps1 (before)
Import-Module SecondLine -RequiredVersion 0.3.0 -ErrorAction Stop
Test-SecondLine -Strict
```

After, the standard approves the version once. Subprojects inherit it through nearest-parent discovery or `Extends`:

```powershell
# secondline.standard.psd1 (after)
@{
    Extends        = '@development'
    Name           = 'Consumer'
    ModuleVersions = @{ SecondLine = '0.4.0' }
    # existing Tools / GitAttributes entries stay as they are
}
```

## 3. Select the version before import

Copy the bootstrap from the approved, installed package. Do not copy it from a SecondLine checkout:

```powershell
$pkg = Get-Module -ListAvailable SecondLine | Where-Object Version -eq '0.4.0'
Copy-Item (Join-Path $pkg.ModuleBase 'Bootstrap\Import-SecondLine.ps1') C:\src\Consumer\build\
```

Then replace each hardcoded import:

```powershell
# build/Check.ps1 (after)
& "$PSScriptRoot\Import-SecondLine.ps1" -Path $PSScriptRoot
Test-SecondLine -Strict
```

CI installs exactly the approved version. Machine and user settings are ignored there automatically:

```yaml
- name: Install approved SecondLine
  run: Install-Module SecondLine -RequiredVersion 0.4.0 -Scope CurrentUser -Force
- name: Checks
  run: ./build/Check.ps1
```

A later upgrade is a reviewed one-line change to `ModuleVersions`, plus installing that version. A Gallery release alone never changes it.

## 4. Shared policy and entry points

```powershell
Export-SLPolicy -Path C:\src\Consumer -WhatIf
Export-SLPolicy -Path C:\src\Consumer          # writes docs/shared-development-policy.md only
```

By hand, add these two lines near the top of both CLAUDE.md and AGENTS.md. Keep every local instruction:

```text
SecondLine-Policy: 1 docs/shared-development-policy.md
SecondLine-Status: docs/status/current.md
```

Remove any reference to a developer-specific path such as `C:\Users\...\SecondLine\docs\...`. Keep both entry points equivalent. If the repo already had local edits inside its policy copy, move them into the entry points before exporting. `Export-SLPolicy` refuses to overwrite a modified copy.

## 5. Status checkpoint

```powershell
New-SLStatusCheckpoint -Path C:\src\Consumer
```

Fill it in: Position, Completed, Remaining, Changed files, Verification (Verified or Planned, with evidence paths), Blockers, and Next action. Never put credentials in it. Never copy another project's status or approvals into it.

## 6. Line endings

```powershell
Repair-SLLineEnding -Path C:\src\Consumer -WhatIf
Repair-SLLineEnding -Path C:\src\Consumer          # working copies and editor settings; never stages
Set-SLGitAttributes -Path C:\src\Consumer -WhatIf  # only if .gitattributes or stored normalization needs work
```

Commit line-ending changes separately from content changes.

## 7. Verify, then hand off

```powershell
Test-SLPolicyReference -Path C:\src\Consumer -Strict
Test-SLLineEnding -Path C:\src\Consumer -Strict
Get-SLSetting -Path C:\src\Consumer -NoHostSettings   # what CI will see
```

Run the consumer's own test suite and lint in the shells it supports. Then update its checkpoint and stop for review. Passing checks do not authorize merging, publishing, or advancing a milestone.

## Rollback

Revert the branch. Scripts that still pin 0.3.0 keep working while 0.3.0 stays installed: the published 0.3.0 package is unchanged.
