#Requires -Version 5.1
<#
.SYNOPSIS
    Security audit check functions used by SystemHealthCheck.ps1. Malware cleanup workflows use Defender/CST helpers from this module.
#>

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $MyInvocation.MyCommand.Path }
$WorkflowsDir = Join-Path $ScriptDir '..\Workflows'
$StartupRiskScript = Join-Path $ScriptDir 'StartupRisk.ps1'
$StartupScheduledTaskScript = Join-Path $ScriptDir 'StartupScheduledTask.ps1'
$HijackHelpersScript = Join-Path $ScriptDir 'HijackRepairHelpers.ps1'
if (Test-Path $StartupRiskScript) { . $StartupRiskScript }
if (Test-Path $StartupScheduledTaskScript) { . $StartupScheduledTaskScript }
if (Test-Path $HijackHelpersScript) { . $HijackHelpersScript }
function Resolve-CoreSecurityToolPath {
    $candidates = @()

    if (-not [string]::IsNullOrWhiteSpace($env:TOOLKIT_ROOT)) {
        $candidates += (Join-Path $env:TOOLKIT_ROOT 'Security\CST\CoreSecurityTool.ps1')
    }
    $candidates += (Join-Path $ScriptDir '..\..\Security\CST\CoreSecurityTool.ps1')

    # Walk up to app builds root only if path depth allows (fails safely on USB roots)
    try {
        $p1 = Split-Path $ScriptDir -Parent
        $p2 = if ($p1) { Split-Path $p1 -Parent } else { $null }
        $p3 = if ($p2) { Split-Path $p2 -Parent } else { $null }
        $appBuildsRoot = if ($p3) { Split-Path $p3 -Parent } else { $null }
        if (-not [string]::IsNullOrWhiteSpace($appBuildsRoot)) {
            $candidates += (Join-Path $appBuildsRoot 'Core Security Tool\CST\CoreSecurityTool.ps1')
        }
    } catch { }

    foreach ($path in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path $path)) {
            return $path
        }
    }

    return $null
}

function Resolve-CdeBehaviorCollectorPath {
    $candidates = @()

    if (-not [string]::IsNullOrWhiteSpace($env:TOOLKIT_ROOT)) {
        $root = $env:TOOLKIT_ROOT.TrimEnd('\', '/')
        $candidates += (Join-Path $root 'CDE\ToolkitGUI\bin\Release\net8.0-windows\CdeBehaviorCollector.exe')
        $candidates += (Join-Path $root 'App\ToolkitGUI\bin\Release\net8.0-windows\CdeBehaviorCollector.exe')
    }

    $toolkitRoot = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir '..\..'))
    $candidates += (Join-Path $toolkitRoot 'CDE\ToolkitGUI\bin\Release\net8.0-windows\CdeBehaviorCollector.exe')
    $candidates += (Join-Path $toolkitRoot 'App\ToolkitGUI\bin\Release\net8.0-windows\CdeBehaviorCollector.exe')

    try {
        $p1 = Split-Path $ScriptDir -Parent
        $p2 = if ($p1) { Split-Path $p1 -Parent } else { $null }
        $p3 = if ($p2) { Split-Path $p2 -Parent } else { $null }
        $appBuildsRoot = if ($p3) { Split-Path $p3 -Parent } else { $null }
        if (-not [string]::IsNullOrWhiteSpace($appBuildsRoot)) {
            $candidates += (Join-Path $appBuildsRoot 'Core Diagnostic Engine\Toolkit\App\ToolkitGUI\bin\Release\net8.0-windows\CdeBehaviorCollector.exe')
        }
    } catch { }

    foreach ($path in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            return $path
        }
    }

    return $null
}

