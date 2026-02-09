. "$PSScriptRoot/config.ps1"

$ErrorActionPreference = "Stop"

Write-Host "========== PHASE 0 =========="

Set-AzContext -SubscriptionId $SourceSubscriptionId

$vm = Get-AzVM -Name $VMName -ResourceGroupName $SourceResourceGroup -ErrorAction Stop

$backupFile = "backup-config-$($VMName).json"

$vm | ConvertTo-Json -Depth 20 | Out-File $backupFile -Force

Write-Host "Backup export completed."
