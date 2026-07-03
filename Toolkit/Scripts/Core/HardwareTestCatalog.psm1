#Requires -Version 5.1

$script:HardwareCatalogPath = $null
$script:HardwareCatalogCache = $null

function Get-HardwareTestCatalogPath {
    if ($script:HardwareCatalogPath -and (Test-Path -LiteralPath $script:HardwareCatalogPath)) {
        return $script:HardwareCatalogPath
    }

    $candidates = @(
        (Join-Path $PSScriptRoot '..\..\Config\HardwareTestCatalog.json'),
        (Join-Path $PSScriptRoot '..\..\..\Config\HardwareTestCatalog.json')
    )

    foreach ($rel in $candidates) {
        $full = [IO.Path]::GetFullPath($rel)
        if (Test-Path -LiteralPath $full) {
            $script:HardwareCatalogPath = $full
            return $full
        }
    }

    throw 'HardwareTestCatalog.json not found. Run Sync-HardwareTestCatalog.ps1 or Publish-ToolkitGUI.ps1.'
}

function Get-HardwareTestCatalog {
    $path = Get-HardwareTestCatalogPath
    if ($script:HardwareCatalogCache -and $script:HardwareCatalogCache._path -eq $path) {
        return $script:HardwareCatalogCache.data
    }

    $data = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $script:HardwareCatalogCache = @{ _path = $path; data = $data }
    return $data
}

function Get-HardwareTestProfileParameters {
    param(
        [ValidateSet('Quick', 'Extended')]
        [string]$Profile = 'Quick'
    )

    $catalog = Get-HardwareTestCatalog
    $key = if ($Profile -eq 'Extended') { 'extended' } else { 'quick' }
    $props = $catalog.profiles.$key
    if (-not $props) {
        throw "Profile '$Profile' not defined in hardware test catalog."
    }
    return $props
}

function Get-HardwareTestsForCategory {
    param(
        [ValidateSet('CPU', 'Memory', 'HardDrive')]
        [string]$Category,
        [ValidateSet('Quick', 'Extended')]
        [string]$Profile = 'Quick'
    )

    $catalog = Get-HardwareTestCatalog
    $profileKey = if ($Profile -eq 'Extended') { 'extended' } else { 'quick' }

    @($catalog.tests | Where-Object {
        $_.category -eq $Category -and $_.profiles.$profileKey -eq $true
    } | Sort-Object { [int]$_.order })
}

function Get-HardwareTestDisplayNames {
    param(
        [ValidateSet('CPU', 'Memory', 'HardDrive')]
        [string]$Category,
        [ValidateSet('Quick', 'Extended')]
        [string]$Profile = 'Quick'
    )

    @(Get-HardwareTestsForCategory -Category $Category -Profile $Profile | ForEach-Object { $_.displayName })
}

function Get-HardwareTestCountByCategory {
  param(
    [ValidateSet('Quick', 'Extended')]
    [string]$Profile = 'Quick'
  )

  @{
    CPU       = (Get-HardwareTestsForCategory -Category CPU -Profile $Profile).Count
    Memory    = (Get-HardwareTestsForCategory -Category Memory -Profile $Profile).Count
    HardDrive = (Get-HardwareTestsForCategory -Category HardDrive -Profile $Profile).Count
  }
}

Export-ModuleMember -Function @(
    'Get-HardwareTestCatalogPath',
    'Get-HardwareTestCatalog',
    'Get-HardwareTestProfileParameters',
    'Get-HardwareTestsForCategory',
    'Get-HardwareTestDisplayNames',
    'Get-HardwareTestCountByCategory'
)
