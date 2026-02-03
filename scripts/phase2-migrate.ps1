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

Write-Host "==============================================="
Write-Host " AZURE VM SUBSCRIPTION MIGRATION (PHASE 2)"
Write-Host "==============================================="

# ==========================================
# 1️⃣ SET SOURCE CONTEXT
# ==========================================
Set-AzContext -SubscriptionId $SourceSubscriptionId | Out-Null
Write-Host "[OK] Source subscription set"

$vm = Get-AzVM -Name $VMName -ResourceGroupName $SourceResourceGroup
Write-Host "[OK] VM found"

$resourceIds = @()

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

    # NSG on NIC
    if ($nic.NetworkSecurityGroup) {
        $resourceIds += $nic.NetworkSecurityGroup.Id
    }
}

# Public IPs
$pips = Get-AzPublicIpAddress -ResourceGroupName $SourceResourceGroup -ErrorAction SilentlyContinue
foreach ($pip in $pips) {
    $resourceIds += $pip.Id
}

Write-Host ""
Write-Host "[INFO] Resources collected for validation:"
$resourceIds | ForEach-Object { Write-Host $_ }

# ==========================================
# 2️⃣ VALIDATION STEP (CRITICAL)
# ==========================================
Write-Host ""
Write-Host "[ACTION] Running move validation..."

try {

    Test-AzResourceMove `
        -ResourceId $resourceIds `
        -DestinationSubscriptionId $DestinationSubscriptionId `
        -DestinationResourceGroupName $DestinationResourceGroup

    Write-Host "[SUCCESS] Validation PASSED"

}
catch {

    Write-Host ""
    Write-Host "❌ VALIDATION FAILED"
    Write-Host "-------------------------------------"
    Write-Host $_.Exception.Message
    Write-Host "-------------------------------------"
    Write-Host ""
    Write-Host "Fix the above dependency and re-run."
    exit 1
}

# ==========================================
# 3️⃣ CREATE DESTINATION RG
# ==========================================
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

# ==========================================
# 4️⃣ MOVE RESOURCES
# ==========================================
Set-AzContext -SubscriptionId $SourceSubscriptionId | Out-Null

Write-Host ""
Write-Host "[ACTION] Moving resources..."

Move-AzResource `
  -ResourceId $resourceIds `
  -DestinationSubscriptionId $DestinationSubscriptionId `
  -DestinationResourceGroupName $DestinationResourceGroup `
  -Force

Write-Host "[SUCCESS] Move completed"

Write-Host "==============================================="
Write-Host " MIGRATION FINISHED SUCCESSFULLY"
Write-Host "==============================================="
