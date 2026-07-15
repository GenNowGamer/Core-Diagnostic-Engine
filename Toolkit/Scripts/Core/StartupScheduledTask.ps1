#Requires -Version 5.1
<#
.SYNOPSIS
    Scheduled tasks with logon/boot/registration startup triggers for Startup Manager.
#>

. (Join-Path $PSScriptRoot 'OfflineRuntime.ps1')

function Test-IsWindowsPlumbingScheduledTaskPath {
    param([string]$TaskPath)

    $normalized = if ([string]::IsNullOrWhiteSpace($TaskPath)) { '\' } else { $TaskPath }
    if (-not $normalized.StartsWith('\')) {
        $normalized = "\$normalized"
    }

    return ($normalized -match '^\\Microsoft(\\|$)')
}

function Test-ScheduledTaskHasStartupTrigger {
    param($Task)

    foreach ($trigger in @($Task.Triggers)) {
        if ($null -eq $trigger) { continue }
        $typeName = ''
        try {
            $typeName = [string]$trigger.CimClass.CimClassName
        } catch {
            $typeName = $trigger.GetType().Name
        }

        if ($typeName -in @(
                'MSFT_TaskLogonTrigger',
                'MSFT_TaskBootTrigger',
                'MSFT_TaskRegistrationTrigger',
                'MSFT_TaskSessionStateChangeTrigger'
            )) {
            return $true
        }
    }

    return $false
}

function Get-ScheduledTaskStartupCommandLine {
    param($Task)

    $actions = @($Task.Actions)
    if ($actions.Count -eq 0) {
        return ''
    }

    $action = $actions[0]
    $execute = ''
    $arguments = ''
    try { $execute = [string]$action.Execute } catch { }
    try { $arguments = [string]$action.Arguments } catch { }

    if ([string]::IsNullOrWhiteSpace($execute)) {
        return ''
    }

    if ([string]::IsNullOrWhiteSpace($arguments)) {
        return $execute
    }

    return "$execute $arguments".Trim()
}

function Get-StartupScheduledTaskDisplayPath {
    param(
        [string]$CommandLine,
        [string]$TaskPath,
        [string]$TaskName
    )

    if (-not [string]::IsNullOrWhiteSpace($CommandLine)) {
        return $CommandLine
    }

    $folder = if ([string]::IsNullOrWhiteSpace($TaskPath)) { '\' } else { $TaskPath }
  return "$folder$TaskName (COM / no executable path)"
}

function Get-StartupScheduledTaskRows {
    param(
        [switch]$IncludeWindowsScheduledTasks
    )

    if (Test-OfflineRegistrySessionActive) {
        return @()
    }

    $rows = [System.Collections.Generic.List[object]]::new()

    try {
        $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue)
    } catch {
        return @()
    }

    foreach ($task in $tasks) {
        if (-not (Test-ScheduledTaskHasStartupTrigger -Task $task)) {
            continue
        }

        $commandLine = Get-ScheduledTaskStartupCommandLine -Task $task
        $taskPath = [string]$task.TaskPath
        $taskName = [string]$task.TaskName
        $isWindowsPlumbing = Test-IsWindowsPlumbingScheduledTaskPath -TaskPath $taskPath

        $executePath = ''
        $actions = @($task.Actions)
        if ($actions.Count -gt 0) {
            try { $executePath = [string]$actions[0].Execute } catch { }
        }

        if ($isWindowsPlumbing -and -not $IncludeWindowsScheduledTasks) {
            continue
        }

        $state = [string]$task.State
        $isEnabled = $state -ne 'Disabled'
        $displayPath = Get-StartupScheduledTaskDisplayPath -CommandLine $commandLine -TaskPath $taskPath -TaskName $taskName
        $sourceGroup = if ($isWindowsPlumbing) {
            "Scheduled Task (Windows) $taskPath"
        } else {
            "Scheduled Task $taskPath"
        }

        $rows.Add(@{
            Category           = 'StartupItems'
            RowType            = 'ScheduledTask'
            SourceGroup        = $sourceGroup.Trim()
            Name               = $taskName
            Publisher          = if ($isWindowsPlumbing) { 'Microsoft Corporation' } else { 'Unknown' }
            FilePath           = $displayPath
            Source             = 'TaskScheduler'
            RegistryPath       = ''
            ValueName          = ''
            RegistryKey        = ''
            RiskLevel          = if ($isWindowsPlumbing) { 'Safe' } else { 'Caution' }
            IsSigned           = $false
            IsEnabled          = $isEnabled
            ServiceName        = $taskName
            OriginalData       = $state
            IsCritical         = $isWindowsPlumbing
            SupportsEnable     = -not $isWindowsPlumbing
            SupportsDisable    = -not $isWindowsPlumbing
            SupportsDelete     = -not $isWindowsPlumbing
            SupportsReset      = $false
            SupportsUndo       = $false
            IsDeviated         = $false
            DeviationReason    = ''
            PreserveRiskLevel  = $isWindowsPlumbing
            AnalysisFilePath   = if (-not [string]::IsNullOrWhiteSpace($executePath)) { $executePath } else { $displayPath }
            Clsid              = ''
            User               = ''
            ActionStatePayload = $taskPath
        })
    }

    return @($rows)
}

function Set-StartupScheduledTaskEntryState {
    param(
        [string]$TaskName,
        [string]$TaskPath,
        [bool]$Enable
    )

    if ([string]::IsNullOrWhiteSpace($TaskName)) {
        throw 'TaskName is required for scheduled task actions.'
    }

    if ($env:OFFLINE_WINDOWS_ROOT) {
        throw 'PROTECTED_OR_UNSUPPORTED: Scheduled tasks are not supported in offline registry mode.'
    }

    if (Test-IsWindowsPlumbingScheduledTaskPath -TaskPath $TaskPath) {
        throw 'PROTECTED_OR_UNSUPPORTED: Windows scheduled tasks cannot be modified from Startup Manager.'
    }

    $normalizedPath = Resolve-StartupScheduledTaskPath -TaskPath $TaskPath
    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $normalizedPath -ErrorAction Stop
    $current = [string]$task.State

    if ($Enable) {
        if ($current -ne 'Disabled') {
            throw 'ALREADY_IN_DESIRED_STATE: Scheduled task is already enabled.'
        }

        Enable-ScheduledTask -TaskName $TaskName -TaskPath $normalizedPath -ErrorAction Stop | Out-Null
    } else {
        if ($current -eq 'Disabled') {
            throw 'ALREADY_IN_DESIRED_STATE: Scheduled task is already disabled.'
        }

        Disable-ScheduledTask -TaskName $TaskName -TaskPath $normalizedPath -ErrorAction Stop | Out-Null
    }

    $verify = (Get-ScheduledTask -TaskName $TaskName -TaskPath $normalizedPath -ErrorAction Stop).State
    if ($Enable -and [string]$verify -eq 'Disabled') {
        throw "Scheduled task enable verification failed for '$TaskName'."
    }
    if (-not $Enable -and [string]$verify -ne 'Disabled') {
        throw "Scheduled task disable verification failed for '$TaskName'."
    }
}

function Resolve-StartupScheduledTaskPath {
    param([string]$TaskPath)

    $normalizedPath = if ([string]::IsNullOrWhiteSpace($TaskPath)) { '\' } else { $TaskPath }
    if (-not $normalizedPath.EndsWith('\')) {
        $normalizedPath += '\'
    }
    return $normalizedPath
}

function Remove-StartupScheduledTaskEntry {
    param(
        [string]$TaskName,
        [string]$TaskPath
    )

    if ([string]::IsNullOrWhiteSpace($TaskName)) {
        throw 'TaskName is required for scheduled task delete.'
    }

    if ($env:OFFLINE_WINDOWS_ROOT) {
        throw 'PROTECTED_OR_UNSUPPORTED: Scheduled tasks are not supported in offline registry mode.'
    }

    if (Test-IsWindowsPlumbingScheduledTaskPath -TaskPath $TaskPath) {
        throw 'PROTECTED_OR_UNSUPPORTED: Windows scheduled tasks cannot be deleted from Startup Manager.'
    }

    $normalizedPath = Resolve-StartupScheduledTaskPath -TaskPath $TaskPath
    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $normalizedPath -ErrorAction Stop
    Unregister-ScheduledTask -InputObject $task -Confirm:$false -ErrorAction Stop

    $stillThere = $null
    try {
        $stillThere = Get-ScheduledTask -TaskName $TaskName -TaskPath $normalizedPath -ErrorAction Stop
    } catch {
        $stillThere = $null
    }

    if ($null -ne $stillThere) {
        throw "Scheduled task delete verification failed for '$TaskName'."
    }
}
