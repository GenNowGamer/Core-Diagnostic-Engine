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
        [string]$ArgumentString = '',
        [hashtable]$RelayOut = $null,
        [switch]$StreamToHost
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
    $logFile = Join-Path $elevDir ("cde_elev_{0}.log" -f $runId)
    $errLogFile = Join-Path $elevDir ("cde_elev_err_{0}.log" -f $runId)
    $exitFile = Join-Path $elevDir ("cde_elev_exit_{0}.txt" -f $runId)
    $cancelFile = Join-Path $elevDir 'cancel.flag'
    $env:CDE_ELEVATED_PID_FILE = $pidFile

    $escapedScript = $ScriptPath.Replace("'", "''")
    $escapedPidFile = $pidFile.Replace("'", "''")
    $escapedLogFile = $logFile.Replace("'", "''")
    $escapedErrLogFile = $errLogFile.Replace("'", "''")
    $escapedExitFile = $exitFile.Replace("'", "''")
    $escapedCancelFile = $cancelFile.Replace("'", "''")
    $argSuffix = if ([string]::IsNullOrWhiteSpace($ArgumentString)) { '' } else { " $ArgumentString" }

    $envLines = [System.Collections.Generic.List[string]]::new()
    foreach ($envName in @('TOOLKIT_ROOT', 'OFFLINE_WINDOWS_ROOT', 'OFFLINE_REGISTRY_LOADED', 'OFFLINE_DRIVERS_LOADED', 'CDE_ELEV_PID_DIR')) {
        $envValue = [Environment]::GetEnvironmentVariable($envName)
        if ([string]::IsNullOrWhiteSpace($envValue)) { continue }
        $escapedValue = $envValue.Replace("'", "''")
        $envLines.Add("`$env:$envName = '$escapedValue'") | Out-Null
    }
    $envPrefix = if ($envLines.Count -gt 0) { ($envLines -join "`n") + "`n" } else { '' }

    $targetScript = @"
`$ErrorActionPreference = 'Continue'
$envPrefix`$env:CDE_ELEVATED_PID_FILE = '$escapedPidFile'
`$global:LASTEXITCODE = 0
try {
    & '$escapedScript'$argSuffix
    `$code = if (`$null -ne `$LASTEXITCODE) { [int]`$LASTEXITCODE } else { 0 }
} catch {
    Write-Error `$_.Exception.Message
    `$code = 1
}
exit `$code
"@
    $targetEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($targetScript))

    $inner = @"
