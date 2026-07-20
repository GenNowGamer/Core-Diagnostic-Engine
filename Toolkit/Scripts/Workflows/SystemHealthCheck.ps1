#Requires -Version 5.1
<#
.SYNOPSIS
    SystemHealthCheck.ps1 — Run selected diagnostic checks and produce a unified health report.
#>

param(
    [string]$SelectedChecks = '',
    [string[]]$CheckIds = @(),
    [string]$Preset = ''
)

$ErrorActionPreference = 'Stop'

$WorkflowsDir = Split-Path $MyInvocation.MyCommand.Path
$CoreDir      = Join-Path $WorkflowsDir '..\Core'
$CoreModule   = Join-Path $CoreDir 'Toolkit.Core.psm1'

Import-Module $CoreModule -Force -DisableNameChecking
. (Join-Path $CoreDir 'HealthFindings.ps1')
. (Join-Path $CoreDir 'EventFindingClusters.ps1')
. (Join-Path $CoreDir 'HealthFindingCorroboration.ps1')
. (Join-Path $CoreDir 'DriverFilterAllowlist.ps1')
. (Join-Path $CoreDir 'HealthChecks.ps1')
. (Join-Path $CoreDir 'SystemAuditChecks.ps1')
. (Join-Path $CoreDir 'SecurityAuditChecks.ps1')
. (Join-Path $CoreDir 'HijackRepairChecks.ps1')
. (Join-Path $CoreDir 'HealthCheckOrchestrator.ps1')
. (Join-Path $CoreDir 'MachineBaseline.ps1')

$catalog = Get-HealthCheckCatalog
$validIds = Get-HealthCheckCatalogIds -Catalog $catalog

$hasExplicitChecks = ($CheckIds -and $CheckIds.Count -gt 0) -or (-not [string]::IsNullOrWhiteSpace($SelectedChecks))
if (-not [string]::IsNullOrWhiteSpace($Preset) -and $hasExplicitChecks) {
    Write-Error 'Cannot combine -Preset with -SelectedChecks or -CheckIds.'
    exit 1
}

$selected = [System.Collections.Generic.List[string]]::new()
if (-not [string]::IsNullOrWhiteSpace($Preset)) {
    $presetProp = $catalog.presets.PSObject.Properties[$Preset]
    if (-not $presetProp) {
        Write-Error "Unknown health check preset: $Preset"
        exit 1
    }

    foreach ($id in @($presetProp.Value)) {
        if (-not [string]::IsNullOrWhiteSpace($id)) { $selected.Add([string]$id) }
    }

    if ($selected.Count -eq 0) {
        Write-Error "Health check preset '$Preset' is empty."
        exit 1
    }
}
elseif ($CheckIds -and $CheckIds.Count -gt 0) {
    foreach ($id in $CheckIds) {
        if (-not [string]::IsNullOrWhiteSpace($id)) { $selected.Add($id.Trim()) }
    }
}
elseif (-not [string]::IsNullOrWhiteSpace($SelectedChecks)) {
    foreach ($part in ($SelectedChecks -split ',')) {
        if (-not [string]::IsNullOrWhiteSpace($part)) { $selected.Add($part.Trim()) }
    }
}

$uniqueSelected = [System.Collections.Generic.List[string]]::new()
$seen = @{}
foreach ($id in $selected) {
    # Fold legacy duplicate into Deep System's System Information check.
    if ($id -eq 'audit_system_info') {
        $id = 'system_info'
    }
    if ($seen.ContainsKey($id)) { continue }
    $seen[$id] = $true
    if (-not $validIds.Contains($id)) {
        Write-Warning "Unknown health check id ignored: $id"
        continue
    }
    $uniqueSelected.Add($id)
}

if ($uniqueSelected.Count -eq 0) {
    Write-Error 'No valid health checks selected.'
    exit 1
}

