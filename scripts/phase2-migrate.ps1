. "$PSScriptRoot/config.ps1"

$ErrorActionPreference = "Stop"

Import-Module Az.Accounts
Import-Module Az.Compute
Import-Module Az.Network
Import-Module Az.Resources
Import-Module Az.RecoveryServices

Write-Host "==========================================="
Write-Host "PHASE 2: MIGRATION (AZURE-CORRECT FLOW)"
Write-Host "==========================================="

# ---------------------------------------------------
# Source context
# ---------------------------------------------------
Set-AzContext -SubscriptionId $SourceSubscriptionId
$vm = Get-AzVM -Name $VMName -ResourceGroupName $SourceResourceGroup -ErrorAction Stop

# ---------------------------------------------------
# Disable Backup Protection
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
# Remove Restore Point Collections (CRITICAL FIX)
# ---------------------------------------------------
Write-Host "Checking for Restore Point Collections..."

$rpcList = Get-AzRestorePointCollection -ResourceGroupName $SourceResourceGroup -ErrorAction SilentlyContinue

if ($rpcList) {

    foreach ($rpc in $rpcList) {

        Write-Host "Found Restore Point Collection: $($rpc.Name)"
        Write-Host "Deleting Restore Points..."

        $restorePoints = Get-AzRestorePoint -RestorePointCollection $rpc -ErrorAction SilentlyContinue

        if ($restorePoints) {
            foreach ($rp in $restorePoints) {
                Write-Host "Deleting Restore Point: $($rp.Name)"
                Remove-AzRestorePoint `
                    -RestorePointCollection $rpc `
                    -Name $rp.Name `
                    -Force `
                    -ErrorAction Stop
            }
        }

        Write-Host "Deleting Restore Point Collection: $($rpc.Name)"
        Remove-AzRestorePointCollection `
            -Name $rpc.Name `
            -ResourceGroupName $SourceResourceGroup `
            -Force `
            -ErrorAction Stop
    }

    Write-Host "Waiting 60 seconds for disk references to clear..."
    Start-Sleep -Seconds 60
}
else {
    Write-Host "No Restore Point Collections found."
}

# ---------------------------------------------------
# Stop VM
# ---------------------------------------------------
Write-Host "Stopping VM..."
Stop-AzVM -Name $VMName -ResourceGroupName $SourceResourceGroup -Force

# ---------------------------------------------------
# Collect Resources
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
# Destination context
# ---------------------------------------------------
Set-AzContext -SubscriptionId $DestinationSubscriptionId

if (-not (Get-AzResourceGroup -Name $DestinationResourceGroup -ErrorAction SilentlyContinue)) {
    New-AzResourceGroup -Name $DestinationResourceGroup -Location $DestinationLocation
}

# ---------------------------------------------------
# Move Resources
# ---------------------------------------------------
Write-Host "Starting Move..."

try {
    Move-AzResource `
        -ResourceId $resourcesToMove `
        -DestinationSubscriptionId $DestinationSubscriptionId `
        -DestinationResourceGroupName $DestinationResourceGroup `
        -Force `
        -ErrorAction Stop
}
catch {
    Write-Host "=========== AZURE MOVE ERROR ==========="
    Write-Host $_.Exception.Message

    if ($_.Exception.Response) {
        $r = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
        Write-Host $r.ReadToEnd()
    }
    throw
}

# ---------------------------------------------------
# Start VM in Destination
# ---------------------------------------------------
Write-Host "Starting VM in destination subscription..."
Start-AzVM -Name $VMName -ResourceGroupName $DestinationResourceGroup

Write-Host "==========================================="
Write-Host "PHASE 2 COMPLETED SUCCESSFULLY"
Write-Host "==========================================="
