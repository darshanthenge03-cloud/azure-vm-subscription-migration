. "$PSScriptRoot/config.ps1"

$ErrorActionPreference = "Stop"

Import-Module Az.Accounts
Import-Module Az.Compute
Import-Module Az.Network
Import-Module Az.Resources
Import-Module Az.RecoveryServices

Write-Host "==========================================="
Write-Host "PHASE 2: MIGRATION (WITH PIP MOVE)"
Write-Host "==========================================="

# ---------------------------------------------------
# SOURCE CONTEXT
# ---------------------------------------------------
Set-AzContext -SubscriptionId $SourceSubscriptionId
$vm = Get-AzVM -Name $VMName -ResourceGroupName $SourceResourceGroup -ErrorAction Stop

# ---------------------------------------------------
# DISABLE BACKUP
# ---------------------------------------------------
Write-Host "Disabling backup protection..."

$vault = Get-AzRecoveryServicesVault -Name $VaultName -ErrorAction SilentlyContinue

if ($vault) {
    Set-AzRecoveryServicesVaultContext -Vault $vault

    $container = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVM |
        Where-Object { $_.FriendlyName -eq $VMName }

    if ($container) {
        $item = Get-AzRecoveryServicesBackupItem -Container $container -WorkloadType AzureVM -ErrorAction SilentlyContinue

        if ($item) {
            Disable-AzRecoveryServicesBackupProtection -Item $item -RemoveRecoveryPoints -Force

            do {
                Start-Sleep 15
                $item = Get-AzRecoveryServicesBackupItem -Container $container -WorkloadType AzureVM -ErrorAction SilentlyContinue
            }
            while ($item -and $item.ProtectionState -ne "ProtectionStopped")
        }
    }
}

# ---------------------------------------------------
# REMOVE RESTORE POINT COLLECTIONS (SUBSCRIPTION WIDE)
# ---------------------------------------------------
Write-Host "Checking subscription for Restore Point Collections..."

$rpcResources = Get-AzResource -ResourceType "Microsoft.Compute/restorePointCollections" -ErrorAction SilentlyContinue

foreach ($rpcRes in $rpcResources) {

    if ($rpcRes.Properties.source.id -like "*$VMName*") {

        Write-Host "Removing Restore Point Collection: $($rpcRes.Name)"
        Remove-AzResource -ResourceId $rpcRes.ResourceId -Force -ErrorAction Stop
    }
}

Start-Sleep -Seconds 90

# ---------------------------------------------------
# STOP VM
# ---------------------------------------------------
Write-Host "Stopping VM..."
Stop-AzVM -Name $VMName -ResourceGroupName $SourceResourceGroup -Force

# ---------------------------------------------------
# COLLECT RESOURCES
# ---------------------------------------------------
$resourcesToMove = @()
$resourcesToMove += $vm.Id
$resourcesToMove += $vm.StorageProfile.OsDisk.ManagedDisk.Id

foreach ($d in $vm.StorageProfile.DataDisks) {
    $resourcesToMove += $d.ManagedDisk.Id
}

$publicIpToMove = $null
$nicList = @()

foreach ($nicRef in $vm.NetworkProfile.NetworkInterfaces) {

    $nic = Get-AzNetworkInterface -ResourceId $nicRef.Id
    $nicList += $nic
    $resourcesToMove += $nic.Id

    if ($nic.NetworkSecurityGroup) {
        $resourcesToMove += $nic.NetworkSecurityGroup.Id
    }

    foreach ($ip in $nic.IpConfigurations) {

        if ($ip.PublicIpAddress) {

            $pipId = $ip.PublicIpAddress.Id
            $pipName = $pipId.Split("/")[-1]
            $pipRG = $pipId.Split("/")[4]

            $publicIpToMove = Get-AzPublicIpAddress -Name $pipName -ResourceGroupName $pipRG

            Write-Host "Detaching Public IP: $pipName"
            $ip.PublicIpAddress = $null
            Set-AzNetworkInterface $nic
        }

        $subnetId = $ip.Subnet.Id
        $vnetName = $subnetId.Split("/")[8]
        $vnetRG = $subnetId.Split("/")[4]

        $vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $vnetRG
        $resourcesToMove += $vnet.Id
    }
}

$resourcesToMove = $resourcesToMove | Select-Object -Unique

# ---------------------------------------------------
# DESTINATION CONTEXT
# ---------------------------------------------------
Set-AzContext -SubscriptionId $DestinationSubscriptionId

if (-not (Get-AzResourceGroup -Name $DestinationResourceGroup -ErrorAction SilentlyContinue)) {
    New-AzResourceGroup -Name $DestinationResourceGroup -Location $DestinationLocation
}

# ---------------------------------------------------
# MOVE MAIN RESOURCES
# ---------------------------------------------------
Write-Host "Moving VM and dependencies..."
Move-AzResource `
    -ResourceId $resourcesToMove `
    -DestinationSubscriptionId $DestinationSubscriptionId `
    -DestinationResourceGroupName $DestinationResourceGroup `
    -Force `
    -ErrorAction Stop

# ---------------------------------------------------
# MOVE PUBLIC IP (IF STANDARD SKU)
# ---------------------------------------------------
if ($publicIpToMove) {

    Write-Host "Processing Public IP: $($publicIpToMove.Name)"

    if ($publicIpToMove.Sku.Name -eq "Standard") {

        Set-AzContext -SubscriptionId $SourceSubscriptionId

        Move-AzResource `
            -ResourceId $publicIpToMove.Id `
            -DestinationSubscriptionId $DestinationSubscriptionId `
            -DestinationResourceGroupName $DestinationResourceGroup `
            -Force `
            -ErrorAction Stop

        Write-Host "Public IP moved successfully."

        # Reattach
        Set-AzContext -SubscriptionId $DestinationSubscriptionId

        $nic = Get-AzNetworkInterface -Name $nicList[0].Name -ResourceGroupName $DestinationResourceGroup
        $pip = Get-AzPublicIpAddress -Name $publicIpToMove.Name -ResourceGroupName $DestinationResourceGroup

        $nic.IpConfigurations[0].PublicIpAddress = $pip
        Set-AzNetworkInterface $nic

        Write-Host "Public IP reattached."
    }
    else {
        Write-Host "Public IP SKU is Basic. Cross-subscription move not supported."
    }
}

# ---------------------------------------------------
# START VM
# ---------------------------------------------------
Write-Host "Starting VM in destination..."
Start-AzVM -Name $VMName -ResourceGroupName $DestinationResourceGroup

Write-Host "==========================================="
Write-Host "PHASE 2 COMPLETED SUCCESSFULLY"
Write-Host "==========================================="
