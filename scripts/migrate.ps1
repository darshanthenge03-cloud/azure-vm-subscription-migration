$RG = "rg-prod"
$VM = "prod-vm01"

$vm = Get-AzVM -Name $VM -ResourceGroupName $RG
Write-Host "VM found:" $vm.Name
