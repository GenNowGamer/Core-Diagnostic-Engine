#Requires -Version 5.1
<#
.SYNOPSIS
    Elevation relay and workflow step helpers for CDE PowerShell workflows.
#>

function Test-ToolkitIsElevated {
    [OutputType([bool])]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-ToolkitElevatedRelay {
    <#
    .SYNOPSIS
        Re-launches a PowerShell script elevated (UAC), captures its output, and re-emits it
        to the caller so GUI workflows still receive live tagged lines (e.g. [HIJACK:FINDING]).
    .OUTPUTS
        $null when already elevated (caller should continue in-process).
        PSCustomObject with Relayed/ExitCode/PidFile/Pid when an elevated child ran.
    #>
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string]$ArgumentString = ''
    )

    if (Test-ToolkitIsElevated) {
        return $null
    }

    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        throw "Elevated relay script not found: $ScriptPath"
    }

    $elevDir = if (-not [string]::IsNullOrWhiteSpace($env:CDE_ELEV_PID_DIR)) {
        $env:CDE_ELEV_PID_DIR
    } else {
        Join-Path $env:LOCALAPPDATA 'CoreDiagnosticEngine\Runtime\elev'
    }
    if (-not (Test-Path -LiteralPath $elevDir -PathType Container)) {
        New-Item -ItemType Directory -Path $elevDir -Force | Out-Null
    }

    $runId = [Guid]::NewGuid().ToString('N')
    $pidFile = Join-Path $elevDir ("cde_elev_pid_{0}.txt" -f $runId)
    $transcriptFile = Join-Path $elevDir ("cde_elev_{0}.log" -f $runId)
    $env:CDE_ELEVATED_PID_FILE = $pidFile

    $escapedScript = $ScriptPath.Replace("'", "''")
    $escapedPidFile = $pidFile.Replace("'", "''")
    $escapedTranscript = $transcriptFile.Replace("'", "''")
    $argSuffix = if ([string]::IsNullOrWhiteSpace($ArgumentString)) { '' } else { " $ArgumentString" }

    $inner = @"
