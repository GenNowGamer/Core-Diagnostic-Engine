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

function Test-IsWindowsCoreScheduledTaskPath {
    param([string]$TaskPath)

    $normalized = if ([string]::IsNullOrWhiteSpace($TaskPath)) { '\' } else { $TaskPath }
    if (-not $normalized.StartsWith('\')) {
        $normalized = "\$normalized"
    }

    return ($normalized -match '^\\Microsoft\\Windows(\\|$)')
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

    if (-not $script:ComHandlerServerPathCache) {
        $script:ComHandlerServerPathCache = @{}
    }
    $cacheKey = $normalized.ToUpperInvariant()
    if ($script:ComHandlerServerPathCache.ContainsKey($cacheKey)) {
        return $script:ComHandlerServerPathCache[$cacheKey]
    }

    $roots = @(
        @{ Hive = [Microsoft.Win32.Registry]::LocalMachine; Sub = "SOFTWARE\Classes\CLSID\$normalized" },
        @{ Hive = [Microsoft.Win32.Registry]::LocalMachine; Sub = "SOFTWARE\WOW6432Node\Classes\CLSID\$normalized" },
        @{ Hive = [Microsoft.Win32.Registry]::CurrentUser;  Sub = "SOFTWARE\Classes\CLSID\$normalized" }
    )

    foreach ($root in $roots) {
        foreach ($kind in @('InprocServer32', 'LocalServer32')) {
            $raw = ''
            $regKey = $null
            try {
                $regKey = $root.Hive.OpenSubKey("$($root.Sub)\$kind")
                if ($null -eq $regKey) { continue }
                $raw = [string]$regKey.GetValue('')
            } catch {
                continue
            } finally {
                if ($null -ne $regKey) { $regKey.Dispose() }
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
                $script:ComHandlerServerPathCache[$cacheKey] = $result
                return $result
            }

            $result.Detail = "COM $kind path missing: $candidate"
        }
    }

    $packaged = Resolve-PackagedComServerPath -ClassId $normalized
    if ($packaged -and $packaged.Exists) {
        $script:ComHandlerServerPathCache[$cacheKey] = $packaged
        return $packaged
    }
    if ($packaged -and -not [string]::IsNullOrWhiteSpace($packaged.Detail) -and [string]::IsNullOrWhiteSpace($result.Detail)) {
        $result.ServerKind = $packaged.ServerKind
        $result.ServerPath = $packaged.ServerPath
        $result.Detail = $packaged.Detail
    }

    if ([string]::IsNullOrWhiteSpace($result.Detail)) {
        $result.Detail = "COM ClassId not found in registry: $normalized"
    }

    $script:ComHandlerServerPathCache[$cacheKey] = $result
    return $result
}

function Get-PackagedComInstallLocation {
    <#
    .SYNOPSIS
        Resolve and cache the InstallLocation for an Appx/MSIX PackageFullName.
    #>
    param(
        [Parameter(Mandatory)][string]$PackageFullName
    )

    if (-not $script:PackagedComInstallLocationCache) {
        $script:PackagedComInstallLocationCache = @{}
    }
    if ($script:PackagedComInstallLocationCache.ContainsKey($PackageFullName)) {
        return [string]$script:PackagedComInstallLocationCache[$PackageFullName]
    }

    $installLocation = ''

    # Fast registry lookup (<1ms) before falling back to Get-AppxPackage.
    $userRepoKey = $null
    try {
        $userRepoKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages\$PackageFullName")
        if ($null -ne $userRepoKey) {
            $root = [string]$userRepoKey.GetValue('PackageRootFolder')
            if (-not [string]::IsNullOrWhiteSpace($root)) {
                $installLocation = $root
            }
        }
    } catch { } finally {
        if ($null -ne $userRepoKey) { $userRepoKey.Dispose() }
    }

    if ([string]::IsNullOrWhiteSpace($installLocation)) {
        foreach ($storeSub in @(
                "SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Applications\$PackageFullName",
                "SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\InboxApplications\$PackageFullName"
            )) {
            $storeKey = $null
            try {
                $storeKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($storeSub)
                if ($null -eq $storeKey) { continue }
                $manifestPath = [string]$storeKey.GetValue('Path')
                if (-not [string]::IsNullOrWhiteSpace($manifestPath)) {
                    $parentDir = Split-Path -Path $manifestPath -Parent
                    if (-not [string]::IsNullOrWhiteSpace($parentDir)) {
                        $installLocation = $parentDir
                        break
                    }
                }
            } catch { } finally {
                if ($null -ne $storeKey) { $storeKey.Dispose() }
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($installLocation)) {
        foreach ($appFolder in @(
                (Join-Path $env:ProgramFiles "WindowsApps\$PackageFullName"),
                (Join-Path $env:SystemRoot "SystemApps\$PackageFullName")
            )) {
            if (Test-Path -LiteralPath $appFolder -PathType Container -ErrorAction SilentlyContinue) {
                $installLocation = $appFolder
                break
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($installLocation) -and -not $script:PackagedComAppxBulkLoaded -and (Get-Command -Name Get-AppxPackage -ErrorAction SilentlyContinue)) {
        $script:PackagedComAppxBulkLoaded = $true
        try {
            foreach ($pkg in @(Get-AppxPackage -ErrorAction SilentlyContinue)) {
                if ($null -eq $pkg -or [string]::IsNullOrWhiteSpace([string]$pkg.PackageFullName)) { continue }
                $script:PackagedComInstallLocationCache[[string]$pkg.PackageFullName] = [string]$pkg.InstallLocation
            }
            if ($script:PackagedComInstallLocationCache.ContainsKey($PackageFullName)) {
                $installLocation = [string]$script:PackagedComInstallLocationCache[$PackageFullName]
            }
        } catch { }
    }

    $script:PackagedComInstallLocationCache[$PackageFullName] = $installLocation
    return $installLocation
}

function Resolve-PackagedComServerPath {
    <#
    .SYNOPSIS
        Resolve a PackagedCom CLSID (HKLM/HKCU\SOFTWARE\Classes\PackagedCom) to its DLL or EXE path.
    #>
    param(
        [Parameter(Mandatory)][string]$ClassId
    )

    $result = [PSCustomObject]@{
        ClassId    = $ClassId
        ServerPath = ''
        ServerKind = ''
        Exists     = $false
        Detail     = ''
    }

    $packagedRoots = @(
        [Microsoft.Win32.Registry]::LocalMachine,
        [Microsoft.Win32.Registry]::CurrentUser
    )

    foreach ($hive in $packagedRoots) {
        $pkgFullNames = @()
        $indexKey = $null
        try {
            $indexKey = $hive.OpenSubKey("SOFTWARE\Classes\PackagedCom\ClassIndex\$ClassId")
            if ($null -eq $indexKey) { continue }
            $pkgFullNames = @($indexKey.GetSubKeyNames() | Sort-Object -Descending)
        } catch {
            continue
        } finally {
            if ($null -ne $indexKey) { $indexKey.Dispose() }
        }

        foreach ($pkgFullName in $pkgFullNames) {
            if ([string]::IsNullOrWhiteSpace($pkgFullName)) { continue }

            $installLocation = Get-PackagedComInstallLocation -PackageFullName $pkgFullName
            if ([string]::IsNullOrWhiteSpace($installLocation) -or -not (Test-Path -LiteralPath $installLocation -PathType Container -ErrorAction SilentlyContinue)) {
                continue
            }

            $relTarget = ''
            $kind = ''
            $classKey = $null
            try {
                $classKey = $hive.OpenSubKey("SOFTWARE\Classes\PackagedCom\Package\$pkgFullName\Class\$ClassId")
                if ($null -eq $classKey) { continue }
                $dllPath = [string]$classKey.GetValue('DllPath')
                if (-not [string]::IsNullOrWhiteSpace($dllPath)) {
                    $relTarget = $dllPath
                    $kind = 'PackagedCom (Inproc)'
                } else {
                    $serverId = $classKey.GetValue('ServerId')
                    if ($null -ne $serverId -and -not [string]::IsNullOrWhiteSpace([string]$serverId)) {
                        $serverKey = $null
                        try {
                            $serverKey = $hive.OpenSubKey("SOFTWARE\Classes\PackagedCom\Package\$pkgFullName\Server\$serverId")
                            if ($null -ne $serverKey) {
                                $exePath = [string]$serverKey.GetValue('Executable')
                                if (-not [string]::IsNullOrWhiteSpace($exePath)) {
                                    $relTarget = $exePath
                                    $kind = 'PackagedCom (OutOfProc)'
                                }
                            }
                        } catch { } finally {
                            if ($null -ne $serverKey) { $serverKey.Dispose() }
                        }
                    }
                }
            } catch {
                continue
            } finally {
                if ($null -ne $classKey) { $classKey.Dispose() }
            }

            if ([string]::IsNullOrWhiteSpace($relTarget)) { continue }

            $expanded = Expand-WindowsImagePath -Path $relTarget.Trim().Trim('"')
            $candidate = if ([System.IO.Path]::IsPathRooted($expanded)) { $expanded } else { Join-Path $installLocation $expanded }

            $result.ServerKind = $kind
            $result.ServerPath = $candidate
            if (Test-Path -LiteralPath $candidate -PathType Leaf -ErrorAction SilentlyContinue) {
                try {
                    $result.ServerPath = (Get-Item -LiteralPath $candidate -ErrorAction Stop).FullName
                } catch { }
                $result.Exists = $true
                $result.Detail = "PackagedCom ($pkgFullName)"
                return $result
            }

            $result.Detail = "PackagedCom target missing: $candidate"
        }
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
            return "$folder$TaskName (COM$idPart -> $ComServerPath)"
        }
        return "$folder$TaskName (COM$idPart)"
    }

    return "$folder$TaskName (no executable path)"
}

function Get-StartupScheduledTaskRows {
    param(
        [switch]$IncludeWindowsScheduledTasks,
        [switch]$IncludeAllTriggers,
        [string]$Category = 'ScheduledTasks'
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
        if (-not $IncludeAllTriggers -and -not (Test-ScheduledTaskHasStartupTrigger -Task $task)) {
            continue
        }

        $taskPath = [string]$task.TaskPath
        $isWindowsPlumbing = Test-IsWindowsPlumbingScheduledTaskPath -TaskPath $taskPath
        if ($isWindowsPlumbing -and -not $IncludeWindowsScheduledTasks) {
            continue
        }

        $taskName = [string]$task.TaskName
        $isWindowsCore = Test-IsWindowsCoreScheduledTaskPath -TaskPath $taskPath
        $commandLine = Get-ScheduledTaskStartupCommandLine -Task $task

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
            Category           = $Category
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
            IsCritical         = $isWindowsCore
            SupportsEnable     = -not $isWindowsCore
            SupportsDisable    = -not $isWindowsCore
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

    if (Test-IsWindowsCoreScheduledTaskPath -TaskPath $TaskPath) {
        throw 'PROTECTED_OR_UNSUPPORTED: Windows core scheduled tasks cannot be modified from Startup Manager.'
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
