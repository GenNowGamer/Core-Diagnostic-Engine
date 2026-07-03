#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

if (-not ('CdeSmart.Reader' -as [type])) {
    $csPath = Join-Path $PSScriptRoot 'CdeSmartReader.cs'
    if (-not (Test-Path -LiteralPath $csPath)) {
        throw "CdeSmartReader.cs not found at $csPath"
    }
    Add-Type -Path $csPath -ErrorAction Stop
}

Import-Module (Join-Path $PSScriptRoot 'PhysicalDiskCatalog.psm1') -Force -DisableNameChecking

function Get-CdeSmartDrives {
    $allowed = @{}
    foreach ($idx in (Get-CdeTestablePhysicalDiskIndices)) {
        $allowed[$idx] = $true
    }

    $list = [CdeSmart.Reader]::ReadAll()
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($d in $list) {
        if (-not $allowed.ContainsKey([int]$d.Index)) { continue }
        $attrs = New-Object System.Collections.Generic.List[object]
        foreach ($a in $d.Attributes) {
            $attrs.Add([PSCustomObject]@{
                Id        = $a.Id
                Name      = $a.Name
                Current   = $a.Current
                Worst     = $a.Worst
                Threshold = $a.Threshold
                Raw       = $a.Raw
                Status    = $a.Status
            })
        }
        $out.Add([PSCustomObject]@{
            Index         = $d.Index
            Model         = $d.Model
            Serial        = $d.Serial
            Bus           = $d.Bus
            Protocol      = $d.Protocol
            SizeGB        = $d.SizeGB
            Overall       = $d.Overall
            TemperatureC  = $d.TemperatureC
            Supported     = $d.Supported
            Note          = $d.Note
            Attributes    = $attrs
        })
    }
    return $out
}

function Get-CdeSmartDriveByIndex {
    param([int]$Index)
    $d = [CdeSmart.Reader]::GetDriveByIndex($Index)
    if ($null -eq $d) { return $null }
    foreach ($drive in (Get-CdeSmartDrives)) {
        if ($drive.Index -eq $Index) { return $drive }
    }
    return $null
}

function Test-CdeSmartThresholds {
    param([int]$DriveIndex)
    $d = Get-CdeSmartDriveByIndex -Index $DriveIndex
    if (-not $d) { return 'Skipped: Drive not found for SMART' }
    if (-not $d.Supported) {
        if ($d.Note) { return "Skipped: $($d.Note)" }
        return 'Skipped: SMART not supported'
    }
    $fails = @($d.Attributes | Where-Object { $_.Status -eq 'Fail' })
    if ($fails.Count -gt 0) {
        $names = ($fails | Select-Object -First 3 | ForEach-Object { $_.Name }) -join ', '
        return "Failed: threshold tripped ($names)"
    }
    $warns = @($d.Attributes | Where-Object { $_.Status -eq 'Warn' })
    if ($warns.Count -gt 0) {
        return ('Passed: {0} warning attribute(s)' -f $warns.Count)
    }
    return 'Passed'
}

function Test-CdeSmartStatus {
    param([int]$DriveIndex)
    $d = Get-CdeSmartDriveByIndex -Index $DriveIndex
    if (-not $d) { return 'Skipped: Drive not found for SMART' }
    if (-not $d.Supported -and $d.Note) { return "Skipped: $($d.Note)" }
    switch ($d.Overall) {
        'Fail' { return "Failed: SMART overall $($d.Overall)" }
        'Warn' { return "Passed: SMART warnings present ($($d.Overall))" }
        'Pass' { return 'Passed' }
        default { return "Skipped: SMART status $($d.Overall)" }
    }
}

function Start-CdeSmartShortSelfTest {
    param(
        [int]$DriveIndex,
        [int]$TimeoutSec = 120
    )
    return [CdeSmart.Reader]::RunShortSelfTest($DriveIndex, $TimeoutSec)
}
