#Requires -Version 5.1
<#
.SYNOPSIS
    Contract tests for DiskLayout.psm1 JSON output.
#>

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path (Split-Path $MyInvocation.MyCommand.Path) '..\Core\DiskLayout.psm1'
Import-Module $modulePath -Force

$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0

function Assert-True {
    param(
        [string]$Name,
        [bool]$Condition,
        [string]$Detail = ''
    )

    if ($Condition) {
        $script:passed++
        Write-Host "PASS: $Name"
        return
    }

    $message = $Name
    if (-not [string]::IsNullOrWhiteSpace($Detail)) {
        $message = "$Name :: $Detail"
    }

    $failures.Add($message) | Out-Null
    Write-Host "FAIL: $message" -ForegroundColor Red
}

if (-not (Get-Command Get-Disk -ErrorAction SilentlyContinue)) {
    Write-Host "SKIP: Get-Disk unavailable (WinPE-StorageWMI not installed on this host)." -ForegroundColor Yellow
    exit 0
}

$json = Export-CdeDiskLayoutJson
Assert-True -Name 'JSON is non-empty' -Condition (-not [string]::IsNullOrWhiteSpace($json))

$obj = $null
try {
    $obj = $json | ConvertFrom-Json
} catch {
    Assert-True -Name 'JSON parses' -Condition $false -Detail $_.Exception.Message
}

if ($null -ne $obj) {
    Assert-True -Name 'schemaVersion present' -Condition ($obj.PSObject.Properties['SchemaVersion'] -or $obj.PSObject.Properties['schemaVersion'])
    Assert-True -Name 'disks array present' -Condition ($null -ne $obj.Disks -or $null -ne $obj.disks)
}

Write-Host "`n--- SUMMARY ---" -ForegroundColor Cyan
Write-Host "Passed: $passed"
Write-Host "Failed: $($failures.Count)"
if ($failures.Count -gt 0) {
    foreach ($failure in $failures) {
        Write-Host "  $failure" -ForegroundColor Red
    }
    exit 1
}

exit 0
