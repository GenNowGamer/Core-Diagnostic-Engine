#Requires -Version 5.1
<#
.SYNOPSIS
    Shared physical-disk policy for CDE hardware storage testing and SMART.
    Excludes removable media (USB flash, memory cards, boot toolkit USB).
#>

function Test-CdeIsRemovableMediaDisk {
    [CmdletBinding()]
    param(
        [string]$MediaType = '',
        [bool]$IsRemovableFromStorage = $false,
        $DiskObject = $null
    )

    if ($null -ne $DiskObject) {
        $MediaType = [string]$DiskObject.MediaType
        $index = if ($null -ne $DiskObject.Index) { [int]$DiskObject.Index } else { -1 }
        if ($index -ge 0 -and $script:CdeRemovableMap -and $script:CdeRemovableMap.ContainsKey($index)) {
            $IsRemovableFromStorage = [bool]$script:CdeRemovableMap[$index]
        }
    }

    if ($IsRemovableFromStorage) { return $true }
    if (-not [string]::IsNullOrWhiteSpace($MediaType) -and
        $MediaType.IndexOf('Removable', [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        return $true
    }
    return $false
}

function Get-CdeAllPhysicalDisks {
    $disks = @()
    try {
        $disks = @(Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue | Sort-Object { [int]$_.Index })
    } catch {}
    if ($disks.Count -eq 0) {
        try {
            $disks = @(Get-WmiObject Win32_DiskDrive -ErrorAction SilentlyContinue | Sort-Object { [int]$_.Index })
        } catch {}
    }
    return $disks
}

function Get-CdeRemovableMediaDiskMap {
    $map = @{}
    if (-not (Get-Command Get-Disk -ErrorAction SilentlyContinue)) {
        return $map
    }
    try {
        foreach ($disk in @(Get-Disk -ErrorAction SilentlyContinue)) {
            if ($null -eq $disk) { continue }
            $num = [int]$disk.Number
            if ($disk.IsRemovable) {
                $map[$num] = $true
            }
        }
    } catch {}
    return $map
}

function Get-CdeTestablePhysicalDisks {
    [CmdletBinding()]
    param()

    $script:CdeRemovableMap = Get-CdeRemovableMediaDiskMap
    $testable = @()

    foreach ($disk in (Get-CdeAllPhysicalDisks)) {
        if (Test-CdeIsRemovableMediaDisk -DiskObject $disk) {
            $model = if ($disk.Model) { [string]$disk.Model.Trim() } else { 'Unknown' }
            $idx = if ($null -ne $disk.Index) { [int]$disk.Index } else { -1 }
            Write-Verbose ("Excluded removable media: Drive {0} ({1})" -f $idx, $model)
            continue
        }
        $testable += $disk
    }

    $script:CdeRemovableMap = $null
    return $testable
}

function Get-CdeTestablePhysicalDiskIndices {
    @((Get-CdeTestablePhysicalDisks | ForEach-Object { [int]$_.Index }))
}

Export-ModuleMember -Function @(
    'Test-CdeIsRemovableMediaDisk'
    'Get-CdeAllPhysicalDisks'
    'Get-CdeRemovableMediaDiskMap'
    'Get-CdeTestablePhysicalDisks'
    'Get-CdeTestablePhysicalDiskIndices'
)
