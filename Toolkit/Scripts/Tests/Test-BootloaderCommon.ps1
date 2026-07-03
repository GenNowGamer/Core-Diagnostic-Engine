#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Bootloader.Common.ps1 helpers.
#>

$ErrorActionPreference = 'Stop'

$commonScript = Join-Path (Split-Path $MyInvocation.MyCommand.Path) '..\Workflows\Bootloader.Common.ps1'
$coreModule = Join-Path (Split-Path $MyInvocation.MyCommand.Path) '..\Core\Toolkit.Core.psm1'
$orchestrator = Join-Path (Split-Path $MyInvocation.MyCommand.Path) '..\Core\HealthCheckOrchestrator.ps1'
Import-Module $coreModule -Force -DisableNameChecking
. $orchestrator
. $commonScript

$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0

function Assert-True {
    param(
        [string]$Name,
        [bool]$Condition,
        [string]$Detail = ''
    )

    if ($Condition) {
        $script:passed++
        Write-Host "PASS: $Name"
        return
    }

    $message = $Name
    if (-not [string]::IsNullOrWhiteSpace($Detail)) {
        $message = "$Name :: $Detail"
    }

    $failures.Add($message) | Out-Null
    Write-Host "FAIL: $message" -ForegroundColor Red
}

Assert-True -Name 'Bootsect volume normalizes drive root' -Condition ((Get-BootsectVolumeSpecifier -DriveRoot 'D:\') -eq 'D:')
Assert-True -Name 'Normalize drive root' -Condition ((Normalize-DriveRoot -DriveRoot 'C') -eq 'C:')
Assert-True -Name 'Normalize drive root with slash' -Condition ((Normalize-DriveRoot -DriveRoot 'D:\') -eq 'D:')

$capture = Get-CommandCaptureText -Stdout $null -Stderr ''
Assert-True -Name 'Capture text tolerates null stdout' -Condition ($capture -eq '')
$captureBoth = Get-CommandCaptureText -Stdout 'ok' -Stderr $null
Assert-True -Name 'Capture text joins non-null stdout' -Condition ($captureBoth -eq 'ok')

$warnWorkflow = [PSCustomObject]@{
    WorkflowName = 'Bootloader_BCDBackup'
    Steps        = @(
        [PSCustomObject]@{ Name = 'BackupEFI_BCD'; Status = 'Pass'; Output = 'copied' }
        [PSCustomObject]@{ Name = 'BackupBIOS_BCD'; Status = 'Warn'; Output = 'missing' }
    )
}
$parsed = ConvertFrom-ChildWorkflowJsonText -Text ($warnWorkflow | ConvertTo-Json -Depth 6)
Assert-True -Name 'Child workflow JSON parses steps' -Condition ($null -ne $parsed -and @($parsed.Steps).Count -eq 2)
$mergedHealth = Get-WorkflowOverallHealth -Steps @($parsed.Steps)
Assert-True -Name 'Merged child steps surface Warning health' -Condition ($mergedHealth -eq 'Warning')

$resolved = Resolve-PreselectedBootloaderItem -Items @(
    [PSCustomObject]@{ DriveRoot = 'C:'; WindowsDir = 'C:\Windows' }
    [PSCustomObject]@{ DriveRoot = 'D:'; WindowsDir = 'D:\Windows' }
) -PreSelectedDrive 'D:\'
Assert-True -Name 'Resolve preselected drive' -Condition ($null -ne $resolved -and $resolved.DriveRoot -eq 'D:')

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('CDE_BootloaderTest_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
    $efiBackup = Join-Path $tempRoot 'EFI_BCDExport_20260101_120000.bcd'
    $biosBackup = Join-Path $tempRoot 'BIOS_BCDExport_20260102_120000.bcd'
    Set-Content -LiteralPath $efiBackup -Value 'efi' -Encoding Ascii
    Set-Content -LiteralPath $biosBackup -Value 'bios' -Encoding Ascii

    $inventory = Get-BcdBackupInventory -BackupRoot $tempRoot
    Assert-True -Name 'Inventory finds EFI backups' -Condition ($inventory.EfiBackups.Count -eq 1)
    Assert-True -Name 'Inventory finds BIOS backups' -Condition ($inventory.BiosBackups.Count -eq 1)

    $selected = Resolve-BcdBackupSelection -Inventory $inventory -Kind 'EFI' -PreselectedPath $efiBackup
    Assert-True -Name 'Resolve EFI backup path' -Condition ($selected.FullName -eq $efiBackup)
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`n--- SUMMARY ---" -ForegroundColor Cyan
Write-Host "Passed: $passed"
Write-Host "Failed: $($failures.Count)"
if ($failures.Count -gt 0) {
    foreach ($failure in $failures) {
        Write-Host "  $failure" -ForegroundColor Red
    }
    exit 1
}

exit 0
