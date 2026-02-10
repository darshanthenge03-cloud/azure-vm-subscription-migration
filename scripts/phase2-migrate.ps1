. "$PSScriptRoot/config.ps1"

$ErrorActionPreference = "Stop"

Import-Module Az.Accounts -Force
Import-Module Az.Compute -Force
Import-Module Az.Network -Force
Import-Module Az.Resources -Force
Import-Module Az.RecoveryServices -Force
Import-Module Az.Storage -Force

Write-Host "==========================================="
Write-Host "PHASE 2: FINAL FULL DEPENDENCY MIGRATION"
Write-Host "==========================================="

# ---------------------------------------------------
# Switch to Source Subscription
# ---------------------------------------------------
Set-AzContext -SubscriptionId $SourceSubscriptionId

$vm = Get-AzVM -Name $VMName -ResourceGroupName $SourceResourceGroup -ErrorAction Stop

# ---------------------------------------------------
# Disable Backup + Remove Recovery Points
# ---------------------------------------------------
Write-Host "Removing backup protection..."

$vault = Get-AzRecoveryServicesVault -Name $VaultName -ErrorAction SilentlyContinue

if ($vault) {
    Set-AzRecoveryServicesVaultContext -Vault $vault

    $container = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVM |
        Where-Object { $_.FriendlyName -eq $VMName }

    if ($container) {
        $item = Get-AzRecoveryServicesBackupItem -Container $container -WorkloadType AzureVM -ErrorAction SilentlyContinue

        if ($item) {
            Disable-AzRecoveryServicesBackupProtection -Item $item -RemoveRecoveryPoints -Force
            Start-Sleep -Seconds 30
        }
    }
}

# ---------------------------------------------------
# Stop VM
# ---------------------------------------------------
Stop-AzVM -Name $VMName -ResourceGroupName $SourceResourceGroup -Force

# ---------------------------------------------------
# Collect ALL Dependencies
# ---------------------------------------------------
$resourcesToMove = @()

# VM
$resourcesToMove += $vm.Id

# Availability Set
if ($vm.AvailabilitySetReference) {
    $resourcesToMove += $vm.AvailabilitySetReference.Id
}

# Disks
$resourcesToMove += $vm.StorageProfile.OsDisk.ManagedDisk.Id
foreach ($disk in $vm.StorageProfile.DataDisks) {
    if ($disk.ManagedDisk) {
        $resourcesToMove += $disk.ManagedDisk.Id
    }
}

# Boot Diagnostics Storage
if ($vm.DiagnosticsProfile -and $vm.DiagnosticsProfile.BootDiagnostics.Enabled) {

    $storageUri = $vm.DiagnosticsProfile.BootDiagnostics.StorageUri

    if ($storageUri) {
        $storageAccountName = $storageUri.Split("//")[1].Split(".")[0]

        $storageAccount = Get-AzStorageAccount -ResourceGroupName $SourceResourceGroup |
            Where-Object { $_.StorageAccountName -eq $storageAccountName }

        if ($storageAccount) {
            $resourcesToMove += $storageAccount.Id
            Write-Host "Added Boot Diagnostics Storage Account: $storageAccountName"
        }
    }
}

# Networking
foreach ($nicRef in $vm.NetworkProfile.NetworkInterfaces) {

    $nic = Get-AzNetworkInterface -ResourceId $nicRef.Id
    $resourcesToMove += $nic.Id

    # NIC NSG
    if ($nic.NetworkSecurityGroup) {
        $resourcesToMove += $nic.NetworkSecurityGroup.Id
    }

    foreach ($ipconfig in $nic.IpConfigurations) {

        # Public IP
        if ($ipconfig.PublicIpAddress) {
            $pipId = $ipconfig.PublicIpAddress.Id
            $pipName = $pipId.Split("/")[-1]
            $pipRG = $pipId.Split("/")[4]

            $pip = Get-AzPublicIpAddress -Name $pipName -ResourceGroupName $pipRG
            $resourcesToMove += $pip.Id

            # Disassociate
            $ipconfig.PublicIpAddress = $null
            Set-AzNetworkInterface -NetworkInterface $nic
        }

        # VNet + Subnet
        $subnetId = $ipconfig.Subnet.Id
        $vnetName = $subnetId.Split("/")[8]
        $vnetRG   = $subnetId.Split("/")[4]

        $vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $vnetRG
        $resourcesToMove += $vnet.Id

        # Route Table
        $subnetName = $subnetId.Split("/")[-1]
        $subnet = $vnet.Subnets | Where-Object { $_.Name -eq $subnetName }

        if ($subnet.RouteTable) {
            $resourcesToMove += $subnet.RouteTable.Id
        }
    }
}

# Remove duplicates
$resourcesToMove = $resourcesToMove | Select-Object -Unique

Write-Host "Resources to Move:"
$resourcesToMove | ForEach-Object { Write-Host $_ }

# ---------------------------------------------------
# Switch to Destination Subscription
# ---------------------------------------------------
Set-AzContext -SubscriptionId $DestinationSubscriptionId

if (-not (Get-AzResourceGroup -Name $DestinationResourceGroup -ErrorAction SilentlyContinue)) {
    New-AzResourceGroup -Name $DestinationResourceGroup -Location $DestinationLocation
}

# ---------------------------------------------------
# Perform Move
# ---------------------------------------------------
Write-Host "Starting Resource Move..."

Move-AzResource `
    -ResourceId $resourcesToMove `
    -DestinationSubscriptionId $DestinationSubscriptionId `
    -DestinationResourceGroupName $DestinationResourceGroup `
    -Force `
    -ErrorAction Stop

Write-Host "Move Completed Successfully."

# ---------------------------------------------------
# Start VM
# ---------------------------------------------------
Start-AzVM -Name $VMName -ResourceGroupName $DestinationResourceGroup

Write-Host "==========================================="
Write-Host "MIGRATION COMPLETED SUCCESSFULLY"
Write-Host "==========================================="
