. "$PSScriptRoot/config.ps1"

$ErrorActionPreference = "Stop"

Import-Module Az.Accounts -Force
Import-Module Az.RecoveryServices -Force

Write-Host "========== PHASE 0: EXPORT BACKUP =========="

# Set subscription context
Set-AzContext -SubscriptionId $SourceSubscriptionId

Write-Host "Using Recovery Vault: $VaultName"

# Get vault
$vault = Get-AzRecoveryServicesVault -Name $VaultName -ErrorAction Stop
Set-AzRecoveryServicesVaultContext -Vault $vault

# Get containers (compatible with old + new Az modules)
$containers = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVM -ErrorAction SilentlyContinue

if (-not $containers) {
    throw "No backup containers found in vault '$VaultName'"
}

# Match container by VM name
$container = $containers | Where-Object {
    $_.FriendlyName -eq $VMName
}

if (-not $container) {
    throw "Backup container not found for VM '$VMName'"
}

# Get backup item
$backupItem = Get-AzRecoveryServicesBackupItem `
    -Container $container `
    -WorkloadType AzureVM `
    -ErrorAction Stop

if (-not $backupItem) {
    throw "Backup item not found for VM '$VMName'"
}

# Get policy
$policy = Get-AzRecoveryServicesBackupProtectionPolicy `
    -Name $backupItem.ProtectionPolicyName `
    -ErrorAction Stop

Write-Host "Vault Found: $($vault.Name)"
Write-Host "Policy Found: $($policy.Name)"

# -------------------------------
# UNIVERSAL POLICY PARSING LOGIC
# -------------------------------

$retentionDays = "Unknown"
$backupTime = "Unknown"

# Handle Standard Policy
if ($policy.RetentionPolicy -and $policy.RetentionPolicy.DailyRetention) {
    $retentionDays = $policy.RetentionPolicy.DailyRetention.DurationCountInDays
}

if ($policy.SchedulePolicy -and $policy.SchedulePolicy.ScheduleRunTimes) {
    try {
        $backupTime = $policy.SchedulePolicy.ScheduleRunTimes[0].ToString("HH:mm")
    }
    catch {
        $backupTime = "Configured (Standard Policy)"
    }
}

# Handle Enhanced Policy (Snapshot-based)
if (-not $policy.SchedulePolicy.ScheduleRunTimes) {
    $backupTime = "Enhanced Policy (Snapshot-based)"
}

# -------------------------------

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
