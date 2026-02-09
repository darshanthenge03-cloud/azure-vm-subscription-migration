. "$PSScriptRoot/config.ps1"

$ErrorActionPreference = "Stop"

Write-Host "==========================================="
Write-Host "PHASE 3: POST-MIGRATION VALIDATION"
Write-Host "==========================================="

# Switch to Destination
Write-Host "Switching to Destination Subscription..."
Set-AzContext -SubscriptionId $DestinationSubscriptionId

# Verify VM exists
$vm = Get-AzVM -Name $VMName -ResourceGroupName $DestinationResourceGroup -ErrorAction Stop

if (-not $vm) {
    throw "VM not found in destination subscription."
}

Write-Host "VM Verified in Destination."
Write-Host "Location: $($vm.Location)"
Write-Host "Resource Group: $($vm.ResourceGroupName)"

Write-Host "Post-migration validation successful."
Write-Host "==========================================="
