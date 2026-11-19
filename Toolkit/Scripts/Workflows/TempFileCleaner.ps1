#Requires -Version 5.1
param(
    [string]$Action = 'Scan',
    [string]$PathsJson = '',
    [string]$PathsFile = '',
    [string]$DrivesJson = '',
    [string]$DrivesFile = '',
    [string]$WhitelistJson = '',
    [string]$WhitelistFile = '',
    [switch]$ElevatedRelay
)

$ErrorActionPreference = 'Stop'

$Script:TempFileCleanerScriptPath = $MyInvocation.MyCommand.Path
$ScriptDir  = Split-Path $Script:TempFileCleanerScriptPath
$CoreModule = Join-Path $ScriptDir '..\Core\Toolkit.Core.psm1'
$ElevationModule = Join-Path $ScriptDir '..\Core\Toolkit.Elevation.psm1'
Import-Module $CoreModule -Force -DisableNameChecking
Import-Module $ElevationModule -Force -DisableNameChecking

function Get-TempFileCleanerRelayArgumentString {
    $parts = [System.Collections.Generic.List[string]]::new()
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'Action' -Value $Action
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'ElevatedRelay' -IsSwitch
    if (-not [string]::IsNullOrWhiteSpace($PathsFile)) {
        Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'PathsFile' -Value $PathsFile
    } elseif (-not [string]::IsNullOrWhiteSpace($PathsJson)) {
        Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'PathsJson' -Value $PathsJson
    }
    if (-not [string]::IsNullOrWhiteSpace($DrivesFile)) {
        Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'DrivesFile' -Value $DrivesFile
    } elseif (-not [string]::IsNullOrWhiteSpace($DrivesJson)) {
        Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'DrivesJson' -Value $DrivesJson
    }
    if (-not [string]::IsNullOrWhiteSpace($WhitelistFile)) {
        Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'WhitelistFile' -Value $WhitelistFile
    } elseif (-not [string]::IsNullOrWhiteSpace($WhitelistJson)) {
        Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'WhitelistJson' -Value $WhitelistJson
    }
    return Join-ToolkitRelayArgumentString -Parts $parts
}

