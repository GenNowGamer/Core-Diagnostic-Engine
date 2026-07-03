#Requires -Version 5.1
<#
    Loads HardwareTestEngine and CpuSimdEngine (C#) for Diag & Repair hardware tests.
    On Windows PowerShell 5.1, prefers pre-published CdeCpuSimdCli.exe (.NET 8 intrinsics)
    over in-process Add-Type compile (compat/stub).
#>
$ErrorActionPreference = 'Stop'

$script:CdeCpuSimdCliPath = $null
$script:CdeCpuSimdUsesCli = $false

if (-not ('HardwareTestEngine' -as [type])) {
    $engineCs = Join-Path $PSScriptRoot 'HardwareTestEngine.cs'
    if (-not (Test-Path -LiteralPath $engineCs)) {
        throw "HardwareTestEngine.cs not found at $engineCs"
    }
    Add-Type -Path $engineCs -ErrorAction Stop
}

function Get-CdeCpuSimdCliPath {
    if ($script:CdeCpuSimdCliPath -and (Test-Path -LiteralPath $script:CdeCpuSimdCliPath)) {
        return $script:CdeCpuSimdCliPath
    }

    $candidates = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($env:TOOLKIT_ROOT)) {
        $root = $env:TOOLKIT_ROOT.TrimEnd('\')
        $candidates.Add((Join-Path $root 'CDE\ToolkitGUI\bin\Release\net8.0-windows\CdeCpuSimdCli.exe'))
        $candidates.Add((Join-Path $root 'App\ToolkitGUI\bin\Release\net8.0-windows\CdeCpuSimdCli.exe'))
    }

    $coreDir = $PSScriptRoot
    $candidates.Add((Join-Path $coreDir '..\..\CDE\ToolkitGUI\bin\Release\net8.0-windows\CdeCpuSimdCli.exe'))
    $candidates.Add((Join-Path $coreDir '..\..\App\ToolkitGUI\bin\Release\net8.0-windows\CdeCpuSimdCli.exe'))

    foreach ($rel in $candidates) {
        try {
            $full = [IO.Path]::GetFullPath($rel)
            if (Test-Path -LiteralPath $full) {
                $script:CdeCpuSimdCliPath = $full
                return $full
            }
        }
        catch { }
    }

    return $null
}

function Initialize-CdeCpuSimdCli {
    if ($script:CdeCpuSimdUsesCli) { return $true }

    $cli = Get-CdeCpuSimdCliPath
    if (-not $cli) { return $false }

    try {
        $probeJson = & $cli probe 2>$null
        if ($LASTEXITCODE -ne 0) { return $false }
        $probe = $probeJson | ConvertFrom-Json
        if ($probe.isStubEngine) { return $false }
        $script:CdeCpuSimdUsesCli = $true
        return $true
    }
    catch {
        return $false
    }
}

function Initialize-CpuSimdEngineAddType {
    if ('CpuSimdEngine' -as [type]) { return }

    $simdCs = Join-Path $PSScriptRoot 'CpuSimdEngine.cs'
    $compatCs = Join-Path $PSScriptRoot 'CpuSimdEngineCompat.cs'
    if (-not (Test-Path -LiteralPath $simdCs)) { return }

    try {
        if ($PSVersionTable.PSEdition -eq 'Core') {
            Add-Type -Path $simdCs -ErrorAction Stop
        }
        else {
            $stubCs = Join-Path $PSScriptRoot 'CpuSimdEngineStub.cs'
            try {
                $rt = [Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
                $numerics = Join-Path $rt 'System.Numerics.Vectors.dll'
                $refs = @((Join-Path $rt 'mscorlib.dll'))
                if (Test-Path -LiteralPath $numerics) { $refs += $numerics }
                Add-Type -Path $compatCs -ReferencedAssemblies $refs -ErrorAction Stop
            }
            catch {
                Add-Type -Path $stubCs -ErrorAction Stop
            }
        }
    }
    catch {
        if (Test-Path -LiteralPath $compatCs) {
            $stubCs = Join-Path $PSScriptRoot 'CpuSimdEngineStub.cs'
            try {
                $rt = [Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
                $numerics = Join-Path $rt 'System.Numerics.Vectors.dll'
                $refs = @((Join-Path $rt 'mscorlib.dll'))
                if (Test-Path -LiteralPath $numerics) { $refs += $numerics }
                Add-Type -Path $compatCs -ReferencedAssemblies $refs -ErrorAction Stop
            }
            catch {
                Add-Type -Path $stubCs -ErrorAction Stop
            }
        }
        else {
            throw
        }
    }
}

if (-not (Initialize-CdeCpuSimdCli)) {
    Initialize-CpuSimdEngineAddType
}

function Test-CpuSimdEngineIsStub {
    if ($script:CdeCpuSimdUsesCli) { return $false }
    if (-not ('CpuSimdEngine' -as [type])) { return $true }
    return [CpuSimdEngine]::IsStubEngine
}

function Invoke-CpuSimdEngineTest {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet(
            'RunMmxTest', 'RunSseTest', 'RunSse2Test', 'RunSse3Test',
            'RunSsse3Test', 'RunSse41Test', 'RunSse42Test'
        )]
        [string]$Implementation
    )

    if ($script:CdeCpuSimdUsesCli) {
        $shortName = $Implementation -replace '^Run', '' -replace 'Test$', ''
        & $script:CdeCpuSimdCliPath run $shortName | Out-Null
        return ($LASTEXITCODE -eq 0)
    }

    switch ($Implementation) {
        'RunMmxTest'   { return [CpuSimdEngine]::RunMmxTest() }
        'RunSseTest'   { return [CpuSimdEngine]::RunSseTest() }
        'RunSse2Test'  { return [CpuSimdEngine]::RunSse2Test() }
        'RunSse3Test'  { return [CpuSimdEngine]::RunSse3Test() }
        'RunSsse3Test' { return [CpuSimdEngine]::RunSsse3Test() }
        'RunSse41Test' { return [CpuSimdEngine]::RunSse41Test() }
        'RunSse42Test' { return [CpuSimdEngine]::RunSse42Test() }
        default        { return $false }
    }
}

function Initialize-HardwareTestEngineFromCatalog {
    param($ProfileParams)

    [HardwareTestEngine]::RegisterIterations = [int]$ProfileParams.registerIterations
    [HardwareTestEngine]::CacheSizeBytes = [int]$ProfileParams.cacheSizeBytes
    [HardwareTestEngine]::CachePasses = [int]$ProfileParams.cachePasses
    [HardwareTestEngine]::PrimeLimit = [int]$ProfileParams.primeLimit
    [HardwareTestEngine]::ExpectedPrimeCount = [int]$ProfileParams.expectedPrimeCount
    [HardwareTestEngine]::FpuLoops = [int]$ProfileParams.fpuLoops
    [HardwareTestEngine]::MemoryPatternPasses = [int]$ProfileParams.memoryPatternPasses
    [HardwareTestEngine]::MemoryBlockCount = [int]$ProfileParams.memoryBlockCount
    if ($ProfileParams.movingInversionPatterns) {
        $patterns = @($ProfileParams.movingInversionPatterns | ForEach-Object { [byte]$_ })
        [HardwareTestEngine]::SetMovingInversionPatterns($patterns)
    }
}
