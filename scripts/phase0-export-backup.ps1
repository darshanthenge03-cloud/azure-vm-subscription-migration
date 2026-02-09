. "$PSScriptRoot/config.ps1"

$ErrorActionPreference = "Stop"

Import-Module Az.Accounts -Force
Import-Module Az.RecoveryServices -Force

Set-AzContext -SubscriptionId $SourceSubscriptionId

Write-Host "========== PHASE 0: EXPORT BACKUP =========="
Write-Host "Searching vault protecting VM: $VMName"

$vaults = Get-AzRecoveryServicesVault
$selectedVault = $null
$policy = $null

foreach ($vault in $vaults) {

    Write-Host "Checking Vault: $($vault.Name)"
    Set-AzRecoveryServicesVaultContext -Vault $vault

    $item = Get-AzRecoveryServicesBackupItem `
        -WorkloadType AzureVM `
        -BackupManagementType AzureVM `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -eq $VMName }

    if ($item) {
        $selectedVault = $vault
        $policy = Get-AzRecoveryServicesBackupProtectionPolicy `
            -Name $item.ProtectionPolicyName
        break
    }
}

if (-not $selectedVault) {
    throw "No Recovery Vault found protecting VM '$VMName'"
}

$retentionDays = $policy.RetentionPolicy.DailyRetention.DurationCountInDays
$backupTime = $policy.SchedulePolicy.ScheduleRunTimes[0].ToString("HH:mm")

$export = @{
    VaultName     = $selectedVault.Name
    Location      = $selectedVault.Location
    PolicyName    = $policy.Name
    RetentionDays = $retentionDays
    BackupTime    = $backupTime
}

$path = Join-Path $env:GITHUB_WORKSPACE "backup-config.json"

$export | ConvertTo-Json -Depth 5 | Out-File $path -Force

Write-Host "Backup config exported to: $path"
Write-Host "========== PHASE 0 COMPLETED =========="
