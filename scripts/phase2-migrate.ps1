. "$PSScriptRoot/config.ps1"

$ErrorActionPreference = "Stop"

Import-Module Az.Accounts -Force
Import-Module Az.Compute -Force
Import-Module Az.Network -Force
Import-Module Az.Resources -Force

Write-Host "==========================================="
Write-Host "PHASE 2: MIGRATION STARTED"
Write-Host "==========================================="

# ---------------------------------------------------
# Validate Config
# ---------------------------------------------------
if (-not $SourceSubscriptionId -or -not $DestinationSubscriptionId -or `
    -not $SourceResourceGroup -or -not $DestinationResourceGroup -or `
    -not $DestinationLocation -or -not $VMName) {

    throw "One or more required configuration values are missing in config.ps1"
}

# ---------------------------------------------------
# Switch to Source Subscription
# ---------------------------------------------------
Write-Host "Switching to Source Subscription..."
Set-AzContext -SubscriptionId $SourceSubscriptionId

$currentContext = Get-AzContext
Write-Host "Current Source Subscription: $($currentContext.Subscription.Id)"

# ---------------------------------------------------
# Get VM
# ---------------------------------------------------
$vm = Get-AzVM -Name $VMName -ResourceGroupName $SourceResourceGroup -ErrorAction Stop

if (-not $vm) {
    throw "VM '$VMName' not found in source subscription."
}

Write-Host "VM Found: $($vm.Name)"
Write-Host "VM Location: $($vm.Location)"

# ---------------------------------------------------
# Validate Region (Move-AzResource does NOT support cross-region)
# ---------------------------------------------------
if ($vm.Location -ne $DestinationLocation) {
    throw "Cross-region migration is NOT supported. Source: $($vm.Location) | Destination: $DestinationLocation"
}

# ---------------------------------------------------
# Collect All Dependent Resources
# ---------------------------------------------------
$resourcesToMove = @()

# VM
$resourcesToMove += $vm.Id

# OS Disk
if ($vm.StorageProfile.OsDisk.ManagedDisk) {
    $resourcesToMove += $vm.StorageProfile.OsDisk.ManagedDisk.Id
}

# Data Disks
foreach ($disk in $vm.StorageProfile.DataDisks) {
    if ($disk.ManagedDisk) {
        $resourcesToMove += $disk.ManagedDisk.Id
    }
}

# NICs + Associated Public IP + NSG
foreach ($nicRef in $vm.NetworkProfile.NetworkInterfaces) {

    $nic = Get-AzNetworkInterface -ResourceId $nicRef.Id
    $resourcesToMove += $nic.Id

    # Public IP
    foreach ($ipconfig in $nic.IpConfigurations) {
        if ($ipconfig.PublicIpAddress) {
            $resourcesToMove += $ipconfig.PublicIpAddress.Id
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
Write-Host "Switching to Destination Subscription..."
Set-AzContext -SubscriptionId $DestinationSubscriptionId

$currentContext = Get-AzContext
Write-Host "Current Destination Subscription: $($currentContext.Subscription.Id)"

# ---------------------------------------------------
# Create Destination Resource Group if needed
# ---------------------------------------------------
$destRG = Get-AzResourceGroup -Name $DestinationResourceGroup -ErrorAction SilentlyContinue

if (-not $destRG) {
    Write-Host "Creating Destination Resource Group..."
    New-AzResourceGroup `
        -Name $DestinationResourceGroup `
        -Location $DestinationLocation
}

# ---------------------------------------------------
# Perform Move
# ---------------------------------------------------
Write-Host "Starting Resource Move..."

Move-AzResource `
    -ResourceId $resourcesToMove `
    -DestinationSubscriptionId $DestinationSubscriptionId `
    -DestinationResourceGroupName $DestinationResourceGroup `
    -ErrorAction Stop

Write-Host "Migration Completed Successfully."
Write-Host "==========================================="