function Invoke-CdeBehaviorTelemetryCollection {
    param(
        [Parameter(Mandatory)][string]$OutputPath,
        [double]$SinceHours = 24,
        [int]$MaxEvents = 32
    )

    $collectorPath = Resolve-CdeBehaviorCollectorPath
    if (-not $collectorPath) {
        return [PSCustomObject]@{
            status = 'Unavailable'
            collectorPath = ''
            outputPath = ''
            artifactCount = 0
            channelCount = 0
            message = 'CdeBehaviorCollector.exe not found in expected runtime paths.'
        }
    }

    $outputDir = Split-Path -Path $OutputPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($outputDir) -and -not (Test-Path -LiteralPath $outputDir)) {
        New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
    }

    $collectorOutput = @(& $collectorPath collect --output $OutputPath --since-hours $SinceHours --max-events $MaxEvents 2>&1)
    if ($LASTEXITCODE -ne 0) {
        return [PSCustomObject]@{
            status = 'Error'
            collectorPath = $collectorPath
            outputPath = $OutputPath
            artifactCount = 0
            channelCount = 0
            message = (($collectorOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
        }
    }

    $artifactCount = 0
    $channelCount = 0
    $status = 'Collected'
    $message = 'Behavior telemetry bundle created.'
    if (Test-Path -LiteralPath $OutputPath -PathType Leaf) {
        try {
            $payload = Get-Content -LiteralPath $OutputPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $artifactCount = @($payload.artifacts).Count
            $channelCount = @($payload.channels).Count
            if ($artifactCount -eq 0) {
                $status = 'NoArtifacts'
                $message = 'Behavior telemetry bundle created, but no qualifying events were present.'
            }
        } catch {
            $status = 'Warn'
            $message = "Behavior telemetry bundle created, but could not be summarized: $($_.Exception.Message)"
        }
    }

    return [PSCustomObject]@{
        status = $status
        collectorPath = $collectorPath
        outputPath = $OutputPath
        artifactCount = $artifactCount
        channelCount = $channelCount
        message = $message
    }
}

function Resolve-CstWinPeScanRoot {
    $offlineRoot = [string]$env:OFFLINE_WINDOWS_ROOT
    if (-not [string]::IsNullOrWhiteSpace($offlineRoot)) {
        $trimmed = $offlineRoot.Trim().TrimEnd('\', '/') + '\'
        if (Test-Path -LiteralPath (Join-Path $trimmed 'Windows\System32') -ErrorAction SilentlyContinue) {
            return $trimmed
        }
    }

    for ($code = [int][char]'C'; $code -le [int][char]'Z'; $code++) {
        $drive = [char]$code
        if ($drive -eq 'X') { continue }
        $root = "$drive`:\"
        if (Test-Path -LiteralPath (Join-Path $root 'Windows\System32') -ErrorAction SilentlyContinue) {
            return $root
        }
    }

    return $null
}

function Invoke-CoreSecurityTool {
    param($r)

    Write-Log "Running Core Security Tool ($CstMode)..."
    $behaviorTelemetry = $null
    try {
        $effectiveActionMode = $CstActionMode
        if ($effectiveActionMode -in @('ScanAndRemove', 'ScanAndQuarantine')) {
            $confirmDestructive = $false
            if (Get-Variable -Name ConfirmDestructiveActionMode -ErrorAction SilentlyContinue) {
                $confirmDestructive = [bool]$ConfirmDestructiveActionMode
            }
            if (-not $confirmDestructive) {
                Write-Warning "ActionMode='$effectiveActionMode' without -ConfirmDestructiveActionMode; coercing to ScanOnly."
                $effectiveActionMode = 'ScanOnly'
            }
        }

        $cstScript = Resolve-CoreSecurityToolPath
        if (-not $cstScript) {
            $r.Steps.Add([PSCustomObject]@{ Name='CoreSecurityTool'; Status='Skip'; Output='Core Security Tool was not found in expected paths.' })
            return
        }

        $isWinPe = ((Get-EnvironmentMode) -eq 'WinPE')
        $maxMinutes = if ($CstMode -eq 'ThreatScan') {
            if ($isWinPe) { 12 } else { 10 }
        } else {
            $null
        }
        $toolkitRoot = $ScriptDir | Split-Path -Parent | Split-Path -Parent
        $cstDataRoot = Join-Path $toolkitRoot 'CDE\Runtime\Data\cst'
        if (-not (Test-Path $cstDataRoot)) {
            New-Item -Path $cstDataRoot -ItemType Directory -Force | Out-Null
        }
        $sessionTs = if (Get-Command Get-SessionReportTimestamp -ErrorAction SilentlyContinue) {
            Get-SessionReportTimestamp
        } else {
            Get-Date -Format 'yyyyMMdd_HHmmss'
        }
        $resultArtifactPath = Join-Path $cstDataRoot ("CST_Result_{0}.json" -f $sessionTs)
        $behaviorArtifactPath = Join-Path $cstDataRoot ("CST_BehaviorTelemetry_{0}.json" -f $sessionTs)
        $networkArtifactPath = Join-Path $cstDataRoot ("CST_NetworkSnapshot_{0}.json" -f $sessionTs)

        $behaviorTelemetry = Invoke-CdeBehaviorTelemetryCollection -OutputPath $behaviorArtifactPath -SinceHours 24 -MaxEvents 32
        $behaviorPaths = New-Object System.Collections.Generic.List[string]
        if ($behaviorTelemetry.status -in @('Collected', 'NoArtifacts', 'Warn') -and -not [string]::IsNullOrWhiteSpace([string]$behaviorTelemetry.outputPath) -and (Test-Path -LiteralPath $behaviorTelemetry.outputPath -PathType Leaf)) {
            $behaviorPaths.Add([string]$behaviorTelemetry.outputPath) | Out-Null
        }

        if (-not $isWinPe) {
            try {
                $paCore = Join-Path $PSScriptRoot 'ProcessAnalyzer.Core.ps1'
                if (Test-Path -LiteralPath $paCore) { . $paCore }
                if (Get-Command Export-ProcessNetworkArtifactsForCst -ErrorAction SilentlyContinue) {
                    Export-ProcessNetworkArtifactsForCst -OutputPath $networkArtifactPath -MaxRows 200 | Out-Null
                    if (Test-Path -LiteralPath $networkArtifactPath -PathType Leaf) {
                        $behaviorPaths.Add($networkArtifactPath) | Out-Null
                    }
                }
            } catch {
                Write-Log ("Network snapshot for CST skipped: {0}" -f $_.Exception.Message)
            }
        }

        $invokeArgs = @{
            Mode = $CstMode
            DetectionScope = $CstDetectionScope
            ActionMode = $effectiveActionMode
            OutputPath = $resultArtifactPath
            RequireElevation = $true
            AutoElevate = $true
        }
        if ($null -ne $maxMinutes) {
            $invokeArgs.MaxMinutes = [int]$maxMinutes
        }

        if ($behaviorPaths.Count -gt 0) {
            $invokeArgs.BehaviorArtifactsPath = @($behaviorPaths)
        }

        if ($CstMode -eq 'CustomScan' -and $ScanTarget -and $ScanTarget.Count -gt 0) {
            $invokeArgs.Target = @($ScanTarget)
        }

        if ($isWinPe) {
            $invokeArgs.OfflineOnly = $true
            $winPeScanRoot = Resolve-CstWinPeScanRoot
            if (-not $winPeScanRoot) {
                $r.Steps.Add([PSCustomObject]@{
                    Name   = 'CoreSecurityTool'
                    Status = 'Skip'
                    Output = @(
                        'WinPE: no offline Windows installation is available for CST.',
                        'Boot option 2 (Offline CDE) loads the client OS volume and registry hives.',
                        'Without a mounted Windows root (C:-Z:, excluding X:), CST cannot scan files.'
                    ) -join ' '
                })
                return
            }

            if (-not ($CstMode -eq 'CustomScan' -and $ScanTarget -and $ScanTarget.Count -gt 0)) {
                $invokeArgs.Target = @($winPeScanRoot)
            }

            Write-Log ("WinPE CST scan root: {0}" -f $winPeScanRoot)
        }

        $result = & $cstScript @invokeArgs

        if (-not $result) {
            $r.Steps.Add([PSCustomObject]@{ Name='CoreSecurityTool'; Status='Warn'; Output='Core Security Tool returned no result object.' })
            return
        }

        $summary = $result.summary
        $findings = @($result.findings)
        $scanConfig = $result.scanConfiguration
        $detectorCounts = $result.detectorCounts

        $status = switch ([string]$result.status) {
            'Pass' { 'Pass' }
            'Warn' { 'Warn' }
            'Fail' { 'Fail' }
            default { 'Warn' }
        }

        if ($summary.noEligibleTargets -or [string]$result.coverage -eq 'NoTargets') {
            $status = 'Skip'
        }

        $display = "CORE SECURITY TOOL ($($result.scanMode))`n"
        $display += "================================`n`n"
        $display += "Status             : $($result.status)`n"
        $display += "Environment        : $($result.environmentMode)`n"
        $display += "Detection Scope    : $($scanConfig.detectionScope)`n"
        $display += "Requested Action   : $($scanConfig.requestedActionMode)`n"
        $display += "Effective Action   : $($scanConfig.effectiveActionMode)`n"
        if ($null -ne $scanConfig.maxMinutes) {
            $display += "Max Minutes        : $($scanConfig.maxMinutes)`n"
        } else {
            $display += "Max Minutes        : Uncapped for this mode`n"
        }
        if ($scanConfig.resolvedScanRoot) {
            $display += "Resolved Root      : $($scanConfig.resolvedScanRoot)`n"
        }
        if ($scanConfig.offlineRoot) {
            $display += "Offline Root       : $($scanConfig.offlineRoot)`n"
        }
        if ($scanConfig.discoveredWindowsRoots) {
            $display += "Windows Roots      : $(@($scanConfig.discoveredWindowsRoots) -join ', ')`n"
        }
        if ($null -ne $scanConfig.targetCountBeforeExistenceFilter -and $null -ne $scanConfig.targetCountAfterExistenceFilter) {
            $display += "Target Counts      : requested=$($scanConfig.targetCountBeforeExistenceFilter), existing=$($scanConfig.targetCountAfterExistenceFilter)`n"
        }
        if ($scanConfig.targets) {
            $display += "Targets            : $(@($scanConfig.targets) -join ', ')`n"
        }
        if ($scanConfig.missingTargets) {
            $display += "Missing Targets    : $(@($scanConfig.missingTargets) -join ', ')`n"
        }
        if ($resultArtifactPath) {
            $display += "Result Artifact    : $resultArtifactPath`n"
        }
        $display += "Behavior Telemetry : status=$($behaviorTelemetry.status), artifacts=$($behaviorTelemetry.artifactCount), channels=$($behaviorTelemetry.channelCount)`n"
        if ($behaviorTelemetry.outputPath) {
            $display += "Telemetry Bundle   : $($behaviorTelemetry.outputPath)`n"
        }
        if ($behaviorTelemetry.collectorPath) {
            $display += "Telemetry Source   : $($behaviorTelemetry.collectorPath)`n"
        }
        if ($behaviorTelemetry.message) {
            $display += "Telemetry Note     : $($behaviorTelemetry.message)`n"
        }
        if ($scanConfig.behaviorArtifactsPath) {
            $display += "Telemetry Inputs   : $(@($scanConfig.behaviorArtifactsPath) -join ', ')`n"
        }
        $display += "Rules Version      : $($result.rulesVersion)`n"
        $display += "Items Scanned      : $($summary.itemsScanned)`n"
        $display += "Threats Found      : $($summary.threatsFound)`n"
        $display += "Warnings Found     : $($summary.warningsFound)`n"
        $display += "Scan Errors        : $($summary.scanErrors)`n"
        if ($null -ne $summary.noEligibleTargets) {
            $display += "No Eligible Targets: $($summary.noEligibleTargets)`n"
        }
        $display += "Coverage           : $($result.coverage)`n"
        if ($result.coverageReason) {
            $display += "Coverage Reason    : $($result.coverageReason)`n"
        }
        if ($result.actionSummary) {
            $display += "Action Summary     : $($result.actionSummary)`n"
        }
        if ($result.remediation) {
            $display += "Rollback Manifest  : $($result.remediation.rollbackManifestPath)`n"
            $display += "Remediation        : success=$($result.remediation.succeeded), failed=$($result.remediation.failed), skipped=$($result.remediation.skipped)`n"
        }
        if ($null -ne $summary.bootItemsScanned -or $null -ne $summary.bootWarnings -or $null -ne $summary.bootErrors) {
            $display += "`nBOOT CHECKS`n"
            $display += "-----------`n"
            if ($null -ne $scanConfig.bootChecksEnabled) {
                $display += "Checks Enabled     : $($scanConfig.bootChecksEnabled)`n"
            }
            if ($scanConfig.bootChecksMode) {
                $display += "Checks Mode        : $($scanConfig.bootChecksMode)`n"
            }
            if ($scanConfig.bootTargetsResolved) {
                $display += "Resolved Targets   : $(@($scanConfig.bootTargetsResolved) -join ', ')`n"
            }
            if ($null -ne $summary.bootItemsScanned) {
                $display += "Items Scanned      : $($summary.bootItemsScanned)`n"
            }
            if ($null -ne $summary.bootWarnings) {
                $display += "Warnings           : $($summary.bootWarnings)`n"
            }
            if ($null -ne $summary.bootErrors) {
                $display += "Errors             : $($summary.bootErrors)`n"
            }
            if ($detectorCounts) {
                $display += "Detector Counts    : bootFileIntegrity=$($detectorCounts.bootFileIntegrity), bcdInspector=$($detectorCounts.bcdInspector), mbrVbrInspector=$($detectorCounts.mbrVbrInspector), gptStructureInspector=$($detectorCounts.gptStructureInspector)`n"
            }
        }
        $display += "`n"

        if ($findings.Count -gt 0) {
            $display += "TOP FINDINGS`n"
            $display += "------------`n"
            foreach ($f in ($findings | Select-Object -First 15)) {
                $display += "[$($f.type)] $($f.name)`n"
                $display += "  Severity : $($f.severity)`n"
                $display += "  Location : $($f.location)`n"
                $display += "  Evidence : $($f.evidence)`n`n"
            }
        } else {
            if ([int]$summary.scanErrors -gt 0) {
                $display += "No findings detected, but scan completed with $($summary.scanErrors) scan error(s). Review scanErrorDetails in the CST result artifact.`n"
            } else {
                $display += "No findings detected in current scan scope.`n"
            }
        }

        Write-Log $display
        $r.Steps.Add([PSCustomObject]@{ Name='CoreSecurityTool'; Status=$status; Output=$display })
    } catch {
        $warningOutput = [string]$_.Exception.Message
        if ($null -ne $behaviorTelemetry) {
            $warningOutput += "`n`nBehavior Telemetry : status=$($behaviorTelemetry.status), artifacts=$($behaviorTelemetry.artifactCount), channels=$($behaviorTelemetry.channelCount)"
            if ($behaviorTelemetry.outputPath) {
                $warningOutput += "`nTelemetry Bundle   : $($behaviorTelemetry.outputPath)"
            }
            if ($behaviorTelemetry.collectorPath) {
                $warningOutput += "`nTelemetry Source   : $($behaviorTelemetry.collectorPath)"
            }
            if ($behaviorTelemetry.message) {
                $warningOutput += "`nTelemetry Note     : $($behaviorTelemetry.message)"
            }
        }
        $r.Steps.Add([PSCustomObject]@{ Name='CoreSecurityTool'; Status='Warn'; Output=$warningOutput })
    }
}

function Write-DefenderProgress {
    <#
    .SYNOPSIS Emit a machine-readable progress line for the CST / Malware Cleanup GUI.
    .NOTES Defender does not expose files-scanned or true %. Progress is estimated from elapsed time.
    #>
    param(
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][double]$Percent,
        [string]$Detail = '',
        [int]$ElapsedSec = 0,
        [int]$EtaSec = 0,
        [int]$ThreatCount = -1,
        [string]$EngineVersion = '',
        [bool]$Estimated = $true
    )

    $payload = [ordered]@{
        phase         = $Phase
        percent       = [math]::Round([math]::Max(0, [math]::Min(100, $Percent)), 1)
        detail        = $Detail
        elapsedSec    = [int][math]::Max(0, $ElapsedSec)
        etaSec        = [int][math]::Max(0, $EtaSec)
        threatCount   = $ThreatCount
        engineVersion = $EngineVersion
        estimated     = [bool]$Estimated
    }
    [Console]::Out.WriteLine("[DEFENDER:PROGRESS] $($payload | ConvertTo-Json -Compress)")
}

function Format-DefenderElapsed([int]$Seconds) {
    $ts = [TimeSpan]::FromSeconds([math]::Max(0, $Seconds))
    if ($ts.TotalHours -ge 1) { return $ts.ToString('h\:mm\:ss') }
    return $ts.ToString('m\:ss')
}

function Invoke-DefenderScan {
    param($r)
    $envMode = Get-EnvironmentMode
    if ($envMode -ne 'Windows') {
        $toolkitRoot = Join-Path $ScriptDir '..\..'
        $toolsPath = Join-Path $toolkitRoot 'Diagnostics\Malware'
        $scanners  = Get-ChildItem -Path $toolsPath -Filter '*.exe' -Recurse -ErrorAction SilentlyContinue
        if ($scanners) {
            Write-Log "WinPE mode: Found $($scanners.Count) external scanner(s)"
            $r.Steps.Add([PSCustomObject]@{ Name='ExternalScanners'; Status='Pass'; Output="Available: $($scanners.Name -join ', ')" })
        } else {
            $r.Steps.Add([PSCustomObject]@{ Name='ExternalScanners'; Status='Warn'; Output='No external scanners found in Diagnostics\Malware. Add MBAM, RKill, etc.' })
        }
        return
    }

    Write-Log "Checking Windows Defender status..."
    Write-DefenderProgress -Phase 'Status' -Percent 4 -Detail 'Reading Windows Defender status...' -Estimated $false
    try {
        $mpStatus = Get-MpComputerStatus -ErrorAction Stop

        $engineProp = $mpStatus.PSObject.Properties['EngineVersion']
        $amEngineProp = $mpStatus.PSObject.Properties['AMEngineVersion']
        $engineVersion = if ($engineProp -and -not [string]::IsNullOrWhiteSpace([string]$engineProp.Value)) {
            [string]$engineProp.Value
        } elseif ($amEngineProp -and -not [string]::IsNullOrWhiteSpace([string]$amEngineProp.Value)) {
            [string]$amEngineProp.Value
        } else {
            'Unknown'
        }

        $formatted = Format-DefenderStatus -MpStatus $mpStatus
        Write-Log ("Defender status — Antivirus:{0}; Antispyware:{1}; RTP:{2}; Mode:{3}; Signature:{4}; Engine:{5}" -f `
            $mpStatus.AntivirusEnabled,
            $mpStatus.AntiSpywareEnabled,
            $mpStatus.RealTimeProtectionEnabled,
            $mpStatus.AMRunningMode,
            $mpStatus.AntivirusSignatureVersion,
            $engineVersion)

        $defStatus = if ($mpStatus.AntivirusEnabled) { 'Pass' } else { 'Warn' }
        $r.Steps.Add([PSCustomObject]@{ Name='DefenderStatus'; Status=$defStatus; Output=$formatted })

        if (-not $mpStatus.AntivirusEnabled) {
            Write-DefenderProgress -Phase 'Blocked' -Percent 100 -Detail 'Antivirus is disabled — cannot start a Defender scan.' -EngineVersion $engineVersion -Estimated $false
            $r.Steps.Add([PSCustomObject]@{ Name='DefenderScan'; Status='Warn'; Output='Antivirus is disabled. Enable Windows Defender or another AV before scanning.' })
            return
        }

        $priorEnd = $null
        if ($mpStatus.PSObject.Properties['QuickScanEndTime'] -and $null -ne $mpStatus.QuickScanEndTime) {
            $priorEnd = [datetime]$mpStatus.QuickScanEndTime
        }

        Write-Log "Starting Windows Defender quick scan (live elapsed + estimated progress; Defender does not report files scanned)..."
        Write-DefenderProgress -Phase 'Starting' -Percent 8 -Detail 'Starting Windows Defender quick scan...' -EngineVersion $engineVersion -Estimated $false

        $scanStart = Get-Date
        # Typical quick scans finish in a few minutes; ETA stretches if the scan runs longer.
        $estimateSec = 180
        $job = Start-MpScan -ScanType QuickScan -AsJob -ErrorAction Stop

        while ($true) {
            $elapsed = [int][math]::Floor(((Get-Date) - $scanStart).TotalSeconds)

            $jobState = $null
            try { $jobState = [string]$job.State } catch { $jobState = 'Unknown' }

            $scanCompleted = $false
            if ($jobState -eq 'Completed' -or $jobState -eq 'Failed' -or $jobState -eq 'Stopped') {
                $scanCompleted = $true
            }

            if (-not $scanCompleted) {
                try {
                    $live = Get-MpComputerStatus -ErrorAction SilentlyContinue
                    if ($live -and $live.PSObject.Properties['QuickScanEndTime'] -and $null -ne $live.QuickScanEndTime) {
                        $endTime = [datetime]$live.QuickScanEndTime
                        if ($null -eq $priorEnd -or $endTime -gt $priorEnd) {
                            # End time advanced after we started — treat as completed.
                            if ($endTime -ge $scanStart.AddSeconds(-5)) {
                                $scanCompleted = $true
                            }
                        }
                    }
                } catch { }
            }

            if ($scanCompleted) { break }

            if ($elapsed -gt [int]($estimateSec * 0.85)) {
                $estimateSec = [math]::Max($estimateSec + 30, [int][math]::Ceiling($elapsed / 0.85))
            }

            $ratio = [math]::Min(1.0, $elapsed / [math]::Max(1, $estimateSec))
            $pct = 8.0 + (82.0 * $ratio)
            $eta = [math]::Max(0, $estimateSec - $elapsed)
            $elapsedText = Format-DefenderElapsed $elapsed
            $etaText = Format-DefenderElapsed $eta
            $detail = "Elapsed $elapsedText • ETA ~$etaText (estimated) • Defender does not report files scanned"

            Write-DefenderProgress -Phase 'Scanning' -Percent $pct -Detail $detail `
                -ElapsedSec $elapsed -EtaSec $eta -EngineVersion $engineVersion -Estimated $true

            Start-Sleep -Seconds 2
        }

        $elapsedFinal = [int][math]::Floor(((Get-Date) - $scanStart).TotalSeconds)
        try { $jobState = [string]$job.State } catch { }
        try {
            Wait-Job -Job $job -Timeout 10 | Out-Null
            Receive-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
            try { $jobState = [string]$job.State } catch { }
        } catch { }
        try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch { }

        if ($jobState -eq 'Failed') {
            $jobError = ''
            try { $jobError = (@($job.ChildJobs | ForEach-Object { $_.JobStateInfo.Reason }) | Where-Object { $_ }) -join '; ' } catch { }
            Write-DefenderProgress -Phase 'Failed' -Percent 100 -Detail "Defender scan job failed. $jobError" `
                -ElapsedSec $elapsedFinal -EngineVersion $engineVersion -Estimated $false
            $r.Steps.Add([PSCustomObject]@{
                Name   = 'DefenderScan'
                Status = 'Warn'
                Output = "Defender quick scan job failed after $(Format-DefenderElapsed $elapsedFinal). $jobError"
            })
            return
        }

        Write-DefenderProgress -Phase 'Completing' -Percent 95 -Detail 'Collecting Defender threat results...' `
            -ElapsedSec $elapsedFinal -EngineVersion $engineVersion -Estimated $false

        $threatLines = @()
        $threatCount = 0
        $unscopedPriorCount = 0
        try {
            $detectionCutoff = $scanStart.AddMinutes(-2)
            $allDetections = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Sort-Object InitialDetectionTime -Descending | Select-Object -First 40)
            $detections = @()
            foreach ($d in $allDetections) {
                $when = $null
                if ($d.PSObject.Properties['InitialDetectionTime'] -and $d.InitialDetectionTime) {
                    try { $when = [datetime]$d.InitialDetectionTime } catch { $when = $null }
                }
                if ($null -ne $when -and $when -ge $detectionCutoff) {
                    $detections += $d
                } else {
                    $unscopedPriorCount++
                }
            }
            $threatCount = $detections.Count
            foreach ($d in $detections) {
                $name = if ($d.PSObject.Properties['ThreatName'] -and $d.ThreatName) { [string]$d.ThreatName } else { 'Threat' }
                $res = if ($d.PSObject.Properties['Resources'] -and $d.Resources) { @($d.Resources) -join '; ' } else { '' }
                $when = if ($d.PSObject.Properties['InitialDetectionTime'] -and $d.InitialDetectionTime) { [string]$d.InitialDetectionTime } else { '' }
                $line = if ($res) { "$name — $res" } else { $name }
                if ($when) { $line = "$line ($when)" }
                $threatLines += $line
                Write-Log "  Detection: $line"
            }
        } catch {
            Write-Log "  Unable to enumerate Defender threat detections: $_"
        }

        $elapsedText = Format-DefenderElapsed $elapsedFinal
        $summary = if ($threatCount -gt 0) {
            "Quick scan finished in $elapsedText. Threat detections reported: $threatCount. Review Windows Security for remediation."
        } else {
            "Quick scan finished in $elapsedText. No threat detections returned by Get-MpThreatDetection."
        }
        if ($unscopedPriorCount -gt 0) {
            $summary = $summary + " ($unscopedPriorCount prior detection(s) omitted — InitialDetectionTime before scan start window.)"
        }
        if ($threatLines.Count -gt 0) {
            $summary = $summary + "`n`n" + ($threatLines -join "`n")
        }

        Write-Log "  $summary"
        Write-DefenderProgress -Phase 'Completed' -Percent 100 -Detail $summary.Split("`n")[0] `
            -ElapsedSec $elapsedFinal -ThreatCount $threatCount -EngineVersion $engineVersion -Estimated $false

        $scanStepStatus = if ($threatCount -gt 0) { 'Warn' } else { 'Pass' }
        $r.Steps.Add([PSCustomObject]@{ Name='DefenderScan'; Status=$scanStepStatus; Output=$summary })
    } catch {
        Write-DefenderProgress -Phase 'Failed' -Percent 100 -Detail "Defender cmdlets unavailable: $_" -Estimated $false
        $r.Steps.Add([PSCustomObject]@{ Name='DefenderScan'; Status='Warn'; Output="Defender cmdlets unavailable: $_" })
    }
}

function Invoke-AutorunsAudit {
    param($r)
    $envMode = Get-EnvironmentMode
    if ($envMode -eq 'WinPE' -and $env:OFFLINE_REGISTRY_LOADED -ne '1') {
        $step = @{
            Name = 'AutorunsAudit'; Status = 'N/A'; CheckId = 'sec_autoruns'
            Output = 'WinPE: load an offline Windows installation to audit startup registry hives and Winlogon.'
        }
        Add-HealthFindingsToStep -Step $step -Findings @(
            New-HealthFinding -FindingId 'security.autorun.na_winpe' -CheckId 'sec_autoruns' `
                -Finding 'Autoruns audit unavailable without offline hives' -Impact 'Cannot review persistence keys offline until a Windows hive is loaded.' `
                -Severity 'Info' -Confidence 95 -Status 'N/A' -Evidence @('Environment=WinPE')
        ) -SummaryText $step.Output
        $r.Steps.Add([PSCustomObject]$step)
        return
    }

    Write-Log "Auditing startup locations..."
    try {
        $postOpEntries = @(Get-PostOpStartupEntries)
        $entries = @(
            foreach ($entry in $postOpEntries) {
                $entryType = if ($entry.PSObject.Properties['EntryType']) { [string]$entry.EntryType } else { 'Registry' }
                $isDeviated = $false
                if ($entry.PSObject.Properties['IsDeviated']) {
                    $isDeviated = [bool]$entry.IsDeviated
                }

                [PSCustomObject]@{
                    Location   = [string]$entry.SourceGroup
                    Name       = [string]$entry.Name
                    Value      = [string]$entry.Command
                    EntryType  = $entryType
                    IsDeviated = $isDeviated
                }
            }
        )

        $suspicious = @(
            $entries | Where-Object {
                if ($_.IsDeviated) { return $true }
                [string]$_.Value -match '(?i)(temp|appdata|roaming|programdata)' -and
                    [string]$_.Value -match '\.(exe|cmd|bat|vbs|ps1|scr|pif)$'
            } | Sort-Object Location, Name
        )

        $formatted = Format-AutorunsList -Entries $entries -Suspicious $suspicious
        Write-Log $formatted

        $findings = @()
        if ($suspicious.Count -gt 0) {
            foreach ($item in @($suspicious | Select-Object -First 15)) {
                $cmd = [string]$item.Value
                $publisherTrusted = $false
                $signer = ''
                try {
                    $exePath = $null
                    if ($cmd -match '(?i)^"([^"]+\.(?:exe|com|scr))"') { $exePath = $Matches[1] }
                    elseif ($cmd -match '(?i)^([^\s"]+\.(?:exe|com|scr))\b') { $exePath = $Matches[1] }
                    if ($exePath -and (Test-Path -LiteralPath $exePath -PathType Leaf)) {
                        $sig = Get-AuthenticodeSignature -LiteralPath $exePath -ErrorAction SilentlyContinue
                        if ($sig -and $sig.Status -eq 'Valid' -and $sig.SignerCertificate) {
                            $signer = [string]$sig.SignerCertificate.Subject
                            $publisherTrusted = Test-IsTrustedAuthenticodePublisher -SignedBy $signer
                        }
                    }
                } catch { }

                $tier = Resolve-AutorunPublisherFindingTier `
                    -IsDeviated ([bool]$item.IsDeviated) `
                    -PublisherTrusted $publisherTrusted

                $evidence = [System.Collections.Generic.List[string]]::new()
                $evidence.Add("Location=$($item.Location)") | Out-Null
                $evidence.Add("Value=$cmd") | Out-Null
                $evidence.Add("Deviated=$([bool]$item.IsDeviated)") | Out-Null
                if ($signer) { $evidence.Add("Signer=$signer") | Out-Null }

                $recs = if ($tier.Classification -eq 'Inventory') {
                    @('Confirm the user expects this app at startup.', 'Remove only if unrecognized.')
                } else {
                    @('Disable or remove unexpected autoruns in Startup Manager.', 'Investigate the command path before trusting the entry.')
                }

                $findings += New-HealthFinding -FindingId $tier.FindingId -CheckId 'sec_autoruns' `
                    -Subject ([string]$item.Name) -Finding $tier.Finding -Impact $tier.Impact `
                    -Severity $tier.Severity -Confidence $tier.Confidence -Status $tier.Status `
                    -Classification $tier.Classification `
                    -Evidence @($evidence) `
                    -Recommendations $recs `
                    -Actions @(@{ type = 'cde'; target = 'StartupManager'; label = 'Startup Manager' })
            }
        }
        else {
            $findings += New-HealthFinding -FindingId 'security.autorun.ok' -CheckId 'sec_autoruns' `
                -Finding 'No suspicious autoruns flagged' -Impact 'Autorun locations did not match high-risk heuristics.' `
                -Severity 'Info' -Confidence 75 -Status 'Pass' -Evidence @("Entries: $($entries.Count)")
        }

        $step = @{ Name='AutorunsAudit'; Status='Pass'; Output=$formatted; CheckId='sec_autoruns'; Detail="Suspicious: $($suspicious.Count) / $($entries.Count)" }
        Add-HealthFindingsToStep -Step $step -Findings $findings -SummaryText $step.Detail
        $r.Steps.Add([PSCustomObject]$step)
    } catch {
        $r.Steps.Add([PSCustomObject]@{ Name='AutorunsAudit'; Status='Warn'; Output=$_.Exception.Message; CheckId='sec_autoruns' })
    }
}

function Invoke-HostsFileCheck {
    param($r)
    Write-Log "Checking hosts file integrity..."
    try {
        $hostsPath = Get-ToolkitHostsFilePath

        if (Test-Path $hostsPath) {
            $lines   = Get-Content $hostsPath -ErrorAction Stop
            $custom  = @($lines | Where-Object { $_ -notmatch '^\s*#' -and $_ -match '\S' -and $_ -notmatch '127\.0\.0\.1\s+localhost' -and $_ -notmatch '::1\s+localhost' })
            
            $formatted = Format-HostsFileDetail -HostsPath $hostsPath -CustomEntries $custom
            Write-Log $formatted
            
            $findings = @()
            if ($custom.Count -gt 10) {
                $findings += New-HealthFinding -FindingId 'security.hosts.many_custom' -CheckId 'sec_hosts' `
                    -Finding 'Hosts file has many non-default entries' `
                    -Impact 'Large hosts redirects can hijack browsing, block updates, or break DNS resolution.' `
                    -Severity 'Medium' -Confidence 85 -Status 'Warn' `
                    -Evidence @("Path=$hostsPath", "Custom entries: $($custom.Count)") `
                    -Recommendations @('Review custom hosts lines and remove unexpected redirects.', 'Run Hijack and Scam Repair if browser traffic is being redirected.') `
                    -Actions @(@{ type = 'cde'; target = 'HijackRepair'; label = 'Hijack Repair' })
                foreach ($entry in @($custom | Select-Object -First 8)) {
                    $findings += New-HealthFinding -FindingId 'security.hosts.custom_entry' -CheckId 'sec_hosts' `
                        -Subject ([string]$entry) -Finding 'Custom hosts entry' `
                        -Impact 'This mapping overrides DNS for the listed name.' `
                        -Severity 'Low' -Confidence 90 -Status 'Warn' `
                        -Evidence @([string]$entry) `
                        -Recommendations @('Confirm the mapping is intentional before leaving it in place.')
                }
            }
            else {
                $findings += New-HealthFinding -FindingId 'security.hosts.ok' -CheckId 'sec_hosts' `
                    -Finding 'Hosts file looks within normal bounds' `
                    -Impact 'Custom entry count is not elevated.' `
                    -Severity 'Info' -Confidence 80 -Status 'Pass' `
                    -Evidence @("Path=$hostsPath", "Custom entries: $($custom.Count)")
            }

            $step = @{ Name='HostsFile'; Status='Pass'; Output=$formatted; CheckId='sec_hosts'; Detail="Custom hosts entries: $($custom.Count)" }
            Add-HealthFindingsToStep -Step $step -Findings $findings -SummaryText $step.Detail
            $r.Steps.Add([PSCustomObject]$step)
        } else {
            $r.Steps.Add([PSCustomObject]@{ Name='HostsFile'; Status='Skip'; Output='Hosts file not found'; CheckId='sec_hosts' })
        }
    } catch {
        $r.Steps.Add([PSCustomObject]@{ Name='HostsFile'; Status='Warn'; Output=$_.Exception.Message; CheckId='sec_hosts' })
    }
}

