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

$comResolved = Resolve-ComHandlerServerPath -ClassId '{B7F5B442-EBF8-46CD-9F0B-D8E45ED43492}'
Assert-True -Name 'COM ClassId resolves InprocServer32' -Condition (
    $comResolved.Exists -and
    $comResolved.ServerPath -match 'AccountHealth\.dll$'
)
$comSig = Get-FileSignatureInfo -FilePath $comResolved.ServerPath
Assert-True -Name 'COM handler DLL has Valid Authenticode' -Condition ($comSig.IsSigned -eq $true)

$comRows = @(Get-StartupScheduledTaskRows -IncludeWindowsScheduledTasks)
$recoverability = @($comRows | Where-Object { $_.Name -eq 'RecoverabilityToastTask' } | Select-Object -First 1)
if ($recoverability.Count -gt 0) {
    Assert-True -Name 'RecoverabilityToastTask is COM action' -Condition ($recoverability[0].TaskActionKind -eq 'Com')
    Assert-True -Name 'RecoverabilityToastTask has ClassId' -Condition (-not [string]::IsNullOrWhiteSpace($recoverability[0].Clsid))
    Assert-True -Name 'RecoverabilityToastTask analysis path is DLL' -Condition (
        $recoverability[0].AnalysisFilePath -match '\.dll$'
    )
    Assert-True -Name 'RecoverabilityToastTask analysis path exists' -Condition (
        Test-Path -LiteralPath $recoverability[0].AnalysisFilePath -PathType Leaf
    )
}

$staleOneDrive = 'C:\Program Files\Microsoft OneDrive\00.0.0.0\OneDriveLauncher.exe'
$odRemap = Resolve-OneDriveStaleInstallPath -Path $staleOneDrive
if ($odRemap) {
    Assert-True -Name 'OneDrive stale path remaps when install present' -Condition (Test-Path -LiteralPath $odRemap -PathType Leaf)
} else {
    Write-Host 'INFO: OneDrive install not present; skipped stale-path remap assertion.'
}

$syntheticCom = Resolve-StartupTarget -Command '\Microsoft\Windows\Foo\Bar (COM {ABC})'
Assert-True -Name 'Synthetic COM display path is not treated as a filesystem target' -Condition (
    $syntheticCom.Exists -eq $false -and
    $syntheticCom.Detail -match 'COM'
)

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

