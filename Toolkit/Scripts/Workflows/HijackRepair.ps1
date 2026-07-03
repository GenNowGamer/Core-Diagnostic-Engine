#Requires -Version 5.1
<#
.SYNOPSIS
    HijackRepair.ps1 — Hijack scanner, selective repair, and bulk repair dispatcher.
#>
param(
    [string]$ToolName = 'All',
    [string]$FindingIds = '',
    [string]$SnapshotPath = '',
    [switch]$ElevatedRelay
)

$ErrorActionPreference = 'Stop'

$Script:HijackRepairScriptPath = $MyInvocation.MyCommand.Path
$ScriptDir  = Split-Path $Script:HijackRepairScriptPath
$CoreModule = Join-Path $ScriptDir '..\Core\Toolkit.Core.psm1'
$ElevationModule = Join-Path $ScriptDir '..\Core\Toolkit.Elevation.psm1'
$HelpersScript = Join-Path $ScriptDir '..\Core\HijackRepairHelpers.ps1'
$PostOpCleanupScript = Join-Path $ScriptDir '..\Core\PostOpCleanup.ps1'

Import-Module $CoreModule -Force -DisableNameChecking
Import-Module $ElevationModule -Force -DisableNameChecking
. $HelpersScript
. $PostOpCleanupScript

function Add-HijackRepairStep {
    param($r, [string]$StepName, $Result)
    $status = if ($Result.Status) { [string]$Result.Status } else { 'Pass' }
    $output = if ($Result.Output) { [string]$Result.Output } else { '' }
    $detailText = if ($Result.Details -and @($Result.Details).Count -gt 0) {
        ($Result.Details -join "`n")
    } else {
        $output
    }
    if ($detailText -and $detailText -ne $output) {
        $output = if ($output) { "$output`n`n$detailText" } else { $detailText }
    }
    Add-ToolkitWorkflowStep -WorkflowResult $r -Name $StepName -Status $status -Output $output
}

function Import-HijackRelayedWorkflowStep {
    param(
        $r,
        [Parameter(Mandatory)][string]$WorkflowName,
        [Parameter(Mandatory)][string]$StepName
    )

    Import-ToolkitRelayedWorkflowStep -WorkflowResult $r -WorkflowName $WorkflowName -StepName $StepName
}

function Import-HijackRelayedRepairSteps {
    param(
        $r,
        [Parameter(Mandatory)][string]$WorkflowName,
        [Parameter(Mandatory)][string[]]$StepNames
    )

    foreach ($stepName in $StepNames) {
        Import-HijackRelayedWorkflowStep -r $r -WorkflowName $WorkflowName -StepName $stepName
    }
}

function Invoke-HijackRepairElevationRelay {
    param([string]$Tool, [string]$ExtraArgs = '')
    if ($ElevatedRelay) { return $false }
    if (Test-ToolkitIsElevated) { return $false }
    $argString = "-ToolName $Tool -ElevatedRelay"
    if (-not [string]::IsNullOrWhiteSpace($ExtraArgs)) {
        $argString += " $ExtraArgs"
    }
    $relay = Invoke-ToolkitElevatedRelay -ScriptPath $Script:HijackRepairScriptPath -ArgumentString $argString
    if ($null -eq $relay) { return $false }
    if ($relay.ExitCode -ne 0) {
        throw "Elevated hijack repair failed (exit code $($relay.ExitCode))."
    }
    return $true
}

function Get-HijackRepairRelayExtraArgs {
    param([string]$Tool)
    $extra = @()
    if ($Tool -eq 'RepairSelected') {
        if (-not [string]::IsNullOrWhiteSpace($FindingIds)) {
            $extra += "-FindingIds `"$FindingIds`""
        }
        if (-not [string]::IsNullOrWhiteSpace($SnapshotPath)) {
            $extra += "-SnapshotPath `"$SnapshotPath`""
        }
    }
    return ($extra -join ' ')
}

function Invoke-HijackScanWorkflow {
    param($r)
    Write-Log 'Running hijack scanner...'
    Write-CdeEvent -Payload @{ type = 'progress'; tool = 'HijackRepair'; step = 'Scan'; pct = 0; message = 'Starting hijack scan' }
    $findings = @(Invoke-HijackEmitScan)
    $flagged = @($findings | Where-Object { $_.isFlagged }).Count
    $detailLines = @(
        $findings |
            Where-Object { $_.isFlagged } |
            ForEach-Object {
                $location = if ([string]::IsNullOrWhiteSpace($_.location)) { 'n/a' } else { [string]$_.location }
                "[$($_.severity)] $($_.category)/$($_.name) @ $location"
            }
    )
    $summary = "Hijack scan complete: $($findings.Count) item(s), $flagged flagged."
    Write-Log $summary
    Add-HijackRepairStep -r $r -StepName 'HijackScan' -Result @{
        Status  = if ($flagged -gt 0) { 'Warn' } else { 'Pass' }
        Output  = $summary
        Details = $detailLines
    }
}

