#Requires -Version 5.1
param([string]$TargetDrive = '', [switch]$Confirmed)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $ScriptDir '..\Core\Toolkit.Core.psm1') -Force -DisableNameChecking
. (Join-Path $ScriptDir 'Bootloader.Common.ps1')

$workflow = Start-Workflow -WorkflowName 'Bootloader_BCDRepair' -ScriptBlock {
    param($r)

    Assert-WinPeOrThrow -Result $r
    $target = Select-BootloaderTargetWithConfirmation -Targets (Get-BootloaderTargets) -ActionName 'BCD Repair' -PreSelectedDrive $TargetDrive

    $bcdStore = if (Test-Path -LiteralPath $target.EfiBcdPath -PathType Leaf) {
        $target.EfiBcdPath
    } elseif (Test-Path -LiteralPath $target.BiosBcdPath -PathType Leaf) {
        $target.BiosBcdPath
    } else {
        $target.EfiBcdPath
    }
    $enumStep = if (Test-Path -LiteralPath $bcdStore -PathType Leaf) {
        Invoke-BootloaderCommandCaptured -FilePath 'bcdedit.exe' -ArgumentList @('/store', $bcdStore, '/enum', 'all') -StepName 'BCDEnum'
    } else {
        [PSCustomObject]@{
            Name = 'BCDEnum'
            Status = 'Warn'
            ExitCode = 1
            Output = "BCD store not found at $($target.EfiBcdPath) or $($target.BiosBcdPath)"
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
    #   bootsect.exe  - writes MBR and VBR (from ADK, injected into WinPE by Customize-WinPE.ps1)
    #   bcdboot.exe   - rebuilds BCD store and boot files (native in WinPE)

    $isMbrDisk = $false
    if (Get-Command Get-Partition -ErrorAction SilentlyContinue) {
        try {
            $winLetter = $target.DriveRoot.TrimEnd('\').TrimEnd(':')
            $winPart = Get-Partition -DriveLetter $winLetter -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($winPart -and (Get-Command Get-Disk -ErrorAction SilentlyContinue)) {
                $diskObj = Get-Disk -Number $winPart.DiskNumber -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($diskObj -and [string]$diskObj.PartitionStyle -ieq 'MBR') {
                    $isMbrDisk = $true
                }
            }
        } catch { }
    }

    if ($isMbrDisk) {
        $step = Invoke-BootsectOnBootloaderTarget -Target $target -StepName 'BootsectFixMBR' -IncludeMbr
        Add-BootloaderStep -Result $r -Step $step
    }

    $step = Invoke-BootsectOnBootloaderTarget -Target $target -StepName 'BootsectFixBoot'
    Add-BootloaderStep -Result $r -Step $step

    $bootTargetRoot = if ($target.EfiDriveRoot) { $target.EfiDriveRoot } else { $target.DriveRoot }
    $step = Invoke-BootloaderCommandCaptured -FilePath 'bcdboot.exe' -ArgumentList @($target.WindowsDir, '/s', $bootTargetRoot, '/f', 'ALL') -StepName 'BcdBootRebuildBCD'
    Add-BootloaderStep -Result $r -Step $step
}

Generate-Report -WorkflowResult $workflow | Out-Null
