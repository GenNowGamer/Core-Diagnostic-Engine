#Requires -Version 5.1
<#
.SYNOPSIS
    Security audit check functions used by SystemHealthCheck.ps1. Malware cleanup workflows use Defender/CST helpers from this module.
#>

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $MyInvocation.MyCommand.Path }
$WorkflowsDir = Join-Path $ScriptDir '..\Workflows'
$StartupRiskScript = Join-Path $ScriptDir 'StartupRisk.ps1'
$HijackHelpersScript = Join-Path $ScriptDir 'HijackRepairHelpers.ps1'
if (Test-Path $StartupRiskScript) { . $StartupRiskScript }
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

        $behaviorTelemetry = Invoke-CdeBehaviorTelemetryCollection -OutputPath $behaviorArtifactPath -SinceHours 24 -MaxEvents 32

        $invokeArgs = @{
            Mode = $CstMode
            DetectionScope = $CstDetectionScope
            ActionMode = $CstActionMode
            OutputPath = $resultArtifactPath
            RequireElevation = $true
            AutoElevate = $true
        }
        if ($null -ne $maxMinutes) {
            $invokeArgs.MaxMinutes = [int]$maxMinutes
        }

        if ($behaviorTelemetry.status -in @('Collected', 'NoArtifacts', 'Warn') -and -not [string]::IsNullOrWhiteSpace([string]$behaviorTelemetry.outputPath) -and (Test-Path -LiteralPath $behaviorTelemetry.outputPath -PathType Leaf)) {
            $invokeArgs.BehaviorArtifactsPath = @($behaviorTelemetry.outputPath)
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
    try {
        $mpStatus = Get-MpComputerStatus -ErrorAction Stop
        
        $formatted = Format-DefenderStatus -MpStatus $mpStatus
        Write-Log $formatted
        
        $defStatus = if ($mpStatus.AntivirusEnabled) { 'Pass' } else { 'Warn' }
        $r.Steps.Add([PSCustomObject]@{ Name='DefenderStatus'; Status=$defStatus; Output=$formatted })
        
        Start-MpScan -ScanType QuickScan -ErrorAction SilentlyContinue
        Write-Log "  Quick scan initiated (runs in background via Windows Security)"
        $r.Steps.Add([PSCustomObject]@{ Name='DefenderScan'; Status='Pass'; Output='Quick scan initiated. Check Windows Security for results.' })
    } catch {
        $r.Steps.Add([PSCustomObject]@{ Name='DefenderScan'; Status='Warn'; Output="Defender cmdlets unavailable: $_" })
    }
}

function Invoke-AutorunsAudit {
    param($r)
    $envMode = Get-EnvironmentMode
    if ($envMode -eq 'WinPE' -and $env:OFFLINE_REGISTRY_LOADED -ne '1') {
        $r.Steps.Add([PSCustomObject]@{
            Name   = 'AutorunsAudit'
            Status = 'N/A'
            Output = 'WinPE: load an offline Windows installation to audit startup registry hives and Winlogon.'
        })
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

        $status = if ($suspicious.Count -gt 0) { 'Warn' } else { 'Pass' }
        $r.Steps.Add([PSCustomObject]@{ Name='AutorunsAudit'; Status=$status; Output=$formatted })
    } catch {
        $r.Steps.Add([PSCustomObject]@{ Name='AutorunsAudit'; Status='Warn'; Output=$_.Exception.Message })
    }
}

function Invoke-HostsFileCheck {
    param($r)
    Write-Log "Checking hosts file integrity..."
    try {
        $hostsPath = Get-ToolkitHostsFilePath

        if (Test-Path $hostsPath) {
            $lines   = Get-Content $hostsPath -ErrorAction Stop
            $custom  = $lines | Where-Object { $_ -notmatch '^\s*#' -and $_ -match '\S' -and $_ -notmatch '127\.0\.0\.1\s+localhost' -and $_ -notmatch '::1\s+localhost' }
            if ($null -eq $custom) { $custom = @() }
            
            $formatted = Format-HostsFileDetail -HostsPath $hostsPath -CustomEntries $custom
            Write-Log $formatted
            
            $status  = if ($custom.Count -gt 10) { 'Warn' } else { 'Pass' }
            $r.Steps.Add([PSCustomObject]@{ Name='HostsFile'; Status=$status; Output=$formatted })
        } else {
            $r.Steps.Add([PSCustomObject]@{ Name='HostsFile'; Status='Skip'; Output='Hosts file not found' })
        }
    } catch {
        $r.Steps.Add([PSCustomObject]@{ Name='HostsFile'; Status='Warn'; Output=$_.Exception.Message })
    }
}

function Invoke-BrowserExtensionScan {
    param($r)
    if ((Get-EnvironmentMode) -ne 'Windows') {
        $r.Steps.Add([PSCustomObject]@{ Name='BrowserExtensionScan'; Status='N/A'; Output='Not applicable in WinPE. Browser profile extension stores are not available as live user sessions.' }); return
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
        
        $status = if ($suspicious.Count -gt 0) { 'Warn' } else { 'Pass' }
        $r.Steps.Add([PSCustomObject]@{ Name='BrowserExtensionScan'; Status=$status; Output=$formatted })
    } catch {
        $detail = [string]$_.Exception.Message
        if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
            $detail += "`n" + [string]$_.InvocationInfo.PositionMessage
        }
        $r.Steps.Add([PSCustomObject]@{ Name='BrowserExtensionScan'; Status='Skip'; Output=$detail })
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

function Invoke-ScheduledTasksAudit {
    param($r)
    if ((Get-EnvironmentMode) -ne 'Windows') {
        $r.Steps.Add([PSCustomObject]@{ Name='ScheduledTasksAudit'; Status='N/A'; Output='Not applicable in WinPE. Requires live Task Scheduler service state.' }); return
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

        $suspect = @($tasks | Where-Object {
            $flagged = $false
            try {
                foreach ($action in @($_.Actions)) {
                    $exeProp = $action.PSObject.Properties['Execute']
                    $exe = if ($exeProp) { [string]$exeProp.Value } else { '' }
                    if ($exe -match '(?i)(temp|appdata|roaming|programdata)' -or $exe -match '(?i)\.(cmd|bat|vbs|ps1|scr)(\s|$)') {
                        $flagged = $true
                        break
                    }
                }
            }
            catch {
                Write-Log "Skipping scheduled task action review '$($_.TaskName)': $($_.Exception.Message)" -Level Verbose
            }
            $flagged
        })
        
        $formatted = Format-ScheduledTasksList -CustomTasks @($tasks) -SuspiciousTasks $suspect
        Write-Log $formatted
        
        $status = if (@($suspect).Count -gt 0) { 'Warn' } else { 'Pass' }
        $r.Steps.Add([PSCustomObject]@{ Name='ScheduledTasksAudit'; Status=$status; Output=$formatted })
    } catch {
        $r.Steps.Add([PSCustomObject]@{ Name='ScheduledTasksAudit'; Status='Skip'; Output=$_.Exception.Message })
    }
}

# â”€â”€â”€ Dispatch â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
function Get-SecurityAuditCheckDispatchMap {
    return @{
        sec_defender           = { param($r) Invoke-DefenderScan $r }
        sec_cst                = { param($r) Invoke-CoreSecurityTool $r }
        sec_autoruns           = { param($r) Invoke-AutorunsAudit $r }
        sec_hosts              = { param($r) Invoke-HostsFileCheck $r }
        sec_browser_extensions = { param($r) Invoke-BrowserExtensionScan $r }
        sec_scheduled_tasks    = { param($r) Invoke-ScheduledTasksAudit $r }
    }
}
