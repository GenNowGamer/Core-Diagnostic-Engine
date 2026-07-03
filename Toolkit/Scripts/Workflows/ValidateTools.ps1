#Requires -Version 5.1
<#
.SYNOPSIS
    Validates workflow scripts produce structured JSON reports under CDE\Runtime\Data\workflows.
#>
param(
    [string]$DataRoot = ''
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$coreModule = Join-Path $scriptDir '..\Core\Toolkit.Core.psm1'
Import-Module $coreModule -Force -DisableNameChecking

if ([string]::IsNullOrWhiteSpace($DataRoot)) {
    $DataRoot = Join-Path (Split-Path (Split-Path $scriptDir -Parent) -Parent) 'CDE\Runtime\Data\workflows'
    if (-not [string]::IsNullOrWhiteSpace($env:TOOLKIT_ROOT)) {
        $DataRoot = Join-Path $env:TOOLKIT_ROOT 'CDE\Runtime\Data\workflows'
    }
}

$saChecks = @(
    @{ CheckId = 'audit_system_info'; StepName = 'SystemInfo' }
    @{ CheckId = 'audit_installed_software'; StepName = 'InstalledSoftware' }
    @{ CheckId = 'audit_drivers'; StepName = 'Drivers' }
    @{ CheckId = 'audit_pnp_devices'; StepName = 'PnPDevices' }
    @{ CheckId = 'audit_services'; StepName = 'Services' }
    @{ CheckId = 'audit_startup'; StepName = 'StartupAudit' }
    @{ CheckId = 'audit_network_config'; StepName = 'NetworkConfig' }
    @{ CheckId = 'audit_event_logs'; StepName = 'EventLogs' }
    @{ CheckId = 'audit_partition_table'; StepName = 'PartitionTable' }
)
$secChecks = @(
    @{ CheckId = 'sec_autoruns'; StepName = 'AutorunsAudit' }
    @{ CheckId = 'sec_hosts'; StepName = 'HostsFile' }
    @{ CheckId = 'sec_browser_extensions'; StepName = 'BrowserExtensionScan' }
    @{ CheckId = 'sec_scheduled_tasks'; StepName = 'ScheduledTasksAudit' }
    @{ CheckId = 'sec_browser_hijack'; StepName = 'BrowserHijackAudit' }
    @{ CheckId = 'sec_network_hijack'; StepName = 'NetworkHijackAudit' }
    @{ CheckId = 'sec_security_tampering'; StepName = 'SecurityTamperingAudit' }
    @{ CheckId = 'sec_remote_access'; StepName = 'RemoteAccessAudit' }
)
$hijackTools = @('Scan', 'BrowserHijackRepair', 'NetworkHijackRepair', 'SecurityTamperingRepair', 'RepairAll')
$msTools = @('DefenderScan')
$extraTools = @(
    @{ Script = 'PostOp.ps1'; ToolName = 'DnsFlush'; WorkflowPrefix = 'PostOp' }
)

$stats = @{ Missing = 0; ParseError = 0; InvalidStructure = 0; Total = 0 }

function Test-WorkflowReportStructure {
    param($Report, [string]$ExpectedWorkflowPrefix)

    if ($null -eq $Report) { return $false }
    if (-not $Report.PSObject.Properties['Steps']) { return $false }
    $steps = @($Report.Steps)
    if ($steps.Count -eq 0) { return $false }
    foreach ($step in $steps) {
        if ([string]::IsNullOrWhiteSpace([string]$step.Name)) { return $false }
        if ([string]::IsNullOrWhiteSpace([string]$step.Status)) { return $false }
    }
    if ($Report.PSObject.Properties['Workflow'] -and $ExpectedWorkflowPrefix) {
        $wf = [string]$Report.Workflow
        if ($wf -notlike "$ExpectedWorkflowPrefix*") { return $false }
    }
    return $true
}

function Run-Tool {
    param(
        [string]$ScriptFile,
        [string]$ToolName,
        [string]$WorkflowPrefix,
        [string[]]$ExtraArgs = @()
    )

    Write-Host "Running $ScriptFile $ToolName..." -ForegroundColor Cyan
    $scriptPath = Join-Path $scriptDir $ScriptFile
    $filteredArgs = @($ExtraArgs | Where-Object { $null -ne $_ -and $_ -ne '' })
    if ($filteredArgs.Count -gt 0) {
        & $scriptPath @filteredArgs | Out-Null
    } else {
        & $scriptPath -ToolName $ToolName | Out-Null
    }

    $prefix = if ($WorkflowPrefix -eq 'SystemHealthCheck') { 'SystemHealthCheck' } else { "${WorkflowPrefix}_$ToolName" }
    if (-not (Test-Path -LiteralPath $DataRoot -PathType Container)) {
        Write-Host "  Error: Data root not found: $DataRoot" -ForegroundColor Red
        $stats.Missing++
        return
    }

    $file = Get-ChildItem -LiteralPath $DataRoot -Filter "$prefix*.json" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $file) {
        Write-Host "  Error: No report found for $prefix in $DataRoot" -ForegroundColor Red
        $stats.Missing++
        return
    }

    try {
        $json = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $stats.Total++
        if (-not (Test-WorkflowReportStructure -Report $json -ExpectedWorkflowPrefix $prefix)) {
            Write-Host "  Error: Invalid report structure in $($file.Name)" -ForegroundColor Red
            $stats.InvalidStructure++
            return
        }

        $steps = @($json.Steps)
        if ($ToolName -and $WorkflowPrefix -ne 'SystemHealthCheck') {
            $steps = @($steps | Where-Object { [string]$_.Name -eq $ToolName })
        }
        foreach ($step in $steps) {
            $len = if ($step.Output) { [string]$step.Output.Length } else { 0 }
            Write-Host "  [$($json.Workflow)] Step:$($step.Name)($($step.Status)) Len:$len"
        }
    } catch {
        Write-Host "  Error: Failed to parse $($file.Name) — $($_.Exception.Message)" -ForegroundColor Red
        $stats.ParseError++
    }
}

