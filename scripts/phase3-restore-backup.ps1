$ErrorActionPreference = "Stop"

Import-Module Az.Accounts -Force
Import-Module Az.RecoveryServices -Force

# INPUT
$DestinationSubscriptionId = "d4e068bf-2473-4201-b10a-7f8501d50ebc"
$DestinationResourceGroup  = "Dev-RG"
$VMName = "ubuntu"

Set-AzContext -SubscriptionId $DestinationSubscriptionId

$configPath = Join-Path $env:GITHUB_WORKSPACE "backup-config.json"

if (-not (Test-Path $configPath)) {
    throw "backup-config.json not found"
}

$config = Get-Content $configPath | ConvertFrom-Json

# Create vault hear is name of vauult
$vault = Get-AzRecoveryServicesVault -Name $config.VaultName -ErrorAction SilentlyContinue

if (-not $vault) {
    $vault = New-AzRecoveryServicesVault `
        -Name $config.VaultName `
        -ResourceGroupName $DestinationResourceGroup `
        -Location $config.Location
}

Set-AzRecoveryServicesVaultContext -Vault $vault

# Create policy cleanly
$policy = Get-AzRecoveryServicesBackupProtectionPolicy `
    -Name $config.PolicyName -ErrorAction SilentlyContinue

if (-not $policy) {

    $schedule = New-AzRecoveryServicesBackupSchedulePolicyObject `
        -WorkloadType AzureVM

    $schedule.ScheduleRunFrequency = "Daily"
    $schedule.ScheduleRunTimes = @([DateTime]::Parse($config.BackupTime))

    $retention = New-AzRecoveryServicesBackupRetentionPolicyObject `
        -WorkloadType AzureVM

    $retention.DailyRetention.DurationCountInDays = $config.RetentionDays

    $policy = New-AzRecoveryServicesBackupProtectionPolicy `
        -Name $config.PolicyName `
        -WorkloadType AzureVM `
        -RetentionPolicy $retention `
        -SchedulePolicy $schedule
}

# Enable backup
Enable-AzRecoveryServicesBackupProtection `
    -Policy $policy `
    -Name $VMName `
    -ResourceGroupName $DestinationResourceGroup

# Trigger initial backup
$item = Get-AzRecoveryServicesBackupItem `
    -WorkloadType AzureVM `
    -BackupManagementType AzureVM |
    Where-Object { $_.FriendlyName -eq $VMName }

Backup-AzRecoveryServicesBackupItem -Item $item

Write-Host "Backup restored and initial backup triggered."
