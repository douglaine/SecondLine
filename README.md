# SecondLine

[![test](https://github.com/douglaine/SecondLine/actions/workflows/test.yml/badge.svg)](https://github.com/douglaine/SecondLine/actions/workflows/test.yml)

Keep every dev machine in step.

Declare the tool versions your machines should run in **one file**, then audit each machine
against it. When something's off, the report tells you what's wrong and how to fix it.

```
  SecondLine - Example standard v1.0.0
  C:\src\myproject\secondline.standard.psd1

  OK        git            2.45.1       expect 2.40 (Minimum)
  OK        PowerShell 7   7.4.6        expect 7.4 (Minimum)
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

## In scripts and CI

```powershell
Test-SecondLine -PassThru -Quiet | Where-Object Status -ne 'OK'
Test-SecondLine -Strict        # throws if anything isn't OK
```

## Works on

Windows PowerShell 5.1 and PowerShell 7 on Windows, tested on both in CI. SecondLine is built
for Windows dev machines first; other platforms may work but aren't tested yet.

## License

[MIT](LICENSE)
