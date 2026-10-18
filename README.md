# SecondLine

[![test](https://github.com/douglaine/SecondLine/actions/workflows/test.yml/badge.svg)](https://github.com/douglaine/SecondLine/actions/workflows/test.yml)

Keep every dev machine in step.

Declare the tool versions your machines should run in **one file**, then audit each machine
against it. When something's off, the report tells you what's wrong and how to fix it.

```
  SecondLine - Example standard v1.0.0
  C:\src\myproject\secondline.standard.psd1

  OK        git            2.45.1       expect 2.40 (Minimum)
  OK        PowerShell 7   7.6.1        expect 7.6 (Minor)
  OK        .NET SDK       10.0.100     expect 10.0 (Minor)
  MISMATCH  MongoDB Server 8.2.3        expect 8.0 (Minor)
            fix: winget install --id MongoDB.Server -e --version 8.0.x
  MISSING   mongosh        -            expect 2 (Major)
            'mongosh' is not on PATH.
            fix: winget install --id MongoDB.Shell -e

  3 of 5 tools OK
```

> Named for the New Orleans second line: the band sets the step, and everybody
> following falls in behind it.

## Why

Two machines that are "set up the same" drift within days: a tool upgraded on one, a script
edited on the other. SecondLine makes the expected setup a file you keep in git, and makes
checking a machine a one-liner. See [GOTCHAS.md](GOTCHAS.md) for the lessons that led here.

## Quick start

```powershell
Install-PSResource SecondLine        # PowerShell 7.4+; on 5.1: Install-Module SecondLine

# grab the example standard, then edit it for your team
Invoke-WebRequest https://raw.githubusercontent.com/douglaine/SecondLine/main/examples/secondline.standard.psd1 -OutFile secondline.standard.psd1
Test-SecondLine
```

`Test-SecondLine` is read-only. It never installs or changes anything.

## The standard file

```powershell
@{
    Name    = 'My team'
    Version = '1.0.0'
    Tools   = @(
        @{ Name = 'git';  Command = 'git';    Expect = '2.40'; Rule = 'Minimum'
           Install = 'winget install --id Git.Git -e' }
        @{ Name = 'MongoDB Server'; Command = 'mongod'; Expect = '8.0'; Rule = 'Minor'
           VersionPattern = 'db version v(?<version>\d+\.\d+\.\d+)' }
    )
}
```

| Rule | Meaning | `Expect = '8.0'` accepts |
|---|---|---|
| `Exact` | every part given must match | 8.0.x (`'8.0.34'` would accept only 8.0.34) |
| `Minor` | same major.minor | 8.0.x, not 8.2 |
| `Major` | same major | 8.x |
| `Minimum` | this version or newer | 8.0 and up |

Optional per tool: `Arguments` (default `--version`), `VersionPattern`, `Install`,
`TimeoutSeconds` (default 15; tools that answer but never exit are stopped and flagged).

`Match = 'Any'` is for tools that install side by side. `dotnet --version` reports only the newest
SDK, which may be a preview, so use `Arguments = '--list-sdks'; Match = 'Any'` and the check
passes if any installed SDK satisfies the rule. Prerelease builds (`-rc`, `-preview`, ...) are
always shown with their tag and flagged, never reported as releases.

The standard is found from `-Path`, then the `SECONDLINE_STANDARD` environment variable,
then `secondline.standard.psd1` in the current folder.

## Local MongoDB replica set (Windows)

Multi-document transactions and change streams need a replica set, even on a dev machine.
`mlaunch` creates one, but on Windows it's rough: `mlaunch stop` fails, nodes take a while to open
their ports, and apps that connect before a PRIMARY is elected can't write. SecondLine wraps it:

```powershell
Start-SLMongo        # start, wait for every port, then wait for a PRIMARY
Get-SLMongoStatus    # UP / ELECTING / PARTIAL / DOWN, PRIMARY, each member's state
Stop-SLMongo         # mlaunch stop -> clean shutdown -> kill (this set's mongod only)
```

```
  SecondLine - MongoDB replica set 'replset'  UP
  C:\Users\you\mongo-dev\data\replset

  27017  PRIMARY    C:\Users\you\mongo-dev\data\replset\replset\rs1\db
  27018  SECONDARY  C:\Users\you\mongo-dev\data\replset\replset\rs2\db
  27019  SECONDARY  C:\Users\you\mongo-dev\data\replset\replset\rs3\db

  PRIMARY: localhost:27017
```

**Which set?** SecondLine reads each `.mlaunch_startup` (written by `mlaunch init --dir <folder>`)
and checks that every node's data folder exists, so a stale startup file is reported, not used.
It looks at `-Path`, then `SECONDLINE_MONGO_DIR`, then searches `SECONDLINE_MONGO_ROOT` (default
`~/mongo-dev`, `~/mlaunch`, `~/data`). If it finds more than one usable set, it asks.
`Find-SLMongoReplicaSet` shows what it found and why each one is or isn't usable.

**Safe stop.** If it has to kill processes, it matches `mongod` by data folder, never by port, so
nothing else listening on 27017 is touched. `-NoKill` stops before that step.

Needs `mlaunch` (`pip install mtools`) and `mongosh` on PATH.

## In scripts and CI

```powershell
Test-SecondLine -PassThru -Quiet | Where-Object Status -ne 'OK'
Test-SecondLine -Strict        # throws if anything isn't OK
```

## Linting

The module is checked with [PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer)
in CI, on both Windows PowerShell 5.1 and PowerShell 7. Run the same check before pushing:

```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser   # once
.\build\Test-Lint.ps1                                # exits 1 on any Error or Warning
.\build\Format-SecondLine.ps1 -WhatIf               # layout fixes, same settings
```

The rules live in `PSScriptAnalyzerSettings.psd1` at the repo root, which VS Code's PowerShell
extension picks up automatically. They include `PSUseCompatibleSyntax` and
`PSUseCompatibleCommands` for 5.1 and 7, so PowerShell 7-only syntax (`??`, `?.`, ternaries,
`ForEach-Object -Parallel`) and commands fail the check.

## Works on

Windows PowerShell 5.1 and PowerShell 7 on Windows, tested on both in CI. SecondLine is built
for Windows dev machines first; other platforms may work but aren't tested yet.

## License

[MIT](LICENSE)
