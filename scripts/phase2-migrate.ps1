$ErrorActionPreference = "Stop"

# ================================
# USER INPUT
# ================================
$SourceSubscriptionId      = "46689057-be43-4229-9241-e0591dad4dbf"
$DestinationSubscriptionId = "d4e068bf-2473-4201-b10a-7f8501d50ebc"

$SourceResourceGroup       = "Dev-RG"
$DestinationResourceGroup  = "Dev-RG"
$DestinationLocation       = "Central India"

$VMName = "ubuntuServer"

Write-Host "================================================="
Write-Host " AZURE VM SUBSCRIPTION MIGRATION (PHASE 2)"
Write-Host "================================================="

# ================================
# SET SOURCE CONTEXT
# ================================
Write-Host "[INFO] Switching to SOURCE subscription..."
Set-AzContext -SubscriptionId $SourceSubscriptionId | Out-Null
Write-Host "[OK] Source subscription set"

# ================================
# GET VM
# ================================
$vm = Get-AzVM -Name $VMName -ResourceGroupName $SourceResourceGroup
Write-Host "[OK] VM found:" $vm.Name

# ================================
# COLLECT DEPENDENCIES
# ================================
Write-Host "[INFO] Collecting resource dependencies..."

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

    # Store primary NIC info for reattach
    $NicPipMap[$nic.Name] = @{
        IpConfigName = $nic.IpConfigurations[0].Name
    }
}

# ================================
# FIND PUBLIC IP (Detached in Phase-1)
# ================================
Write-Host "[INFO] Searching for Public IP in source RG..."

$pips = Get-AzPublicIpAddress -ResourceGroupName $SourceResourceGroup -ErrorAction SilentlyContinue

foreach ($pip in $pips) {

    Write-Host "[TRACK] Public IP found:" $pip.Name
    $resourceIds += $pip.Id

    # Map PIP to primary NIC
    $primaryNicName = $NicPipMap.Keys | Select-Object -First 1
    $NicPipMap[$primaryNicName]["PipName"] = $pip.Name
}

Write-Host "[OK] Dependency collection completed"

# ================================
# SWITCH TO DESTINATION
# ================================
Write-Host "[INFO] Switching to DESTINATION subscription..."
Set-AzContext -SubscriptionId $DestinationSubscriptionId | Out-Null

# Create RG if not exists
if (-not (Get-AzResourceGroup -Name $DestinationResourceGroup -ErrorAction SilentlyContinue)) {

    Write-Host "[ACTION] Creating destination Resource Group..."
    New-AzResourceGroup `
        -Name $DestinationResourceGroup `
        -Location $DestinationLocation | Out-Null

    Write-Host "[OK] Destination Resource Group created"
}
else {
    Write-Host "[OK] Destination Resource Group already exists"
}

# ================================
# VALIDATION
# ================================
Import-Module Az.Resources -Force

Write-Host "[INFO] Running Test-AzResourceMove..."
Test-AzResourceMove `
    -ResourceId $resourceIds `
    -DestinationSubscriptionId $DestinationSubscriptionId `
    -DestinationResourceGroupName $DestinationResourceGroup

Write-Host "[OK] Pre-move validation PASSED"

# ================================
# MOVE
# ================================
Write-Host "[ACTION] Moving resources..."
Move-AzResource `
    -ResourceId $resourceIds `
    -DestinationSubscriptionId $DestinationSubscriptionId `
    -DestinationResourceGroupName $DestinationResourceGroup `
    -Force

Write-Host "[OK] Resource move completed"

# ================================
# REATTACH PUBLIC IP
# ================================
Write-Host "[INFO] Reattaching Public IP..."

foreach ($nicName in $NicPipMap.Keys) {

    $pipName      = $NicPipMap[$nicName]["PipName"]
    $ipConfigName = $NicPipMap[$nicName]["IpConfigName"]

    if (-not $pipName) { continue }

    $nic = Get-AzNetworkInterface `
        -Name $nicName `
        -ResourceGroupName $DestinationResourceGroup

    $pip = Get-AzPublicIpAddress `
        -Name $pipName `
        -ResourceGroupName $DestinationResourceGroup

    Write-Host "[ACTION] Reattaching PIP:" $pipName

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
Write-Host "[OK] VM started successfully"

Write-Host "================================================="
Write-Host " PHASE 2 COMPLETED SUCCESSFULLY"
Write-Host "================================================="

exit 0
