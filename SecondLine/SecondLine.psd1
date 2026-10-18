@{
    RootModule        = 'SecondLine.psm1'
    ModuleVersion     = '0.2.0'
    GUID              = '5b0f2d7e-8c41-4e3a-9d6b-2f1a7c9e4b30'
    Author            = 'Doug Laine'
    Copyright         = '(c) 2026 Doug Laine.'
    Description       = 'Keep every dev machine in step. Declare the tool versions your machines should run in one file and audit each machine against it; start, stop and check a local MongoDB replica set on Windows without the usual mlaunch pain.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Get-SecondLineStandard'
        'Test-SecondLine'
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
            Tags         = @('DevEnvironment', 'Versions', 'Audit', 'Consistency', 'MongoDB', 'ReplicaSet', 'mlaunch', 'Windows', 'PSEdition_Desktop', 'PSEdition_Core')
            ProjectUri   = 'https://github.com/douglaine/SecondLine'
            LicenseUri   = 'https://github.com/douglaine/SecondLine/blob/main/LICENSE'
            ReleaseNotes = 'https://github.com/douglaine/SecondLine/blob/main/CHANGELOG.md'
        }
    }
}