`$ErrorActionPreference = 'Continue'
`$env:CDE_ELEVATED_PID_FILE = '$escapedPidFile'
Start-Transcript -LiteralPath '$escapedTranscript' -Force | Out-Null
try {
    & '$escapedScript'$argSuffix
    `$exitCode = if (`$null -ne `$LASTEXITCODE) { `$LASTEXITCODE } else { 0 }
} catch {
    Write-Error `$_.Exception.Message
    `$exitCode = 1
} finally {
    Stop-Transcript | Out-Null
}
exit `$exitCode
"@

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
    $launchArgs = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"

    $child = $null
    try {
        $child = Start-Process -FilePath 'powershell.exe' -ArgumentList $launchArgs -Verb RunAs -PassThru -WindowStyle Hidden
        if ($null -eq $child) {
            throw "Elevation request was canceled or failed: no process started"
        }

        Set-Content -LiteralPath $pidFile -Value ([string]$child.Id) -Encoding ascii -Force
        Wait-Process -Id $child.Id -ErrorAction SilentlyContinue
        try { $child.Refresh() } catch { }
    } catch {
        throw "Elevation request was canceled or failed: $($_.Exception.Message)"
    } finally {
        if (Test-Path -LiteralPath $transcriptFile) {
            Get-Content -LiteralPath $transcriptFile -Encoding UTF8 -ErrorAction SilentlyContinue |
                ForEach-Object {
                    if ($_ -match '^(?:\*{3}|Host Application:|Windows PowerShell transcript (?:start|end))') { return }
                    if ($_ -match '^PS(?:>| )') { return }
                    Write-Host $_
                }
            Remove-Item -LiteralPath $transcriptFile -Force -ErrorAction SilentlyContinue
        }
    }

    return [PSCustomObject]@{
        Relayed  = $true
        ExitCode = if ($null -ne $child) { $child.ExitCode } else { 1 }
        PidFile  = $pidFile
        Pid      = if ($null -ne $child) { $child.Id } else { $null }
    }
}

function Test-ToolkitShouldRelayElevation {
    param([switch]$ElevatedRelay)

    if ($ElevatedRelay) { return $false }
    if (Test-ToolkitIsElevated) { return $false }
    return $true
}

function Invoke-ToolkitWorkflowElevationRelay {
    <#
    .SYNOPSIS
        Runs a workflow script elevated when the current process is not admin.
    .OUTPUTS
        $true when an elevated child completed successfully; $false when caller should continue in-process.
    #>
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$ArgumentString,
        [switch]$ElevatedRelay
    )

    if (-not (Test-ToolkitShouldRelayElevation -ElevatedRelay:$ElevatedRelay)) {
        return $false
    }

    $relay = Invoke-ToolkitElevatedRelay -ScriptPath $ScriptPath -ArgumentString $ArgumentString
    if ($null -eq $relay) { return $false }
    if ($relay.ExitCode -ne 0) {
        throw "Elevated workflow failed (exit code $($relay.ExitCode))."
    }
    return $true
}

function Get-ToolkitWorkflowDataRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:TOOLKIT_ROOT)) {
        return Join-Path $env:TOOLKIT_ROOT 'CDE\Runtime\Data\workflows'
    }

    $toolkitRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    return Join-Path $toolkitRoot 'CDE\Runtime\Data\workflows'
}

function Import-ToolkitRelayedWorkflowStep {
    param(
        $WorkflowResult,
        [Parameter(Mandatory)][string]$WorkflowName,
        [Parameter(Mandatory)][string]$StepName
    )

    if ($null -eq $WorkflowResult) { return }

    try {
        $dataRoot = Get-ToolkitWorkflowDataRoot
        if (-not (Test-Path -LiteralPath $dataRoot -PathType Container)) { return }

        $latest = Get-ChildItem -LiteralPath $dataRoot -Filter "${WorkflowName}_*.json" -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($null -eq $latest) { return }

        $report = Get-Content -LiteralPath $latest.FullName -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $step = @($report.Steps | Where-Object { [string]$_.Name -eq $StepName }) | Select-Object -First 1
        if ($null -eq $step) { return }

        Add-ToolkitWorkflowStep -WorkflowResult $WorkflowResult -Name $StepName -Status ([string]$step.Status) -Output ([string]$step.Output)
    } catch { }
}

function Add-ToolkitQuotedRelayArgument {
    param(
        [AllowEmptyCollection()]
        [Parameter(Mandatory)][System.Collections.Generic.List[string]]$Parts,
        [Parameter(Mandatory)][string]$Name,
        [string]$Value = '',
        [switch]$IsSwitch
    )

    if ($IsSwitch) {
        $Parts.Add("-$Name") | Out-Null
        return
    }

    if ([string]::IsNullOrWhiteSpace($Value)) { return }
    $escaped = $Value.Replace("'", "''")
    $Parts.Add("-$Name '$escaped'") | Out-Null
}

function Join-ToolkitRelayArgumentString {
    param([Parameter(Mandatory)][System.Collections.Generic.List[string]]$Parts)
    return ($Parts -join ' ')
}

function Add-ToolkitWorkflowStep {
    param(
        [Parameter(Mandatory)]$WorkflowResult,
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('Pass', 'Warn', 'Fail', 'Skip', 'N/A')]
        [string]$Status,
        [Parameter(Mandatory)][string]$Output
    )

    $null = $WorkflowResult.Steps.Add([PSCustomObject]@{
        Name   = $Name
        Status = $Status
        Output = $Output
    })
}

function Get-ToolkitWorkflowStepStatus {
    param(
        [int]$Succeeded,
        [int]$Failed = 0,
        [int]$Skipped = 0,
        [switch]$RequireSuccess
    )

    if ($Failed -gt 0 -or ($RequireSuccess -and $Succeeded -eq 0)) {
        return 'Fail'
    }
    if ($Skipped -gt 0) {
        return 'Warn'
    }
    if ($Succeeded -gt 0) {
        return 'Pass'
    }
    return 'Fail'
}

Export-ModuleMember -Function @(
    'Test-ToolkitIsElevated',
    'Test-ToolkitShouldRelayElevation',
    'Invoke-ToolkitElevatedRelay',
    'Invoke-ToolkitWorkflowElevationRelay',
    'Get-ToolkitWorkflowDataRoot',
    'Import-ToolkitRelayedWorkflowStep',
    'Add-ToolkitQuotedRelayArgument',
    'Join-ToolkitRelayArgumentString',
    'Add-ToolkitWorkflowStep',
    'Get-ToolkitWorkflowStepStatus'
)
