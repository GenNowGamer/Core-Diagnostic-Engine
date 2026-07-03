#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$testsRoot = Split-Path $MyInvocation.MyCommand.Path
$coreDir = Join-Path $testsRoot '..\Core'
Import-Module (Join-Path $coreDir 'Toolkit.Core.psm1') -Force -DisableNameChecking
. (Join-Path $coreDir 'HealthChecks.ps1')

function Test-HealthStepOutput {
    param(
        [string]$Name,
        [scriptblock]$InvokeCheck,
        [string[]]$RequiredFragments
    )

    $workflow = [PSCustomObject]@{ Steps = [System.Collections.ArrayList]@() }
    & $InvokeCheck $workflow
    $step = $workflow.Steps | Select-Object -Last 1
    if (-not $step) {
        Write-Error "$Name produced no step."
        exit 1
    }

    $output = [string]$step.Output
    if ([string]::IsNullOrWhiteSpace($output)) {
        Write-Error "$Name step has empty Output."
        exit 1
    }

    if ($output.Length -lt 80) {
        Write-Error "$Name Output too short ($($output.Length) chars)."
        exit 1
    }

    foreach ($fragment in $RequiredFragments) {
        if ($output -notmatch [regex]::Escape($fragment)) {
            Write-Error "$Name Output missing expected fragment: $fragment"
            exit 1
        }
    }

    Write-Host "  PASS: $Name ($($output.Length) chars)"
}

Write-Host 'Test-HealthCheckOutputDetail'

Test-HealthStepOutput -Name 'network_adapters' -InvokeCheck {
    param($r)
    Invoke-HealthCheck_network_adapters $r
} -RequiredFragments @('NETWORK ADAPTERS', 'Description', 'MAC Address')

Test-HealthStepOutput -Name 'gpu_info' -InvokeCheck {
    param($r)
    Invoke-HealthCheck_gpu_info $r
} -RequiredFragments @('GRAPHICS ADAPTERS', 'Driver Version')

Test-HealthStepOutput -Name 'os_version' -InvokeCheck {
    param($r)
    Invoke-HealthCheck_os_version $r
} -RequiredFragments @('OPERATING SYSTEM', 'Build')

Write-Host 'Test-HealthCheckOutputDetail: PASS'
exit 0
