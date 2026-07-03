#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$testsRoot = Split-Path $MyInvocation.MyCommand.Path
$coreDir = Join-Path $testsRoot '..\Core'
$toolkitRoot = Join-Path $testsRoot '..\..'
$catalogPath = Join-Path $toolkitRoot 'Config\HealthCheckCatalog.json'

$HelpersScript = Join-Path $coreDir 'HijackRepairHelpers.ps1'
if (Test-Path $HelpersScript) { . $HelpersScript }

. (Join-Path $coreDir 'HealthChecks.ps1')
. (Join-Path $coreDir 'SystemAuditChecks.ps1')
. (Join-Path $coreDir 'SecurityAuditChecks.ps1')
. (Join-Path $coreDir 'HijackRepairChecks.ps1')
. (Join-Path $coreDir 'HealthCheckOrchestrator.ps1')

if (-not (Test-Path $catalogPath)) {
    Write-Error "Catalog missing: $catalogPath"
    exit 1
}

$catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
$catalogIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($cat in @($catalog.categories)) {
    foreach ($check in @($cat.checks)) {
        [void]$catalogIds.Add([string]$check.id)
    }
}

$health = Get-HealthCheckStepDispatchMap
$audit = Get-SystemAuditCheckDispatchMap
$security = Get-SecurityAuditCheckDispatchMap
$hijack = Get-HijackRepairCheckDispatchMap

$missing = @()
foreach ($id in $catalogIds) {
    if ($health.ContainsKey($id)) { continue }
    if ($audit.ContainsKey($id)) { continue }
    if ($security.ContainsKey($id)) { continue }
    if ($hijack.ContainsKey($id)) { continue }
    $missing += $id
}

if ($missing.Count -gt 0) {
    Write-Error ("Catalog ids without dispatcher: {0}" -f ($missing -join ', '))
    exit 1
}

$orphanDispatch = @()
foreach ($key in $health.Keys) {
    if (-not $catalogIds.Contains([string]$key)) {
        $orphanDispatch += [string]$key
    }
}

if ($orphanDispatch.Count -gt 0) {
    Write-Error ("Health dispatch keys not in catalog: {0}" -f ($orphanDispatch -join ', '))
    exit 1
}

$categoryPresetPairs = @(
    @{ CategoryId = 'quick_vitals'; PresetName = 'quick_vitals' },
    @{ CategoryId = 'deep_system'; PresetName = 'deep_system' },
    @{ CategoryId = 'system_audit'; PresetName = 'full_audit' }
)

foreach ($pair in $categoryPresetPairs) {
    $category = @($catalog.categories) | Where-Object { $_.id -eq $pair.CategoryId } | Select-Object -First 1
    if (-not $category) {
        Write-Error "Catalog category missing for preset parity: $($pair.CategoryId)"
        exit 1
    }

    $categoryIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($check in @($category.checks)) {
        [void]$categoryIds.Add([string]$check.id)
    }

    $presetProp = $catalog.presets.PSObject.Properties[$pair.PresetName]
    if (-not $presetProp) {
        Write-Error "Catalog preset missing: $($pair.PresetName)"
        exit 1
    }

    $presetIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in @($presetProp.Value)) {
        [void]$presetIds.Add([string]$id)
    }

    if ($categoryIds.Count -ne $presetIds.Count) {
        Write-Error ("Preset '$($pair.PresetName)' count mismatch with category '$($pair.CategoryId)': preset=$($presetIds.Count) category=$($categoryIds.Count)")
        exit 1
    }

    foreach ($id in $categoryIds) {
        if (-not $presetIds.Contains($id)) {
            Write-Error ("Preset '$($pair.PresetName)' missing category id: $id")
            exit 1
        }
    }
}

foreach ($presetName in @($catalog.presets.PSObject.Properties.Name)) {
    $ids = @($catalog.presets.$presetName)
    if ($ids.Count -eq 0) {
        Write-Error "Preset '$presetName' is empty"
        exit 1
    }
    foreach ($id in $ids) {
        if (-not $catalogIds.Contains($id)) {
            Write-Error "Preset '$presetName' references unknown id: $id"
            exit 1
        }
    }
}

$requiredSymptomPresets = @('slow_pc', 'suspected_malware', 'tech_support_scam', 'network_issues', 'wont_boot')
foreach ($presetName in $requiredSymptomPresets) {
    if (-not $catalog.presets.PSObject.Properties[$presetName]) {
        Write-Error "Required symptom preset missing: $presetName"
        exit 1
    }
}

foreach ($rule in @($catalog.recommendations)) {
    if (-not $catalogIds.Contains([string]$rule.whenCheckId)) {
        Write-Error "Recommendation references unknown check id: $($rule.whenCheckId)"
        exit 1
    }
    $navTarget = Get-HealthCheckRuleNavTarget -Rule $rule
    $hasActions = @($rule.actions).Count -gt 0
    if ([string]::IsNullOrWhiteSpace($navTarget) -and -not $hasActions) {
        Write-Error "Recommendation for '$($rule.whenCheckId)' has no navTarget or cde actions"
        exit 1
    }
}

Write-Host 'Test-HealthCheckCatalog: PASS'
exit 0
