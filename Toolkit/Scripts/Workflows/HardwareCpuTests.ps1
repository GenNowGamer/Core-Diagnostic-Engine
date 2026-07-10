#Requires -Version 5.1

function Invoke-CpuTests {
    param($r)

    $cpuName = 'Unknown CPU'
    try {
        $cpuObj = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cpuObj) { $cpuName = $cpuObj.Name.Trim() }
    } catch {
        try {
            $cpuObj = Get-WmiObject Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($cpuObj) { $cpuName = $cpuObj.Name.Trim() }
        } catch {}
    }
    Write-Log "CPU: $cpuName"
    Write-HwDeviceHeader -Category 'CPU' -DeviceTitle ('Processor: {0}' -f $cpuName)

    $catalogTests = Get-HardwareTestsForCategory -Category CPU -Profile $script:HwProfileName
    $total = $catalogTests.Count
    $counter = [ref]0
    $phase = 'CPU Tests'
    $simdStub = Test-CpuSimdEngineIsStub

    foreach ($entry in $catalogTests) {
        $displayName = $entry.displayName
        $impl = $entry.implementations.windows

        Invoke-SingleTest -Category 'CPU' -TestName $displayName -Result $r -Counter $counter -Total $total -Phase $phase -TestAction {
            if ($simdStub -and $impl -match '^Run(Mmx|Sse)') {
                return 'Warn: SIMD intrinsics not verified on this host (stub engine)'
            }
            switch ($impl) {
                'RunCacheTest'           { return [HardwareTestEngine]::RunCacheTest() }
                'RunRegisterTest'        { return [HardwareTestEngine]::RunRegisterTest() }
                'RunMmxTest'             { return Invoke-CpuSimdEngineTest -Implementation 'RunMmxTest' }
                'RunSseTest'             { return Invoke-CpuSimdEngineTest -Implementation 'RunSseTest' }
                'RunSse2Test'            { return Invoke-CpuSimdEngineTest -Implementation 'RunSse2Test' }
                'RunSse3Test'            { return Invoke-CpuSimdEngineTest -Implementation 'RunSse3Test' }
                'RunSsse3Test'           { return Invoke-CpuSimdEngineTest -Implementation 'RunSsse3Test' }
                'RunSse41Test'           { return Invoke-CpuSimdEngineTest -Implementation 'RunSse41Test' }
                'RunSse42Test'           { return Invoke-CpuSimdEngineTest -Implementation 'RunSse42Test' }
                'RunMathRegisterTest'    { return [HardwareTestEngine]::RunMathRegisterTest() }
                'RunPrimeGenerationTest' { return [HardwareTestEngine]::RunPrimeGenerationTest() }
                'RunFpuTest'             { return [HardwareTestEngine]::RunFpuTest() }
                'RunCpuStressTest' {
                    $result = [HardwareTestEngine]::RunCpuStressTest()
                    if ($result -is [string] -and ($result.StartsWith('Failed') -or $result.StartsWith('Warn:'))) {
                        $script:HwCpuStressIncomplete = $true
                    }
                    return $result
                }
                default                  { return $false }
            }
        }
    }
}
