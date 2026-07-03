#Requires -Version 5.1
param([string]$TargetDrive = '', [switch]$Confirmed)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $ScriptDir '..\Core\Toolkit.Core.psm1') -Force -DisableNameChecking
. (Join-Path $ScriptDir 'Bootloader.Common.ps1')

$workflow = Start-Workflow -WorkflowName 'Bootloader_BCDBackup' -ScriptBlock {
    param($r)

    Assert-WinPeOrThrow -Result $r
    $target = Select-BootloaderTargetWithConfirmation -Targets (Get-BootloaderTargets) -ActionName 'BCD Backup' -PreSelectedDrive $TargetDrive -SkipConfirmation:$Confirmed.IsPresent

    $backupRoot = Join-Path $target.DriveRoot 'CDE_Bootloader_Backups'
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

    if (-not (Confirm-BootloaderWriteAction -Message "Create BCD backups (store file copy) on $backupRoot for target $($target.WindowsDir)?" -Force:$Confirmed)) {
        throw 'Operation cancelled by operator at write confirmation.'
    }

    if (-not (Test-Path -LiteralPath $backupRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    }

    if (Test-Path -LiteralPath $target.EfiBcdPath -PathType Leaf) {
        $efiBackup = Join-Path $backupRoot "EFI_BCDExport_$timestamp.bcd"
        $step = Invoke-BcdEditExport -BcdStorePath $target.EfiBcdPath -ExportPath $efiBackup -StepName 'BackupEFI_BCD'
        Add-BootloaderStep -Result $r -Step $step
    } else {
        Add-BootloaderStep -Result $r -Step ([PSCustomObject]@{
            Name = 'BackupEFI_BCD'
            Status = 'Warn'
            ExitCode = 1
            Output = "EFI BCD store not found at $($target.EfiBcdPath)"
        })
    }

    if (Test-Path -LiteralPath $target.BiosBcdPath -PathType Leaf) {
        $biosBackup = Join-Path $backupRoot "BIOS_BCDExport_$timestamp.bcd"
        $step = Invoke-BcdEditExport -BcdStorePath $target.BiosBcdPath -ExportPath $biosBackup -StepName 'BackupBIOS_BCD'
        Add-BootloaderStep -Result $r -Step $step
    } else {
        Add-BootloaderStep -Result $r -Step ([PSCustomObject]@{
            Name = 'BackupBIOS_BCD'
            Status = 'Warn'
            ExitCode = 1
            Output = "BIOS BCD store not found at $($target.BiosBcdPath)"
        })
    }
}

try {
    Complete-BootloaderWorkflow -WorkflowResult $workflow
} catch {
    Write-Error "BootloaderBcdBackup workflow failed: $($_.Exception.Message)"
    exit 1
}
