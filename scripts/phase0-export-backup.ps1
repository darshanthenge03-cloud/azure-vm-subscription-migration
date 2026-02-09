. "$PSScriptRoot/config.ps1"

$ErrorActionPreference = "Stop"

Import-Module Az.Accounts -Force
Import-Module Az.RecoveryServices -Force

Write-Host "========== PHASE 0: EXPORT BACKUP =========="

# Set correct subscription
Set-AzContext -SubscriptionId $SourceSubscriptionId

# Get VM backup item directly
Write-Host "Getting backup item for VM: $VMName"

$backupItem = Get-AzRecoveryServicesBackupItem `
    -WorkloadType AzureVM `
    -Name $VMName `
    -ErrorAction SilentlyContinue

if (-not $backupItem) {
    throw "Backup item not found for VM '$VMName'"
}

# Get vault from backup item
$vaultId = $backupItem.Id.Split("/")[8]
$vault = Get-AzRecoveryServicesVault -Name $vaultId

Set-AzRecoveryServicesVaultContext -Vault $vault

$policy = Get-AzRecoveryServicesBackupProtectionPolicy `
    -Name $backupItem.ProtectionPolicyName

Write-Host "Vault Found: $($vault.Name)"
Write-Host "Policy Found: $($policy.Name)"

$retentionDays = $policy.RetentionPolicy.DailyRetention.DurationCountInDays
$backupTime = $policy.SchedulePolicy.ScheduleRunTimes[0].ToString("HH:mm")

$export = @{
    VaultName     = $vault.Name
    Location      = $vault.Location
    PolicyName    = $policy.Name
    RetentionDays = $retentionDays
    BackupTime    = $backupTime
}

$path = Join-Path $env:GITHUB_WORKSPACE "backup-config.json"

$export | ConvertTo-Json -Depth 5 | Out-File $path -Force

Write-Host "Backup config exported to: $path"
Write-Host "========== PHASE 0 COMPLETED =========="
