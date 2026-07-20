#Requires -Version 5.1
<#
.SYNOPSIS
  Merge a DriverFilterHarvest JSON into CST rules.json allowlistedFilterNames.

.PARAMETER HarvestPath
  Path to DriverFilterHarvest_*.json from Harvest-DriverFilterAllowlist.ps1

.PARAMETER RulesPath
  Optional. Defaults to Core Security Tool CST rules.json (authoritative), then toolkit mirror.

.PARAMETER AlsoSyncToolkitMirror
  Also update Toolkit\Security\CST\rules\rules.json when the authoritative CST path is used.

.PARAMETER WhatIf
  Show names that would be added without writing.
#>
param(
    [Parameter(Mandatory)][string]$HarvestPath,
    [string]$RulesPath,
    [switch]$AlsoSyncToolkitMirror,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $HarvestPath)) {
    throw "Harvest file missing: $HarvestPath"
}

$cstSourceRules = 'D:\Robert\Desktop\App Project Builds\Core Security Tool\CST\rules\rules.json'
$toolkitMirror  = 'D:\Robert\Desktop\App Project Builds\Core Diagnostic Engine\Toolkit\Security\CST\rules\rules.json'

if ([string]::IsNullOrWhiteSpace($RulesPath)) {
    if (Test-Path -LiteralPath $cstSourceRules) {
        $RulesPath = $cstSourceRules
        if (-not $PSBoundParameters.ContainsKey('AlsoSyncToolkitMirror')) {
            $AlsoSyncToolkitMirror = $true
        }
    } elseif (Test-Path -LiteralPath $toolkitMirror) {
        $RulesPath = $toolkitMirror
    } else {
        throw 'Could not locate CST rules.json'
    }
}

$harvest = Get-Content -LiteralPath $HarvestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$toMerge = @()
if ($harvest.proposedAllowlist) {
    $toMerge = @($harvest.proposedAllowlist)
} elseif ($harvest.newNames) {
    $toMerge = @($harvest.newNames)
} else {
    throw 'Harvest JSON has no proposedAllowlist/newNames'
}

$raw = Get-Content -LiteralPath $RulesPath -Raw -Encoding UTF8
$rules = $raw | ConvertFrom-Json
if (-not $rules.driverFilterPolicies) {
    throw 'rules.json missing driverFilterPolicies'
}

$current = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($n in @($rules.driverFilterPolicies.allowlistedFilterNames)) {
    if ($n) { [void]$current.Add([string]$n) }
}

$added = New-Object System.Collections.Generic.List[string]
foreach ($n in $toMerge) {
    $name = ([string]$n).Trim()
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    if ($current.Add($name)) { $added.Add($name) | Out-Null }
}

$merged = @($current | Sort-Object)
Write-Host "Rules: $RulesPath"
Write-Host "Harvest: $HarvestPath"
Write-Host "Already present: $($current.Count - $added.Count) | To add: $($added.Count)"
if ($added.Count -gt 0) {
    $added | ForEach-Object { Write-Host "  + $_" }
} else {
    Write-Host 'No new names to add.'
}

if ($WhatIf) {
    Write-Host 'WhatIf: no files written.'
    exit 0
}

if ($added.Count -eq 0) {
    exit 0
}

$rules.driverFilterPolicies.allowlistedFilterNames = $merged
$outJson = $rules | ConvertTo-Json -Depth 100
# PowerShell ConvertTo-Json can be lossy on huge rules.json — prefer surgical replace of the allowlist array.
# Surgical edit: replace the allowlistedFilterNames array block via regex on original text.
$escapedNames = ($merged | ForEach-Object {
    $s = $_ -replace '\\', '\\' -replace '"', '\"'
    '                                                                "{0}"' -f $s
}) -join ",`r`n"

$pattern = '("allowlistedFilterNames"\s*:\s*\[)[\s\S]*?(\])'
$replacement = "`$1`r`n$escapedNames`r`n                                                            `$2"
if ($raw -notmatch '"allowlistedFilterNames"\s*:') {
    throw 'Could not find allowlistedFilterNames in rules.json text'
}
$updated = [regex]::Replace($raw, $pattern, $replacement, 1)
if ($updated -eq $raw) {
    throw 'Failed to surgically update allowlistedFilterNames (regex no-op)'
}

$bak = "$RulesPath.bak_{0:yyyyMMdd_HHmmss}" -f (Get-Date)
Copy-Item -LiteralPath $RulesPath -Destination $bak -Force
Set-Content -LiteralPath $RulesPath -Value $updated -Encoding UTF8
Write-Host "Updated: $RulesPath (backup $bak)"

if ($AlsoSyncToolkitMirror -and (Test-Path -LiteralPath $toolkitMirror) -and (
        [IO.Path]::GetFullPath($RulesPath) -ne [IO.Path]::GetFullPath($toolkitMirror))) {
    $bak2 = "$toolkitMirror.bak_{0:yyyyMMdd_HHmmss}" -f (Get-Date)
    Copy-Item -LiteralPath $toolkitMirror -Destination $bak2 -Force
    # Re-read updated source and apply same surgical replace to mirror from harvest merge result
    $mirrorRaw = Get-Content -LiteralPath $toolkitMirror -Raw -Encoding UTF8
    $mirrorUpdated = [regex]::Replace($mirrorRaw, $pattern, $replacement, 1)
    if ($mirrorUpdated -eq $mirrorRaw) {
        Write-Warning 'Toolkit mirror allowlist regex no-op; copying full source rules.json instead.'
        Copy-Item -LiteralPath $RulesPath -Destination $toolkitMirror -Force
    } else {
        Set-Content -LiteralPath $toolkitMirror -Value $mirrorUpdated -Encoding UTF8
    }
    Write-Host "Synced toolkit mirror: $toolkitMirror"
}

# Keep Health Check fallback defaults in sync is optional; runtime loads rules.json.
Write-Host 'Merge complete. Re-publish/push CDE so the guest Health Check picks up the new list.'
exit 0
