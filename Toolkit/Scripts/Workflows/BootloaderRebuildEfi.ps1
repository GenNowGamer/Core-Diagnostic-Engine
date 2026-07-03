#Requires -Version 5.1
param([string]$TargetDrive = '', [string]$EfiTargetDrive = '', [switch]$Confirmed)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $ScriptDir '..\Core\Toolkit.Core.psm1') -Force -DisableNameChecking
. (Join-Path $ScriptDir 'Bootloader.Common.ps1')

$workflow = Start-Workflow -WorkflowName 'Bootloader_RebuildEFI' -ScriptBlock {
    param($r)

    Assert-WinPeOrThrow -Result $r
    $target = Select-BootloaderTargetWithConfirmation -Targets (Get-BootloaderTargets) -ActionName 'EFI rebuild' -PreSelectedDrive $TargetDrive

    $efiTarget = if (Test-Path -LiteralPath $target.EfiBcdPath -PathType Leaf) {
        $target
    } else {
        Select-BootloaderEfiVolumeWithConfirmation -PreSelectedDrive $EfiTargetDrive
    }

    if (-not (Test-Path -LiteralPath $efiTarget.EfiBcdPath -PathType Leaf)) {
        throw 'Unable to find an EFI BCD store on mounted volumes. Cannot run EFI rebuild.'
    }

    $msg = @(
        'Run bcdboot to rebuild EFI boot files?',
        '',
        "Windows source: $($target.WindowsDir)",
        "EFI system volume: $($efiTarget.DriveRoot)"
    ) -join "`n"

    if (-not (Confirm-BootloaderWriteAction -Message $msg -Force:$Confirmed)) {
        throw 'Operation cancelled by operator at write confirmation.'
    }

    $step = Invoke-BootloaderCommandCaptured -FilePath 'bcdboot.exe' -ArgumentList @($target.WindowsDir, '/s', $efiTarget.DriveRoot, '/f', 'UEFI') -StepName 'BCDBootRebuildEFI'
    Add-BootloaderStep -Result $r -Step $step
}

Generate-Report -WorkflowResult $workflow | Out-Null
