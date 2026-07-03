#Requires -Version 5.1
<#
.SYNOPSIS
    List and mount VSS shadow copies for File Manager browse (read-only recovery).
#>
param(
    [ValidateSet('List', 'Mount')]
    [string]$Action = 'List',
    [string]$ShadowId = '',
    [string]$DeviceObject = '',
    [string]$Drive = ''
)

$ErrorActionPreference = 'Stop'
$script:VssAdminElevationDenied = $false

function Test-ShadowCopyWindowsMode {
    if ($env:SystemDrive -eq 'X:') { return $false }
    if ($env:WINPE -eq '1') { return $false }
    if ($env:PEINSTALL -eq '1') { return $false }
    return $true
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ErrorText {
    param($ErrorRecord)

    if ($null -eq $ErrorRecord) {
        return 'Unknown error'
    }

    if ($ErrorRecord.Exception -and -not [string]::IsNullOrWhiteSpace($ErrorRecord.Exception.Message)) {
        return $ErrorRecord.Exception.Message
    }

    if ($ErrorRecord.ErrorDetails -and -not [string]::IsNullOrWhiteSpace($ErrorRecord.ErrorDetails.Message)) {
        return $ErrorRecord.ErrorDetails.Message
    }

    return [string]$ErrorRecord
}

function Normalize-DriveQualifier {
    param([string]$Drive)

    if ([string]::IsNullOrWhiteSpace($Drive)) {
        return $null
    }

    $driveLetter = $Drive.Trim().TrimEnd('\')
    if (-not $driveLetter.EndsWith(':')) {
        $driveLetter = "${driveLetter}:"
    }

    return $driveLetter.ToUpperInvariant()
}

function Get-DriveLetterFromOriginalVolume {
    param([string]$OriginalVolume)

    if ([string]::IsNullOrWhiteSpace($OriginalVolume)) {
        return $null
    }

    $trimmed = $OriginalVolume.Trim()
    if ($trimmed -match '^\(([A-Za-z]:)\)') {
        return $Matches[1].ToUpperInvariant()
    }

    if ($trimmed -match '\(([A-Za-z]:)\)') {
        return $Matches[1].ToUpperInvariant()
    }

    return $null
}

function Get-VssAdminSetInstallDate {
    param([string]$Block)

    if ([string]::IsNullOrWhiteSpace($Block)) {
        return 'Unknown'
    }

    if ($Block -match 'Contained\s+\d+\s+shadow copies at creation time:\s*(.+)') {
        return $Matches[1].Trim()
    }

    return 'Unknown'
}

function Parse-VssAdminShadowCopiesFromBlock {
    param([string]$Block)

    $results = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($Block)) {
        return $results
    }

    $installDate = Get-VssAdminSetInstallDate -Block $Block
    $shadowPattern = '(?ms)^\s*Shadow Copy ID:\s*(\{[0-9A-Fa-f\-]+\})\s*\r?\n\s*Original Volume:\s*([^\r\n]+)\s*\r?\n\s*Shadow Copy Volume:\s*([^\r\n]+)'
    $matches = [regex]::Matches($Block, $shadowPattern)

    foreach ($match in $matches) {
        $shadowId = $match.Groups[1].Value.Trim()
        $originalVolume = $match.Groups[2].Value.Trim()
        $deviceObject = $match.Groups[3].Value.Trim()
        if ([string]::IsNullOrWhiteSpace($deviceObject)) {
            continue
        }

        $results.Add([PSCustomObject]@{
            ID           = $shadowId
            InstallDate  = $installDate
            DeviceObject = $deviceObject
            VolumeName   = $originalVolume
            Drive        = Get-DriveLetterFromOriginalVolume -OriginalVolume $originalVolume
            Source       = 'vssadmin'
        }) | Out-Null
    }

    return $results
}

function Get-ShadowCopiesViaVssAdmin {
    param(
        [string]$Drive = '',
        [switch]$AllowFailure
    )

    $normalizedDrive = if ([string]::IsNullOrWhiteSpace($Drive)) { $null } else { Normalize-DriveQualifier -Drive $Drive }

    $vssOut = cmd /c "vssadmin list shadows" 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        if ($vssOut -match 'correct permissions|administrator privileges|Access is denied') {
            $script:VssAdminElevationDenied = $true
            if ($AllowFailure) {
                return @()
            }

            throw 'VSS browse requires elevation. Start CDE as Administrator to enumerate shadow copies.'
        }

        if ($AllowFailure) {
            return @()
        }

        throw "Failed to enumerate shadow copies via vssadmin. Output: $vssOut"
    }

    $blocks = [regex]::Split($vssOut, '(?=Contents of shadow copy set ID:)')
    $results = New-Object System.Collections.Generic.List[object]

    foreach ($block in $blocks) {
        if ([string]::IsNullOrWhiteSpace($block)) {
            continue
        }

        foreach ($shadow in (Parse-VssAdminShadowCopiesFromBlock -Block $block)) {
            if ($normalizedDrive -and $shadow.Drive -and $shadow.Drive -ne $normalizedDrive) {
                continue
            }

            $results.Add($shadow) | Out-Null
        }
    }

    return (ConvertTo-ShadowCopyArray $results)
}

