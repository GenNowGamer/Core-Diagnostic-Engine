#Requires -Version 5.1
param([string]$TargetDrive = '', [string]$EfiTargetDrive = '', [switch]$Confirmed)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $ScriptDir '..\Core\Toolkit.Core.psm1') -Force -DisableNameChecking
. (Join-Path $ScriptDir 'Bootloader.Common.ps1')

$workflow = Start-Workflow -WorkflowName 'Bootloader_RebuildEFI' -ScriptBlock {
    param($r)

    Assert-WinPeOrThrow -Result $r
    $target = Select-BootloaderTargetWithConfirmation -Targets (Get-BootloaderTargets) -ActionName 'EFI rebuild' -PreSelectedDrive $TargetDrive

    $efiRoot = if ($target.EfiDriveRoot) { $target.EfiDriveRoot } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($EfiTargetDrive)) {
        $normalizedEfiDrive = Normalize-DriveRoot -DriveRoot $EfiTargetDrive
        if ((Test-Path -LiteralPath ($normalizedEfiDrive + '\') -PathType Container) -and
            -not (Test-IsToolkitMediaDriveRoot -DriveRoot $normalizedEfiDrive)) {
            $efiRoot = $normalizedEfiDrive
            Write-Host "EFI volume pre-selected: $efiRoot" -ForegroundColor Cyan
        } else {
            $efiTarget = Select-BootloaderEfiVolumeWithConfirmation -PreSelectedDrive $EfiTargetDrive
            $efiRoot = $efiTarget.DriveRoot
        }
    } elseif ([string]::IsNullOrWhiteSpace($efiRoot) -or ($efiRoot -eq $target.DriveRoot -and -not (Test-Path -LiteralPath $target.EfiBcdPath -PathType Leaf))) {
        $efiTarget = Select-BootloaderEfiVolumeWithConfirmation -PreSelectedDrive $EfiTargetDrive
        $efiRoot = $efiTarget.DriveRoot
    }

    if ([string]::IsNullOrWhiteSpace($efiRoot)) {
        throw 'Unable to find a mounted EFI system partition. Cannot run EFI rebuild.'
    }

    $msg = @(
        'Run bcdboot to rebuild EFI boot files?',
        '',
        "Windows source: $($target.WindowsDir)",
        "EFI system volume: $efiRoot"
    ) -join "`n"

    if (-not (Confirm-BootloaderWriteAction -Message $msg -Force:$Confirmed)) {
        throw 'Operation cancelled by operator at write confirmation.'
    }

    $step = Invoke-BootloaderCommandCaptured -FilePath 'bcdboot.exe' -ArgumentList @($target.WindowsDir, '/s', $efiRoot, '/f', 'UEFI') -StepName 'BCDBootRebuildEFI'
    Add-BootloaderStep -Result $r -Step $step
}

Generate-Report -WorkflowResult $workflow | Out-Null