function Invoke-BrowserExtensionScan {
    param($r)
    if ((Get-EnvironmentMode) -ne 'Windows') {
        $step = @{
            Name = 'BrowserExtensionScan'; Status = 'N/A'; CheckId = 'sec_browser_extensions'
            Output = 'Not applicable in WinPE. Browser profile extension stores are not available as live user sessions.'
        }
        Add-HealthFindingsToStep -Step $step -Findings @(
            New-HealthFinding -FindingId 'security.extension.na_winpe' -CheckId 'sec_browser_extensions' `
                -Finding 'Browser extension scan unavailable in WinPE' -Impact 'User profile extension stores are not available offline as live sessions.' `
                -Severity 'Info' -Confidence 95 -Status 'N/A' -Evidence @('Environment!=Windows')
        ) -SummaryText $step.Output
        $r.Steps.Add([PSCustomObject]$step)
        return
    }
    Write-Log "Scanning browser extension folders..."
    try {
        function Resolve-LocalizedManifestText {
            param(
                [string]$Text,
                [string]$VersionPath,
                [string]$DefaultLocale
            )

            if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
            if ($Text -notmatch '^__MSG_(.+?)__$') { return [string]$Text }

            $messageKey = $matches[1]
            $localeCandidates = New-Object System.Collections.Generic.List[string]
            if (-not [string]::IsNullOrWhiteSpace($DefaultLocale)) { $localeCandidates.Add($DefaultLocale) }
            foreach ($fallbackLocale in @('en_US', 'en', 'en-GB')) {
                if (-not $localeCandidates.Contains($fallbackLocale)) {
                    $localeCandidates.Add($fallbackLocale)
                }
            }

            foreach ($locale in $localeCandidates) {
                $messagesPath = Join-Path $VersionPath ('_locales\' + $locale + '\messages.json')
                if (-not (Test-Path $messagesPath)) { continue }

                try {
                    $messages = Get-Content -LiteralPath $messagesPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    if ($messages.PSObject.Properties[$messageKey]) {
                        $messageEntry = $messages.$messageKey
                        if ($messageEntry -and $messageEntry.PSObject.Properties['message']) {
                            $resolved = [string]$messageEntry.message
                            if (-not [string]::IsNullOrWhiteSpace($resolved)) { return $resolved }
                        }
                    }
                } catch { }
            }

            return [string]$Text
        }

        $inventory = New-Object System.Collections.Generic.List[object]

        $users = @(Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue)
        foreach ($user in $users) {
            $userRoot = $user.FullName
            $userName = $user.Name

            $chromiumStores = @(
                @{ Browser = 'Chrome'; Profile = 'Default'; Root = Join-Path $userRoot 'AppData\Local\Google\Chrome\User Data\Default\Extensions' },
                @{ Browser = 'Edge'; Profile = 'Default'; Root = Join-Path $userRoot 'AppData\Local\Microsoft\Edge\User Data\Default\Extensions' }
            )

            foreach ($store in $chromiumStores) {
                if (-not (Test-Path $store.Root)) { continue }

                $inventory.Add([PSCustomObject]@{
                    Kind = 'Store'
                    Browser = $store.Browser
                    Profile = $store.Profile
                    User = $userName
                    Location = $store.Root
                    ExtensionId = ''
                    ExtensionName = ''
                    Version = ''
                    ExtensionPath = $store.Root
                    ManifestDescription = ''
                })

                $extensionFolders = @(Get-ChildItem -Path $store.Root -Directory -ErrorAction SilentlyContinue)
                foreach ($extensionFolder in $extensionFolders) {
                    $extensionId = $extensionFolder.Name
                    $extensionIdPath = $extensionFolder.FullName
                    $versionFolders = @(Get-ChildItem -Path $extensionIdPath -Directory -ErrorAction SilentlyContinue | Sort-Object Name)
                    $selectedVersion = $null
                    if ($versionFolders.Count -gt 0) {
                        $selectedVersion = $versionFolders[$versionFolders.Count - 1]
                    }

                    $versionName = ''
                    $versionPath = $extensionIdPath
                    $manifestName = ''
                    $manifestDescription = ''
                    $defaultLocale = ''

                    if ($null -ne $selectedVersion) {
                        $versionName = [string]$selectedVersion.Name
                        $versionPath = $selectedVersion.FullName
                        $manifestPath = Join-Path $versionPath 'manifest.json'
                        if (Test-Path $manifestPath) {
                            try {
                                $manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                                if ($manifest.PSObject.Properties['default_locale']) { $defaultLocale = [string]$manifest.default_locale }
                                if ($manifest.PSObject.Properties['name']) { $manifestName = Resolve-LocalizedManifestText -Text ([string]$manifest.name) -VersionPath $versionPath -DefaultLocale $defaultLocale }
                                if ($manifest.PSObject.Properties['description']) { $manifestDescription = Resolve-LocalizedManifestText -Text ([string]$manifest.description) -VersionPath $versionPath -DefaultLocale $defaultLocale }
                            } catch { }
                        }
                    }

                    $inventory.Add([PSCustomObject]@{
                        Kind = 'Extension'
                        Browser = $store.Browser
                        Profile = $store.Profile
                        User = $userName
                        Location = $extensionIdPath
                        ExtensionId = $extensionId
                        ExtensionName = $manifestName
                        Version = $versionName
                        ExtensionPath = $versionPath
                        ManifestDescription = $manifestDescription
                    })
                }
            }

            $firefoxProfilesRoot = Join-Path $userRoot 'AppData\Roaming\Mozilla\Firefox\Profiles'
            if (Test-Path $firefoxProfilesRoot) {
                $profileFolders = @(Get-ChildItem -Path $firefoxProfilesRoot -Directory -ErrorAction SilentlyContinue)
                foreach ($profileFolder in $profileFolders) {
                    $profileDir = $profileFolder.FullName
                    $profileName = $profileFolder.Name

                    $inventory.Add([PSCustomObject]@{
                        Kind = 'Profile'
                        Browser = 'Firefox'
                        Profile = $profileName
                        User = $userName
                        Location = $profileDir
                        ExtensionId = ''
                        ExtensionName = ''
                        Version = ''
                        ExtensionPath = $profileDir
                        ManifestDescription = ''
                    })

                    $extensionsDir = Join-Path $profileDir 'extensions'
                    if (Test-Path $extensionsDir) {
                        $xpiFiles = @(Get-ChildItem -Path $extensionsDir -File -Filter '*.xpi' -ErrorAction SilentlyContinue)
                        foreach ($xpi in $xpiFiles) {
                            $inventory.Add([PSCustomObject]@{
                                Kind = 'Extension'
                                Browser = 'Firefox'
                                Profile = $profileName
                                User = $userName
                                Location = $xpi.FullName
                                ExtensionId = $xpi.BaseName
                                ExtensionName = $xpi.BaseName
                                Version = ''
                                ExtensionPath = $xpi.FullName
                                ManifestDescription = 'Firefox extension package'
                            })
                        }
                    }

                    $extensionsJson = Join-Path $profileDir 'extensions.json'
                    if (Test-Path $extensionsJson) {
                        try {
                            $addonData = Get-Content -LiteralPath $extensionsJson -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                            if ($addonData.PSObject.Properties['addons']) {
                                foreach ($addon in @($addonData.addons)) {
                                    $addonId = ''
                                    $addonName = ''
                                    $addonVersion = ''
                                    $addonSummary = ''
                                    if ($addon.PSObject.Properties['id']) { $addonId = [string]$addon.id }
                                    if ($addon.PSObject.Properties['defaultLocale'] -and $addon.defaultLocale -and $addon.defaultLocale.PSObject.Properties['name']) { $addonName = [string]$addon.defaultLocale.name }
                                    if ($addon.PSObject.Properties['version']) { $addonVersion = [string]$addon.version }
                                    if ($addon.PSObject.Properties['description']) { $addonSummary = [string]$addon.description }

                                    $inventory.Add([PSCustomObject]@{
                                        Kind = 'Extension'
                                        Browser = 'Firefox'
                                        Profile = $profileName
                                        User = $userName
                                        Location = $extensionsJson
                                        ExtensionId = $addonId
                                        ExtensionName = $addonName
                                        Version = $addonVersion
                                        ExtensionPath = $extensionsJson
                                        ManifestDescription = $addonSummary
                                    })
                                }
                            }
                        } catch { }
                    }
                }
            }
        }

        $formatted = Format-BrowserExtensionList -ExtensionInventory $inventory.ToArray()
        Write-Log $formatted

        $suspicious = @(
            $inventory | Where-Object {
                $_.Kind -eq 'Extension' -and (
                    Test-HijackSuspiciousExtension -ExtensionName ([string]$_.ExtensionName) `
                        -ExtensionId ([string]$_.ExtensionId) `
                        -Description ([string]$_.ManifestDescription)
                )
            }
        )
        if ($suspicious.Count -gt 0) {
            $formatted += "`n`nSUSPICIOUS EXTENSIONS ($($suspicious.Count))`n"
            $formatted += "---------------------------`n"
            foreach ($ext in $suspicious) {
                $formatted += " - $($ext.Browser) / $($ext.User): $($ext.ExtensionName) [$($ext.ExtensionId)]`n"
            }
            $formatted += "`nReview in browser settings or run Hijack and Scam Repair.`n"
        }
        
        $findings = @()
        $extCount = @($inventory | Where-Object { $_.Kind -eq 'Extension' }).Count
        if ($suspicious.Count -gt 0) {
            foreach ($ext in @($suspicious | Select-Object -First 15)) {
                $findings += New-HealthFinding -FindingId 'security.extension.suspicious' -CheckId 'sec_browser_extensions' `
                    -Subject ([string]$ext.ExtensionName) -Finding 'Suspicious browser extension' `
                    -Impact 'Unwanted extensions can hijack search, inject ads, or steal session data.' `
                    -Severity 'High' -Confidence 80 -Status 'Warn' `
                    -Evidence @(
                        "Browser=$($ext.Browser)",
                        "User=$($ext.User)",
                        "Id=$($ext.ExtensionId)",
                        "Path=$($ext.ExtensionPath)"
                    ) `
                    -Recommendations @('Remove the extension from the browser profile.', 'Run Hijack and Scam Repair for related redirects.') `
                    -Actions @(@{ type = 'cde'; target = 'HijackRepair'; label = 'Hijack Repair' })
            }
        }
        else {
            $findings += New-HealthFinding -FindingId 'security.extension.ok' -CheckId 'sec_browser_extensions' `
                -Finding 'No suspicious browser extensions flagged' `
                -Impact 'Extension inventory did not match known-risk heuristics.' `
                -Severity 'Info' -Confidence 70 -Status 'Pass' `
                -Evidence @("Extensions: $extCount")
        }

        $step = @{
            Name = 'BrowserExtensionScan'; Status = 'Pass'; Output = $formatted
            CheckId = 'sec_browser_extensions'; Detail = "Suspicious: $($suspicious.Count) / extensions $extCount"
        }
        Add-HealthFindingsToStep -Step $step -Findings $findings -SummaryText $step.Detail
        $r.Steps.Add([PSCustomObject]$step)
    } catch {
        $detail = [string]$_.Exception.Message
        if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
            $detail += "`n" + [string]$_.InvocationInfo.PositionMessage
        }
        $r.Steps.Add([PSCustomObject]@{ Name='BrowserExtensionScan'; Status='Skip'; Output=$detail; CheckId='sec_browser_extensions' })
    }
}

