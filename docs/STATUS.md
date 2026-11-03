# SecondLine status

Where the project stands and what's next. Released work is in [CHANGELOG.md](../CHANGELOG.md).

## Current

- **0.3.0** (2026-10-21) on the PowerShell Gallery: standards with parent-folder discovery and
  `Extends` inheritance (including the shipped `@development` baseline), repo line-ending checks
  and fixes (`Test-SLRepo`, `Set-SLGitAttributes`), PSScriptAnalyzer in CI.
  - 0.3.0 was released from `feature/repo-line-endings` (tagged `v0.3.0`) and is not merged into
    `main` yet. `main` still carries 0.2.0 code.
- **0.2.0** (2026-10-18): local MongoDB replica-set commands (`Start-/Stop-/Get-SLMongoStatus`,
  `Find-SLMongoReplicaSet`).

## To do

### Startup task runner

One entry point, called from `$PROFILE`, that runs a per-machine list of tasks according to a
config file, without slowing or blocking the shell.

- **Task registry in the module:** each task has a name, the function it calls, and a kind
  (check or action). New features register themselves; the runner never needs editing.
- **Per-machine config:** build on the 0.3.0 standard file rather than a second config format.
  Add an optional `Tasks` section to the standard, the way `GitAttributes` was added, so tasks
  inherit through `Extends` like everything else: a shared baseline can list tasks (all off),
  and each machine's standard overrides by name to turn on what it wants. It turns each task on or off and sets how often it runs
  (`Startup`, `Daily`, `Weekly`, `OnDemand`). Read with `Import-PowerShellDataFile`, which works in
  5.1 and 7. Everything is opt-in: no config file means nothing runs, and a task a new release
  adds stays off until the user turns it on, so an upgrade never starts Mongo or anything else
  on its own. `New-SLConfig` writes a starter file with every task listed and disabled.
- **Entry point:** `Invoke-SLStartup` reads the config, checks each task's last-run stamp, and
  starts what's due. `Invoke-SLTask <name>` runs one on demand.
- **How tasks run:**
  - *Checks* (fast, read-only, such as the version audit or `Get-SLMongoStatus`): thread jobs started
    after the prompt appears (`OnIdle` engine event), each with a hard timeout.
  - *Actions* (slow or changing, such as IDE sync or installs): Task Scheduler, so they run without a
    terminal open and can run elevated. Startup only reports that one is due.
  - *Interactive* (anything that may need to ask, such as picking between replica sets): on demand.
- **The Mongo commands are the first real tasks.** Since 0.2.0 every `mlaunch` and `mongosh` call
  has a timeout, so they can't hang a job. `Get-SLMongoStatus` fits as a startup check.
  `Start-SLMongo` waits for every port and a PRIMARY, so it belongs in a background job, not inline.

- **Clean first run after an upgrade (safe mode):** the runner stamps the SecondLine version it
  last ran under. When the installed version differs, that startup runs no tasks at all. It only
  checks the config against the new release's task list (unknown or renamed task names, settings
  that changed shape), writes a short report ("2 new tasks available, off; config OK"), and
  updates the stamp. The next shell start runs the selected tasks normally.
  - The "reboot" is the next shell open, or `Invoke-SLStartup` by hand. The runner does not
    relaunch the terminal itself: it can't cleanly replace the user's window, and a bad task
    could loop.
  - If the config check fails, or the new version won't import at all, roll back to the
    last-known-good version (below) instead of running on a config the new release reads
    differently.
- **Rollback to last-known-good:** this works because `Update-Module` and `Install-Module`
  install each version side by side in its own folder (`SecondLine\0.2.0\`, `SecondLine\0.3.0\`)
  and leave the old one in place.
  - A small stub in `$PROFILE` imports SecondLine by a pinned version read from a pointer file
    (`Import-Module SecondLine -RequiredVersion <good>`), not whatever is newest. The rollback
    logic lives in that stub, not in the module, because a broken release may not import far
    enough to roll itself back.
  - Upgrade flow: the stub sees a newer version installed, imports it, and runs the safe-mode
    check. On pass it moves the pointer to the new version. On fail it re-imports the pinned
    version, keeps the pointer where it was, and reports why ("0.3.0 failed config check: task
    `MongoStart` renamed; still on 0.2.0").
  - The config is backed up before the check, so a rollback restores the config the old version
    expects too.
  - If the old version folder is gone (`Uninstall-Module -AllVersions`, manual cleanup), there's
    nothing to roll back to: report it and run no tasks.
  - Rollback is only for upgrade failures. An ordinary task failure is the crash guard's job.
- **Update check against the PowerShell Gallery:** a built-in check task (off by default, at
  most daily) asks the Gallery for the newest published SecondLine and compares it with the
  installed version. If newer, the next prompt shows "SecondLine 0.3.0 available". Read-only:
  nothing about the machine is sent, and there's no server of our own.
  - Use `Find-PSResource` (PSResourceGet, built into PowerShell 7.4+) when present; fall back to
    `Find-Module` on 5.1.
  - On 5.1, an old PowerShellGet can stop and ask to install the NuGet provider. In a
    background job that prompt hangs forever, so if the provider is missing, skip the check and
    report it instead of calling `Find-Module`.
  - 5.1 may also need TLS 1.2 enabled for the session to reach the Gallery.
  - Offline or slow: the job times out quietly and tries again next day. It never delays a shell.
  - The check only reports. Installing stays a deliberate `Update-Module`, and the safe-mode
    first run and rollback take over from there.
- **Crash guard:** a task that fails or times out on two starts in a row is marked suspended and
  skipped until the user clears it (`Resume-SLTask <name>`), so one broken task can't break
  every shell.

Rules:

- Never wait on a startup job from the profile (no `Wait-Job`, no `Receive-Job -Wait`), and don't
  let a child process inherit the console's output handle. Either one brings back the stuck-startup
  hang.
- Background jobs can't prompt or elevate. A task that might need to belongs on demand.
- Jobs write results to a status file. The next prompt shows a one-line summary instead of
  printing over what you're typing.
- Config and last-run stamps live in a local per-user folder that OneDrive doesn't sync, so two
  machines never share one stamp. PowerShell 7.7 plans to move user content out of Documents for
  the same reason.

### IDE extension and workload sync

Becomes a task under the runner (an action, `Weekly`), once the runner exists.

Make every dev machine end up with the same IDE tooling automatically, driven by files in each repo.

- **Visual Studio:** read the repo's `.vsconfig` and run the Visual Studio Installer
  `modify --config .vsconfig --passive` against the instance found with `vswhere.exe`.
  Covers workloads and components, including the Aspire tooling in the ASP.NET workload.
  Idempotent, so safe to rerun.
- **Visual Studio marketplace extensions:** install downloaded `.vsix` files with
  `VSIXInstaller.exe /q`.
- **VS Code:** read `.vscode/extensions.json` recommendations and run
  `code --install-extension <id>` for anything missing; `code --list-extensions` for the
  export side.
- **IDE-independent tools:** `winget` for Visual Studio, VS Code and the .NET SDK;
  `dotnet tool` for global tools; the Aspire CLI.

Gotchas to handle:

- The Visual Studio Installer won't modify an instance while `devenv.exe` is running. Check
  first and stop with a clear message instead of hanging.
- Installer changes need admin; `code --install-extension` must run as the normal user or the
  extensions land in the wrong profile. Two privilege levels in one command.

Working name: `Sync-SLIdeExtensions`.
