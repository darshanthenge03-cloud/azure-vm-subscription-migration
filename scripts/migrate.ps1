# ================================
# USER INPUT
# ================================
$ResourceGroupName = "Dev-RG"
$VMName            = "ubuntuServer"

# ================================
Write-Host "======================================="
Write-Host " Azure VM Subscription Migration Script "
Write-Host "======================================="

# ================================
# VERIFY CONTEXT
# ================================
$context = Get-AzContext

if (-not $context.Subscription) {
    throw "Azure subscription context not found."
}

Write-Host "Using subscription:" $context.Subscription.Name

# ================================
# GET VM
# ================================
$vm = Get-AzVM -Name $VMName -ResourceGroupName $ResourceGroupName
Write-Host "VM found:" $vm.Name

# ================================
# STOP VM (required)
# ================================
Write-Host "Stopping VM..."
Stop-AzVM -Name $VMName -ResourceGroupName $ResourceGroupName -Force

do {
    Start-Sleep -Seconds 10
    $state = (Get-AzVM -Name $VMName -ResourceGroupName $ResourceGroupName -Status).Statuses |
        Where-Object Code -like "PowerState/*"
    Write-Host "VM state:" $state.DisplayStatus
}
while ($state.DisplayStatus -ne "VM deallocated")

Write-Host "VM deallocated successfully."

# ================================
# GET NIC + PUBLIC IP
# ================================
$nicId = $vm.NetworkProfile.NetworkInterfaces[0].Id
$nic   = Get-AzNetworkInterface -ResourceId $nicId

$ipConfigName = $nic.IpConfigurations[0].Name
$pip = $nic.IpConfigurations[0].PublicIpAddress

if (-not $pip) {
    Write-Host "No Public IP attached. Skipping detach."
    exit 0
}

$pipId   = $pip.Id
$pipName = ($pipId -split "/")[-1]

Write-Host "Public IP detected:" $pipName

# ================================
# DETACH PUBLIC IP
# ================================
Write-Host "Detaching public IP..."

Set-AzNetworkInterfaceIpConfig `
    -NetworkInterface $nic `
    -Name $ipConfigName `
    -PublicIpAddress $null

Set-AzNetworkInterface -NetworkInterface $nic

# ================================
# VERIFY
# ================================
$nicCheck = Get-AzNetworkInterface -ResourceId $nicId

if ($null -eq $nicCheck.IpConfigurations[0].PublicIpAddress) {
    Write-Host "✅ Public IP detached successfully."
}
else {
    throw "❌ Public IP detach failed."
}

Write-Host "======================================="
Write-Host " STEP 1 COMPLETED SUCCESSFULLY "
Write-Host "======================================="
