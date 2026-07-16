#Requires -Version 5.1
<#
.SYNOPSIS
    Scheduled tasks with logon/boot/registration startup triggers for Startup Manager.
#>

. (Join-Path $PSScriptRoot 'OfflineRuntime.ps1')

# COM ClassId resolution uses Expand-WindowsImagePath / Parse-StartupCommandLine from StartupRisk.
if (-not (Get-Command -Name Expand-WindowsImagePath -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'StartupRisk.ps1')
}

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

function Get-ScheduledTaskActionKind {
    param($Action)

    if ($null -eq $Action) {
        return 'None'
    }

    $typeName = ''
    try {
        $typeName = [string]$Action.CimClass.CimClassName
    } catch {
        $typeName = $Action.GetType().Name
    }

    if ($typeName -match 'ComHandler') {
        return 'Com'
    }

    $execute = ''
    try { $execute = [string]$Action.Execute } catch { }
    if (-not [string]::IsNullOrWhiteSpace($execute)) {
        return 'Exec'
    }

    $classId = ''
    try { $classId = [string]$Action.ClassId } catch { }
    if (-not [string]::IsNullOrWhiteSpace($classId)) {
        return 'Com'
    }

    return 'None'
}

function Get-ScheduledTaskComClassId {
    param($Action)

    if ($null -eq $Action) {
        return ''
    }

    try {
        $classId = [string]$Action.ClassId
        if (-not [string]::IsNullOrWhiteSpace($classId)) {
            return $classId.Trim()
        }
    } catch { }

    return ''
}

function Resolve-ComHandlerServerPath {
    <#
    .SYNOPSIS
        Resolve a scheduled-task COM handler CLSID to InprocServer32/LocalServer32.
    #>
    param(
        [Parameter(Mandatory)][string]$ClassId
    )

    $result = [PSCustomObject]@{
        ClassId      = $ClassId
        ServerPath   = ''
        ServerKind   = ''
        Exists       = $false
        Detail       = ''
    }

    if ([string]::IsNullOrWhiteSpace($ClassId)) {
        $result.Detail = 'Empty COM ClassId'
        return $result
    }

    $normalized = $ClassId.Trim()
    if ($normalized -notmatch '^\{[0-9A-Fa-f\-]+\}$') {
        if ($normalized -match '^[0-9A-Fa-f\-]{36}$') {
            $normalized = "{$normalized}"
        }
    }

    $roots = @(
        "HKLM:\SOFTWARE\Classes\CLSID\$normalized",
        "HKLM:\SOFTWARE\WOW6432Node\Classes\CLSID\$normalized",
        "HKCU:\SOFTWARE\Classes\CLSID\$normalized"
    )

    foreach ($root in $roots) {
        foreach ($kind in @('InprocServer32', 'LocalServer32', 'InProcServer32')) {
            $keyPath = Join-Path $root $kind
            if (-not (Test-Path -LiteralPath $keyPath -ErrorAction SilentlyContinue)) {
                continue
            }

            try {
                $raw = [string](Get-ItemProperty -LiteralPath $keyPath -ErrorAction Stop).'(default)'
            } catch {
                continue
            }

            if ([string]::IsNullOrWhiteSpace($raw)) {
                continue
            }

            # LocalServer32 may be a command line; take the executable token.
            $expanded = Expand-WindowsImagePath -Path $raw.Trim().Trim('"')
            $parsed = Parse-StartupCommandLine -Command $expanded
            $candidate = if (-not [string]::IsNullOrWhiteSpace($parsed.ExecutablePath)) {
                $parsed.ExecutablePath
            } else {
                $expanded
            }
            $candidate = Expand-WindowsImagePath -Path $candidate

            if ([string]::IsNullOrWhiteSpace($candidate)) {
                continue
            }

            $result.ServerKind = $kind
            $result.ServerPath = $candidate
            if (Test-Path -LiteralPath $candidate -PathType Leaf -ErrorAction SilentlyContinue) {
                try {
                    $result.ServerPath = (Get-Item -LiteralPath $candidate -ErrorAction Stop).FullName
                } catch { }
                $result.Exists = $true
                $result.Detail = "COM $kind"
                return $result
            }

            $result.Detail = "COM $kind path missing: $candidate"
        }
    }

    if ([string]::IsNullOrWhiteSpace($result.Detail)) {
        $result.Detail = "COM ClassId not found in registry: $normalized"
    }

    return $result
}

function Get-StartupScheduledTaskDisplayPath {
    param(
        [string]$CommandLine,
        [string]$TaskPath,
        [string]$TaskName,
        [string]$ActionKind = '',
        [string]$ClassId = '',
        [string]$ComServerPath = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($CommandLine)) {
        return $CommandLine
    }

    $folder = if ([string]::IsNullOrWhiteSpace($TaskPath)) { '\' } else { $TaskPath }
    if ($ActionKind -eq 'Com' -or -not [string]::IsNullOrWhiteSpace($ClassId)) {
        $idPart = if (-not [string]::IsNullOrWhiteSpace($ClassId)) { " $ClassId" } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($ComServerPath)) {
            return "$folder$TaskName (COM$idPart → $ComServerPath)"
        }
        return "$folder$TaskName (COM$idPart)"
    }

    return "$folder$TaskName (no executable path)"
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

        $actions = @($task.Actions)
        $action = if ($actions.Count -gt 0) { $actions[0] } else { $null }
        $actionKind = Get-ScheduledTaskActionKind -Action $action
        $comClassId = if ($actionKind -eq 'Com') { Get-ScheduledTaskComClassId -Action $action } else { '' }
        $comServer = $null
        $comServerPath = ''
        if ($actionKind -eq 'Com' -and -not [string]::IsNullOrWhiteSpace($comClassId)) {
            $comServer = Resolve-ComHandlerServerPath -ClassId $comClassId
            if ($comServer -and -not [string]::IsNullOrWhiteSpace($comServer.ServerPath)) {
                $comServerPath = [string]$comServer.ServerPath
            }
        }

        $executePath = ''
        if ($actionKind -eq 'Exec' -and $null -ne $action) {
            try { $executePath = [string]$action.Execute } catch { }
        }

        if ($isWindowsPlumbing -and -not $IncludeWindowsScheduledTasks) {
            continue
        }

        $state = [string]$task.State
        $isEnabled = $state -ne 'Disabled'
        $displayPath = Get-StartupScheduledTaskDisplayPath `
            -CommandLine $commandLine `
            -TaskPath $taskPath `
            -TaskName $taskName `
            -ActionKind $actionKind `
            -ClassId $comClassId `
            -ComServerPath $comServerPath
        $sourceGroup = if ($isWindowsPlumbing) {
            "Scheduled Task (Windows) $taskPath"
        } else {
            "Scheduled Task $taskPath"
        }

        $analysisPath = if ($actionKind -eq 'Exec' -and -not [string]::IsNullOrWhiteSpace($executePath)) {
            $executePath
        } elseif ($actionKind -eq 'Com' -and -not [string]::IsNullOrWhiteSpace($comServerPath)) {
            $comServerPath
        } else {
            ''
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
            AnalysisFilePath   = $analysisPath
            Clsid              = $comClassId
            User               = ''
            ActionStatePayload = $taskPath
            TaskActionKind     = $actionKind
            ComServerExists    = if ($comServer) { [bool]$comServer.Exists } else { $false }
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
