. "$PSScriptRoot/config.ps1"

$ErrorActionPreference = "Stop"

Import-Module Az.Accounts -Force
Import-Module Az.RecoveryServices -Force

Write-Host "========== PHASE 3: RECREATE BACKUP =========="

# Switch to destination subscription
Set-AzContext -SubscriptionId $DestinationSubscriptionId

# Load exported config
$path = Join-Path $env:GITHUB_WORKSPACE "backup-config.json"

if (-not (Test-Path $path)) {
    throw "backup-config.json not found."
}

$config = Get-Content $path | ConvertFrom-Json

$VaultName = $config.VaultName
$PolicyObj = $config.Policy

# ----------------------------
# Create Vault if needed
# ----------------------------

$vault = Get-AzRecoveryServicesVault -Name $VaultName -ErrorAction SilentlyContinue

if (-not $vault) {
    Write-Host "Creating Recovery Services Vault..."
    $vault = New-AzRecoveryServicesVault `
        -Name $VaultName `
        -ResourceGroupName $DestinationResourceGroup `
        -Location $DestinationLocation
}

Set-AzRecoveryServicesVaultContext -Vault $vault

# ----------------------------
# Recreate Policy Automatically
# ----------------------------

$policyName = $PolicyObj.Name

$existingPolicy = Get-AzRecoveryServicesBackupProtectionPolicy `
    -Name $policyName `
    -ErrorAction SilentlyContinue

if (-not $existingPolicy) {

    Write-Host "Recreating Policy: $policyName"

    # Create schedule object
    if ($PolicyObj.SchedulePolicy.ScheduleRunTimes) {

        $schedule = New-AzRecoveryServicesBackupSchedulePolicyObject `
            -WorkloadType AzureVM

        $schedule.ScheduleRunFrequency = $PolicyObj.SchedulePolicy.ScheduleRunFrequency
        $schedule.ScheduleRunTimes = $PolicyObj.SchedulePolicy.ScheduleRunTimes
    }
    else {
        # Enhanced policy
        $schedule = New-AzRecoveryServicesBackupSchedulePolicyObject `
            -WorkloadType AzureVM
    }

    # Create retention object
    $retention = New-AzRecoveryServicesBackupRetentionPolicyObject `
        -WorkloadType AzureVM

    if ($PolicyObj.RetentionPolicy.DailyRetention) {
        $retention.DailySchedule.DurationCountInDays =
            $PolicyObj.RetentionPolicy.DailyRetention.DurationCountInDays
    }

    if ($PolicyObj.RetentionPolicy.WeeklyRetention) {
        $retention.WeeklySchedule.DurationCountInWeeks =
            $PolicyObj.RetentionPolicy.WeeklyRetention.DurationCountInWeeks
        $retention.WeeklySchedule.DaysOfTheWeek =
            $PolicyObj.RetentionPolicy.WeeklyRetention.DaysOfTheWeek
    }

    if ($PolicyObj.RetentionPolicy.MonthlyRetention) {
        $retention.MonthlySchedule.DurationCountInMonths =
            $PolicyObj.RetentionPolicy.MonthlyRetention.DurationCountInMonths
    }

    if ($PolicyObj.RetentionPolicy.YearlyRetention) {
        $retention.YearlySchedule.DurationCountInYears =
            $PolicyObj.RetentionPolicy.YearlyRetention.DurationCountInYears
    }

    # Create final policy
    New-AzRecoveryServicesBackupProtectionPolicy `
        -Name $policyName `
        -WorkloadType AzureVM `
        -BackupManagementType AzureVM `
        -SchedulePolicy $schedule `
        -RetentionPolicy $retention

    Write-Host "Policy recreated successfully."
}

# ----------------------------
# Enable Backup
# ----------------------------

Write-Host "Enabling backup on VM..."

$policy = Get-AzRecoveryServicesBackupProtectionPolicy -Name $policyName

Enable-AzRecoveryServicesBackupProtection `
    -ResourceGroupName $DestinationResourceGroup `
    -Name $VMName `
    -Policy $policy

# ----------------------------
# Trigger Initial Backup
# ----------------------------

Write-Host "Triggering Initial Backup..."

$container = Get-AzRecoveryServicesBackupContainer `
    -ContainerType AzureVM `
    -FriendlyName $VMName

$item = Get-AzRecoveryServicesBackupItem `
    -Container $container `
    -WorkloadType AzureVM

Backup-AzRecoveryServicesBackupItem -Item $item

Write-Host "========== BACKUP RECREATED & INITIAL BACKUP TRIGGERED =========="
