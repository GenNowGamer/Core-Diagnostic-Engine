#Requires -Version 5.1
# Shared helpers for Diag & Repair hardware workflows (dot-sourced).

$script:HwCoreDir = Join-Path (Split-Path $MyInvocation.MyCommand.Path) '..\Core'
Import-Module (Join-Path $script:HwCoreDir 'PhysicalDiskCatalog.psm1') -Force -DisableNameChecking

$script:HwGlobalTotal = 28
$script:HwGlobalDone = 0
$script:HwProfileName = 'Quick'
$script:HwProfileParams = $null
$script:HwStorageRandomReads = 64
$script:HwStorageLinearReadMb = 32
$script:HwStorageSkippedInRun = $false

function Initialize-HwTestProfile {
    param([string]$Profile)

    $script:HwProfileName = if ($Profile -eq 'Extended') { 'Extended' } else { 'Quick' }
    $script:HwProfileParams = Get-HardwareTestProfileParameters -Profile $script:HwProfileName
    $p = $script:HwProfileParams

    Initialize-HardwareTestEngineFromCatalog -ProfileParams $p

    $script:HwStorageRandomReads = [int]$p.storageRandomReads
    $script:HwStorageLinearReadMb = [int]$p.storageLinearReadMb
    $script:HwStorageSkippedInRun = $false
}

function Get-HwPhysicalDisks {
    return @(Get-CdeTestablePhysicalDisks)
}

function Get-HwStorageSubTestCount {
    $storCount = (Get-HardwareTestsForCategory -Category HardDrive -Profile $script:HwProfileName).Count
    $disks = Get-HwPhysicalDisks
    if ($disks.Count -eq 0) { return 1 }
    return $disks.Count * $storCount
}

function Get-HwTestTotal {
    param([string]$Name)
    $counts = Get-HardwareTestCountByCategory -Profile $script:HwProfileName
    switch ($Name) {
        'CpuTests'     { return $counts.CPU }
        'MemoryTests'  { return $counts.Memory }
        'StorageTests' { return (Get-HwStorageSubTestCount) }
        'CstScan'      { return 1 }
        default        { return $counts.CPU + $counts.Memory + (Get-HwStorageSubTestCount) }
    }
}

function Get-HwDrivePhysicalPath {
    param($Disk)
    $deviceId = [string]$Disk.DeviceID
    if ($deviceId -match 'PHYSICALDRIVE(\d+)') {
        return ('\\.\PHYSICALDRIVE{0}' -f $matches[1])
    }
    return $deviceId
}

function New-HwDriveInfo {
    param($Disk)
    $model = if ($Disk.Model) { [string]$Disk.Model.Trim() } else { 'Unknown Model' }
    $sizeGB = if ($Disk.Size) { [math]::Round($Disk.Size / 1GB, 1) } else { 0 }
    $sizeBytes = if ($Disk.Size) { [int64]$Disk.Size } else { [int64]0 }
    $index = if ($null -ne $Disk.Index) { [int]$Disk.Index } else { 0 }
    $deviceId = [string]$Disk.DeviceID
    $physicalPath = Get-HwDrivePhysicalPath -Disk $Disk
    $title = 'Drive {0}: {1} ({2} GB)' -f $index, $model, $sizeGB
    return @{
        Index        = $index
        Model        = $model
        SizeGB       = $sizeGB
        SizeBytes    = $sizeBytes
        DeviceId     = $deviceId
        PhysicalPath = $physicalPath
        Title        = $title
        ContextTag   = ('Drive {0}: {1} | {2}' -f $index, $model, $physicalPath)
        WmiDisk      = $Disk
    }
}

function Add-HwDriveHeaderStep {
    param($Result, [hashtable]$DriveInfo)
    Write-HwDeviceHeader -Category 'Hard Drive' -DeviceTitle ('Hard Drive: {0}' -f $DriveInfo.Title) -DriveIndex $DriveInfo.Index
    $detail = '{0} | {1}' -f $DriveInfo.Title, $DriveInfo.PhysicalPath
    $Result.Steps.Add([PSCustomObject]@{
        Name   = $DriveInfo.Title
        Status = 'Pass'
        Output = $detail
        Detail = $detail
    })
}

