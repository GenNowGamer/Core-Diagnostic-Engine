#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$testsRoot = Split-Path $MyInvocation.MyCommand.Path
$coreDir = Join-Path $testsRoot '..\Core'
Import-Module (Join-Path $coreDir 'HardwareTestCatalog.psm1') -Force

$catalog = Get-HardwareTestCatalog
$counts = Get-HardwareTestCountByCategory -Profile Quick

if ([int]$catalog.version -lt 1) {
    Write-Error 'Catalog version must be >= 1.'
    exit 1
}

if ($counts.CPU -ne 12 -or $counts.Memory -ne 10 -or $counts.HardDrive -ne 6) {
    Write-Error "Unexpected sub-test counts: CPU=$($counts.CPU) Memory=$($counts.Memory) HardDrive=$($counts.HardDrive) (expected 12/10/6)."
    exit 1
}

$chuCandidates = @(
    [IO.Path]::GetFullPath((Join-Path $testsRoot '..\..\..\..\Core Hardware Utility\Core_Hardware_Utility.json')),
    [IO.Path]::GetFullPath((Join-Path $testsRoot '..\..\..\Core Hardware Utility\Core_Hardware_Utility.json'))
)
$chuPath = $chuCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $chuPath) {
    Write-Error 'CHU Core_Hardware_Utility.json not found for version parity check.'
    exit 1
}

$chuRoot = Get-Content -LiteralPath $chuPath -Raw | ConvertFrom-Json
$chuCatalog = $chuRoot.hardwareTestCatalog
if ([int]$chuCatalog.version -ne [int]$catalog.version) {
    Write-Error "Catalog version mismatch: CDE=$($catalog.version) CHU=$($chuCatalog.version). Re-run Sync-HardwareTestCatalog.ps1."
    exit 1
}

$cdeTests = @($catalog.tests)
$chuTests = @($chuCatalog.tests)

$cdeIds = @($cdeTests | ForEach-Object { [string]$_.id })
$chuIds = @($chuTests | ForEach-Object { [string]$_.id })

$missingInCde = @($chuIds | Where-Object { $_ -notin $cdeIds })
if ($missingInCde.Count -gt 0) {
    Write-Error "CHU test ids missing from CDE catalog: $($missingInCde -join ', ')"
    exit 1
}

$missingInChu = @($cdeIds | Where-Object { $_ -notin $chuIds })
if ($missingInChu.Count -gt 0) {
    Write-Error "CDE test ids missing from CHU catalog: $($missingInChu -join ', ')"
    exit 1
}

$chuById = @{}
foreach ($t in $chuTests) { $chuById[[string]$t.id] = $t }

foreach ($cde in $cdeTests) {
    $id = [string]$cde.id
    $chu = $chuById[$id]
    if (-not $chu) {
        Write-Error "Missing CHU entry for id '$id'."
        exit 1
    }

    if ([string]$cde.category -ne [string]$chu.category) {
        Write-Error "Category mismatch for '$id': CDE=$($cde.category) CHU=$($chu.category)"
        exit 1
    }

    $cdeQuick = [bool]$cde.profiles.quick
    $chuQuick = [bool]$chu.profiles.quick
    $cdeExt = [bool]$cde.profiles.extended
    $chuExt = [bool]$chu.profiles.extended
    if ($cdeQuick -ne $chuQuick -or $cdeExt -ne $chuExt) {
        Write-Error "Profile membership mismatch for '$id'."
        exit 1
    }

    $cdeUefi = [string]$cde.implementations.uefi
    $chuUefi = [string]$chu.implementations.uefi
    if ($cdeUefi -ne $chuUefi) {
        Write-Error "UEFI implementation mismatch for '$id': CDE=$cdeUefi CHU=$chuUefi"
        exit 1
    }
}

foreach ($category in @('CPU', 'Memory', 'HardDrive')) {
    $cdeOrder = @($cdeTests | Where-Object { [string]$_.category -eq $category } | Sort-Object { [int]$_.order } | ForEach-Object { [string]$_.id })
    $chuOrder = @($chuTests | Where-Object { [string]$_.category -eq $category } | Sort-Object { [int]$_.order } | ForEach-Object { [string]$_.id })
    if (($cdeOrder -join '|') -ne ($chuOrder -join '|')) {
        Write-Error "Relative order mismatch in category '$category'."
        exit 1
    }
}

Write-Host "Test-HardwareTestCatalogSync: PASS (version=$($catalog.version), ids=$($cdeIds.Count), CPU/Memory/Drive=$($counts.CPU)/$($counts.Memory)/$($counts.HardDrive))"
exit 0