function Invoke-HijackRepairSelectedWorkflow {
    param($r)
    $ids = @(
        $FindingIds -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($ids.Count -eq 0) {
        Add-HijackRepairStep -r $r -StepName 'RepairSelected' -Result @{
            Status  = 'Warn'
            Output  = 'No finding IDs were supplied for repair.'
            Details = @()
        }
        return
    }

    $relayExtra = Get-HijackRepairRelayExtraArgs -Tool 'RepairSelected'
    if (Invoke-HijackRepairElevationRelay -Tool 'RepairSelected' -ExtraArgs $relayExtra) {
        Import-HijackRelayedWorkflowStep -r $r -WorkflowName 'HijackRepair_RepairSelected' -StepName 'RepairSelected'
        return
    }

    Write-Log "Repairing $($ids.Count) selected finding(s)..."
    $result = Invoke-HijackRepairSelectedFindings -FindingIds $ids -SnapshotPath $SnapshotPath
    Add-HijackRepairStep -r $r -StepName 'RepairSelected' -Result $result
    Write-Log 'Re-scanning after repair...'
    Invoke-HijackEmitScan -SnapshotPath $SnapshotPath | Out-Null
}

function Invoke-BrowserHijackRepair {
    param($r, [switch]$SkipRescan)
    if (Invoke-HijackRepairElevationRelay -Tool 'BrowserHijackRepair') {
        Import-HijackRelayedWorkflowStep -r $r -WorkflowName 'HijackRepair_BrowserHijackRepair' -StepName 'BrowserHijackRepair'
        return
    }
    Write-Log 'Repairing browser homepage, search, and policy hijacks...'
    $result = Invoke-HijackBrowserRepair
    Add-HijackRepairStep -r $r -StepName 'BrowserHijackRepair' -Result $result
    if (-not $SkipRescan) {
        Write-Log 'Re-scanning after browser repair...'
        Invoke-HijackEmitScan | Out-Null
    }
}

function Invoke-NetworkHijackRepair {
    param($r, [switch]$SkipRescan)
    if (Invoke-HijackRepairElevationRelay -Tool 'NetworkHijackRepair') {
        Import-HijackRelayedWorkflowStep -r $r -WorkflowName 'HijackRepair_NetworkHijackRepair' -StepName 'NetworkHijackRepair'
        return
    }
    Write-Log 'Repairing network DNS, proxy, and NRPT hijacks...'
    $result = Invoke-HijackNetworkRepair
    Add-HijackRepairStep -r $r -StepName 'NetworkHijackRepair' -Result $result
    if (-not $SkipRescan) {
        Write-Log 'Re-scanning after network repair...'
        Invoke-HijackEmitScan | Out-Null
    }
}

function Invoke-SecurityTamperingRepair {
    param($r, [switch]$SkipRescan)
    if (Invoke-HijackRepairElevationRelay -Tool 'SecurityTamperingRepair') {
        Import-HijackRelayedWorkflowStep -r $r -WorkflowName 'HijackRepair_SecurityTamperingRepair' -StepName 'SecurityTamperingRepair'
        return
    }
    Write-Log 'Restoring Defender, firewall, UAC, and SmartScreen defaults...'
    $result = Invoke-HijackSecurityTamperingRepair
    Add-HijackRepairStep -r $r -StepName 'SecurityTamperingRepair' -Result $result
    if (-not $SkipRescan) {
        Write-Log 'Re-scanning after security repair...'
        Invoke-HijackEmitScan | Out-Null
    }
}

function Invoke-HijackRepairBundle {
    param($r)
    if (Invoke-HijackRepairElevationRelay -Tool 'RepairAll') {
        Import-HijackRelayedRepairSteps -r $r -WorkflowName 'HijackRepair_RepairAll' -StepNames @(
            'BrowserHijackRepair', 'NetworkHijackRepair', 'SecurityTamperingRepair'
        )
        return
    }
    Write-Log 'Running full hijack repair bundle...'
    Invoke-BrowserHijackRepair $r -SkipRescan
    Invoke-NetworkHijackRepair $r -SkipRescan
    Invoke-SecurityTamperingRepair $r -SkipRescan
    Write-Log 'Hijack repair bundle complete.'
    Invoke-HijackEmitScan | Out-Null
}

$workflowName = switch ($ToolName) {
    'Scan' { 'HijackRepair_Scan' }
    'RepairSelected' { 'HijackRepair_RepairSelected' }
    default { if ($ToolName -eq 'All') { 'HijackRepair_All' } else { "HijackRepair_$ToolName" } }
}

try {
    $workflow = Start-Workflow -WorkflowName $workflowName -ScriptBlock {
        param($r)
        switch ($ToolName) {
            'Scan'                     { Invoke-HijackScanWorkflow $r }
            'RepairSelected'           { Invoke-HijackRepairSelectedWorkflow $r }
            'BrowserHijackRepair'      { Invoke-BrowserHijackRepair $r }
            'NetworkHijackRepair'      { Invoke-NetworkHijackRepair $r }
            'SecurityTamperingRepair'  { Invoke-SecurityTamperingRepair $r }
            'RepairAll'                { Invoke-HijackRepairBundle $r }
            default                    { Invoke-HijackRepairBundle $r }
        }
    }

    Generate-Report -WorkflowResult $workflow -IncludeHtml | Out-Null
} catch {
    Write-Error "HijackRepair workflow failed: $($_.Exception.Message)"
    exit 1
}
