# Changelog

All notable changes to SecondLine. Versions follow [Semantic Versioning](https://semver.org).

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