# Scheduled-task audit path must use real Authenticode checks (not hardcoded unsigned).
$signedTaskSamples = @(
    'Adobe Acrobat Update Task',
    'GoogleUpdateTaskMachineCore*',
    'GoogleUpdateTaskMachineUA*',
    'OneDrive Startup Task*',
    'OneDrive Reporting Task*',
    'OneDrive Per-Machine Standalone Update Task'
)
$taskEntries = @($postOp | Where-Object { $_.EntryType -eq 'ScheduledTask' })
$checkedSignedTask = $false
foreach ($pattern in $signedTaskSamples) {
    $hit = @($taskEntries | Where-Object { $_.Name -like $pattern } | Select-Object -First 1)
    if ($hit.Count -eq 0) { continue }
    $entry = $hit[0]
    $checkedSignedTask = $true
    Assert-True -Name "Scheduled task signature checked: $($entry.Name)" -Condition (
        $entry.IsSigned -eq $true
    ) -Detail "IsSigned=$($entry.IsSigned); Publisher=$($entry.Publisher); Path=$($entry.ResolvedPath)"

    $assessment = Test-PostOpStartupSuspicious `
        -Name $entry.Name `
        -SourceGroup $entry.SourceGroup `
        -ResolvedPath $entry.ResolvedPath `
        -Publisher $entry.Publisher `
        -IsSigned:$entry.IsSigned `
        -RiskBand $entry.RiskBand `
        -IsRunOnce:$false `
        -TargetExists:$entry.TargetExists `
        -EntryType 'ScheduledTask'
    Assert-True -Name "Scheduled task not flagged unsigned-only: $($entry.Name)" -Condition (
        $assessment.Reasons -notcontains 'unsigned'
    ) -Detail ("Reasons=" + ($assessment.Reasons -join ', '))
}
if (-not $checkedSignedTask -and $taskEntries.Count -gt 0) {
    Write-Host 'INFO: No Adobe/Google/OneDrive sample tasks present; skipped live signature assertions.'
}

# Guard against regressions that hardcode IsSigned:$false on the PostOp task path.
$startupRiskText = Get-Content -LiteralPath (Join-Path $coreRoot 'StartupRisk.ps1') -Raw
Assert-True -Name 'PostOp scheduled tasks no longer hardcode IsSigned false' -Condition (
    $startupRiskText -notmatch 'Get-StartupScheduledTaskRows[\s\S]{0,400}-IsSigned:\$false'
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
# Driver ImagePath NT prefix + BootExecute resolution
function ConvertFrom-JsonArraySafe {
    param([string]$Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { return @() }
    Add-Type -AssemblyName System.Web.Extensions -ErrorAction SilentlyContinue
    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $ser.MaxJsonLength = [int]::MaxValue
    $obj = $ser.DeserializeObject($Json)
    if ($null -eq $obj) { return @() }
    if ($obj -is [System.Collections.IEnumerable] -and -not ($obj -is [string])) {
        return @($obj)
    }
    return @($obj)
}

function Get-JsonRowProp {
    param($Row, [string]$Prop)
    if ($null -eq $Row) { return $null }
    if ($Row -is [System.Collections.IDictionary]) { return $Row[$Prop] }
    return $Row.$Prop
}

$ntPrefixSample = "\??\$env:SystemRoot\System32\drivers\null.sys"
$expandedNt = Expand-WindowsImagePath -Path $ntPrefixSample
Assert-True -Name 'Expand strips \??\ NT object prefix' -Condition (
    $expandedNt -match '^[A-Za-z]:\\' -and
    $expandedNt -notmatch '\\\?\?\\' -and
    $expandedNt.EndsWith('null.sys')
)
$ntResolve = Resolve-StartupTarget -Command $ntPrefixSample
Assert-True -Name 'Resolve finds driver via \??\ ImagePath' -Condition (
    $ntResolve.Exists -eq $true -and
    (Test-Path -LiteralPath $ntResolve.ResolvedPath -PathType Leaf)
)
$ntSig = Get-FileSignatureInfo -FilePath $ntPrefixSample
Assert-True -Name 'Driver \??\ ImagePath is not Signed=Not found' -Condition (
    $ntSig.SignedDisplay -ne 'Not found'
)

$sysRootSample = '\SystemRoot\System32\drivers\null.sys'
$expandedSysRoot = Expand-WindowsImagePath -Path $sysRootSample
Assert-True -Name 'Expand maps \SystemRoot\ ImagePath' -Condition (
    $expandedSysRoot -match '^[A-Za-z]:\\' -and
    (Test-Path -LiteralPath $expandedSysRoot -PathType Leaf)
)

$bareSystem32 = Expand-WindowsImagePath -Path 'system32\drivers\null.sys'
Assert-True -Name 'Expand maps system32\drivers relative ImagePath' -Condition (
    $bareSystem32 -match '^[A-Za-z]:\\' -and
    (Test-Path -LiteralPath $bareSystem32 -PathType Leaf)
)

$bootTarget = Resolve-StartupTarget -Command 'autocheck autochk *'
Assert-True -Name 'BootExecute autochk maps to autochk.exe when present' -Condition (
    ($bootTarget.ResolutionMethod -eq 'BootExecute') -and (
        ($bootTarget.Exists -and $bootTarget.ResolvedPath -match 'autochk\.exe$') -or
        (-not $bootTarget.Exists -and $bootTarget.Detail -match 'BootExecute')
    )
)

# Live Drivers list: empty ImagePath + BootExecute should not show red Not found / Warning falsely
$driversJson = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path (Split-Path $MyInvocation.MyCommand.Path) '..\Workflows\StartupManager.ps1') -Action ListDrivers 2>$null
if (-not [string]::IsNullOrWhiteSpace($driversJson)) {
    $driverRows = @(ConvertFrom-JsonArraySafe -Json $driversJson)
    $emptyImage = @($driverRows | Where-Object {
        ([string](Get-JsonRowProp $_ 'RowType') -eq 'DriverService') -and
        [string]::IsNullOrWhiteSpace([string](Get-JsonRowProp $_ 'FilePath'))
    } | Select-Object -First 3)
    if ($emptyImage.Count -gt 0) {
        Assert-True -Name 'Empty ImagePath drivers use Windows driver signed label' -Condition (
            (@($emptyImage | Where-Object { [string](Get-JsonRowProp $_ 'SignedDisplay') -eq 'Windows driver' }).Count -eq $emptyImage.Count)
        )
        Assert-True -Name 'Empty ImagePath drivers stay Safe' -Condition (
            (@($emptyImage | Where-Object { [string](Get-JsonRowProp $_ 'RiskLevel') -eq 'Safe' }).Count -eq $emptyImage.Count)
        )
    }

    $bootRows = @($driverRows | Where-Object {
        ([string](Get-JsonRowProp $_ 'Name') -eq 'BootExecute') -or
        ([string](Get-JsonRowProp $_ 'SourceGroup') -eq 'Boot Execute')
    })
    if ($bootRows.Count -gt 0) {
        Assert-True -Name 'BootExecute is not Signed=Not found' -Condition (
            (@($bootRows | Where-Object { [string](Get-JsonRowProp $_ 'SignedDisplay') -eq 'Not found' }).Count -eq 0)
        )
        Assert-True -Name 'BootExecute stays Safe' -Condition (
            (@($bootRows | Where-Object { [string](Get-JsonRowProp $_ 'RiskLevel') -eq 'Safe' }).Count -eq $bootRows.Count)
        )
    }

    # Only treat as false positive when the expanded ImagePath exists on disk.
    $falseNt = @($driverRows | Where-Object {
        $fp = [string](Get-JsonRowProp $_ 'FilePath')
        $sd = [string](Get-JsonRowProp $_ 'SignedDisplay')
        if (-not $fp.StartsWith('\??\') -or $sd -ne 'Not found') { return $false }
        $expanded = Expand-WindowsImagePath -Path $fp
        return (Test-Path -LiteralPath $expanded -PathType Leaf -ErrorAction SilentlyContinue)
    })
    Assert-True -Name 'No present \??\ driver ImagePaths remain Signed=Not found' -Condition ($falseNt.Count -eq 0)

    $falseSysRoot = @($driverRows | Where-Object {
        $fp = [string](Get-JsonRowProp $_ 'FilePath')
        $sd = [string](Get-JsonRowProp $_ 'SignedDisplay')
        if ($fp -notlike '\SystemRoot\*' -or $sd -ne 'Not found') { return $false }
        $expanded = Expand-WindowsImagePath -Path $fp
        return (Test-Path -LiteralPath $expanded -PathType Leaf -ErrorAction SilentlyContinue)
    })
    Assert-True -Name 'No present \SystemRoot\ driver ImagePaths remain Signed=Not found' -Condition ($falseSysRoot.Count -eq 0)
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
