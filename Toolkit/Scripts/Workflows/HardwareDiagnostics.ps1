#Requires -Version 5.1
<#
.SYNOPSIS
    HardwareDiagnostics.ps1 - Diag and Repair suite: CPU, Memory, Storage, and CST security scan.
    Pass -ToolName to run a specific category, CstScan, or All (hardware plus CST).
#>

param(
    [string]$ToolName = 'All',
    [ValidateSet('Quick', 'Extended')]
    [string]$TestProfile = 'Quick',
    [switch]$ElevatedRelay
)

$ErrorActionPreference = 'Stop'

$Script:HardwareDiagnosticsScriptPath = $MyInvocation.MyCommand.Path
$ScriptDir  = Split-Path $Script:HardwareDiagnosticsScriptPath
$CoreDir    = Join-Path $ScriptDir '..\Core'
$CoreModule = Join-Path $CoreDir 'Toolkit.Core.psm1'
$ElevationModule = Join-Path $CoreDir 'Toolkit.Elevation.psm1'
Import-Module $CoreModule -Force -DisableNameChecking
Import-Module $ElevationModule -Force -DisableNameChecking
Import-Module (Join-Path $CoreDir 'HardwareTestCatalog.psm1') -Force -DisableNameChecking

. (Join-Path $CoreDir 'HardwareTestEngine.ps1')
. (Join-Path $CoreDir 'HardwareSmartEngine.ps1')
. (Join-Path $ScriptDir 'HardwareCommon.ps1')
. (Join-Path $ScriptDir 'HardwareCpuTests.ps1')
. (Join-Path $ScriptDir 'HardwareMemoryTests.ps1')
. (Join-Path $ScriptDir 'HardwareStorageTests.ps1')

$SecurityChecks = Join-Path $CoreDir 'SecurityAuditChecks.ps1'
if (Test-Path $SecurityChecks) { . $SecurityChecks }

function Get-HardwareDiagnosticsRelayArgumentString {
    $parts = [System.Collections.Generic.List[string]]::new()
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'ToolName' -Value $ToolName
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'TestProfile' -Value $TestProfile
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'ElevatedRelay' -IsSwitch
    return Join-ToolkitRelayArgumentString -Parts $parts
}

function Invoke-HardwareDiagnosticsElevationRelay {
    if ($ElevatedRelay) { return $false }
    if ($ToolName -notin @('StorageTests', 'All')) { return $false }
    if ((Get-EnvironmentMode) -eq 'WinPE') { return $false }
    if (-not (Test-ToolkitShouldRelayElevation -ElevatedRelay:$ElevatedRelay)) { return $false }

    try {
        $relay = Invoke-ToolkitElevatedRelay -ScriptPath $Script:HardwareDiagnosticsScriptPath `
            -ArgumentString (Get-HardwareDiagnosticsRelayArgumentString)
        if ($null -eq $relay) { return $false }
        if ($relay.ExitCode -ne 0) {
            Write-Log ("Elevated Diag and Repair exited with code {0}; continuing without elevation." -f $relay.ExitCode) -Level Warning
            return $false
        }
        return $true
    } catch {
        Write-Log ("Elevation canceled or failed ({0}); continuing without elevation. Storage physical reads may Warn." -f $_.Exception.Message) -Level Warning
        return $false
    }
}

function Write-HwGuidanceIfNeeded {
    $reasons = [System.Collections.Generic.List[string]]::new()
    if ($script:HwMemoryCoverageIncomplete) { [void]$reasons.Add('memory_coverage') }
    if ($script:HwCpuStressIncomplete) { [void]$reasons.Add('cpu_stress') }
    if ($script:HwStorageElevationWarn) { [void]$reasons.Add('storage_elevation') }
    if ($reasons.Count -eq 0) { return }

    $payload = @{
        recommendChu = $true
        reasons      = @($reasons)
    }
    Write-Host ("[HW:GUIDANCE] {0}" -f ($payload | ConvertTo-Json -Compress))
}

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

function Write-HardwareDiagnosticsRelayedJson {
    $dataRoot = Get-ToolkitWorkflowDataRoot
    if (-not (Test-Path -LiteralPath $dataRoot)) { return }

    $prefix = switch ($ToolName) {
        'CpuTests'     { 'HardwareDiag_CPU_' }
        'MemoryTests'  { 'HardwareDiag_Memory_' }
        'StorageTests' { 'HardwareDiag_Storage_' }
        'CstScan'      { 'HardwareDiag_CST_' }
        default        { 'HardwareDiag_All_' }
    }

    $latest = Get-ChildItem -LiteralPath $dataRoot -Filter ($prefix + '*.json') -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if (-not $latest) {
        $latest = Get-ChildItem -LiteralPath $dataRoot -Filter 'HardwareDiag_*.json' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 1
    }
    if ($latest) {
        # Success-stream emit so automation/tests capture JSON (transcript re-emit uses Write-Host).
        Get-Content -LiteralPath $latest.FullName -Raw
    }
}

try {
    if (Invoke-HardwareDiagnosticsElevationRelay) {
        Write-HardwareDiagnosticsRelayedJson
        exit 0
    }

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
            Write-HwGuidanceIfNeeded
        }
    }

    foreach ($step in $workflow.Steps) {
        if (-not $step.PSObject.Properties['Output']) {
            $step | Add-Member -NotePropertyName Output -NotePropertyValue $step.Detail -Force
        }
    }

    # Derive overall health from step statuses (Fail/Warn). When Extended failOnSkip
    # mapped soft skips to Fail, this yields Critical/Warning instead of Healthy.
    $null = Set-WorkflowOverallHealth -WorkflowResult $workflow

    # Safety net: if any fail-on-skip was recorded but steps somehow lacked Fail,
    # do not leave OverallHealth as Healthy (previous code set Warning then overwrite).
    if ($script:HwStorageSkippedInRun -and $script:HwProfileName -eq 'Extended') {
        if ($workflow.OverallHealth -eq 'Healthy' -or $workflow.OverallHealth -eq 'HealthyWithNotes' -or [string]::IsNullOrWhiteSpace($workflow.OverallHealth)) {
            $workflow.OverallHealth = 'Warning'
        }
    }

    $workflow | ConvertTo-Json -Depth 10 -Compress
    Generate-Report -WorkflowResult $workflow | Out-Null
} catch {
    Write-Error "Diag and Repair workflow failed: $($_.Exception.Message)"
    exit 1
}
