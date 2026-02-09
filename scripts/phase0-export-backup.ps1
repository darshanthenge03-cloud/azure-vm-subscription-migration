. "$PSScriptRoot/config.ps1"

$ErrorActionPreference = "Stop"

Import-Module Az.Accounts -Force
Import-Module Az.RecoveryServices -Force

Write-Host "========== PHASE 0: EXPORT BACKUP POLICY =========="

# ---------------------------------------------------
# Set Source Subscription Context
# ---------------------------------------------------
Set-AzContext -SubscriptionId $SourceSubscriptionId

Write-Host "Using Recovery Vault: $VaultName"
Write-Host "Target VM: $VMName"

# ---------------------------------------------------
# Get Vault
# ---------------------------------------------------
$vault = Get-AzRecoveryServicesVault -Name $VaultName -ErrorAction Stop
Set-AzRecoveryServicesVaultContext -Vault $vault

# ---------------------------------------------------
# Get Backup Container (compatible with all Az versions)
# ---------------------------------------------------
$containers = Get-AzRecoveryServicesBackupContainer `
    -ContainerType AzureVM `
    -ErrorAction SilentlyContinue

if (-not $containers) {
    throw "No backup containers found in vault '$VaultName'"
}

$container = $containers | Where-Object {
    $_.FriendlyName -eq $VMName
}

if (-not $container) {
    throw "Backup container not found for VM '$VMName'"
}

# ---------------------------------------------------
# Get Backup Item
# ---------------------------------------------------
$backupItem = Get-AzRecoveryServicesBackupItem `
    -Container $container `
    -WorkloadType AzureVM `
    -ErrorAction Stop

if (-not $backupItem) {
    throw "Backup item not found for VM '$VMName'"
}

# ---------------------------------------------------
# Get Policy
# ---------------------------------------------------
$policy = Get-AzRecoveryServicesBackupProtectionPolicy `
    -Name $backupItem.ProtectionPolicyName `
    -ErrorAction Stop

Write-Host "Vault Found: $($vault.Name)"
Write-Host "Policy Found: $($policy.Name)"

# ---------------------------------------------------
# Export FULL policy object (Standard + Enhanced compatible)
# ---------------------------------------------------

$export = @{
    VaultName = $vault.Name
    Location  = $vault.Location
    Policy    = $policy
}

$path = Join-Path $env:GITHUB_WORKSPACE "backup-config.json"

$export | ConvertTo-Json -Depth 40 | Out-File $path -Force

Write-Host "Full backup configuration exported to: $path"
Write-Host "========== PHASE 0 COMPLETED =========="
