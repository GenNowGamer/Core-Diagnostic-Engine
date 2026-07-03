#Requires -Version 5.1
param(
    [string]$TargetDrive = '',
    [int]$DiskNumber = -1,
    [switch]$Confirmed
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $ScriptDir '..\Core\Toolkit.Core.psm1') -Force -DisableNameChecking
. (Join-Path $ScriptDir 'Bootloader.Common.ps1')

$workflow = Start-Workflow -WorkflowName 'BootArtifacts_BackupAll' -ScriptBlock {
    param($r)

    Assert-WinPeOrThrow -Result $r
    $target = Select-BootloaderTargetWithConfirmation -Targets (Get-BootloaderTargets) -ActionName 'Backup boot artifacts' -PreSelectedDrive $TargetDrive -SkipConfirmation:$Confirmed.IsPresent

    $resolvedDisk = $DiskNumber
    if ($resolvedDisk -lt 0 -and (Get-Command Get-Partition -ErrorAction SilentlyContinue)) {
        $letter = $target.DriveRoot.TrimEnd('\').TrimEnd(':')
        $part = Get-Partition -DriveLetter $letter -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($part) { $resolvedDisk = [int]$part.DiskNumber }
    }

    if (-not (Confirm-BootloaderWriteAction -Message "Backup BCD (store file copy) and partition layout for $($target.WindowsDir)?" -Force:$Confirmed)) {
        throw 'Operation cancelled by operator at write confirmation.'
    }

    $bcdScript = Join-Path $ScriptDir 'BootloaderBcdBackup.ps1'
    Merge-BootloaderChildWorkflow -Result $r -ScriptPath $bcdScript -Arguments @{
        TargetDrive = $target.DriveRoot
        Confirmed   = [bool]$Confirmed.IsPresent
    } -GroupName 'BcdBackup'

    if ($resolvedDisk -ge 0) {
        $ptScript = Join-Path $ScriptDir 'PartitionTableBackup.ps1'
        $backupRoot = Join-Path $target.DriveRoot 'CDE_Bootloader_Backups'
        Merge-BootloaderChildWorkflow -Result $r -ScriptPath $ptScript -Arguments @{
            DiskNumber = $resolvedDisk
            BackupRoot = $backupRoot
            Confirmed  = [bool]$Confirmed.IsPresent
        } -GroupName 'PartitionBackup'
    } else {
        Add-BootloaderStep -Result $r -Step ([PSCustomObject]@{
            Name     = 'PartitionTableBackupChild'
            Status   = 'Skip'
            ExitCode = 0
            Output   = 'Could not resolve disk number for partition layout backup.'
            CheckId  = 'PartitionBackup'
        })
    }

    $null = Set-WorkflowOverallHealth -WorkflowResult $r
}

Generate-Report -WorkflowResult $workflow | Out-Null
