. "$PSScriptRoot/config.ps1"

$ErrorActionPreference = "Stop"

Import-Module Az.Accounts -Force
Import-Module Az.Compute -Force
Import-Module Az.Network -Force
Import-Module Az.Resources -Force

Write-Host "==========================================="
Write-Host "PHASE 2: FULL STACK MIGRATION"
Write-Host "==========================================="

# ---------------------------------------------------
# Switch to Source Subscription
# ---------------------------------------------------
Set-AzContext -SubscriptionId $SourceSubscriptionId

$vm = Get-AzVM -Name $VMName -ResourceGroupName $SourceResourceGroup -ErrorAction Stop

Write-Host "Stopping VM..."
Stop-AzVM -Name $VMName -ResourceGroupName $SourceResourceGroup -Force

# ---------------------------------------------------
# Collect Resources
# ---------------------------------------------------
$resourcesToMove = @()
$publicIpObject = $null

# VM
$resourcesToMove += $vm.Id

# Disks
$resourcesToMove += $vm.StorageProfile.OsDisk.ManagedDisk.Id

foreach ($disk in $vm.StorageProfile.DataDisks) {
    if ($disk.ManagedDisk) {
        $resourcesToMove += $disk.ManagedDisk.Id
    }
}

# Networking
foreach ($nicRef in $vm.NetworkProfile.NetworkInterfaces) {

    $nic = Get-AzNetworkInterface -ResourceId $nicRef.Id
    $resourcesToMove += $nic.Id

    foreach ($ipconfig in $nic.IpConfigurations) {

        # ---------------------------
        # Handle Public IP (Version Safe)
        # ---------------------------
        if ($ipconfig.PublicIpAddress) {

            $publicIpId   = $ipconfig.PublicIpAddress.Id
            $publicIpName = $publicIpId.Split("/")[-1]
            $publicIpRG   = $publicIpId.Split("/")[4]

            $publicIpObject = Get-AzPublicIpAddress `
                -Name $publicIpName `
                -ResourceGroupName $publicIpRG

            $resourcesToMove += $publicIpObject.Id

            # Disassociate Public IP
            Write-Host "Disassociating Public IP..."
            $ipconfig.PublicIpAddress = $null
            Set-AzNetworkInterface -NetworkInterface $nic
        }

        # ---------------------------
        # Subnet + VNet
        # ---------------------------
        $subnetId = $ipconfig.Subnet.Id
        $vnetName = $subnetId.Split("/")[8]
        $subnetName = $subnetId.Split("/")[-1]
        $vnetRG = $subnetId.Split("/")[4]

        $vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $vnetRG

        $resourcesToMove += $vnet.Id

        # Route Table (if attached)
        $subnet = $vnet.Subnets | Where-Object { $_.Name -eq $subnetName }

        if ($subnet.RouteTable) {
            $resourcesToMove += $subnet.RouteTable.Id
        }
    }

    # NIC NSG
    if ($nic.NetworkSecurityGroup) {
        $resourcesToMove += $nic.NetworkSecurityGroup.Id
    }
}

# Remove duplicates
$resourcesToMove = $resourcesToMove | Select-Object -Unique

Write-Host "-------------------------------------------"
Write-Host "Resources to Move:"
$resourcesToMove | ForEach-Object { Write-Host $_ }
Write-Host "-------------------------------------------"

# ---------------------------------------------------
# Switch to Destination Subscription
# ---------------------------------------------------
Set-AzContext -SubscriptionId $DestinationSubscriptionId

# Create Destination RG if needed
if (-not (Get-AzResourceGroup -Name $DestinationResourceGroup -ErrorAction SilentlyContinue)) {
    Write-Host "Creating Destination Resource Group..."
    New-AzResourceGroup `
        -Name $DestinationResourceGroup `
        -Location $DestinationLocation
}

# ---------------------------------------------------
# Perform Move
# ---------------------------------------------------
Write-Host "Starting Move..."

Move-AzResource `
    -ResourceId $resourcesToMove `
    -DestinationSubscriptionId $DestinationSubscriptionId `
    -DestinationResourceGroupName $DestinationResourceGroup `
    -Force `
    -ErrorAction Stop

Write-Host "Move Completed Successfully."

# ---------------------------------------------------
# Reattach Public IP (Destination)
# ---------------------------------------------------
if ($publicIpObject) {

    Write-Host "Reattaching Public IP..."

    $nicName = $vm.NetworkProfile.NetworkInterfaces[0].Id.Split("/")[-1]

    $nic = Get-AzNetworkInterface `
        -Name $nicName `
        -ResourceGroupName $DestinationResourceGroup

    $publicIp = Get-AzPublicIpAddress `
        -Name $publicIpObject.Name `
        -ResourceGroupName $DestinationResourceGroup

    $nic.IpConfigurations[0].PublicIpAddress = $publicIp
    Set-AzNetworkInterface -NetworkInterface $nic
}

# ---------------------------------------------------
# Start VM
# ---------------------------------------------------
Write-Host "Starting VM..."
Start-AzVM -Name $VMName -ResourceGroupName $DestinationResourceGroup

Write-Host "==========================================="
Write-Host "MIGRATION COMPLETED SUCCESSFULLY"
Write-Host "==========================================="
