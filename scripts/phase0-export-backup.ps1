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
# Get Backup Container
# ---------------------------------------------------
$containers = Get-AzRecoveryServicesBackupContainer `
    -ContainerType AzureVM `
    -ErrorAction SilentlyContinue

if (-not $containers) {
    Write-Host "No backup containers found in vault. Skipping Phase 0."
    return
}

$container = $containers | Where-Object {
    $_.FriendlyName -eq $VMName
}

if (-not $container) {
    Write-Host "No backup container found for VM '$VMName'. Skipping Phase 0."
    return
}

# ---------------------------------------------------
# Get Backup Item
# ---------------------------------------------------
$backupItem = Get-AzRecoveryServicesBackupItem `
    -Container $container `
    -WorkloadType AzureVM `
    -ErrorAction SilentlyContinue

if (-not $backupItem) {
    Write-Host "No backup item found for VM '$VMName'. Skipping Phase 0."
    return
}

# ---------------------------------------------------
# Validate Protection State
# ---------------------------------------------------
if ($backupItem.ProtectionState -ne "Protected") {
    Write-Host "Backup exists but is not active (State: $($backupItem.ProtectionState)). Skipping Phase 0."
    return
}

if ([string]::IsNullOrEmpty($backupItem.ProtectionPolicyName)) {
    Write-Host "Backup policy name is empty. Skipping Phase 0."
    return
}

# ---------------------------------------------------
# Get Policy
# ---------------------------------------------------
$policy = Get-AzRecoveryServicesBackupProtectionPolicy `
    -Name $backupItem.ProtectionPolicyName `
    -ErrorAction Stop

Write-Host "Vault Found : $($vault.Name)"
Write-Host "Policy Found: $($policy.Name)"

# ---------------------------------------------------
# Export Policy
# ---------------------------------------------------
$export = @{
    VaultName = $vault.Name
    Location  = $vault.Location
    Policy    = $policy
}

$path = Join-Path $env:GITHUB_WORKSPACE "backup-config.json"

$export | ConvertTo-Json -Depth 40 | Out-File $path -Force

Write-Host "Backup configuration exported to: $path"
Write-Host "========== PHASE 0 COMPLETED =========="
