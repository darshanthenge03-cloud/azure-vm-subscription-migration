$RG = "Dev-RG"
$VM = "ubuntuServer"

$vm = Get-AzVM -Name $VM -ResourceGroupName $RG
Write-Host "VM found:" $vm.Name

$nicId = $vm.NetworkProfile.NetworkInterfaces[0].Id
$nic = Get-AzNetworkInterface -ResourceId $nicId

$ipConfigName = $nic.IpConfigurations[0].Name
$pipId = $nic.IpConfigurations[0].PublicIpAddress.Id
$pipName = ($pipId -split "/")[-1]

Write-Host "Public IP detected:" $pipName

# ✅ THIS IS THE IMPORTANT PART
Set-AzNetworkInterfaceIpConfig `
    -NetworkInterface $nic `
    -Name $ipConfigName `
    -PublicIpAddress $null

Set-AzNetworkInterface -NetworkInterface $nic

Write-Host "✅ Public IP detached successfully"
