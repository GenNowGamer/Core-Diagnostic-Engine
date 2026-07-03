#Requires -Version 5.1
param([string]$TargetDrive = '', [switch]$Confirmed)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $ScriptDir '..\Core\Toolkit.Core.psm1') -Force -DisableNameChecking
. (Join-Path $ScriptDir 'Bootloader.Common.ps1')

$workflow = Start-Workflow -WorkflowName 'Bootloader_FixMBR' -ScriptBlock {
    param($r)

    Assert-WinPeOrThrow -Result $r
    $target = Select-BootloaderTargetWithConfirmation -Targets (Get-BootloaderTargets) -ActionName 'Fix MBR' -PreSelectedDrive $TargetDrive

    if (-not (Confirm-BootloaderWriteAction -Message "Run bootsect /nt60 SYS /mbr for target $($target.WindowsDir)?`n`nThis will rewrite the MBR and VBR on the system disk." -Force:$Confirmed)) {
        throw 'Operation cancelled by operator at write confirmation.'
    }

    # bootrec /fixmbr is not available in ADK WinPE (WinRE-only).
    # Target the selected volume explicitly instead of WinPE's SYS volume.
    $step = Invoke-BootsectOnBootloaderTarget -Target $target -StepName 'BootsectFixMBR' -IncludeMbr
    Add-BootloaderStep -Result $r -Step $step
}

Generate-Report -WorkflowResult $workflow | Out-Null
