param(
    [Parameter(Mandatory=$true)]
    [string]$SourceSubscriptionId,

    [Parameter(Mandatory=$true)]
    [string]$VMName
)

$ErrorActionPreference = "Stop"

Write-Host "==========================================="
Write-Host "PHASE 0: EXPORT VM CONFIGURATION BACKUP"
Write-Host "==========================================="

# Switch to Source Subscription
Write-Host "Setting Azure context to Source Subscription..."
Set-AzContext -SubscriptionId $SourceSubscriptionId

# Get VM
Write-Host "Fetching VM details..."
$vm = Get-AzVM -Name $VMName -ErrorAction Stop

if (-not $vm) {
    throw "VM '$VMName' not found in subscription '$SourceSubscriptionId'."
}

Write-Host "VM Found: $($vm.Name)"
Write-Host "Resource Group: $($vm.ResourceGroupName)"
Write-Host "Location: $($vm.Location)"

# Export VM configuration
$backupFile = "backup-config-$($VMName).json"

Write-Host "Exporting VM configuration to $backupFile ..."

$vm | ConvertTo-Json -Depth 20 | Out-File $backupFile -Force

Write-Host "Backup export completed successfully."
Write-Host "File saved as: $backupFile"

Write-Host "==========================================="
Write-Host "PHASE 0 COMPLETED SUCCESSFULLY"
Write-Host "==========================================="
