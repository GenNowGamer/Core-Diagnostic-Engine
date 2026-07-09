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

    $raw = if (-not [string]::IsNullOrWhiteSpace($FilePath) -and (Test-Path -LiteralPath $FilePath)) {
        Get-Content -LiteralPath $FilePath -Raw
    } else {
        $Json
    }

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }

    try {
        $parsed = $raw | ConvertFrom-Json
    } catch {
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

    $candidate = [string]$Path
    if ($candidate -match '^[A-Za-z]:$') {
        $candidate = "${candidate}\\"
    }

    try {
        return [System.IO.Path]::GetFullPath($candidate).TrimEnd('\\')
    } catch {
        return $candidate.Trim().TrimEnd('\\')
    }
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
        if (-not (Test-Path -LiteralPath $normalized)) { return }
        if (-not $Seen.Add($normalized)) { return }

        $fileItems = @(Get-ChildItem -LiteralPath $normalized -File -Recurse -Force -ErrorAction SilentlyContinue)
        $bytesRaw = ($fileItems | Measure-Object Length -Sum -ErrorAction SilentlyContinue).Sum
        $bytes = if ($null -eq $bytesRaw) { 0L } else { [long]$bytesRaw }

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
            FileCount        = [int]$fileItems.Count
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
                    @{ Rel = 'AppData\Roaming\Mozilla\Firefox\Profiles'; Cat = 'Firefox Cache' }
                )

                foreach ($target in $targets) {
                    Add-ScanLocation -Locations $locations -Seen $seenPaths -Path (Join-Path $user.FullName $target.Rel) -Category $target.Cat -UserAccount $user.Name -ProfileGroup $user.Name -DiscoverySource 'DynamicProfile'
                }
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

    $locations | ConvertTo-Json -Depth 4
}

function Test-IsUnavailableForDeletionException {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)

    $message = [string]$ErrorRecord.Exception.Message
    if ($message -match 'being used by another process') { return $true }
    if ($message -match 'cannot access the file.*because it is being used') { return $true }
    if ($message -match 'Access to the path .* is denied\.?') { return $true }

    $exception = $ErrorRecord.Exception
    if ($exception -is [System.UnauthorizedAccessException]) { return $true }
    if ($exception -is [System.IO.IOException] -and $message -match 'is denied') { return $true }

    $inner = $exception.InnerException
    if ($null -ne $inner) {
        $innerMessage = [string]$inner.Message
        if ($innerMessage -match 'being used by another process') { return $true }
        if ($innerMessage -match 'cannot access the file.*because it is being used') { return $true }
        if ($innerMessage -match 'Access to the path .* is denied\.?') { return $true }
        if ($inner -is [System.UnauthorizedAccessException]) { return $true }
    }

    $win32 = $exception.HResult -band 0xFFFF
    if ($win32 -in @(0x0020, 0x0021, 0x0005)) { return $true }

    return $false
}

function Register-RemovalFailure {
    param(
        [string]$ItemPath,
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [ref]$FailedCount,
        [ref]$SkippedInUseCount
    )

    if (Test-IsUnavailableForDeletionException -ErrorRecord $ErrorRecord) {
        $SkippedInUseCount.Value++
        return
    }

    $FailedCount.Value++
    Write-Log "[WARN] Failed to remove ${ItemPath}: $($ErrorRecord.Exception.Message)" -Level Warning
}

