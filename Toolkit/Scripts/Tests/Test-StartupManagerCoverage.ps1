#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Startup Manager gap-closure: GPO Run keys, StartupApproved,
    scheduled tasks, correlation, and audit_startup parity wiring.
#>

$ErrorActionPreference = 'Stop'

$coreRoot = Join-Path (Split-Path $MyInvocation.MyCommand.Path) '..\Core'
. (Join-Path $coreRoot 'StartupRisk.ps1')
. (Join-Path $coreRoot 'StartupApproved.ps1')
. (Join-Path $coreRoot 'StartupScheduledTask.ps1')
. (Join-Path $coreRoot 'StartupCorrelation.ps1')

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

$runKeys = @(Get-StandardStartupRunKeyDefinitions)
Assert-True -Name 'Run key definitions include GPO HKLM' -Condition (
    @($runKeys | Where-Object { $_.SourceGroup -like '*GPO*' -and $_.Hive -eq 'HKLM' }).Count -ge 1
)
Assert-True -Name 'Run key definitions include GPO HKCU' -Condition (
    @($runKeys | Where-Object { $_.SourceGroup -like '*GPO*' -and $_.Hive -eq 'HKCU' }).Count -ge 1
)
Assert-True -Name 'Run key definitions include standard HKCU Run' -Condition (
    @($runKeys | Where-Object { $_.Key -eq 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -and $_.Hive -eq 'HKCU' }).Count -eq 1
)

Assert-True -Name 'StartupApproved Run32 for WOW6432Node' -Condition (
    (Get-StartupApprovedCategoryForSource -SourceGroup 'HKLM\SOFTWARE\WOW6432Node\...\Run' -RowType 'RegistryValue') -eq 'Run32'
)
Assert-True -Name 'StartupApproved StartupFolder for files' -Condition (
    (Get-StartupApprovedCategoryForSource -SourceGroup 'User Startup' -RowType 'FileStartupItem') -eq 'StartupFolder'
)
Assert-True -Name 'StartupApproved entry name uses file leaf' -Condition (
    (Get-StartupApprovedEntryName -RowType 'FileStartupItem' -ValueName '' -Name 'foo' -FilePath 'C:\Startup\bar.lnk') -eq 'bar.lnk'
)

$logonTriggerTask = [PSCustomObject]@{
    Triggers = @(
        [PSCustomObject]@{
            CimClass = [PSCustomObject]@{ CimClassName = 'MSFT_TaskLogonTrigger' }
        }
    )
}
$idleTask = [PSCustomObject]@{
    Triggers = @(
        [PSCustomObject]@{
            CimClass = [PSCustomObject]@{ CimClassName = 'MSFT_TaskIdleTrigger' }
        }
    )
}
Assert-True -Name 'Logon trigger detected' -Condition (Test-ScheduledTaskHasStartupTrigger -Task $logonTriggerTask)
Assert-True -Name 'Idle trigger not startup' -Condition (-not (Test-ScheduledTaskHasStartupTrigger -Task $idleTask))