function Invoke-CstRulesUpdate {
    param($r)
    Write-Log "Checking for Hash IOC updates from CDE threat rules feed..."
    try {
        $cstScript = Resolve-CoreSecurityToolPath
        $updateScript = $null
        if ($cstScript) {
            $candidate = Join-Path (Split-Path $cstScript -Parent) 'updates\Update-CstRulesFromGitHub.ps1'
            if (Test-Path $candidate) { $updateScript = $candidate }
        }
        if (-not $updateScript) {
            $msg = 'Update-CstRulesFromGitHub.ps1 not found alongside Core Security Tool.'
            Write-Log $msg -Level Warning
            $r.Steps.Add([PSCustomObject]@{ Name='UpdateHashIOCs'; Status='Skip'; Output=$msg })
            return
        }
        $output = & $updateScript 2>&1
        $callSucceeded = $?
        $text = ($output | ForEach-Object { "$_" }) -join "`n"
        Write-Log $text
        $status = if (-not $callSucceeded) { 'Fail' } else { 'Pass' }
        $r.Steps.Add([PSCustomObject]@{ Name='UpdateHashIOCs'; Status=$status; Output=$text })
    } catch {
        $r.Steps.Add([PSCustomObject]@{ Name='UpdateHashIOCs'; Status='Fail'; Output=$_.Exception.Message })
    }
}

