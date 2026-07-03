#Requires -Version 5.1
<#
.SYNOPSIS
    BackupAndImage.ps1 - Individual backup and imaging tools dispatcher.
    Pass -ToolName to run a specific tool.
#>

param(
    [string]$ToolName          = 'All',   # RobocopyBackup | All
    [string]$BackupSource      = "$env:USERPROFILE",
    [string]$BackupDestination = '',
    [switch]$DryRun            = $false,
    [switch]$Mirror            = $false
)

$ErrorActionPreference = 'Stop'

$ScriptDir  = Split-Path $MyInvocation.MyCommand.Path
$CoreModule = Join-Path $ScriptDir '..\Core\Toolkit.Core.psm1'
Import-Module $CoreModule -Force -DisableNameChecking

function Normalize-BackupPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    $normalized = $Path.Trim().Trim("'").Trim('"')
    if ($normalized -match '^([A-Za-z]):$') {
        return "$($matches[1]):\"
    }

    if ($normalized -match '^([A-Za-z]):\\$') {
        return $normalized
    }

    return $normalized.TrimEnd('\')
}

$BackupSource = Normalize-BackupPath -Path $BackupSource
if (-not [string]::IsNullOrWhiteSpace($BackupDestination)) {
    $BackupDestination = Normalize-BackupPath -Path $BackupDestination
}

function Resolve-BackupDest {
    param($r)
    $dest = $BackupDestination
    if ($null -eq $dest -or [string]::IsNullOrWhiteSpace([string]$dest)) {
        $extDrives = Get-PSDrive -PSProvider FileSystem |
                 Where-Object { $null -ne $_.Free -and $_.Name -ne 'C' -and $_.Name.Length -eq 1 }
        if ($extDrives) {
            $dest = "$($extDrives[0].Root)ToolkitBackup\$(Get-Date -Format 'yyyyMMdd_HHmmss')"
            Write-Log "Auto-selected destination: $dest"
        } else {
            Write-Log "No backup destination available and no external drives detected." -Level Warning
            return $null
        }
    }
    Write-Log "Backup destination (resolved): $dest"
    return $dest
}

