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

---

## Case study: a local MongoDB replica set on every machine

### You need a replica set locally, not a standalone `mongod`
Multi-document transactions and change streams require a replica set; the default standalone
install doesn't support them. If the app needs them, a local replica set is a requirement of every
dev machine — put it in the standard.

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
