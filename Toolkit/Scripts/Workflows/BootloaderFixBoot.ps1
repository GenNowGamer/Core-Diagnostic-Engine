#Requires -Version 5.1
param([string]$TargetDrive = '', [switch]$Confirmed)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $ScriptDir '..\Core\Toolkit.Core.psm1') -Force -DisableNameChecking
. (Join-Path $ScriptDir 'Bootloader.Common.ps1')

$workflow = Start-Workflow -WorkflowName 'Bootloader_FixBoot' -ScriptBlock {
    param($r)

    Assert-WinPeOrThrow -Result $r
    $target = Select-BootloaderTargetWithConfirmation -Targets (Get-BootloaderTargets) -ActionName 'Fix Boot VBR' -PreSelectedDrive $TargetDrive

    if (-not (Confirm-BootloaderWriteAction -Message "Run bootsect /nt60 SYS for target $($target.WindowsDir)?`n`nThis will rewrite the Volume Boot Record on the system partition." -Force:$Confirmed)) {
        throw 'Operation cancelled by operator at write confirmation.'
    }

    # bootrec /fixboot is not available in ADK WinPE (WinRE-only).
    # Target the selected volume explicitly instead of WinPE's SYS volume.
    $step = Invoke-BootsectOnBootloaderTarget -Target $target -StepName 'BootsectFixBoot'
    Add-BootloaderStep -Result $r -Step $step
}

Generate-Report -WorkflowResult $workflow | Out-Null