$healthDispatch = Get-HealthCheckStepDispatchMap
$auditDispatch  = Get-SystemAuditCheckDispatchMap
$securityDispatch = Get-SecurityAuditCheckDispatchMap
$hijackDispatch = Get-HijackRepairCheckDispatchMap

$ctx = @{ WorkflowsDir = $WorkflowsDir }

# CST scan-only for health check orchestration
$script:CstMode = 'ThreatScan'
$script:CstDetectionScope = 'All'
$script:CstActionMode = 'ScanOnly'

$workflow = Start-Workflow -WorkflowName 'SystemHealthCheck' -ScriptBlock {
    param($r)

    $total = $uniqueSelected.Count
    $index = 0

    foreach ($checkId in $uniqueSelected) {
        $index++
        $label = Get-HealthCheckLabel -Catalog $catalog -CheckId $checkId
        $pct = [math]::Min(100, [math]::Floor(($index / [math]::Max($total, 1)) * 100))
        Write-CdeEvent -Payload @{
            type    = 'progress'
            tool    = 'SystemHealthCheck'
            step    = $checkId
            pct     = $pct
            message = $label
        }
        Write-HealthPhaseLine -CheckId $checkId -Label $label -Index $index -Total $total
        Write-Log "Running health check [$index/$total]: $checkId ($label)"

        $before = $r.Steps.Count

        if ($healthDispatch.ContainsKey($checkId)) {
            & $healthDispatch[$checkId] $r $ctx
        }
        elseif ($auditDispatch.ContainsKey($checkId)) {
            & $auditDispatch[$checkId] $r
            Add-CheckIdToNewSteps -WorkflowResult $r -BeforeCount $before -CheckId $checkId
        }
        elseif ($securityDispatch.ContainsKey($checkId)) {
            & $securityDispatch[$checkId] $r
            Add-CheckIdToNewSteps -WorkflowResult $r -BeforeCount $before -CheckId $checkId
        }
        elseif ($hijackDispatch.ContainsKey($checkId)) {
            & $hijackDispatch[$checkId] $r
            Add-CheckIdToNewSteps -WorkflowResult $r -BeforeCount $before -CheckId $checkId
        }
        else {
            $r.Steps.Add([PSCustomObject]@{
                Name    = $checkId
                Status  = 'Skip'
                Detail  = "No dispatcher registered for check: $checkId"
                Output  = "No dispatcher registered for check: $checkId"
                CheckId = $checkId
            })
        }

        Invoke-HealthCheckRecommendations -WorkflowResult $r -Catalog $catalog -FromStepIndex $before
    }

    $corroborated = Invoke-HealthFindingCorroboration -WorkflowResult $r
    if ($corroborated -gt 0) {
        Write-Log "Corroboration pass adjusted $corroborated finding(s)."
    }

    $calibrated = Invoke-HealthFindingConfidenceCalibration -WorkflowResult $r
    if ($calibrated -gt 0) {
        Write-Log "Confidence calibration adjusted $calibrated finding(s)."
    }

    try {
        $deltaCount = Add-HealthBaselineDeltaFindings -WorkflowResult $r
        if ($deltaCount -gt 0) {
            Write-Log "Baseline delta attached $deltaCount finding(s)."
        }
        $baselinePath = Save-CdeMachineBaselineFromWorkflow -WorkflowResult $r
        Write-Log "Machine baseline saved: $baselinePath"
    }
    catch {
        Write-Log ("Baseline store skipped: {0}" -f $_.Exception.Message) -Level Warning
    }

    $overallHealth = Set-WorkflowOverallHealth -WorkflowResult $r
    Write-Log "System Health Check complete. Overall: $overallHealth"
}

try {
    Normalize-WorkflowStepOutput -WorkflowResult $workflow
    $workflow | ConvertTo-Json -Depth 12
    Generate-Report -WorkflowResult $workflow | Out-Null
} catch {
    Write-Error "SystemHealthCheck workflow failed: $($_.Exception.Message)"
    exit 1
}
