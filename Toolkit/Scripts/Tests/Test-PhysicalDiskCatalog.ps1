#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$coreDir = Join-Path (Split-Path $MyInvocation.MyCommand.Path) '..\Core'
Import-Module (Join-Path $coreDir 'PhysicalDiskCatalog.psm1') -Force -DisableNameChecking

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        Write-Error "FAIL: $Message"
        exit 1
    }
}

# Removable media by WMI MediaType
Assert-True (Test-CdeIsRemovableMediaDisk -MediaType 'Removable media') `
    'MediaType "Removable media" should be excluded'
Assert-True (Test-CdeIsRemovableMediaDisk -MediaType 'Removable Media') `
    'MediaType "Removable Media" should be excluded (case-insensitive)'

# Fixed internal / USB HDD heuristic
Assert-True (-not (Test-CdeIsRemovableMediaDisk -MediaType 'Fixed hard disk media')) `
    'MediaType "Fixed hard disk media" should not be excluded'
Assert-True (-not (Test-CdeIsRemovableMediaDisk -MediaType 'Fixed hard disk media' -IsRemovableFromStorage $false)) `
    'Fixed media with IsRemovable=false should not be excluded'

# Storage IsRemovable without MediaType hint
Assert-True (Test-CdeIsRemovableMediaDisk -MediaType '' -IsRemovableFromStorage $true) `
    'IsRemovable=true should exclude even without MediaType'

# Empty / unknown fixed
Assert-True (-not (Test-CdeIsRemovableMediaDisk -MediaType '' -IsRemovableFromStorage $false)) `
    'Empty MediaType and IsRemovable=false should not be excluded'
Assert-True (-not (Test-CdeIsRemovableMediaDisk -MediaType 'Unknown')) `
    'Unknown MediaType should not be excluded'

Write-Host 'Test-PhysicalDiskCatalog: PASS'
exit 0
