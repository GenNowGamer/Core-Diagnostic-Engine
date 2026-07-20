#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for autorun/task publisher-aware finding tiers (P0-6).
#>
$ErrorActionPreference = 'Stop'

$testsRoot = Split-Path $MyInvocation.MyCommand.Path
$coreDir = Join-Path $testsRoot '..\Core'
. (Join-Path $coreDir 'HealthFindings.ps1')
. (Join-Path $coreDir 'SecurityAuditChecks.ps1')

$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0

function Assert-Eq {
    param([string]$Name, $Expected, $Actual)
    if ("$Expected" -eq "$Actual") {
        $script:passed++
        Write-Host "PASS: $Name"
        return
    }
    $script:failures.Add("$Name :: expected=$Expected actual=$Actual") | Out-Null
    Write-Host "FAIL: $Name :: expected=$Expected actual=$Actual"
}

function Assert-True {
    param([string]$Name, [bool]$Condition)
    if ($Condition) {
        $script:passed++
        Write-Host "PASS: $Name"
        return
    }
    $script:failures.Add($Name) | Out-Null
    Write-Host "FAIL: $Name"
}

Write-Host 'Test-PublisherAwareScoring'

Assert-True -Name 'Microsoft Corporation trusted' `
    -Condition (Test-IsTrustedAuthenticodePublisher -SignedBy 'CN=Microsoft Corporation, O=Microsoft Corporation')
Assert-True -Name 'Totally Fine LLC not trusted' `
    -Condition (-not (Test-IsTrustedAuthenticodePublisher -SignedBy 'CN=Totally Fine LLC'))
Assert-True -Name 'Empty signer not trusted' `
    -Condition (-not (Test-IsTrustedAuthenticodePublisher -SignedBy ''))
Assert-True -Name 'Scheduled-task alias matches Authenticode helper' `
    -Condition ((Test-IsTrustedScheduledTaskPublisher -SignedBy 'CN=Google LLC') -eq $true)

$deviated = Resolve-AutorunPublisherFindingTier -IsDeviated:$true -PublisherTrusted:$false
Assert-Eq -Name 'Deviated classification' -Expected 'CorroboratedSuspect' -Actual $deviated.Classification
Assert-Eq -Name 'Deviated severity' -Expected 'High' -Actual $deviated.Severity
Assert-True -Name 'Deviated requires attention' -Condition $deviated.Attention

$trusted = Resolve-AutorunPublisherFindingTier -IsDeviated:$false -PublisherTrusted:$true
Assert-Eq -Name 'Trusted path classification' -Expected 'Inventory' -Actual $trusted.Classification
Assert-Eq -Name 'Trusted path status' -Expected 'Info' -Actual $trusted.Status
Assert-True -Name 'Trusted path not attention' -Condition (-not $trusted.Attention)
Assert-True -Name 'Trusted path attention filter' -Condition (
    -not (Test-HealthFindingRequiresAttention -Classification $trusted.Classification -Status $trusted.Status -Severity $trusted.Severity -Confidence $trusted.Confidence)
)

$unsigned = Resolve-AutorunPublisherFindingTier -IsDeviated:$false -PublisherTrusted:$false
Assert-Eq -Name 'Unsigned path classification' -Expected 'SingleSignal' -Actual $unsigned.Classification
Assert-Eq -Name 'Unsigned path severity' -Expected 'Medium' -Actual $unsigned.Severity
Assert-True -Name 'Unsigned path attention filter' -Condition (
    Test-HealthFindingRequiresAttention -Classification $unsigned.Classification -Status $unsigned.Status -Severity $unsigned.Severity -Confidence $unsigned.Confidence
)

$temp = Resolve-ScheduledTaskSuspiciousFindingTier -Reasons @('risky path')
Assert-Eq -Name 'Temp path severity' -Expected 'High' -Actual $temp.Severity
Assert-Eq -Name 'Temp path classification' -Expected 'SingleSignal' -Actual $temp.Classification

$combo = Resolve-ScheduledTaskSuspiciousFindingTier -Reasons @('script action', 'risky path')
Assert-Eq -Name 'Script+Temp classification' -Expected 'CorroboratedSuspect' -Actual $combo.Classification
Assert-Eq -Name 'Script+Temp severity' -Expected 'High' -Actual $combo.Severity

$writableUnsigned = Resolve-ScheduledTaskSuspiciousFindingTier -Reasons @('unsigned in user-writable path')
Assert-Eq -Name 'Writable unsigned severity' -Expected 'Medium' -Actual $writableUnsigned.Severity
Assert-Eq -Name 'Writable unsigned classification' -Expected 'SingleSignal' -Actual $writableUnsigned.Classification

$untrusted = Resolve-ScheduledTaskSuspiciousFindingTier -Reasons @('untrusted publisher in user-writable path')
Assert-Eq -Name 'Untrusted publisher severity' -Expected 'Medium' -Actual $untrusted.Severity

if ($failures.Count -gt 0) {
    Write-Host "Test-PublisherAwareScoring: FAIL ($($failures.Count) failure(s), $passed passed)"
    foreach ($f in $failures) { Write-Host "  - $f" }
    exit 1
}

Write-Host "Test-PublisherAwareScoring: PASS ($passed assertions)"
exit 0
