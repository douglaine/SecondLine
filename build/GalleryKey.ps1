# PowerShell Gallery API key lookup for build/Publish-SecondLine.ps1.
# Kept in its own file so the lookup order can be tested without publishing.
#
# Order:
#   1. $env:SECONDLINE_GALLERY_KEY (CI / automation)
#   2. SecretManagement: a secret named -SecretName in -Vault (or any registered vault)
#   3. a hidden prompt; after a successful publish, Save-GalleryApiKey offers to store it
#
# The key is never written to disk, logged, or stored anywhere except a vault the
# maintainer agrees to.

# True if Microsoft.PowerShell.SecretManagement's commands can be used.
function Test-SecretManagement {
    foreach ($name in 'Get-Secret', 'Get-SecretInfo', 'Get-SecretVault', 'Set-Secret') {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) { return $false }
    }
    return $true
}

# Returns @{ Key; Secure; Source; Vault }, or $null under -WhatIf (nothing is read then).
#   Source  Environment | Vault | Prompt
#   Secure  the prompted SecureString (Source = Prompt only), for Save-GalleryApiKey
function Get-GalleryApiKey {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string] $SecretName = 'SecondLine.GalleryApiKey',
        [string] $Vault,
        [switch] $NoVault
    )

    if (-not $PSCmdlet.ShouldProcess('PowerShell Gallery API key', 'Read')) { return $null }

    if ($env:SECONDLINE_GALLERY_KEY) {
        Write-Host '          Using the API key from SECONDLINE_GALLERY_KEY.' -ForegroundColor DarkGray
        return [pscustomobject]@{ Key = $env:SECONDLINE_GALLERY_KEY; Secure = $null; Source = 'Environment'; Vault = '' }
    }

    if (-not $NoVault) {
        if (Test-SecretManagement) {
            $info = $null
            try {
                $p = @{ Name = $SecretName; ErrorAction = 'Stop' }
                if ($Vault) { $p.Vault = $Vault }
                $info = @(Get-SecretInfo @p) | Where-Object { $_.Name -eq $SecretName } | Select-Object -First 1
            }
            catch {
                Write-Host "          Could not search the secret vaults: $($_.Exception.Message)" -ForegroundColor Yellow
            }
            if ($info) {
                try {
                    $key = Get-Secret -Name $SecretName -Vault $info.VaultName -AsPlainText -ErrorAction Stop
                    if ($key) {
                        Write-Host "          Using the API key '$SecretName' from vault '$($info.VaultName)'." -ForegroundColor DarkGray
                        return [pscustomobject]@{ Key = $key; Secure = $null; Source = 'Vault'; Vault = $info.VaultName }
                    }
                }
                catch {
                    Write-Host "          Could not read '$SecretName' from vault '$($info.VaultName)': $($_.Exception.Message)" -ForegroundColor Yellow
                }
            }
        }
        else {
            Write-Host '          Tip: store the key once with Microsoft.PowerShell.SecretManagement (README, "Releasing").' -ForegroundColor DarkGray
        }
    }

    Write-Host '          Paste your PowerShell Gallery API key. Nothing will show as you paste; that is normal.' -ForegroundColor DarkGray
    $secure = Read-Host -Prompt '  API key' -AsSecureString
    if (-not $secure -or $secure.Length -eq 0) { return $null }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $key = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    return [pscustomobject]@{ Key = $key; Secure = $secure; Source = 'Prompt'; Vault = '' }
}

# After a successful publish with a prompted key: offer to store it. Never saves
# without a 'y'. Returns $true if saved.
function Save-GalleryApiKey {
    param(
        [Parameter(Mandatory)] [securestring] $Secure,
        [string] $SecretName = 'SecondLine.GalleryApiKey',
        [string] $Vault,
        [switch] $NoVault
    )

    if ($NoVault -or -not (Test-SecretManagement)) { return $false }

    $target = $Vault
    if (-not $target) {
        $vaults = @(Get-SecretVault -ErrorAction SilentlyContinue)
        $default = @($vaults | Where-Object { $_.IsDefault }) | Select-Object -First 1
        if ($default) { $target = $default.Name }
        elseif ($vaults.Count -eq 1) { $target = $vaults[0].Name }
    }
    if (-not $target) {
        Write-Host '          No default secret vault registered, so the key was not saved (README, "Releasing").' -ForegroundColor DarkGray
        return $false
    }

    $answer = Read-Host "  Save this key to vault '$target' for next time? [y/N]"
    if ($answer -notmatch '^(y|yes)$') { return $false }
    try {
        Set-Secret -Name $SecretName -Vault $target -SecureStringSecret $Secure -ErrorAction Stop
        Write-Host "    OK    Saved as '$SecretName' in vault '$target'." -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "    WARN  Could not save the key: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
}