function Invoke-TempFileCleanerElevationRelay {
    if ($ElevatedRelay) { return $false }
    if ($Action -ne 'Clean') { return $false }
    if ((Get-EnvironmentMode) -eq 'WinPE') { return $false }
    return (Invoke-ToolkitWorkflowElevationRelay -ScriptPath $Script:TempFileCleanerScriptPath `
        -ArgumentString (Get-TempFileCleanerRelayArgumentString) -ElevatedRelay:$ElevatedRelay)
}

function Get-JsonArrayInput {
    param(
        [string]$Json,
        [string]$FilePath
    )

    if (-not [string]::IsNullOrWhiteSpace($FilePath)) {
        if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
            throw "Input JSON file not found: $FilePath"
        }
        $raw = Get-Content -LiteralPath $FilePath -Raw
    } else {
        $raw = $Json
    }

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }

    try {
        $parsed = $raw | ConvertFrom-Json
    } catch {
        $source = if (-not [string]::IsNullOrWhiteSpace($FilePath)) { $FilePath } else { 'inline JSON' }
        throw "Failed to parse JSON input from ${source}: $($_.Exception.Message)"
    }

    if ($null -eq $parsed) {
        return @()
    }

    if ($parsed -is [System.Array]) {
        return @($parsed)
    }

    return @($parsed)
}

function Normalize-PathString {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }

    $candidate = ([string]$Path).Trim()
    if ($candidate -match '^[A-Za-z]:$') {
        $candidate = "${candidate}\"
    }

    try {
        $normalized = [System.IO.Path]::GetFullPath($candidate).TrimEnd('\', '/')
    } catch {
        $normalized = $candidate.TrimEnd('\', '/')
    }

    # Preserve the trailing separator on bare drive roots so Test-Path / Join-Path stay rooted (C:\ not C:).
    if ($normalized -match '^[A-Za-z]:$') {
        return "${normalized}\"
    }

    return $normalized
}

function Get-DriveLetterFromPath {
    param([string]$Path)

    if ($Path -match '^[A-Za-z]:') {
        return $Path.Substring(0, 2).ToUpperInvariant()
    }

    return ''
}

function Get-ProtectionInfo {
    param([string]$Path)

    $lower = [string]::Empty
    try {
        $lower = (Normalize-PathString -Path $Path).ToLowerInvariant()
    } catch {}

    if ($lower -match '\\windows\\prefetch($|\\)') {
        return [PSCustomObject]@{ IsProtected = $true; Reason = 'Prefetch is protected by policy.' }
    }

    if ($lower -match '\\windows\\softwaredistribution\\download($|\\)') {
        return [PSCustomObject]@{ IsProtected = $true; Reason = 'Windows Update cache is protected by policy.' }
    }

    return [PSCustomObject]@{ IsProtected = $false; Reason = '' }
}

function Get-ScanRoots {
    $roots = [System.Collections.Generic.List[string]]::new()
    $selectedDrives = Get-JsonArrayInput -Json $DrivesJson -FilePath $DrivesFile

    foreach ($drive in $selectedDrives) {
        $normalized = Normalize-PathString -Path ([string]$drive)
        if ([string]::IsNullOrWhiteSpace($normalized)) { continue }
        if (-not (Test-Path -LiteralPath $normalized)) { continue }
        $roots.Add($normalized)
    }

    if ($roots.Count -eq 0) {
        $offlineRoot = Normalize-PathString -Path $env:OFFLINE_WINDOWS_ROOT
        if (-not [string]::IsNullOrWhiteSpace($offlineRoot) -and (Test-Path -LiteralPath $offlineRoot)) {
            $roots.Add($offlineRoot)
        }
    }

    if ($roots.Count -eq 0) {
        $systemRoot = Normalize-PathString -Path ([System.IO.Path]::GetPathRoot($env:SystemRoot))
        if (-not [string]::IsNullOrWhiteSpace($systemRoot)) {
            $roots.Add($systemRoot)
        }
    }

    return @($roots | Sort-Object -Unique)
}

function Add-ScanLocation {
    param(
        [System.Collections.Generic.List[object]]$Locations,
        [System.Collections.Generic.HashSet[string]]$Seen,
        [string]$Path,
        [string]$Category,
        [string]$UserAccount,
        [string]$ProfileGroup,
        [string]$DiscoverySource
    )

    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { return }

        $normalized = Normalize-PathString -Path $Path
        if ([string]::IsNullOrWhiteSpace($normalized)) { return }

        $rootInfo = [System.IO.DirectoryInfo]::new($normalized)
        if (-not $rootInfo.Exists) { return }
        if (($rootInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return }
        if (-not $Seen.Add($normalized)) { return }

        $fileCount = 0
        $bytes = 0L
        $stack = [System.Collections.Generic.Stack[System.IO.DirectoryInfo]]::new()
        $stack.Push($rootInfo)
        while ($stack.Count -gt 0) {
            $dir = $stack.Pop()
            try {
                if (($dir.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                foreach ($file in $dir.EnumerateFiles()) {
                    try {
                        $fileCount++
                        $bytes += [long]$file.Length
                    } catch {}
                }
                foreach ($subDir in $dir.EnumerateDirectories()) {
                    if (($subDir.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
                        $stack.Push($subDir)
                    }
                }
            } catch {}
        }

        $protection = Get-ProtectionInfo -Path $normalized

        $Locations.Add([PSCustomObject]@{
            Path             = $normalized
            Category         = $Category
            UserAccount      = $UserAccount
            ProfileGroup     = $ProfileGroup
            DriveLetter      = Get-DriveLetterFromPath -Path $normalized
            DiscoverySource  = $DiscoverySource
            IsProtected      = [bool]$protection.IsProtected
            ProtectionReason = [string]$protection.Reason
            FileCount        = [int]$fileCount
            Bytes            = $bytes
        })
    } catch {
        Write-Log "[WARN] Skipping scan location ${Path}: $($_.Exception.Message)" -Level Warning
    }
}

function Invoke-Scan {
    $locations = [System.Collections.Generic.List[object]]::new()
    $seenPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $roots = Get-ScanRoots

    foreach ($root in $roots) {
        $usersRoot = Join-Path $root 'Users'
        if (Test-Path -LiteralPath $usersRoot) {
            $users = @(Get-ChildItem -LiteralPath $usersRoot -Directory -ErrorAction SilentlyContinue)
            foreach ($user in $users) {
                $targets = @(
                    @{ Rel = 'AppData\Local\Temp'; Cat = 'User Temp' },
                    @{ Rel = 'AppData\Local\Microsoft\Windows\Temporary Internet Files'; Cat = 'User IE Cache' },
                    @{ Rel = 'AppData\Local\Microsoft\Windows\History'; Cat = 'User IE History' },
                    @{ Rel = 'AppData\Local\Microsoft\Windows\INetCache'; Cat = 'IE/Edge Cache' },
                    @{ Rel = 'AppData\Local\Microsoft\Office\15.0\OfficeFileCache'; Cat = 'Microsoft Office File Cache' },
                    @{ Rel = 'AppData\Local\Microsoft\Office\15.0\OfficeServiceCache'; Cat = 'Microsoft Office Service Cache' },
                    @{ Rel = 'AppData\Local\Google\Chrome\User Data\Default\Cache'; Cat = 'Chrome Cache' },
                    @{ Rel = 'AppData\Local\Google\Chrome\User Data\Default\GPUCache'; Cat = 'User Chrome GPU Cache' },
                    @{ Rel = 'AppData\Local\Microsoft\Edge\User Data\Default\Cache'; Cat = 'Edge Cache' },
                    @{ Rel = 'AppData\Local\Microsoft\Edge\User Data\Default\GPUCache'; Cat = 'Edge GPU Cache' }
                )

                foreach ($target in $targets) {
                    Add-ScanLocation -Locations $locations -Seen $seenPaths -Path (Join-Path $user.FullName $target.Rel) -Category $target.Cat -UserAccount $user.Name -ProfileGroup $user.Name -DiscoverySource 'DynamicProfile'
                }

                # Firefox cache lives under AppData\Local\Mozilla\Firefox\Profiles\<profile>\cache2 (never Roaming\Profiles).
                try {
                    $ffProfilesRoot = Join-Path $user.FullName 'AppData\Local\Mozilla\Firefox\Profiles'
                    $ffRootInfo = [System.IO.DirectoryInfo]::new($ffProfilesRoot)
                    if ($ffRootInfo.Exists -and (($ffRootInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0)) {
                        foreach ($profileDir in $ffRootInfo.EnumerateDirectories()) {
                            if (($profileDir.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                            $ffCachePath = Join-Path $profileDir.FullName 'cache2'
                            Add-ScanLocation -Locations $locations -Seen $seenPaths -Path $ffCachePath -Category 'Firefox Cache' -UserAccount $user.Name -ProfileGroup $user.Name -DiscoverySource 'DynamicProfile'
                        }
                    }
                } catch {}
            }
        }

        Add-ScanLocation -Locations $locations -Seen $seenPaths -Path (Join-Path $root 'Windows\System32\config\systemprofile\AppData\Local\Microsoft\Windows\History') -Category 'User IE History' -UserAccount 'SYSTEM' -ProfileGroup 'systemprofile' -DiscoverySource 'DynamicSystemProfile'
        Add-ScanLocation -Locations $locations -Seen $seenPaths -Path (Join-Path $root 'Windows\SysWOW64\config\systemprofile\AppData\Local\Microsoft\Windows\History') -Category 'User IE History' -UserAccount 'SYSTEM' -ProfileGroup 'syswow64profile' -DiscoverySource 'DynamicSystemProfile'

        Add-ScanLocation -Locations $locations -Seen $seenPaths -Path (Join-Path $root 'Windows\Temp') -Category 'Windows Temp' -UserAccount 'SYSTEM' -ProfileGroup 'Other Directories' -DiscoverySource 'DynamicSystem'
        Add-ScanLocation -Locations $locations -Seen $seenPaths -Path (Join-Path $root 'Windows\Prefetch') -Category 'Prefetch' -UserAccount 'SYSTEM' -ProfileGroup 'Other Directories' -DiscoverySource 'DynamicSystem'
        Add-ScanLocation -Locations $locations -Seen $seenPaths -Path (Join-Path $root 'Windows\SoftwareDistribution\Download') -Category 'Windows SoftwareDistribution Download' -UserAccount 'SYSTEM' -ProfileGroup 'Other Directories' -DiscoverySource 'DynamicSystem'
        Add-ScanLocation -Locations $locations -Seen $seenPaths -Path (Join-Path $root 'Temp') -Category 'Temp Directory' -UserAccount 'SYSTEM' -ProfileGroup 'Other Directories' -DiscoverySource 'DynamicDriveRoot'
        Add-ScanLocation -Locations $locations -Seen $seenPaths -Path (Join-Path $root '$Recycle.Bin') -Category 'Recycle Bin' -UserAccount 'SYSTEM' -ProfileGroup 'Other Directories' -DiscoverySource 'DynamicDriveRoot'
    }

    ConvertTo-Json -InputObject @($locations) -Depth 4
}

function Get-RemovalFailureCategory {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)

    $exception = $ErrorRecord.Exception
    $message = [string]$exception.Message
    $inner = $exception.InnerException
    $innerMessage = if ($null -ne $inner) { [string]$inner.Message } else { '' }
    $win32 = $exception.HResult -band 0xFFFF
    $innerWin32 = if ($null -ne $inner) { $inner.HResult -band 0xFFFF } else { 0 }

    if ($message -match 'being used by another process' -or
        $message -match 'cannot access the file.*because it is being used' -or
        $innerMessage -match 'being used by another process' -or
        $innerMessage -match 'cannot access the file.*because it is being used' -or
        $win32 -in @(0x0020, 0x0021) -or
        $innerWin32 -in @(0x0020, 0x0021)) {
        return 'InUse'
    }

    if ($exception -is [System.UnauthorizedAccessException] -or
        $inner -is [System.UnauthorizedAccessException] -or
        $message -match 'Access to the path .* is denied\.?' -or
        $innerMessage -match 'Access to the path .* is denied\.?' -or
        ($exception -is [System.IO.IOException] -and $message -match 'is denied') -or
        $win32 -eq 0x0005 -or
        $innerWin32 -eq 0x0005) {
        return 'AccessDenied'
    }

    return 'Failed'
}

function Register-RemovalFailure {
    param(
        [string]$ItemPath,
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [ref]$FailedCount,
        [ref]$SkippedInUseCount,
        [ref]$SkippedAccessDeniedCount
    )

    switch (Get-RemovalFailureCategory -ErrorRecord $ErrorRecord) {
        'InUse' {
            $SkippedInUseCount.Value++
        }
        'AccessDenied' {
            $SkippedAccessDeniedCount.Value++
        }
        default {
            $FailedCount.Value++
            Write-Log "[WARN] Failed to remove ${ItemPath}: $($ErrorRecord.Exception.Message)" -Level Warning
        }
    }
}

function Get-SafeCleanupEntries {
    param([Parameter(Mandatory)][string]$RootPath)

    $files = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $dirs = [System.Collections.Generic.List[System.IO.DirectoryInfo]]::new()
    $accessDeniedCount = 0

    $rootInfo = [System.IO.DirectoryInfo]::new($RootPath)
    if (-not $rootInfo.Exists -or (($rootInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
        return [PSCustomObject]@{
            Files             = $files
            Directories       = $dirs
            AccessDeniedCount = $accessDeniedCount
        }
    }

    $stack = [System.Collections.Generic.Stack[System.IO.DirectoryInfo]]::new()
    $stack.Push($rootInfo)

    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        try {
            if (($current.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                continue
            }

            foreach ($file in $current.EnumerateFiles()) {
                $files.Add($file)
            }

            foreach ($subDir in $current.EnumerateDirectories()) {
                if (($subDir.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    continue
                }
                $dirs.Add($subDir)
                $stack.Push($subDir)
            }
        } catch [System.UnauthorizedAccessException] {
            $accessDeniedCount++
        } catch {
            Write-Log "[WARN] Skipping unreadable directory $($current.FullName): $($_.Exception.Message)" -Level Warning
        }
    }

    return [PSCustomObject]@{
        Files             = $files
        Directories       = $dirs
        AccessDeniedCount = $accessDeniedCount
    }
}

function Invoke-Clean {
    $selected = Get-JsonArrayInput -Json $PathsJson -FilePath $PathsFile
    if (@($selected).Count -eq 0) {
        throw 'No target paths were provided to clean.'
    }

    $whitelistRaw = Get-JsonArrayInput -Json $WhitelistJson -FilePath $WhitelistFile
    $allowed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($item in $whitelistRaw) {
        $normalized = Normalize-PathString -Path ([string]$item)
        if (-not [string]::IsNullOrWhiteSpace($normalized)) {
            [void]$allowed.Add($normalized)
        }
    }

    if ($allowed.Count -eq 0) {
        throw 'No whitelisted paths were provided for cleanup validation.'
    }

    $totalDeleted = 0
    $totalFailed = 0
    $totalSkippedInUse = 0
    $totalSkippedAccessDenied = 0
    $totalBytes = 0L
    $totalScannedBytes = 0L
    $skippedProtected = 0
    $skippedInvalid = 0
    $skippedMissing = 0
    $folderResults = [System.Collections.Generic.List[object]]::new()

    foreach ($entry in $selected) {
        $path = Normalize-PathString -Path ([string]$entry)
        if ([string]::IsNullOrWhiteSpace($path)) {
            $skippedInvalid++
            $folderResults.Add([PSCustomObject]@{
                Path         = [string]$entry
                Status       = 'SkippedInvalid'
                DeletedItems = 0
                FreedBytes   = 0
                Message      = 'Skipped invalid path.'
            })
            continue
        }

        if (-not $allowed.Contains($path)) {
            Write-Log "[WARN] Skipping non-whitelisted path: $path" -Level Warning
            $skippedInvalid++
            $folderResults.Add([PSCustomObject]@{
                Path         = $path
                Status       = 'SkippedInvalid'
                DeletedItems = 0
                FreedBytes   = 0
                Message      = 'Skipped non-whitelisted path.'
            })
            continue
        }

        $protection = Get-ProtectionInfo -Path $path
        if ($protection.IsProtected) {
            Write-Log "[WARN] Skipping protected path ${path}: $($protection.Reason)" -Level Warning
            $skippedProtected++
            $folderResults.Add([PSCustomObject]@{
                Path         = $path
                Status       = 'SkippedProtected'
                DeletedItems = 0
                FreedBytes   = 0
                Message      = "Skipped protected path: $($protection.Reason)"
            })
            continue
        }

        if (-not (Test-Path -LiteralPath $path)) {
            $skippedMissing++
            $folderResults.Add([PSCustomObject]@{
                Path         = $path
                Status       = 'SkippedMissing'
                DeletedItems = 0
                FreedBytes   = 0
                Message      = 'Skipped missing path.'
            })
            continue
        }

        $rootDirInfo = [System.IO.DirectoryInfo]::new($path)
        if (-not $rootDirInfo.Exists) {
            $skippedMissing++
            $folderResults.Add([PSCustomObject]@{
                Path         = $path
                Status       = 'SkippedMissing'
                DeletedItems = 0
                FreedBytes   = 0
                Message      = 'Skipped missing directory.'
            })
            continue
        }

        if (($rootDirInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Write-Log "[WARN] Skipping reparse point / junction ${path}" -Level Warning
            $skippedProtected++
            $folderResults.Add([PSCustomObject]@{
                Path         = $path
                Status       = 'SkippedProtected'
                DeletedItems = 0
                FreedBytes   = 0
                Message      = 'Skipped reparse point / junction for safety.'
            })
            continue
        }

        try {
            $entries = Get-SafeCleanupEntries -RootPath $path
            $scannedBytes = 0L
            foreach ($file in $entries.Files) {
                try { $scannedBytes += [long]$file.Length } catch {}
            }

            $removedCount = 0
            $failedCount = 0
            $skippedInUseCount = 0
            $skippedAccessDeniedCount = [int]$entries.AccessDeniedCount
            $freedBytes = 0L

            foreach ($file in ($entries.Files | Sort-Object FullName -Descending)) {
                try {
                    $fileLength = [long]$file.Length
                    if (($file.Attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
                        $file.Attributes = [System.IO.FileAttributes]::Normal
                    }
                    $file.Delete()
                    $removedCount++
                    $freedBytes += $fileLength
                } catch {
                    Register-RemovalFailure -ItemPath $file.FullName -ErrorRecord $_ `
                        -FailedCount ([ref]$failedCount) `
                        -SkippedInUseCount ([ref]$skippedInUseCount) `
                        -SkippedAccessDeniedCount ([ref]$skippedAccessDeniedCount)
                }
            }

            foreach ($dir in ($entries.Directories | Sort-Object { $_.FullName.Length } -Descending)) {
                try {
                    if (-not [System.IO.Directory]::Exists($dir.FullName)) { continue }
                    $hasRemaining = $false
                    foreach ($unused in [System.IO.Directory]::EnumerateFileSystemEntries($dir.FullName)) {
                        $hasRemaining = $true
                        break
                    }
                    if ($hasRemaining) { continue }
                    if (($dir.Attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
                        $dir.Attributes = [System.IO.FileAttributes]::Directory
                    }
                    $dir.Delete($false)
                } catch {
                    Register-RemovalFailure -ItemPath $dir.FullName -ErrorRecord $_ `
                        -FailedCount ([ref]$failedCount) `
                        -SkippedInUseCount ([ref]$skippedInUseCount) `
                        -SkippedAccessDeniedCount ([ref]$skippedAccessDeniedCount)
                }
            }

            $totalBytes += $freedBytes
            $totalScannedBytes += $scannedBytes
            $totalDeleted += $removedCount
            $totalFailed += $failedCount
            $totalSkippedInUse += $skippedInUseCount
            $totalSkippedAccessDenied += $skippedAccessDeniedCount
            $folderFreedText = Format-SizeHuman -Bytes $freedBytes
            $folderStatus = if ($failedCount -gt 0 -or $skippedAccessDeniedCount -gt 0) { 'CleanedWithWarnings' } else { 'Cleaned' }
            $folderMessage = "Freed $folderFreedText, Deleted $removedCount item(s)."
            if ($skippedInUseCount -gt 0) {
                $folderMessage += " $skippedInUseCount skipped (in use)."
            }
            if ($skippedAccessDeniedCount -gt 0) {
                $folderMessage += " $skippedAccessDeniedCount skipped (access denied)."
            }
            if ($failedCount -gt 0) {
                $folderMessage += " $failedCount failed."
            }
            $folderResults.Add([PSCustomObject]@{
                Path                = $path
                Status              = $folderStatus
                DeletedItems        = $removedCount
                FailedItems         = $failedCount
                SkippedInUse        = $skippedInUseCount
                SkippedAccessDenied = $skippedAccessDeniedCount
                FreedBytes          = [long]$freedBytes
                ScannedBytes        = [long]$scannedBytes
                Message             = $folderMessage
            })
        } catch {
            Write-Log "[WARN] Failed to clean ${path}: $($_.Exception.Message)" -Level Warning
            $folderResults.Add([PSCustomObject]@{
                Path         = $path
                Status       = 'Warn'
                DeletedItems = 0
                FreedBytes   = 0
                Message      = "Cleanup warning: $($_.Exception.Message)"
            })
        }
    }

    [PSCustomObject]@{
        DeletedItems        = $totalDeleted
        FailedItems         = $totalFailed
        SkippedInUse        = $totalSkippedInUse
        SkippedAccessDenied = $totalSkippedAccessDenied
        FreedBytes          = [long]$totalBytes
        ScannedBytes        = [long]$totalScannedBytes
        FreedMb             = [math]::Round($totalBytes / 1MB, 1)
        PathsCount          = @($selected).Count
        SkippedProtected    = $skippedProtected
        SkippedInvalid      = $skippedInvalid
        SkippedMissing      = $skippedMissing
        FolderResults       = @($folderResults)
    }
}

try {
    switch ($Action) {
        'Scan' {
            Invoke-Scan
        }
        'Clean' {
            if (Invoke-TempFileCleanerElevationRelay) { exit 0 }

            $workflow = Start-Workflow -WorkflowName 'TempFileCleaner_Clean' -ScriptBlock {
                param($r)

                try {
                    $summary = Invoke-Clean
                } catch {
                    $msg = $_.Exception.Message
                    $r.Errors.Add($msg)
                    $r.Steps.Add([PSCustomObject]@{
                        Name   = 'TempFileClean'
                        Status = 'Fail'
                        Output = "Cleanup failed: $msg"
                    })
                    return
                }

                $freedText = Format-SizeHuman -Bytes ([long]$summary.FreedBytes)
                $topStatus = if ($summary.FailedItems -gt 0 -or $summary.SkippedInvalid -gt 0 -or $summary.SkippedMissing -gt 0 -or $summary.PathsCount -eq 0) { 'Warn' } else { 'Pass' }
                $failedSuffix = if ($summary.FailedItems -gt 0) { " Failed: $($summary.FailedItems)." } else { '' }
                $inUseSuffix = if ($summary.SkippedInUse -gt 0) { " In-use: $($summary.SkippedInUse)." } else { '' }
                $accessSuffix = if ($summary.SkippedAccessDenied -gt 0) { " Access denied: $($summary.SkippedAccessDenied)." } else { '' }
                $r.Steps.Add([PSCustomObject]@{
                    Name   = 'TempFileClean'
                    Status = $topStatus
                    Output = "Cleaned $($summary.DeletedItems) items and freed ~$freedText across $($summary.PathsCount) selected location(s). Skipped: protected=$($summary.SkippedProtected), invalid=$($summary.SkippedInvalid), missing=$($summary.SkippedMissing).$inUseSuffix$accessSuffix$failedSuffix"
                })

                foreach ($folder in @($summary.FolderResults)) {
                    $stepStatus = switch ($folder.Status) {
                        'Cleaned' { 'Pass' }
                        'CleanedWithWarnings' { 'Warn' }
                        'SkippedProtected' { 'Warn' }
                        'SkippedInvalid' { 'Warn' }
                        'SkippedMissing' { 'Warn' }
                        default { 'Warn' }
                    }

                    $r.Steps.Add([PSCustomObject]@{
                        Name   = 'Folder Cleanup'
                        Status = $stepStatus
                        Output = [string]$folder.Message
                        Detail = [string]$folder.Path
                    })
                }
            }

            $null = Set-WorkflowOverallHealth -WorkflowResult $workflow
            $workflow | ConvertTo-Json -Depth 10
            Generate-Report -WorkflowResult $workflow | Out-Null
            if ($workflow.Status -eq 'Failed') {
                exit 1
            }
        }
        default {
            throw "Unsupported action: $Action"
        }
    }
} catch {
    Write-Error "TempFileCleaner action '$Action' failed: $($_.Exception.Message)"
    exit 1
}