function Test-IsTrustedAuthenticodePublisher {
    <#
    .SYNOPSIS
      True when Authenticode subject matches a well-known OS/browser/vendor identity.
      Aligns with Microsoft Authenticode guidance: a Valid signature identifies the
      publisher; CDE only demotes path heuristics for a curated known-good set
      (not every CA-issued cert).
    #>
    param([string]$SignedBy)

    if ([string]::IsNullOrWhiteSpace($SignedBy)) { return $false }
    return [bool]($SignedBy -match '(?i)(Microsoft Corporation|Microsoft Windows|Microsoft OneDrive|Google LLC|Google Inc|Mozilla Corporation|Adobe|Apple|Intel|NVIDIA|AMD|Realtek|Logitech)')
}

function Test-IsTrustedScheduledTaskPublisher {
    <#
    .SYNOPSIS Alias for Test-IsTrustedAuthenticodePublisher (scheduled-task callers).
    #>
    param([string]$SignedBy)
    return Test-IsTrustedAuthenticodePublisher -SignedBy $SignedBy
}

function Resolve-AutorunPublisherFindingTier {
    <#
    .SYNOPSIS Map autorun path/deviation + publisher trust to Severity/Classification.
    #>
    param(
        [bool]$IsDeviated,
        [bool]$PublisherTrusted
    )

    if ($IsDeviated) {
        return [PSCustomObject]@{
            FindingId      = 'security.autorun.suspicious'
            Finding        = 'Suspicious autorun entry'
            Impact         = 'Winlogon-deviated autoruns can persist unwanted software.'
            Severity       = 'High'
            Confidence     = 85
            Status         = 'Warn'
            Classification = 'CorroboratedSuspect'
            Attention      = $true
        }
    }

    if ($PublisherTrusted) {
        return [PSCustomObject]@{
            FindingId      = 'security.autorun.path_review'
            Finding        = 'Autorun in writable path with trusted publisher'
            Impact         = 'Path heuristic matched, but Authenticode publisher looks known-good. Review only if unexpected.'
            Severity       = 'Low'
            Confidence     = 55
            Status         = 'Info'
            Classification = 'Inventory'
            Attention      = $false
        }
    }

    return [PSCustomObject]@{
        FindingId      = 'security.autorun.suspicious'
        Finding        = 'Suspicious autorun entry'
        Impact         = 'Writable-folder autoruns without a trusted publisher can persist unwanted software.'
        Severity       = 'Medium'
        Confidence     = 70
        Status         = 'Warn'
        Classification = 'SingleSignal'
        Attention      = $true
    }
}

