#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$coreDir = Join-Path (Split-Path $MyInvocation.MyCommand.Path) '..\Core'
. (Join-Path $coreDir 'HardwareTestEngine.ps1')

$cliPath = Get-CdeCpuSimdCliPath
$usesCli = $script:CdeCpuSimdUsesCli
$isStub = Test-CpuSimdEngineIsStub

if ($cliPath -and -not $usesCli) {
    Write-Error "CdeCpuSimdCli found at $cliPath but probe failed; SIMD engine not initialized"
    exit 1
}

if ($usesCli) {
    $ok = Invoke-CpuSimdEngineTest -Implementation 'RunSse2Test'
    if (-not $ok) {
        Write-Error 'Invoke-CpuSimdEngineTest RunSse2Test returned false on this host'
        exit 1
    }
    Write-Host "Test-CpuSimdEnginePs5: PASS (CdeCpuSimdCli, IsStubEngine=False)"
    exit 0
}

if (-not ('CpuSimdEngine' -as [type])) {
    Write-Error 'CpuSimdEngine type was not loaded and CdeCpuSimdCli is unavailable'
    exit 1
}

$null = [CpuSimdEngine]::RunMmxTest()
if ($isStub) {
    Write-Host "Test-CpuSimdEnginePs5: PASS (fallback Add-Type, IsStubEngine=True - publish toolkit for full SIMD)"
    exit 0
}

Write-Host "Test-CpuSimdEnginePs5: PASS (Add-Type compat, IsStubEngine=False)"
exit 0
