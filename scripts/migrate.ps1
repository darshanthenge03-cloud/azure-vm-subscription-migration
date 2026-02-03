$ErrorActionPreference = "Stop"

# ================================
# INPUT
# ================================
$SubscriptionId = "46689057-be43-4229-9241-e0591dad4dbf"
$ResourceGroup  = "Dev-RG"
$VMName         = "ubuntuServer"

# ================================
Write-Host "======================================="
Write-Host " PHASE 1: VM STOP | IP DETACH | BACKUP CLEANUP "
Write-Host "======================================="

# ================================
# CONTEXT
# ================================
Set-AzContext -SubscriptionId $SubscriptionId
Write-Host "Subscription context set."

# ================================
# GET VM
# ================================
$vm = Get-AzVM -Name $VMName -ResourceGroupName $ResourceGroup
Write-Host "VM found:" $vm.Name

# ================================
# STOP & DEALLOCATE VM
# ================================
Write-Host "Stopping VM..."
Stop-AzVM -Name $VMName -ResourceGroupName $ResourceGroup -Force

do {
    Start-Sleep 10
    $state = (Get-AzVM -Name $VMName -ResourceGroupName $ResourceGroup -Status).Statuses |
        Where-Object Code -like "PowerState/*"
    Write-Host "VM state:" $state.DisplayStatus
}
while ($state.DisplayStatus -ne "VM deallocated")

Write-Host "VM deallocated."

# ================================
# DISASSOCIATE PUBLIC IP
# ================================
Write-Host "Checking NICs for Public IP..."

foreach ($nicRef in $vm.NetworkProfile.NetworkInterfaces) {

    $nic = Get-AzNetworkInterface -ResourceId $nicRef.Id

    foreach ($ipConfig in $nic.IpConfigurations) {

        if ($ipConfig.PublicIpAddress) {

            $pipName = ($ipConfig.PublicIpAddress.Id -split "/")[-1]
            Write-Host "Detaching Public IP:" $pipName

            Set-AzNetworkInterfaceIpConfig `
                -NetworkInterface $nic `
                -Name $ipConfig.Name `
                -PublicIpAddress $null

            Set-AzNetworkInterface -NetworkInterface $nic

            Write-Host "Public IP detached."
        }
    }
}

# ================================
# BACKUP CLEANUP (ROBUST + SAFE)
# ================================
Write-Host "Searching Recovery Services Vaults..."

$vaults = Get-AzRecoveryServicesVault -ErrorAction SilentlyContinue
$backupFound = $false

foreach ($vault in $vaults) {

    Write-Host "Checking vault:" $vault.Name
    Set-AzRecoveryServicesVaultContext -Vault $vault

    $containers = Get-AzRecoveryServicesBackupContainer `
        -ContainerType AzureVM `
        -ErrorAction SilentlyContinue

    foreach ($container in $containers) {

        if ($container.FriendlyName -ne $VMName) {
            continue
        }

        Write-Host "Backup FOUND in vault:" $vault.Name
        $backupFound = $true

        $backupItem = Get-AzRecoveryServicesBackupItem `
            -Container $container `
            -WorkloadType AzureVM `
            -ErrorAction Stop

        Write-Host "Disabling backup protection..."

        Disable-AzRecoveryServicesBackupProtection `
            -Item $backupItem `
            -RemoveRecoveryPoints `
            -Force

        Write-Host "Backup protection disabled."

        # ================================
        # SOFT DELETE (BEST EFFORT)
        # ================================
        Write-Host "Attempting to disable Soft Delete..."

        try {
            Set-AzRecoveryServicesVaultProperty `
                -VaultId $vault.Id `
                -SoftDeleteFeatureState Disable

            Write-Host "Soft Delete disabled."
        }
        catch {
            Write-Warning "Soft Delete could not be disabled now."
            Write-Warning "This is expected immediately after backup deletion."
            Write-Warning "You can disable it later or via a separate script."
        }

        break
    }

    if ($backupFound) { break }
}

if (-not $backupFound) {
    Write-Host "No Azure Backup found for this VM."
}

Write-Host "======================================="
Write-Host " PHASE 1 COMPLETED SUCCESSFULLY "
Write-Host " VM STOPPED | IP DETACHED | BACKUP REMOVED "
Write-Host "======================================="

exit 0
