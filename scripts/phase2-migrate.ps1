. "$PSScriptRoot/config.ps1"

$ErrorActionPreference = "Stop"

Import-Module Az.Accounts
Import-Module Az.Compute
Import-Module Az.Network
Import-Module Az.Resources
Import-Module Az.RecoveryServices

Write-Host "==========================================="
Write-Host "PHASE 2: MIGRATION (PIPELINE SAFE)"
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

        $item = Get-AzRecoveryServicesBackupItem `
            -Container $container `
            -WorkloadType AzureVM `
            -ErrorAction SilentlyContinue

        if ($item) {

            Disable-AzRecoveryServicesBackupProtection `
                -Item $item `
                -RemoveRecoveryPoints `
                -Force

            Write-Host "Waiting for protection to stop..."

            do {
                Start-Sleep 15
                $item = Get-AzRecoveryServicesBackupItem `
                    -Container $container `
                    -WorkloadType AzureVM `
                    -ErrorAction SilentlyContinue
            }
            while ($item -and $item.ProtectionState -ne "ProtectionStopped")

            Write-Host "Backup protection stopped."
        }
    }
}

# ---------------------------------------------------
# REMOVE RESTORE POINT COLLECTIONS (100% PIPELINE SAFE)
# ---------------------------------------------------
Write-Host "Checking entire subscription for Restore Point Collections..."

$rpcResources = Get-AzResource `
    -ResourceType "Microsoft.Compute/restorePointCollections" `
    -ErrorAction SilentlyContinue

if (-not $rpcResources) {
    Write-Host "No Restore Point Collections found in subscription."
}
else {

    foreach ($rpcRes in $rpcResources) {

        $rpcName = $rpcRes.Name
        $rpcRG   = $rpcRes.ResourceGroupName

        Write-Host "Found Restore Point Collection: $rpcName in RG: $rpcRG"

        # Check if belongs to our VM
        $rpcFull = Get-AzResource -ResourceId $rpcRes.ResourceId

        if ($rpcFull.Properties.source.id -like "*$VMName*") {

            Write-Host "Restore Point Collection belongs to VM $VMName. Removing entire collection..."

            # Delete entire collection (auto deletes restore points)
            Remove-AzResource `
                -ResourceId $rpcRes.ResourceId `
                -Force `
                -ErrorAction Stop
        }
    }

    Write-Host "Waiting 90 seconds for Azure to release disk locks..."
    Start-Sleep -Seconds 90
}

# ---------------------------------------------------
# STOP VM
# ---------------------------------------------------
Write-Host "Stopping VM..."
Stop-AzVM -Name $VMName -ResourceGroupName $SourceResourceGroup -Force

# ---------------------------------------------------
# COLLECT RESOURCES
# ---------------------------------------------------
Write-Host "Collecting resources to move..."

$resourcesToMove = @()
$resourcesToMove += $vm.Id
$resourcesToMove += $vm.StorageProfile.OsDisk.ManagedDisk.Id

foreach ($d in $vm.StorageProfile.DataDisks) {
    $resourcesToMove += $d.ManagedDisk.Id
}

foreach ($nicRef in $vm.NetworkProfile.NetworkInterfaces) {

    $nic = Get-AzNetworkInterface -ResourceId $nicRef.Id
    $resourcesToMove += $nic.Id

    if ($nic.NetworkSecurityGroup) {
        $resourcesToMove += $nic.NetworkSecurityGroup.Id
    }

    foreach ($ip in $nic.IpConfigurations) {

        if ($ip.PublicIpAddress) {
            $pipId = $ip.PublicIpAddress.Id
            $pipName = $pipId.Split("/")[-1]
            $pipRG = $pipId.Split("/")[4]

            $pipObj = Get-AzPublicIpAddress -Name $pipName -ResourceGroupName $pipRG
            $resourcesToMove += $pipObj.Id

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

Write-Host "Resources to move:"
$resourcesToMove | ForEach-Object { Write-Host $_ }

# ---------------------------------------------------
# DESTINATION CONTEXT
# ---------------------------------------------------
Set-AzContext -SubscriptionId $DestinationSubscriptionId

if (-not (Get-AzResourceGroup -Name $DestinationResourceGroup -ErrorAction SilentlyContinue)) {
    New-AzResourceGroup -Name $DestinationResourceGroup -Location $DestinationLocation
}

# ---------------------------------------------------
# MOVE RESOURCES
# ---------------------------------------------------
Write-Host "Starting Move..."

Move-AzResource `
    -ResourceId $resourcesToMove `
    -DestinationSubscriptionId $DestinationSubscriptionId `
    -DestinationResourceGroupName $DestinationResourceGroup `
    -Force `
    -ErrorAction Stop

# ---------------------------------------------------
# START VM IN DESTINATION
# ---------------------------------------------------
Write-Host "Starting VM in destination..."
Start-AzVM -Name $VMName -ResourceGroupName $DestinationResourceGroup

Write-Host "==========================================="
Write-Host "PHASE 2 COMPLETED SUCCESSFULLY"
Write-Host "==========================================="
