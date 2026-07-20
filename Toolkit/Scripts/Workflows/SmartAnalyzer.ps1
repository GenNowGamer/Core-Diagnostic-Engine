#Requires -Version 5.1
<#
.SYNOPSIS
    Core Diagnostic Engine - native S.M.A.R.T. Attribute Analyzer.

.DESCRIPTION
    Reads true S.M.A.R.T. data directly from storage devices using native
    Windows DeviceIoControl APIs (no third-party tools). Supports:
      - SATA / ATA drives via IOCTL_ATA_PASS_THROUGH (SMART READ DATA / THRESHOLDS / STATUS)
      - NVMe drives via IOCTL_STORAGE_QUERY_PROPERTY (NVMe SMART/Health log page 0x02)
      - USB bridges via best-effort ATA pass-through (SAT)
    Runs from full Windows and WinPE (the GUI hosts PowerShell 7 in-process, so
    Add-Type uses bundled Roslyn; powershell.exe -File mode uses NetFx csc).

.PARAMETER Mode
    Query  - emit compact JSON of all drives to stdout (used by the GUI grid).
    Report - run as a full workflow and generate JSON + HTML reports to the Logs root.
#>
param(
    [ValidateSet('Query', 'Report')]
    [string]$Mode = 'Report'
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path $MyInvocation.MyCommand.Path
$CoreDir = Join-Path $ScriptDir '..\Core'

. (Join-Path $CoreDir 'HardwareSmartEngine.ps1')

if ($Mode -eq 'Query') {
    $drives = Get-CdeSmartDrives
    [PSCustomObject]@{ Drives = @($drives) } | ConvertTo-Json -Depth 6
    return
}

# --- Report mode: full workflow with JSON + HTML report ---
$CoreModule = Join-Path $ScriptDir '..\Core\Toolkit.Core.psm1'
Import-Module $CoreModule -Force -DisableNameChecking
. (Join-Path $CoreDir 'MachineBaseline.ps1')

$workflow = Start-Workflow -WorkflowName 'SmartAnalyzer' -ScriptBlock {
    param($r)

    $drives = Get-CdeSmartDrives

    if (@($drives).Count -eq 0) {
        $r.Steps.Add([PSCustomObject]@{
            Name   = 'Storage Devices'
            Status = 'Warn'
            Detail = 'No physical drives detected or access denied.'
            Data   = $null
        })
        return
    }

    foreach ($d in $drives) {
        $status = if (-not $d.Supported) {
            'Skip'
        } else {
            switch ($d.Overall) {
                'Fail'  { 'Fail' }
                'Warn'  { 'Warn' }
                'Pass'  { 'Pass' }
                default { 'Warn' }
            }
        }
        $temp = if ($d.TemperatureC -ge 0) { "$($d.TemperatureC)C" } else { 'N/A' }
        $detail = "$($d.Model) [$($d.Bus)] $($d.SizeGB)GB - Health: $($d.Overall), Temp: $temp"
        if (-not $d.Supported -and $d.Note) { $detail = "$($d.Model) [$($d.Bus)] - $($d.Note)" }

        $r.Steps.Add([PSCustomObject]@{
            Name   = "Drive $($d.Index): $($d.Model)"
            Status = $status
            Detail = $detail
            Data   = $d
        })
    }
}

try {
    foreach ($step in $workflow.Steps) {
        if (-not $step.PSObject.Properties['Output']) {
            $step | Add-Member -NotePropertyName Output -NotePropertyValue $step.Detail -Force
        }
    }

    $null = Set-WorkflowOverallHealth -WorkflowResult $workflow

    try {
        $baselinePath = Save-CdeMachineBaselineFromWorkflow -WorkflowResult $workflow
        Write-Log "SMART machine baseline saved: $baselinePath"
    }
    catch {
        Write-Log ("SMART baseline store skipped: {0}" -f $_.Exception.Message) -Level Warning
    }

    # Emit markers on the success stream so the GUI (RedirectStandardOutput) can
    # locate the JSON deliverable. Write-Host / Write-Log alone are not reliably captured.
    $paths = Generate-Report -WorkflowResult $workflow
    Write-Output "Report saved: $($paths.JsonPath)"
    if (Test-Path -LiteralPath $paths.JsonPath) {
        Get-Content -LiteralPath $paths.JsonPath -Raw
    }
}
catch {
    Write-Error "SmartAnalyzer report failed: $($_.Exception.Message)"
    exit 1
}
