$RG = "rg-prod"
$VM = "prod-vm01"

Write-Host "Starting migration for $VM"

Get-AzVM -Name $VM -ResourceGroupName $RG
