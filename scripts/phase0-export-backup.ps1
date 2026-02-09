. "$PSScriptRoot/config.ps1"

$ErrorActionPreference = "Stop"

Import-Module Az.Accounts -Force
Import-Module Az.RecoveryServices -Force

Write-Host "========== PHASE 0: EXPORT BACKUP =========="

# Switch to Source Subscription
Set-AzContext -SubscriptionId $SourceSubscriptionId

Write-Host "Using Recovery Vault: $VaultName"

# Get Vault
$vault = Get-AzRecoveryServicesVault -Name $VaultName
Set-AzRecoveryServicesVaultContext -Vault $vault

# Get all containers (compatible with older Az versions)
$containers = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVM

# Find container matching VM
$container = $containers | Where-Object {
    $_.FriendlyName -eq $VMName
}

if (-not $container) {
    throw "Backup container not found for VM '$VMName'"
}

# Get backup item from container
$backupItem = Get-AzRecoveryServicesBackupItem `
    -Container $container `
    -WorkloadType AzureVM

if (-not $backupItem) {
    throw "Backup item not found for VM '$VMName'"
}

# Get backup policy
$policy = Get-AzRecoveryServicesBackupProtectionPolicy `
    -Name $backupItem.ProtectionPolicyName

Write-Host "Vault Found: $($vault.Name)"
Write-Host "Policy Found: $($policy.Name)"

# Extract values
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
