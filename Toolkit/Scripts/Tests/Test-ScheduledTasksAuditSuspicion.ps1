#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Scheduled Tasks Audit suspicion heuristics (false-positive reduction).
#>

$ErrorActionPreference = 'Stop'

$coreRoot = Join-Path (Split-Path $MyInvocation.MyCommand.Path) '..\Core'
Import-Module (Join-Path $coreRoot 'Toolkit.Core.psm1') -Force -DisableNameChecking
. (Join-Path $coreRoot 'SecurityAuditChecks.ps1')

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

Write-Host 'Test-ScheduledTasksAuditSuspicion'

# --- OneDrive under AppData, Microsoft-signed → NOT suspicious (was false positive) ---
$oneDrive = Test-ScheduledTaskExecuteSuspicious `
    -Execute '%localappdata%\Microsoft\OneDrive\OneDriveStandaloneUpdate.exe' `
    -Arguments '/reporting' `
    -TaskName 'OneDrive Reporting Task' `
    -ResolvedPath 'C:\Users\a350776\AppData\Local\Microsoft\OneDrive\OneDriveStandaloneUpdate.exe' `
    -TargetExists:$true `
    -IsSigned:$true `
    -SignedBy 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'

Assert-True -Name 'OneDrive AppData Microsoft-signed not flagged' -Condition (-not $oneDrive.IsSuspicious)

$oneDriveLauncher = Test-ScheduledTaskExecuteSuspicious `
    -Execute 'C:\Users\a350776\AppData\Local\Microsoft\OneDrive\24.113.0614.0004\OneDriveLauncher.exe' `
    -Arguments '/startinstances' `
    -ResolvedPath 'C:\Users\a350776\AppData\Local\Microsoft\OneDrive\24.113.0614.0004\OneDriveLauncher.exe' `
    -TargetExists:$true `
    -IsSigned:$true `
    -SignedBy 'CN=Microsoft Corporation'

Assert-True -Name 'OneDriveLauncher Microsoft-signed not flagged' -Condition (-not $oneDriveLauncher.IsSuspicious)

# --- Edge Update in Program Files → NOT suspicious ---
$edge = Test-ScheduledTaskExecuteSuspicious `
    -Execute 'C:\Program Files (x86)\Microsoft\EdgeUpdate\MicrosoftEdgeUpdate.exe' `
    -ResolvedPath 'C:\Program Files (x86)\Microsoft\EdgeUpdate\MicrosoftEdgeUpdate.exe' `
    -TargetExists:$true `
    -IsSigned:$true `
    -SignedBy 'CN=Microsoft Corporation'

Assert-True -Name 'Edge Update Program Files not flagged' -Condition (-not $edge.IsSuspicious)

# --- Unsigned under AppData → suspicious ---
$unsignedAppData = Test-ScheduledTaskExecuteSuspicious `
    -Execute 'C:\Users\bob\AppData\Roaming\EvilCorp\update.exe' `
    -ResolvedPath 'C:\Users\bob\AppData\Roaming\EvilCorp\update.exe' `
    -TargetExists:$true `
    -IsSigned:$false `
    -SignedBy ''

Assert-True -Name 'Unsigned AppData flagged' -Condition $unsignedAppData.IsSuspicious
Assert-True -Name 'Unsigned AppData reason' -Condition ($unsignedAppData.Reasons -contains 'unsigned in user-writable path')

# --- Temp path → always suspicious ---
$temp = Test-ScheduledTaskExecuteSuspicious `
    -Execute 'C:\Users\bob\AppData\Local\Temp\payload.exe' `
    -ResolvedPath 'C:\Users\bob\AppData\Local\Temp\payload.exe' `
    -TargetExists:$true `
    -IsSigned:$true `
    -SignedBy 'CN=Microsoft Corporation'

Assert-True -Name 'Temp path flagged even if signed' -Condition $temp.IsSuspicious
Assert-True -Name 'Temp path reason' -Condition ($temp.Reasons -contains 'risky path')

# --- Script action → suspicious ---
$script = Test-ScheduledTaskExecuteSuspicious `
    -Execute 'C:\Program Files\Vendor\run.cmd' `
    -ResolvedPath 'C:\Program Files\Vendor\run.cmd' `
    -TargetExists:$true `
    -IsSigned:$false `
    -SignedBy ''

Assert-True -Name 'Script action flagged' -Condition $script.IsSuspicious
Assert-True -Name 'Script action reason' -Condition ($script.Reasons -contains 'script action')

# --- Empty Execute flagged ---
$unknown = Test-ScheduledTaskExecuteSuspicious -Execute ''
Assert-True -Name 'Empty Execute flagged' -Condition $unknown.IsSuspicious
Assert-True -Name 'Empty Execute reason' -Condition ($unknown.Reasons -contains 'unknown action')

# --- Missing target under AppData → suspicious ---
$missing = Test-ScheduledTaskExecuteSuspicious `
    -Execute 'C:\Users\bob\AppData\Local\Ghost\gone.exe' `
    -ResolvedPath 'C:\Users\bob\AppData\Local\Ghost\gone.exe' `
    -TargetExists:$false `
    -IsSigned:$false `
    -SignedBy ''

Assert-True -Name 'Missing AppData target flagged' -Condition $missing.IsSuspicious
Assert-True -Name 'Missing AppData reason' -Condition ($missing.Reasons -contains 'missing target in user-writable path')

