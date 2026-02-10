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
$vm = Get-AzVM -Name $VMName -ResourceGroupName $SourceResourceGroup

# ---------------------------------------------------
# Disable backup & remove recovery points (FINAL STATE)
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
# Stop VM
# ---------------------------------------------------
Stop-AzVM -Name $VMName -ResourceGroupName $SourceResourceGroup -Force

# ---------------------------------------------------
# Collect resources
# ---------------------------------------------------
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
# Move with FULL ERROR OUTPUT
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

Start-AzVM -Name $VMName -ResourceGroupName $DestinationResourceGroup

Write-Host "==========================================="
Write-Host "PHASE 2 COMPLETED"
Write-Host "==========================================="
