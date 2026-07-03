#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$CoreDir = Join-Path $PSScriptRoot '..\Core'
Import-Module (Join-Path $CoreDir 'Toolkit.Elevation.psm1') -Force -DisableNameChecking

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-False {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { throw $Message }
}

$parts = [System.Collections.Generic.List[string]]::new()
Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'ToolName' -Value "Repair'Selected"
Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'ElevatedRelay' -IsSwitch
Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'Empty' -Value ''
$joined = Join-ToolkitRelayArgumentString -Parts $parts

Assert-True ($joined -match "-ToolName 'Repair''Selected'") 'Single quotes in values should be escaped'
Assert-True ($joined -match '-ElevatedRelay') 'Switch arguments should be emitted'
Assert-True ($joined -notmatch "-Empty") 'Empty values should be omitted'

Assert-True (Test-ToolkitShouldRelayElevation) 'Non-elevated session should relay by default'
Assert-False (Test-ToolkitShouldRelayElevation -ElevatedRelay) 'Elevated relay child should not relay again'

Write-Output 'Test-ToolkitElevation: PASS'
