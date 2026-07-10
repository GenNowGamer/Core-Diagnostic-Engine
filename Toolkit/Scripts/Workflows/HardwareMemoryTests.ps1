#Requires -Version 5.1

function Set-HwMemoryCoverageGuidance {
    param([int]$SizeMB)

    $script:HwMemoryCoverageIncomplete = $false
    $coverage = Get-MemoryCoverageDetail -SizeMB $SizeMB
    $totalRamMB = 0
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os) { $totalRamMB = [math]::Round($os.TotalVisibleMemorySize / 1024) }
    } catch {}

    if ($totalRamMB -le 0) {
        Write-Log ("Memory coverage: {0}" -f $coverage)
        return
    }

    $pct = ($SizeMB / $totalRamMB) * 100.0
    $threshold = if ($script:HwProfileName -eq 'Extended') { 20.0 } else { 15.0 }
    if ($pct -lt $threshold) {
        $script:HwMemoryCoverageIncomplete = $true
        Write-Log ("Memory coverage incomplete: {0} (below {1}% of installed RAM; CHU recommended)" -f $coverage, [int]$threshold) -Level Warning
        return
    }

    Write-Log ("Memory coverage: {0}" -f $coverage)
}

function Invoke-MemoryTests {
    param($r)

    $sizeMB = Get-MemoryTestSizeMB
    $coverage = Get-MemoryCoverageDetail -SizeMB $sizeMB
    Set-HwMemoryCoverageGuidance -SizeMB $sizeMB

    $totalRamMB = 0
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os) { $totalRamMB = [math]::Round($os.TotalVisibleMemorySize / 1024) }
    } catch {}
    $memLabel = if ($totalRamMB -gt 0) { 'System Memory ({0} MB)' -f $totalRamMB } else { 'System Memory' }
    Write-Log ('Memory: {0} - {1}, {2} pass(es) per pattern ({3} profile)' -f $memLabel, $coverage, [HardwareTestEngine]::MemoryPatternPasses, $script:HwProfileName)
    Write-HwDeviceHeader -Category 'Memory' -DeviceTitle $memLabel

    $catalogTests = Get-HardwareTestsForCategory -Category Memory -Profile $script:HwProfileName
    $total = $catalogTests.Count
    $counter = [ref]0
    $phase = 'Memory Tests'

    foreach ($entry in $catalogTests) {
        $displayName = $entry.displayName
        $impl = [string]$entry.implementations.windows
        Invoke-SingleTest -Category 'Memory' -TestName $displayName -Result $r -Counter $counter -Total $total -Phase $phase -TestAction {
            $result = [HardwareTestEngine]::RunMemoryTest($displayName, $sizeMB)
            if ($result.StartsWith('Passed')) {
                return ('Passed: {0}' -f $coverage)
            }
            return $result
        }
    }
}
