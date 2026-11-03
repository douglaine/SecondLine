# Shared baseline for the five .NET consumers. Project standards may impose stricter pins.
@{
    Name = 'SecondLine shared .NET development baseline'
    Version = '1.0.0'
    Tools = @(
        @{ Name = 'Git'; Command = 'git'; Expect = '2.0'; Rule = 'Minimum' }
        @{ Name = '.NET SDK selected by this repository'; Command = 'dotnet'; Expect = '10.0'; Rule = 'Minor' }
    )
}
