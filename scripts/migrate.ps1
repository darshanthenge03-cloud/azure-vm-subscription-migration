$RG = "Dev-RG"
$VM = "ubuntuserver"

$vm = Get-AzVM -Name $VM -ResourceGroupName $RG
Write-Host "VM found:" $vm.Name
