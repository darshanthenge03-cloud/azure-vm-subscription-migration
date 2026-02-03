$ErrorActionPreference = "Stop"

Import-Module Az.Accounts
Import-Module Az.Compute
Import-Module Az.Network
Import-Module Az.Resources

# ================================
# USER INPUT
# ================================
$SourceSubscriptionId      = "46689057-be43-4229-9241-e0591dad4dbf"
$DestinationSubscriptionId = "d4e068bf-2473-4201-b10a-7f8501d50ebc"

$SourceResourceGroup       = "Dev-RG"
$DestinationResourceGroup  = "Dev-RG"
$DestinationLocation       = "centralindia"

$VMName = "ubuntuServer"

Write-Host "================================================="
Write-Host " AZURE VM SUBSCRIPTION MIGRATION (PHASE 2)"
Write-Host "================================================="

# ================================
# SOURCE CONTEXT
# ================================
Set-AzContext -SubscriptionId $SourceSubscriptionId | Out-Null
Write-Host "[OK] Source subscription set"

$vm = Get-AzVM -Name $VMName -ResourceGroupName $SourceResourceGroup
Write-Host "[OK] VM found"

$resourceIds = @()
$NicPipMap   = @{}

# VM
$resourceIds += $vm.Id

# OS Disk
$resourceIds += $vm.StorageProfile.OsDisk.ManagedDisk.Id

# Data Disks
foreach ($disk in $vm.StorageProfile.DataDisks) {
    $resourceIds += $disk.ManagedDisk.Id
}

# NICs
foreach ($nicRef in $vm.NetworkProfile.NetworkInterfaces) {

    $nic = Get-AzNetworkInterface -ResourceId $nicRef.Id
    $resourceIds += $nic.Id

    $NicPipMap[$nic.Name] = @{
        IpConfigName = $nic.IpConfigurations[0].Name
    }
}

# Public IPs
$pips = Get-AzPublicIpAddress -ResourceGroupName $SourceResourceGroup -ErrorAction SilentlyContinue

foreach ($pip in $pips) {

    $resourceIds += $pip.Id

    $primaryNic = $NicPipMap.Keys | Select-Object -First 1
    $NicPipMap[$primaryNic]["PipName"] = $pip.Name
}

Write-Host "[INFO] Resources to move:"
$resourceIds | ForEach-Object { Write-Host $_ }

# ================================
# DESTINATION RG CHECK
# ================================
Set-AzContext -SubscriptionId $DestinationSubscriptionId | Out-Null

if (-not (Get-AzResourceGroup -Name $DestinationResourceGroup -ErrorAction SilentlyContinue)) {

    Write-Host "[ACTION] Creating destination RG..."
    New-AzResourceGroup `
        -Name $DestinationResourceGroup `
        -Location $DestinationLocation | Out-Null

    Write-Host "[OK] Destination RG created"
}
else {
    Write-Host "[OK] Destination RG exists"
}

# ================================
# SWITCH BACK TO SOURCE FOR MOVE
# ================================
Set-AzContext -SubscriptionId $SourceSubscriptionId | Out-Null

Write-Host "[ACTION] Moving resources..."

Move-AzResource `
  -ResourceId $resourceIds `
  -DestinationSubscriptionId $DestinationSubscriptionId `
  -DestinationResourceGroupName $DestinationResourceGroup `
  -Force

Write-Host "[OK] Move completed"

# ================================
# SWITCH TO DESTINATION
# ================================
Set-AzContext -SubscriptionId $DestinationSubscriptionId | Out-Null

# ================================
# REATTACH PUBLIC IP
# ================================
foreach ($nicName in $NicPipMap.Keys) {

    $pipName      = $NicPipMap[$nicName]["PipName"]
    $ipConfigName = $NicPipMap[$nicName]["IpConfigName"]

    if (-not $pipName) { continue }

    $nic = Get-AzNetworkInterface -Name $nicName -ResourceGroupName $DestinationResourceGroup
    $pip = Get-AzPublicIpAddress -Name $pipName -ResourceGroupName $DestinationResourceGroup

    Write-Host "[ACTION] Reattaching $pipName"

    Set-AzNetworkInterfaceIpConfig `
        -NetworkInterface $nic `
        -Name $ipConfigName `
        -PublicIpAddress $pip | Out-Null

    Set-AzNetworkInterface -NetworkInterface $nic | Out-Null
}

Write-Host "[OK] Public IP reattached"

# ================================
# START VM
# ================================
Start-AzVM -Name $VMName -ResourceGroupName $DestinationResourceGroup | Out-Null

Write-Host "================================================="
Write-Host " MIGRATION COMPLETED SUCCESSFULLY"
Write-Host "================================================="
