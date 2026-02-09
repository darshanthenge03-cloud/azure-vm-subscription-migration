. "$PSScriptRoot/config.ps1"

$ErrorActionPreference = "Stop"

Write-Host "========== PHASE 0: EXPORT BACKUP =========="

Set-AzContext -SubscriptionId $SourceSubscriptionId

$vm = Get-AzVM -Name $VMName -ResourceGroupName $SourceResourceGroup -ErrorAction Stop

if (-not $vm) {
    throw "VM not found."
}

# Create backup folder
$backupFolder = "$PSScriptRoot/backup"
if (-not (Test-Path $backupFolder)) {
    New-Item -ItemType Directory -Path $backupFolder | Out-Null
}

$backupFile = "$backupFolder/backup-config-$($VMName).json"

$vm | ConvertTo-Json -Depth 20 | Out-File $backupFile -Force

Write-Host "Backup saved at $backupFile"
Write-Host "========== PHASE 0 COMPLETED =========="
