#Requires -Version 5.1
<#
.SYNOPSIS
    HardwareDiagnostics.ps1 - Diag and Repair suite: CPU, Memory, Storage, and CST security scan.
    Pass -ToolName to run a specific category, CstScan, or All (hardware plus CST).
#>

param(
    [string]$ToolName = 'All',
    [ValidateSet('Quick', 'Extended')]
    [string]$TestProfile = 'Quick'
)

$ErrorActionPreference = 'Stop'

$ScriptDir  = Split-Path $MyInvocation.MyCommand.Path
$CoreDir    = Join-Path $ScriptDir '..\Core'
$CoreModule = Join-Path $CoreDir 'Toolkit.Core.psm1'
Import-Module $CoreModule -Force -DisableNameChecking
Import-Module (Join-Path $CoreDir 'HardwareTestCatalog.psm1') -Force -DisableNameChecking

. (Join-Path $CoreDir 'HardwareTestEngine.ps1')
. (Join-Path $CoreDir 'HardwareSmartEngine.ps1')
. (Join-Path $ScriptDir 'HardwareCommon.ps1')
. (Join-Path $ScriptDir 'HardwareCpuTests.ps1')
. (Join-Path $ScriptDir 'HardwareMemoryTests.ps1')
. (Join-Path $ScriptDir 'HardwareStorageTests.ps1')

$SecurityChecks = Join-Path $CoreDir 'SecurityAuditChecks.ps1'
if (Test-Path $SecurityChecks) { . $SecurityChecks }

function Invoke-DiagRepairCstScan {
    param($r)

    $cstMode = if ($TestProfile -eq 'Extended') { 'FullScan' } else { 'ThreatScan' }
    $script:CstMode = $cstMode
    $script:CstDetectionScope = 'All'
    $script:CstActionMode = 'ScanOnly'

    Write-Log ("Diag and Repair: starting CST ($cstMode, ScanOnly)...")
    Write-HwProgress -Percent 0 -Scanned 0 -Total 1 -CurrentTest 'Core Security Tool' -Phase 'Security Scan'

    Invoke-CoreSecurityTool $r

    Write-HwProgress -Percent 100 -Scanned 1 -Total 1 -CurrentTest 'Core Security Tool' -Phase 'Security Scan Complete'
}

$workflowName = switch ($ToolName) {
    'CpuTests'     { 'HardwareDiag_CPU' }
    'MemoryTests'  { 'HardwareDiag_Memory' }
    'StorageTests' { 'HardwareDiag_Storage' }
    'CstScan'      { 'HardwareDiag_CST' }
    default        { 'HardwareDiag_All' }
}

try {
    if ($ToolName -ne 'CstScan') {
        Initialize-HwTestProfile -Profile $TestProfile
    }
    else {
        $script:HwProfileName = $TestProfile
    }

    $script:HwGlobalTotal = Get-HwTestTotal -Name $ToolName
    $script:HwGlobalDone = 0
    Write-Log ("Diag and Repair: profile={0}, tool={1}, sub-tests={2}" -f $script:HwProfileName, $ToolName, $script:HwGlobalTotal)
    Write-Host "[HW:PROFILE] $((@{ profile = $script:HwProfileName; toolName = $ToolName } | ConvertTo-Json -Compress))"

    $workflow = Start-Workflow -WorkflowName $workflowName -ScriptBlock {
        param($r)
        switch ($ToolName) {
            'CpuTests'     { Invoke-CpuTests $r }
            'MemoryTests'  { Invoke-MemoryTests $r }
            'StorageTests' { Invoke-StorageTests $r }
            'CstScan'      { Invoke-DiagRepairCstScan $r }
            default {
                Invoke-CpuTests $r
                Invoke-MemoryTests $r
                Invoke-StorageTests $r
                Invoke-DiagRepairCstScan $r
            }
        }
        if ($ToolName -ne 'CstScan') {
            $hwTotal = Get-HwTestTotal -Name $ToolName
            Write-HwProgress -Percent 100 -Scanned $hwTotal -Total $hwTotal -CurrentTest 'Complete' -Phase 'All Tests Complete'
        }
    }

    foreach ($step in $workflow.Steps) {
        if (-not $step.PSObject.Properties['Output']) {
            $step | Add-Member -NotePropertyName Output -NotePropertyValue $step.Detail -Force
        }
    }

    if ($script:HwStorageSkippedInRun -and $script:HwProfileName -eq 'Extended') {
        if ($workflow.OverallHealth -eq 'Healthy' -or [string]::IsNullOrWhiteSpace($workflow.OverallHealth)) {
            $workflow.OverallHealth = 'Warning'
        }
    }

    $null = Set-WorkflowOverallHealth -WorkflowResult $workflow

    $workflow | ConvertTo-Json -Depth 10 -Compress
    Generate-Report -WorkflowResult $workflow | Out-Null
} catch {
    Write-Error "Diag and Repair workflow failed: $($_.Exception.Message)"
    exit 1
}