# --- Untrusted publisher under AppData → suspicious ---
$untrusted = Test-ScheduledTaskExecuteSuspicious `
    -Execute 'C:\Users\bob\AppData\Local\OddSoft\agent.exe' `
    -ResolvedPath 'C:\Users\bob\AppData\Local\OddSoft\agent.exe' `
    -TargetExists:$true `
    -IsSigned:$true `
    -SignedBy 'CN=Totally Fine LLC'

Assert-True -Name 'Untrusted publisher AppData flagged' -Condition $untrusted.IsSuspicious
Assert-True -Name 'Untrusted publisher reason' -Condition ($untrusted.Reasons -contains 'untrusted publisher in user-writable path')

# --- SoftLanding-style COM under Windows\SystemApps, Microsoft-signed → NOT suspicious ---
$softLanding = Test-ScheduledTaskComActionSuspicious `
    -ClassId '{b7165223-97ba-4324-a037-f95310f20207}' `
    -ResolvedServerPath 'C:\Windows\SystemApps\Microsoft.Windows.ContentDeliveryManager_cw5n1h2txyewy\SoftLandingTask.exe' `
    -TargetExists:$true `
    -IsSigned:$true `
    -SignedBy 'CN=Microsoft Windows, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'

Assert-True -Name 'SoftLanding COM Microsoft SystemApps not flagged' -Condition (-not $softLanding.IsSuspicious)

# --- COM with unresolved ClassId → suspicious ---
$comUnresolved = Test-ScheduledTaskComActionSuspicious `
    -ClassId '{11111111-2222-3333-4444-555555555555}' `
    -ResolvedServerPath '' `
    -TargetExists:$false `
    -IsSigned:$false `
    -SignedBy ''

Assert-True -Name 'Unresolved COM handler flagged' -Condition $comUnresolved.IsSuspicious
Assert-True -Name 'Unresolved COM reason' -Condition ($comUnresolved.Reasons -contains 'unresolved COM handler')

# --- COM under AppData unsigned → suspicious ---
$comUnsigned = Test-ScheduledTaskComActionSuspicious `
    -ClassId '{aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee}' `
    -ResolvedServerPath 'C:\Users\bob\AppData\Local\Evil\handler.dll' `
    -TargetExists:$true `
    -IsSigned:$false `
    -SignedBy ''

Assert-True -Name 'Unsigned COM AppData flagged' -Condition $comUnsigned.IsSuspicious
Assert-True -Name 'Unsigned COM AppData reason' -Condition ($comUnsigned.Reasons -contains 'unsigned in user-writable path')

# --- Full task object: COM ClassId without Execute is classified as Com (not blank Exec) ---
$comTaskOk = [PSCustomObject]@{
    TaskName = 'SoftLandingCreativeManagementTask'
    TaskPath = '\SoftLanding\S-1-5-21-1000\'
    State = 'Ready'
    Actions = [PSCustomObject]@{
        Execute = ''
        Arguments = ''
        ClassId = '{b7165223-97ba-4324-a037-f95310f20207}'
        CimClass = [PSCustomObject]@{ CimClassName = 'MSFT_TaskComHandlerAction' }
    }
}
# Monkey-patch Resolve for this task by testing Com helper; task-level uses live resolve.
# Ensure Get-ScheduledTaskActionKind sees ComHandler:
$kind = Get-ScheduledTaskActionKind -Action $comTaskOk.Actions
Assert-True -Name 'COM handler action kind is Com' -Condition ($kind -eq 'Com')

# Verify Get-ScheduledTaskActionDisplay shows COM ClassId
$display = Get-ScheduledTaskActionDisplay -Action $comTaskOk.Actions
Assert-True -Name 'COM action display includes ClassId' -Condition ($display -match 'COM \{b7165223')

# --- Format shows Review Reason when present ---
$sketchy = [PSCustomObject]@{
    TaskName = 'Sketchy'
    TaskPath = '\Startup\'
    State = 'Ready'
    Actions = [PSCustomObject]@{ Execute = 'C:\Users\Public\runme.cmd'; Arguments = '' }
    SuspiciousReasons = @('script action', 'risky path')
}
$formatted = Format-ScheduledTasksList -CustomTasks @($sketchy) -SuspiciousTasks @($sketchy)
Assert-True -Name 'Format includes Review Reason' -Condition ($formatted -match 'Review Reason')
Assert-True -Name 'Format includes script action reason text' -Condition ($formatted -match 'script action')

$comFormatTask = [PSCustomObject]@{
    TaskName = 'SoftLandingDeferralTask'
    TaskPath = '\SoftLanding\S-1-5-21-1000\'
    State = 'Ready'
    Actions = [PSCustomObject]@{ Execute = ''; ClassId = '{b7165223-97ba-4324-a037-f95310f20207}'; Arguments = '' }
}
$comFormatted = Format-ScheduledTasksList -CustomTasks @($comFormatTask) -SuspiciousTasks @()
Assert-True -Name 'Format shows COM ClassId not Unknown' -Condition ($comFormatted -match 'COM \{b7165223' -and $comFormatted -notmatch 'Action\s+:\s+Unknown')

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "Test-ScheduledTasksAuditSuspicion: FAIL ($($failures.Count) failure(s), $passed passed)"
    foreach ($f in $failures) { Write-Host "  - $f" }
    exit 1
}

Write-Host "Test-ScheduledTasksAuditSuspicion: PASS ($passed assertions)"
exit 0
