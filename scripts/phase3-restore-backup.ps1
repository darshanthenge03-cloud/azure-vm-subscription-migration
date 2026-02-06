$ErrorActionPreference = "Stop"

Import-Module Az.Accounts -Force
Import-Module Az.RecoveryServices -Force

# INPUT
$DestinationSubscriptionId = "d4e068bf-2473-4201-b10a-7f8501d50ebc"
$DestinationResourceGroup  = "Dev-RG"
$VMName = "ubuntu"

Set-AzContext -SubscriptionId $DestinationSubscriptionId

# Read exported config
$config = Get-Content "./backup-config.json" | ConvertFrom-Json

# Create vault
$vault = Get-AzRecoveryServicesVault -Name $config.VaultName -ErrorAction SilentlyContinue

if (-not $vault) {
    $vault = New-AzRecoveryServicesVault `
        -Name $config.VaultName `
        -ResourceGroupName $DestinationResourceGroup `
        -Location $config.VaultLocation
}

Set-AzRecoveryServicesVaultContext -Vault $vault

# Create policy
$policy = Get-AzRecoveryServicesBackupProtectionPolicy `
    -Name $config.PolicyName -ErrorAction SilentlyContinue

if (-not $policy) {

    $policy = New-AzRecoveryServicesBackupProtectionPolicy `
        -Name $config.PolicyName `
        -WorkloadType AzureVM `
        -SchedulePolicy $config.Schedule `
        -RetentionPolicy $config.Retention
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

Write-Host "Backup restored successfully."