function Get-ShadowCopiesForDrive {
    param([string]$Drive)

    $vssAdminShadows = @(Get-ShadowCopiesViaVssAdmin -Drive $Drive)
    if ($vssAdminShadows.Count -gt 0) {
        return $vssAdminShadows
    }

    if ($PSVersionTable.PSEdition -eq 'Core') {
        return @()
    }

    $all = @()
    try {
        $all = @(Get-CimInstance Win32_ShadowCopy -ErrorAction Stop)
    }
    catch {
        try {
            $all = @(Get-WmiObject Win32_ShadowCopy -ErrorAction Stop)
        }
        catch {
            $all = @()
        }
    }

    $normalizedDrive = Normalize-DriveQualifier -Drive $Drive
    if (-not $normalizedDrive) {
        return @($all | ForEach-Object {
            [PSCustomObject]@{
                ID           = [string]$_.ID
                InstallDate  = (Get-ShadowCopyInstallDateText $_.InstallDate)
                DeviceObject = [string]$_.DeviceObject
                VolumeName   = [string]$_.VolumeName
                Drive        = $normalizedDrive
                Source       = 'cim'
            }
        })
    }

    return @($all | Where-Object {
        $vol = [string]$_.VolumeName
        $vol -match [regex]::Escape($normalizedDrive) -or $vol -match [regex]::Escape($normalizedDrive.TrimEnd(':'))
    } | ForEach-Object {
        [PSCustomObject]@{
            ID           = [string]$_.ID
            InstallDate  = (Get-ShadowCopyInstallDateText $_.InstallDate)
            DeviceObject = [string]$_.DeviceObject
            VolumeName   = [string]$_.VolumeName
            Drive        = $normalizedDrive
            Source       = 'cim'
        }
    })
}

function ConvertTo-ShadowCopyArray {
    param($Items)

    if ($null -eq $Items) {
        return @()
    }

    if ($Items -is [System.Collections.Generic.List[object]]) {
        return $Items.ToArray()
    }

    if ($Items -is [System.Array]) {
        return $Items
    }

    if ($Items -is [System.Collections.IEnumerable] -and -not ($Items -is [string])) {
        return @($Items | ForEach-Object { $_ })
    }

    return @($Items)
}

function Get-ShadowCopyInstallDateText {
    param($InstallDate)

    if (-not $InstallDate) {
        return 'Unknown'
    }

    if ($InstallDate -is [datetime]) {
        return $InstallDate.ToString('g')
    }

    try {
        return [Management.ManagementDateTimeConverter]::ToDateTime([string]$InstallDate).ToString('g')
    }
    catch {
        return [string]$InstallDate
    }
}

function Get-ShadowCopySortDate {
    param([string]$InstallDate)

    if ([string]::IsNullOrWhiteSpace($InstallDate) -or $InstallDate -eq 'Unknown') {
        return [datetime]::MinValue
    }

    try {
        return [datetime]::Parse(
            $InstallDate,
            [System.Globalization.CultureInfo]::CurrentCulture,
            [System.Globalization.DateTimeStyles]::AllowWhiteSpaces)
    }
    catch {
        try {
            return [datetime]::Parse($InstallDate)
        }
        catch {
            return [datetime]::MinValue
        }
    }
}

function Sort-ShadowCopiesForDisplay {
    param($Shadows)

    return @($Shadows | Sort-Object `
        @{ Expression = { Get-ShadowCopySortDate -InstallDate $_.InstallDate }; Descending = $true }, `
        Drive)
}

function Get-AllShadowCopiesForBrowse {
    $merged = New-Object System.Collections.Generic.List[object]
    $blockingReason = $null
    $script:VssAdminElevationDenied = $false

    foreach ($shadow in (Get-ShadowCopiesViaVssAdmin -AllowFailure)) {
        $merged.Add($shadow) | Out-Null
    }

    if ($merged.Count -gt 0) {
        return [PSCustomObject]@{
            Shadows        = (ConvertTo-ShadowCopyArray $merged)
            BlockingReason = $null
        }
    }

    $cimShadows = @()
    try {
        $cimShadows = @(Get-CimInstance Win32_ShadowCopy -ErrorAction Stop)
    }
    catch {
        if ($PSVersionTable.PSEdition -ne 'Core') {
            try {
                $cimShadows = @(Get-WmiObject Win32_ShadowCopy -ErrorAction Stop)
            }
            catch {
                $cimShadows = @()
            }
        }
    }

    foreach ($shadow in $cimShadows) {
        $volumeName = [string]$shadow.VolumeName
        $drive = Get-DriveLetterFromOriginalVolume -OriginalVolume $volumeName
        if (-not $drive) {
            $drive = ''
        }

        $merged.Add([PSCustomObject]@{
            ID           = [string]$shadow.ID
            InstallDate  = (Get-ShadowCopyInstallDateText $shadow.InstallDate)
            DeviceObject = [string]$shadow.DeviceObject
            VolumeName   = $volumeName
            Drive        = $drive
            Source       = 'cim'
        }) | Out-Null
    }

    if ($merged.Count -eq 0) {
        if ($script:VssAdminElevationDenied -or -not (Test-IsAdministrator)) {
            $blockingReason = 'VSS browse requires elevation. Start CDE as Administrator to enumerate shadow copies.'
        }
    }

    return [PSCustomObject]@{
        Shadows        = (ConvertTo-ShadowCopyArray $merged)
        BlockingReason = $blockingReason
    }
}

