#Requires -Version 5.1
param(
    [int]$DiskNumber = -1,
    [string]$BackupRoot = '',
    [string]$TargetDrive = '',
    [switch]$Confirmed
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $ScriptDir '..\Core\Toolkit.Core.psm1') -Force -DisableNameChecking
. (Join-Path $ScriptDir 'Bootloader.Common.ps1')

$workflow = Start-Workflow -WorkflowName 'PartitionTable_Backup' -ScriptBlock {
    param($r)

    Assert-WinPeOrThrow -Result $r

    if ($DiskNumber -lt 0) {
        throw 'DiskNumber is required.'
    }

    $resolvedBackupRoot = $BackupRoot
    if ([string]::IsNullOrWhiteSpace($resolvedBackupRoot)) {
        if ([string]::IsNullOrWhiteSpace($TargetDrive)) {
            throw 'BackupRoot or TargetDrive is required.'
        }

        $clean = $TargetDrive.Trim().TrimEnd('\')
        if (-not $clean.EndsWith(':')) { $clean = "${clean}:" }
        $resolvedBackupRoot = Join-Path $clean 'CDE_Bootloader_Backups'
    }

    if (-not (Confirm-BootloaderWriteAction -Message "Export partition layout for disk $DiskNumber to $resolvedBackupRoot?" -Force:$Confirmed)) {
        throw 'Operation cancelled by operator at write confirmation.'
    }

    if (-not (Test-Path -LiteralPath $resolvedBackupRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $resolvedBackupRoot -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $textPath = Join-Path $resolvedBackupRoot "PartitionTable_Disk${DiskNumber}_$timestamp.txt"
    $jsonPath = Join-Path $resolvedBackupRoot "PartitionTable_Disk${DiskNumber}_$timestamp.json"

    $dpScript = @(
        "select disk $DiskNumber"
        'detail disk'
        'list partition'
        'exit'
    ) -join "`r`n"

    $tempScript = Join-Path $env:TEMP "cde_diskpart_detail_$DiskNumber.txt"
    $tempStdout = Join-Path $env:TEMP "cde_diskpart_detail_${DiskNumber}_out.txt"
    $tempStderr = Join-Path $env:TEMP "cde_diskpart_detail_${DiskNumber}_err.txt"
    try {
        $dpScript | Out-File -LiteralPath $tempScript -Encoding ASCII -Force
        if (Test-Path -LiteralPath $tempStdout) { Remove-Item -LiteralPath $tempStdout -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $tempStderr) { Remove-Item -LiteralPath $tempStderr -Force -ErrorAction SilentlyContinue }

        $proc = Start-Process -FilePath 'diskpart.exe' -ArgumentList "/s `"$tempScript`"" -Wait -PassThru -NoNewWindow `
            -RedirectStandardOutput $tempStdout -RedirectStandardError $tempStderr

        $stdout = if (Test-Path -LiteralPath $tempStdout) {
            Get-Content -LiteralPath $tempStdout -Raw -Encoding Default
        } else { '' }
        $stderr = if (Test-Path -LiteralPath $tempStderr) {
            Get-Content -LiteralPath $tempStderr -Raw -Encoding Default
        } else { '' }
        $diskpartOutput = Get-CommandCaptureText -Stdout $stdout -Stderr $stderr -Delimiter "`r`n"

        $header = @(
            "CDE Partition Layout Backup"
            "Disk: $DiskNumber"
            "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            "diskpart exit code: $($proc.ExitCode)"
            '---'
        ) -join "`r`n"

        ($header + "`r`n" + $diskpartOutput) | Out-File -LiteralPath $textPath -Encoding UTF8

        Add-BootloaderStep -Result $r -Step ([PSCustomObject]@{
            Name     = 'DiskPartLayoutExport'
            Status   = if ($proc.ExitCode -eq 0) { 'Pass' } else { 'Warn' }
            ExitCode = $proc.ExitCode
            Output   = "Wrote $textPath"
        })
    } finally {
        Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tempStdout -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tempStderr -Force -ErrorAction SilentlyContinue
    }

    if (Get-Command Get-Disk -ErrorAction SilentlyContinue) {
        try {
            $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
            $parts = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue)
            $payload = [PSCustomObject]@{
                SchemaVersion  = 1
                DiskNumber     = $DiskNumber
                GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
                Disk           = $disk
                Partitions     = $parts
            }
            ($payload | ConvertTo-Json -Depth 6) | Out-File -LiteralPath $jsonPath -Encoding UTF8
            Add-BootloaderStep -Result $r -Step ([PSCustomObject]@{
                Name     = 'StorageJsonExport'
                Status   = 'Pass'
                ExitCode = 0
                Output   = "Wrote $jsonPath"
            })
        } catch {
            Add-BootloaderStep -Result $r -Step ([PSCustomObject]@{
                Name     = 'StorageJsonExport'
                Status   = 'Warn'
                ExitCode = 1
                Output   = $_.Exception.Message
            })
        }
    } else {
        Add-BootloaderStep -Result $r -Step ([PSCustomObject]@{
            Name     = 'StorageJsonExport'
            Status   = 'Skip'
            ExitCode = 0
            Output   = 'Get-Disk unavailable; diskpart text export only.'
        })
    }
}

try {
    Complete-BootloaderWorkflow -WorkflowResult $workflow
} catch {
    Write-Error "PartitionTableBackup workflow failed: $($_.Exception.Message)"
    exit 1
}
