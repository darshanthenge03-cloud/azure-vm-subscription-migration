. "$PSScriptRoot/config.ps1"

$ErrorActionPreference = "Stop"

Import-Module Az.Accounts -Force
Import-Module Az.Compute -Force
Import-Module Az.Network -Force
Import-Module Az.Resources -Force

Write-Host "==========================================="
Write-Host "PHASE 2: FULL STACK MIGRATION"
Write-Host "==========================================="

# Switch to Source
Set-AzContext -SubscriptionId $SourceSubscriptionId

$vm = Get-AzVM -Name $VMName -ResourceGroupName $SourceResourceGroup -ErrorAction Stop

Write-Host "Stopping VM..."
Stop-AzVM -Name $VMName -ResourceGroupName $SourceResourceGroup -Force

# ----------------------------
# Collect Resources
# ----------------------------

$resourcesToMove = @()

# VM
$resourcesToMove += $vm.Id

# Disks
$resourcesToMove += $vm.StorageProfile.OsDisk.ManagedDisk.Id

foreach ($disk in $vm.StorageProfile.DataDisks) {
    $resourcesToMove += $disk.ManagedDisk.Id
}

# NIC + Networking
foreach ($nicRef in $vm.NetworkProfile.NetworkInterfaces) {

    $nic = Get-AzNetworkInterface -ResourceId $nicRef.Id
    $resourcesToMove += $nic.Id

    foreach ($ipconfig in $nic.IpConfigurations) {

        # Public IP
        if ($ipconfig.PublicIpAddress) {
            $publicIp = Get-AzPublicIpAddress -ResourceId $ipconfig.PublicIpAddress.Id
            $resourcesToMove += $publicIp.Id

            # Disassociate Public IP
            Write-Host "Disassociating Public IP..."
            $ipconfig.PublicIpAddress = $null
            Set-AzNetworkInterface -NetworkInterface $nic
        }

        # Subnet
        $subnet = Get-AzVirtualNetworkSubnetConfig `
            -VirtualNetwork (Get-AzVirtualNetwork -ResourceGroupName $SourceResourceGroup | Where-Object { $_.Subnets.Id -contains $ipconfig.Subnet.Id }) `
            -Name ($ipconfig.Subnet.Id.Split("/")[-1])

        $vnet = Get-AzVirtualNetwork -ResourceGroupName $SourceResourceGroup -Name ($ipconfig.Subnet.Id.Split("/")[8])

        $resourcesToMove += $vnet.Id

        # Route Table
        if ($subnet.RouteTable) {
            $resourcesToMove += $subnet.RouteTable.Id
        }
    }

    # NIC NSG
    if ($nic.NetworkSecurityGroup) {
        $resourcesToMove += $nic.NetworkSecurityGroup.Id
    }
}

$resourcesToMove = $resourcesToMove | Select-Object -Unique

Write-Host "Resources being moved:"
$resourcesToMove | ForEach-Object { Write-Host $_ }

# ----------------------------
# Switch to Destination
# ----------------------------
Set-AzContext -SubscriptionId $DestinationSubscriptionId

# Create RG if missing
if (-not (Get-AzResourceGroup -Name $DestinationResourceGroup -ErrorAction SilentlyContinue)) {
    New-AzResourceGroup `
        -Name $DestinationResourceGroup `
        -Location $DestinationLocation
}

# ----------------------------
# Move Resources
# ----------------------------
Write-Host "Starting Move..."
Move-AzResource `
    -ResourceId $resourcesToMove `
    -DestinationSubscriptionId $DestinationSubscriptionId `
    -DestinationResourceGroupName $DestinationResourceGroup `
    -Force

Write-Host "Move Completed."

# ----------------------------
# Reattach Public IP (Destination Context)
# ----------------------------

Set-AzContext -SubscriptionId $DestinationSubscriptionId

$nic = Get-AzNetworkInterface -Name $vm.NetworkProfile.NetworkInterfaces[0].Id.Split("/")[-1] -ResourceGroupName $DestinationResourceGroup
$publicIp = Get-AzPublicIpAddress -Name $publicIp.Name -ResourceGroupName $DestinationResourceGroup

if ($publicIp) {
    Write-Host "Reattaching Public IP..."
    $nic.IpConfigurations[0].PublicIpAddress = $publicIp
    Set-AzNetworkInterface -NetworkInterface $nic
}

# Start VM
Start-AzVM -Name $VMName -ResourceGroupName $DestinationResourceGroup

Write-Host "==========================================="
Write-Host "MIGRATION COMPLETED SUCCESSFULLY"
Write-Host "==========================================="