function Resolve-ScheduledTaskSuspiciousFindingTier {
    <#
    .SYNOPSIS
      Map scheduled-task suspicion reasons to Severity/Classification.
      High-risk paths/scripts stay High; unsigned/untrusted AppData alone is Medium.
    #>
    param([string[]]$Reasons)

    $list = @($Reasons | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $highMarkers = @(
        'risky path',
        'script action',
        'unknown action',
        'unreadable actions',
        'no actions',
        'unresolved COM handler'
    )
    $highHits = @($list | Where-Object { $highMarkers -contains $_ })

    if ($highHits.Count -ge 2) {
        return [PSCustomObject]@{
            Severity       = 'High'
            Confidence     = 88
            Status         = 'Warn'
            Classification = 'CorroboratedSuspect'
            Attention      = $true
        }
    }

    if ($highHits.Count -eq 1) {
        return [PSCustomObject]@{
            Severity       = 'High'
            Confidence     = 82
            Status         = 'Warn'
            Classification = 'SingleSignal'
            Attention      = $true
        }
    }

    # unsigned / untrusted publisher / missing target in writable path
    return [PSCustomObject]@{
        Severity       = 'Medium'
        Confidence     = 70
        Status         = 'Warn'
        Classification = 'SingleSignal'
        Attention      = $true
    }
}

function Test-IsScheduledTaskScriptExecute {
    param([string]$Execute)

    if ([string]::IsNullOrWhiteSpace($Execute)) { return $false }
    return [bool]($Execute -match '(?i)\.(cmd|bat|vbs|js|jse|wsf|wsh|ps1|psc1|scr|hta)(\s|"|$)')
}

function Test-IsHighRiskScheduledTaskPath {
    <#
    .SYNOPSIS Temp/Downloads/Public — always review-worthy regardless of publisher.
    #>
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return [bool]($Path -match '(?i)(\\Temp\\|\\Tmp\\|\\Downloads\\|AppData\\Local\\Temp\\|\\Users\\Public\\)')
}

function Test-IsUserWritableScheduledTaskPath {
    <#
    .SYNOPSIS AppData / ProgramData / per-user profile paths (not Program Files).
    #>
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($Path -match '(?i)\\(Program Files|Program Files \(x86\)|Windows)\\') { return $false }
    return [bool]($Path -match '(?i)(\\AppData\\|\\ProgramData\\|\\Users\\[^\\]+\\)')
}

function Test-ScheduledTaskExecuteSuspicious {
    <#
    .SYNOPSIS
      Decide whether a scheduled-task Execute path warrants review.
      Pass ResolvedPath / TargetExists / IsSigned / SignedBy to inject resolution (unit tests).
    #>
    param(
        [string]$Execute,
        [string]$Arguments = '',
        [string]$TaskName = '',
        [string]$ResolvedPath,
        [bool]$TargetExists,
        [bool]$IsSigned,
        [string]$SignedBy
    )

    $reasons = [System.Collections.Generic.List[string]]::new()

    if ([string]::IsNullOrWhiteSpace($Execute)) {
        $reasons.Add('unknown action') | Out-Null
        return [PSCustomObject]@{
            IsSuspicious = $true
            Reasons      = @($reasons)
            ResolvedPath = ''
        }
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($Execute.Trim().Trim('"'))
    $pathForChecks = $expanded

    $exists = $false
    $signed = $false
    $signedByValue = ''

    $useInjected = $PSBoundParameters.ContainsKey('ResolvedPath') `
        -or $PSBoundParameters.ContainsKey('TargetExists') `
        -or $PSBoundParameters.ContainsKey('IsSigned') `
        -or $PSBoundParameters.ContainsKey('SignedBy')

    if ($useInjected) {
        if ($PSBoundParameters.ContainsKey('ResolvedPath') -and -not [string]::IsNullOrWhiteSpace($ResolvedPath)) {
            $pathForChecks = $ResolvedPath
        }
        $exists = if ($PSBoundParameters.ContainsKey('TargetExists')) { $TargetExists } else { $true }
        $signed = if ($PSBoundParameters.ContainsKey('IsSigned')) { $IsSigned } else { $false }
        $signedByValue = if ($PSBoundParameters.ContainsKey('SignedBy')) { [string]$SignedBy } else { '' }
    }
    else {
        try {
            if (Get-Command -Name Resolve-StartupTarget -ErrorAction SilentlyContinue) {
                $target = Resolve-StartupTarget -Command $expanded
                if (-not [string]::IsNullOrWhiteSpace([string]$target.ResolvedPath)) {
                    $pathForChecks = [string]$target.ResolvedPath
                }
                $exists = [bool]$target.Exists
            }
            else {
                $exists = Test-Path -LiteralPath $expanded -PathType Leaf -ErrorAction SilentlyContinue
                if ($exists) { $pathForChecks = $expanded }
            }

            if ($exists -and (Get-Command -Name Get-FileSignatureInfo -ErrorAction SilentlyContinue)) {
                $sig = Get-FileSignatureInfo -FilePath $pathForChecks
                $signed = [bool]$sig.IsSigned
                $signedByValue = if (-not [string]::IsNullOrWhiteSpace([string]$sig.SignedBy)) {
                    [string]$sig.SignedBy
                } else {
                    [string]$sig.SignedDisplay
                }
            }
        }
        catch {
            # Fall through with best-effort path string
        }
    }

    if (Test-IsScheduledTaskScriptExecute -Execute $expanded) {
        $reasons.Add('script action') | Out-Null
    }

    if (Test-IsHighRiskScheduledTaskPath -Path $pathForChecks) {
        $reasons.Add('risky path') | Out-Null
    }
    elseif (Test-IsUserWritableScheduledTaskPath -Path $pathForChecks) {
        if (-not $exists) {
            $reasons.Add('missing target in user-writable path') | Out-Null
        }
        elseif (-not $signed) {
            $reasons.Add('unsigned in user-writable path') | Out-Null
        }
        elseif (-not (Test-IsTrustedScheduledTaskPublisher -SignedBy $signedByValue)) {
            $reasons.Add('untrusted publisher in user-writable path') | Out-Null
        }
        # else: Microsoft/Google/Mozilla-signed under AppData (e.g. OneDrive) - not suspicious
    }

    return [PSCustomObject]@{
        IsSuspicious = ($reasons.Count -gt 0)
        Reasons      = @($reasons)
        ResolvedPath = $pathForChecks
    }
}

function Test-ScheduledTaskComActionSuspicious {
    <#
    .SYNOPSIS
      Evaluate a COM-handler scheduled-task action (ClassId -> Inproc/LocalServer32).
      Inject ResolvedServerPath / TargetExists / IsSigned / SignedBy for unit tests.
    #>
    param(
        [string]$ClassId,
        [string]$ResolvedServerPath,
        [bool]$TargetExists,
        [bool]$IsSigned,
        [string]$SignedBy
    )

    if ([string]::IsNullOrWhiteSpace($ClassId)) {
        return [PSCustomObject]@{
            IsSuspicious = $true
            Reasons      = @('unknown action')
            ResolvedPath = ''
            ClassId      = ''
        }
    }

    $serverPath = ''
    $exists = $false
    $signed = $false
    $signedByValue = ''

    $useInjected = $PSBoundParameters.ContainsKey('ResolvedServerPath') `
        -or $PSBoundParameters.ContainsKey('TargetExists') `
        -or $PSBoundParameters.ContainsKey('IsSigned') `
        -or $PSBoundParameters.ContainsKey('SignedBy')

    if ($useInjected) {
        $serverPath = if ($PSBoundParameters.ContainsKey('ResolvedServerPath')) { [string]$ResolvedServerPath } else { '' }
        $exists = if ($PSBoundParameters.ContainsKey('TargetExists')) { $TargetExists } else { $false }
        $signed = if ($PSBoundParameters.ContainsKey('IsSigned')) { $IsSigned } else { $false }
        $signedByValue = if ($PSBoundParameters.ContainsKey('SignedBy')) { [string]$SignedBy } else { '' }
    }
    else {
        if (-not (Get-Command -Name Resolve-ComHandlerServerPath -ErrorAction SilentlyContinue)) {
            return [PSCustomObject]@{
                IsSuspicious = $true
                Reasons      = @('unresolved COM handler')
                ResolvedPath = ''
                ClassId      = $ClassId
            }
        }

        $com = Resolve-ComHandlerServerPath -ClassId $ClassId
        $serverPath = if ($com) { [string]$com.ServerPath } else { '' }
        $exists = if ($com) { [bool]$com.Exists } else { $false }

        if ($exists -and -not [string]::IsNullOrWhiteSpace($serverPath) `
                -and (Get-Command -Name Get-FileSignatureInfo -ErrorAction SilentlyContinue)) {
            try {
                $sig = Get-FileSignatureInfo -FilePath $serverPath
                $signed = [bool]$sig.IsSigned
                $signedByValue = if (-not [string]::IsNullOrWhiteSpace([string]$sig.SignedBy)) {
                    [string]$sig.SignedBy
                } else {
                    [string]$sig.SignedDisplay
                }
            }
            catch { }
        }
    }

    if ([string]::IsNullOrWhiteSpace($serverPath)) {
        return [PSCustomObject]@{
            IsSuspicious = $true
            Reasons      = @('unresolved COM handler')
            ResolvedPath = ''
            ClassId      = $ClassId
        }
    }

    # Reuse Exec path heuristics against the COM server binary/DLL.
    $execArgs = @{
        Execute      = $serverPath
        ResolvedPath = $serverPath
        TargetExists = $exists
        IsSigned     = $signed
        SignedBy     = $signedByValue
    }
    $assessment = Test-ScheduledTaskExecuteSuspicious @execArgs

    return [PSCustomObject]@{
        IsSuspicious = [bool]$assessment.IsSuspicious
        Reasons      = @($assessment.Reasons)
        ResolvedPath = [string]$assessment.ResolvedPath
        ClassId      = $ClassId
    }
}

function Test-ScheduledTaskSuspicious {
    <#
    .SYNOPSIS Evaluate all actions on a scheduled task object (Exec + COM).
    #>
    param(
        [Parameter(Mandatory)]$Task
    )

    $reasons = [System.Collections.Generic.List[string]]::new()
    $actions = @()
    try {
        $actions = @($Task.Actions)
    }
    catch {
        return [PSCustomObject]@{
            IsSuspicious = $true
            Reasons      = @('unreadable actions')
        }
    }

    if ($actions.Count -eq 0) {
        return [PSCustomObject]@{
            IsSuspicious = $true
            Reasons      = @('no actions')
        }
    }

    foreach ($action in $actions) {
        try {
            $actionKind = 'Exec'
            if (Get-Command -Name Get-ScheduledTaskActionKind -ErrorAction SilentlyContinue) {
                $actionKind = Get-ScheduledTaskActionKind -Action $action
            }
            else {
                $exeProbe = ''
                try {
                    $exeProp = $action.PSObject.Properties['Execute']
                    $exeProbe = if ($exeProp) { [string]$exeProp.Value } else { '' }
                } catch { }
                $classProbe = ''
                try {
                    $cidProp = $action.PSObject.Properties['ClassId']
                    $classProbe = if ($cidProp) { [string]$cidProp.Value } else { '' }
                } catch { }
                if ([string]::IsNullOrWhiteSpace($exeProbe) -and -not [string]::IsNullOrWhiteSpace($classProbe)) {
                    $actionKind = 'Com'
                }
                elseif ([string]::IsNullOrWhiteSpace($exeProbe) -and [string]::IsNullOrWhiteSpace($classProbe)) {
                    $actionKind = 'None'
                }
            }

            if ($actionKind -eq 'Com') {
                $classId = ''
                if (Get-Command -Name Get-ScheduledTaskComClassId -ErrorAction SilentlyContinue) {
                    $classId = Get-ScheduledTaskComClassId -Action $action
                }
                else {
                    $cidProp = $action.PSObject.Properties['ClassId']
                    $classId = if ($cidProp) { [string]$cidProp.Value } else { '' }
                }

                $assessment = Test-ScheduledTaskComActionSuspicious -ClassId $classId
            }
            elseif ($actionKind -eq 'None') {
                $assessment = [PSCustomObject]@{
                    IsSuspicious = $true
                    Reasons      = @('unknown action')
                }
            }
            else {
                $exe = ''
                $args = ''
                if (Get-Command -Name Get-ScheduledTaskActionExecute -ErrorAction SilentlyContinue) {
                    $exe = Get-ScheduledTaskActionExecute -Action $action
                    $args = Get-ScheduledTaskActionArguments -Action $action
                }
                else {
                    $exeProp = $action.PSObject.Properties['Execute']
                    $exe = if ($exeProp) { [string]$exeProp.Value } else { '' }
                    $argProp = $action.PSObject.Properties['Arguments']
                    $args = if ($argProp) { [string]$argProp.Value } else { '' }
                }

                $assessment = Test-ScheduledTaskExecuteSuspicious `
                    -Execute $exe `
                    -Arguments $args `
                    -TaskName ([string]$Task.TaskName)
            }

            foreach ($reason in @($assessment.Reasons)) {
                if (-not [string]::IsNullOrWhiteSpace($reason) -and -not $reasons.Contains($reason)) {
                    $reasons.Add($reason) | Out-Null
                }
            }
        }
        catch {
            $reasons.Add('unreadable action') | Out-Null
        }
    }

    return [PSCustomObject]@{
        IsSuspicious = ($reasons.Count -gt 0)
        Reasons      = @($reasons)
    }
}

function Invoke-ScheduledTasksAudit {
    param($r)
    if ((Get-EnvironmentMode) -ne 'Windows') {
        $step = @{
            Name = 'ScheduledTasksAudit'; Status = 'N/A'; CheckId = 'sec_scheduled_tasks'
            Output = 'Not applicable in WinPE. Requires live Task Scheduler service state.'
        }
        Add-HealthFindingsToStep -Step $step -Findings @(
            New-HealthFinding -FindingId 'security.task.na_winpe' -CheckId 'sec_scheduled_tasks' `
                -Finding 'Scheduled task audit unavailable in WinPE' -Impact 'Live Task Scheduler state cannot be queried offline.' `
                -Severity 'Info' -Confidence 95 -Status 'N/A' -Evidence @('Environment!=Windows')
        ) -SummaryText $step.Output
        $r.Steps.Add([PSCustomObject]$step)
        return
    }
    Write-Log "Auditing scheduled tasks..."
    try {
        $tasks = [System.Collections.Generic.List[object]]::new()
        foreach ($task in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
            try {
                if ($task.State -ne 'Ready') { continue }
                if ($task.TaskPath -like '\Microsoft\*') { continue }
                $null = $task.Actions
                $tasks.Add($task) | Out-Null
            }
            catch {
                Write-Log "Skipping scheduled task '$($task.TaskName)': $($_.Exception.Message)" -Level Verbose
            }
        }

        $suspect = [System.Collections.Generic.List[object]]::new()
        foreach ($task in $tasks) {
            try {
                $assessment = Test-ScheduledTaskSuspicious -Task $task
                if ($assessment.IsSuspicious) {
                    $task | Add-Member -NotePropertyName SuspiciousReasons -NotePropertyValue @($assessment.Reasons) -Force
                    $suspect.Add($task) | Out-Null
                }
            }
            catch {
                Write-Log "Skipping scheduled task action review '$($task.TaskName)': $($_.Exception.Message)" -Level Verbose
            }
        }

        $formatted = Format-ScheduledTasksList -CustomTasks @($tasks) -SuspiciousTasks @($suspect)
        Write-Log $formatted

        $findings = @()
        if ($suspect.Count -gt 0) {
            foreach ($task in @($suspect | Select-Object -First 15)) {
                $reasons = if ($task.PSObject.Properties['SuspiciousReasons']) { @($task.SuspiciousReasons) } else { @() }
                $reasonText = ($reasons -join ', ')
                $actionText = ''
                try {
                    $actionText = (@($task.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join '; ')
                } catch { }
                $tier = Resolve-ScheduledTaskSuspiciousFindingTier -Reasons $reasons
                $findings += New-HealthFinding -FindingId 'security.task.suspicious' -CheckId 'sec_scheduled_tasks' `
                    -Subject ([string]$task.TaskName) -Finding 'Suspicious scheduled task' `
                    -Impact 'Malicious or unexpected tasks can reinstall malware and run with elevated rights.' `
                    -Severity $tier.Severity -Confidence $tier.Confidence -Status $tier.Status `
                    -Classification $tier.Classification `
                    -Evidence @("Path=$($task.TaskPath)", "Reasons=$reasonText", "Action=$actionText") `
                    -Recommendations @('Disable or delete the task if unexpected.', 'Inspect the action executable path and publisher.') `
                    -Actions @(@{ type = 'shell'; target = 'taskschd.msc'; label = 'Task Scheduler' })
            }
        }
        else {
            $findings += New-HealthFinding -FindingId 'security.task.ok' -CheckId 'sec_scheduled_tasks' `
                -Finding 'No suspicious non-Microsoft tasks flagged' `
                -Impact 'Custom Ready tasks did not match high-risk heuristics.' `
                -Severity 'Info' -Confidence 75 -Status 'Pass' `
                -Evidence @("Custom Ready tasks: $($tasks.Count)")
        }

        $step = @{
            Name = 'ScheduledTasksAudit'; Status = 'Pass'; Output = $formatted
            CheckId = 'sec_scheduled_tasks'; Detail = "Suspicious: $($suspect.Count) / custom $($tasks.Count)"
        }
        Add-HealthFindingsToStep -Step $step -Findings $findings -SummaryText $step.Detail
        $r.Steps.Add([PSCustomObject]$step)
    } catch {
        $r.Steps.Add([PSCustomObject]@{ Name='ScheduledTasksAudit'; Status='Skip'; Output=$_.Exception.Message; CheckId='sec_scheduled_tasks' })
    }
}

# â”€â”€â”€ Dispatch â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
function Invoke-RansomwareRecoveryAudit {
    param($r)
    Write-Log 'Auditing ransomware recovery tamper indicators (T1490)...'
    $env = if (Get-Command Get-EnvironmentMode -ErrorAction SilentlyContinue) { Get-EnvironmentMode } else { 'Windows' }
    $issues = [System.Collections.Generic.List[string]]::new()
    $highSignal = 0

    foreach ($svcName in @('VSS', 'swprv', 'wbengine')) {
        try {
            $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            if ($null -eq $svc) { continue }
            if ($svc.StartType -eq 'Disabled') {
                $issues.Add("Service $svcName is Disabled.") | Out-Null
                $highSignal++
            }
        } catch { }
    }

    if ($env -eq 'Windows') {
        try {
            $shadowBrowse = Join-Path $PSScriptRoot 'ShadowCopyBrowse.ps1'
            if (Test-Path -LiteralPath $shadowBrowse) {
                . $shadowBrowse
                $shadows = @(Get-ShadowCopiesViaVssAdmin -AllowFailure)
                if ($shadows.Count -eq 0) {
                    $issues.Add('No volume shadow copies found (Warn: System Restore may be off).') | Out-Null
                }
            }
        } catch {
            $issues.Add("Shadow copy enumeration failed: $($_.Exception.Message)") | Out-Null
        }

        try {
            $reagent = & reagentc.exe /info 2>&1 | Out-String
            if ($reagent -match '(?i)Windows\s+RE\s+status\s*:\s*Disabled') {
                $issues.Add('Windows RE is Disabled (reagentc).') | Out-Null
                $highSignal++
            }
        } catch {
            $issues.Add("WinRE check failed: $($_.Exception.Message)") | Out-Null
        }
    } else {
        $offlineRoot = $env:OFFLINE_WINDOWS_ROOT
        if (-not [string]::IsNullOrWhiteSpace($offlineRoot)) {
            $recoveryDir = Join-Path $offlineRoot.TrimEnd('\') 'Windows\System32\Recovery'
            if (-not (Test-Path -LiteralPath $recoveryDir)) {
                $issues.Add("Offline recovery folder missing: $recoveryDir") | Out-Null
                $highSignal++
            }
        } else {
            $issues.Add('WinPE: set OFFLINE_WINDOWS_ROOT for offline WinRE checks.') | Out-Null
        }
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('RANSOMWARE RECOVERY AUDIT') | Out-Null
    $lines.Add('=========================') | Out-Null
    foreach ($issue in $issues) { $lines.Add(" - $issue") | Out-Null }
    if ($highSignal -ge 2) {
        $lines.Add('') | Out-Null
        $lines.Add('High: multiple recovery features impaired (T1490 pattern).') | Out-Null
    }

    $status = if ($highSignal -ge 2) { 'Fail' } elseif ($issues.Count -gt 0) { 'Warn' } else { 'Pass' }
    $findings = @()
    if ($status -eq 'Pass') {
        $findings += New-HealthFinding -FindingId 'security.ransomware_recovery.ok' -CheckId 'sec_ransomware_recovery' `
            -Finding 'Recovery features look intact' -Impact 'No strong T1490 recovery-tamper indicators.' `
            -Severity 'Info' -Confidence 80 -Status 'Pass' -Evidence @('VSS/WinRE checks completed.')
    } else {
        foreach ($issue in $issues) {
            if ($issue -match '(?i)informational') { continue }
            $findings += New-HealthFinding -FindingId 'security.ransomware_recovery.issue' -CheckId 'sec_ransomware_recovery' `
                -Finding $issue -Impact 'Ransomware often disables shadow copies, backup services, or WinRE before encryption.' `
                -Severity $(if ($highSignal -ge 2) { 'High' } else { 'Medium' }) -Confidence 75 -Status $status `
                -Evidence @($issue) `
                -Recommendations @('Review VSS/WinRE state and run Core Security Tool Full Scan.', 'Do not rely on missing shadows alone as proof of ransomware.') `
                -Actions @(
                    @{ type = 'cde'; target = 'CoreSecurityTool'; label = 'Core Security Tool' }
                    @{ type = 'cde'; target = 'FileManager'; label = 'File Manager (Shadow Copies)' }
                )
        }
    }

    $step = @{
        Name    = 'RansomwareRecoveryAudit'
        Status  = $status
        Output  = ($lines -join "`n")
        CheckId = 'sec_ransomware_recovery'
        Detail  = "Issues=$($issues.Count); HighSignal=$highSignal"
    }
    Add-HealthFindingsToStep -Step $step -Findings $findings -SummaryText $step.Detail
    $r.Steps.Add([PSCustomObject]$step)
    Write-Log $step.Output
}

function Invoke-MinerBehaviorAudit {
    param($r)
    Write-Log 'Auditing miner behavior heuristics...'
    $env = if (Get-Command Get-EnvironmentMode -ErrorAction SilentlyContinue) { Get-EnvironmentMode } else { 'Windows' }
    if ($env -ne 'Windows') {
        $step = @{
            Name = 'MinerBehaviorAudit'; Status = 'N/A'; CheckId = 'sec_miner_behavior'
            Output = 'Miner behavior audit requires live Windows process telemetry.'
        }
        Add-HealthFindingsToStep -Step $step -Findings @(
            New-HealthFinding -FindingId 'security.miner.na' -CheckId 'sec_miner_behavior' `
                -Finding 'Not available in WinPE' -Impact 'Live process heuristics unavailable.' `
                -Severity 'Info' -Confidence 90 -Status 'N/A'
        ) -SummaryText 'N/A'
        $r.Steps.Add([PSCustomObject]$step)
        return
    }

    $core = Join-Path $PSScriptRoot 'ProcessAnalyzer.Core.ps1'
    if (Test-Path -LiteralPath $core) { . $core }

    $hits = [System.Collections.Generic.List[string]]::new()
    try {
        # Two spaced CPU maps: high_cpu+writable_path must sustain across both samples.
        # miner_cmdline remains a strong one-shot signal.
        $samplesA = Get-ProcessCpuPercentMap -SampleMs 400
        Start-Sleep -Milliseconds 1500
        $samplesB = Get-ProcessCpuPercentMap -SampleMs 400
        foreach ($proc in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
            if ($null -eq $proc) { continue }
            $procId = [int]$proc.ProcessId
            $path = [string]$proc.ExecutablePath
            $cmd = [string]$proc.CommandLine
            $cpuA = 0.0
            $cpuB = 0.0
            if ($samplesA -and $samplesA.ContainsKey($procId)) { $cpuA = [double]$samplesA[$procId] }
            if ($samplesB -and $samplesB.ContainsKey($procId)) { $cpuB = [double]$samplesB[$procId] }
            $cpu = [math]::Max($cpuA, $cpuB)
            $riskA = Get-ProcessRiskInfo -Name ([string]$proc.Name) -FilePath $path -CommandLine $cmd `
                -IsSigned $null -CpuPercent $cpuA -RamMB 0 -Status 'Running'
            $riskB = Get-ProcessRiskInfo -Name ([string]$proc.Name) -FilePath $path -CommandLine $cmd `
                -IsSigned $null -CpuPercent $cpuB -RamMB 0 -Status 'Running'
            $flagsA = @([string]$riskA.Flags -split ',' | Where-Object { $_ })
            $flagsB = @([string]$riskB.Flags -split ',' | Where-Object { $_ })
            $cmdlineHit = ($flagsA -contains 'miner_cmdline') -or ($flagsB -contains 'miner_cmdline')
            $sustainedRiskyCpu = (
                ($flagsA -contains 'high_cpu' -and $flagsA -contains 'writable_path') -and
                ($flagsB -contains 'high_cpu' -and $flagsB -contains 'writable_path')
            )
            if ($cmdlineHit -or $sustainedRiskyCpu) {
                $flagText = if ($cmdlineHit) { 'miner_cmdline' } else { 'high_cpu,writable_path (sustained)' }
                $hits.Add("PID $procId $($proc.Name) cpuA=$([math]::Round($cpuA,1))% cpuB=$([math]::Round($cpuB,1))% flags=$flagText path=$path") | Out-Null
            }
        }
    } catch {
        $hits.Add("Miner audit failed: $($_.Exception.Message)") | Out-Null
    }

    $status = if ($hits.Count -gt 0) { 'Warn' } else { 'Pass' }
    $findings = @()
    if ($hits.Count -eq 0) {
        $findings += New-HealthFinding -FindingId 'security.miner.ok' -CheckId 'sec_miner_behavior' `
            -Finding 'No miner heuristics triggered' -Impact 'No sustained high-CPU risky-path or miner cmdline process found across samples.' `
            -Severity 'Info' -Confidence 75 -Status 'Pass'
    } else {
        foreach ($hit in $hits) {
            $isCmdline = $hit -match 'miner_cmdline'
            $findings += New-HealthFinding -FindingId 'security.miner.suspect' -CheckId 'sec_miner_behavior' `
                -Finding 'Possible miner behavior' -Impact 'Crypto miners often show sustained high CPU and mining pool cmdline from user-writable paths.' `
                -Severity 'Medium' -Confidence $(if ($isCmdline) { 75 } else { 70 }) -Status 'Warn' `
                -Classification $(if ($isCmdline) { 'CorroboratedSuspect' } else { 'SingleSignal' }) `
                -Evidence @($hit) `
                -Recommendations @('Inspect the process in Process Analyzer and scan the image path with CST.') `
                -Actions @(@{ type = 'cde'; target = 'ProcessAnalyzer'; label = 'Process Analyzer' })
        }
    }

    $step = @{
        Name = 'MinerBehaviorAudit'; Status = $status; CheckId = 'sec_miner_behavior'
        Output = if ($hits.Count -eq 0) { 'No miner heuristics triggered.' } else { ($hits -join "`n") }
        Detail = "Hits=$($hits.Count)"
    }
    Add-HealthFindingsToStep -Step $step -Findings $findings -SummaryText $step.Detail
    $r.Steps.Add([PSCustomObject]$step)
    Write-Log $step.Output
}

function Get-SecurityAuditCheckDispatchMap {
    return @{
        sec_defender             = { param($r) Invoke-DefenderScan $r }
        sec_cst                  = { param($r) Invoke-CoreSecurityTool $r }
        sec_autoruns             = { param($r) Invoke-AutorunsAudit $r }
        sec_hosts                = { param($r) Invoke-HostsFileCheck $r }
        sec_browser_extensions   = { param($r) Invoke-BrowserExtensionScan $r }
        sec_scheduled_tasks      = { param($r) Invoke-ScheduledTasksAudit $r }
        sec_ransomware_recovery  = { param($r) Invoke-RansomwareRecoveryAudit $r }
        sec_miner_behavior       = { param($r) Invoke-MinerBehaviorAudit $r }
    }
}
