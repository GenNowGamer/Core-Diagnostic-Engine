#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$testsRoot = Split-Path $MyInvocation.MyCommand.Path
$toolkitRoot = Join-Path $testsRoot '..\..'
$flowsPath = Join-Path $toolkitRoot 'Config\SymptomFlows.json'
$catalogPath = Join-Path $toolkitRoot 'Config\HealthCheckCatalog.json'

if (-not (Test-Path -LiteralPath $flowsPath)) {
    Write-Error "Symptom flows config missing: $flowsPath"
    exit 1
}

if (-not (Test-Path -LiteralPath $catalogPath)) {
    Write-Error "Health check catalog missing: $catalogPath"
    exit 1
}

$flows = Get-Content -LiteralPath $flowsPath -Raw | ConvertFrom-Json
$catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json

$knownNavSections = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
@(
    'Dashboard', 'SystemHealth', 'SystemAudit', 'ChuResults', 'SmartAnalyzer',
    'DiagAndRepair', 'HardwareDiagnostics', 'OSRepair', 'MalwareCleanup',
    'BootloaderRepair', 'BackupAndImaging', 'PostOp', 'HijackRepair', 'ToolsLibrary',
    'FileManager', 'StartupManager', 'ProcessAnalyzer', 'TempFileCleaner',
    'UninstallManager', 'FastFixes', 'Settings'
) | ForEach-Object { [void]$knownNavSections.Add($_) }

if (-not $flows.flows -or @($flows.flows).Count -lt 1) {
    Write-Error 'SymptomFlows.json must define at least one flow.'
    exit 1
}

$seenFlowIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($flow in @($flows.flows)) {
    $flowId = [string]$flow.id
    if ([string]::IsNullOrWhiteSpace($flowId)) {
        Write-Error 'Symptom flow is missing id.'
        exit 1
    }

    if (-not $seenFlowIds.Add($flowId)) {
        Write-Error "Duplicate symptom flow id: $flowId"
        exit 1
    }

    $preset = [string]$flow.healthPreset
    if ([string]::IsNullOrWhiteSpace($preset)) {
        Write-Error "Symptom flow '$flowId' is missing healthPreset."
        exit 1
    }

    if (-not $catalog.presets.PSObject.Properties[$preset]) {
        Write-Error "Symptom flow '$flowId' references unknown health preset: $preset"
        exit 1
    }

    $followUps = @($flow.followUps)
    if ($followUps.Count -lt 1) {
        Write-Error "Symptom flow '$flowId' must define at least one followUp."
        exit 1
    }

    foreach ($followUp in $followUps) {
        $target = [string]$followUp.target
        if ([string]::IsNullOrWhiteSpace($target)) {
            Write-Error "Symptom flow '$flowId' has a followUp without target."
            exit 1
        }

        $section = $target
        $colon = $target.IndexOf(':')
        if ($colon -gt 0) {
            $section = $target.Substring(0, $colon)
        }

        if (-not $knownNavSections.Contains($section)) {
            Write-Error "Symptom flow '$flowId' followUp target '$target' uses unknown nav section: $section"
            exit 1
        }
    }
}

Write-Host "Test-SymptomFlowsCatalog: PASS ($($seenFlowIds.Count) flows)"
exit 0
