# SecondLine

[![test](https://github.com/douglaine/SecondLine/actions/workflows/test.yml/badge.svg)](https://github.com/douglaine/SecondLine/actions/workflows/test.yml)

Keep every dev machine in step.

Declare the tool versions your machines should run in **one file**, then audit each machine
against it. When something's off, the report tells you what's wrong and how to fix it.
It also checks that every git repo on the machine follows the same line-ending rules.

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

## Repos: line endings

Every repo should carry a `.gitattributes` that decides line endings, so no machine's
`core.autocrlf` gets a vote (see [GOTCHAS.md](GOTCHAS.md), "Line endings"). SecondLine checks
that across all the repos on a machine, and fixes it:

```powershell
Test-SLRepo C:\src                             # read-only: every repo up to 2 folders down
Set-SLGitAttributes C:\src\docs-site -WhatIf   # show what it would write and run
Set-SLGitAttributes C:\src\docs-site           # write it, stage it, renormalize; never commits
```

```
  SecondLine - repo line endings
  C:\src  (built-in profiles)

  DIFFERS   Contoso.Api  dotnet (found src\Contoso.Api\Contoso.Api.csproj)  3 to renormalize
            missing:  text eol=crlf: *.bat *.cmd *.ps1 *.psm1 *.psd1
            conflict: *.sln: profile has 'text eol=crlf', repo has 'text eol=lf'
            committed with CRLF or mixed endings:
              README.md
              build.ps1
              src/Contoso.Api/Contoso.Api.csproj
            fix: Set-SLGitAttributes -Path 'C:\src\Contoso.Api' -Force   # replaces the conflicting lines
  MISSING   docs-site    docs (no .NET project or module manifest found)    3 to renormalize
            no .gitattributes
            fix: Set-SLGitAttributes -Path 'C:\src\docs-site'
  EXTENDS   MyApp        dotnet (found MyApp.slnx)                          -
            extra:    tools/git-hooks/* text eol=lf
  MATCHES   MyModule     powershell (found MyModule\MyModule.psd1)          -

  2 of 4 repos OK
```

**What it checks.** Files are compared by meaning, not text: comments, blank lines, spacing and
order don't matter, and `binary` equals `-diff -merge -text`. A repo **MATCHES** its profile,
**EXTENDS** it (every profile rule plus its own, which is fine), **DIFFERS** (a rule is missing,
or a pattern has different attributes), or is **MISSING** a `.gitattributes`. It also counts
committed text files whose stored copy still has CRLF or mixed endings, which need
`git add --renormalize .`. A repo is OK when it matches or extends and nothing needs
renormalizing.

**Profiles.** Three are built in, each a real file under `SecondLine/Profiles/gitattributes`:

| Profile | For | Picked when |
|---|---|---|
| `dotnet` | .NET solutions: source LF, `*.sln` CRLF (Visual Studio writes it that way) | a `.sln`, `.slnx`, `.csproj` or `.fsproj` within 3 folders |
| `powershell` | PowerShell modules (SecondLine's own `.gitattributes`) | a module manifest (`.psd1` with `RootModule` or `ModuleVersion`) within 2 folders |
| `docs` | docs and notes: text LF, Windows scripts CRLF | anything else |

`-Profile` overrides the choice for every repo; the report says which rule picked each one.

**Fixing.** `Set-SLGitAttributes` writes a missing file from the profile, appends missing rules
under `# Added by SecondLine` (keeping every existing line), and refuses conflicting rules unless
you pass `-Force`, which replaces just those lines. It writes UTF-8 without BOM, LF. Then it runs
`git add .gitattributes` and `git add --renormalize .` and shows what's staged. It never commits.
It refuses to run on a repo with uncommitted changes to tracked files (`-AllowDirty` to
override), so the line-ending change gets a commit of its own. Pipe from the check to fix several:

```powershell
Test-SLRepo C:\src -PassThru -Quiet | Where-Object Status -eq 'MISSING' | Set-SLGitAttributes
```

**In the standard file** (optional; the commands work without one), add or replace profiles and
pin repos by folder name:

```powershell
@{
    GitAttributes = @{
        Profiles = @{
            web = @('* text=auto', '*.ts text eol=lf', '*.png binary')
        }
        Repos = @{
            'docs-site' = 'docs'
        }
    }
}
```

A standard can have `Tools`, `GitAttributes`, or both. `Test-SecondLine -RepoPath C:\src` runs
the repo check after the tool checks, in the same report, and `-Strict` counts the repos too.

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

## Releasing

`build/Publish-SecondLine.ps1` runs every release check (manifest, changelog, clean and pushed
git, tests in a fresh process, package contents), then publishes and tags. Try it with `-WhatIf`
first: that runs every check and publishes nothing.

The PowerShell Gallery API key comes from `SECONDLINE_GALLERY_KEY` if set, else from a secret
vault, else a hidden prompt. To store the key once instead of pasting it every release:

```powershell
Install-Module Microsoft.PowerShell.SecretManagement, Microsoft.PowerShell.SecretStore -Scope CurrentUser
Register-SecretVault -Name LocalStore -ModuleName Microsoft.PowerShell.SecretStore -DefaultVault
Set-Secret -Name SecondLine.GalleryApiKey      # paste the key at the prompt
```

The script reads the secret only at the moment of publishing (`-SecretName` and `-Vault` pick a
different one; `-NoVault` always prompts). After a successful publish from a pasted key, it offers
to save the key to your default vault, and never saves without asking.

SecretStore asks for its own password once per session (default timeout 15 minutes). That's the
point: the key is encrypted at rest and useless without the password. You can turn the password
off with `Set-SecretStoreConfiguration -Authentication None`; then anyone who can run code as
you can read the key, protected only by your Windows account. Gallery keys expire: if the stored
key is rejected, the script says so and stops, and `Set-Secret -Name SecondLine.GalleryApiKey`
replaces it.

## Works on

Windows PowerShell 5.1 and PowerShell 7 on Windows, tested on both in CI. SecondLine is built
for Windows dev machines first; other platforms may work but aren't tested yet.

## License

[MIT](LICENSE)
