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
#   VersionPattern  regex to find the version in the output; a (?<version>...) group wins
#   Install         shown when the tool is missing or wrong, so the fix is one copy-paste away
#   TimeoutSeconds  stop waiting after this long (default: 15)

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
            Name    = 'PowerShell 7'
            Command = 'pwsh'
            Expect  = '7.4'
            Rule    = 'Minimum'
            Install = 'winget install --id Microsoft.PowerShell -e'
        }
        @{
            Name    = '.NET SDK'
            Command = 'dotnet'
            Expect  = '10.0'
            Rule    = 'Minor'
            Install = 'winget install --id Microsoft.DotNet.SDK.10 -e'
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
}