function Get-HwDriveLengthBytes {
    param([hashtable]$DriveInfo, [System.IO.Stream]$Stream = $null)
    if ($DriveInfo.SizeBytes -and [int64]$DriveInfo.SizeBytes -gt 0) { return [int64]$DriveInfo.SizeBytes }
    if ($DriveInfo.WmiDisk -and $DriveInfo.WmiDisk.Size) {
        $wmiSize = [int64]$DriveInfo.WmiDisk.Size
        if ($wmiSize -gt 0) { return $wmiSize }
    }
    if ($Stream -and $Stream.CanSeek) {
        try {
            $streamLen = [int64]$Stream.Length
            if ($streamLen -gt 0) { return $streamLen }
        } catch {}
    }
    return [int64]0
}

function Get-HwInt64Max {
    param([long]$Left, [long]$Right)
    if ($Left -gt $Right) { return $Left }
    return $Right
}

function Get-MemoryTestSizeMB {
    $p = $script:HwProfileParams
    if ((Get-EnvironmentMode) -eq 'WinPE') {
        return [int]$p.memoryWinPeMb
    }
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os) {
            $freeMb = [math]::Round($os.FreePhysicalMemory / 1024)
            $target = [math]::Floor($freeMb * [double]$p.memoryFreePercent)
            $cap = [int]$p.memorySizeCapMb
            $floor = [int]$p.memorySizeFloorMb
            return [int][math]::Min($cap, [math]::Max($floor, $target))
        }
    } catch {}
    return [int]$p.memorySizeCapMb
}

function Get-MemoryCoverageDetail {
    param([int]$SizeMB)
    $totalRamMB = 0
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os) { $totalRamMB = [math]::Round($os.TotalVisibleMemorySize / 1024) }
    } catch {}
    $blocks = [HardwareTestEngine]::MemoryBlockCount
    $testedMb = $SizeMB
    if ($totalRamMB -gt 0) {
        $pct = [math]::Round(($testedMb / $totalRamMB) * 100, 1)
        return ('{0} MB tested (~{1}% of {2} MB installed)' -f $testedMb, $pct, $totalRamMB)
    }
    return ('{0} MB tested ({1} block(s))' -f $testedMb, $blocks)
}

function Write-HwDeviceHeader {
    param(
        [string]$Category,
        [string]$DeviceTitle,
        [int]$DriveIndex = -1
    )
    Write-HwTestEvent -Category $Category -Test '' -Status 'Header' -Detail $DeviceTitle -DriveIndex $DriveIndex
}

function Write-HwTestEvent {
    param(
        [string]$Category,
        [string]$Test,
        [string]$Status,
        [string]$Detail = '',
        [double]$DurationSec = -1,
        [int]$DriveIndex = -1
    )
    $payload = @{ category = $Category; test = $Test; status = $Status }
    if ($Detail) { $payload.detail = $Detail }
    if ($DurationSec -ge 0) { $payload.durationSec = $DurationSec }
    if ($DriveIndex -ge 0) { $payload.driveIndex = $DriveIndex }
    Write-Host "[HW:TEST] $($payload | ConvertTo-Json -Compress)"
}

function Write-HwProgress {
    param([int]$Percent, [int]$Scanned, [int]$Total, [string]$CurrentTest, [string]$Phase)
    $payload = @{ percent = $Percent; scanned = $Scanned; total = $Total; currentTest = $CurrentTest; phase = $Phase }
    Write-Host "[HW:PROGRESS] $($payload | ConvertTo-Json -Compress)"
}

