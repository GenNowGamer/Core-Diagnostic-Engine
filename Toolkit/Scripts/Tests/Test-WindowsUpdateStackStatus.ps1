#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Get-WindowsUpdateStackStatus (modern wuauserv Manual default).
#>

$ErrorActionPreference = 'Stop'

$coreRoot = Join-Path (Split-Path $MyInvocation.MyCommand.Path) '..\Core'
Import-Module (Join-Path $coreRoot 'Toolkit.Core.psm1') -Force -DisableNameChecking

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

function New-WuSvc {
    param(
        [string]$Name,
        [string]$Status,
        [string]$StartType,
        [bool]$Present = $true
    )
    [PSCustomObject]@{
        Name      = $Name
        Status    = $Status
        StartType = $StartType
        Present   = $Present
    }
}

Write-Host 'Test-WindowsUpdateStackStatus'

# Screenshot baseline: modern Win11 defaults → Pass
$modernDefaults = @(
    (New-WuSvc 'wuauserv' 'Stopped' 'Manual'),
    (New-WuSvc 'UsoSvc' 'Running' 'Automatic'),
    (New-WuSvc 'bits' 'Running' 'Automatic'),
    (New-WuSvc 'WaaSMedicSvc' 'Stopped' 'Manual')
)
$r = Get-WindowsUpdateStackStatus -Services $modernDefaults
Assert-True -Name 'Modern defaults Pass' -Condition ($r.Status -eq 'Pass') -Detail $r.Summary
Assert-True -Name 'Modern defaults summary mentions defaults' -Condition ($r.Summary -match 'default')

# wuauserv Automatic + UsoSvc Automatic → Pass
$classic = @(
    (New-WuSvc 'wuauserv' 'Running' 'Automatic'),
    (New-WuSvc 'UsoSvc' 'Running' 'Automatic'),
    (New-WuSvc 'bits' 'Running' 'Automatic'),
    (New-WuSvc 'WaaSMedicSvc' 'Stopped' 'Manual')
)
$r2 = Get-WindowsUpdateStackStatus -Services $classic
Assert-True -Name 'Automatic wuauserv Pass' -Condition ($r2.Status -eq 'Pass')

# Disabled wuauserv → Fail
$disabled = @(
    (New-WuSvc 'wuauserv' 'Stopped' 'Disabled'),
    (New-WuSvc 'UsoSvc' 'Running' 'Automatic'),
    (New-WuSvc 'bits' 'Running' 'Automatic'),
    (New-WuSvc 'WaaSMedicSvc' 'Stopped' 'Manual')
)
$r3 = Get-WindowsUpdateStackStatus -Services $disabled
Assert-True -Name 'Disabled wuauserv Fail' -Condition ($r3.Status -eq 'Fail')
Assert-True -Name 'Disabled summary names wuauserv' -Condition ($r3.Summary -match 'wuauserv')

# UsoSvc Manual → Warn (orchestrator should be Automatic)
$usoManual = @(
    (New-WuSvc 'wuauserv' 'Stopped' 'Manual'),
    (New-WuSvc 'UsoSvc' 'Stopped' 'Manual'),
    (New-WuSvc 'bits' 'Running' 'Automatic'),
    (New-WuSvc 'WaaSMedicSvc' 'Stopped' 'Manual')
)
$r4 = Get-WindowsUpdateStackStatus -Services $usoManual
Assert-True -Name 'UsoSvc Manual Warn' -Condition ($r4.Status -eq 'Warn')
Assert-True -Name 'UsoSvc Manual summary' -Condition ($r4.Summary -match 'UsoSvc')

# Missing UsoSvc → Warn
$noUso = @(
    (New-WuSvc 'wuauserv' 'Stopped' 'Manual'),
    (New-WuSvc 'bits' 'Running' 'Automatic'),
    (New-WuSvc 'WaaSMedicSvc' 'Stopped' 'Manual')
)
$r5 = Get-WindowsUpdateStackStatus -Services $noUso
Assert-True -Name 'Missing UsoSvc Warn' -Condition ($r5.Status -eq 'Warn')

# Idle stack (both core stopped) with healthy start types → Pass
$idle = @(
    (New-WuSvc 'wuauserv' 'Stopped' 'Manual'),
    (New-WuSvc 'UsoSvc' 'Stopped' 'Automatic'),
    (New-WuSvc 'bits' 'Stopped' 'Manual'),
    (New-WuSvc 'WaaSMedicSvc' 'Stopped' 'Manual')
)
$r6 = Get-WindowsUpdateStackStatus -Services $idle
Assert-True -Name 'Idle healthy stack Pass' -Condition ($r6.Status -eq 'Pass')

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "Test-WindowsUpdateStackStatus: FAIL ($($failures.Count) failure(s), $passed passed)"
    foreach ($f in $failures) { Write-Host "  - $f" }
    exit 1
}

Write-Host "Test-WindowsUpdateStackStatus: PASS ($passed assertions)"
exit 0
