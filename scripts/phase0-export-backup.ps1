$ErrorActionPreference = "Stop"

Import-Module Az.Accounts -Force
Import-Module Az.RecoveryServices -Force

# ============================================
# INPUT
# ============================================
$SourceSubscriptionId = "46689057-be43-4229-9241-e0591dad4dbf"
$VMName               = "ubuntu"

Write-Host "==============================================="
Write-Host " PHASE 0 - EXPORT BACKUP CONFIGURATION"
Write-Host "==============================================="

Set-AzContext -SubscriptionId $SourceSubscriptionId | Out-Null
Write-Host "[OK] Connected to subscription"

# ============================================
# FIND VAULT PROTECTING THIS VM
# ============================================
$vaults = Get-AzRecoveryServicesVault
$foundVault = $null
$foundItem  = $null

Write-Host "Searching for vault protecting VM: $VMName"

foreach ($vault in $vaults) {

    Write-Host "Checking vault:" $vault.Name
    Set-AzRecoveryServicesVaultContext -Vault $vault

    $items = Get-AzRecoveryServicesBackupItem `
        -WorkloadType AzureVM `
        -BackupManagementType AzureVM `
        -ErrorAction SilentlyContinue

    if ($items) {

        $match = $items | Where-Object {
            $_.FriendlyName -eq $VMName
        }

        if ($match) {
            $foundVault = $vault
            $foundItem  = $match
            break
        }
    }
}

if (-not $foundVault) {
    throw "No Recovery Services Vault found protecting VM '$VMName'"
}

Write-Host "[OK] Found Vault:" $foundVault.Name

# ============================================
# GET POLICY
# ============================================
Set-AzRecoveryServicesVaultContext -Vault $foundVault

$policy = Get-AzRecoveryServicesBackupProtectionPolicy `
    -Name $foundItem.ProtectionPolicyName

Write-Host "[OK] Found Policy:" $policy.Name

# ============================================
# EXPORT CONFIG
# ============================================
$export = [PSCustomObject]@{
    VaultName     = $foundVault.Name
    VaultLocation = $foundVault.Location
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

Write-Host ""
Write-Host "Files in workspace:"
Get-ChildItem $workspace
