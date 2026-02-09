. "$PSScriptRoot/config.ps1"

$ErrorActionPreference = "Stop"

Import-Module Az.Accounts -Force
Import-Module Az.RecoveryServices -Force

Write-Host "========== PHASE 0: EXPORT BACKUP =========="

Set-AzContext -SubscriptionId $SourceSubscriptionId

Write-Host "Searching vault protecting VM: $VMName"

$vaults = Get-AzRecoveryServicesVault
$selectedVault = $null
$policy = $null

foreach ($vault in $vaults) {

    Write-Host "Checking Vault: $($vault.Name)"
    Set-AzRecoveryServicesVaultContext -Vault $vault

    # NEW way (Enhanced compatible)
    $items = Get-AzRecoveryServicesBackupItem `
        -WorkloadType AzureVM `
        -ErrorAction SilentlyContinue

    foreach ($item in $items) {

        Write-Host "Found protected VM: $($item.FriendlyName)"

        if ($item.FriendlyName -eq $VMName) {
            $selectedVault = $vault
            $policy = Get-AzRecoveryServicesBackupProtectionPolicy `
                -Name $item.ProtectionPolicyName
            break
        }
    }

    if ($selectedVault) { break }
}

if (-not $selectedVault) {
    throw "No Recovery Vault found protecting VM '$VMName'"
}

Write-Host "Vault Found: $($selectedVault.Name)"
Write-Host "Policy Found: $($policy.Name)"

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