function Invoke-Clean {
    $selected = Get-JsonArrayInput -Json $PathsJson -FilePath $PathsFile
    $whitelistRaw = Get-JsonArrayInput -Json $WhitelistJson -FilePath $WhitelistFile
    $allowed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($item in $whitelistRaw) {
        $normalized = Normalize-PathString -Path ([string]$item)
        if (-not [string]::IsNullOrWhiteSpace($normalized)) {
            [void]$allowed.Add($normalized)
        }
    }

    $totalDeleted = 0
    $totalFailed = 0
    $totalSkippedInUse = 0
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
                Path = [string]$entry
                Status = 'SkippedInvalid'
                DeletedItems = 0
                FreedBytes = 0
                Message = 'Skipped invalid path.'
            })
            continue
        }

        if (-not $allowed.Contains($path)) {
            Write-Log "[WARN] Skipping non-whitelisted path: $path" -Level Warning
            $skippedInvalid++
            $folderResults.Add([PSCustomObject]@{
                Path = $path
                Status = 'SkippedInvalid'
                DeletedItems = 0
                FreedBytes = 0
                Message = 'Skipped non-whitelisted path.'
            })
            continue
        }

        $protection = Get-ProtectionInfo -Path $path
        if ($protection.IsProtected) {
            Write-Log "[WARN] Skipping protected path ${path}: $($protection.Reason)" -Level Warning
            $skippedProtected++
            $folderResults.Add([PSCustomObject]@{
                Path = $path
                Status = 'SkippedProtected'
                DeletedItems = 0
                FreedBytes = 0
                Message = "Skipped protected path: $($protection.Reason)"
            })
            continue
        }

        if (-not (Test-Path -LiteralPath $path)) {
            $skippedMissing++
            $folderResults.Add([PSCustomObject]@{
                Path = $path
                Status = 'SkippedMissing'
                DeletedItems = 0
                FreedBytes = 0
                Message = 'Skipped missing path.'
            })
            continue
        }

        try {
            $fileItems = @(Get-ChildItem -LiteralPath $path -File -Recurse -Force -ErrorAction SilentlyContinue)
            $dirItems  = @(Get-ChildItem -LiteralPath $path -Directory -Recurse -Force -ErrorAction SilentlyContinue)

            $bytesRaw = ($fileItems | Measure-Object Length -Sum -ErrorAction SilentlyContinue).Sum
            $scannedBytes = if ($null -eq $bytesRaw) { 0L } else { [long]$bytesRaw }

            $removedCount = 0
            $failedCount = 0
            $skippedInUseCount = 0
            $freedBytes = 0L
            foreach ($item in ($fileItems | Sort-Object FullName -Descending)) {
                try {
                    $fileLength = [long]$item.Length
                    Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
                    $removedCount++
                    $freedBytes += $fileLength
                } catch {
                    Register-RemovalFailure -ItemPath $item.FullName -ErrorRecord $_ `
                        -FailedCount ([ref]$failedCount) -SkippedInUseCount ([ref]$skippedInUseCount)
                }
            }

            foreach ($item in ($dirItems | Sort-Object FullName -Descending)) {
                try {
                    Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
                } catch {
                    Register-RemovalFailure -ItemPath $item.FullName -ErrorRecord $_ `
                        -FailedCount ([ref]$failedCount) -SkippedInUseCount ([ref]$skippedInUseCount)
                }
            }

            try {
                Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue |
                    Sort-Object FullName -Descending |
                    ForEach-Object {
                        try {
                            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                        } catch {}
                    }
            } catch {}

            $totalBytes += $freedBytes
            $totalScannedBytes += $scannedBytes
            $totalDeleted += $removedCount
            $totalFailed += $failedCount
            $totalSkippedInUse += $skippedInUseCount
            $folderFreedText = Format-SizeHuman -Bytes $freedBytes
            $folderStatus = if ($failedCount -eq 0) { 'Cleaned' } else { 'CleanedWithWarnings' }
            $folderMessage = "Freed $folderFreedText, Deleted $removedCount item(s)."
            if ($skippedInUseCount -gt 0) {
                $folderMessage += " $skippedInUseCount skipped (in use)."
            }
            if ($failedCount -gt 0) {
                $folderMessage += " $failedCount failed."
            }
            $folderResults.Add([PSCustomObject]@{
                Path = $path
                Status = $folderStatus
                DeletedItems = $removedCount
                FailedItems = $failedCount
                SkippedInUse = $skippedInUseCount
                FreedBytes = [long]$freedBytes
                ScannedBytes = [long]$scannedBytes
                Message = $folderMessage
            })
        } catch {
            Write-Log "[WARN] Failed to clean ${path}: $($_.Exception.Message)" -Level Warning
            $folderResults.Add([PSCustomObject]@{
                Path = $path
                Status = 'Warn'
                DeletedItems = 0
                FreedBytes = 0
                Message = "Cleanup warning: $($_.Exception.Message)"
            })
        }
    }

    [PSCustomObject]@{
        DeletedItems = $totalDeleted
        FailedItems = $totalFailed
        SkippedInUse = $totalSkippedInUse
        FreedBytes = [long]$totalBytes
        ScannedBytes = [long]$totalScannedBytes
        FreedMb = [math]::Round($totalBytes / 1MB, 1)
        PathsCount = @($selected).Count
        SkippedProtected = $skippedProtected
        SkippedInvalid = $skippedInvalid
        SkippedMissing = $skippedMissing
        FolderResults = @($folderResults)
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

                $summary = Invoke-Clean
                $freedText = Format-SizeHuman -Bytes ([long]$summary.FreedBytes)
                $topStatus = if ($summary.FailedItems -gt 0) { 'Warn' } else { 'Pass' }
                $failedSuffix = if ($summary.FailedItems -gt 0) { " Failed: $($summary.FailedItems)." } else { '' }
                $inUseSuffix = if ($summary.SkippedInUse -gt 0) { " In-use: $($summary.SkippedInUse)." } else { '' }
                $r.Steps.Add([PSCustomObject]@{
                    Name = 'TempFileClean'
                    Status = $topStatus
                    Output = "Cleaned $($summary.DeletedItems) items and freed ~$freedText across $($summary.PathsCount) selected location(s). Skipped: protected=$($summary.SkippedProtected), invalid=$($summary.SkippedInvalid), missing=$($summary.SkippedMissing).$inUseSuffix$failedSuffix"
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
                        Name = 'Folder Cleanup'
                        Status = $stepStatus
                        Output = [string]$folder.Message
                        Detail = [string]$folder.Path
                    })
                }
            }

            $workflow | ConvertTo-Json -Depth 10
            Generate-Report -WorkflowResult $workflow | Out-Null
        }
        default {
            throw "Unsupported action: $Action"
        }
    }
} catch {
    Write-Error "TempFileCleaner action '$Action' failed: $($_.Exception.Message)"
    exit 1
}