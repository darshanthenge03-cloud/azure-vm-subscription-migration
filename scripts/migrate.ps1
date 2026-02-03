$ErrorActionPreference = "Stop"
Import-Module Az.Resources -Force

# ================================
# USER INPUT
# ================================
$SourceSubscriptionId      = "46689057-be43-4229-9241-e0591dad4dbf"
$DestinationSubscriptionId = "d4e068bf-2473-4201-b10a-7f8501d50ebc"

$SourceResourceGroup       = "Dev-RG"
$DestinationResourceGroup  = "Dev-RG"
$DestinationLocation       = "Central India"

$VMName = "ubuntuServer"

# ================================
Write-Host "======================================="
Write-Host " Azure VM Subscription Migration Script "
Write-Host "======================================="

# ================================
# VERIFY CONTEXT
# ================================
if (-not (Get-AzContext).Subscription) {
    throw "Azure login missing."
}

# ================================
# SOURCE CONTEXT
# ================================
Set-AzContext -SubscriptionId $SourceSubscriptionId
Write-Host "Source subscription set."

# ================================
# GET VM
# ================================
$vm = Get-AzVM -Name $VMName -ResourceGroupName $SourceResourceGroup
Write-Host "VM found:" $vm.Name

# ================================
# STOP & DEALLOCATE VM
# ================================
Stop-AzVM -Name $VMName -ResourceGroupName $SourceResourceGroup -Force

do {
    Start-Sleep 10
    $state = (Get-AzVM -Name $VMName -ResourceGroupName $SourceResourceGroup -Status).Statuses |
        Where-Object Code -like "PowerState/*"
    Write-Host "VM state:" $state.DisplayStatus
}
while ($state.DisplayStatus -ne "VM deallocated")

# ================================
# BACKUP CLEANUP
# ================================
Write-Host "Checking Azure Backup..."

$vaults = Get-AzRecoveryServicesVault -ErrorAction SilentlyContinue

foreach ($vault in $vaults) {

    Write-Host "Checking vault:" $vault.Name
    Set-AzRecoveryServicesVaultContext -Vault $vault

    $containers = Get-AzRecoveryServicesBackupContainer `
        -ContainerType AzureVM `
        -Status Registered `
        -ErrorAction SilentlyContinue

    foreach ($container in $containers) {

        $backupItem = Get-AzRecoveryServicesBackupItem `
            -Container $container `
            -WorkloadType AzureVM `
            -ErrorAction SilentlyContinue |
            Where-Object { $_.FriendlyName -eq $VMName }

        if ($backupItem) {
            Write-Host "Backup FOUND for VM:" $VMName

            Disable-AzRecoveryServicesBackupProtection `
                -Item $backupItem `
                -RemoveRecoveryPoints `
                -Force

            Write-Host "Backup protection disabled."

            Write-Host "Disabling soft delete..."
            Set-AzRecoveryServicesVaultProperty `
                -Vault $vault `
                -SoftDeleteFeatureState Disable

            Write-Host "Soft delete disabled."
        }
    }
}

# ================================
# DEPENDENCIES + PIP TRACKING
# ================================
$resourceIds = @()
$resourceIds += $vm.Id
$resourceIds += $vm.StorageProfile.OsDisk.ManagedDisk.Id

foreach ($disk in $vm.StorageProfile.DataDisks) {
    $resourceIds += $disk.ManagedDisk.Id
}

$NicPipMap = @{}

foreach ($nicRef in $vm.NetworkProfile.NetworkInterfaces) {

    $nic = Get-AzNetworkInterface -ResourceId $nicRef.Id
    $resourceIds += $nic.Id

    foreach ($ipConfig in $nic.IpConfigurations) {
        if ($ipConfig.PublicIpAddress) {

            $pipId = $ipConfig.PublicIpAddress.Id
            $pipName = ($pipId -split "/")[-1]

            Write-Host "Detaching Public IP:" $pipName

            $NicPipMap[$nic.Name] = @{
                IpConfigName = $ipConfig.Name
                PipName      = $pipName
            }

            Set-AzNetworkInterfaceIpConfig `
                -NetworkInterface $nic `
                -Name $ipConfig.Name `
                -PublicIpAddress $null

            Set-AzNetworkInterface -NetworkInterface $nic
        }
    }
}

# ================================
# DESTINATION CONTEXT + RG CREATE
# ================================
Set-AzContext -SubscriptionId $DestinationSubscriptionId

if (-not (Get-AzResourceGroup -Name $DestinationResourceGroup -ErrorAction SilentlyContinue)) {
    New-AzResourceGroup `
        -Name $DestinationResourceGroup `
        -Location $DestinationLocation
}

# ================================
# PRE-MOVE VALIDATION
# ================================
Test-AzResourceMove `
    -ResourceId $resourceIds `
    -DestinationSubscriptionId $DestinationSubscriptionId `
    -DestinationResourceGroupName $DestinationResourceGroup

# ================================
# MOVE RESOURCES
# ================================
Move-AzResource `
    -ResourceId $resourceIds `
    -DestinationSubscriptionId $DestinationSubscriptionId `
    -DestinationResourceGroupName $DestinationResourceGroup `
    -Force

# ================================
# RE-ATTACH SAME PUBLIC IP
# ================================
foreach ($nicName in $NicPipMap.Keys) {

    $pipName = $NicPipMap[$nicName].PipName
    $ipConfigName = $NicPipMap[$nicName].IpConfigName

    $nic = Get-AzNetworkInterface `
        -Name $nicName `
        -ResourceGroupName $DestinationResourceGroup

    $pip = Get-AzPublicIpAddress `
        -Name $pipName `
        -ResourceGroupName $DestinationResourceGroup

    Write-Host "Re-attaching Public IP:" $pipName

    Set-AzNetworkInterfaceIpConfig `
        -NetworkInterface $nic `
        -Name $ipConfigName `
        -PublicIpAddress $pip

    Set-AzNetworkInterface -NetworkInterface $nic
}

# ================================
# FINAL VALIDATION
# ================================
$vmCheck = Get-AzVM -Name $VMName -ResourceGroupName $DestinationResourceGroup
Start-AzVM -Name $VMName -ResourceGroupName $DestinationResourceGroup

Write-Host "======================================="
Write-Host " MIGRATION + PUBLIC IP REATTACH DONE "
Write-Host "======================================="
