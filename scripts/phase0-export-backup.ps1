$ErrorActionPreference = "Stop"

Import-Module Az.Accounts -Force
Import-Module Az.RecoveryServices -Force

Write-Host "==============================================="
Write-Host "PHASE 0 - EXPORT BACKUP CONFIGURATION"
Write-Host "==============================================="

# INPUT
$SourceSubscriptionId = "46689057-be43-4229-9241-e0591dad4dbf"
$VMName               = "ubuntu"

# Set Context
Set-AzContext -SubscriptionId $SourceSubscriptionId | Out-Null
Write-Host "[OK] Connected to subscription"

$vaultFound = $null
$backupItem = $null

$vaults = Get-AzRecoveryServicesVault

foreach ($vault in $vaults) {

    Write-Host "Checking vault:" $vault.Name

    Set-AzRecoveryServicesVaultContext -Vault $vault

    $items = Get-AzRecoveryServicesBackupItem `
        -WorkloadType AzureVM `
        -BackupManagementType AzureVM `
        -ErrorAction SilentlyContinue

    if ($items) {

        foreach ($item in $items) {

            if ($item.FriendlyName -eq $VMName) {

                $vaultFound = $vault
                $backupItem = $item
                break
            }
        }
    }

    if ($vaultFound) { break }
}

if (-not $vaultFound) {
    throw "No Recovery Services Vault found protecting VM '$VMName'"
}

Write-Host "[OK] Vault Found:" $vaultFound.Name
Write-Host "[OK] Backup Item Found"

# Get policy
$policy = Get-AzRecoveryServicesBackupProtectionPolicy `
    -Name $backupItem.ProtectionPolicyName

Write-Host "[OK] Policy Found:" $policy.Name

# Build export object
$export = [PSCustomObject]@{
    VaultName     = $vaultFound.Name
    VaultLocation = $vaultFound.Location
    PolicyName    = $policy.Name
    Schedule      = $policy.SchedulePolicy
    Retention     = $policy.RetentionPolicy
}

# Save to GitHub workspace
$workspace = $env:GITHUB_WORKSPACE
$path = Join-Path $workspace "backup-config.json"

$export | ConvertTo-Json -Depth 20 | Out-File $path -Force

Write-Host ""
Write-Host "Backup configuration exported to:"
Write-Host $path

Write-Host ""
Write-Host "Files in workspace:"
Get-ChildItem $workspace
