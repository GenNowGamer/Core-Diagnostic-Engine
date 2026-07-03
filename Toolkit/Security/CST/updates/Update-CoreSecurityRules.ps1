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
if (-not $sourceJson.rulesVersion) {
    throw 'Invalid rules format. Expected rulesVersion.'
}

if (-not $sourceJson.hashes -or -not $sourceJson.yaraLikeRules -or -not $sourceJson.signerPolicies -or -not $sourceJson.heuristicThresholds -or -not $sourceJson.correlationRules) {
    throw 'Invalid rules format. Expected sectioned schema: hashes, yaraLikeRules, signerPolicies, heuristicThresholds, correlationRules.'
}

if (-not $sourceJson.patterns) {
    throw 'Invalid rules format. Expected patterns during transition compatibility window.'
}

$destDir = Split-Path $DestinationPath -Parent
if (-not (Test-Path $destDir)) {
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
}

Copy-Item -Path $SourcePath -Destination $DestinationPath -Force
Write-Output "Rules updated to version $($sourceJson.rulesVersion): $DestinationPath"