foreach ($check in $saChecks) {
    Run-Tool -ScriptFile 'SystemHealthCheck.ps1' -ToolName $check.StepName -WorkflowPrefix 'SystemHealthCheck' `
        -ExtraArgs @('-SelectedChecks', $check.CheckId)
}
foreach ($check in $secChecks) {
    Run-Tool -ScriptFile 'SystemHealthCheck.ps1' -ToolName $check.StepName -WorkflowPrefix 'SystemHealthCheck' `
        -ExtraArgs @('-SelectedChecks', $check.CheckId)
}
foreach ($t in $msTools) { Run-Tool -ScriptFile 'MalwareSweep.ps1' -ToolName $t -WorkflowPrefix 'MalwareSweep' }
foreach ($t in $hijackTools) { Run-Tool -ScriptFile 'HijackRepair.ps1' -ToolName $t -WorkflowPrefix 'HijackRepair' }
foreach ($entry in $extraTools) {
    Run-Tool -ScriptFile $entry.Script -ToolName $entry.ToolName -WorkflowPrefix $entry.WorkflowPrefix
}

Write-Host "`n--- SUMMARY ---" -ForegroundColor Cyan
$res = if ($stats.Missing -eq 0 -and $stats.ParseError -eq 0 -and $stats.InvalidStructure -eq 0) { 'PASS' } else { 'FAIL' }
Write-Host "Result: $res"
Write-Host "DataRoot: $DataRoot"
Write-Host "Total Reports: $($stats.Total)"
Write-Host "Missing: $($stats.Missing)"
Write-Host "Parse Errors: $($stats.ParseError)"
Write-Host "Invalid Structure: $($stats.InvalidStructure)"

if ($res -eq 'PASS') { exit 0 }
exit 1
