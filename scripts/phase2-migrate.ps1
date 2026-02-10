. "$PSScriptRoot/config.ps1"

$ErrorActionPreference = "Stop"

Import-Module Az.Accounts -Force
Import-Module Az.Compute -Force
Import-Module Az.Network -Force
Import-Module Az.Resources -Force
Import-Module Az.RecoveryServices -Force

Write-Host "==========================================="
Write-Host "PHASE 2: FINAL MIGRATION WITH CLEAN BACKUP DETACH"
Write-Host "==========================================="

# ---------------------------------------------------
# Switch to Source Subscription
# ---------------------------------------------------
Set-AzContext -SubscriptionId $SourceSubscriptionId

$vm = Get-AzVM -Name $VMName -ResourceGroupName $SourceResourceGroup -ErrorAction Stop

# ---------------------------------------------------
# STEP 1 - Disable Backup + Remove Recovery Points
# ---------------------------------------------------
Write-Host "Checking Recovery Vault..."

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

            Write-Host "Disabling backup and removing recovery points..."

            $job = Disable-AzRecoveryServicesBackupProtection `
                -Item $item `
                -RemoveRecoveryPoints `
                -Force

            # ---------------------------------------------------
            # WAIT FOR DELETE JOB TO COMPLETE
            # ---------------------------------------------------
            Write-Host "Waiting for delete job to complete..."

            do {
                Start-Sleep -Seconds 15
                $jobStatus = Get-AzRecoveryServicesBackupJob -JobId $job.JobId
                Write-Host "Job Status: $($jobStatus.Status)"
            }
            while ($jobStatus.Status -eq "InProgress")

            if ($jobStatus.Status -ne "Completed") {
                throw "Backup delete job failed."
            }

            Write-Host "Backup delete job completed."

            # ---------------------------------------------------
            # UNREGISTER BACKUP CONTAINER (CRITICAL)
            # ---------------------------------------------------
            Write-Host "Unregistering backup container..."

            Unregister-AzRecoveryServicesBackupContainer `
                -Container $container `
                -Force

            Start-Sleep -Seconds 20

            # Verify container removal
            $checkContainer = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVM |
                Where-Object { $_.FriendlyName -eq $VMName }

            if ($checkContainer) {
                throw "Backup container still registered. Cannot proceed."
            }

            Write-Host "Backup container successfully removed."
        }
    }
}

# ---------------------------------------------------
# STEP 2 - Stop VM
# ---------------------------------------------------
Write-Host "Stopping VM..."
Stop-AzVM -Name $VMName -ResourceGroupName $SourceResourceGroup -Force

# ---------------------------------------------------
# STEP 3 - Collect Resources (NO VAULT INCLUDED)
# ---------------------------------------------------
$resourcesToMove = @()

$resourcesToMove += $vm.Id
$resourcesToMove += $vm.StorageProfile.OsDisk.ManagedDisk.Id

foreach ($disk in $vm.StorageProfile.DataDisks) {
    if ($disk.ManagedDisk) {
        $resourcesToMove += $disk.ManagedDisk.Id
    }
}

foreach ($nicRef in $vm.NetworkProfile.NetworkInterfaces) {

    $nic = Get-AzNetworkInterface -ResourceId $nicRef.Id
    $resourcesToMove += $nic.Id

    if ($nic.NetworkSecurityGroup) {
        $resourcesToMove += $nic.NetworkSecurityGroup.Id
    }

    foreach ($ipconfig in $nic.IpConfigurations) {

        if ($ipconfig.PublicIpAddress) {
            $pipId = $ipconfig.PublicIpAddress.Id
            $pipName = $pipId.Split("/")[-1]
            $pipRG = $pipId.Split("/")[4]

            $pip = Get-AzPublicIpAddress -Name $pipName -ResourceGroupName $pipRG
            $resourcesToMove += $pip.Id

            $ipconfig.PublicIpAddress = $null
            Set-AzNetworkInterface -NetworkInterface $nic
        }

        $subnetId = $ipconfig.Subnet.Id
        $vnetName = $subnetId.Split("/")[8]
        $vnetRG = $subnetId.Split("/")[4]

        $vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $vnetRG
        $resourcesToMove += $vnet.Id
    }
}

$resourcesToMove = $resourcesToMove | Select-Object -Unique

Write-Host "Resources to Move:"
$resourcesToMove | ForEach-Object { Write-Host $_ }

# ---------------------------------------------------
# STEP 4 - Switch to Destination
# ---------------------------------------------------
Set-AzContext -SubscriptionId $DestinationSubscriptionId

if (-not (Get-AzResourceGroup -Name $DestinationResourceGroup -ErrorAction SilentlyContinue)) {
    New-AzResourceGroup -Name $DestinationResourceGroup -Location $DestinationLocation
}

# ---------------------------------------------------
# STEP 5 - Move With Full Error Output
# ---------------------------------------------------
Write-Host "Starting Resource Move..."

try {

    Move-AzResource `
        -ResourceId $resourcesToMove `
        -DestinationSubscriptionId $DestinationSubscriptionId `
        -DestinationResourceGroupName $DestinationResourceGroup `
        -Force `
        -ErrorAction Stop

    Write-Host "Move Completed Successfully."

}
catch {

    Write-Host "========== FULL AZURE ERROR =========="

    Write-Host $_.Exception.Message

    if ($_.Exception.Response) {
        $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
        $responseBody = $reader.ReadToEnd()
        Write-Host $responseBody
    }

    throw
}

# ---------------------------------------------------
# STEP 6 - Start VM
# ---------------------------------------------------
Start-AzVM -Name $VMName -ResourceGroupName $DestinationResourceGroup

Write-Host "==========================================="
Write-Host "MIGRATION COMPLETED SUCCESSFULLY"
Write-Host "==========================================="
