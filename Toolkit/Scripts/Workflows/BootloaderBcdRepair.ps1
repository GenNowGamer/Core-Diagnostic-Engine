#Requires -Version 5.1
param([string]$TargetDrive = '', [switch]$Confirmed)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $ScriptDir '..\Core\Toolkit.Core.psm1') -Force -DisableNameChecking
. (Join-Path $ScriptDir 'Bootloader.Common.ps1')

$workflow = Start-Workflow -WorkflowName 'Bootloader_BCDRepair' -ScriptBlock {
    param($r)

    Assert-WinPeOrThrow -Result $r
    $target = Select-BootloaderTargetWithConfirmation -Targets (Get-BootloaderTargets) -ActionName 'BCD Repair' -PreSelectedDrive $TargetDrive

    $efiStore = $target.EfiBcdPath
    $enumStep = if (Test-Path -LiteralPath $efiStore -PathType Leaf) {
        Invoke-BootloaderCommandCaptured -FilePath 'bcdedit.exe' -ArgumentList @('/store', $efiStore, '/enum', 'all') -StepName 'BCDEnum'
    } else {
        [PSCustomObject]@{
            Name = 'BCDEnum'
            Status = 'Warn'
            ExitCode = 1
            Output = "EFI BCD store not found at $efiStore"
        }
    }
    Add-BootloaderStep -Result $r -Step $enumStep

    if ($enumStep.ExitCode -eq 0) {
        Write-Log 'BCD enum completed successfully. No repair needed.'
        return
    }

    if (-not (Confirm-BootloaderWriteAction -Message "BCD check reported issues. Run bootrec remediation for $($target.WindowsDir)?" -Force:$Confirmed)) {
        throw 'Operation cancelled by operator at write confirmation.'
    }

    # bootrec.exe is not available in ADK WinPE (WinRE-only). Use WinPE-native equivalents:
    #   bootsect.exe  — writes MBR and VBR (from ADK, injected into WinPE by Customize-WinPE.ps1)
    #   bcdboot.exe   — rebuilds BCD store and boot files (native in WinPE)

    $step = Invoke-BootsectOnBootloaderTarget -Target $target -StepName 'BootsectFixMBR' -IncludeMbr
    Add-BootloaderStep -Result $r -Step $step

    $step = Invoke-BootsectOnBootloaderTarget -Target $target -StepName 'BootsectFixBoot'
    Add-BootloaderStep -Result $r -Step $step

    $step = Invoke-BootloaderCommandCaptured -FilePath 'bcdboot.exe' -ArgumentList @($target.WindowsDir, '/s', $target.DriveRoot, '/f', 'ALL') -StepName 'BcdBootRebuildBCD'
    Add-BootloaderStep -Result $r -Step $step
}

Generate-Report -WorkflowResult $workflow | Out-Null
