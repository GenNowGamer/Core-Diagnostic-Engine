#Requires -Version 5.1
param(
    [string]$TargetDrive = '',
    [string]$EfiBackupPath = '',
    [string]$BiosBackupPath = '',
    [switch]$Confirmed
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $ScriptDir '..\Core\Toolkit.Core.psm1') -Force -DisableNameChecking
. (Join-Path $ScriptDir 'Bootloader.Common.ps1')

$workflow = Start-Workflow -WorkflowName 'Bootloader_BCDRestore' -ScriptBlock {
    param($r)

    Assert-WinPeOrThrow -Result $r
    $target = Select-BootloaderTargetWithConfirmation -Targets (Get-BootloaderTargets) -ActionName 'BCD Restore' -PreSelectedDrive $TargetDrive -SkipConfirmation:$Confirmed.IsPresent

    $backupRoot = Join-Path $target.DriveRoot 'CDE_Bootloader_Backups'
    if (-not (Test-Path -LiteralPath $backupRoot -PathType Container)) {
        throw "Backup folder not found: $backupRoot"
    }

    $inventory = Get-BcdBackupInventory -BackupRoot $backupRoot

    $efiBackup = $null
    if ($inventory.EfiBackups.Count -gt 0) {
        if (-not [string]::IsNullOrWhiteSpace($EfiBackupPath)) {
            $efiBackup = Resolve-BcdBackupSelection -Inventory $inventory -Kind 'EFI' -PreselectedPath $EfiBackupPath
        } elseif (-not $Confirmed) {
            $efiBackup = Resolve-BcdBackupSelection -Inventory $inventory -Kind 'EFI'
        }
    }

    $biosBackup = $null
    if ($inventory.BiosBackups.Count -gt 0) {
        if (-not [string]::IsNullOrWhiteSpace($BiosBackupPath)) {
            $biosBackup = Resolve-BcdBackupSelection -Inventory $inventory -Kind 'BIOS' -PreselectedPath $BiosBackupPath
        } elseif (-not $Confirmed) {
            $biosBackup = Resolve-BcdBackupSelection -Inventory $inventory -Kind 'BIOS'
        }
    }

    if (-not $efiBackup -and -not $biosBackup) {
        throw "No BCD backup files were selected from $backupRoot"
    }

    $msg = @(
        "Restore selected BCD backups (store file copy) for target $($target.WindowsDir)?",
        '',
        'WARNING: restore replaces the live BCD store file after saving a safety snapshot.',
        '',
        "EFI backup: $(if ($efiBackup) { $efiBackup.FullName } else { 'Skip' })",
        "BIOS backup: $(if ($biosBackup) { $biosBackup.FullName } else { 'Skip' })"
    ) -join "`n"

    if (-not (Confirm-BootloaderWriteAction -Message $msg -Force:$Confirmed)) {
        throw 'Operation cancelled by operator at write confirmation.'
    }

    if ($efiBackup) {
        if (Test-Path -LiteralPath $target.EfiBcdPath -PathType Leaf) {
            $step = Invoke-BcdEditImport -BcdStorePath $target.EfiBcdPath -ImportPath $efiBackup.FullName -StepName 'RestoreEFI_BCD'
            Add-BootloaderStep -Result $r -Step $step
        } else {
            Add-BootloaderStep -Result $r -Step ([PSCustomObject]@{
                Name = 'RestoreEFI_BCD'
                Status = 'Warn'
                ExitCode = 1
                Output = "EFI destination not found at $($target.EfiBcdPath)"
            })
        }
    }

    if ($biosBackup) {
        if (Test-Path -LiteralPath $target.BiosBcdPath -PathType Leaf) {
            $step = Invoke-BcdEditImport -BcdStorePath $target.BiosBcdPath -ImportPath $biosBackup.FullName -StepName 'RestoreBIOS_BCD'
            Add-BootloaderStep -Result $r -Step $step
        } else {
            Add-BootloaderStep -Result $r -Step ([PSCustomObject]@{
                Name = 'RestoreBIOS_BCD'
                Status = 'Warn'
                ExitCode = 1
                Output = "BIOS destination not found at $($target.BiosBcdPath)"
            })
        }
    }
}

Generate-Report -WorkflowResult $workflow | Out-Null
