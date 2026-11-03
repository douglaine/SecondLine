# Example SecondLine standard.
#
# Copy this next to your project (or anywhere, and point SECONDLINE_STANDARD at it),
# then run:  Test-SecondLine
#
# Each tool:
#   Name            what to call it in the report
#   Command         the executable on PATH
#   Expect          the version you want
#   Rule            Exact | Minor | Major | Minimum
#                     Exact    every part given must match   ('8.0.34' -> 8.0.34 only)
#                     Minor    same major.minor              ('8.0'    -> 8.0.x)
#                     Major    same major                    ('2'      -> 2.x)
#                     Minimum  this version or newer         ('2.40'   -> 2.40+)
# Optional:
#   Arguments       how to ask for the version (default: --version)
#   Match           First (default): use the first version in the output
#                   Any: the output lists several installed versions; OK if any one passes
#                   Prerelease builds (-rc, -preview ...) are always flagged in the report.
#   VersionPattern  regex to find the version in the output; a (?<version>...) group wins
#   Install         shown when the tool is missing or wrong, so the fix is one copy-paste away
#   TimeoutSeconds  stop waiting after this long (default: 15)
#
# GitAttributes (optional, for Test-SLRepo and Set-SLGitAttributes):
#   Profiles        add a line-ending profile, or replace a built-in one (docs, powershell,
#                   dotnet), as a list of .gitattributes lines
#   Repos           repo folder name -> profile, instead of auto-detection
# A standard needs Tools, GitAttributes, or both.

@{
    Name    = 'Example standard'
    Version = '1.0.0'

    Tools = @(
        @{
            Name    = 'git'
            Command = 'git'
            Expect  = '2.40'
            Rule    = 'Minimum'
            Install = 'winget install --id Git.Git -e'
        }
        @{
            # 7.6 is the current LTS; 7.4 and 7.5 reach end of support 2026-11-10.
            Name    = 'PowerShell 7'
            Command = 'pwsh'
            Expect  = '7.6'
            Rule    = 'Minor'
            Install = 'winget upgrade --id Microsoft.PowerShell -e'
        }
        @{
            # dotnet --version reports only the newest SDK (or the one global.json
            # pins), which may be a preview. SDKs install side by side, so list
            # them all and pass if any one satisfies the rule.
            Name      = '.NET SDK'
            Command   = 'dotnet'
            Arguments = '--list-sdks'
            Match     = 'Any'
            Expect    = '10.0'
            Rule      = 'Minor'
            Install   = 'winget install --id Microsoft.DotNet.SDK.10 -e'
        }
        @{
            # Long-supported line; match what production runs, never newer.
            Name           = 'MongoDB Server'
            Command        = 'mongod'
            Expect         = '8.0'
            Rule           = 'Minor'
            VersionPattern = 'db version v(?<version>\d+\.\d+\.\d+)'
            Install        = 'winget install --id MongoDB.Server -e --version 8.0.x'
        }
        @{
            Name           = 'mongosh'
            Command        = 'mongosh'
            Expect         = '2'
            Rule           = 'Major'
            TimeoutSeconds = 20
            Install        = 'winget install --id MongoDB.Shell -e'
        }
    )

    # GitAttributes = @{
    #     Profiles = @{
    #         web = @('* text=auto', '*.ts text eol=lf', '*.css text eol=lf', '*.png binary')
    #     }
    #     Repos = @{
    #         'docs-site'   = 'docs'
    #         'Contoso.Web' = 'web'
    #     }
    # }
}
