. "$PSScriptRoot/config.ps1"

$ErrorActionPreference = "Stop"

Import-Module Az.Accounts -Force
Import-Module Az.Compute -Force
Import-Module Az.Network -Force
Import-Module Az.Resources -Force
Import-Module Az.RecoveryServices -Force

Write-Host "==========================================="
Write-Host "PHASE 2: FULL STACK MIGRATION"
Write-Host "==========================================="

# ---------------------------------------------------
# Switch to SOURCE subscription
# ---------------------------------------------------
Set-AzContext -SubscriptionId $SourceSubscriptionId

$vm = Get-AzVM -Name $VMName -ResourceGroupName $SourceResourceGroup -ErrorAction Stop

# ---------------------------------------------------
# STEP 1: Disable Backup & REMOVE Recovery Points
# ---------------------------------------------------
Write-Host "Checking backup protection..."

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

            Write-Host "Disabling backup protection and removing recovery points..."

            Disable-AzRecoveryServicesBackupProtection `
                -Item $item `
                -RemoveRecoveryPoints `
                -Force

            # ---------------------------------------------------
            # WAIT LOGIC (CORRECT & AZURE-SAFE)
            # ---------------------------------------------------
            Write-Host "Waiting for backup protection removal..."

            $maxAttempts = 20
            $attempt = 0
            $protectionStopped = $false

            do {
                Start-Sleep -Seconds 15
                $attempt++

                $containerCheck = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVM |
                    Where-Object { $_.FriendlyName -eq $VMName }

                if ($containerCheck) {

                    $itemCheck = Get-AzRecoveryServicesBackupItem `
                        -Container $containerCheck `
                        -WorkloadType AzureVM `
                        -ErrorAction SilentlyContinue

                    if (-not $itemCheck) {
                        $protectionStopped = $true
                        break
                    }

                    if ($itemCheck.ProtectionState -eq "ProtectionStopped") {
                        $protectionStopped = $true
                        break
                    }
                }
                else {
                    $protectionStopped = $true
                    break
                }

                Write-Host "Checking protection state... Attempt $attempt"

            } while ($attempt -lt $maxAttempts)

            if (-not $protectionStopped) {
                throw "Backup protection removal timed out. Aborting migration."
            }

            Write-Host "Backup protection successfully removed."
        }
    }
}

# ---------------------------------------------------
# STEP 2: Stop VM
# ---------------------------------------------------
Write-Host "Stopping VM..."
Stop-AzVM -Name $VMName -ResourceGroupName $SourceResourceGroup -Force

# ---------------------------------------------------
# STEP 3: Collect Resources to Move
# ---------------------------------------------------
$resourcesToMove = @()
$publicIpObject = $null

# VM
$resourcesToMove += $vm.Id

# OS Disk
$resourcesToMove += $vm.StorageProfile.OsDisk.ManagedDisk.Id

# Data Disks
foreach ($disk in $vm.StorageProfile.DataDisks) {
    if ($disk.ManagedDisk) {
        $resourcesToMove += $disk.ManagedDisk.Id
    }
}

# Networking
foreach ($nicRef in $vm.NetworkProfile.NetworkInterfaces) {

    $nic = Get-AzNetworkInterface -ResourceId $nicRef.Id
    $resourcesToMove += $nic.Id

    foreach ($ipconfig in $nic.IpConfigurations) {

        # -------- Public IP --------
        if ($ipconfig.PublicIpAddress) {

            $pipId   = $ipconfig.PublicIpAddress.Id
            $pipName = $pipId.Split("/")[-1]
            $pipRG   = $pipId.Split("/")[4]

            $publicIpObject = Get-AzPublicIpAddress `
                -Name $pipName `
                -ResourceGroupName $pipRG

            $resourcesToMove += $publicIpObject.Id

            Write-Host "Disassociating Public IP..."
            $ipconfig.PublicIpAddress = $null
            Set-AzNetworkInterface -NetworkInterface $nic
        }

        # -------- VNet / Subnet --------
        $subnetId = $ipconfig.Subnet.Id
        $vnetName = $subnetId.Split("/")[8]
        $vnetRG   = $subnetId.Split("/")[4]

        $vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $vnetRG
        $resourcesToMove += $vnet.Id

        $subnetName = $subnetId.Split("/")[-1]
        $subnet = $vnet.Subnets | Where-Object { $_.Name -eq $subnetName }

        if ($subnet.RouteTable) {
            $resourcesToMove += $subnet.RouteTable.Id
        }
    }

    # NIC NSG
    if ($nic.NetworkSecurityGroup) {
        $resourcesToMove += $nic.NetworkSecurityGroup.Id
    }
}

$resourcesToMove = $resourcesToMove | Select-Object -Unique

Write-Host "Resources to Move:"
$resourcesToMove | ForEach-Object { Write-Host $_ }

# ---------------------------------------------------
# STEP 4: Switch to DESTINATION subscription
# ---------------------------------------------------
Set-AzContext -SubscriptionId $DestinationSubscriptionId

if (-not (Get-AzResourceGroup -Name $DestinationResourceGroup -ErrorAction SilentlyContinue)) {
    Write-Host "Creating destination resource group..."
    New-AzResourceGroup `
        -Name $DestinationResourceGroup `
        -Location $DestinationLocation
}

# ---------------------------------------------------
# STEP 5: Move Resources
# ---------------------------------------------------
Write-Host "Starting resource move..."

Move-AzResource `
    -ResourceId $resourcesToMove `
    -DestinationSubscriptionId $DestinationSubscriptionId `
    -DestinationResourceGroupName $DestinationResourceGroup `
    -Force `
    -ErrorAction Stop

Write-Host "Move completed successfully."

# ---------------------------------------------------
# STEP 6: Reattach Public IP
# ---------------------------------------------------
if ($publicIpObject) {

    Write-Host "Reattaching Public IP..."

    $nicName = $vm.NetworkProfile.NetworkInterfaces[0].Id.Split("/")[-1]

    $nic = Get-AzNetworkInterface `
        -Name $nicName `
        -ResourceGroupName $DestinationResourceGroup

    $pip = Get-AzPublicIpAddress `
        -Name $publicIpObject.Name `
        -ResourceGroupName $DestinationResourceGroup

    $nic.IpConfigurations[0].PublicIpAddress = $pip
    Set-AzNetworkInterface -NetworkInterface $nic
}

# ---------------------------------------------------
# STEP 7: Start VM
# ---------------------------------------------------
Write-Host "Starting VM..."
Start-AzVM -Name $VMName -ResourceGroupName $DestinationResourceGroup

Write-Host "==========================================="
Write-Host "PHASE 2 COMPLETED SUCCESSFULLY"
Write-Host "==========================================="
