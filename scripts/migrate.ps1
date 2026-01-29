$RG = "Dev-RG"
$VM = "ubuntuserver"

$vm = Get-AzVM -Name $VM -ResourceGroupName $RG
Write-Host "VM found:" $vm.Name

$nic = Get-AzNetworkInterface -ResourceId $vm.NetworkProfile.NetworkInterfaces[0].Id
$pipId = $nic.IpConfigurations[0].PublicIpAddress.Id
$pipName = ($pipId -split "/")[-1]

$nic.IpConfigurations[0].PublicIpAddress = $null
Set-AzNetworkInterface $nic
