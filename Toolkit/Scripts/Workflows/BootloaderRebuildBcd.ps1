#Requires -Version 5.1
param([string]$TargetDrive = '', [switch]$Confirmed)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $ScriptDir '..\Core\Toolkit.Core.psm1') -Force -DisableNameChecking
. (Join-Path $ScriptDir 'Bootloader.Common.ps1')

$workflow = Start-Workflow -WorkflowName 'Bootloader_RebuildBCD' -ScriptBlock {
    param($r)

    Assert-WinPeOrThrow -Result $r
    $target = Select-BootloaderTargetWithConfirmation -Targets (Get-BootloaderTargets) -ActionName 'Rebuild BCD' -PreSelectedDrive $TargetDrive

    if (-not (Confirm-BootloaderWriteAction -Message "Run bcdboot to rebuild BCD for target $($target.WindowsDir)?`n`nSystem partition: $($target.DriveRoot)" -Force:$Confirmed)) {
        throw 'Operation cancelled by operator at write confirmation.'
    }

    # bootrec /rebuildbcd is not available in ADK WinPE (WinRE-only).
    # bcdboot.exe is the WinPE-native equivalent: it creates/repairs the BCD store and copies
    # boot files for the specified Windows installation. /f ALL covers both BIOS and UEFI.
    $step = Invoke-BootloaderCommandCaptured -FilePath 'bcdboot.exe' -ArgumentList @($target.WindowsDir, '/s', $target.DriveRoot, '/f', 'ALL') -StepName 'BcdBootRebuildBCD'
    Add-BootloaderStep -Result $r -Step $step
}

Generate-Report -WorkflowResult $workflow | Out-Null