function Format-RobocopyPathArgument {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    # Start-Process passes each ArgumentList entry to robocopy.exe without quoting;
    # paths with spaces must be wrapped or robocopy treats the tail as file filters.
    if ($Path -match '\s') {
        return "`"$Path`""
    }

    return $Path
}

function Get-RobocopySummaryCounts {
    param([string]$Output)

    $result = [PSCustomObject]@{
        FilesTotal  = -1
        FilesCopied = -1
    }

    if ([string]::IsNullOrWhiteSpace($Output)) {
        return $result
    }

    if ($Output -match 'Files\s*:\s*(\d+)\s+(\d+)') {
        $result.FilesTotal = [int]$Matches[1]
        $result.FilesCopied = [int]$Matches[2]
    }

    return $result
}

function Invoke-RobocopyBackup {
    param($r)
    $dest = Resolve-BackupDest $r
    if (-not $dest) {
        $r.Steps.Add([PSCustomObject]@{ Name='RobocopyBackup'; Status='Warn'; Output='No backup destination found. Connect an external drive or specify -BackupDestination.' })
        return
    }

    if ([string]::IsNullOrWhiteSpace($BackupSource)) {
        $message = 'Backup source path is empty.'
        Write-Log $message -Level Error
        $r.Steps.Add([PSCustomObject]@{ Name='RobocopyBackup'; Status='Fail'; Output=$message })
        return
    }

    if (-not (Test-Path -LiteralPath $BackupSource)) {
        $message = "Backup source path was not found: $BackupSource"
        Write-Log $message -Level Error
        $r.Steps.Add([PSCustomObject]@{ Name='RobocopyBackup'; Status='Fail'; Output=$message })
        return
    }

    Write-Log "Starting Robocopy: $BackupSource --> $dest"
    if ($DryRun) {
        Write-Log 'Dry run enabled (/L). No files will be copied.'
    }
    if ($Mirror) {
        Write-Log 'Mirror mode enabled (/MIR).'
    }

    try {
        if (-not (Test-Path -LiteralPath $dest)) {
            New-Item -ItemType Directory -Force -Path $dest | Out-Null
        }

        $roboSource = Format-RobocopyPathArgument -Path $BackupSource
        $roboDest = Format-RobocopyPathArgument -Path $dest

        # Use data/timestamps/attributes only to avoid requiring backup audit privileges.
        $roboArgs = @(
            $roboSource,
            $roboDest,
            '/E',
            '/COPY:DAT',
            '/DCOPY:DAT',
            '/R:3',
            '/W:5',
            '/MT:8',
            '/XD',
            '$RECYCLE.BIN',
            'System Volume Information',
            '/NP'
        )
        if ($Mirror) {
            $roboArgs = @(
                $roboSource,
                $roboDest,
                '/MIR',
                '/COPY:DAT',
                '/DCOPY:DAT',
                '/R:3',
                '/W:5',
                '/MT:8',
                '/XD',
                '$RECYCLE.BIN',
                'System Volume Information',
                '/NP'
            )
        }
        if ($DryRun) {
            $roboArgs += '/L'
        }

        $proc = Start-Process -FilePath 'robocopy.exe' -ArgumentList $roboArgs `
                              -Wait -PassThru -NoNewWindow `
                              -RedirectStandardOutput "$env:TEMP\robocopy_out.txt"
        $output = if (Test-Path "$env:TEMP\robocopy_out.txt") {
            Get-Content "$env:TEMP\robocopy_out.txt" -Raw
        } else {
            ''
        }
        $counts = Get-RobocopySummaryCounts -Output $output
        $success = $proc.ExitCode -le 7
        $noFilesCopied = (-not $DryRun) -and $counts.FilesCopied -eq 0 -and $counts.FilesTotal -gt 0
        if ($noFilesCopied) {
            $success = $false
            Write-Log 'Robocopy finished with exit code 0 but copied no files. A destination path with spaces may have been split into a folder plus file filter.' -Level Warning
        }

        Write-Log "Robocopy exit code: $($proc.ExitCode) - $(if ($success) { 'Success' } else { 'Error' })"
        $tail = if ([string]::IsNullOrWhiteSpace($output)) {
            ''
        } else {
            ($output -split "`r?`n" | Select-Object -Last 15) -join "`n"
        }
        if (-not [string]::IsNullOrWhiteSpace($tail)) {
            Write-Log "Robocopy summary:`n$tail"
        }
        if ($success) {
            if ($DryRun) {
                Write-Log "Dry run complete. Would copy to $dest"
            } elseif ($counts.FilesCopied -gt 0) {
                Write-Log "Copied $($counts.FilesCopied) file(s) to $dest"
            } else {
                Write-Log "Robocopy completed with no file changes at $dest"
            }
        }
        $stepOutput = if ($DryRun) { 'Dry run (/L). ' } else { '' }
        $stepOutput += "Exit code $($proc.ExitCode). Destination: $dest"
        if (-not [string]::IsNullOrWhiteSpace($tail)) {
            $stepOutput += "`n$tail"
        }
        if ($noFilesCopied) {
            $stepOutput += "`nNo files were copied even though the source contains $($counts.FilesTotal) file(s)."
        }
        $stepStatus = if (-not $success) { 'Fail' } elseif ($counts.FilesCopied -eq 0 -and -not $DryRun) { 'Warn' } else { 'Pass' }
        $r.Steps.Add([PSCustomObject]@{
            Name   = 'RobocopyBackup'
            Status = $stepStatus
            Output = $stepOutput
        })
    } catch {
        $message = $_.Exception.Message
        Write-Log "Robocopy backup failed: $message" -Level Error
        $r.Steps.Add([PSCustomObject]@{ Name='RobocopyBackup'; Status='Fail'; Output=$message })
    }
}

# --- Dispatch ---
$workflowName = if ($ToolName -eq 'All') { 'Backup_All' } else { "Backup_$ToolName" }

try {
    $workflow = Start-Workflow -WorkflowName $workflowName -ScriptBlock {
        param($r)
        Write-Log "Resolved backup source: $BackupSource"
        if (-not [string]::IsNullOrWhiteSpace($BackupDestination)) {
            Write-Log "Resolved backup destination parameter: $BackupDestination"
        }
        switch ($ToolName) {
            default {
                Invoke-RobocopyBackup $r
            }
        }
        $failCount = @($r.Steps | Where-Object { $_.Status -eq 'Fail' }).Count
        $warnCount = @($r.Steps | Where-Object { $_.Status -eq 'Warn' }).Count
        $summary   = if ($failCount) { 'Some operations failed' } elseif ($warnCount) { 'Completed with warnings' } else { 'All operations completed' }
        Write-Log "Summary: $summary"
    }

    Generate-Report -WorkflowResult $workflow | Out-Null

    if ($workflow.Status -eq 'Failed') {
        exit 1
    }
} catch {
    Write-Error "BackupAndImage workflow failed: $($_.Exception.Message)"
    exit 1
}
