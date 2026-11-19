#Requires -Version 5.1

function Set-HwMemoryCoverageGuidance {
    param(
        [int]$SizeMB,
        [int]$TotalRamMB = 0,
        [string]$Coverage = ''
    )

    $script:HwMemoryCoverageIncomplete = $false
    if ([string]::IsNullOrWhiteSpace($Coverage)) {
        $Coverage = Get-MemoryCoverageDetail -SizeMB $SizeMB -TotalRamMB $TotalRamMB
    }
    if ($TotalRamMB -le 0) {
        try {
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
            if ($os) { $TotalRamMB = [math]::Round($os.TotalVisibleMemorySize / 1024) }
        } catch {}
    }

    if ($TotalRamMB -le 0) {
        Write-Log ("Memory coverage: {0}" -f $Coverage)
        return
    }

    $pct = ($SizeMB / $TotalRamMB) * 100.0
    $threshold = if ($script:HwProfileName -eq 'Extended') { 10.0 } else { 3.0 }
    if ($pct -lt $threshold) {
        $script:HwMemoryCoverageIncomplete = $true
        Write-Log ("Memory coverage incomplete: {0} (below {1}% of installed RAM; CHU recommended)" -f $Coverage, [int]$threshold) -Level Warning
        return
    }

    Write-Log ("Memory coverage: {0}" -f $Coverage)
}

function Invoke-MemoryTests {
    param($r)

    $os = $null
    $totalRamMB = 0
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os) { $totalRamMB = [math]::Round($os.TotalVisibleMemorySize / 1024) }
    } catch {}

    $sizeMB = Get-MemoryTestSizeMB -OsInfo $os
    $coverage = Get-MemoryCoverageDetail -SizeMB $sizeMB -TotalRamMB $totalRamMB
    Set-HwMemoryCoverageGuidance -SizeMB $sizeMB -TotalRamMB $totalRamMB -Coverage $coverage

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
            $result = [HardwareTestEngine]::RunMemoryTest($impl, $sizeMB)
            if ($result.StartsWith('Passed')) {
                return ('Passed: {0}' -f $coverage)
            }
            return $result
        }
    }
}
