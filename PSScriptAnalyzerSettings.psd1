# PSScriptAnalyzer settings for SecondLine.
#
# Used by CI (.github/workflows/test.yml), build/Test-Lint.ps1 and VS Code's PowerShell
# extension, which picks this file up from the repo root automatically.
#
# Formatting rules are set to the style the code already uses: 4-space indents, opening
# brace on the same line, '}' on its own line before else/catch/finally, one-line blocks
# allowed, and aligned '=' in consecutive assignments.

@{
    IncludeDefaultRules = $true
    Severity            = @('Error', 'Warning')

    ExcludeRules        = @(
        # The reports print in colour on purpose; Write-Host is the only way to do that in 5.1.
        'PSAvoidUsingWriteHost'
        # Set-SLGitAttributes is named after the file; private helpers returning lists are plural on purpose.
        'PSUseSingularNouns'
    )

    Rules               = @{
        # No PowerShell 7-only syntax: the module runs on Windows PowerShell 5.1 too.
        PSUseCompatibleSyntax      = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }

        # Only commands that exist in both editions on Windows.
        #   win-48_..._5.1.17763.316_..._framework  Windows 10 (1809), Windows PowerShell 5.1
        #   win-4_..._7.0.0_..._core                Windows 10 (1903), PowerShell 7.0
        # (7.0 is the newest PowerShell 7 profile shipped with PSScriptAnalyzer.)
        PSUseCompatibleCommands    = @{
            Enable         = $true
            TargetProfiles = @(
                'win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework'
                'win-4_x64_10.0.18362.0_7.0.0_x64_3.1.2_core'
            )
        }

        PSUseConsistentIndentation = @{
            Enable              = $true
            Kind                = 'space'
            IndentationSize     = 4
            # 'None': continuation lines of a pipeline are indented by hand (+4, or more inside @( )).
            PipelineIndentation = 'None'
        }

        PSUseConsistentWhitespace  = @{
            Enable                          = $true
            CheckInnerBrace                 = $true
            # Off: consecutive one-line ifs align their '{' (e.g. Mongo.ps1, Read-SLMongoStartupFile).
            CheckOpenBrace                  = $false
            CheckOpenParen                  = $true
            CheckPipe                       = $true
            CheckSeparator                  = $true
            CheckParameter                  = $false
            # Off: the code aligns '=' across consecutive assignments.
            CheckOperator                   = $false
            CheckPipeForRedundantWhitespace = $false
        }

        PSPlaceOpenBrace           = @{
            Enable             = $true
            OnSameLine         = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
        }

        PSPlaceCloseBrace          = @{
            Enable             = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
            NoEmptyLineBefore  = $false
        }
    }
}
