# SecondLine status

Where the project stands and what's next. Released work is in [CHANGELOG.md](../CHANGELOG.md).

## Current

- **0.2.0** (2026-10-18) on the PowerShell Gallery: machine audit (`Test-SecondLine`) and local
  MongoDB replica-set commands (`Start-/Stop-/Get-SLMongoStatus`, `Find-SLMongoReplicaSet`).

## To do

### IDE extension and workload sync

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
