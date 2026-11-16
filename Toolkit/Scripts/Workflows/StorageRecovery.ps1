#Requires -Version 5.1
<#
.SYNOPSIS
    CDE Storage Recovery — Read-only partition & file system diagnostic workflow.
.PARAMETER ToolName
    Workflow action: Inspect, Snapshot, or ValidateRules.
.PARAMETER ImagePath
    Optional path to a raw disk image file (.img/.bin/.raw) to inspect in read-only mode.
.PARAMETER DiskNumber
    Optional physical disk number to inspect in read-only mode.
.PARAMETER LogicalSectorSize
    Logical sector size for disk image inspection (512 or 4096).
#>
param(
    [ValidateSet('Inspect', 'Snapshot', 'ValidateRules')]
    [string]$ToolName = 'Inspect',
    [string]$ImagePath = '',
    [int]$DiskNumber = -1,
    [int]$LogicalSectorSize = 512,
    [string]$SnapshotOutputDir = ''
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ToolkitRoot = Split-Path (Split-Path $ScriptDir -Parent) -Parent
Import-Module (Join-Path $ScriptDir '..\Core\Toolkit.Core.psm1') -Force -DisableNameChecking

try {
    $workflow = Start-Workflow -WorkflowName "StorageRecovery_$ToolName" -ScriptBlock {
        param($r)

        Assert-ToolkitCapability -Workflow 'StorageRecovery' -Action 'Run'

        $rulesPath = Join-Path $ToolkitRoot 'Config\StorageRecoveryRules.json'
        if (-not (Test-Path -LiteralPath $rulesPath -PathType Leaf)) {
            throw "StorageRecoveryRules.json not found at $rulesPath"
        }

        $rules = Get-Content -LiteralPath $rulesPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $r.Steps += [PSCustomObject]@{
            Name   = 'LoadRecoveryRules'
            Status = 'Pass'
            Output = "Loaded StorageRecoveryRules.json (schema v$($rules.schemaVersion), defaultMode=$($rules.safetyPolicy.defaultMode))"
        }

        if ($ToolName -eq 'ValidateRules') {
            return
        }

        $dllCandidates = @(
            (Join-Path $ToolkitRoot 'App\ToolkitGUI\bin\Release\net8.0-windows\CdeRecovery.Core.dll'),
            (Join-Path $ToolkitRoot 'App\ToolkitGUI\bin\Debug\net8.0-windows\CdeRecovery.Core.dll'),
            (Join-Path $ToolkitRoot 'CDE\ToolkitGUI\bin\Release\net8.0-windows\CdeRecovery.Core.dll')
        )
        $coreDll = $dllCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

        if (-not [string]::IsNullOrWhiteSpace($ImagePath)) {
            if (-not (Test-Path -LiteralPath $ImagePath -PathType Leaf)) {
                throw "Disk image not found: $ImagePath"
            }

            $fs = [System.IO.File]::Open($ImagePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                $sec0 = New-Object byte[] 512
                $read0 = $fs.Read($sec0, 0, 512)
                $mbrSig = if ($read0 -ge 512) { [BitConverter]::ToUInt16($sec0, 510) } else { 0 }
                $sigHex = ('0x{0:X4}' -f $mbrSig)

                $sec1 = New-Object byte[] 512
                $fs.Seek($LogicalSectorSize, [System.IO.SeekOrigin]::Begin) | Out-Null
                $read1 = $fs.Read($sec1, 0, 512)
                $gptSig = if ($read1 -ge 8) { [System.Text.Encoding]::ASCII.GetString($sec1, 0, 8) } else { '' }

                $status = if ($mbrSig -eq 0xAA55) { 'Pass' } else { 'Warn' }
                $r.Steps += [PSCustomObject]@{
                    Name   = 'InspectDiskImage'
                    Status = $status
                    Output = "Inspected image $(Split-Path $ImagePath -Leaf) ($($fs.Length) bytes): MBR Sig=$sigHex, Primary GPT Sig='$gptSig'"
                }
            } finally {
                $fs.Dispose()
            }
        } elseif ($DiskNumber -ge 0) {
            if (Get-Command Get-Disk -ErrorAction SilentlyContinue) {
                $d = Get-Disk -Number $DiskNumber -ErrorAction Stop
                $r.Steps += [PSCustomObject]@{
                    Name   = 'InspectPhysicalDisk'
                    Status = 'Pass'
                    Output = "Disk $($d.Number) ($($d.FriendlyName), $($d.PartitionStyle), $($d.Size) bytes, Health=$($d.HealthStatus))"
                }
            } else {
                $r.Steps += [PSCustomObject]@{
                    Name   = 'InspectPhysicalDisk'
                    Status = 'Skip'
                    Output = 'Get-Disk cmdlet not available in current session.'
                }
            }
        } else {
            $r.Steps += [PSCustomObject]@{
                Name   = 'StorageRecoveryInventory'
                Status = 'Pass'
                Output = "Storage Recovery read-only engine ready (CoreAssemblyPresent=$([bool]$coreDll))."
            }
        }
    }

    Generate-Report -WorkflowResult $workflow | Out-Null
} catch {
    Write-Error "StorageRecovery workflow failed: $($_.Exception.Message)"
    exit 1
}
exit 0
