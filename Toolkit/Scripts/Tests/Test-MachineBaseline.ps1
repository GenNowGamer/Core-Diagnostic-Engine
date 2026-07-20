#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$testsRoot = Split-Path $MyInvocation.MyCommand.Path
$coreDir = Join-Path $testsRoot '..\Core'
Import-Module (Join-Path $coreDir 'Toolkit.Core.psm1') -Force -DisableNameChecking
. (Join-Path $coreDir 'HealthFindings.ps1')
. (Join-Path $coreDir 'MachineBaseline.ps1')

$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0

function Assert-True([string]$Name, [bool]$Condition) {
    if ($Condition) { $script:passed++; Write-Host "PASS: $Name"; return }
    $script:failures.Add($Name) | Out-Null
    Write-Host "FAIL: $Name"
}

function Assert-Eq([string]$Name, $Expected, $Actual) {
    if ("$Expected" -eq "$Actual") { $script:passed++; Write-Host "PASS: $Name"; return }
    $script:failures.Add("$Name :: expected=$Expected actual=$Actual") | Out-Null
    Write-Host "FAIL: $Name :: expected=$Expected actual=$Actual"
}

Write-Host 'Test-MachineBaseline'

$id = Get-CdeMachineBaselineId
Assert-True -Name 'Machine id non-empty' -Condition (-not [string]::IsNullOrWhiteSpace($id))

$testId = 'cde_baseline_unit_test'
$path = Get-CdeMachineBaselinePath -MachineId $testId
if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }

$prior = [PSCustomObject]@{
    schemaVersion = 1
    machineId     = $testId
    capturedUtc   = [datetime]::UtcNow.AddDays(-1).ToString('o')
    overallHealth = 'Healthy'
    vitals        = @{ cpu_load = 10 }
    smart         = @{ ata_5 = 1; ata_199 = 2 }
    findings      = @([PSCustomObject]@{ findingId = 'old.fault'; classification = 'ConfirmedFault'; status = 'Fail'; severity = 'Critical'; confidence = 95 })
}
Export-CdeMachineBaseline -Baseline $prior -MachineId $testId | Out-Null
$loaded = Import-CdeMachineBaseline -MachineId $testId
Assert-True -Name 'Baseline loads' -Condition ($null -ne $loaded)
Assert-Eq -Name 'Loaded machineId' -Expected $testId -Actual $loaded.machineId

$deltas = @(Compare-CdeSmartBaselineDelta -PriorSmart $loaded.smart -CurrentSmart @{ ata_5 = 4; ata_199 = 2 })
Assert-True -Name 'SMART growth detected' -Condition ($deltas.Count -eq 1 -and $deltas[0].Key -eq 'ata_5' -and $deltas[0].Delta -eq 3)

$wf = [PSCustomObject]@{
    WorkflowName  = 'SystemHealthCheck'
    OverallHealth = 'Warning'
    Steps         = [System.Collections.ArrayList]@(
        [PSCustomObject]@{
            Name = 'CriticalEvents'; Status = 'Fail'; CheckId = 'critical_events_7d'; Detail = 'x'; Output = 'body'
            StructuredFindings = @(
                [PSCustomObject]@{
                    findingId = 'event.new_bsod'; classification = 'ConfirmedFault'; status = 'Fail'
                    severity = 'Critical'; confidence = 98; evidence = @(); recommendations = @(); actions = @()
                    finding = 'BSOD'; impact = 'x'; checkId = 'critical_events_7d'; subject = ''
                }
            )
        }
    )
}

# Point compare at our test baseline by temporarily using test machine id via env? 
# Invoke-HealthBaselineDelta uses Get-CdeMachineBaselineId — override by saving under real id is hard.
# Unit-test Add path via Invoke with imported prior already validated; test New-CdeMachineBaselineFromWorkflow:

$snap = New-CdeMachineBaselineFromWorkflow -WorkflowResult $wf
Assert-True -Name 'Snapshot has findings' -Condition ($snap.findings.Count -ge 1)
Assert-Eq -Name 'Snapshot finding id' -Expected 'event.new_bsod' -Actual $snap.findings[0].findingId

# Fingerprint from text
$fp = Get-CdeSmartBaselineFingerprint -Text "Attr 5 Reallocated Sectors 12`nMediaErrors: 3"
Assert-Eq -Name 'Fingerprint ata_5' -Expected '12' -Actual ([string]$fp['ata_5'])
Assert-Eq -Name 'Fingerprint media' -Expected '3' -Actual ([string]$fp['nvme_media_errors'])

Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue

if ($failures.Count -gt 0) {
    Write-Host "Test-MachineBaseline: FAIL ($($failures.Count))"
    foreach ($f in $failures) { Write-Host "  - $f" }
    exit 1
}

Write-Host "Test-MachineBaseline: PASS ($passed assertions)"
exit 0
