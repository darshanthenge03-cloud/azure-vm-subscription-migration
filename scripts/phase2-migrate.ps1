. "$PSScriptRoot/config.ps1"

$ErrorActionPreference = "Stop"

Write-Host "==========================================="
Write-Host "PHASE 2: MIGRATION STARTED"
Write-Host "==========================================="

# ---------------------------
# Switch to Source
# ---------------------------
Write-Host "Switching to Source Subscription..."
Set-AzContext -SubscriptionId $SourceSubscriptionId

$vm = Get-AzVM -Name $VMName -ResourceGroupName $SourceResourceGroup -ErrorAction Stop

if (-not $vm) {
    throw "VM not found in source subscription."
}

Write-Host "VM Found: $($vm.Name)"

# ---------------------------
# Collect Resources
# ---------------------------
$resourcesToMove = @()

# VM
$resourcesToMove += $vm.Id

# OS Disk
$resourcesToMove += $vm.StorageProfile.OsDisk.ManagedDisk.Id

# Data Disks
foreach ($disk in $vm.StorageProfile.DataDisks) {
    $resourcesToMove += $disk.ManagedDisk.Id
}

# NICs
foreach ($nic in $vm.NetworkProfile.NetworkInterfaces) {
    $resourcesToMove += $nic.Id
}

Write-Host "Resources to move:"
$resourcesToMove | ForEach-Object { Write-Host $_ }

# ---------------------------
# Switch to Destination
# ---------------------------
Write-Host "Switching to Destination Subscription..."
Set-AzContext -SubscriptionId $DestinationSubscriptionId

# ---------------------------
# Auto Create Destination RG
# ---------------------------
$destRG = Get-AzResourceGroup -Name $DestinationResourceGroup -ErrorAction SilentlyContinue

if (-not $destRG) {
    Write-Host "Creating Destination Resource Group..."
    New-AzResourceGroup `
        -Name $DestinationResourceGroup `
        -Location $DestinationLocation
}

# ---------------------------
# Perform Move
# ---------------------------
Write-Host "Starting Resource Move..."

Move-AzResource `
    -ResourceId $resourcesToMove `
    -DestinationSubscriptionId $DestinationSubscriptionId `
    -DestinationResourceGroupName $DestinationResourceGroup

Write-Host "Migration Completed Successfully."
Write-Host "==========================================="
