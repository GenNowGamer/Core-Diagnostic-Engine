#Requires -Version 5.1
<#
.SYNOPSIS
    Verifies startup audit review labeling and suspicious-entry reasons.
#>

$ErrorActionPreference = 'Stop'

$coreRoot = Join-Path (Split-Path $MyInvocation.MyCommand.Path) '..\Core'
. (Join-Path $coreRoot 'StartupRisk.ps1')

$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) {
        $script:passed++
        Write-Host "PASS: $Name"
        return
    }

    $msg = if ($Detail) { "$Name :: $Detail" } else { $Name }
    $script:failures.Add($msg) | Out-Null
    Write-Host "FAIL: $msg"
}

$assessment = Test-PostOpStartupSuspicious `
    -Name 'OneDriveSetup' `
    -SourceGroup 'HKCU Run' `
    -ResolvedPath 'C:\Windows\System32\cmd.exe' `
    -Publisher 'Microsoft Corporation' `
    -IsSigned:$true `
    -RiskBand 'Safe' `
    -IsRunOnce:$true `
    -TargetExists:$true

Assert-True -Name 'RunOnce entry flagged for review' -Condition $assessment.IsSuspicious
Assert-True -Name 'RunOnce reason present' -Condition ($assessment.Reasons -contains 'RunOnce key')

$auditScript = Get-Content -LiteralPath (Join-Path $coreRoot 'SystemAuditChecks.ps1') -Raw
Assert-True -Name 'Startup audit uses Review summary label' -Condition ($auditScript -match '\| Review: \$reviewCount \|')
Assert-True -Name 'Startup audit uses REVIEW tag' -Condition ($auditScript -match "'\[REVIEW\]'")
Assert-True -Name 'Startup audit no longer uses Suspicious summary label' -Condition ($auditScript -notmatch '\| Suspicious: \$')

Write-Host ''
Write-Host "Passed: $passed"
Write-Host "Failed: $($failures.Count)"

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) {
        Write-Host $failure
    }
    exit 1
}

exit 0