function Get-ShadowCopyMountRoot {
    return Join-Path $env:TEMP 'CDE_ShadowBrowse'
}

function Get-ShadowCopyMountName {
    param(
        [string]$Drive,
        [string]$ShadowId
    )

    $driveLetter = Normalize-DriveQualifier -Drive $Drive
    if (-not $driveLetter) {
        $driveLetter = 'VOL'
    }

    $safeId = ($ShadowId -replace '[{}\\/:]', '')
    if ($safeId.Length -gt 24) {
        $safeId = $safeId.Substring(0, 24)
    }
    if ([string]::IsNullOrWhiteSpace($safeId)) {
        $safeId = [Guid]::NewGuid().ToString('N').Substring(0, 12)
    }

    return ("{0}_{1}" -f $driveLetter.TrimEnd(':'), $safeId)
}

function Mount-ShadowCopyForBrowse {
    param(
        [string]$ShadowId,
        [string]$DeviceObject,
        [string]$Drive
    )

    if ([string]::IsNullOrWhiteSpace($DeviceObject)) {
        throw 'DeviceObject is required to mount a shadow copy.'
    }

    $browseRoot = Get-ShadowCopyMountRoot
    if (-not (Test-Path -LiteralPath $browseRoot)) {
        New-Item -ItemType Directory -Force -Path $browseRoot | Out-Null
    }

    $mountName = Get-ShadowCopyMountName -Drive $Drive -ShadowId $ShadowId
    $browsePath = Join-Path $browseRoot $mountName

    if (Test-Path -LiteralPath $browsePath) {
        return $browsePath
    }

    $target = $DeviceObject.Trim()
    if (-not $target.EndsWith('\')) {
        $target = "$target\"
    }

    $mkOut = cmd /c "mklink /d `"$browsePath`" `"$target`"" 2>&1 | Out-String
    if (-not (Test-Path -LiteralPath $browsePath)) {
        throw "Failed to expose shadow copy path. mklink output: $mkOut"
    }

    return $browsePath
}

$script:IsShadowCopyBrowseDotSourced = $MyInvocation.InvocationName -eq '.'
if ($script:IsShadowCopyBrowseDotSourced) {
    return
}

if (-not (Test-ShadowCopyWindowsMode)) {
    if ($Action -eq 'List') {
        @() | ConvertTo-Json -Depth 4
        exit 0
    }

    throw 'Shadow copy browse is not available in WinPE mode.'
}

switch ($Action) {
    'List' {
        try {
            $browseResult = Get-AllShadowCopiesForBrowse
            $shadows = ConvertTo-ShadowCopyArray $browseResult.Shadows
            $blockingReason = [string]$browseResult.BlockingReason
            if ($shadows.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($blockingReason)) {
                [PSCustomObject]@{ error = [string]$blockingReason } | ConvertTo-Json -Compress
                return
            }

            $payload = foreach ($shadow in (Sort-ShadowCopiesForDisplay -Shadows $shadows)) {
                $drive = if ($shadow.Drive) { $shadow.Drive } else { '' }
                $labelDate = [string]$shadow.InstallDate
                if ($labelDate -eq 'Unknown' -and $shadow.ID -match '\{(.+)\}') {
                    $labelDate = $shadow.ID
                }

                [PSCustomObject]@{
                    Id           = [string]$shadow.ID
                    Drive        = $drive
                    InstallDate  = [string]$shadow.InstallDate
                    DeviceObject = [string]$shadow.DeviceObject
                    VolumeName   = [string]$shadow.VolumeName
                    DisplayLabel = if ($drive) { "$drive  $labelDate" } else { $labelDate }
                }
            }

            if (@($payload).Count -eq 0) {
                '[]'
            }
            else {
                $payload | ConvertTo-Json -Depth 4
            }
        }
        catch {
            [PSCustomObject]@{ error = (Get-ErrorText $_) } | ConvertTo-Json -Compress
        }
    }

    'Mount' {
        $mountPath = Mount-ShadowCopyForBrowse -ShadowId $ShadowId -DeviceObject $DeviceObject -Drive $Drive
        [PSCustomObject]@{
            MountPath = $mountPath
            ShadowId  = $ShadowId
        } | ConvertTo-Json -Depth 4
    }
}
