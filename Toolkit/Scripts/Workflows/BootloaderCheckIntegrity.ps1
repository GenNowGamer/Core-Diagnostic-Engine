#Requires -Version 5.1
param([string]$TargetDrive = '')

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $ScriptDir '..\Core\Toolkit.Core.psm1') -Force -DisableNameChecking
. (Join-Path $ScriptDir 'Bootloader.Common.ps1')

$workflow = Start-Workflow -WorkflowName 'Bootloader_IntegrityCheck' -ScriptBlock {
    param($r)

    Assert-WinPeOrThrow -Result $r
    $target = Select-BootloaderTargetWithConfirmation -Targets (Get-BootloaderTargets) -ActionName 'Boot sector integrity check' -PreSelectedDrive $TargetDrive

    $efiRoot = if ($target.EfiDriveRoot) { $target.EfiDriveRoot } else { $target.DriveRoot }

    foreach ($check in @(
        @{ Name = 'CheckBootmgrEFI'; Path = (Join-Path $efiRoot 'EFI\Microsoft\Boot\bootmgfw.efi') },
        @{ Name = 'CheckBootmgrBIOS'; Path = (Join-Path $target.DriveRoot 'bootmgr') },
        @{ Name = 'CheckEFI_BCD_File'; Path = $target.EfiBcdPath },
        @{ Name = 'CheckBIOS_BCD_File'; Path = $target.BiosBcdPath }
    )) {
        $exists = Test-Path -LiteralPath $check.Path -PathType Leaf
        Add-BootloaderStep -Result $r -Step ([PSCustomObject]@{
            Name = $check.Name
            Status = if ($exists) { 'Pass' } else { 'Warn' }
            ExitCode = if ($exists) { 0 } else { 1 }
            Output = if ($exists) { "Found $($check.Path)" } else { "Missing $($check.Path)" }
        })
    }

    if (Test-Path -LiteralPath $target.EfiBcdPath -PathType Leaf) {
        $efiEnum = Invoke-BootloaderCommandCaptured -FilePath 'bcdedit.exe' -ArgumentList @('/store', $target.EfiBcdPath, '/enum', 'all') -StepName 'CheckEFI_BCD_Enum'
        Add-BootloaderStep -Result $r -Step $efiEnum
    }

    if (Test-Path -LiteralPath $target.BiosBcdPath -PathType Leaf) {
        $biosEnum = Invoke-BootloaderCommandCaptured -FilePath 'bcdedit.exe' -ArgumentList @('/store', $target.BiosBcdPath, '/enum', 'all') -StepName 'CheckBIOS_BCD_Enum'
        Add-BootloaderStep -Result $r -Step $biosEnum
    }
}

Generate-Report -WorkflowResult $workflow | Out-Null
