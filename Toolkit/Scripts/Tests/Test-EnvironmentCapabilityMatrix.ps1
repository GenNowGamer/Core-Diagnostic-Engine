#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$testsRoot = Split-Path $MyInvocation.MyCommand.Path
$toolkitRoot = Split-Path (Split-Path $testsRoot) -Parent
$coreModule = Join-Path $toolkitRoot 'Scripts\Core\Toolkit.Core.psm1'
Import-Module $coreModule -Force -DisableNameChecking

$matrix = Get-ToolkitCapabilityMatrix
if ($null -eq $matrix -or $null -eq $matrix.workflows) {
    Write-Error 'Failed to load EnvironmentCapabilityMatrix.json'
    exit 1
}
Write-Host 'PASS: loads matrix JSON'

$apply = $matrix.workflows.FastFixes.actions.Apply
if ($apply.winpe_online -ne 'na' -or $apply.winpe_offline -ne 'na') {
    Write-Error 'Expected FastFixes Apply to be na in WinPE columns'
    exit 1
}
Write-Host 'PASS: includes FastFixes Apply as na in WinPE columns'

$workflowDir = Join-Path $toolkitRoot 'Scripts\Workflows'
$scripts = Get-ChildItem -LiteralPath $workflowDir -Filter '*.ps1' |
    Where-Object {
        $_.Name -notlike 'Test-*' -and
        $_.Name -ne 'Bootloader.Common.ps1' -and
        $_.Name -ne 'HardwareCommon.ps1'
    }

$matrixWorkflowNames = @($matrix.workflows.PSObject.Properties.Name)
foreach ($script in $scripts) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($script.Name)
    if ($matrixWorkflowNames -notcontains $name) {
        Write-Error "Workflow script '$($script.Name)' is missing from EnvironmentCapabilityMatrix.json"
        exit 1
    }
}
Write-Host 'PASS: maps every workflow ps1 to a matrix row'

if ($matrixWorkflowNames -contains 'BootloaderRepair') {
    Write-Error 'Orphaned BootloaderRepair entry still present in EnvironmentCapabilityMatrix.json'
    exit 1
}
Write-Host 'PASS: no orphaned BootloaderRepair row'

Write-Host 'Test-EnvironmentCapabilityMatrix: PASS'
exit 0
