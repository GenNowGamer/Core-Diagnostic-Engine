#Requires -Version 5.1
<#
.SYNOPSIS
    Local non-destructive regression entry point for CDE Phase 1 checks.
.PARAMETER IncludeWorkflowSmoke
    Also runs read-only workflow smoke tests (longer).
#>

param(
    [switch]$IncludeWorkflowSmoke
)

$ErrorActionPreference = 'Stop'

$testsRoot = Split-Path $MyInvocation.MyCommand.Path
$workflowsRoot = Join-Path $testsRoot '..\Workflows'
$results = [System.Collections.Generic.List[object]]::new()

function Invoke-Tier {
    param(
        [string]$Name,
        [string]$ScriptPath,
        [string[]]$ArgumentList = @()
    )

    Write-Host "`n=== $Name ===" -ForegroundColor Cyan
    try {
        & $ScriptPath @ArgumentList
        if ($LASTEXITCODE -ne 0) {
            $results.Add([PSCustomObject]@{ Tier = $Name; Status = 'FAIL' }) | Out-Null
            return
        }
        $results.Add([PSCustomObject]@{ Tier = $Name; Status = 'PASS' }) | Out-Null
    } catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        $results.Add([PSCustomObject]@{ Tier = $Name; Status = 'FAIL' }) | Out-Null
    }
}

function Invoke-WorkflowSmoke {
    param(
        [string]$Name,
        [string]$Script,
        [hashtable]$ArgumentList = @{}
    )

    Write-Host "`n--- Smoke: $Name ---" -ForegroundColor DarkCyan
    try {
        & $Script @ArgumentList | Out-Null
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            throw "Exit code $LASTEXITCODE"
        }
        $results.Add([PSCustomObject]@{ Tier = "Smoke:$Name"; Status = 'PASS' }) | Out-Null
        Write-Host "PASS: $Name" -ForegroundColor Green
    } catch {
        Write-Host "FAIL: $Name - $($_.Exception.Message)" -ForegroundColor Red
        $results.Add([PSCustomObject]@{ Tier = "Smoke:$Name"; Status = 'FAIL' }) | Out-Null
    }
}

