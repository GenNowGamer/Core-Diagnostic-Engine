#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for StorageRecovery rules, capability matrix entry, and workflow execution.
#>

$ErrorActionPreference = 'Stop'

$testsRoot = Split-Path $MyInvocation.MyCommand.Path
$toolkitRoot = Split-Path (Split-Path $testsRoot) -Parent
$rulesPath = Join-Path $toolkitRoot 'Config\StorageRecoveryRules.json'
$matrixPath = Join-Path $toolkitRoot 'Config\EnvironmentCapabilityMatrix.json'
$workflowPath = Join-Path $toolkitRoot 'Scripts\Workflows\StorageRecovery.ps1'

$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0

function Assert-True {
    param(
        [string]$Name,
        [bool]$Condition,
        [string]$Detail = ''
    )

    if ($Condition) {
        $script:passed++
        Write-Host "PASS: $Name"
        return
    }

    $message = if ([string]::IsNullOrWhiteSpace($Detail)) { $Name } else { "$Name :: $Detail" }
    $failures.Add($message) | Out-Null
    Write-Host "FAIL: $message" -ForegroundColor Red
}

Assert-True -Name 'StorageRecoveryRules.json exists' -Condition (Test-Path -LiteralPath $rulesPath -PathType Leaf)
$rules = Get-Content -LiteralPath $rulesPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True -Name 'Rules schemaVersion is 1' -Condition ($rules.schemaVersion -eq 1)
Assert-True -Name 'Default mode is ReadOnly' -Condition ($rules.safetyPolicy.defaultMode -eq 'ReadOnly')
Assert-True -Name 'System disk writes are blocked' -Condition ($rules.safetyPolicy.blockSystemDiskWrites -eq $true)
Assert-True -Name 'Pre-repair metadata snapshot is required' -Condition ($rules.safetyPolicy.requirePreRepairMetadataSnapshot -eq $true)

$matrix = Get-Content -LiteralPath $matrixPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True -Name 'EnvironmentCapabilityMatrix contains StorageRecovery' -Condition ($null -ne $matrix.workflows.StorageRecovery)

& $workflowPath -ToolName ValidateRules | Out-Null
Assert-True -Name 'StorageRecovery.ps1 ValidateRules exits 0' -Condition ($LASTEXITCODE -eq 0)

Write-Host "`n--- SUMMARY ---" -ForegroundColor Cyan
Write-Host "Passed: $passed"
Write-Host "Failed: $($failures.Count)"
if ($failures.Count -gt 0) {
    exit 1
}
exit 0
