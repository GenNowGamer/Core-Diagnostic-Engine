#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$testsRoot = Split-Path $MyInvocation.MyCommand.Path
$coreDir = Join-Path $testsRoot '..\Core'
. (Join-Path $coreDir 'HealthFindings.ps1')
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

# Benign per-user service timeouts (e.g. GameDVR) downgrade to Info/ExpectedLimitation
$benignEvents = @(
    [PSCustomObject]@{
        LogName = 'System'; Source = 'Service Control Manager'; EventId = 7009
        TimeCreated = (Get-Date); Message = 'A timeout was reached (90000 milliseconds) while waiting for the GameDVR and Broadcast User Service_1b9577 service to connect.'
    },
    [PSCustomObject]@{
        LogName = 'System'; Source = 'Service Control Manager'; EventId = 7000
        TimeCreated = (Get-Date); Message = 'The GameDVR and Broadcast User Service_1b9577 service failed to start due to the following error: The service did not respond to the start or control request in a timely fashion.'
    }
)
$benignFindings = @(Invoke-EventFindingClustering -CheckId 'event_logs_24h' -Events $benignEvents)
$benignCluster = @($benignFindings | Where-Object { $_.findingId -eq 'event.service_startup_failure' })[0]
Assert-True -Name 'Benign per-user service timeout downgraded to Info' -Condition (
    $null -ne $benignCluster -and
    $benignCluster.status -eq 'Info' -and
    $benignCluster.severity -eq 'Info' -and
    $benignCluster.classification -eq 'ExpectedLimitation'
)
$benignWarnResiduals = @($benignFindings | Where-Object { $_.status -eq 'Warn' })
Assert-True -Name 'Benign per-user service timeout emits no Warn residual' -Condition ($benignWarnResiduals.Count -eq 0)

# Critical service failure (e.g. wuauserv) stays Warn/Medium/SingleSignal
$realEvents = @(
    [PSCustomObject]@{
        LogName = 'System'; Source = 'Service Control Manager'; EventId = 7009
        TimeCreated = (Get-Date); Message = 'A timeout was reached (30000 milliseconds) while waiting for the Windows Update (wuauserv) service to connect.'
    },
    [PSCustomObject]@{
        LogName = 'System'; Source = 'Service Control Manager'; EventId = 7000
        TimeCreated = (Get-Date); Message = 'The Windows Update (wuauserv) service failed to start due to the following error: Access is denied.'
    }
)
$realFindings = @(Invoke-EventFindingClustering -CheckId 'event_logs_24h' -Events $realEvents)
$realCluster = @($realFindings | Where-Object { $_.findingId -eq 'event.service_startup_failure' })[0]
Assert-True -Name 'Real service failure remains Warn/Medium/SingleSignal' -Condition (
    $null -ne $realCluster -and
    $realCluster.status -eq 'Warn' -and
    $realCluster.severity -eq 'Medium' -and
    $realCluster.classification -eq 'SingleSignal'
)

if ($failures.Count -gt 0) {
    Write-Host "Test-EventSuppressorPacks: FAIL ($($failures.Count))"
    foreach ($f in $failures) { Write-Host "  - $f" }
    exit 1
}

Write-Host "Test-EventSuppressorPacks: PASS ($passed assertions)"
exit 0
