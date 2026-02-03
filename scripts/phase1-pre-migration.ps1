$ErrorActionPreference = "Stop"

Import-Module Az.Accounts
Import-Module Az.Compute
Import-Module Az.Network
Import-Module Az.RecoveryServices
Import-Module Az.Resources

# ================================
# USER INPUT
# ================================
$SourceSubscriptionId = "46689057-be43-4229-9241-e0591dad4dbf"
$SourceResourceGroup  = "Dev-RG"
$VMName               = "ubuntuServer"

Write-Host "================================================="
Write-Host " PHASE 1 - PRE MIGRATION CLEANUP"
Write-Host "================================================="

# ================================
# SET CONTEXT
# ================================
Set-AzContext -SubscriptionId $SourceSubscriptionId | Out-Null
Write-Host "[OK] Source subscription set"

# ================================
# GET VM
# ================================
$vm = Get-AzVM -Name $VMName -ResourceGroupName $SourceResourceGroup
Write-Host "[OK] VM found"

# ================================
# STOP & DEALLOCATE VM
# ================================
Write-Host "[ACTION] Stopping VM..."
Stop-AzVM -Name $VMName -ResourceGroupName $SourceResourceGroup -Force

do {
    Start-Sleep 10
    $state = (Get-AzVM -Name $VMName -ResourceGroupName $SourceResourceGroup -Status).Statuses |
        Where-Object Code -like "PowerState/*"
    Write-Host "[INFO] VM State:" $state.DisplayStatus
}
while ($state.DisplayStatus -ne "VM deallocated")

Write-Host "[OK] VM deallocated"

# ================================
# DETACH PUBLIC IP (MANDATORY)
# ================================
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

# ================================
# REMOVE BACKUP PROTECTION
# ================================
Write-Host "[INFO] Removing backup protection..."

$vaults = Get-AzRecoveryServicesVault

foreach ($vault in $vaults) {

    Set-AzRecoveryServicesVaultContext -Vault $vault

    $backupItems = Get-AzRecoveryServicesBackupItem `
        -WorkloadType AzureVM `
        -BackupManagementType AzureVM `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -eq $VMName }

    foreach ($item in $backupItems) {

        Write-Host "[ACTION] Disabling backup in vault:" $vault.Name

        Disable-AzRecoveryServicesBackupProtection `
            -Item $item `
            -RemoveRecoveryPoints `
            -Force

        Write-Host "[OK] Backup removed"
    }
}

# ================================
# DELETE RESTORE POINT COLLECTIONS
# ================================
Write-Host "[ACTION] Deleting Restore Point Collections..."

$rpcRGs = Get-AzResourceGroup | Where-Object { $_.ResourceGroupName -like "AzureBackupRG_*" }

foreach ($rg in $rpcRGs) {

    $collections = Get-AzRestorePointCollection `
        -ResourceGroupName $rg.ResourceGroupName `
        -ErrorAction SilentlyContinue

    foreach ($collection in $collections) {

        Write-Host "[ACTION] Removing RPC:" $collection.Name

        Remove-AzRestorePointCollection `
            -ResourceGroupName $rg.ResourceGroupName `
            -Name $collection.Name `
            -Force

        Write-Host "[OK] RPC deleted"
    }
}

# ================================
# WAIT FOR CLEANUP
# ================================
Write-Host "[INFO] Waiting for restore points to clear..."
Start-Sleep 40

Write-Host "================================================="
Write-Host " PHASE 1 COMPLETED SUCCESSFULLY"
Write-Host " VM stopped"
Write-Host " Public IP detached"
Write-Host " Backup removed"
Write-Host " Restore points deleted"
Write-Host "================================================="
