#Requires -Version 5.1

function Invoke-StorageTestsForDrive {
    param(
        $Result,
        [hashtable]$DriveInfo,
        [ref]$Counter,
        [int]$TestsPerDrive,
        [string]$Phase
    )

    $driveDeviceId = $DriveInfo.DeviceId
    $driveIndex = $DriveInfo.Index
    $timeout = [int]$script:HwProfileParams.smartSelfTestTimeoutSec

    $catalogTests = Get-HardwareTestsForCategory -Category HardDrive -Profile $script:HwProfileName

    foreach ($entry in $catalogTests) {
        $displayName = $entry.displayName
        $impl = $entry.implementations.windows

        Invoke-SingleTest -Category 'Hard Drive' -TestName $displayName -Result $Result `
            -Counter $Counter -Total $TestsPerDrive -Phase $Phase -DriveInfo $DriveInfo -TestAction {
            switch ($impl) {
                'SmartThresholds' {
                    return (Test-CdeSmartThresholds -DriveIndex $driveIndex)
                }
                'SmartStatus' {
                    return (Test-CdeSmartStatus -DriveIndex $driveIndex)
                }
                'TargetedRead' {
                    if (-not $driveDeviceId) { return 'Skipped: No physical drive path (run as Administrator)' }
                    try {
                        $rng = New-Object System.Random(42)
                        $bufSize = 65536
                        $buf = New-Object byte[] $bufSize
                        $stream = [System.IO.File]::Open($driveDeviceId, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                        try {
                            $bufSize64 = [int64]$bufSize
                            $diskLen = [int64](Get-HwDriveLengthBytes -DriveInfo $DriveInfo -Stream $stream)
                            if ($diskLen -le 512) { return 'Failed: Drive length unavailable' }
                            $readCount = $script:HwStorageRandomReads
                            $upper = Get-HwInt64Max -Left 512 -Right ($diskLen - $bufSize64)
                            for ($i = 0; $i -lt $readCount; $i++) {
                                $offset = [int64]($rng.NextDouble() * $upper)
                                $offset = $offset - ($offset % 512)
                                $stream.Position = $offset
                                $read = $stream.Read($buf, 0, $bufSize)
                                if ($read -le 0) { return ('Failed: Read returned {0} bytes at offset {1}' -f $read, $offset) }
                            }
                            return ('Passed: {0} random 64KB reads' -f $readCount)
                        } finally {
                            $stream.Close()
                        }
                    } catch [System.UnauthorizedAccessException] {
                        return 'Skipped: Access denied - run CDE as Administrator for physical drive reads'
                    }
                }
                'LinearRead' {
                    if (-not $driveDeviceId) { return 'Skipped: No physical drive path (run as Administrator)' }
                    try {
                        $bufSize = 65536
                        $buf = New-Object byte[] $bufSize
                        $readLimit = $script:HwStorageLinearReadMb * 1024 * 1024
                        $stream = [System.IO.File]::Open($driveDeviceId, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                        try {
                            $totalRead = 0
                            while ($totalRead -lt $readLimit) {
                                $bytesRead = $stream.Read($buf, 0, $bufSize)
                                if ($bytesRead -eq 0) { break }
                                $totalRead += $bytesRead
                            }
                            if ($totalRead -lt 1048576) { return ('Failed: Only read {0} bytes sequentially' -f $totalRead) }
                            return ('Passed: {0} MB linear read' -f [math]::Round($totalRead / 1MB, 1))
                        } finally {
                            $stream.Close()
                        }
                    } catch [System.UnauthorizedAccessException] {
                        return 'Skipped: Access denied - run CDE as Administrator for physical drive reads'
                    }
                }
                'LinearReadEnd' {
                    if (-not $driveDeviceId) { return 'Skipped: No physical drive path (run as Administrator)' }
                    try {
                        $bufSize = 65536
                        $buf = New-Object byte[] $bufSize
                        $readLimit = [int64]($script:HwStorageLinearReadMb * 1024 * 1024)
                        $stream = [System.IO.File]::Open($driveDeviceId, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                        try {
                            $diskLen = [int64](Get-HwDriveLengthBytes -DriveInfo $DriveInfo -Stream $stream)
                            if ($diskLen -le 512) { return 'Failed: Drive length unavailable for end-of-disk read' }
                            $startPos = Get-HwInt64Max -Left 0 -Right ($diskLen - $readLimit)
                            $startPos = $startPos - ($startPos % 512)
                            $stream.Position = $startPos
                            $totalRead = 0
                            while ($totalRead -lt $readLimit) {
                                $bytesRead = $stream.Read($buf, 0, $bufSize)
                                if ($bytesRead -eq 0) { break }
                                $totalRead += $bytesRead
                            }
                            if ($totalRead -lt 1048576) { return ('Failed: Only read {0} bytes at end of disk' -f $totalRead) }
                            return ('Passed: {0} MB end-of-disk linear read' -f [math]::Round($totalRead / 1MB, 1))
                        } finally {
                            $stream.Close()
                        }
                    } catch [System.UnauthorizedAccessException] {
                        return 'Skipped: Access denied - run CDE as Administrator for physical drive reads'
                    }
                }
                'SmartSelfTest' {
                    return (Start-CdeSmartShortSelfTest -DriveIndex $driveIndex -TimeoutSec $timeout)
                }
                default {
                    return 'Failed: Unknown storage test implementation'
                }
            }
        }
    }
}

function Invoke-StorageTests {
    param($r)

    $disks = Get-HwPhysicalDisks
    $testsPerDrive = (Get-HardwareTestsForCategory -Category HardDrive -Profile $script:HwProfileName).Count
    $counter = [ref]0
    $phase = 'Storage Tests'

    if ($disks.Count -eq 0) {
        Write-Log 'Storage: no physical drives detected' -Level Warning
        Invoke-SingleTest -Category 'Hard Drive' -TestName 'Storage Discovery' -Result $r `
            -Counter $counter -Total 1 -Phase $phase -TestAction {
            return 'Failed: No physical drives detected'
        }
        return
    }

    foreach ($disk in $disks) {
        $driveInfo = New-HwDriveInfo -Disk $disk
        Write-Log ('Storage: {0} | {1}' -f $driveInfo.Title, $driveInfo.PhysicalPath)
        Add-HwDriveHeaderStep -Result $r -DriveInfo $driveInfo
        Invoke-StorageTestsForDrive -Result $r -DriveInfo $driveInfo `
            -Counter $counter -TestsPerDrive $testsPerDrive -Phase $phase
    }
}
