$RG = "Dev-RG"
$VM = "ubuntuServer"

Write-Host "=============================="
Write-Host "Starting VM migration process"
Write-Host "=============================="

$vm = Get-AzVM -Name $VM -ResourceGroupName $RG
Write-Host "VM found: $($vm.Name)"

# -----------------------------
# STOP VM (VERY IMPORTANT)
# -----------------------------
Write-Host "Stopping VM..."
Stop-AzVM -Name $VM -ResourceGroupName $RG -Force -NoWait

Write-Host "Waiting for VM deallocation..."

do {
    Start-Sleep -Seconds 10
    $status = (Get-AzVM -Name $VM -ResourceGroupName $RG -Status).Statuses |
              Where-Object Code -like "PowerState/*"
    Write-Host "Current VM state:" $status.DisplayStatus
}
while ($status.DisplayStatus -ne "VM deallocated")

Write-Host "VM deallocated successfully"

# -----------------------------
# GET NIC & PUBLIC IP
# -----------------------------
$nicId = $vm.NetworkProfile.NetworkInterfaces[0].Id
$nic = Get-AzNetworkInterface -ResourceId $nicId

$ipConfigName = $nic.IpConfigurations[0].Name
$pipId = $nic.IpConfigurations[0].PublicIpAddress.Id
$pipName = ($pipId -split "/")[-1]

Write-Host "Public IP detected: $pipName"

# -----------------------------
# DETACH PUBLIC IP
# -----------------------------
Write-Host "Detaching public IP..."

Set-AzNetworkInterfaceIpConfig `
    -NetworkInterface $nic `
    -Name $ipConfigName `
    -PublicIpAddress $null

Set-AzNetworkInterface -NetworkInterface $nic

Write-Host "✅ Public IP detached"

# -----------------------------
# VERIFY DETACH
# -----------------------------
$nicVerify = Get-AzNetworkInterface -ResourceId $nicId

if ($null -eq $nicVerify.IpConfigurations[0].PublicIpAddress) {
    Write-Host "✅ Verification passed: PIP is detached"
}
else {
    throw "❌ Public IP is still attached"
}