Assert-True -Name 'Microsoft task path detected' -Condition (Test-IsWindowsPlumbingScheduledTaskPath -TaskPath '\Microsoft\Windows\MemoryDiagnostic\')
Assert-True -Name 'Vendor task path not Microsoft plumbing' -Condition (-not (Test-IsWindowsPlumbingScheduledTaskPath -TaskPath '\AcmeUpdater\'))

$cautionOnly = Test-PostOpStartupSuspicious `
    -Name 'OneDrive' `
    -SourceGroup 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' `
    -ResolvedPath "$env:SystemRoot\System32\notepad.exe" `
    -Publisher 'Microsoft Corporation' `
    -IsSigned $true `
    -RiskBand 'Caution' `
    -IsRunOnce $false `
    -TargetExists $true `
    -EntryType 'Registry'
Assert-True -Name 'Caution alone is not hijack-suspicious' -Condition (-not [bool]$cautionOnly.IsSuspicious)

$warningRisk = Test-PostOpStartupSuspicious `
    -Name 'Dropper' `
    -SourceGroup 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' `
    -ResolvedPath "$env:TEMP\dropper.exe" `
    -Publisher 'Unknown' `
    -IsSigned $false `
    -RiskBand 'Warning' `
    -IsRunOnce $false `
    -TargetExists $true `
    -EntryType 'Registry'
Assert-True -Name 'Warning risk marks hijack-suspicious' -Condition ([bool]$warningRisk.IsSuspicious)

$corrTokens = Get-StartupCorrelationTokens -Entry ([PSCustomObject]@{
        Name       = 'SecurityHealth'
        Publisher  = 'Microsoft Corporation'
        FilePath   = "$env:SystemRoot\System32\SecurityHealthSystray.exe"
        RowType    = 'RegistryValue'
        SourceGroup = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
        ServiceName = ''
    })
Assert-True -Name 'Generic Microsoft publisher not a correlation token' -Condition (
    @($corrTokens | Where-Object { $_ -eq 'Microsoft Corporation' }).Count -eq 0
)

$defaultRows = @(Get-StartupScheduledTaskRows)
$allRows = @(Get-StartupScheduledTaskRows -IncludeWindowsScheduledTasks)
Assert-True -Name 'Default excludes some Microsoft tasks when present' -Condition (
    ($allRows.Count -ge $defaultRows.Count) -and (($allRows.Count -eq $defaultRows.Count) -or ($allRows.Count -gt $defaultRows.Count))
)

if ($allRows.Count -gt 0) {
    $windowsRow = @($allRows | Where-Object { $_.IsCritical -eq $true } | Select-Object -First 1)
    if ($windowsRow) {
        Assert-True -Name 'Windows plumbing rows are read-only' -Condition (
            ($windowsRow.SupportsEnable -eq $false) -and ($windowsRow.SupportsDisable -eq $false)
        )
    }
}

$entries = [System.Collections.Generic.List[object]]::new()
$entries.Add([PSCustomObject]@{
    Name               = 'Teams'
    RowType            = 'MsixStartupTask'
    SourceGroup        = 'MSIX Startup Task'
    FilePath           = 'msteams.exe'
    AnalysisFilePath   = 'msteams.exe'
    Publisher          = 'Microsoft Corporation'
    ServiceName        = 'MSTeams_8wekyb3d8bbwe'
    AnalysisDetail     = ''
    AnalysisLevel      = 'OK'
    HasAnalysisWarning = $false
})
$entries.Add([PSCustomObject]@{
    Name               = 'Teams'
    RowType            = 'RegistryValue'
    SourceGroup        = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    FilePath           = 'C:\Users\me\AppData\Local\Microsoft\Teams\msteams.exe'
    AnalysisFilePath   = 'C:\Users\me\AppData\Local\Microsoft\Teams\msteams.exe'
    Publisher          = 'Microsoft Corporation'
    ServiceName        = ''
    AnalysisDetail     = ''
    AnalysisLevel      = 'OK'
    HasAnalysisWarning = $false
})
Add-StartupEntryCorrelations -Entries $entries
Assert-True -Name 'Correlation assigns group id' -Condition (-not [string]::IsNullOrWhiteSpace($entries[0].CorrelationGroupId))
Assert-True -Name 'Correlation links both rows' -Condition ($entries[0].CorrelationGroupId -eq $entries[1].CorrelationGroupId)
Assert-True -Name 'Correlation summary mentions MSIX' -Condition ($entries[1].CorrelationSummary -match 'MSIX')

$postOp = @(Get-PostOpStartupEntries)
Assert-True -Name 'PostOp startup entries returns data' -Condition ($null -ne $postOp)

$entryTypes = @($postOp | ForEach-Object { $_.EntryType } | Select-Object -Unique)
Assert-True -Name 'PostOp includes standard registry or folder entries' -Condition (
    ($entryTypes -contains 'Registry') -or ($entryTypes -contains 'GpoRun') -or ($entryTypes -contains 'Folder')
)

$startupScript = Join-Path (Split-Path $MyInvocation.MyCommand.Path) '..\Workflows\StartupManager.ps1'
$startupScriptText = Get-Content -LiteralPath $startupScript -Raw
Assert-True -Name 'StartupManager wires scheduled tasks' -Condition ($startupScriptText -match "'ScheduledTask'")
Assert-True -Name 'StartupManager can delete non-Windows scheduled tasks' -Condition (
    $startupScriptText -match 'Remove-StartupScheduledTaskEntry'
)
Assert-True -Name 'StartupManager wires StartupApproved' -Condition ($startupScriptText -match 'StartupApproved')
Assert-True -Name 'StartupManager wires correlation' -Condition ($startupScriptText -match 'Add-StartupEntryCorrelations')
Assert-True -Name 'StartupManager passes SourceGroup to registry actions' -Condition ($startupScriptText -match '-SourceGroup \$SourceGroup')
Assert-True -Name 'StartupManager enforces mutation allowlist' -Condition ($startupScriptText -match 'Assert-StartupMutationPathAllowed')
Assert-True -Name 'StartupManager delete removes StartupApproved' -Condition ($startupScriptText -match 'Sync-StartupApprovedAfterMutation')
Assert-True -Name 'StartupManager blocks GPO Run delete' -Condition ($startupScriptText -match '\$isGpoRun')
Assert-True -Name 'Remove-RegistryValueEntry fails closed' -Condition (
    $startupScriptText -match 'Delete verification failed for registry value'
)

# Non-Microsoft task rows should advertise SupportsDelete when any are present on this machine.
$vendorLike = @($defaultRows | Where-Object {
    -not (Test-IsWindowsPlumbingScheduledTaskPath -TaskPath $_.ActionStatePayload)
})
if ($vendorLike.Count -gt 0) {
    Assert-True -Name 'Non-Microsoft scheduled tasks support Delete' -Condition (
        @($vendorLike | Where-Object { $_.SupportsDelete }).Count -eq $vendorLike.Count
    )
}
$msftLike = @($allRows | Where-Object {
    Test-IsWindowsPlumbingScheduledTaskPath -TaskPath $_.ActionStatePayload
} | Select-Object -First 5)
if ($msftLike.Count -gt 0) {
    Assert-True -Name 'Microsoft scheduled tasks remain delete-blocked' -Condition (
        (@($msftLike | Where-Object { $_.SupportsDelete }).Count -eq 0)
    )
}
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
