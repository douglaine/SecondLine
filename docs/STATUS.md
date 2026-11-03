# SecondLine status

Where the project stands and what's next. Released work is in [CHANGELOG.md](../CHANGELOG.md).

## Current

- **0.2.0** (2026-10-18) on the PowerShell Gallery: machine audit (`Test-SecondLine`) and local
  MongoDB replica-set commands (`Start-/Stop-/Get-SLMongoStatus`, `Find-SLMongoReplicaSet`).

## To do

### Startup task runner

One entry point, called from `$PROFILE`, that runs a per-machine list of tasks according to a
config file, without slowing or blocking the shell.

- **Task registry in the module:** each task has a name, the function it calls, and a kind
  (check or action). New features register themselves; the runner never needs editing.
- **Per-machine config (`.psd1`):** turns each task on or off and sets how often it runs
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
  - If the config check fails, tasks stay off until it's fixed, rather than running on a config
    the new release reads differently.
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
