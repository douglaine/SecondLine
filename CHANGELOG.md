# Changelog

All notable changes to SecondLine. Versions follow [Semantic Versioning](https://semver.org).

## 0.4.0 - Unreleased (release candidate)

Headline: **one rulebook for every AI coding agent.** `CLAUDE.md` and `AGENTS.md` in every repo point at the same versioned, hash-stamped rules, with a handoff note per repo, and one command audits them all. Also: one approved SecondLine version per project, one shared update check, and line endings checked end to end. Minor version: these are new, backward-compatible features. Nothing from 0.3.0 changes incompatibly.

### Added

- `Show-SLHelp` (built separately at the user's request and kept here):
  - A catalog of commands and their help synopses, discovered from the module's exports, plus the configuration and the version policy, and detailed help for one command. It never runs a listed command.
  - `about_SecondLine`.
  - Opening help reads the shared update cache and, when the result isn't current, starts one background lookup without waiting for it. `-NoUpdateCheck` opts out. `-CheckForUpdates` forces a background refresh.
- One shared update service (`Invoke-SLUpdateCheck`, `Get-SLUpdateStatus`), replacing the session-only cache in the help work:
  - A per-user, per-machine cache in LocalApplicationData\SecondLine (or `SECONDLINE_CACHE_DIR`), with atomic writes.
  - A lock file, so concurrent shells and help calls don't repeat a lookup.
  - A daily refresh by default.
  - A three-second timeout and one retry by default, and a 1 MB response limit.
  - A 60-minute failure backoff shared across sessions.
  - Only the PowerShell Gallery is queried, only for SecondLine, and only stable releases by default.
  - The status separates update availability, version-policy mismatch, and security advisories. Advisories are reported as not configured: no advisory source exists, and none is invented.
  - A failed or offline lookup is reported as unknown, never as up to date.
  - Each notice is shown once, for example `SecondLine 0.4.1 available; installed 0.4.0.` Nothing is ever installed.
- `Enable-SLProfileUpdateCheck` and `Disable-SLProfileUpdateCheck` (opt-in, `-WhatIf`, explicit `-Path`) add or remove one marked profile block:
  - The block imports nothing into the shell, so project version selection still works afterwards.
  - It shows a pending notice and, when the shared cache is due, starts one hidden, no-profile process that runs the shared check.
  - Other profile bytes, the encoding, the BOM and the line endings are kept. Duplicate blocks are collapsed, and removal is clean.
- Layered settings and approved module versions:
  - `ModuleVersions` and `Updates` sections in standards, merged by key through `Extends`.
  - Machine and user `settings.psd1` files.
  - `Get-SLSetting` shows each value's source and what it overrode.
  - A project's `ModuleVersions` always wins over personal values. Update preferences are personal.
  - In CI, or with `SECONDLINE_NO_HOST_SETTINGS=1`, machine and user files are ignored.
- `Bootstrap/Import-SecondLine.ps1` selects the approved version before import:
  - It follows nearest-parent discovery and `Extends`, with relative paths resolved and cycles detected.
  - It imports the version with `-RequiredVersion`.
  - It refuses to swap an already loaded different version.
  - It never installs anything, and explains how to install a missing version.
  - The module dot-sources the same file, so there is one implementation.
- `Test-SLLineEnding` (read-only, `-Strict` for CI) audits:
  - effective `.gitattributes`
  - local and parent `.editorconfig` files, up to `root = true`, with full glob support
  - explicit VS Code `files.eol` settings, global and per-language, in `.vscode/settings.json` and `*.code-workspace` (JSONC)
  - actual working-copy endings, including mixed files
  - Git's stored normalization, reported separately

  Binary files are skipped. Intentional CRLF is respected.
- `Repair-SLLineEnding` (`-WhatIf`, `-File`, `-Scope`):
  - It converts only line endings, byte-for-byte, keeping the encoding, BOM, content and a missing final newline, and verifies the result before an atomic write.
  - Files with uncommitted edits are skipped unless `-AllowModified`.
  - It makes `.editorconfig` and VS Code settings agree with `.gitattributes` only where that is provably safe, and reports the rest as manual work.
  - It never stages.
- One rulebook for every AI coding agent:
  - `docs/shared-development-policy.md` now has a version header with a SHA-256, so copies can be verified offline. It ships in the package as `Policy/shared-development-policy.md`.
  - `Export-SLPolicy` writes a reviewed copy into a repo. It never edits CLAUDE.md or AGENTS.md, and it refuses to overwrite a modified copy unless `-Force`.
  - `New-SLStatusCheckpoint` creates `docs/status/current.md` from the shipped template.
  - `Test-SLPolicyReference` audits:
    - entry points that are missing or differ
    - missing, broken, non-portable or outdated policy references
    - modified copies
    - the checkpoint's required sections, and credential-like content in it
    - outdated bootstrap copies and hardcoded `Import-Module SecondLine -RequiredVersion`
- Status checkpoint convention (`docs/status/current.md`) in the shared policy and in both entry points. A checkpoint is a handoff to verify, never an authorization.
- `build/Build-SecondLinePackage.ps1` stages exactly the shipped files. `Publish-SecondLine.ps1` now uses it.
- `build/Test-SecondLinePackage.ps1` builds the real `.nupkg` (with `Compress-PSResource`), checks the required assets and the excluded development files, and smoke-tests the extracted package. It publishes nothing.
- `build/Update-PolicyHeader.ps1` updates the policy header after a reviewed edit.
- `AppliesWhen` on a tool: a list of file patterns. The tool is only checked in a git repo that
  contains a matching file (or, outside a repo, a folder that has one), and is reported as
  `SKIPPED` elsewhere. `SKIPPED` isn't a failure: the summary counts only the tools checked,
  and `-Strict` ignores it.
- VS Code workspace files for working on SecondLine: recommended extensions (PowerShell,
  Pester Tests) and the repo's PSScriptAnalyzer settings wired into the editor.

### Changed

- A standard is valid with only `ModuleVersions` or `Updates`.
- Standard discovery and `Extends` resolution moved into the bootstrap file, shared by the module and the pre-import loader. The behavior and error messages are unchanged.

### Fixed

- The `@development` baseline no longer reports a false .NET SDK `MISMATCH` in repos with no
  .NET in them. Its .NET check now has `AppliesWhen` (`global.json`, `*.sln`, `*.slnx`,
  `*.csproj`, `*.fsproj`), and its fix hint says to add a `global.json` pinning the SDK, which
  is what stops a repo from silently building with a newer preview SDK.
- "Standard not found" now says how to create one, and a standard that won't parse reports the
  error once, naming the file that failed.

## 0.3.0 - 2026-10-21

Every git repo on a machine follows the same line-ending rules, checked and fixed like tool versions.

### Added

- Parent-folder standard discovery and explicit recursive Extends inheritance, including relative parents, the packaged @development baseline, child overrides, and cycle detection.

- Shipped shared .NET developer baseline at `SecondLine/Standards/development.psd1`: Git 2+ and a selected stable .NET 10.0 SDK. Consumers inherit it with Extends = '@development' and override tools by Name for stricter project pins.

- `Test-SLRepo` finds git repos under a folder (worktrees and submodules too) and reports, per
  repo, whether its `.gitattributes` matches, extends or differs from its line-ending profile,
  or is missing, plus committed files that still need `git add --renormalize .`. Read-only.
  Files are compared by meaning, not text.
- `Set-SLGitAttributes` writes a missing `.gitattributes`, appends missing rules (keeping every
  existing line), replaces conflicting ones with `-Force`, then stages and renormalizes. It never
  commits, refuses a dirty working tree unless `-AllowDirty`, and supports `-WhatIf`.
- Built-in profiles `docs`, `powershell` and `dotnet`, shipped as files in the module, picked per
  repo by `-Profile`, a pin in the standard, or detection (a .NET solution or project, a module
  manifest, else docs).
- Optional `GitAttributes` section in the standard: add or replace profiles, pin repos to one.
- `Test-SecondLine -RepoPath` runs the repo check after the tools, in the same report and result.
- Static analysis with PSScriptAnalyzer (`PSScriptAnalyzerSettings.psd1`), run in CI on 5.1 and
  7 and locally with `build/Test-Lint.ps1`. It includes compatibility checks, so PowerShell
  7-only syntax and commands fail the build.
- `build/Publish-SecondLine.ps1` can read the Gallery API key from a SecretManagement vault
  (`-SecretName`, `-Vault`, `-NoVault`), and offers to save a pasted key there after a
  successful publish. See README, "Releasing".

### Changed

- A standard no longer needs `Tools` when it has a `GitAttributes` section.
- The example standard expects PowerShell 7.6 (`Rule = 'Minor'`), the current LTS; 7.4 and 7.5
  reach end of support on 2026-11-10.

## 0.2.0 - 2026-10-18

Local MongoDB replica sets on Windows, without the usual mlaunch pain.

- `Find-SLMongoReplicaSet` finds mlaunch replica sets by reading each `.mlaunch_startup`, and
  checks that every node's data folder exists, so a stale startup file is reported, not used.
  A copied startup file (say, in a backup folder) is recognised as a copy, because the folder it
  records isn't the one it sits in, so it doesn't make SecondLine think there are two sets.
- `Get-SLMongoStatus` reports UP / ELECTING / UNKNOWN / PARTIAL / DOWN, the PRIMARY, each
  member's state, and the `mongod` processes that belong to the set.
- `Start-SLMongo` starts the set, waits for every port, then waits for a PRIMARY so apps don't
  connect before the set can take writes.
- `Stop-SLMongo` escalates only as far as needed: `mlaunch stop`, then a clean shutdown command to
  each node (secondaries first, primary last), then stops this set's `mongod` processes, matched
  by data folder so nothing else listening on those ports is ever touched.
- Every `mlaunch` and `mongosh` call is bounded by a timeout; a `mongosh` that answers and never
  exits can't hang a command.
- Which set to use: `-Path`, then `SECONDLINE_MONGO_DIR`, then the one usable set found under
  `SECONDLINE_MONGO_ROOT` (default `~/mongo-dev`, `~/mlaunch`, `~/data`). With more than one,
  SecondLine asks instead of guessing.

## 0.1.0 - 2026-10-17

First release.

- `Test-SecondLine` audits a machine against a standard file and reports OK / MISMATCH /
  MISSING / UNKNOWN, with the fix command under every failure.
- `Get-SecondLineStandard` loads a standard file and reports every problem in it at once.
- Version rules: Exact, Minor, Major, Minimum.
- `Match = 'Any'` for tools that install side by side (e.g. `dotnet --list-sdks`).
- Prerelease builds (`-rc`, `-preview`, ...) keep their tag and are flagged, never reported as
  releases.
- Tools that answer but never exit are stopped at a timeout and flagged.
- `-PassThru`, `-Quiet` and `-Strict` for scripts and CI.
- Tested on Windows PowerShell 5.1 and PowerShell 7.
