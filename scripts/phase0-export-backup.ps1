$ErrorActionPreference = "Stop"

Import-Module Az.Accounts -Force
Import-Module Az.RecoveryServices -Force

# ==========================================================
# INPUT
# ==========================================================
$SourceSubscriptionId = "46689057-be43-4229-9241-e0591dad4dbf"
$VMName               = "ubuntu"   # <-- change if needed

Write-Host "================================================="
Write-Host " PHASE 0 - EXPORT BACKUP CONFIGURATION"
Write-Host "================================================="

# ==========================================================
# SET CONTEXT
# ==========================================================
Set-AzContext -SubscriptionId $SourceSubscriptionId | Out-Null
Write-Host "[OK] Connected to subscription"

# ==========================================================
# FIND VAULT PROTECTING THE VM
# ==========================================================
Write-Host ""
Write-Host "Searching for vault protecting VM: $VMName"

$allVaults = Get-AzRecoveryServicesVault

if (-not $allVaults) {
    throw "No Recovery Services Vaults found in subscription."
}

$foundVault = $null
$foundItem  = $null

foreach ($vault in $allVaults) {

    Write-Host "Checking vault:" $vault.Name

    Set-AzRecoveryServicesVaultContext -Vault $vault

    $items = Get-AzRecoveryServicesBackupItem `
        -WorkloadType AzureVM `
        -BackupManagementType AzureVM `
        -ErrorAction SilentlyContinue

    if ($items) {

        # Robust matching (case-insensitive, contains)
        $match = $items | Where-Object {
            $_.FriendlyName.ToLower().Contains($VMName.ToLower())
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

Write-Host ""
Write-Host "[OK] Vault found:" $foundVault.Name
Write-Host "[OK] Backup Item:" $foundItem.FriendlyName

# ==========================================================
# GET POLICY
# ==========================================================
$policy = Get-AzRecoveryServicesBackupProtectionPolicy `
    -Name $foundItem.ProtectionPolicyName

Write-Host "[OK] Policy found:" $policy.Name

# ==========================================================
# BUILD EXPORT OBJECT
# ==========================================================
$export = [PSCustomObject]@{
    VaultName        = $foundVault.Name
    VaultResourceGroup = $foundVault.ResourceGroupName
    VaultLocation    = $foundVault.Location
    PolicyName       = $policy.Name
    SchedulePolicy   = $policy.SchedulePolicy
    RetentionPolicy  = $policy.RetentionPolicy
}

# ==========================================================
# SAVE JSON TO GITHUB WORKSPACE
# ==========================================================
$workspace = $env:GITHUB_WORKSPACE

if (-not $workspace) {
    throw "GITHUB_WORKSPACE not found."
}

$path = Join-Path $workspace "backup-config.json"

$export | ConvertTo-Json -Depth 20 | Out-File $path -Force

Write-Host ""
Write-Host "================================================="
Write-Host " Backup configuration exported successfully"
Write-Host " File location:"
Write-Host $path
Write-Host "================================================="

Write-Host ""
Write-Host "Files in workspace:"
Get-ChildItem $workspace
