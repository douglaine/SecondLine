# Gotchas: keeping multiple dev machines in sync

Running notes from real sessions keeping two or more Windows dev machines consistent — same tools,
same versions, same scripts, same behavior. Each entry: what bit, why, and the fix.
Written generically — raw material for a future README, write-up, and answers.

---

## Drift

### Copying files between machines = drift
**Symptom:** the "same" script behaves differently on two machines a day later.
**Why:** files copied by hand (remote-desktop file managers, USB, email) get edited in one place and
not the other, and nobody can tell which copy is current.
**Fix:** one source of truth in git (or a package), pulled on each machine. Never edit the
deployed copy.

### Overwriting a script loses how things used to work
**Lesson:** an old start script was copied over before anyone recorded what it did. The knowledge
was gone.
**Fix:** scripts live in version control before anything replaces them. `.bak` copies are a
stopgap, not a system.

### "Works on my machine" usually means "different version on yours"
**Symptom:** one machine runs a tool a minor version (or a whole release line) apart from another,
and nobody noticed until something broke.
**Fix:** write the expected versions down in one file, and audit each machine against it.

---

## Code vs. machine settings

### Machine differences leak into code
**Symptom:** a path, port, or folder that's right on one machine is hard-coded, so the script works
there and fails elsewhere.
**Examples:** `C:\Users\<name>\...`; a data folder set up one level apart on two machines.
**Fix:** code is shared; settings are local. Scripts read a per-machine settings file. Build user
paths from `$HOME`. Where layouts genuinely differ, *detect* (search candidate folders for a marker
file) instead of assuming — and fail loudly if nothing matches.

### Putting machine settings inside a package re-creates drift
**Why:** every machine difference becomes a new package version.
**Fix:** the package ships code and defaults; each machine keeps its own settings file outside it.

---

## A versions standard

### Pin by rule, not just by number
Each tool gets an expected version **and** a match rule: exact, same minor (`8.0.x`), or minimum.
Include the install command, so a mismatch tells you how to fix it.

### Short-lived release lines make bad standards
Some vendors ship "rapid" minor releases that stop getting patches within about a year (MongoDB
8.2 went end-of-life ~11½ months after release; the 8.0 major line is supported ~5 years).
**Rule:** standardize on long-supported lines unless production deliberately follows the fast track.

