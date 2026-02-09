. "$PSScriptRoot/config.ps1"

$ErrorActionPreference = "Stop"

Import-Module Az.Accounts -Force
Import-Module Az.Compute -Force
Import-Module Az.Resources -Force

Write-Host "==========================================="
Write-Host "PHASE 1: PRE-MIGRATION VALIDATION"
Write-Host "==========================================="

# ---------------------------------------------------
# Validate Config Variables
# ---------------------------------------------------

if (-not $SourceSubscriptionId -or -not $DestinationSubscriptionId -or `
    -not $SourceResourceGroup -or -not $DestinationResourceGroup -or `
    -not $VMName) {

    throw "One or more required configuration values are missing in config.ps1"
}

# ---------------------------------------------------
# Switch to Source Subscription
# ---------------------------------------------------

Write-Host "Switching to Source Subscription..."
Set-AzContext -SubscriptionId $SourceSubscriptionId

$currentContext = Get-AzContext
Write-Host "Current Subscription: $($currentContext.Subscription.Id)"

# ---------------------------------------------------
# Validate VM Exists
# ---------------------------------------------------

Write-Host "Checking if VM exists..."

$vm = Get-AzVM -Name $VMName -ResourceGroupName $SourceResourceGroup -ErrorAction Stop

if (-not $vm) {
    throw "VM '$VMName' not found in Resource Group '$SourceResourceGroup'."
}

Write-Host "VM Found: $($vm.Name)"
Write-Host "Location: $($vm.Location)"
Write-Host "VM Size: $($vm.HardwareProfile.VmSize)"

# ---------------------------------------------------
# Validate Same Region Constraint
# ---------------------------------------------------

if ($vm.Location -ne $DestinationLocation) {
    Write-Host "WARNING: Source VM region ($($vm.Location)) differs from destination region ($DestinationLocation)."
    Write-Host "Cross-region Move-AzResource is NOT supported."
}

# ---------------------------------------------------
# Check Resource Locks
# ---------------------------------------------------

Write-Host "Checking for resource locks..."

$locks = Get-AzResourceLock -ResourceGroupName $SourceResourceGroup -ErrorAction SilentlyContinue

if ($locks) {
    Write-Host "WARNING: Resource locks detected in source resource group."
    $locks | ForEach-Object {
        Write-Host " - Lock Name: $($_.Name) | Level: $($_.Level)"
    }
}
else {
    Write-Host "No resource locks found."
}

# ---------------------------------------------------
# Validate RBAC on Destination Subscription
# ---------------------------------------------------

Write-Host "Validating access to Destination Subscription..."

Set-AzContext -SubscriptionId $DestinationSubscriptionId

try {
    $null = Get-AzSubscription -SubscriptionId $DestinationSubscriptionId -ErrorAction Stop
    Write-Host "Access to Destination Subscription confirmed."
}
catch {
    throw "Service Principal does NOT have access to Destination Subscription."
}

# Switch back to Source
Set-AzContext -SubscriptionId $SourceSubscriptionId

Write-Host "Pre-migration validation completed successfully."
Write-Host "==========================================="
