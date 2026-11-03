# Shared baseline for the five .NET consumers. Project standards may impose stricter pins.
@{
    Name = 'SecondLine shared .NET development baseline'
    Version = '1.0.0'
    Tools = @(
        @{ Name = 'Git'; Command = 'git'; Expect = '2.0'; Rule = 'Minimum' }
        # Only in a repo with .NET in it; SKIPPED elsewhere (a PowerShell repo, say).
        @{ Name = '.NET SDK selected by this repository'; Command = 'dotnet'; Expect = '10.0'; Rule = 'Minor'
           AppliesWhen = @('global.json', '*.sln', '*.slnx', '*.csproj', '*.fsproj')
           Install = 'Add a global.json pinning the SDK: { "sdk": { "version": "10.0.100", "rollForward": "latestFeature", "allowPrerelease": false } }' }
    )
}