function Invoke-SingleTest {
    param(
        [string]$Category,
        [string]$TestName,
        [scriptblock]$TestAction,
        [object]$Result,
        [ref]$Counter,
        [int]$Total,
        [string]$Phase,
        [hashtable]$DriveInfo = $null
    )

    $driveIndex = if ($DriveInfo) { [int]$DriveInfo.Index } else { -1 }
    Write-HwTestEvent -Category $Category -Test $TestName -Status 'Running' -DriveIndex $driveIndex
    $pct = if ($script:HwGlobalTotal -gt 0) {
        [math]::Floor($script:HwGlobalDone / $script:HwGlobalTotal * 100)
    } else {
        [math]::Floor($Counter.Value / $Total * 100)
    }
    Write-HwProgress -Percent $pct -Scanned $script:HwGlobalDone -Total $script:HwGlobalTotal `
                     -CurrentTest $TestName -Phase $Phase
    Write-Log "Running: $TestName"

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $testResult = & $TestAction
        $passed = $false
        $detail = ''

        if ($testResult -is [bool]) {
            $passed = $testResult
            $detail = if ($passed) { 'Verification OK' } else { 'Verification failed' }
        } elseif ($testResult -is [string]) {
            if ($testResult.StartsWith('Skipped:')) {
                $passed = $true
                $detail = $testResult
                if ($script:HwProfileName -eq 'Extended' -and $script:HwProfileParams.failOnSkipInExtended) {
                    $script:HwStorageSkippedInRun = $true
                }
            } elseif ($testResult.StartsWith('Warn:')) {
                $passed = $true
                $detail = $testResult.Substring(5).Trim()
            } else {
                $passed = $testResult -eq 'Passed' -or $testResult.StartsWith('Passed')
                $detail = $testResult
            }
        } else {
            $passed = $true
            $detail = 'Completed'
        }

        $sw.Stop()
        $durationSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        if ($detail -notmatch '^Skipped:') {
            $detail = ('{0} ({1}s)' -f $detail, $durationSec)
        }

        $status = if ($passed) {
            if ($detail -match '^Skipped:') { 'Skipped' }
            elseif ($detail -match 'SIMD intrinsics not verified') { 'Warn' }
            else { 'Passed' }
        } else { 'Failed' }
        $stepName = if ($DriveInfo) {
            ('Drive {0}: {1}' -f $DriveInfo.Index, $TestName)
        } else {
            $TestName
        }
        $outputDetail = if ($DriveInfo) {
            ('[{0}] {1}' -f $DriveInfo.ContextTag, $detail)
        } else {
            $detail
        }

        Write-HwTestEvent -Category $Category -Test $TestName -Status $status -Detail $outputDetail -DurationSec $durationSec -DriveIndex $driveIndex
        Write-Log "$stepName : $status - $outputDetail"
        $stepStatus = switch ($status) {
            'Failed' { 'Fail' }
            'Warn' { 'Warn' }
            default { 'Pass' }
        }
        $Result.Steps.Add([PSCustomObject]@{
            Name   = $stepName
            Status = $stepStatus
            Output = $outputDetail
            Detail = $outputDetail
        })
    }
    catch {
        $sw.Stop()
        $durationSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        $msg = $_.Exception.Message
        $stepName = if ($DriveInfo) {
            ('Drive {0}: {1}' -f $DriveInfo.Index, $TestName)
        } else {
            $TestName
        }
        $outputDetail = if ($DriveInfo) {
            ('[{0}] {1}' -f $DriveInfo.ContextTag, $msg)
        } else {
            $msg
        }
        Write-HwTestEvent -Category $Category -Test $TestName -Status 'Failed' -Detail $outputDetail -DurationSec $durationSec -DriveIndex $driveIndex
        Write-Log "$stepName : Failed - $outputDetail" -Level Error
        $Result.Steps.Add([PSCustomObject]@{
            Name   = $stepName
            Status = 'Fail'
            Output = $outputDetail
            Detail = $outputDetail
        })
    }

    $Counter.Value++
    $script:HwGlobalDone++
}
