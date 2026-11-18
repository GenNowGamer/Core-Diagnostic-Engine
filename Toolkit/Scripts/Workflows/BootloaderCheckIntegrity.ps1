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
    $efiBootmgr = Join-Path $efiRoot 'EFI\Microsoft\Boot\bootmgfw.efi'
    $biosBootmgr = Join-Path $target.DriveRoot 'bootmgr'

    $hasEfi = (Test-Path -LiteralPath $efiBootmgr -PathType Leaf) -or (Test-Path -LiteralPath $target.EfiBcdPath -PathType Leaf) -or ($efiRoot -ne $target.DriveRoot)
    $hasBios = (Test-Path -LiteralPath $biosBootmgr -PathType Leaf) -or (Test-Path -LiteralPath $target.BiosBcdPath -PathType Leaf)

    foreach ($check in @(
        @{ Name = 'CheckBootmgrEFI';  Path = $efiBootmgr;         Applicable = ($hasEfi -or -not $hasBios) },
        @{ Name = 'CheckBootmgrBIOS'; Path = $biosBootmgr;        Applicable = ($hasBios -or -not $hasEfi) },
        @{ Name = 'CheckEFI_BCD_File';  Path = $target.EfiBcdPath;  Applicable = ($hasEfi -or -not $hasBios) },
        @{ Name = 'CheckBIOS_BCD_File'; Path = $target.BiosBcdPath; Applicable = ($hasBios -or -not $hasEfi) }
    )) {
        $exists = Test-Path -LiteralPath $check.Path -PathType Leaf
        if (-not $exists -and -not $check.Applicable) {
            Add-BootloaderStep -Result $r -Step ([PSCustomObject]@{
                Name = $check.Name
                Status = 'Skip'
                ExitCode = 0
                Output = "Not applicable for detected boot mode ($($check.Path) not present)."
            })
            continue
        }
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
