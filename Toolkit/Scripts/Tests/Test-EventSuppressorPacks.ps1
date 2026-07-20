#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$testsRoot = Split-Path $MyInvocation.MyCommand.Path
$coreDir = Join-Path $testsRoot '..\Core'
. (Join-Path $coreDir 'EventFindingClusters.ps1')

$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0

function Assert-True([string]$Name, [bool]$Condition) {
    if ($Condition) { $script:passed++; Write-Host "PASS: $Name"; return }
    $script:failures.Add($Name) | Out-Null
    Write-Host "FAIL: $Name"
}

Write-Host 'Test-EventSuppressorPacks'

$env:CDE_EVENT_SUPPRESSOR_PACKS = 'dock_usb'
$catalog = Get-EventFindingClustersCatalog
Assert-True -Name 'Applied packs recorded' -Condition (@($catalog.AppliedSuppressorPacks) -contains 'dock_usb')

$disk = @($catalog.clusters | Where-Object { $_.clusterId -eq 'disk_instability' })[0]
Assert-True -Name 'disk_instability cluster found' -Condition ($null -ne $disk)
$providers = @($disk.suppressors | ForEach-Object { [string]$_.providerContains })
Assert-True -Name 'USBSTOR suppressor merged' -Condition ([bool]($providers | Where-Object { $_ -match 'USBSTOR' }))

# Forced empty packs list via merge helper
$rawPath = Get-EventFindingClustersCatalogPath
$raw = Get-Content -LiteralPath $rawPath -Raw -Encoding UTF8 | ConvertFrom-Json
$mergedNone = Merge-EventSuppressorPacksIntoCatalog -Catalog $raw -PackIds @()
# PackIds empty triggers auto-detect — force none by passing a non-existent pack
$mergedFake = Merge-EventSuppressorPacksIntoCatalog -Catalog (
    Get-Content -LiteralPath $rawPath -Raw -Encoding UTF8 | ConvertFrom-Json
) -PackIds @('does_not_exist')
Assert-True -Name 'Missing pack is no-op' -Condition (
    $null -eq $mergedFake.AppliedSuppressorPacks -or @($mergedFake.AppliedSuppressorPacks).Count -eq 0
)

Remove-Item Env:\CDE_EVENT_SUPPRESSOR_PACKS -ErrorAction SilentlyContinue

if ($failures.Count -gt 0) {
    Write-Host "Test-EventSuppressorPacks: FAIL ($($failures.Count))"
    foreach ($f in $failures) { Write-Host "  - $f" }
    exit 1
}

Write-Host "Test-EventSuppressorPacks: PASS ($passed assertions)"
exit 0
