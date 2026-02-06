$ErrorActionPreference = "Stop"

# ==========================================================
# ENSURE MODULES
# ==========================================================
$modules = @(
    "Az.Accounts",
    "Az.Compute",
    "Az.Network",
    "Az.RecoveryServices",
    "Az.Resources"
)

foreach ($m in $modules) {
    if (-not (Get-Module -ListAvailable -Name $m)) {
        Install-Module $m -Force -Scope CurrentUser -AllowClobber
    }
    Import-Module $m -Force
}

# ==========================================================
# USER INPUT
# ==========================================================
$SourceSubscriptionId = "46689057-be43-4229-9241-e0591dad4dbf"
$SourceResourceGroup  = "Dev-RG"
$VMName               = "ubuntu"

Write-Host "================================================="
Write-Host " PHASE 1 - PRE MIGRATION CLEANUP"
Write-Host "================================================="

# ==========================================================
# SET CONTEXT
# ==========================================================
Set-AzContext -SubscriptionId $SourceSubscriptionId | Out-Null
Write-Host "[OK] Source subscription set"

# ==========================================================
# GET VM
# ==========================================================
$vm = Get-AzVM -Name $VMName -ResourceGroupName $SourceResourceGroup
Write-Host "[OK] VM found"

# ==========================================================
# STOP & DEALLOCATE VM
# ==========================================================
Write-Host "[ACTION] Stopping and deallocating VM..."
Stop-AzVM -Name $VMName -ResourceGroupName $SourceResourceGroup -Force

do {
    Start-Sleep 10
    $state = (Get-AzVM -Name $VMName -ResourceGroupName $SourceResourceGroup -Status).Statuses |
        Where-Object Code -like "PowerState/*"
    Write-Host "[INFO] VM State:" $state.DisplayStatus
}
while ($state.DisplayStatus -ne "VM deallocated")

Write-Host "[OK] VM fully deallocated"

# ==========================================================
# DETACH PUBLIC IP
# ==========================================================
Write-Host "[ACTION] Detaching Public IP..."

foreach ($nicRef in $vm.NetworkProfile.NetworkInterfaces) {

    $nic = Get-AzNetworkInterface -ResourceId $nicRef.Id

    foreach ($ipConfig in $nic.IpConfigurations) {

        if ($ipConfig.PublicIpAddress) {

            $pipName = ($ipConfig.PublicIpAddress.Id -split "/")[-1]
            Write-Host "[INFO] Detaching PIP:" $pipName

            Set-AzNetworkInterfaceIpConfig `
                -NetworkInterface $nic `
                -Name $ipConfig.Name `
                -PublicIpAddress $null | Out-Null

            Set-AzNetworkInterface -NetworkInterface $nic | Out-Null

            Write-Host "[OK] Public IP detached"
        }
    }
}

# ==========================================================
# REMOVE BACKUP PROTECTION
# ==========================================================
Write-Host "[ACTION] Removing Backup Protection..."

$vaults = Get-AzRecoveryServicesVault

foreach ($vault in $vaults) {

    Set-AzRecoveryServicesVaultContext -Vault $vault

    $items = Get-AzRecoveryServicesBackupItem `
        -WorkloadType AzureVM `
        -BackupManagementType AzureVM `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -eq $VMName }

    foreach ($item in $items) {

        Write-Host "[INFO] Disabling backup in vault:" $vault.Name

        Disable-AzRecoveryServicesBackupProtection `
            -Item $item `
            -RemoveRecoveryPoints `
            -Force

        Write-Host "[OK] Backup + Recovery points removed"
    }
}

# ==========================================================
# DELETE RESTORE POINT COLLECTIONS (Correct Way)
# ==========================================================
Write-Host "[ACTION] Deleting Restore Point Collections..."

$backupRGs = Get-AzResourceGroup | Where-Object {
    $_.ResourceGroupName -like "AzureBackupRG_*"
}

foreach ($rg in $backupRGs) {

    $collections = Get-AzResource `
        -ResourceGroupName $rg.ResourceGroupName `
        -ResourceType "Microsoft.Compute/restorePointCollections" `
        -ErrorAction SilentlyContinue

    foreach ($collection in $collections) {

        Write-Host "[INFO] Deleting RPC:" $collection.Name

        Remove-AzResource `
            -ResourceId $collection.ResourceId `
            -Force

        Write-Host "[OK] RPC deleted"
    }
}

# ==========================================================
# WAIT UNTIL RPCs ARE GONE
# ==========================================================
Write-Host "[INFO] Verifying restore points are deleted..."
Start-Sleep 40

Write-Host ""
Write-Host "================================================="
Write-Host " PHASE 1 COMPLETED SUCCESSFULLY"
Write-Host " VM Deallocated"
Write-Host " Public IP Detached"
Write-Host " Backup Removed"
Write-Host " Restore Points Deleted"
Write-Host "================================================="