Invoke-Tier -Name 'Unit: Workflow health semantics' -ScriptPath (Join-Path $testsRoot 'Test-WorkflowHealthSemantics.ps1')
Invoke-Tier -Name 'Unit: Health findings + event clusters' -ScriptPath (Join-Path $testsRoot 'Test-HealthFindingsAndEventClusters.ps1')
Invoke-Tier -Name 'Unit: Health check catalog' -ScriptPath (Join-Path $testsRoot 'Test-HealthCheckCatalog.ps1')
Invoke-Tier -Name 'Unit: Symptom flows catalog' -ScriptPath (Join-Path $testsRoot 'Test-SymptomFlowsCatalog.ps1')
Invoke-Tier -Name 'Unit: Health check output detail' -ScriptPath (Join-Path $testsRoot 'Test-HealthCheckOutputDetail.ps1')
Invoke-Tier -Name 'Unit: Health check grouped output' -ScriptPath (Join-Path $testsRoot 'Test-HealthCheckGroupedOutput.ps1')
Invoke-Tier -Name 'Unit: Skipped health checks regression' -ScriptPath (Join-Path $testsRoot 'Test-SkippedHealthChecks.ps1')
Invoke-Tier -Name 'Unit: Audit check robustness' -ScriptPath (Join-Path $testsRoot 'Test-AuditCheckRobustness.ps1')
Invoke-Tier -Name 'Unit: Installed software format' -ScriptPath (Join-Path $testsRoot 'Test-InstalledSoftwareFormat.ps1')
Invoke-Tier -Name 'Unit: Security audit output format' -ScriptPath (Join-Path $testsRoot 'Test-SecurityAuditOutputFormat.ps1')
Invoke-Tier -Name 'Unit: System health check' -ScriptPath (Join-Path $testsRoot 'Test-SystemHealthCheck.ps1')
Invoke-Tier -Name 'Unit: System health check presets' -ScriptPath (Join-Path $testsRoot 'Test-SystemHealthCheckPresets.ps1')
Invoke-Tier -Name 'Unit: Hardware diagnostics JSON' -ScriptPath (Join-Path $testsRoot 'Test-HardwareDiagnosticsJson.ps1')
Invoke-Tier -Name 'Unit: CPU SIMD PS5 load' -ScriptPath (Join-Path $testsRoot 'Test-CpuSimdEnginePs5.ps1')
Invoke-Tier -Name 'Unit: Hardware test catalog sync' -ScriptPath (Join-Path $testsRoot 'Test-HardwareTestCatalogSync.ps1')
Invoke-Tier -Name 'Unit: Work order case events' -ScriptPath (Join-Path $testsRoot 'Test-WorkOrderCaseEvents.ps1')
Invoke-Tier -Name 'Unit: CST structured results' -ScriptPath (Join-Path $testsRoot 'Test-CstStructuredResults.ps1')
Invoke-Tier -Name 'Unit: Hardware diagnostics CST' -ScriptPath (Join-Path $testsRoot 'Test-HardwareDiagnosticsCst.ps1')
Invoke-Tier -Name 'Unit: Hardware storage drive labels' -ScriptPath (Join-Path $testsRoot 'Test-HardwareStorageDriveLabels.ps1')
Invoke-Tier -Name 'Unit: Hardware storage targeted read' -ScriptPath (Join-Path $testsRoot 'Test-HardwareStorageTargetedRead.ps1')
Invoke-Tier -Name 'Unit: Physical disk catalog' -ScriptPath (Join-Path $testsRoot 'Test-PhysicalDiskCatalog.ps1')
Invoke-Tier -Name 'Unit: Event grouping' -ScriptPath (Join-Path $testsRoot 'Test-GroupWorkflowEvents.ps1')
Invoke-Tier -Name 'Unit: Resolve startup target' -ScriptPath (Join-Path $testsRoot 'Test-ResolveStartupTarget.ps1')
Invoke-Tier -Name 'Unit: MSIX startup tasks' -ScriptPath (Join-Path $testsRoot 'Test-MsixStartupTasks.ps1')
Invoke-Tier -Name 'Unit: Startup Manager coverage' -ScriptPath (Join-Path $testsRoot 'Test-StartupManagerCoverage.ps1')
Invoke-Tier -Name 'Unit: Post-Op cleanup helpers' -ScriptPath (Join-Path $testsRoot 'Test-PostOpCleanup.ps1')
Invoke-Tier -Name 'Unit: Hijack repair helpers' -ScriptPath (Join-Path $testsRoot 'Test-HijackRepairHelpers.ps1')
Invoke-Tier -Name 'Unit: Process analyzer risk/network' -ScriptPath (Join-Path $testsRoot 'Test-ProcessAnalyzerRiskAndNetwork.ps1')
Invoke-Tier -Name 'Unit: Offline hosts path' -ScriptPath (Join-Path $testsRoot 'Test-OfflineHostsPath.ps1')
Invoke-Tier -Name 'Unit: Environment capability matrix' -ScriptPath (Join-Path $testsRoot 'Test-EnvironmentCapabilityMatrix.ps1')
Invoke-Tier -Name 'Unit: Symptom flows E2E' -ScriptPath (Join-Path $testsRoot 'Test-SymptomFlowsE2E.ps1')
Invoke-Tier -Name 'Unit: Toolkit elevation' -ScriptPath (Join-Path $testsRoot 'Test-ToolkitElevation.ps1')
Invoke-Tier -Name 'Unit: Bootloader common' -ScriptPath (Join-Path $testsRoot 'Test-BootloaderCommon.ps1')
Invoke-Tier -Name 'Unit: Shadow copy browse' -ScriptPath (Join-Path $testsRoot 'Test-ShadowCopyBrowse.ps1')
Invoke-Tier -Name 'Unit: Offline SAM crypto' -ScriptPath (Join-Path $workflowsRoot 'Test-OfflineSamCrypto.ps1')
Invoke-Tier -Name 'Unit: Startup audit review UX' -ScriptPath (Join-Path $testsRoot 'Test-StartupAuditReviewUx.ps1')
Invoke-Tier -Name 'Syntax: All Scripts/*.ps1' -ScriptPath (Join-Path $testsRoot 'Test-ScriptSyntax.ps1')

if ($IncludeWorkflowSmoke) {
    Write-Host "`n=== Read-only workflow smoke ===" -ForegroundColor Cyan
    Invoke-WorkflowSmoke -Name 'FastFixes List' -Script (Join-Path $workflowsRoot 'FastFixes.ps1') -ArgumentList @{ Action = 'List' }
    Invoke-WorkflowSmoke -Name 'TempFileCleaner Scan' -Script (Join-Path $workflowsRoot 'TempFileCleaner.ps1') -ArgumentList @{ Action = 'Scan' }
    Invoke-WorkflowSmoke -Name 'SystemHealthCheck quick_vitals' -Script (Join-Path $workflowsRoot 'SystemHealthCheck.ps1') -ArgumentList @{ Preset = 'quick_vitals' }
    Invoke-WorkflowSmoke -Name 'SystemHealthCheck deep_system' -Script (Join-Path $workflowsRoot 'SystemHealthCheck.ps1') -ArgumentList @{ Preset = 'deep_system' }
    Invoke-WorkflowSmoke -Name 'SystemHealthCheck system_info' -Script (Join-Path $workflowsRoot 'SystemHealthCheck.ps1') -ArgumentList @{ SelectedChecks = 'system_info' }
    Invoke-WorkflowSmoke -Name 'SmartAnalyzer Query' -Script (Join-Path $workflowsRoot 'SmartAnalyzer.ps1') -ArgumentList @{ Mode = 'Query' }
}

Write-Host "`n=== REGRESSION SUMMARY ===" -ForegroundColor Cyan
$results | Format-Table -AutoSize
$failed = @($results | Where-Object { $_.Status -ne 'PASS' }).Count
if ($failed -gt 0) {
    Write-Host "Result: FAIL ($failed tier(s))" -ForegroundColor Red
    exit 1
}

Write-Host 'Result: PASS' -ForegroundColor Green
exit 0
