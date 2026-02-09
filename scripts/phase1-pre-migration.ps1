. "$PSScriptRoot/config.ps1"

$ErrorActionPreference = "Stop"

Write-Host "==========================================="
Write-Host "PHASE 1: PRE-MIGRATION VALIDATION"
Write-Host "==========================================="

# Switch to Source Subscription
Write-Host "Switching to Source Subscription..."
Set-AzContext -SubscriptionId $SourceSubscriptionId

# Check VM exists
$vm = Get-AzVM -Name $VMName -ResourceGroupName $SourceResourceGroup -ErrorAction Stop

if (-not $vm) {
    throw "VM '$VMName' not found in Resource Group '$SourceResourceGroup'."
}

Write-Host "VM Found: $($vm.Name)"
Write-Host "Location: $($vm.Location)"

# Ensure no locks
$locks = Get-AzResourceLock -ResourceGroupName $SourceResourceGroup -ErrorAction SilentlyContinue

if ($locks) {
    Write-Host "WARNING: Resource locks detected. Migration may fail."
}

Write-Host "Pre-migration validation completed successfully."
Write-Host "==========================================="
