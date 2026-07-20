#Requires -Version 5.1
<#
.SYNOPSIS
  Harvest minifilter and class-filter names from a clean Windows machine for allowlist growth.

.DESCRIPTION
  Run on a clean reference VM (e.g. w11-infect-lab baseline) before infection injects.
  Writes JSON under Logs\ (or -OutputPath) with proposedAllowlist for host-side merge.

.PARAMETER OutputPath
  Optional explicit JSON path. Default: {TOOLKIT_ROOT}\Logs\DriverFilterHarvest_{timestamp}.json

.PARAMETER AlsoWriteDesktop
  Also copy the JSON to the Public Desktop for easy host Copy-VMFile pickup.
#>
param(
    [string]$OutputPath,
    [switch]$AlsoWriteDesktop
)

$ErrorActionPreference = 'Stop'

function Get-HarvestToolkitRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:TOOLKIT_ROOT) -and (Test-Path -LiteralPath $env:TOOLKIT_ROOT)) {
        return $env:TOOLKIT_ROOT.TrimEnd('\', '/')
    }
    $here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $MyInvocation.MyCommand.Path }
    return (Split-Path (Split-Path $here -Parent) -Parent)
}

function Get-FltmcFilterNames {
    $names = New-Object System.Collections.Generic.List[string]
    try {
        $raw = & fltmc.exe filters 2>&1 | Out-String
        foreach ($line in ($raw -split "`r?`n")) {
            if ($line -match '^\s*Filter\s+Name' -or $line -match '^-{3,}' -or [string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line -match '^\s*(\S+)\s+\d+') {
                $names.Add($Matches[1]) | Out-Null
            }
        }
    } catch { }
    return [string[]]$names.ToArray()
}

$toolkitRoot = Get-HarvestToolkitRoot
$coreHelper = Join-Path $toolkitRoot 'Scripts\Core\DriverFilterAllowlist.ps1'
if (Test-Path -LiteralPath $coreHelper) {
    . $coreHelper
}

$classDefs = @(
    @{ Id = 'DiskDrive'; Guid = '{4d36e967-e325-11ce-bfc1-08002be10318}' }
    @{ Id = 'CDROM';     Guid = '{4d36e96a-e325-11ce-bfc1-08002be10318}' }
    @{ Id = 'Volume';    Guid = '{71a27cdd-812a-11d0-bec7-08002be2092f}' }
)

$minifilters = @(Get-FltmcFilterNames | Sort-Object -Unique)
$classFilters = New-Object System.Collections.Generic.List[object]
$classNames = New-Object System.Collections.Generic.List[string]

foreach ($cdef in $classDefs) {
    $key = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$($cdef.Guid)"
    if (-not (Test-Path -LiteralPath $key)) { continue }
    try {
        $item = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        foreach ($propName in @('UpperFilters', 'LowerFilters')) {
            if (-not $item.PSObject.Properties[$propName]) { continue }
            $vals = @($item.$propName | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
            foreach ($v in $vals) {
                $classNames.Add([string]$v) | Out-Null
            }
            $classFilters.Add([PSCustomObject]@{
                Class     = $cdef.Id
                ClassGuid = $cdef.Guid
                Property  = $propName
                Names     = @($vals)
                Key       = $key
            }) | Out-Null
        }
    } catch { }
}

$proposed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($n in $minifilters) { if ($n) { [void]$proposed.Add($n) } }
foreach ($n in $classNames) { if ($n) { [void]$proposed.Add(([string]$n).Trim()) } }

$existing = @()
$existingSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
if (Get-Command Get-CdeDriverFilterAllowlistNames -ErrorAction SilentlyContinue) {
    $existing = @(Get-CdeDriverFilterAllowlistNames)
    foreach ($n in $existing) {
        if ($n) {
            [void]$proposed.Add($n)
            [void]$existingSet.Add($n)
        }
    }
}

$newOnly = @($proposed | ForEach-Object { [string]$_ } | Where-Object { -not $existingSet.Contains($_) } | Sort-Object)

$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $logsDir = Join-Path $toolkitRoot 'Logs'
    if (-not (Test-Path -LiteralPath $logsDir)) {
        New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    }
    $OutputPath = Join-Path $logsDir ("DriverFilterHarvest_{0}.json" -f $timestamp)
}

# PS 5.1: avoid Generic.List / HashSet values inside [ordered] hashtables (Argument types do not match).
$payload = @{
    schema            = 'cde.driverFilterHarvest.v1'
    harvestedAtUtc    = [DateTime]::UtcNow.ToString('o')
    computerName      = [string]$env:COMPUTERNAME
    osCaption         = if ($os) { [string]$os.Caption } else { '' }
    osBuild           = if ($os) { [string]$os.BuildNumber } else { '' }
    toolkitRoot       = [string]$toolkitRoot
    minifilters       = @($minifilters | ForEach-Object { [string]$_ })
    classFilters      = @($classFilters.ToArray())
    existingAllowlist = @($existing | ForEach-Object { [string]$_ } | Sort-Object)
    proposedAllowlist = @($proposed | ForEach-Object { [string]$_ } | Sort-Object)
    newNames          = @($newOnly)
    notes             = @(
        'Harvest from a clean baseline VM before BenchLab infection injects.',
        'Merge on host with Scripts\Tools\Merge-DriverFilterAllowlist.ps1',
        'Prefer Microsoft-signed stock filters; review third-party names before merging.'
    )
}

$json = $payload | ConvertTo-Json -Depth 6
Set-Content -LiteralPath $OutputPath -Value $json -Encoding UTF8

$desktopCopy = $null
if ($AlsoWriteDesktop) {
    $desktopCopy = Join-Path $env:PUBLIC ("Desktop\DriverFilterHarvest_{0}.json" -f $timestamp)
    Copy-Item -LiteralPath $OutputPath -Destination $desktopCopy -Force
}

Write-Host "Harvested $($minifilters.Count) minifilters; $($classNames.Count) class-filter values."
Write-Host "Proposed allowlist size: $($proposed.Count) (new vs current: $($newOnly.Count))"
Write-Host "Wrote: $OutputPath"
if ($desktopCopy) { Write-Host "Desktop copy: $desktopCopy" }
if ($newOnly.Count -gt 0) {
    Write-Host 'New names:'
    $newOnly | ForEach-Object { Write-Host "  $_" }
}

Write-Output $OutputPath
exit 0
