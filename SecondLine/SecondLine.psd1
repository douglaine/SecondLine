@{
    RootModule        = 'SecondLine.psm1'
    ModuleVersion     = '0.4.1'
    GUID              = '5b0f2d7e-8c41-4e3a-9d6b-2f1a7c9e4b30'
    Author            = 'Doug Laine'
    Copyright         = '(c) 2026 Doug Laine.'
    Description       = 'Keep every dev machine, every repo and every AI coding agent in step. NEW: one rulebook for every AI coding agent: keep CLAUDE.md and AGENTS.md in every repo pointed at the same versioned, hash-stamped rules, with a handoff note per repo, and audit them all in one command (Export-SLPolicy, New-SLStatusCheckpoint, Test-SLPolicyReference). Declare the tool versions your machines should run in one file and audit each machine against it, with checks that apply only where they matter (AppliesWhen). Pin the SecondLine version a project approves and select it before import. Get a daily update notice from the PowerShell Gallery, opt-in and nothing installed. Check and fix line endings end to end: .gitattributes, .editorconfig, VS Code settings and working copies, across every git repo. Start, stop and check a local MongoDB replica set on Windows without the usual mlaunch pain. Windows PowerShell 5.1 and PowerShell 7, tested on both.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Show-SLHelp'
        'Get-SecondLineStandard'
        'Get-SLSetting'
        'Get-SLUpdateStatus'
        'Invoke-SLUpdateCheck'
        'Enable-SLProfileUpdateCheck'
        'Disable-SLProfileUpdateCheck'
        'Test-SecondLine'
        'Test-SLRepo'
        'Set-SLGitAttributes'
        'Test-SLLineEnding'
        'Repair-SLLineEnding'
        'Test-SLPolicyReference'
        'Export-SLPolicy'
        'New-SLStatusCheckpoint'
        'Find-SLMongoReplicaSet'
        'Get-SLMongoStatus'
        'Start-SLMongo'
        'Stop-SLMongo'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('AI', 'CodingAgents', 'ClaudeCode', 'Codex', 'DevEnvironment', 'Versions', 'Audit', 'Consistency', 'MongoDB', 'ReplicaSet', 'mlaunch', 'Git', 'LineEndings', 'EditorConfig', 'Settings', 'UpdateCheck', 'Windows', 'PSEdition_Desktop', 'PSEdition_Core')
            ProjectUri   = 'https://github.com/douglaine/SecondLine'
            LicenseUri   = 'https://github.com/douglaine/SecondLine/blob/main/LICENSE'
            ReleaseNotes = 'https://github.com/douglaine/SecondLine/blob/main/CHANGELOG.md'
        }
    }
}