`$ErrorActionPreference = 'Continue'
$envPrefix`$env:CDE_ELEVATED_PID_FILE = '$escapedPidFile'
`$sync = New-Object object
`$errSync = New-Object object
`$utf8NoBom = New-Object System.Text.UTF8Encoding(`$false)
`$writer = New-Object System.IO.StreamWriter('$escapedLogFile', `$false, `$utf8NoBom)
`$writer.AutoFlush = `$true
`$errWriter = New-Object System.IO.StreamWriter('$escapedErrLogFile', `$false, `$utf8NoBom)
`$errWriter.AutoFlush = `$true
`$psi = New-Object System.Diagnostics.ProcessStartInfo
`$psi.FileName = 'powershell.exe'
`$psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $targetEncoded'
`$psi.UseShellExecute = `$false
`$psi.RedirectStandardOutput = `$true
`$psi.RedirectStandardError = `$true
`$psi.CreateNoWindow = `$true
`$psi.StandardOutputEncoding = `$utf8NoBom
`$psi.StandardErrorEncoding = `$utf8NoBom
`$proc = New-Object System.Diagnostics.Process
`$proc.StartInfo = `$psi
`$proc.EnableRaisingEvents = `$true
`$outSub = Register-ObjectEvent -InputObject `$proc -EventName OutputDataReceived -Action {
    if (`$null -ne `$EventArgs.Data) {
        [System.Threading.Monitor]::Enter(`$Event.MessageData.Sync)
        try { `$Event.MessageData.Writer.WriteLine(`$EventArgs.Data) } finally { [System.Threading.Monitor]::Exit(`$Event.MessageData.Sync) }
    }
} -MessageData @{ Sync = `$sync; Writer = `$writer }
`$errSub = Register-ObjectEvent -InputObject `$proc -EventName ErrorDataReceived -Action {
    if (`$null -ne `$EventArgs.Data) {
        [System.Threading.Monitor]::Enter(`$Event.MessageData.Sync)
        try { `$Event.MessageData.Writer.WriteLine(`$EventArgs.Data) } finally { [System.Threading.Monitor]::Exit(`$Event.MessageData.Sync) }
    }
} -MessageData @{ Sync = `$errSync; Writer = `$errWriter }
`$exitCode = 1
try {
    [void]`$proc.Start()
    Set-Content -LiteralPath '$escapedPidFile' -Value ([string]`$proc.Id) -Encoding ascii -Force -ErrorAction SilentlyContinue
    `$proc.BeginOutputReadLine()
    `$proc.BeginErrorReadLine()
    while (-not `$proc.WaitForExit(150)) {
        if (Test-Path -LiteralPath '$escapedCancelFile') {
            try { & taskkill.exe /PID `$proc.Id /T /F 2>`$null | Out-Null } catch { }
            try { `$proc.Kill() } catch { }
            break
        }
    }
    `$proc.WaitForExit()
    `$exitCode = if (Test-Path -LiteralPath '$escapedCancelFile') { 1 } else { [int]`$proc.ExitCode }
} finally {
    try { Unregister-Event -SourceIdentifier `$outSub.Name -ErrorAction SilentlyContinue } catch { }
    try { Unregister-Event -SourceIdentifier `$errSub.Name -ErrorAction SilentlyContinue } catch { }
    try { `$writer.Flush(); `$writer.Dispose() } catch { }
    try { `$errWriter.Flush(); `$errWriter.Dispose() } catch { }
    try { `$proc.Dispose() } catch { }
    Set-Content -LiteralPath '$escapedExitFile' -Value ([string]`$exitCode) -Encoding ascii -Force -ErrorAction SilentlyContinue
}
exit `$exitCode
"@

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
    $launchArgs = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"

    $byteOffset = [long]0
    $errByteOffset = [long]0
    $isConsoleHost = ($Host.Name -eq 'ConsoleHost')
    $emitStdoutLine = {
        param([string]$Line)
        if ($StreamToHost) {
            Write-Host $Line
        } elseif ($isConsoleHost) {
            [Console]::Out.WriteLine($Line)
        } else {
            Write-Output $Line
        }
    }
    $emitStderrLine = {
        param([string]$Line)
        if ([string]::IsNullOrWhiteSpace($Line)) { return }
        if ($StreamToHost) {
            Write-Host $Line
        } elseif ($isConsoleHost) {
            [Console]::Error.WriteLine($Line)
        } else {
            Write-Warning $Line
        }
    }
    $readAvailableLines = {
        param([bool]$FlushRemainder)
        if (Test-Path -LiteralPath $logFile) {
            try {
                $fs = [System.IO.FileStream]::new($logFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                try {
                    if ($fs.Length -gt $byteOffset) {
                        $remaining = [int]($fs.Length - $byteOffset)
                        $buf = New-Object byte[] $remaining
                        [void]$fs.Seek($byteOffset, [System.IO.SeekOrigin]::Begin)
                        $bytesRead = $fs.Read($buf, 0, $remaining)
                        if ($bytesRead -gt 0) {
                            $consumeCount = $bytesRead
                            if (-not $FlushRemainder) {
                                $lastLf = [Array]::LastIndexOf($buf, [byte]10, $bytesRead - 1)
                                if ($lastLf -ge 0) {
                                    $consumeCount = $lastLf + 1
                                } else {
                                    $consumeCount = 0
                                }
                            }
                            if ($consumeCount -gt 0) {
                                $chunk = [System.Text.Encoding]::UTF8.GetString($buf, 0, $consumeCount)
                                $byteOffset += $consumeCount
                                $lines = $chunk -split "\r?\n"
                                for ($i = 0; $i -lt $lines.Length; $i++) {
                                    if ($i -eq $lines.Length - 1 -and $lines[$i].Length -eq 0) { continue }
                                    & $emitStdoutLine $lines[$i]
                                }
                            }
                        }
                    }
                } finally {
                    $fs.Dispose()
                }
            } catch { }
        }
        if (Test-Path -LiteralPath $errLogFile) {
            try {
                $efs = [System.IO.FileStream]::new($errLogFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                try {
                    if ($efs.Length -gt $errByteOffset) {
                        $eremaining = [int]($efs.Length - $errByteOffset)
                        $ebuf = New-Object byte[] $eremaining
                        [void]$efs.Seek($errByteOffset, [System.IO.SeekOrigin]::Begin)
                        $ebytesRead = $efs.Read($ebuf, 0, $eremaining)
                        if ($ebytesRead -gt 0) {
                            $econsumeCount = $ebytesRead
                            if (-not $FlushRemainder) {
                                $elastLf = [Array]::LastIndexOf($ebuf, [byte]10, $ebytesRead - 1)
                                if ($elastLf -ge 0) {
                                    $econsumeCount = $elastLf + 1
                                } else {
                                    $econsumeCount = 0
                                }
                            }
                            if ($econsumeCount -gt 0) {
                                $echunk = [System.Text.Encoding]::UTF8.GetString($ebuf, 0, $econsumeCount)
                                $errByteOffset += $econsumeCount
                                $elines = $echunk -split "\r?\n"
                                for ($i = 0; $i -lt $elines.Length; $i++) {
                                    if ($i -eq $elines.Length - 1 -and $elines[$i].Length -eq 0) { continue }
                                    & $emitStderrLine $elines[$i]
                                }
                            }
                        }
                    }
                } finally {
                    $efs.Dispose()
                }
            } catch { }
        }
    }

    $child = $null
    $resolvedExitCode = 1
    try {
        $child = Start-Process -FilePath 'powershell.exe' -ArgumentList $launchArgs -Verb RunAs -PassThru -WindowStyle Hidden
        if ($null -eq $child) {
            throw "Elevation request was canceled or failed: no process started"
        }

        if (-not (Test-Path -LiteralPath $pidFile)) {
            Set-Content -LiteralPath $pidFile -Value ([string]$child.Id) -Encoding ascii -Force
        }

        while (-not $child.HasExited) {
            & $readAvailableLines $false
            Start-Sleep -Milliseconds 150
            try { $child.Refresh() } catch { }
        }
        $child.WaitForExit()
        try { $child.Refresh() } catch { }
        $resolvedExitCode = [int]$child.ExitCode
    } catch {
        throw "Elevation request was canceled or failed: $($_.Exception.Message)"
    } finally {
        & $readAvailableLines $true
        if (Test-Path -LiteralPath $exitFile) {
            $rawExit = (Get-Content -LiteralPath $exitFile -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($rawExit -match '^-?\d+$') {
                $resolvedExitCode = [int]$rawExit
            }
            Remove-Item -LiteralPath $exitFile -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $logFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $errLogFile -Force -ErrorAction SilentlyContinue
    }

    $resultObj = [PSCustomObject]@{
        Relayed  = $true
        ExitCode = $resolvedExitCode
        PidFile  = $pidFile
        Pid      = if ($null -ne $child) { $child.Id } else { $null }
    }
    if ($null -ne $RelayOut) {
        $RelayOut['Result'] = $resultObj
        return
    }
    return $resultObj
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

    $relayOut = @{}
    Invoke-ToolkitElevatedRelay -ScriptPath $ScriptPath -ArgumentString $ArgumentString -RelayOut $relayOut
    $relay = $relayOut['Result']
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
