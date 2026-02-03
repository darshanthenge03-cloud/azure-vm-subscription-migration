$ErrorActionPreference = "Stop"

Import-Module Az.Accounts -Force
Import-Module Az.RecoveryServices -Force

# INPUT
$SourceSubscriptionId = "46689057-be43-4229-9241-e0591dad4dbf"
$VMName = "ubuntuServer"

Set-AzContext -SubscriptionId $SourceSubscriptionId

$vault = Get-AzRecoveryServicesVault | Select-Object -First 1
if (-not $vault) { throw "No vault found in source." }

Set-AzRecoveryServicesVaultContext -Vault $vault

$item = Get-AzRecoveryServicesBackupItem `
    -WorkloadType AzureVM `
    -BackupManagementType AzureVM |
    Where-Object { $_.FriendlyName -eq $VMName }

if (-not $item) { throw "VM not protected in vault." }

$policy = Get-AzRecoveryServicesBackupProtectionPolicy `
    -Name $item.ProtectionPolicyName

# Build export object
$export = [PSCustomObject]@{
    VaultName        = $vault.Name
    VaultLocation    = $vault.Location
    PolicyName       = $policy.Name
    Schedule         = $policy.SchedulePolicy
    Retention        = $policy.RetentionPolicy
}

$export | ConvertTo-Json -Depth 10 | Out-File "./backup-config.json"

Write-Host "Backup configuration exported to backup-config.json"
