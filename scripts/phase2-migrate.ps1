$ErrorActionPreference = "Stop"

# ==========================================================
# ENSURE REQUIRED MODULES
# ==========================================================
$requiredModules = @(
    "Az.Accounts",
    "Az.Compute",
    "Az.Network",
    "Az.Resources"
)

foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Install-Module $module -Force -Scope CurrentUser -AllowClobber
    }
    Import-Module $module -Force
}

# ==========================================================
# USER INPUT
# ==========================================================
$SourceSubscriptionId      = "46689057-be43-4229-9241-e0591dad4dbf"
$DestinationSubscriptionId = "d4e068bf-2473-4201-b10a-7f8501d50ebc"

$SourceResourceGroup       = "Dev-RG"
$DestinationResourceGroup  = "Dev-RG"
$DestinationLocation       = "centralindia"

$VMName = "ubuntuServer"

Write-Host "================================================="
Write-Host " AZURE VM SUBSCRIPTION MIGRATION (PHASE 2)"
Write-Host "================================================="

# ==========================================================
# SOURCE CONTEXT
# ==========================================================
Set-AzContext -SubscriptionId $SourceSubscriptionId | Out-Null
Write-Host "[OK] Source subscription set"

$vm = Get-AzVM -Name $VMName -ResourceGroupName $SourceResourceGroup
Write-Host "[OK] VM found"

$resourceIds = @()
$NicPipMap   = @{}

# ==========================================================
# COLLECT COMPUTE DEPENDENCIES
# ==========================================================
$resourceIds += $vm.Id
$resourceIds += $vm.StorageProfile.OsDisk.ManagedDisk.Id

foreach ($disk in $vm.StorageProfile.DataDisks) {
    $resourceIds += $disk.ManagedDisk.Id
}

# ==========================================================
# COLLECT NETWORK DEPENDENCIES
# ==========================================================
foreach ($nicRef in $vm.NetworkProfile.NetworkInterfaces) {

    $nic = Get-AzNetworkInterface -ResourceId $nicRef.Id
    $resourceIds += $nic.Id

    # VNet
    $subnetId = $nic.IpConfigurations[0].Subnet.Id
    $vnetId   = ($subnetId -replace "/subnets/.*","")

    if ($resourceIds -notcontains $vnetId) {
        $resourceIds += $vnetId
    }

    # NSG
    if ($nic.NetworkSecurityGroup) {
        $resourceIds += $nic.NetworkSecurityGroup.Id
    }

    # Save IP config mapping
    $NicPipMap[$nic.Name] = @{
        IpConfigName = $nic.IpConfigurations[0].Name
    }
}

# Public IP
$pips = Get-AzPublicIpAddress -ResourceGroupName $SourceResourceGroup -ErrorAction SilentlyContinue
foreach ($pip in $pips) {
    $resourceIds += $pip.Id
    $primaryNic = $NicPipMap.Keys | Select-Object -First 1
    $NicPipMap[$primaryNic]["PipName"] = $pip.Name
}

Write-Host "[INFO] Resources collected for validation:"
$resourceIds | ForEach-Object { Write-Host $_ }

# ==========================================================
# VALIDATION
# ==========================================================
Write-Host ""
Write-Host "[ACTION] Running move validation..."

if (-not (Get-Command Test-AzResourceMove -ErrorAction SilentlyContinue)) {
    Write-Host "Installing Az.Resources module..."
    Install-Module Az.Resources -Force -Scope CurrentUser -AllowClobber
    Import-Module Az.Resources -Force
}

try {
    Test-AzResourceMove `
        -ResourceId $resourceIds `
        -DestinationSubscriptionId $DestinationSubscriptionId `
        -DestinationResourceGroupName $DestinationResourceGroup

    Write-Host "[OK] VALIDATION PASSED"
}
catch {
    Write-Host ""
    Write-Host "❌ VALIDATION FAILED"
    Write-Host $_
    exit 1
}

# ==========================================================
# ENSURE DESTINATION RG EXISTS
# ==========================================================
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

# ==========================================================
# MOVE RESOURCES
# ==========================================================
Set-AzContext -SubscriptionId $SourceSubscriptionId | Out-Null

Write-Host ""
Write-Host "[ACTION] Moving resources..."

Move-AzResource `
    -ResourceId $resourceIds `
    -DestinationSubscriptionId $DestinationSubscriptionId `
    -DestinationResourceGroupName $DestinationResourceGroup `
    -Force

Write-Host "[OK] Move completed"

# ==========================================================
# SWITCH TO DESTINATION
# ==========================================================
Set-AzContext -SubscriptionId $DestinationSubscriptionId | Out-Null

# ==========================================================
# REATTACH PUBLIC IP
# ==========================================================
Write-Host "[ACTION] Reattaching Public IP..."

foreach ($nicName in $NicPipMap.Keys) {

    $pipName      = $NicPipMap[$nicName]["PipName"]
    $ipConfigName = $NicPipMap[$nicName]["IpConfigName"]

    if (-not $pipName) { continue }

    $nic = Get-AzNetworkInterface -Name $nicName -ResourceGroupName $DestinationResourceGroup
    $pip = Get-AzPublicIpAddress -Name $pipName -ResourceGroupName $DestinationResourceGroup

    Set-AzNetworkInterfaceIpConfig `
        -NetworkInterface $nic `
        -Name $ipConfigName `
        -PublicIpAddress $pip | Out-Null

    Set-AzNetworkInterface -NetworkInterface $nic | Out-Null

    Write-Host "[OK] Public IP reattached"
}

# ==========================================================
# START VM
# ==========================================================
Write-Host "[ACTION] Starting VM..."

Start-AzVM -Name $VMName -ResourceGroupName $DestinationResourceGroup | Out-Null

Write-Host ""
Write-Host "================================================="
Write-Host " MIGRATION COMPLETED SUCCESSFULLY"
Write-Host " VM moved"
Write-Host " Validation passed"
Write-Host " Public IP reattached"
Write-Host " VM running"
Write-Host "================================================="
