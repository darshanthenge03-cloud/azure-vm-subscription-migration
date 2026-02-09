$ErrorActionPreference = "Stop"

Import-Module Az.Accounts -Force
Import-Module Az.RecoveryServices -Force

# INPUT
$SourceSubscriptionId = "46689057-be43-4229-9241-e0591dad4dbf"
$VMName = "ubuntu"   # Must match EXACT name

Set-AzContext -SubscriptionId $SourceSubscriptionId

Write-Host "Searching for vault protecting VM: $VMName"

$vaults = Get-AzRecoveryServicesVault
$vaultFound = $null
$backupItem = $null

foreach ($vault in $vaults) {

    Write-Host "Checking vault:" $vault.Name
    Set-AzRecoveryServicesVaultContext -Vault $vault

    $items = Get-AzRecoveryServicesBackupItem `
        -WorkloadType AzureVM `
        -BackupManagementType AzureVM `
        -ErrorAction SilentlyContinue

    $item = $items | Where-Object { $_.FriendlyName -eq $VMName }

    if ($item) {
        $vaultFound = $vault
        $backupItem = $item
        break
    }
}

if (-not $vaultFound) {
    throw "No Recovery Services Vault found protecting VM '$VMName'"
}

Write-Host "Vault Found:" $vaultFound.Name
Write-Host "Vault Resource Group:" $vaultFound.ResourceGroupName

$policy = Get-AzRecoveryServicesBackupProtectionPolicy `
    -Name $backupItem.ProtectionPolicyName

# Build export object
$export = [PSCustomObject]@{
    VaultName        = $vaultFound.Name
    VaultResourceGroup = $vaultFound.ResourceGroupName
    VaultLocation    = $vaultFound.Location
    PolicyName       = $policy.Name
    Schedule         = $policy.SchedulePolicy
    Retention        = $policy.RetentionPolicy
}

$workspace = $env:GITHUB_WORKSPACE
$path = Join-Path $workspace "backup-config.json"

$export | ConvertTo-Json -Depth 20 | Out-File $path -Force

Write-Host "Backup configuration exported to:"
Write-Host $path

Write-Host "Files in workspace:"
Get-ChildItem $workspace
