# Changelog

All notable changes to SecondLine. Versions follow [Semantic Versioning](https://semver.org).

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
