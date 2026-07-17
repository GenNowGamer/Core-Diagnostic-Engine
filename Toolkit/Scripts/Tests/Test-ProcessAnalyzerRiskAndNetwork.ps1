#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$testsRoot = Split-Path $MyInvocation.MyCommand.Path
$coreDir = Join-Path $testsRoot '..\Core'
. (Join-Path $coreDir 'ProcessAnalyzer.Core.ps1')

function Assert-True {
    param([string]$Name, [bool]$Condition)
    if (-not $Condition) {
        Write-Error "FAIL: $Name"
        exit 1
    }
    Write-Host "  PASS: $Name"
}

$miner = Get-ProcessRiskInfo -Name 'miner.exe' -FilePath 'C:\Users\Bob\AppData\Local\Temp\miner.exe' `
    -CommandLine 'miner.exe --cuda stratum+tcp://pool.example:3333' -IsSigned $false -CpuPercent 80 -RamMB 200 -Status 'Running'
Assert-True -Name 'Miner cmdline flag' -Condition ($miner.Flags -match 'miner_cmdline')
Assert-True -Name 'Miner high cpu flag' -Condition ($miner.Flags -match 'high_cpu')

$cred = Get-ProcessRiskInfo -Name 'stealer.exe' -FilePath 'C:\Temp\stealer.exe' `
    -CommandLine 'stealer.exe "Login Data"' -IsSigned $false -CpuPercent 1 -RamMB 10 -Status 'Running'
Assert-True -Name 'Credential store touch flag' -Condition ($cred.Flags -match 'credential_store_touch')

$inject = Get-ProcessRiskInfo -Name 'tool.exe' -FilePath 'C:\Temp\tool.exe' `
    -CommandLine 'tool.exe CreateRemoteThread' -IsSigned $false -CpuPercent 1 -RamMB 10 -Status 'Running'
Assert-True -Name 'Injection API cmdline flag' -Condition ($inject.Flags -match 'injection_api_cmdline')

$snap = @(Get-ProcessNetworkSnapshot -MaxRows 5)
Assert-True -Name 'Network snapshot returns array' -Condition ($null -ne $snap)

Write-Host 'All ProcessAnalyzer risk/network tests passed.'
