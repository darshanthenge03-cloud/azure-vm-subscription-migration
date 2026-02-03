$ErrorActionPreference = "Stop"

# ================================
# USER INPUT
# ================================
$SubscriptionId = "46689057-be43-4229-9241-e0591dad4dbf"
$ResourceGroup  = "Dev-RG"
$VMName         = "ubuntuServer"

# ================================
Write-Host "================================================="
Write-Host " AZURE VM PRE-MIGRATION CLEANUP SCRIPT (PHASE 1)"
Write-Host "================================================="

# ================================
# SET CONTEXT
# ================================
Write-Host "[INFO] Setting Azure subscription context..."
Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
Write-Host "[OK] Subscription context set"

# ================================
# GET VM
# ================================
Write-Host "[INFO] Fetching VM details..."
$vm = Get-AzVM -Name $VMName -ResourceGroupName $ResourceGroup
Write-Host "[OK] VM found:" $vm.Name

# ================================
# STOP & DEALLOCATE VM
# ================================
Write-Host "[INFO] Stopping VM..."
Stop-AzVM -Name $VMName -ResourceGroupName $ResourceGroup -Force | Out-Null

do {
    Start-Sleep 10
    $state = (Get-AzVM -Name $VMName -ResourceGroupName $ResourceGroup -Status).Statuses |
        Where-Object Code -like "PowerState/*"
    Write-Host "[WAIT] VM state:" $state.DisplayStatus
}
while ($state.DisplayStatus -ne "VM deallocated")

Write-Host "[OK] VM successfully deallocated"

# ================================
# DETACH PUBLIC IP
# ================================
Write-Host "[INFO] Checking NICs for Public IP association..."

foreach ($nicRef in $vm.NetworkProfile.NetworkInterfaces) {

    $nic = Get-AzNetworkInterface -ResourceId $nicRef.Id

    foreach ($ipConfig in $nic.IpConfigurations) {

        if ($ipConfig.PublicIpAddress) {

            $pipName = ($ipConfig.PublicIpAddress.Id -split "/")[-1]
            Write-Host "[ACTION] Detaching Public IP:" $pipName

            Set-AzNetworkInterfaceIpConfig `
                -NetworkInterface $nic `
                -Name $ipConfig.Name `
                -PublicIpAddress $null | Out-Null

            Set-AzNetworkInterface -NetworkInterface $nic | Out-Null

            Write-Host "[OK] Public IP detached"
        }
    }
}

# ================================
# AZURE BACKUP CLEANUP (REAL BLOCKER)
# ================================
Write-Host "[INFO] Searching for Azure Backup protection..."

$vaults = Get-AzRecoveryServicesVault -ErrorAction SilentlyContinue
$backupFound = $false

foreach ($vault in $vaults) {

    Write-Host "[INFO] Checking vault:" $vault.Name
    Set-AzRecoveryServicesVaultContext -Vault $vault

    $containers = Get-AzRecoveryServicesBackupContainer `
        -ContainerType AzureVM `
        -ErrorAction SilentlyContinue

    foreach ($container in $containers) {

        if ($container.FriendlyName -ne $VMName) { continue }

        Write-Host "[FOUND] Backup found in vault:" $vault.Name
        $backupFound = $true

        $backupItem = Get-AzRecoveryServicesBackupItem `
            -Container $container `
            -WorkloadType AzureVM `
            -ErrorAction Stop

        Write-Host "[ACTION] Disabling backup protection..."
        Disable-AzRecoveryServicesBackupProtection `
            -Item $backupItem `
            -RemoveRecoveryPoints `
            -Force | Out-Null

        Write-Host "[OK] Backup protection disabled"
        Write-Host "[NOTE] Soft Delete is ENABLED by Azure default and is NOT a migration blocker"

        break
    }

    if ($backupFound) { break }
}

if (-not $backupFound) {
    Write-Host "[OK] No Azure Backup configured for this VM"
}

# ================================
# FINAL STATUS
# ================================
Write-Host "================================================="
Write-Host " PHASE 1 COMPLETED SUCCESSFULLY"
Write-Host " - VM deallocated"
Write-Host " - Public IP detached"
Write-Host " - Backup protection removed"
Write-Host " - Soft Delete ignored (by design)"
Write-Host "================================================="

exit 0
