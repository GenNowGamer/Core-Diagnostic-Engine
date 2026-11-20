#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$SourcePath,
    [string]$DestinationPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'rules\rules.json')
)

if (-not (Test-Path $SourcePath)) {
    throw "Source rules file not found: $SourcePath"
}

$sourceJson = Get-Content -Path $SourcePath -Raw | ConvertFrom-Json
$RequiredSections = @(
    'rulesVersion', 'hashes', 'yaraLikeRules', 'signerPolicies',
    'heuristicThresholds', 'correlationRules', 'bootPolicies', 'bootFilePolicies',
    'bcdPolicies', 'sectorPolicies', 'defenderExclusionPolicies',
    'ransomwareTamperPolicies', 'driverFilterPolicies', 'patterns',
    'onlineReputation', 'knownGoodPolicy', 'pathExclusions'
)

$missingSections = @($RequiredSections | Where-Object { -not $sourceJson.PSObject.Properties[$_] -or $null -eq $sourceJson.$_ })
if ($missingSections.Count -gt 0) {
    throw ("Invalid rules format. Missing required configuration section(s): {0}" -f ($missingSections -join ', '))
}

$destDir = Split-Path $DestinationPath -Parent
if (-not (Test-Path $destDir)) {
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
}

Copy-Item -Path $SourcePath -Destination $DestinationPath -Force
Write-Output "Rules updated to version $($sourceJson.rulesVersion): $DestinationPath"