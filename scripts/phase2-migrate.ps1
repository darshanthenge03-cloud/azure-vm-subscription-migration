$ErrorActionPreference = "Stop"

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
# SET SOURCE CONTEXT (PowerShell)
# ================================
Set-AzContext -SubscriptionId $SourceSubscriptionId | Out-Null
Write-Host "[OK] Source subscription set"

# ================================
# GET VM + FULL RESOURCE IDS
# ================================
$vm = Get-AzVM -Name $VMName -ResourceGroupName $SourceResourceGroup
Write-Host "[OK] VM found: $($vm.Name)"

$resourceIds = @()
$NicPipMap   = @{}

# VM ID
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

# Public IPs (detached in Phase 1)
$pips = Get-AzPublicIpAddress -ResourceGroupName $SourceResourceGroup -ErrorAction SilentlyContinue

foreach ($pip in $pips) {

    $resourceIds += $pip.Id

    $primaryNic = $NicPipMap.Keys | Select-Object -First 1
    $NicPipMap[$primaryNic]["PipName"] = $pip.Name
}

Write-Host "[INFO] Resource IDs to move:"
$resourceIds | ForEach-Object { Write-Host $_ }

# ================================
# SET AZ CLI TO SOURCE
# ================================
Write-Host "[INFO] Setting Azure CLI to SOURCE subscription..."
az account set --subscription $SourceSubscriptionId

# Confirm VM exists
az vm show --name $VMName --resource-group $SourceResourceGroup | Out-Null

# ================================
# CREATE DESTINATION RG IF NEEDED
# ================================
Write-Host "[INFO] Switching CLI to DESTINATION subscription..."
az account set --subscription $DestinationSubscriptionId

$rgCheck = az group exists --name $DestinationResourceGroup

if ($rgCheck -eq "false") {
    Write-Host "[ACTION] Creating destination RG..."
    az group create --name $DestinationResourceGroup --location $DestinationLocation | Out-Null
    Write-Host "[OK] Destination RG created"
}
else {
    Write-Host "[OK] Destination RG already exists"
}

# ================================
# SWITCH BACK TO SOURCE FOR MOVE
# ================================
az account set --subscription $SourceSubscriptionId

# ================================
# MOVE RESOURCES
# ================================
Write-Host "[ACTION] Moving resources..."

az resource move `
  --destination-group $DestinationResourceGroup `
  --destination-subscription-id $DestinationSubscriptionId `
  --ids $($resourceIds -join ' ')

if ($LASTEXITCODE -ne 0) {
    Write-Error "Resource move failed. Stopping execution."
    exit 1
}

Write-Host "[OK] Resource move completed"

# ================================
# SWITCH TO DESTINATION
# ================================
Write-Host "[INFO] Switching to DESTINATION subscription..."
az account set --subscription $DestinationSubscriptionId
Set-AzContext -SubscriptionId $DestinationSubscriptionId | Out-Null

# ================================
# REATTACH PUBLIC IP
# ================================
Write-Host "[INFO] Reattaching Public IP..."

foreach ($nicName in $NicPipMap.Keys) {

    $pipName      = $NicPipMap[$nicName]["PipName"]
    $ipConfigName = $NicPipMap[$nicName]["IpConfigName"]

    if (-not $pipName) { continue }

    $nic = Get-AzNetworkInterface -Name $nicName -ResourceGroupName $DestinationResourceGroup
    $pip = Get-AzPublicIpAddress -Name $pipName -ResourceGroupName $DestinationResourceGroup

    Write-Host "[ACTION] Reattaching $pipName to $nicName"

    Set-AzNetworkInterfaceIpConfig `
        -NetworkInterface $nic `
        -Name $ipConfigName `
        -PublicIpAddress $pip | Out-Null

    Set-AzNetworkInterface -NetworkInterface $nic | Out-Null

    Write-Host "[OK] Public IP reattached"
}

# ================================
# START VM
# ================================
Write-Host "[ACTION] Starting VM..."
Start-AzVM -Name $VMName -ResourceGroupName $DestinationResourceGroup | Out-Null

Write-Host "================================================="
Write-Host " MIGRATION COMPLETED SUCCESSFULLY"
Write-Host " VM moved, IP reattached, VM running"
Write-Host "================================================="

exit 0
