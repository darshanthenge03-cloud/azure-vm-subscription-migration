$ErrorActionPreference = "Stop"

# ================================
# INPUT
# ================================
$SubscriptionId = "46689057-be43-4229-9241-e0591dad4dbf"
$ResourceGroup  = "Dev-RG"
$VMName         = "ubuntuServer"

# ================================
Write-Host "======================================="
Write-Host " PHASE 1: IP DETACH + BACKUP CLEANUP "
Write-Host "======================================="

# ================================
# CONTEXT
# ================================
Set-AzContext -SubscriptionId $SubscriptionId
Write-Host "Subscription context set."

# ================================
# GET VM
# ================================
$vm = Get-AzVM -Name $VMName -ResourceGroupName $ResourceGroup
Write-Host "VM found:" $vm.Name

# ================================
# STOP & DEALLOCATE VM
# ================================
Write-Host "Stopping VM..."
Stop-AzVM -Name $VMName -ResourceGroupName $ResourceGroup -Force

do {
    Start-Sleep 10
    $state = (Get-AzVM -Name $VMName -ResourceGroupName $ResourceGroup -Status).Statuses |
        Where-Object Code -like "PowerState/*"
    Write-Host "VM state:" $state.DisplayStatus
}
while ($state.DisplayStatus -ne "VM deallocated")

Write-Host "VM deallocated."

# ================================
# DISASSOCIATE PUBLIC IP
# ================================
Write-Host "Checking NICs for Public IP..."

foreach ($nicRef in $vm.NetworkProfile.NetworkInterfaces) {

    $nic = Get-AzNetworkInterface -ResourceId $nicRef.Id

    foreach ($ipConfig in $nic.IpConfigurations) {

        if ($ipConfig.PublicIpAddress) {

            $pipId   = $ipConfig.PublicIpAddress.Id
            $pipName = ($pipId -split "/")[-1]

            Write-Host "Detaching Public IP:" $pipName

            Set-AzNetworkInterfaceIpConfig `
                -NetworkInterface $nic `
                -Name $ipConfig.Name `
                -PublicIpAddress $null

            Set-AzNetworkInterface -NetworkInterface $nic

            Write-Host "Public IP detached successfully."
        }
    }
}

# ================================
# BACKUP STATUS CHECK (AUTHORITATIVE)
# ================================
Write-Host "Checking Azure Backup status..."

$backupStatus = Get-AzRecoveryServicesBackupStatus `
    -ResourceId $vm.Id `
    -Type AzureVM

if (-not $backupStatus.BackedUp) {
    Write-Host "VM is NOT backed up. Skipping backup cleanup."
    return
}

Write-Host "VM IS backed up."
Write-Host "Vault Name :" $backupStatus.VaultName
Write-Host "Vault RG   :" $backupStatus.VaultResourceGroup

# ================================
# GET VAULT (EXACT)
# ================================
$vault = Get-AzRecoveryServicesVault `
    -Name $backupStatus.VaultName `
    -ResourceGroupName $backupStatus.VaultResourceGroup

Set-AzRecoveryServicesVaultContext -Vault $vault

# ================================
# GET BACKUP CONTAINER
# ================================
$container = Get-AzRecoveryServicesBackupContainer `
    -ContainerType AzureVM `
    -ErrorAction Stop |
    Where-Object { $_.FriendlyName -eq $VMName }

if (-not $container) {
    throw "Backup container not found for VM."
}

# ================================
# GET BACKUP ITEM
# ================================
$backupItem = Get-AzRecoveryServicesBackupItem `
    -Container $container `
    -WorkloadType AzureVM `
    -ErrorAction Stop

# ================================
# DISABLE BACKUP
# ================================
Write-Host "Disabling backup protection..."

Disable-AzRecoveryServicesBackupProtection `
    -Item $backupItem `
    -RemoveRecoveryPoints `
    -Force

Write-Host "Backup protection disabled."

# ================================
# DISABLE SOFT DELETE
# ================================
Write-Host "Disabling Soft Delete..."

Set-AzRecoveryServicesVaultProperty `
    -Vault $vault `
    -SoftDeleteFeatureState Disable

Write-Host "Soft Delete disabled."

Write-Host "======================================="
Write-Host " PHASE 1 COMPLETED SUCCESSFULLY "
Write-Host "======================================="
