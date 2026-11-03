#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# The publish script's API key lookup (build/GalleryKey.ps1). Nothing is published
# and no real key is used: SecretManagement and the prompt are mocked.

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repo 'build\GalleryKey.ps1')

    # Stand-ins so the tests run where SecretManagement isn't installed (CI, 5.1).
    # They shadow the real commands in this scope; every test mocks them anyway.
    function Get-Secret { [CmdletBinding()] param([string] $Name, [string] $Vault, [switch] $AsPlainText) }
    function Get-SecretInfo { [CmdletBinding()] param([string] $Name, [string] $Vault) }
    function Get-SecretVault { [CmdletBinding()] param() }
    function Set-Secret { [CmdletBinding()] param([string] $Name, [string] $Vault, [securestring] $SecureStringSecret) }
}

Describe 'Gallery API key lookup' {
    BeforeEach {
        $script:oldKey = $env:SECONDLINE_GALLERY_KEY
        $env:SECONDLINE_GALLERY_KEY = $null
        Mock Write-Host { }
        Mock Get-SecretInfo { [pscustomobject]@{ Name = 'SecondLine.GalleryApiKey'; VaultName = 'TestVault' } }
        Mock Get-Secret { 'not-a-real-key-from-vault' }
        Mock Read-Host { ConvertTo-SecureString 'not-a-real-key-typed' -AsPlainText -Force } -ParameterFilter { $AsSecureString }
    }
    AfterEach {
        $env:SECONDLINE_GALLERY_KEY = $script:oldKey
    }

    It '-WhatIf reads nothing: no vault, no prompt, no environment' {
        $env:SECONDLINE_GALLERY_KEY = 'not-a-real-key-env'
        Get-GalleryApiKey -WhatIf | Should -BeNullOrEmpty
        Should -Invoke Get-SecretInfo -Times 0 -Exactly
        Should -Invoke Get-Secret -Times 0 -Exactly
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It 'uses a vault secret instead of prompting' {
        $k = Get-GalleryApiKey
        $k.Source | Should -Be 'Vault'
        $k.Vault  | Should -Be 'TestVault'
        $k.Key    | Should -Be 'not-a-real-key-from-vault'
        Should -Invoke Get-Secret -Times 1 -Exactly -ParameterFilter { $Name -eq 'SecondLine.GalleryApiKey' -and $Vault -eq 'TestVault' -and $AsPlainText }
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It 'passes -SecretName and -Vault through' {
        [void] (Get-GalleryApiKey -SecretName 'Other.Key' -Vault 'Mine')
        Should -Invoke Get-SecretInfo -Times 1 -Exactly -ParameterFilter { $Name -eq 'Other.Key' -and $Vault -eq 'Mine' }
    }

    It '-NoVault skips SecretManagement and prompts' {
        $k = Get-GalleryApiKey -NoVault
        $k.Source | Should -Be 'Prompt'
        $k.Key    | Should -Be 'not-a-real-key-typed'
        Should -Invoke Get-SecretInfo -Times 0 -Exactly
        Should -Invoke Get-Secret -Times 0 -Exactly
    }

    It 'SECONDLINE_GALLERY_KEY wins over the vault' {
        $env:SECONDLINE_GALLERY_KEY = 'not-a-real-key-env'
        (Get-GalleryApiKey).Source | Should -Be 'Environment'
        Should -Invoke Get-SecretInfo -Times 0 -Exactly
    }

    It 'falls back to the prompt when no vault has the secret' {
        Mock Get-SecretInfo { }
        (Get-GalleryApiKey).Source | Should -Be 'Prompt'
        Should -Invoke Get-Secret -Times 0 -Exactly
    }

    It 'falls back to the prompt when the vault cannot be read' {
        Mock Get-Secret { throw 'vault is locked' }
        (Get-GalleryApiKey).Source | Should -Be 'Prompt'
    }
}

Describe 'Saving a prompted key' {
    BeforeAll {
        $script:secure = ConvertTo-SecureString 'not-a-real-key-typed' -AsPlainText -Force
    }
    BeforeEach {
        Mock Write-Host { }
        Mock Get-SecretVault { [pscustomobject]@{ Name = 'TestVault'; IsDefault = $true } }
        Mock Set-Secret { }
    }

    It 'never saves without a yes' {
        Mock Read-Host { '' }
        Save-GalleryApiKey -Secure $script:secure | Should -BeFalse
        Should -Invoke Set-Secret -Times 0 -Exactly
    }

    It 'saves to the default vault on y' {
        Mock Read-Host { 'y' }
        Save-GalleryApiKey -Secure $script:secure | Should -BeTrue
        Should -Invoke Set-Secret -Times 1 -Exactly -ParameterFilter { $Name -eq 'SecondLine.GalleryApiKey' -and $Vault -eq 'TestVault' -and $SecureStringSecret }
    }

    It '-NoVault does not ask' {
        Mock Read-Host { 'y' }
        Save-GalleryApiKey -Secure $script:secure -NoVault | Should -BeFalse
        Should -Invoke Read-Host -Times 0 -Exactly
    }
}

Describe 'Publish-SecondLine.ps1' {
    BeforeAll {
        $script:file = Join-Path (Split-Path $PSScriptRoot -Parent) 'build\Publish-SecondLine.ps1'
        $tokens = $null; $errors = $null
        $script:ast = [Management.Automation.Language.Parser]::ParseFile($script:file, [ref] $tokens, [ref] $errors)
        $script:parseErrors = $errors
    }

    It 'parses' {
        $script:parseErrors | Should -BeNullOrEmpty
    }

    It 'has -SecretName, -Vault and -NoVault' {
        $names = $script:ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }
        $names | Should -Contain 'SecretName'
        $names | Should -Contain 'Vault'
        $names | Should -Contain 'NoVault'
    }

    It 'looks up the key only after the -WhatIf exit' {
        $calls = $script:ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true)
        $lookup = @($calls | Where-Object { $_.GetCommandName() -eq 'Get-GalleryApiKey' })
        $lookup.Count | Should -Be 1
        $should = $script:ast.FindAll({ param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and "$($n.Member)" -eq 'ShouldProcess' }, $true) |
            Select-Object -First 1
        $should | Should -Not -BeNullOrEmpty
        $lookup[0].Extent.StartOffset | Should -BeGreaterThan $should.Extent.StartOffset
    }
}