### Match dev to production — never run newer
If dev machines run newer than production, code starts depending on features production doesn't
have. Find out what production (including a cloud service's managed version) actually runs, and
cap dev there.

### Some upgrades are one-way
Example: MongoDB Community can't downgrade server binaries in place (since 7.0); going back means
dump → fresh install → restore. Know which tools are one-way before upgrading any machine, and back
up data before changing binaries.

---

## Same script, different shell

### Windows PowerShell 5.1 and PowerShell 7 are not the same runtime
A script tested only in 7 can fail in 5.1, and `.cmd` wrappers launch **5.1**. Test under both.
Check which you're in: `$PSVersionTable.PSVersion`.

### 5.1: native tool stderr can abort your script
**Symptom:** a script dies partway through under 5.1 only.
**Why:** with `$ErrorActionPreference = 'Stop'`, 5.1 turns redirected stderr from native
executables into terminating errors.
**Fix:** run native calls in a `'Continue'` scope:
```powershell
& { $ErrorActionPreference = 'Continue'; some-native-tool args *> $null }
```

### 5.1: emoji and non-ASCII come out garbled (`≡ƒÜÇ`)
**Why:** 5.1 reads BOM-less files as the system code page, not UTF-8.
**Fix:** save `.ps1` files as UTF-8 **with BOM**.

### `@{` in a git argument is parsed as a hashtable
**Symptom:** `git log --oneline @{u}..HEAD` fails with *"Missing '=' operator after key in hash
literal."*
**Why:** in PowerShell, `@{` starts a hashtable literal. Commands copied from bash docs break.
**Fix:** quote the argument: `git log --oneline "@{u}..HEAD"`. Same for `"HEAD@{1}"` and
`"stash@{0}"`.

### 5.1: `Out-File -Encoding utf8` adds a BOM
**Why:** in Windows PowerShell 5.1, `utf8` means UTF-8 *with* BOM (PowerShell 7 defaults to no BOM).
Fine for `.ps1` files, unwanted for README, JSON, YAML and other files tools expect BOM-less.
**Fix:** write them with
`[IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))`.

### `.psd1` data files reject `$` inside double quotes
**Symptom:** `Import-PowerShellDataFile` fails with *"Cannot generate a PowerShell object for a
ScriptBlock evaluating dynamic expressions."*
**Why:** data files are restricted to literal values. A double-quoted string containing `$...`
counts as an expression, even if you meant it literally.
**Fix:** use single quotes for any value containing `$`: `Arguments = '-Command $PSVersionTable'`.

---

## Line endings

### The rule we follow
Every repo carries a `.gitattributes` that decides line endings, so no machine's git settings
(`core.autocrlf`) get a vote:
- **The repo stores LF.** `* text=auto` normalizes everything that looks like text.
- **Docs and config are LF everywhere:** `.md`, `.yml`, `.yaml`, `.json`, `.gitignore`,
  `.gitattributes`.
- **Windows scripts are CRLF on checkout:** `.ps1`, `.psm1`, `.psd1`, `.bat`, `.cmd`.
  Windows PowerShell 5.1 tooling and `cmd.exe` expect CRLF.
- **Binaries are marked `binary`** (`.png`, `.zip`, `.nupkg`, `.pfx`, `.dll` ...), so git never
  rewrites a byte.

```gitattributes
* text=auto

*.md           text eol=lf
*.yml          text eol=lf
*.yaml         text eol=lf
*.json         text eol=lf
.gitignore     text eol=lf
.gitattributes text eol=lf

*.ps1          text eol=crlf
*.psm1         text eol=crlf
*.psd1         text eol=crlf
*.bat          text eol=crlf
*.cmd          text eol=crlf

*.png          binary
*.zip          binary
*.nupkg        binary
```
Add the language's source types as LF (e.g. `*.cs`, `*.razor`, `*.csproj` for .NET).

SecondLine ships this rule as profiles (`docs`, `powershell`, `dotnet`): `Test-SLRepo C:\src`
checks every repo against them, and `Set-SLGitAttributes` writes or completes a repo's
`.gitattributes` and renormalizes it without committing. See the README, "Repos: line endings".

### "LF will be replaced by CRLF the next time Git touches it"
**Symptom:** `git add` warns about files you just created.
**Why:** the file on disk has LF endings (written by a tool, an editor set to LF, or generated on
Linux), and `.gitattributes` says that type is checked out CRLF. Git is announcing it will convert
the working copy. Harmless — the repo copy is correct either way.
**Fix (to stop the warnings now):** convert the working-copy files to match the rule, then
renormalize so git re-checks every file against `.gitattributes`:
```powershell
git add --renormalize .
git status          # only real content changes should remain
```

### Add `.gitattributes` in the first commit
Adding it to an existing repo means files already committed may have mixed endings. Then
`git add --renormalize .` and commit the result on its own, so the line-ending change doesn't
hide inside a real diff. (`Set-SLGitAttributes` does the renormalize and stops before the
commit; it refuses to run on a dirty tree for this reason.)

### After adding `.gitattributes`, untouched files show as modified
**Symptom:** `git status` lists files you never edited as modified, right after a
`.gitattributes` change.
**Why:** files committed with CRLF no longer match what the new rules would store (LF). When git
re-checks a file, it sees the difference. Whether it re-checks depends on timestamps, so it can
come and go between runs.
**Fix:** that's what `git add --renormalize .` is for. To tell real edits apart, compare ignoring
line endings: `git diff --ignore-cr-at-eol --name-only` lists only files with real changes.

---

## Testing with Pester

### "No modules named 'X' are currently loaded" during Discovery
**Symptom:** CI fails before a single test runs: *"Discovery in ... failed with: No modules named
'X' are currently loaded."* It may pass on your machine because the module is already imported in
your session.
**Why:** Pester 5+ runs in two phases. `InModuleScope` placed at `Describe` level runs during
**discovery**, which happens before any `BeforeAll`, so the import hasn't happened yet.
**Fix:** also import the module in `BeforeDiscovery { Import-Module ... -Force }` at the top of the
test file.

### Windows ships Pester 3.4, and `Install-Module Pester` won't replace it
**Symptom:** `Install-Module Pester -MinimumVersion 5.5` warns *"Version '3.4.0' of module 'Pester'
is already installed"* and installs nothing. Tests needing Pester 5 then fail.
**Why:** Windows includes Pester 3.4.0 in `C:\Program Files\WindowsPowerShell\Modules`, signed by
Microsoft. Installing a newer version beside it needs `-Force`, and newer Pester is signed by a
different publisher, so it also needs `-SkipPublisherCheck`.
**Fix:**
`Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force -SkipPublisherCheck`.
Leave 3.4 alone; the newer version wins when loaded.

### Your tests passing locally proves less than you think
A module already loaded in your session hides missing imports. Run tests in a fresh process
(`pwsh -NoProfile -Command Invoke-Pester`), or let CI be the judge.

---

## Git and GitHub on Windows

### `Remove-Item -Recurse` skips hidden files without `-Force`
**Symptom:** *"Directory ... cannot be removed because it is not empty"* on a folder that looks
empty.
**Why:** hidden files (on Windows the Hidden attribute; on Linux and macOS any dotfile, such as
`.mlaunch_startup`) are skipped unless you pass `-Force`.
**Fix:** `Remove-Item <folder> -Recurse -Force`.

### A repo folder won't delete
**Symptom:** `rmdir` / `Remove-Item` on a cloned repo fails with *"You do not have sufficient access
rights... or the item is hidden, system, or read only"* on files under `.git\objects`.
**Why:** git marks its object files read-only, and `Remove-Item` won't delete read-only files
without `-Force`.
**Fix:** `Remove-Item <folder> -Recurse -Force`. If it still fails, something has the folder open
(a terminal inside it, an editor, Explorer).

### `gh repo delete` is refused
**Why:** the GitHub CLI doesn't get permission to delete repos by default.
**Fix:** grant it once with `gh auth refresh -h github.com -s delete_repo`, then delete.

### Ahead/behind is only as fresh as your last fetch
**Symptom:** `git status` says "up to date" while the remote has new commits.
**Why:** status compares against your local copy of the remote, not the remote itself.
**Fix:** `git fetch --prune` first (read-only, never touches your files), then `git status -sb`.

---

## Case study: a local MongoDB replica set on every machine

### You need a replica set locally, not a standalone `mongod`
Multi-document transactions and change streams require a replica set; the default standalone
install doesn't support them. If the app needs them, a local replica set is a requirement of every
dev machine — put it in the standard.

### A stale `.mlaunch_startup` can point at folders that don't exist
**Symptom:** scripts work on one machine and fail on another, or work only because they happen to
check one folder before another.
**Why:** each `mlaunch init --dir X` writes `X\.mlaunch_startup`. Re-running init in a different
folder, or moving data, leaves the old file behind. It still looks valid, but the node data folders
it names (recorded as `--dbpath` under `startup_info`) are gone.
**Fix:** don't pick a folder by search order. Read each `.mlaunch_startup`, check that every
`--dbpath` it records exists, and use the one that's valid; if more than one is, ask.

### A backed-up `.mlaunch_startup` looks like a second replica set
**Symptom:** a copy of the startup file kept in a backup folder points at the same, existing data
folders, so it passes the "do the folders exist?" check too.
**Fix:** every `.mlaunch_startup` records the folder it was created for (`parsed_args.dir`). If
that isn't the folder the file sits in, it's a copy. Ignore it.

### Kill by data folder, never by port
When a stop has to fall back to killing processes, killing "whatever owns port 27017" can take out
something that isn't your replica set. Match `mongod` processes by the `--dbpath` in their command
line instead (`Win32_Process.CommandLine` on Windows).

### "Started" isn't "ready"
Wait for the ports to listen (allow ~60 s on a cold start), then for a PRIMARY to be elected.

### Stopping needs escalation
`mlaunch stop` doesn't always stop. Escalate: `mlaunch stop` → wait → clean `shutdown` via
`mongosh` (**secondaries first, primary last**) → wait → only then hard-kill.

### `mongosh` answers but doesn't exit
**Suspected cause (unconfirmed):** telemetry sent on exit. Test with
`mongosh --eval "disableTelemetry()"` once per machine. In scripts, put a timeout on `mongosh`
calls regardless.

### Cloud managed versions lag
Azure DocumentDB (formerly Cosmos DB for MongoDB vCore) runs MongoDB 8.0; the RU-based Cosmos DB
for MongoDB was at 7.0 at last report. Neither offers rapid releases. Cap dev at what the cloud
service runs, and verify specific features (e.g. `$merge`) against it.
