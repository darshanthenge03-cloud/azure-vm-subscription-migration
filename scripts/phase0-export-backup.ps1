$ErrorActionPreference = "Stop"

Import-Module Az.Accounts -Force
Import-Module Az.RecoveryServices -Force

Write-Host "==============================================="
Write-Host "PHASE 0 - EXPORT BACKUP CONFIGURATION"
Write-Host "==============================================="

# INPUT
$SourceSubscriptionId = "46689057-be43-4229-9241-e0591dad4dbf"
$VMName               = "ubuntu"

Set-AzContext -SubscriptionId $SourceSubscriptionId | Out-Null
Write-Host "[OK] Connected to subscription"

$vaultFound = $null
$backupItem = $null

$vaults = Get-AzRecoveryServicesVault

foreach ($vault in $vaults) {

    Write-Host "Checking vault:" $vault.Name

    Set-AzRecoveryServicesVaultContext -Vault $vault

    # Get container for VM
    $container = Get-AzRecoveryServicesBackupContainer `
        -ContainerType AzureVM `
        -FriendlyName $VMName `
        -ErrorAction SilentlyContinue

    if ($container) {

        $item = Get-AzRecoveryServicesBackupItem `
            -Container $container `
            -WorkloadType AzureVM `
            -ErrorAction SilentlyContinue

        if ($item) {

            $vaultFound = $vault
            $backupItem = $item
            break
        }
    }
}

if (-not $vaultFound) {
    throw "No Recovery Services Vault found protecting VM '$VMName'"
}

Write-Host "[OK] Vault Found:" $vaultFound.Name
Write-Host "[OK] Backup Item Found"

$policy = Get-AzRecoveryServicesBackupProtectionPolicy `
    -Name $backupItem.ProtectionPolicyName

Write-Host "[OK] Policy Found:" $policy.Name

# Export object
$export = [PSCustomObject]@{
    VaultName     = $vaultFound.Name
    VaultLocation = $vaultFound.Location
    PolicyName    = $policy.Name
    Schedule      = $policy.SchedulePolicy
    Retention     = $policy.RetentionPolicy
}

$workspace = $env:GITHUB_WORKSPACE
$path = Join-Path $workspace "backup-config.json"

$export | ConvertTo-Json -Depth 20 | Out-File $path -Force

Write-Host ""
Write-Host "Backup configuration exported to:"
Write-Host $path

Write-Host "Files in workspace:"
Get-ChildItem $workspace
