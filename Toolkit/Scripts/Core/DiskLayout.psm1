#Requires -Version 5.1
<#
.SYNOPSIS
    Disk layout enumeration for CDE Disk & Boot Repair UI (read-only).
.NOTES
    Requires WinPE-StorageWMI (Get-Disk / Get-Partition) in WinPE, or full Windows Storage module.
#>

$bootCommon = Join-Path $PSScriptRoot '..\Workflows\Bootloader.Common.ps1'
if (Test-Path -LiteralPath $bootCommon -PathType Leaf) {
    . $bootCommon
}

function Get-CdeDiskLayout {
    [CmdletBinding()]
    param()

    if (-not (Get-Command Get-Disk -ErrorAction SilentlyContinue)) {
        throw 'Get-Disk is not available. Install WinPE-StorageWMI in boot.wim or run on full Windows with the Storage module.'
    }

    $disks = @()
    $allDisks = @(Get-Disk -ErrorAction Stop | Sort-Object Number)

    $bootTargets = @()
    $efiVolumes = @()
    try {
        if (Get-Command Get-BootloaderTargets -ErrorAction SilentlyContinue) {
            $bootTargets = @(Get-BootloaderTargets)
        }
    } catch {
        # No Windows installs mounted - map still useful.
    }

    try {
        if (Get-Command Get-EfiSystemVolumes -ErrorAction SilentlyContinue) {
            $efiVolumes = @(Get-EfiSystemVolumes)
        }
    } catch { }

    foreach ($disk in $allDisks) {
        $parts = @()
        $partitionObjects = @(Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue |
            Sort-Object PartitionNumber)

        foreach ($part in $partitionObjects) {
            $letter = if ($part.DriveLetter) { [string]$part.DriveLetter } else { '' }
            $driveRoot = if ($letter) { "${letter}:" } else { '' }

            $install = $null
            if ($driveRoot) {
                $install = @($bootTargets | Where-Object { $_.DriveRoot -eq $driveRoot } | Select-Object -First 1)[0]
            }

            $parts += [PSCustomObject]@{
                PartitionNumber = [int]$part.PartitionNumber
                DriveLetter     = $letter
                DriveRoot       = $driveRoot
                Size            = [long]$part.Size
                Type            = [string]$part.Type
                IsSystem        = [bool]$part.IsSystem
                IsBoot          = [bool]$part.IsBoot
                IsHidden        = [bool]$part.IsHidden
                GptType         = if ($part.GptType) { $part.GptType.ToString() } else { '' }
                HasWindows      = ($null -ne $install)
                WindowsDir      = if ($install) { $install.WindowsDir } else { '' }
                EfiBcdPath      = if ($install) { $install.EfiBcdPath } else { '' }
                BiosBcdPath     = if ($install) { $install.BiosBcdPath } else { '' }
                BootScore       = if ($install) { [int]$install.Score } else { 0 }
            }
        }

        $disks += [PSCustomObject]@{
            DiskNumber      = [int]$disk.Number
            FriendlyName    = [string]$disk.FriendlyName
            SerialNumber    = [string]$disk.SerialNumber
            Size            = [long]$disk.Size
            PartitionStyle  = [string]$disk.PartitionStyle
            IsBoot          = [bool]$disk.IsBoot
            IsSystem        = [bool]$disk.IsSystem
            IsRemovable     = [bool]$disk.IsRemovable
            BusType         = if ($disk.BusType) { $disk.BusType.ToString() } else { '' }
            OperationalStatus = if ($disk.OperationalStatus) { $disk.OperationalStatus.ToString() } else { '' }
            Partitions      = $parts
        }
    }

    $installSummaries = @($bootTargets | ForEach-Object {
        [PSCustomObject]@{
            DriveRoot    = $_.DriveRoot
            WindowsDir   = $_.WindowsDir
            EfiBcdPath   = $_.EfiBcdPath
            EfiDriveRoot = if ($_.EfiDriveRoot) { $_.EfiDriveRoot } else { $_.DriveRoot }
            BiosBcdPath  = $_.BiosBcdPath
            Score        = [int]$_.Score
        }
    })

    $efiSummaries = @($efiVolumes | ForEach-Object {
        [PSCustomObject]@{
            DriveRoot  = $_.DriveRoot
            EfiBcdPath = $_.EfiBcdPath
            HasWindows = [bool]$_.HasWindows
            WindowsDir = $_.WindowsDir
        }
    })

    return [PSCustomObject]@{
        SchemaVersion   = 1
        GeneratedAtUtc  = (Get-Date).ToUniversalTime().ToString('o')
        Disks           = $disks
        WindowsInstalls = $installSummaries
        EfiVolumes      = $efiSummaries
    }
}

function Export-CdeDiskLayoutJson {
    [CmdletBinding()]
    param(
        [switch]$Compress
    )

    $layout = Get-CdeDiskLayout
    if ($Compress) {
        return ($layout | ConvertTo-Json -Depth 8 -Compress)
    }

    return ($layout | ConvertTo-Json -Depth 8)
}

Export-ModuleMember -Function Get-CdeDiskLayout, Export-CdeDiskLayoutJson
