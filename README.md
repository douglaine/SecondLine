# SecondLine

[![test](https://github.com/douglaine/SecondLine/actions/workflows/test.yml/badge.svg)](https://github.com/douglaine/SecondLine/actions/workflows/test.yml)

Keep every dev machine in step.

Declare the tool versions your machines should run in **one file**, then audit each machine
against it. When something's off, the report tells you what's wrong and how to fix it.
It also checks that every git repo on the machine follows the same line-ending rules.

**New in 0.4.0:** [one rulebook for every AI coding agent](#one-rulebook-for-every-ai-coding-agent-040).
Keep `CLAUDE.md` and `AGENTS.md` in every repo pointed at the same versioned rules, and audit
them all in one command.

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

`AppliesWhen` limits a tool to the places it matters. It's a list of file patterns, and the
tool is only checked in a git repo containing a matching file (bin, obj and node_modules
ignored), or, outside a repo, in a folder that has one. Elsewhere it's reported as `SKIPPED`,
which isn't a failure and doesn't trip `-Strict`. For example, so the .NET SDK isn't flagged
in a PowerShell repo:

```powershell
@{ Name = '.NET SDK'; Command = 'dotnet'; Expect = '10.0'; Rule = 'Minor'
   AppliesWhen = @('global.json', '*.sln', '*.slnx', '*.csproj') }
```

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
Test-SLLineEnding -Path . -Strict       # line-ending rules and working copies
Test-SLPolicyReference -Path . -Strict  # agent entry points, policy copy, checkpoint
```

Checks are deterministic in CI: machine and user settings are ignored there, and no update
lookup runs.

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

`build/Test-SecondLinePackage.ps1` validates the actual package without publishing anything. It
builds the `.nupkg` with `Compress-PSResource` (PowerShell 7.4+), checks the required assets
(help, bootstrap, shared policy, status template, standards and profiles) and the excluded
development files, then imports the extracted package in a fresh process.

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

## Shared developer baseline (0.3.0)

`SecondLine/Standards/development.psd1` provides the common Git and .NET baseline.
Projects inherit it with `Extends = '@development'` and keep project-specific SDK
requirements in their own standard. Subfolders discover the nearest standard.
Use the same reviewed SecondLine release across projects; editing a local checkout
does not update installed Gallery copies. Child overrides intentionally replace named
requirements, so review them when changing a project's standard.

The baseline's .NET SDK check has `AppliesWhen`, so it only runs in repos with .NET in them
(a `global.json`, `.sln`, `.slnx`, `.csproj` or `.fsproj`). If you override that tool by
name in your own standard, copy `AppliesWhen` too, or the check applies everywhere.

This baseline only audits configuration. It does not install tools, change SDK pins,
or start or stop MongoDB instances.

### Inherit a shared standard

When no `-Path` or `SECONDLINE_STANDARD` is supplied, SecondLine searches the current folder and then its parents for the nearest `secondline.standard.psd1`. A nested project can use that standard unchanged, or declare its own standard with an explicit parent:

```powershell
@{
    Extends = '@development'
    Name = 'My project environment'
    Tools = @(
        @{ Name = '.NET SDK selected by this repository'; Command = 'dotnet'; Expect = '10.0.401'; Rule = 'Exact' }
    )
}
```

`@development` resolves to the baseline inside the installed SecondLine package. Other `Extends` values are absolute paths or paths relative to the declaring file, for example `../secondline.standard.psd1`. One parent is supported per file; parents may themselves extend another standard. Missing parents and circular inheritance are errors (maximum chain: 64 files).

Child tools replace complete parent entries with the same `Name`, case-insensitively; other parent tools remain. Child metadata overrides parent metadata. `GitAttributes.Profiles` and `GitAttributes.Repos` merge by key, with child values winning. Inheritance reads data files only and installs or starts nothing.

## Help front door (0.4.0)

```powershell
Show-SLHelp                       # version, configuration, version policy, command catalog
Show-SLHelp -Command Stop-SLMongo # full help for one command; never runs it
Show-SLHelp -CheckForUpdates      # force a background refresh
Show-SLHelp -NoUpdateCheck        # start no check (offline, automation)
Get-Help about_SecondLine
```

The catalog is discovered from the loaded module's exports and each command's own help
synopsis, so new exported commands appear automatically. A missing or invalid configuration
doesn't stop help from working.

Opening help reads the shared update cache (see below). If that result isn't current, help
starts one background lookup and returns at once. A newer-version notice appears when the
lookup finishes. Up-to-date results stay quiet. Help never installs anything.

## Approved SecondLine version per project (0.4.0)

A project approves its SecondLine version once, in its standard, instead of every script
hardcoding `Import-Module SecondLine -RequiredVersion ...`:

```powershell
# secondline.standard.psd1 at the project root
@{
    Extends        = '@development'
    ModuleVersions = @{ SecondLine = '0.4.0' }
}
```

Subprojects inherit it through nearest-parent discovery or `Extends`. A nearer file can
pin a different version. A loaded module can't choose its own version, so scripts select it
**before** import with the bootstrap. Copy `SecondLine/Bootstrap/Import-SecondLine.ps1` from
the approved package into the repo (for example `build/Import-SecondLine.ps1`), then:

```powershell
& "$PSScriptRoot\Import-SecondLine.ps1" -Path $PSScriptRoot
```

The bootstrap reads data files only, imports exactly the approved version, and refuses to
swap an already loaded different version. It never installs anything: if the version is
missing, it prints the install command for you to review.

### Settings layers

| Section | Precedence (lowest first) | Purpose |
|---|---|---|
| `ModuleVersions` | machine < user < project chain (root parent < ... < nearest file) | execution policy: a project value always wins |
| `Updates` | defaults < project chain < machine < user | notification preferences: personal, never change a version |

Machine settings live in `CommonApplicationData\SecondLine\settings.psd1`
(`SECONDLINE_MACHINE_SETTINGS`), and user settings in
`ApplicationData\SecondLine\settings.psd1` (`SECONDLINE_USER_SETTINGS`). Both use the same
sections. In CI (`CI`, `GITHUB_ACTIONS` or `TF_BUILD`), or with
`SECONDLINE_NO_HOST_SETTINGS=1`, those two files are ignored, so CI depends only on the
repository. `Get-SLSetting` shows every value, its source and what it overrode.
`Get-SLSetting -NoHostSettings` shows what CI sees.

Publishing a release, installing it, being notified about it, and approving it for a project
are four separate steps. A new Gallery release never changes a project's approved version.

## Update notices (0.4.0)

```powershell
Get-SLUpdateStatus             # offline: update, version policy, advisories, from the cache
Invoke-SLUpdateCheck           # explicit refresh (bounded); prints one line
Invoke-SLUpdateCheck -Force    # refresh even if the cache is current or backing off
```

- **One cache, shared:** one per user per machine, in `LocalApplicationData\SecondLine`
  (`SECONDLINE_CACHE_DIR`). Every session, project and help call shares it.
- **Writes and locking:** writes are atomic, and a lock file stops concurrent sessions from
  repeating a lookup.
- **Requests:** stable releases only by default. Results refresh daily (`Updates.RefreshHours`).
  Each request times out after 3 s (`TimeoutSeconds`) and is retried once (`Retries`), with a
  1 MB response limit. A failure backs off for 60 minutes (`FailureBackoffMinutes`).
- **What is checked:** only SecondLine, only on the PowerShell Gallery.
- **Results:** `Get-SLUpdateStatus` keeps three categories apart:
  - update available
  - version-policy mismatch: the loaded version is not the one the project approves
  - security advisory: always `NotConfigured`, because there is no advisory source and
    SecondLine doesn't invent one

  A failed or offline lookup reports `Failed` and unknown, never up to date.
- **Notices:** each actionable notice, such as `SecondLine 0.4.1 available; installed 0.4.0.`,
  is shown once.
- **Turning checks off:** checks are off in CI and with `SECONDLINE_NO_UPDATE_CHECK=1`.

### Optional profile integration

Nothing is added to your profile unless you run this yourself:

```powershell
Enable-SLProfileUpdateCheck -Path $PROFILE.CurrentUserAllHosts -WhatIf   # preview
Enable-SLProfileUpdateCheck -Path $PROFILE.CurrentUserAllHosts
Disable-SLProfileUpdateCheck -Path $PROFILE.CurrentUserAllHosts          # remove it again
```

The block between `# >>> SecondLine update check >>>` and `# <<< SecondLine update check <<<`
runs only in interactive shells. It shows a pending notice, if there is one. When the shared
cache is due, it starts one hidden, no-profile PowerShell that runs `Invoke-SLUpdateCheck` and
exits. Startup reads two small files and never waits on the network.

The block doesn't import SecondLine into your shell, so project bootstraps can still select
their approved version. Running Enable again updates the block in place. Other profile
content, the encoding and the line endings are kept. No scheduled task or service is
registered.

## Line endings, end to end (0.4.0)

```powershell
Test-SLLineEnding -Path C:\src            # report (read-only)
Test-SLLineEnding -Path . -Strict         # CI: throws if any repo has an issue
Repair-SLLineEnding -Path C:\src\MyApp -WhatIf
Repair-SLLineEnding -Path C:\src\MyApp -File build/Run.ps1 -Scope Files
```

`Test-SLLineEnding` compares three things for tracked files and untracked files that aren't
ignored:

- **Rules:** the effective `.gitattributes`, as git computes it; the applicable `.editorconfig`
  files, local and parent, up to `root = true`; and explicit VS Code `files.eol` settings,
  global or per-language, in `.vscode/settings.json` and `*.code-workspace`.
- **The working copy:** the endings actually in each file.
- **Git's stored copy.**

It reports `Mixed`, `WrongEnding`, `EditorConfigConflict`, `VSCodeConflict` and `Renormalize`
(stored with CRLF). A `.gitattributes` eol is the rule. Without one, `.editorconfig`
`end_of_line` is. Without either, a file only has to be consistent. Binary files are skipped,
and intentional CRLF (for example `*.ps1 eol=crlf`) is respected.

`Repair-SLLineEnding` converts line endings only, byte for byte. Encoding, BOM, content and a
missing final newline stay as they were, and the result is checked before an atomic write.
Tracked files with uncommitted edits are skipped unless `-AllowModified`. It also makes
`.editorconfig` and VS Code settings agree with `.gitattributes`, only where every affected
file provably agrees. Anything else is listed as manual work. It never stages: Git's stored
copy is renormalized by `Set-SLGitAttributes`.

Limits: VS Code applies `files.eol` to new files only, and user-level settings and
`files.associations` are not read. Editors don't control scripts or generators: those must
write the declared endings explicitly.

## One rulebook for every AI coding agent (0.4.0)

**Claude Code reads `CLAUDE.md`. Codex and most other agents read `AGENTS.md`. Every repo you own
needs both, they need to say the same thing, and they need to stay current. SecondLine keeps all
of that in step, the same way it keeps your tools in step.**

The ground rules you want every agent to follow are almost always the same, whatever the repo:
don't commit or publish without being asked, preserve uncommitted work, respect line endings,
write down where you stopped so the next session can pick up. Projects add their own rules on
top. The hard part isn't writing those rules once. It's keeping them identical across a dozen
repos and two agents for months.

### Doing it by hand

Here's what that takes without SecondLine:

1. **Write the shared rules.** Put them in a file somewhere, say a `rules.md` in a notes folder.
2. **Copy them into every repo.** Paste them into each repo's `CLAUDE.md`, then paste them again
   into `AGENTS.md`, below whatever project-specific instructions are already there. Twelve repos,
   twenty-four files.
3. **Keep the pairs identical.** Every time you tweak a project rule in `CLAUDE.md`, remember to
   make the same edit in `AGENTS.md`. Otherwise the two agents quietly follow different rules in
   the same repo, and you find out when one of them does something the other never would.
4. **Change a shared rule.** Open all twenty-four files and edit each one, without disturbing the
   project-specific lines around it. Miss one and that repo is running last month's rules.
5. **Figure out which copy is current.** Six weeks later, three repos have slightly different
   wording. Which one is right? Nothing says. You diff them by eye and guess.
6. **Don't point at your own folder.** The tempting shortcut is a line like "read
   `C:\Users\me\notes\rules.md`". It works on your laptop, fails on your other machine, and fails
   in CI, where nobody has your folder.
7. **Keep a handoff note.** Agents work best when each session starts from a short record of
   where the last one stopped: branch, what's done, what's left, what was actually verified.
   By hand, that's a file you have to remember to create in every repo, keep the same shape,
   and keep secrets out of.
8. **Check all of it, regularly.** Go repo by repo: are both files there? Do they match? Is the
   rules copy current? Is the handoff note complete? Is there a pasted token in it?

Most people give up around step 4, and the drift starts.

### Doing it with SecondLine

```powershell
Export-SLPolicy        -Path C:\src\MyApp            # drop in the versioned, hash-stamped rulebook
New-SLStatusCheckpoint -Path C:\src\MyApp            # start the handoff note from the template
Test-SLPolicyReference -Path C:\src -Strict          # audit every repo under C:\src at once
```

Each repo's `CLAUDE.md` and `AGENTS.md` keep their own project instructions, with two marker lines
at the top that point both agents at the same shared rulebook and handoff note:

```text
SecondLine-Policy: 1 docs/shared-development-policy.md
SecondLine-Status: docs/status/current.md
```

What you get:

- **One rulebook, versioned.** The copy in each repo carries its version and a SHA-256 on its first
  line, so anyone (or CI) can verify it offline, with no path to anyone's machine.
- **Both agents, same rules.** The audit flags a repo where `CLAUDE.md` and `AGENTS.md` have drifted
  apart, or where one is missing.
- **Updates you control.** `Export-SLPolicy` never edits your entry points, and it refuses to
  overwrite a copy someone changed locally. A modified copy is reported, not silently replaced.
- **A handoff note with a fixed shape.** `docs/status/current.md` records the branch and base
  commit, what's done and what's left, changed files, checks labelled `Verified` or `Planned`
  with evidence, blockers, and the exact next action. It's a record to check, never permission to
  proceed, and the audit flags anything in it that looks like a credential.
- **Your whole machine in one sweep.** `Test-SLPolicyReference` reports missing or differing entry
  points, broken, non-portable, modified or outdated rulebook references, incomplete handoff
  notes, and hardcoded SecondLine versions, for every repo under a folder.

Adopting it in an existing repo, step by step: [docs/consumer-migration.md](docs/consumer-migration.md).
