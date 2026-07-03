#Requires -Version 5.1

function Invoke-MemoryTests {
    param($r)

    $sizeMB = Get-MemoryTestSizeMB
    $coverage = Get-MemoryCoverageDetail -SizeMB $sizeMB

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
        Invoke-SingleTest -Category 'Memory' -TestName $displayName -Result $r -Counter $counter -Total $total -Phase $phase -TestAction {
            $result = [HardwareTestEngine]::RunMemoryTest($displayName, $sizeMB)
            if ($result.StartsWith('Passed')) {
                return ('Passed: {0}' -f $coverage)
            }
            return $result
        }
    }
}
