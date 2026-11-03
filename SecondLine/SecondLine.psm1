# SecondLine - keep every dev machine in step.
# Loads the bootstrap's shared functions (standard discovery and version policy),
# then private helpers, then public functions.

. (Join-Path $PSScriptRoot 'Bootstrap\Import-SecondLine.ps1') -LibraryOnly

$private = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' -ErrorAction SilentlyContinue)
$public  = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public')  -Filter '*.ps1' -ErrorAction SilentlyContinue)

foreach ($file in @($private + $public)) {
    . $file.FullName
}

Export-ModuleMember -Function $public.BaseName
