#Requires -Version 5.1
<#
.SYNOPSIS
    Toolkit.Core.psm1 — Core module for Core Diagnostic Engine.
    Provides environment detection, logging, config, system info, and workflow runner.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# When running inside the GUI (PowerShell SDK in-process runspace), the Windows
# built-in module path is not automatically included.  Add it so CimCmdlets,
# NetTCPIP, and other Windows modules load correctly in both PS5 and PS7.
$_winModPath = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\Modules'
if ((Test-Path $_winModPath) -and ($env:PSModulePath -notlike "*$_winModPath*")) {
    $env:PSModulePath = $env:PSModulePath + [System.IO.Path]::PathSeparator + $_winModPath
}

#region ─── CONFIG ───────────────────────────────────────────────────────────

# Honor TOOLKIT_ROOT env var first (set by startnet.cmd in WinPE);
# fall back to deriving from $PSScriptRoot when running interactively.
if (-not [string]::IsNullOrWhiteSpace($env:TOOLKIT_ROOT) -and (Test-Path $env:TOOLKIT_ROOT)) {
    $Script:ToolkitRoot = $env:TOOLKIT_ROOT
} else {
    $Script:ToolkitRoot = $PSScriptRoot | Split-Path -Parent | Split-Path -Parent
}
$Script:ConfigPath     = Join-Path $Script:ToolkitRoot 'Config\settings.json'
$Script:LogsRoot           = Join-Path $Script:ToolkitRoot 'Logs'
$Script:InternalDataRoot    = Join-Path $Script:ToolkitRoot 'CDE\Runtime\Data\workflows'
$Script:InternalScansRoot   = Join-Path $Script:ToolkitRoot 'CDE\Runtime\Data\scans'
$Script:InternalCstRoot     = Join-Path $Script:ToolkitRoot 'CDE\Runtime\Data\cst'
$Script:InternalSessionsRoot = Join-Path $Script:ToolkitRoot 'CDE\Runtime\Data\sessions'
$Script:Config         = $null
$Script:SessionLogFile = $null
$Script:SessionTimestamp = $null

. (Join-Path $PSScriptRoot 'OfflineRuntime.ps1')
. (Join-Path $PSScriptRoot 'WorkOrder.ps1')

#endregion

#region ─── ENVIRONMENT ──────────────────────────────────────────────────────

function Get-EnvironmentMode {
    <#
    .SYNOPSIS Returns 'WinPE' or 'Windows' depending on the current boot environment.
    #>
    [OutputType([string])]
    param()

    # Primary: MiniNT key is present only in WinPE (not on a full Windows install).
    try {
        $val = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control' `
                                -Name 'MiniNT' -ErrorAction SilentlyContinue
        if ($null -ne $val) { return 'WinPE' }
    } catch {}

    # Fallback: SystemRoot on the X: ramdisk (aligns with GUI IsWinPeMode).
    $systemRoot = [string]$env:SystemRoot
    if ($systemRoot -match '^[Xx]:\\') {
        return 'WinPE'
    }

    # Do NOT treat "any X:\ volume exists" as WinPE — live Windows often has X: USB/secondary disks.
    return 'Windows'
}

function Normalize-OfflineWindowsRoot {
    <#
    .SYNOPSIS
        Normalizes a drive root (e.g. F: or F:\) and confirms Windows\ exists.
        Join-Path 'F:' 'Windows' resolves to F:Windows (wrong); always use F:\.
    #>
    param([string]$Root)

    if ([string]::IsNullOrWhiteSpace($Root)) { return '' }

    $trimmed = $Root.Trim()
    if ($trimmed -match '^([A-Za-z]):\\?$') {
        $trimmed = "$($matches[1]):\"
    }
    elseif (-not $trimmed.EndsWith('\')) {
        $trimmed += '\'
    }

    if (Test-Path -LiteralPath (Join-Path $trimmed 'Windows')) {
        return $trimmed
    }

    return ''
}

function Read-OfflineEnvValue {
    param([string]$Key)

    $envFile = Resolve-OfflineEnvFilePath -ToolkitRoot $Script:ToolkitRoot
    if (-not (Test-Path -LiteralPath $envFile)) { return '' }

    foreach ($line in Get-Content -LiteralPath $envFile -ErrorAction SilentlyContinue) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) { continue }
        $idx = $line.IndexOf('=')
        if ($idx -le 0) { continue }
        $k = $line.Substring(0, $idx).Trim()
        if ($k -ne $Key) { continue }
        return $line.Substring($idx + 1).Trim()
    }

    return ''
}

function Resolve-OfflineWindowsRoot {
    <#
    .SYNOPSIS
        Resolves the offline Windows installation root from env, CDE\Runtime\offline_env.txt,
        or (when Offline_SAM is loaded) a single detected Windows install.
    #>
    Sync-OfflineRegistryLoadedEnv | Out-Null

    $candidates = @(
        $env:OFFLINE_WINDOWS_ROOT
        (Read-OfflineEnvValue -Key 'OFFLINE_WINDOWS_ROOT')
    )

    foreach ($raw in $candidates) {
        $resolved = Normalize-OfflineWindowsRoot -Root $raw
        if (-not [string]::IsNullOrWhiteSpace($resolved)) {
            return $resolved
        }
    }

    if (Test-Path -LiteralPath 'HKLM:\Offline_SAM') {
        $installs = [System.Collections.Generic.List[string]]::new()
        for ($driveCode = [int][char]'C'; $driveCode -le [int][char]'Z'; $driveCode++) {
            $drive = ([char]$driveCode).ToString()
            if ($drive -eq 'X') { continue }
            $root = "$drive`:\"
            if (Test-Path -LiteralPath (Join-Path $root 'Windows\System32\config\SYSTEM')) {
                [void]$installs.Add($root)
            }
        }
        if ($installs.Count -eq 1) {
            return $installs[0]
        }
    }

    return ''
}

function Get-ToolkitHostsFilePath {
    <#
    .SYNOPSIS
        Resolves the hosts file for the running OS or an offline Windows installation.
    #>
    $offlineRoot = Resolve-OfflineWindowsRoot
    if (-not [string]::IsNullOrWhiteSpace($offlineRoot)) {
        return Join-Path ($offlineRoot.TrimEnd('\')) 'Windows\System32\drivers\etc\hosts'
    }

    return Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
}

#endregion

#region ─── CONFIG LOADER ─────────────────────────────────────────────────────

function Load-Config {
    <#
    .SYNOPSIS Loads settings.json into the module-level config variable.
    #>
    param(
        [string]$ConfigFile = $Script:ConfigPath
    )

    if (Test-Path $ConfigFile) {
        $Script:Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    } else {
        # Return defaults
        $Script:Config = [PSCustomObject]@{
            ToolkitRoot = $Script:ToolkitRoot
            LogsRoot    = $Script:LogsRoot
            ToolsRoot   = Join-Path $Script:ToolkitRoot 'Tools'
            LogLevel    = 'Info'
        }
    }
    return $Script:Config
}

#endregion

#region ─── LOGGING ───────────────────────────────────────────────────────────

function Initialize-SessionLog {
    <#
    .SYNOPSIS Creates a timestamped session log under CDE\Runtime\Data\sessions (not Logs — operator folder is PDF-only).
    #>
    param([string]$WorkflowName = 'Session')

    if (-not (Test-Path $Script:LogsRoot)) {
        New-Item -ItemType Directory -Force -Path $Script:LogsRoot | Out-Null
    }
    foreach ($internalDir in @(
            $Script:InternalDataRoot
            $Script:InternalScansRoot
            $Script:InternalCstRoot
            $Script:InternalSessionsRoot)) {
        if (-not (Test-Path $internalDir)) {
            New-Item -ItemType Directory -Force -Path $internalDir | Out-Null
        }
    }

    # Retention: keep the newest 50 session logs (cap is enough for light cleanup).
    try {
        $sessionFiles = @(Get-ChildItem -LiteralPath $Script:InternalSessionsRoot -Filter '*.log' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending)
        if ($sessionFiles.Count -gt 50) {
            $sessionFiles | Select-Object -Skip 50 | ForEach-Object {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {}

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $Script:SessionTimestamp = $timestamp
    $Script:SessionLogFile = Join-Path $Script:InternalSessionsRoot "$WorkflowName`_$timestamp.log"
    Write-Log "=== $WorkflowName log started ==="
    return $Script:SessionLogFile
}

function Get-SessionReportTimestamp {
    <#
    .SYNOPSIS Returns the yyyyMMdd_HHmmss stamp for the active workflow session log.
    #>
    if (-not [string]::IsNullOrWhiteSpace($Script:SessionTimestamp)) {
        return $Script:SessionTimestamp
    }
    return Get-Date -Format 'yyyyMMdd_HHmmss'
}

function Write-Log {
    <#
    .SYNOPSIS Writes a timestamped entry to the session log and the Information stream.
    #>
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info','Warning','Error','Success','Verbose')]
        [string]$Level = 'Info'
    )

    # Basic secret redaction (aligned with WorkflowViewModelBase AppendLog).
    $safeMessage = [regex]::Replace(
        [string]$Message,
        '\b(password|pwd|token|apikey|api_key|secret)\s*=\s*[^\s,;"'']+',
        {
            param($m)
            $eq = $m.Value.IndexOf('=')
            if ($eq -lt 0) { return $m.Value }
            return $m.Value.Substring(0, $eq + 1) + '***'
        },
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    $ts = Get-Date -Format 'HH:mm:ss'
    $line = "[$ts][$Level] $safeMessage"

    # Always write to PowerShell streams (GUI picks these up via stdout)
    switch ($Level) {
        'Warning' { Write-Warning $safeMessage }
        'Error'   { Write-Error   $safeMessage -ErrorAction Continue }
        default   { Write-Host $line }
    }

    # Persist to log file
    if ($Script:SessionLogFile) {
        try { Add-Content -Path $Script:SessionLogFile -Value $line } catch {}
    }
}

#endregion

#region ─── SYSTEM INFO ───────────────────────────────────────────────────────

function Format-CdeUptimeSpan {
    param([TimeSpan]$Span)
    '{0}d {1}h {2}m' -f [int]$Span.TotalDays, $Span.Hours, $Span.Minutes
}

function Get-CdeBootUptimeInfo {
    <#
    .SYNOPSIS
        Returns session uptime (OS LastBootUpTime) and cold-boot uptime (latest System 6005 or Kernel-General 12).
    #>
    [OutputType([PSCustomObject])]
    param()

    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $sessionBoot = $os.LastBootUpTime
    $now = Get-Date
    $sessionUptime = $now - $sessionBoot

    $coldBootTime = $sessionBoot
    $coldBootSource = 'OS LastBootUpTime (fallback)'

    try {
        $bootEvent = Get-WinEvent -FilterHashtable @{
            LogName = 'System'
            Id      = 6005
        } -MaxEvents 1 -ErrorAction Stop
        $coldBootTime = $bootEvent.TimeCreated
        $coldBootSource = 'System Event 6005'
    } catch {
        try {
            $kernelBoot = Get-WinEvent -FilterHashtable @{
                LogName      = 'System'
                ProviderName = 'Microsoft-Windows-Kernel-General'
                Id           = 12
            } -MaxEvents 1 -ErrorAction Stop
            $coldBootTime = $kernelBoot.TimeCreated
            $coldBootSource = 'Kernel-General Event 12'
        } catch {
            # Keep WMI session boot as fallback.
        }
    }

    $coldUptime = $now - $coldBootTime

    [PSCustomObject]@{
        SessionBootTime           = $sessionBoot
        SessionUptime             = $sessionUptime
        SessionUptimeFormatted    = Format-CdeUptimeSpan -Span $sessionUptime
        ColdBootTime              = $coldBootTime
        ColdBootSource            = $coldBootSource
        ColdBootUptime            = $coldUptime
        ColdBootUptimeFormatted   = Format-CdeUptimeSpan -Span $coldUptime
    }
}

function Get-SystemInfo {
    <#
    .SYNOPSIS Returns a structured PSCustomObject with key system details.
    #>
    [OutputType([PSCustomObject])]
    param()

    Write-Log "Collecting system information..."

    $os    = Get-CimInstance -ClassName Win32_OperatingSystem
    $cpu   = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
    $mem   = Get-CimInstance -ClassName Win32_PhysicalMemory
    $board = Get-CimInstance -ClassName Win32_BaseBoard
    $bios  = Get-CimInstance -ClassName Win32_BIOS
    $disks = Get-CimInstance -ClassName Win32_DiskDrive

    $totalRam = [math]::Round(($mem | Measure-Object -Property Capacity -Sum).Sum / 1GB, 2)
    $freeRam  = [math]::Round($os.FreePhysicalMemory / 1MB, 2)

    $bootInfo = Get-CdeBootUptimeInfo

    [PSCustomObject]@{
        MachineName     = $env:COMPUTERNAME
        UserName        = $env:USERNAME
        OsCaption       = $os.Caption
        OsVersion       = $os.Version
        OsBuildNumber   = $os.BuildNumber
        OsArchitecture  = $os.OSArchitecture
        LastBoot        = $bootInfo.SessionBootTime
        UptimeFormatted = $bootInfo.SessionUptimeFormatted
        SessionUptimeFormatted  = $bootInfo.SessionUptimeFormatted
        ColdBootUptimeFormatted = $bootInfo.ColdBootUptimeFormatted
        ColdBootSource          = $bootInfo.ColdBootSource

        CpuName         = $cpu.Name.Trim()
        CpuCores        = $cpu.NumberOfCores
        CpuThreads      = $cpu.NumberOfLogicalProcessors
        CpuLoad         = $cpu.LoadPercentage

        TotalRamGB      = $totalRam
        FreeRamGB       = $freeRam
        RamSlots        = ($mem | Measure-Object).Count

        Motherboard     = "$($board.Manufacturer) $($board.Product)"
        BiosVersion     = "$($bios.Manufacturer) $($bios.SMBIOSBIOSVersion)"

        Disks           = $disks | ForEach-Object {
            [PSCustomObject]@{
                Model       = $_.Model
                SizeGB      = [math]::Round($_.Size / 1GB, 1)
                Interface   = $_.InterfaceType
                SerialNumber= $_.SerialNumber.Trim()
            }
        }

        EnvironmentMode = Get-EnvironmentMode
    }
}

#endregion

#region ─── TOOL RUNNER ───────────────────────────────────────────────────────

function Invoke-Tool {
    <#
    .SYNOPSIS Runs an external tool from the Tools directory and returns output.
    #>
    param(
        [Parameter(Mandatory)][string]$ToolName,
        [string]$ToolSubfolder = '',
        [string[]]$Arguments   = @(),
        [int]$TimeoutSeconds   = 300
    )

    $toolsRoot = if ($Script:Config) { $Script:Config.ToolsRoot } else {
        Join-Path $Script:ToolkitRoot 'Tools'
    }

    $searchPath = if ($ToolSubfolder) {
        Join-Path $toolsRoot $ToolSubfolder
    } else { $toolsRoot }

    $exe = Get-ChildItem -Path $searchPath -Filter $ToolName -Recurse -ErrorAction SilentlyContinue |
           Select-Object -First 1

    if (-not $exe) {
        Write-Log "Tool not found: $ToolName in $searchPath" -Level Warning
        return $null
    }

    Write-Log "Invoking tool: $($exe.FullName) $Arguments"

    $proc = Start-Process -FilePath $exe.FullName -ArgumentList $Arguments `
                          -PassThru -NoNewWindow -RedirectStandardOutput "$env:TEMP\tool_stdout.txt" `
                          -RedirectStandardError "$env:TEMP\tool_stderr.txt"
    $proc.WaitForExit($TimeoutSeconds * 1000) | Out-Null

    $stdout = if (Test-Path "$env:TEMP\tool_stdout.txt") {
        Get-Content "$env:TEMP\tool_stdout.txt" -Raw
    } else { '' }

    return [PSCustomObject]@{
        ExitCode = $proc.ExitCode
        Stdout   = $stdout
        ToolName = $ToolName
    }
}

#endregion

#region ─── WORKFLOW RUNNER ───────────────────────────────────────────────────

function Start-Workflow {
    <#
    .SYNOPSIS Entry point for all workflow scripts. Handles environment checks and logging init.
    #>
    param(
        [Parameter(Mandatory)][string]$WorkflowName,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )

    $startTime = Get-Date
    $null = Initialize-SessionLog -WorkflowName $WorkflowName
    Write-Log "Workflow starting: $WorkflowName"
    Write-Log "Environment: $(Get-EnvironmentMode)"
    Write-Log "Machine: $env:COMPUTERNAME | User: $env:USERNAME"

    $result = [PSCustomObject]@{
        WorkflowName  = $WorkflowName
        StartTime     = $startTime
        EndTime       = $null
        DurationSec   = 0
        Status        = 'Running'
        EnvironmentMode = Get-EnvironmentMode
        Steps         = [System.Collections.Generic.List[object]]::new()
        Errors        = [System.Collections.Generic.List[string]]::new()
    }

    try {
        & $ScriptBlock $result
        $hasFailedStep = @($result.Steps | Where-Object { $_.Status -eq 'Fail' }).Count -gt 0
        if ($hasFailedStep) {
            $result.Status = 'Failed'
            Write-Log "Workflow completed with failed steps: $WorkflowName" -Level Warning
        } else {
            $result.Status = 'Completed'
            Write-Log "Workflow completed: $WorkflowName" -Level Success
        }
    } catch {
        $result.Status = 'Failed'
        $result.Errors.Add($_.Exception.Message)
        Write-Log "Workflow failed: $_" -Level Error
    } finally {
        $result.EndTime    = Get-Date
        $result.DurationSec = [math]::Round(($result.EndTime - $startTime).TotalSeconds, 1)
    }

    return $result
}

#endregion

#region ─── WORKFLOW HEALTH ─────────────────────────────────────────────────────

function Get-WorkflowStepCounts {
    param(
        [Parameter(Mandatory)]
        $Steps
    )

    $list = @($Steps)
    [PSCustomObject]@{
        Pass = @($list | Where-Object { $_.Status -eq 'Pass' }).Count
        Warn = @($list | Where-Object { $_.Status -eq 'Warn' }).Count
        Fail = @($list | Where-Object { $_.Status -eq 'Fail' }).Count
        Skip = @($list | Where-Object { $_.Status -eq 'Skip' }).Count
    }
}

function Get-WorkflowOverallHealth {
    param(
        [Parameter(Mandatory)]
        $Steps
    )

    $counts = Get-WorkflowStepCounts -Steps $Steps
    if ($counts.Fail -gt 0) { return 'Critical' }
    if ($counts.Warn -gt 0) { return 'Warning' }
    return 'Healthy'
}

function Set-WorkflowOverallHealth {
    param(
        [Parameter(Mandatory)]
        $WorkflowResult
    )

    $health = Get-WorkflowOverallHealth -Steps $WorkflowResult.Steps
    $WorkflowResult | Add-Member -NotePropertyName OverallHealth -NotePropertyValue $health -Force
    return $health
}

function Group-WorkflowEvents {
    param(
        [Parameter(Mandatory)]
        $Events
    )

    $list = @($Events)
    if ($list.Count -eq 0) {
        return @()
    }

    $groups = $list | Group-Object -Property ProviderName, Id
    $result = foreach ($group in $groups) {
        $sample = $group.Group | Select-Object -First 1
        $message = [string]$sample.Message
        if ($message.Length -gt 200) {
            $message = $message.Substring(0, 200) + '...'
        }

        $latest = ($group.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated

        [PSCustomObject]@{
            ProviderName  = $sample.ProviderName
            Id            = $sample.Id
            Count         = $group.Count
            SampleMessage = $message
            LatestTime    = $latest
        }
    }

    return @($result | Sort-Object Count -Descending)
}

function Format-WorkflowEventSummaryText {
    param(
        [Parameter(Mandatory)]
        $EventSummary,
        [int]$EventCount = 0,
        [int]$TopN = 5
    )

    $groups = @($EventSummary)
    if ($groups.Count -eq 0) {
        return if ($EventCount -gt 0) { "$EventCount event(s)" } else { 'No critical/error events' }
    }

    $topParts = @($groups | Select-Object -First $TopN | ForEach-Object {
        "$($_.ProviderName) Id $($_.Id) x$($_.Count)"
    })
    $summary = "$EventCount event(s) ($($groups.Count) group(s)). Top: $($topParts -join ', ')"
    if ($groups.Count -gt $TopN) {
        $summary += " (+$($groups.Count - $TopN) more)"
    }
    return $summary
}

#endregion

#region ─── REPORTING ─────────────────────────────────────────────────────────

function ConvertTo-HtmlEncodedText {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function Test-JsonProperty {
    param(
        $Object,
        [string]$Name
    )

    return ($null -ne $Object) -and ($Object.PSObject.Properties.Name -contains $Name)
}

function Get-JsonPropertyValue {
    param(
        $Object,
        [string]$Name,
        $Default = $null
    )

    if (-not (Test-JsonProperty -Object $Object -Name $Name)) {
        return $Default
    }

    return $Object.$Name
}

function Get-WorkflowStatusBarSvg {
    param(
        [int]$Pass,
        [int]$Warn,
        [int]$Fail,
        [int]$Skip,
        [int]$Other = 0
    )

    $total = $Pass + $Warn + $Fail + $Skip + $Other
    if ($total -le 0) {
        return '<svg width="520" height="24" xmlns="http://www.w3.org/2000/svg"><rect width="520" height="24" fill="#E5E7EB" rx="4"/></svg>'
    }

    $width = 520.0
    $x = 0.0
    $segments = @(
        @{ Count = $Pass; Color = '#0D7A3E' }
        @{ Count = $Warn; Color = '#D29922' }
        @{ Count = $Fail; Color = '#C42B1C' }
        @{ Count = ($Skip + $Other); Color = '#9CA3AF' }
    )

    $rects = ''
    foreach ($seg in $segments) {
        if ($seg.Count -le 0) { continue }
        $segWidth = [math]::Round(($seg.Count / $total) * $width, 2)
        if ($segWidth -lt 1) { $segWidth = 1 }
        $rects += "<rect x='$x' y='0' width='$segWidth' height='24' fill='$($seg.Color)' />"
        $x += $segWidth
    }

    return "<svg width='520' height='24' xmlns='http://www.w3.org/2000/svg'>$rects</svg>"
}

function Format-WorkflowHtmlReport {
    param(
        [Parameter(Mandatory)]$WorkflowResult
    )

    $steps = @($WorkflowResult.Steps)
    $counts = Get-WorkflowStepCounts -Steps $steps
    $overallHealthValue = Get-JsonPropertyValue -Object $WorkflowResult -Name 'OverallHealth'
    $overall = if (-not [string]::IsNullOrWhiteSpace([string]$overallHealthValue)) {
        [string]$overallHealthValue
    } else {
        Get-WorkflowOverallHealth -Steps $steps
    }

    $healthClass = switch ($overall) {
        'Critical' { 'err' }
        'Warning'  { 'warn' }
        default    { 'ok' }
    }

    $workflowName = [string](Get-JsonPropertyValue -Object $WorkflowResult -Name 'WorkflowName' -Default 'Workflow')
    $status = [string](Get-JsonPropertyValue -Object $WorkflowResult -Name 'Status' -Default '')
    $duration = Get-JsonPropertyValue -Object $WorkflowResult -Name 'DurationSec'
    $environment = [string](Get-JsonPropertyValue -Object $WorkflowResult -Name 'EnvironmentMode' -Default '')
    $startTime = Get-JsonPropertyValue -Object $WorkflowResult -Name 'StartTime'
    $endTime = Get-JsonPropertyValue -Object $WorkflowResult -Name 'EndTime'
    $caseId = [string](Get-JsonPropertyValue -Object $WorkflowResult -Name 'CaseId' -Default '')

    $barSvg = Get-WorkflowStatusBarSvg -Pass $counts.Pass -Warn $counts.Warn -Fail $counts.Fail -Skip $counts.Skip

    $stepRows = ''
    foreach ($step in $steps) {
        $stepName = [string](Get-JsonPropertyValue -Object $step -Name 'Name' -Default 'Step')
        $stepStatus = [string](Get-JsonPropertyValue -Object $step -Name 'Status' -Default '')
        $stepOutput = Get-JsonPropertyValue -Object $step -Name 'Output'
        $stepDetail = Get-JsonPropertyValue -Object $step -Name 'Detail'
        $detailText = if (-not [string]::IsNullOrWhiteSpace([string]$stepOutput)) { [string]$stepOutput } else { [string]$stepDetail }
        $statusClass = switch ($stepStatus) {
            'Fail' { 'err' }
            'Warn' { 'warn' }
            'Pass' { 'ok' }
            default { 'meta' }
        }
        $encodedDetail = (ConvertTo-HtmlEncodedText -Text $detailText) -replace "`r?`n", '<br/>'
        $stepRows += @"
<tr>
  <td>$(ConvertTo-HtmlEncodedText -Text $stepName)</td>
  <td class="$statusClass">$(ConvertTo-HtmlEncodedText -Text $stepStatus)</td>
  <td class="detail">$encodedDetail</td>
</tr>
"@
    }

    if (-not $stepRows) {
        $stepRows = '<tr><td colspan="3">No steps recorded.</td></tr>'
    }

    $errorBlock = ''
    $errors = @($WorkflowResult.Errors | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($errors.Count -gt 0) {
        $errorItems = ($errors | ForEach-Object { "<li>$(ConvertTo-HtmlEncodedText -Text ([string]$_))</li>" }) -join ''
        $errorBlock = @"
<h2>Errors</h2>
<ul class="errors">$errorItems</ul>
"@
    }

    $caseHtml = if ([string]::IsNullOrWhiteSpace($caseId)) { '' } else { "<p><strong>Case ID:</strong> $(ConvertTo-HtmlEncodedText -Text $caseId)</p>" }

    return @"
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8"/>
<title>CDE $workflowName Report</title>
<style>
  body { background:#f4f7fb; color:#1b2b40; font-family:Segoe UI,sans-serif; margin:0; }
  .wrap { max-width:980px; margin:0 auto; padding:32px 24px 48px; }
  .hero { background:linear-gradient(135deg,#0078d4,#005a9e); color:#fff; border-radius:12px; padding:24px 28px; }
  .hero h1 { margin:0 0 8px; font-size:28px; }
  .hero .sub { color:#d6ecff; font-size:13px; }
  .badge { display:inline-block; padding:6px 12px; border-radius:999px; font-weight:600; font-size:12px; margin-top:12px; }
  .badge.ok { background:#0d7a3e; }
  .badge.warn { background:#926800; }
  .badge.err { background:#c42b1c; }
  .cards { display:grid; grid-template-columns:repeat(auto-fit,minmax(140px,1fr)); gap:12px; margin:20px 0; }
  .card { background:#fff; border:1px solid #e1e6ef; border-radius:10px; padding:14px; }
  .card .label { font-size:11px; text-transform:uppercase; letter-spacing:.04em; color:#5a6b80; }
  .card .value { font-size:20px; font-weight:700; margin-top:6px; }
  h2 { color:#37475f; font-size:13px; text-transform:uppercase; letter-spacing:1px; margin:28px 0 10px; }
  table { width:100%; border-collapse:collapse; background:#fff; border:1px solid #e1e6ef; border-radius:10px; overflow:hidden; }
  th, td { border-bottom:1px solid #edf1f6; padding:10px 12px; text-align:left; vertical-align:top; }
  th { background:#f3f6fa; font-size:11px; text-transform:uppercase; letter-spacing:.04em; color:#5a6b80; }
  td.detail { font-family:Consolas,monospace; font-size:12px; white-space:normal; }
  .ok { color:#0d7a3e; font-weight:600; }
  .warn { color:#926800; font-weight:600; }
  .err { color:#c42b1c; font-weight:600; }
  .meta { color:#6b7280; }
  .legend { display:flex; gap:16px; flex-wrap:wrap; margin-top:10px; font-size:12px; }
  .legend span::before { content:''; display:inline-block; width:10px; height:10px; margin-right:6px; border-radius:2px; vertical-align:middle; }
  .legend .p::before { background:#0d7a3e; }
  .legend .w::before { background:#d29922; }
  .legend .f::before { background:#c42b1c; }
  .legend .s::before { background:#9ca3af; }
  ul.errors { background:#fff5f4; border:1px solid #f2c7c2; border-radius:8px; padding:12px 12px 12px 28px; }
  .footer { margin-top:28px; color:#6b7280; font-size:12px; }
</style>
</head>
<body>
<div class="wrap">
  <div class="hero">
    <div class="sub">Core Diagnostic Engine</div>
    <h1>$(ConvertTo-HtmlEncodedText -Text $workflowName) Report</h1>
    <div class="sub">Machine: <strong>$env:COMPUTERNAME</strong> · User: $env:USERNAME · Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')</div>
    <span class="badge $healthClass">$(ConvertTo-HtmlEncodedText -Text $overall)</span>
  </div>
  $caseHtml
  <div class="cards">
    <div class="card"><div class="label">Duration</div><div class="value">${duration}s</div></div>
    <div class="card"><div class="label">Environment</div><div class="value">$(ConvertTo-HtmlEncodedText -Text $environment)</div></div>
    <div class="card"><div class="label">Workflow status</div><div class="value">$(ConvertTo-HtmlEncodedText -Text $status)</div></div>
    <div class="card"><div class="label">Steps</div><div class="value">$($steps.Count)</div></div>
    <div class="card"><div class="label">Pass / Warn / Fail</div><div class="value">$($counts.Pass) / $($counts.Warn) / $($counts.Fail)</div></div>
  </div>
  <h2>Step status overview</h2>
  $barSvg
  <div class="legend">
    <span class="p">Pass: $($counts.Pass)</span>
    <span class="w">Warn: $($counts.Warn)</span>
    <span class="f">Fail: $($counts.Fail)</span>
    <span class="s">Skip/Other: $($counts.Skip)</span>
  </div>
  <h2>Detailed results</h2>
  <table>
    <tr><th>Step</th><th>Status</th><th>Output</th></tr>
    $stepRows
  </table>
  $errorBlock
  <p class="footer">Start: $startTime · End: $endTime · Open the PDF report in CDE for a printable deliverable.</p>
</div>
</body>
</html>
"@
}

function Generate-Report {
    <#
    .SYNOPSIS Saves structured workflow data internally and returns the operator PDF path under Logs.
    #>
    param(
        [Parameter(Mandatory)]$WorkflowResult,
        [string]$OutputDir = $Script:InternalDataRoot,
        [switch]$IncludeHtml,
        [string]$ReportTimestamp = ''
    )

    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    }
    if (-not (Test-Path $Script:LogsRoot)) {
        New-Item -ItemType Directory -Force -Path $Script:LogsRoot | Out-Null
    }

    $ts = if (-not [string]::IsNullOrWhiteSpace($ReportTimestamp)) {
        $ReportTimestamp
    } elseif (-not [string]::IsNullOrWhiteSpace($Script:SessionTimestamp)) {
        $Script:SessionTimestamp
    } else {
        Get-Date -Format 'yyyyMMdd_HHmmss'
    }
    $baseName   = "$($WorkflowResult.WorkflowName)_$ts"
    $jsonPath   = Join-Path $OutputDir "$baseName.json"
    $htmlPath   = Join-Path $OutputDir "$baseName.html"
    $writeHtml  = [bool]$IncludeHtml

    # JSON export — convert DateTime fields to ISO 8601 strings so System.Text.Json
    # can deserialize them correctly regardless of whether the script ran under PS5 or PS7.
    $exportProps = [ordered]@{
        WorkflowName    = $WorkflowResult.WorkflowName
        StartTime       = if ($WorkflowResult.StartTime) { $WorkflowResult.StartTime.ToString('o') } else { $null }
        EndTime         = if ($WorkflowResult.EndTime)   { $WorkflowResult.EndTime.ToString('o')   } else { $null }
        DurationSec     = $WorkflowResult.DurationSec
        Status          = $WorkflowResult.Status
        EnvironmentMode = $WorkflowResult.EnvironmentMode
        Steps           = $WorkflowResult.Steps
        Errors          = $WorkflowResult.Errors
    }
    if ($WorkflowResult.PSObject.Properties.Name -contains 'OverallHealth' -and
        -not [string]::IsNullOrWhiteSpace([string]$WorkflowResult.OverallHealth)) {
        $exportProps['OverallHealth'] = [string]$WorkflowResult.OverallHealth
    }

    $activePointer = $null
    if (Get-Command Get-ActiveWorkOrderPointer -ErrorAction SilentlyContinue) {
        $activePointer = Get-ActiveWorkOrderPointer
    }
    if ($activePointer -and -not [string]::IsNullOrWhiteSpace($activePointer.CaseId)) {
        $exportProps['CaseId'] = [string]$activePointer.CaseId
    }

    $exportObj = [PSCustomObject]$exportProps
    $exportObj | ConvertTo-Json -Depth 10 | Set-Content -Path $jsonPath -Encoding UTF8
    Write-Log "Report saved: $jsonPath"

    if (Get-Command Add-WorkOrderRun -ErrorAction SilentlyContinue) {
        $workOrderHtmlPath = if ($writeHtml) { $htmlPath } else { $null }
        Add-WorkOrderRun -WorkflowResult $WorkflowResult -ReportJsonPath $jsonPath -ReportHtmlPath $workOrderHtmlPath | Out-Null
    }

    if ($writeHtml) {
        $html = Format-WorkflowHtmlReport -WorkflowResult $WorkflowResult
        Set-Content -Path $htmlPath -Value $html -Encoding UTF8
        Write-Log "HTML report saved: $htmlPath"
    }

    $pdfPath = Join-Path $Script:LogsRoot "$baseName.pdf"

    return [PSCustomObject]@{
        JsonPath = $jsonPath
        HtmlPath = if ($writeHtml) { $htmlPath } else { $null }
        PdfPath  = $pdfPath
    }
}

#endregion

#region ─── FORMATTERS FOR AUDIT OUTPUT ──────────────────────────────────────

function Format-GroupedBlockHeader {
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][string]$Title
    )

    $safeTitle = if ($Title.Length -gt 72) { $Title.Substring(0, 72) } else { [string]$Title }
    $header = "$Kind $Index : $safeTitle"
    $separator = '-' * [Math]::Min(72, [Math]::Max(8, $header.Length))
    return "$header`n$separator`n"
}

function Format-GroupedPropertyLine {
    param(
        [Parameter(Mandatory)][string]$Label,
        $Value
    )

    $displayValue = if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { 'Unknown' } else { [string]$Value }
    return ("{0,-24}: {1}" -f $Label, $displayValue)
}

function Format-SizeHuman {
    <#
    .SYNOPSIS Format byte counts into B/KB/MB/GB/TB using 1024-based units.
    #>
    param([Parameter(Mandatory)][long]$Bytes)

    if ($Bytes -lt 0) { $Bytes = 0 }

    $units = @('B', 'KB', 'MB', 'GB', 'TB')
    $value = [double]$Bytes
    $unitIndex = 0
    while ($value -ge 1024 -and $unitIndex -lt ($units.Count - 1)) {
        $value /= 1024
        $unitIndex++
    }

    $decimals = if ($unitIndex -le 1) { 0 } else { 1 }
    return ('{0:N' + $decimals + '} {1}') -f $value, $units[$unitIndex]
}

function Format-SystemDetail {
    <#
    .SYNOPSIS Format system information into readable diagnostic output.
    #>
    param(
        [Parameter(Mandatory)]$Os,
        [Parameter(Mandatory)]$Cpu,
        [Parameter(Mandatory)]$Motherboard
    )

    $bootInfo = Get-CdeBootUptimeInfo
    $totalRamBytes = [long]$os.TotalVisibleMemorySize * 1KB
    $freeRamBytes  = [long]$os.FreePhysicalMemory * 1KB
    $totalRam      = Format-SizeHuman -Bytes $totalRamBytes
    $freeRam       = Format-SizeHuman -Bytes $freeRamBytes
    $usedPct       = [math]::Round((($totalRamBytes - $freeRamBytes) / [math]::Max($totalRamBytes, 1) * 100), 1)

    $output = "SYSTEM INFORMATION`n"
    $output += "==================`n`n"
    $output += Format-GroupedBlockHeader -Kind 'SUMMARY' -Index 1 -Title 'System Overview'
    $output += (Format-GroupedPropertyLine -Label 'Computer Name' -Value $env:COMPUTERNAME) + "`n"
    $output += (Format-GroupedPropertyLine -Label 'User' -Value $env:USERNAME) + "`n"
    $output += (Format-GroupedPropertyLine -Label 'OS' -Value $os.Caption) + "`n"
    $output += (Format-GroupedPropertyLine -Label 'OS Version' -Value $os.Version) + "`n"
    $output += (Format-GroupedPropertyLine -Label 'OS Build' -Value $os.BuildNumber) + "`n"
    $output += (Format-GroupedPropertyLine -Label 'Architecture' -Value $os.OSArchitecture) + "`n"
    $output += (Format-GroupedPropertyLine -Label 'Session Uptime' -Value "$($bootInfo.SessionUptimeFormatted) (OS LastBootUpTime)") + "`n"
    $output += (Format-GroupedPropertyLine -Label 'System Boot Uptime' -Value "$($bootInfo.ColdBootUptimeFormatted) ($($bootInfo.ColdBootSource))") + "`n`n"

    $cpuTitle = if ($cpu.Name) { [string]$cpu.Name.Trim() } else { 'Processor' }
    $output += Format-GroupedBlockHeader -Kind 'PROCESSOR' -Index 1 -Title $cpuTitle
    $output += (Format-GroupedPropertyLine -Label 'Cores' -Value $cpu.NumberOfCores) + "`n"
    $output += (Format-GroupedPropertyLine -Label 'Logical Processors' -Value $cpu.NumberOfLogicalProcessors) + "`n"
    $output += (Format-GroupedPropertyLine -Label 'Current Load' -Value "$($cpu.LoadPercentage)%") + "`n`n"

    $output += Format-GroupedBlockHeader -Kind 'MEMORY' -Index 1 -Title 'Physical Memory'
    $output += (Format-GroupedPropertyLine -Label 'Total RAM' -Value $totalRam) + "`n"
    $output += (Format-GroupedPropertyLine -Label 'Free RAM' -Value $freeRam) + "`n"
    $output += (Format-GroupedPropertyLine -Label 'RAM Used %' -Value "$usedPct%") + "`n`n"

    $boardTitle = "$($motherboard.Manufacturer) $($motherboard.Product)".Trim()
    if ([string]::IsNullOrWhiteSpace($boardTitle)) { $boardTitle = 'Motherboard' }
    $output += Format-GroupedBlockHeader -Kind 'BOARD' -Index 1 -Title $boardTitle
    $output += (Format-GroupedPropertyLine -Label 'Manufacturer' -Value $motherboard.Manufacturer) + "`n"
    $output += (Format-GroupedPropertyLine -Label 'Product' -Value $motherboard.Product) + "`n"

    return $output
}

function Format-SoftwareList {
    <#
    .SYNOPSIS Format installed software into readable list.
    #>
    param([Parameter(Mandatory)]$Software)

    $output = "INSTALLED APPLICATIONS`n"
    $output += "======================`n`n"
    $output += "Total Programs: $($Software.Count)`n`n"

    if ($Software.Count -gt 0) {
        $programIndex = 0
        foreach ($app in $Software) {
            $programIndex++
            $nameRaw = [string]$app.DisplayName
            $verRaw  = [string]$app.DisplayVersion
            $pubRaw  = [string]$app.Publisher
            $pathRaw = Resolve-InstalledSoftwarePath -App $app
            $dateRaw = Format-RegistryInstallDate -InstallDate ([string]$app.InstallDate)

            $title = if ($nameRaw.Length -gt 72) { $nameRaw.Substring(0, 72) } else { $nameRaw }
            $output += Format-GroupedBlockHeader -Kind 'PROGRAM' -Index $programIndex -Title $title
            $output += (Format-GroupedPropertyLine -Label 'Version' -Value $verRaw) + "`n"
            $output += (Format-GroupedPropertyLine -Label 'Publisher' -Value $pubRaw) + "`n"
            $output += (Format-GroupedPropertyLine -Label 'Install Path' -Value $pathRaw) + "`n"
            $output += (Format-GroupedPropertyLine -Label 'Installed On' -Value $dateRaw) + "`n`n"
        }
    }
    return $output
}

function Format-DriversList {
    <#
    .SYNOPSIS Format drivers list with state information.
    #>
    param([Parameter(Mandatory)]$Drivers, [Parameter(Mandatory)]$Stopped)

    $output = "SYSTEM DRIVERS`n"
    $output += "==============`n`n"
    $output += "Total Drivers           : $($Drivers.Count)`n"
    $output += "Auto-Start Stopped      : $($Stopped.Count)`n`n"

    $driverIndex = 0
    foreach ($driver in $Drivers | Sort-Object DisplayName) {
        $driverIndex++
        $name = if ($driver.DisplayName) { [string]$driver.DisplayName } else { [string]$driver.Name }
        $title = if ($name.Length -gt 72) { $name.Substring(0, 72) } else { $name }
        $flagged = ($driver.State -ne 'Running' -and $driver.StartMode -eq 'Auto')
        if ($flagged) { $title = "[!] $title" }

        $output += Format-GroupedBlockHeader -Kind 'DRIVER' -Index $driverIndex -Title $title
        $output += (Format-GroupedPropertyLine -Label 'State' -Value $driver.State) + "`n"
        $output += (Format-GroupedPropertyLine -Label 'Start Mode' -Value $driver.StartMode) + "`n"
        $output += (Format-GroupedPropertyLine -Label 'Flagged' -Value ($(if ($flagged) { 'Yes - auto-start but not running' } else { 'No' }))) + "`n`n"
    }

    return $output
}

function Format-PnPDeviceList {
    <#
    .SYNOPSIS Format PnP device list with error highlighting.
    #>
    param(
        [Parameter(Mandatory)]$Devices,
        [Parameter(Mandatory)]$Problems,
        [int]$ExcludedCount = 0
    )

    $output = "PLUG AND PLAY DEVICES`n"
    $output += "====================`n`n"
    $output += "Scope: Present devices only; excludes VSS shadow copies, firmware, and virtual devices.`n`n"
    $output += "Devices in scope: $($Devices.Count)`n"
    if ($ExcludedCount -gt 0) {
        $output += "Present devices excluded from scope: $ExcludedCount`n"
    }
    $output += "Devices needing attention: $($Problems.Count)`n`n"

    if ($Problems.Count -gt 0) {
        $deviceIndex = 0
        foreach ($dev in $Problems | Sort-Object FriendlyName) {
            $deviceIndex++
            $title = if ($dev.FriendlyName) { [string]$dev.FriendlyName } else { 'Unknown device' }
            if ($title.Length -gt 72) { $title = $title.Substring(0, 72) }
            $output += Format-GroupedBlockHeader -Kind 'DEVICE' -Index $deviceIndex -Title "[!] $title"
            $output += (Format-GroupedPropertyLine -Label 'Status' -Value $dev.Status) + "`n"
            $output += (Format-GroupedPropertyLine -Label 'Class' -Value $dev.Class) + "`n"
            if ($dev.PSObject.Properties['Problem'] -and $null -ne $dev.Problem) {
                $output += (Format-GroupedPropertyLine -Label 'Problem' -Value $dev.Problem) + "`n"
            }
            $output += "`n"
        }
    } else {
        $output += "No present in-scope devices report Error, Degraded, or a config-manager problem code.`n"
    }

    return $output
}

function Format-ServicesList {
    <#
    .SYNOPSIS Format services list with start type and status.
    #>
    param([Parameter(Mandatory)]$Services, [Parameter(Mandatory)]$Stopped)

    $output = "WINDOWS SERVICES (Auto-Start)`n"
    $output += "=============================`n`n"
    $output += "Total Auto-Start Services : $($Services.Count)`n"
    $output += "Currently Stopped         : $($Stopped.Count)`n`n"

    $serviceIndex = 0
    foreach ($svc in $Services | Sort-Object DisplayName) {
        $serviceIndex++
        $name = if ($svc.DisplayName) { [string]$svc.DisplayName } else { [string]$svc.Name }
        $title = if ($name.Length -gt 72) { $name.Substring(0, 72) } else { $name }
        $flagged = ($svc.Status -ne 'Running')
        if ($flagged) { $title = "[!] $title" }

        $output += Format-GroupedBlockHeader -Kind 'SERVICE' -Index $serviceIndex -Title $title
        $output += (Format-GroupedPropertyLine -Label 'Status' -Value $svc.Status) + "`n"
        $output += (Format-GroupedPropertyLine -Label 'Start Type' -Value $svc.StartType) + "`n"
        $output += (Format-GroupedPropertyLine -Label 'Flagged' -Value ($(if ($flagged) { 'Yes - auto-start but stopped' } else { 'No' }))) + "`n`n"
    }

    return $output
}

function Format-NetworkConfig {
    <#
    .SYNOPSIS Format network configuration like ipconfig /all output.
    #>
    param([Parameter(Mandatory)]$IpConfig)

    $output = "NETWORK CONFIGURATION`n"
    $output += "=====================`n`n"
    $output += "Total Interfaces        : $($IpConfig.Count)`n`n"

    $interfaceIndex = 0
    foreach ($nic in $IpConfig) {
        $interfaceIndex++
        $alias = if ($nic.InterfaceAlias) { [string]$nic.InterfaceAlias } else { "Interface $interfaceIndex" }
        $title = if ($alias.Length -gt 72) { $alias.Substring(0, 72) } else { $alias }
        $output += Format-GroupedBlockHeader -Kind 'INTERFACE' -Index $interfaceIndex -Title $title
        $output += (Format-GroupedPropertyLine -Label 'Description' -Value $nic.InterfaceDescription) + "`n"
        $mac = (Get-NetAdapter -InterfaceAlias $nic.InterfaceAlias -ErrorAction SilentlyContinue).MacAddress
        $output += (Format-GroupedPropertyLine -Label 'Physical Address' -Value $mac) + "`n"

        if ($nic.IPv4Address) {
            $ipv4 = $nic.IPv4Address | Select-Object -First 1
            $output += (Format-GroupedPropertyLine -Label 'IPv4 Address' -Value $ipv4.IPAddress) + "`n"
            $output += (Format-GroupedPropertyLine -Label 'Subnet Prefix' -Value $ipv4.PrefixLength) + "`n"
        }

        if ($nic.IPv4DefaultGateway) {
            $gw = $nic.IPv4DefaultGateway | Select-Object -First 1
            $output += (Format-GroupedPropertyLine -Label 'Default Gateway' -Value $gw.NextHop) + "`n"
        }

        if ($nic.DNSServer) {
            $dnsStr = ($nic.DNSServer | ForEach-Object { $_.ServerAddresses } | Select-Object -First 3) -join ', '
            $output += (Format-GroupedPropertyLine -Label 'DNS Servers' -Value $dnsStr) + "`n"
        }

        $output += "`n"
    }

    return $output
}

function Convert-CdeWmiDate {
    param([AllowNull()][string]$WmiDate)
    if ([string]::IsNullOrWhiteSpace($WmiDate)) { return 'Unknown' }
    try {
        return [Management.ManagementDateTimeConverter]::ToDateTime($WmiDate).ToString('yyyy-MM-dd')
    } catch {
        return $WmiDate
    }
}

function Format-RegistryInstallDate {
    param([AllowNull()][string]$InstallDate)
    if ([string]::IsNullOrWhiteSpace($InstallDate)) { return 'Unknown' }

    $raw = [string]$InstallDate
    if ($raw -match '^\d{8}$') {
        return "{0}-{1}-{2}" -f $raw.Substring(0, 4), $raw.Substring(4, 2), $raw.Substring(6, 2)
    }

    return (Convert-CdeWmiDate -WmiDate $raw)
}

function Resolve-InstalledSoftwarePath {
    param($App)

    $location = if ($App.PSObject.Properties['InstallLocation'] -and $App.InstallLocation) {
        [string]$App.InstallLocation.Trim().TrimEnd('\')
    } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($location)) {
        return $location
    }

    $candidates = @()
    if ($App.PSObject.Properties['DisplayIcon'] -and $App.DisplayIcon) {
        $candidates += [PSCustomObject]@{ Kind = 'Icon'; Value = [string]$App.DisplayIcon }
    }
    if ($App.PSObject.Properties['UninstallString'] -and $App.UninstallString) {
        $candidates += [PSCustomObject]@{ Kind = 'Uninstall'; Value = [string]$App.UninstallString }
    }

    foreach ($candidate in $candidates) {
        $raw = $candidate.Value
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }

        $text = [string]$raw
        if ($text.StartsWith('"')) {
            $end = $text.IndexOf('"', 1)
            if ($end -gt 1) {
                $text = $text.Substring(1, $end - 1)
            }
        } elseif ($candidate.Kind -eq 'Uninstall') {
            $text = ($text -split '\s+', 2)[0]
        }

        $text = $text -replace ',\d+$', ''
        if ($text -match '[\\/]') {
            $parent = Split-Path $text -Parent -ErrorAction SilentlyContinue
            if (-not [string]::IsNullOrWhiteSpace($parent)) {
                return $parent.TrimEnd('\')
            }
        }
    }

    return 'Unknown'
}

function Format-HealthCheckOsVersion {
    param([Parameter(Mandatory)]$Os)
    $installDate = Convert-CdeWmiDate -WmiDate ([string]$Os.InstallDate)

    $output = "OPERATING SYSTEM`n"
    $output += "================`n`n"
    $output += Format-GroupedBlockHeader -Kind 'SUMMARY' -Index 1 -Title 'Operating System'
    $output += (Format-GroupedPropertyLine -Label 'Edition' -Value $Os.Caption) + "`n"
    $output += (Format-GroupedPropertyLine -Label 'Version' -Value $Os.Version) + "`n"
    $output += (Format-GroupedPropertyLine -Label 'Build' -Value $Os.BuildNumber) + "`n"
    $output += (Format-GroupedPropertyLine -Label 'Architecture' -Value $Os.OSArchitecture) + "`n"
    $output += (Format-GroupedPropertyLine -Label 'Install Date' -Value $installDate) + "`n"
    $output += (Format-GroupedPropertyLine -Label 'Registered Owner' -Value $Os.RegisteredUser) + "`n"
    $output += (Format-GroupedPropertyLine -Label 'System Directory' -Value $Os.SystemDirectory) + "`n"
    $output += (Format-GroupedPropertyLine -Label 'Last Boot (OS reported)' -Value $Os.LastBootUpTime) + "`n"
    return $output
}

function Format-HealthCheckCpuLoad {
    param([Parameter(Mandatory)]$Processors)
    $procList = @($Processors)
    $loads = @($procList | ForEach-Object { [int]($_.LoadPercentage) })
    $avg = if ($loads.Count -gt 0) { [math]::Round(($loads | Measure-Object -Average).Average, 1) } else { 0 }
    $max = if ($loads.Count -gt 0) { ($loads | Measure-Object -Maximum).Maximum } else { 0 }

    $output = "PROCESSOR LOAD`n"
    $output += "==============`n`n"
    if ($procList.Count -gt 0) {
        $first = $procList | Select-Object -First 1
        $cpuTitle = if ($first.Name) { [string]$first.Name.Trim() } else { 'Processor' }
        $output += Format-GroupedBlockHeader -Kind 'SUMMARY' -Index 1 -Title $cpuTitle
        $output += (Format-GroupedPropertyLine -Label 'Physical Cores' -Value $first.NumberOfCores) + "`n"
        $output += (Format-GroupedPropertyLine -Label 'Logical Processors' -Value $first.NumberOfLogicalProcessors) + "`n"
        $output += (Format-GroupedPropertyLine -Label 'Current Clock (MHz)' -Value $first.CurrentClockSpeed) + "`n"
        $output += (Format-GroupedPropertyLine -Label 'Max Clock (MHz)' -Value $first.MaxClockSpeed) + "`n"
        $output += (Format-GroupedPropertyLine -Label 'Average Load' -Value "${avg}%") + "`n"
        $output += (Format-GroupedPropertyLine -Label 'Peak Load' -Value "${max}%") + "`n`n"
    }

    if ($procList.Count -gt 1) {
        $index = 0
        foreach ($cpu in $procList) {
            $index++
            $output += Format-GroupedBlockHeader -Kind 'CPU' -Index $index -Title "Logical Processor $index"
            $output += (Format-GroupedPropertyLine -Label 'Load' -Value "$($cpu.LoadPercentage)%") + "`n`n"
        }
    }

    return $output
}

function Format-HealthCheckRam {
    param(
        [Parameter(Mandatory)]$Os,
        $PhysicalMemory = @()
    )
    $totalBytes = [long]$Os.TotalVisibleMemorySize * 1KB
    $freeBytes  = [long]$Os.FreePhysicalMemory * 1KB
    $usedBytes  = $totalBytes - $freeBytes
    $usedPct    = if ($totalBytes -gt 0) { [math]::Round(($usedBytes / $totalBytes) * 100, 1) } else { 0 }

    $output = "PHYSICAL MEMORY`n"
    $output += "===============`n`n"
    $output += Format-GroupedBlockHeader -Kind 'SUMMARY' -Index 1 -Title 'Physical Memory'
    $output += (Format-GroupedPropertyLine -Label 'Total RAM' -Value (Format-SizeHuman -Bytes $totalBytes)) + "`n"
    $output += (Format-GroupedPropertyLine -Label 'Free RAM' -Value (Format-SizeHuman -Bytes $freeBytes)) + "`n"
    $output += (Format-GroupedPropertyLine -Label 'Used RAM' -Value "$(Format-SizeHuman -Bytes $usedBytes) ($usedPct%)") + "`n"

    $memModules = @($PhysicalMemory)
    if ($memModules.Count -gt 0) {
        $moduleTotal = ($memModules | Measure-Object -Property Capacity -Sum).Sum
        $output += (Format-GroupedPropertyLine -Label 'Installed Modules' -Value "$($memModules.Count) ($(Format-SizeHuman -Bytes $moduleTotal) reported by SMBIOS)") + "`n`n"
        $slot = 0
        foreach ($mod in $memModules) {
            $slot++
            $cap = Format-SizeHuman -Bytes ([long]$mod.Capacity)
            $speed = if ($mod.Speed) { "$($mod.Speed) MHz" } else { 'Unknown' }
            $title = "$cap @ $speed"
            $output += Format-GroupedBlockHeader -Kind 'MODULE' -Index $slot -Title $title
            $output += (Format-GroupedPropertyLine -Label 'Manufacturer' -Value $mod.Manufacturer) + "`n"
            $output += (Format-GroupedPropertyLine -Label 'Part Number' -Value $mod.PartNumber) + "`n`n"
        }
    }

    return $output
}

function Format-HealthCheckDiskSpace {
    param(
        [Parameter(Mandatory)]$Drives,
        [string[]]$LowDriveNames = @()
    )
    $driveList = @($Drives)
    $output = "DISK FREE SPACE`n"
    $output += "===============`n`n"
    $output += "File-system drives      : $($driveList.Count)`n"
    if ($LowDriveNames.Count -gt 0) {
        $output += "Low space warning (<10% free): $($LowDriveNames -join ', ')`n"
    }
    $output += "`n"

    $driveIndex = 0
    foreach ($drive in ($driveList | Sort-Object Name)) {
        $driveIndex++
        $total = [double]$drive.Used + [double]$drive.Free
        $freePct = if ($total -gt 0) { [math]::Round(($drive.Free / $total) * 100, 1) } else { 0 }
        $flagged = ($LowDriveNames -contains $drive.Name)
        $title = "$($drive.Name)"
        if ($flagged) { $title = "[!] $title" }

        $output += Format-GroupedBlockHeader -Kind 'DRIVE' -Index $driveIndex -Title $title
        $output += (Format-GroupedPropertyLine -Label 'Free' -Value "$([math]::Round($drive.Free / 1GB, 1)) GB") + "`n"
        $output += (Format-GroupedPropertyLine -Label 'Total' -Value "$([math]::Round($total / 1GB, 1)) GB") + "`n"
        $output += (Format-GroupedPropertyLine -Label 'Free %' -Value "$freePct%") + "`n"
        $output += (Format-GroupedPropertyLine -Label 'Flagged' -Value ($(if ($flagged) { 'Yes - low free space' } else { 'No' }))) + "`n`n"
    }

    return $output
}

function Format-HealthCheckActivation {
    param($License)
    if (-not $License) {
        $output = "WINDOWS ACTIVATION`n===================`n`n"
        $output += Format-GroupedBlockHeader -Kind 'SUMMARY' -Index 1 -Title 'Windows Activation'
        $output += (Format-GroupedPropertyLine -Label 'Status' -Value 'Unknown (no licensing product returned)') + "`n"
        return $output
    }

    $statusText = switch ([int]$License.LicenseStatus) {
        0 { 'Unlicensed' }
        1 { 'Licensed / Activated' }
        2 { 'OOB grace period' }
        3 { 'OOT grace period' }
        4 { 'Non-genuine grace period' }
        5 { 'Notification' }
        6 { 'Extended grace' }
        default { "Code $($License.LicenseStatus)" }
    }

    $partialKey = if ($License.PartialProductKey) { $License.PartialProductKey } else { 'N/A' }
    $desc = if ($License.Description) { $License.Description } else { 'N/A' }

    $output = "WINDOWS ACTIVATION`n"
    $output += "===================`n`n"
    $output += Format-GroupedBlockHeader -Kind 'SUMMARY' -Index 1 -Title 'Windows Activation'
    $output += (Format-GroupedPropertyLine -Label 'Status' -Value $statusText) + "`n"
    $output += (Format-GroupedPropertyLine -Label 'Description' -Value $desc) + "`n"
    $output += (Format-GroupedPropertyLine -Label 'Partial Product Key' -Value $partialKey) + "`n"
    $output += (Format-GroupedPropertyLine -Label 'Name' -Value $License.Name) + "`n"
    return $output
}

function Format-HealthCheckEventErrors {
    param(
        [int]$ErrorCount,
        $SampleEvents = @()
    )
    $output = "SYSTEM EVENT ERRORS (24 HOURS)`n"
    $output += "=============================`n`n"
    $output += "Error count             : $ErrorCount`n`n"

    $samples = @($SampleEvents)
    if ($samples.Count -eq 0) {
        $output += "No sample events captured.`n"
        return $output
    }

    $eventIndex = 0
    foreach ($evt in $samples) {
        $eventIndex++
        $msg = [string]$evt.Message -replace '\r?\n', ' '
        if ($msg.Length -gt 120) { $msg = $msg.Substring(0, 120) + '...' }
        $title = "$($evt.Source) (Event $($evt.EventID))"
        $output += Format-GroupedBlockHeader -Kind 'EVENT' -Index $eventIndex -Title $title
        $output += (Format-GroupedPropertyLine -Label 'Time' -Value $evt.TimeGenerated) + "`n"
        $output += (Format-GroupedPropertyLine -Label 'Source' -Value $evt.Source) + "`n"
        $output += (Format-GroupedPropertyLine -Label 'Event ID' -Value $evt.EventID) + "`n"
        $output += (Format-GroupedPropertyLine -Label 'Message' -Value $msg) + "`n`n"
    }

    return $output
}

function Format-CriticalEventsDetail {
    param(
        [int]$EventCount = 0,
        $EventSummary = @(),
        $Events = @()
    )

    $output = "CRITICAL EVENTS (7 DAYS)`n"
    $output += "========================`n`n"
    $output += "Events captured         : $EventCount`n"
    $output += "Grouped signatures      : $(@($EventSummary).Count)`n`n"

    $groupIndex = 0
    foreach ($group in @($EventSummary)) {
        $groupIndex++
        $title = "$($group.ProviderName) Id $($group.Id)"
        $output += Format-GroupedBlockHeader -Kind 'GROUP' -Index $groupIndex -Title $title
        $output += (Format-GroupedPropertyLine -Label 'Occurrences' -Value $group.Count) + "`n"
        if ($group.PSObject.Properties['SampleMessage'] -and $group.SampleMessage) {
            $sample = [string]$group.SampleMessage -replace '\r?\n', ' '
            if ($sample.Length -gt 120) { $sample = $sample.Substring(0, 120) + '...' }
            $output += (Format-GroupedPropertyLine -Label 'Sample Message' -Value $sample) + "`n"
        }
        $output += "`n"
    }

    $eventIndex = 0
    foreach ($evt in @($Events | Select-Object -First 20)) {
        $eventIndex++
        $provider = if ($evt.ProviderName) { [string]$evt.ProviderName } else { 'Unknown' }
        $title = "$provider (Id $($evt.Id))"
        $msg = if ($evt.Message) { [string]$evt.Message -replace '\r?\n', ' ' } else { '' }
        if ($msg.Length -gt 120) { $msg = $msg.Substring(0, 120) + '...' }
        $output += Format-GroupedBlockHeader -Kind 'EVENT' -Index $eventIndex -Title $title
        $output += (Format-GroupedPropertyLine -Label 'Time' -Value $evt.TimeCreated) + "`n"
        $output += (Format-GroupedPropertyLine -Label 'Provider' -Value $provider) + "`n"
        $output += (Format-GroupedPropertyLine -Label 'Event ID' -Value $evt.Id) + "`n"
        $output += (Format-GroupedPropertyLine -Label 'Message' -Value $msg) + "`n`n"
    }

    return $output
}

function Format-NetworkAdapters {
    param(
        [Parameter(Mandatory)]$Adapters,
        $IpConfigs = @()
    )
    $adapterList = @($Adapters)
    $ipList = @($IpConfigs)

    $output = "NETWORK ADAPTERS`n"
    $output += "================`n`n"
    $output += "Adapters in scope       : $($adapterList.Count)`n`n"

    $index = 0
    foreach ($adapter in ($adapterList | Sort-Object { [string]($_.Name) })) {
        $index++
        $alias = if ($adapter.Name) { [string]$adapter.Name } elseif ($adapter.NetConnectionID) { [string]$adapter.NetConnectionID } else { "Adapter $index" }
        $output += "ADAPTER $index : $alias`n"
        $output += ('-' * (10 + $alias.Length)) + "`n"

        $desc = if ($adapter.InterfaceDescription) { $adapter.InterfaceDescription }
                elseif ($adapter.Description) { $adapter.Description }
                else { 'Unknown' }
        $output += "{0,-24}: {1}`n" -f 'Description', $desc

        $status = if ($adapter.Status) { $adapter.Status }
                  elseif ($null -ne $adapter.NetEnabled) { if ($adapter.NetEnabled) { 'Enabled' } else { 'Disabled' } }
                  else { 'Unknown' }
        $output += "{0,-24}: {1}`n" -f 'Status', $status

        if ($adapter.LinkSpeed) {
            $speedLine = if ($adapter.LinkSpeed -is [string]) {
                [string]$adapter.LinkSpeed
            } else {
                $speedMbps = [math]::Round([double]$adapter.LinkSpeed / 1000000, 0)
                "$speedMbps Mbps"
            }
            $output += "{0,-24}: {1}`n" -f 'Link Speed', $speedLine
        }

        $mac = if ($adapter.MacAddress) { $adapter.MacAddress }
               elseif ($adapter.MACAddress) { $adapter.MACAddress }
               else { 'Unknown' }
        $output += "{0,-24}: {1}`n" -f 'MAC Address', $mac

        if ($adapter.MediaType) {
            $output += "{0,-24}: {1}`n" -f 'Media Type', $adapter.MediaType
        }
        if ($adapter.InterfaceType) {
            $output += "{0,-24}: {1}`n" -f 'Interface Type', $adapter.InterfaceType
        }
        if ($adapter.DriverVersion) {
            $output += "{0,-24}: {1}`n" -f 'Driver Version', $adapter.DriverVersion
        }
        if ($adapter.DriverDate) {
            $output += "{0,-24}: {1}`n" -f 'Driver Date', (Convert-CdeWmiDate -WmiDate ([string]$adapter.DriverDate))
        }

        $ipCfg = @($ipList | Where-Object {
            $_.InterfaceAlias -eq $alias -or
            $_.InterfaceAlias -eq $adapter.InterfaceAlias -or
            $_.InterfaceIndex -eq $adapter.ifIndex
        })
        foreach ($nic in $ipCfg) {
            foreach ($addr in @($nic.IPv4Address)) {
                if ($addr -and $addr.IPAddress) {
                    $output += "{0,-24}: {1}/{2}`n" -f 'IPv4 Address', $addr.IPAddress, $addr.PrefixLength
                }
            }
            foreach ($addr in @($nic.IPv6Address | Select-Object -First 2)) {
                if ($addr -and $addr.IPAddress) {
                    $output += "{0,-24}: {1}/{2}`n" -f 'IPv6 Address', $addr.IPAddress, $addr.PrefixLength
                }
            }
            $gw = @($nic.IPv4DefaultGateway | Select-Object -First 1)
            if ($gw -and $gw.NextHop) {
                $output += "{0,-24}: {1}`n" -f 'Default Gateway', $gw.NextHop
            }
            if ($nic.DNSServer -and $nic.DNSServer.ServerAddresses) {
                $dns = @($nic.DNSServer.ServerAddresses | Where-Object { $_ })
                if ($dns.Count -gt 0) {
                    $output += "{0,-24}: {1}`n" -f 'DNS Servers', ($dns -join ', ')
                }
            }
        }

        $output += "`n"
    }

    return $output
}

function Get-GpuDedicatedVideoRamBytes {
    <#
    .SYNOPSIS
        Resolve dedicated GPU memory in bytes.

    .DESCRIPTION
        Win32_VideoController.AdapterRAM is a 32-bit field that saturates near 4 GB.
        Prefer the display-class registry QWORD HardwareInformation.qwMemorySize when
        available, then fall back to AdapterRAM (unsigned).
    #>
    param(
        [Parameter(Mandatory)]$Gpu
    )

    $displayClass = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    $pnpId = [string]$Gpu.PNPDeviceID
    $caption = [string]$(if ($Gpu.Name) { $Gpu.Name } elseif ($Gpu.Caption) { $Gpu.Caption } else { '' })

    # Enumerate numbered adapter keys only. Get-ChildItem on the class key can throw
    # SecurityException on the locked "Properties" subkey and abort the lookup.
    for ($i = 0; $i -lt 64; $i++) {
        $subPath = Join-Path $displayClass ('{0:D4}' -f $i)
        if (-not (Test-Path -LiteralPath $subPath)) {
            continue
        }

        $props = Get-ItemProperty -LiteralPath $subPath -ErrorAction SilentlyContinue
        if (-not $props) { continue }

        $qw = $props.'HardwareInformation.qwMemorySize'
        if ($null -eq $qw) { continue }

        try {
            $qwBytes = [long]$qw
        } catch {
            continue
        }
        if ($qwBytes -le 0) { continue }

        $matched = $false
        $matchId = [string]$props.MatchingDeviceId
        if ($matchId -and $pnpId -and $pnpId.StartsWith($matchId, [System.StringComparison]::OrdinalIgnoreCase)) {
            $matched = $true
        }
        elseif ($props.DriverDesc -and $caption -and
                [string]::Equals([string]$props.DriverDesc, $caption, [System.StringComparison]::OrdinalIgnoreCase)) {
            $matched = $true
        }

        if ($matched) {
            return $qwBytes
        }
    }

    if ($null -eq $Gpu.AdapterRAM) {
        return $null
    }

    try {
        # AdapterRAM is uint32 in WMI; PowerShell may surface it as signed Int32.
        $raw = $Gpu.AdapterRAM
        if ($raw -is [int] -or $raw -is [int32]) {
            return [long]([uint32]$raw)
        }
        $asLong = [long]$raw
        if ($asLong -lt 0) {
            return [long]([uint32]$asLong)
        }
        if ($asLong -gt 0) {
            return $asLong
        }
    } catch {
        return $null
    }

    return $null
}

function Format-GpuInfo {
    param([Parameter(Mandatory)]$Gpus)
    $gpuList = @($Gpus)

    $output = "GRAPHICS ADAPTERS`n"
    $output += "=================`n`n"
    $output += "Adapters found          : $($gpuList.Count)`n`n"

    $index = 0
    foreach ($gpu in $gpuList) {
        $index++
        $name = if ($gpu.Caption) { $gpu.Caption } elseif ($gpu.Name) { $gpu.Name } else { 'Unknown GPU' }
        $output += "GPU $index : $name`n"
        $output += ('-' * (7 + $name.Length)) + "`n"

        if ($gpu.VideoProcessor) {
            $output += "{0,-24}: {1}`n" -f 'Video Processor', $gpu.VideoProcessor
        }
        $vramBytes = $null
        if ($null -ne $gpu.DedicatedVideoRAM -and [long]$gpu.DedicatedVideoRAM -gt 0) {
            $vramBytes = [long]$gpu.DedicatedVideoRAM
        } else {
            $vramBytes = Get-GpuDedicatedVideoRamBytes -Gpu $gpu
        }
        if ($vramBytes -and $vramBytes -gt 0) {
            $output += "{0,-24}: {1}`n" -f 'Dedicated Video RAM', (Format-SizeHuman -Bytes $vramBytes)
        }
        if ($gpu.DriverVersion) {
            $output += "{0,-24}: {1}`n" -f 'Driver Version', $gpu.DriverVersion
        }
        if ($gpu.DriverDate) {
            $output += "{0,-24}: {1}`n" -f 'Driver Date', (Convert-CdeWmiDate -WmiDate ([string]$gpu.DriverDate))
        }
        if ($gpu.CurrentHorizontalResolution -and $gpu.CurrentVerticalResolution) {
            $res = "$($gpu.CurrentHorizontalResolution)x$($gpu.CurrentVerticalResolution)"
            if ($gpu.CurrentRefreshRate) { $res += " @ $($gpu.CurrentRefreshRate) Hz" }
            $output += "{0,-24}: {1}`n" -f 'Current Resolution', $res
        }
        if ($gpu.VideoModeDescription) {
            $output += "{0,-24}: {1}`n" -f 'Video Mode', $gpu.VideoModeDescription
        }
        if ($gpu.Status) {
            $output += "{0,-24}: {1}`n" -f 'Status', $gpu.Status
        }
        if ($gpu.Availability) {
            $output += "{0,-24}: {1}`n" -f 'Availability', $gpu.Availability
        }
        if ($gpu.AdapterDACType) {
            $output += "{0,-24}: {1}`n" -f 'DAC Type', $gpu.AdapterDACType
        }
        if ($gpu.PNPDeviceID) {
            $output += "{0,-24}: {1}`n" -f 'PnP Device ID', $gpu.PNPDeviceID
        }

        $output += "`n"
    }

    return $output
}

function Format-DriverSignatureAudit {
    param(
        [Parameter(Mandatory)]$Drivers,
        [Parameter(Mandatory)]$UnsignedDrivers
    )
    $all = @($Drivers)
    $unsigned = @($UnsignedDrivers)

    $output = "DRIVER SIGNATURE AUDIT`n"
    $output += "======================`n`n"
    $output += "Signed drivers in scope : $($all.Count)`n"
    $output += "Unsigned drivers        : $($unsigned.Count)`n`n"

    if ($unsigned.Count -eq 0) {
        $output += Format-GroupedBlockHeader -Kind 'SUMMARY' -Index 1 -Title 'Driver Signatures'
        $output += (Format-GroupedPropertyLine -Label 'Result' -Value 'All in-scope PnP drivers report as signed.') + "`n"
        return $output
    }

    $unsignedIndex = 0
    foreach ($driver in ($unsigned | Sort-Object DeviceName)) {
        $unsignedIndex++
        $title = if ($driver.DeviceName) { [string]$driver.DeviceName } else { 'Unknown driver' }
        if ($title.Length -gt 72) { $title = $title.Substring(0, 72) }
        $output += Format-GroupedBlockHeader -Kind 'UNSIGNED' -Index $unsignedIndex -Title "[!] $title"
        $output += (Format-GroupedPropertyLine -Label 'Version' -Value $driver.DriverVersion) + "`n"
        $output += (Format-GroupedPropertyLine -Label 'Date' -Value (Convert-CdeWmiDate -WmiDate ([string]$driver.DriverDate))) + "`n"
        $output += (Format-GroupedPropertyLine -Label 'Manufacturer' -Value $driver.Manufacturer) + "`n`n"
    }

    return $output
}

function Format-EventLogDetail {
    <#
    .SYNOPSIS Format event log entries with details.
    #>
    param([Parameter(Mandatory)]$SystemEvents, [Parameter(Mandatory)]$AppEvents)

    $output = "WINDOWS EVENT LOGS (Last 24 Hours)`n"
    $output += "=================================`n`n"
    $systemEvents = @($SystemEvents)
    $appEvents = @($AppEvents)
    $output += "System Events (Errors/Warnings): $($systemEvents.Count)`n"
    $output += "Application Events (Errors/Warnings): $($appEvents.Count)`n`n"

    $eventIndex = 0
    if ($systemEvents.Count -gt 0) {
        foreach ($evt in $systemEvents | Select-Object -First 15) {
            $eventIndex++
            $msg = $evt.Message -replace '\r?\n', ' ' | Select-Object -First 1
            if ($msg.Length -gt 120) { $msg = $msg.Substring(0, 120) + "..." }
            $title = "System · $($evt.Source)"
            $output += Format-GroupedBlockHeader -Kind 'EVENT' -Index $eventIndex -Title $title
            $output += (Format-GroupedPropertyLine -Label 'Level' -Value $evt.EntryType) + "`n"
            $output += (Format-GroupedPropertyLine -Label 'Time' -Value $evt.TimeGenerated) + "`n"
            $output += (Format-GroupedPropertyLine -Label 'Source' -Value $evt.Source) + "`n"
            $output += (Format-GroupedPropertyLine -Label 'Message' -Value $msg) + "`n`n"
        }
    }

    if ($appEvents.Count -gt 0) {
        foreach ($evt in $appEvents | Select-Object -First 15) {
            $eventIndex++
            $msg = $evt.Message -replace '\r?\n', ' ' | Select-Object -First 1
            if ($msg.Length -gt 120) { $msg = $msg.Substring(0, 120) + "..." }
            $title = "Application · $($evt.Source)"
            $output += Format-GroupedBlockHeader -Kind 'EVENT' -Index $eventIndex -Title $title
            $output += (Format-GroupedPropertyLine -Label 'Level' -Value $evt.EntryType) + "`n"
            $output += (Format-GroupedPropertyLine -Label 'Time' -Value $evt.TimeGenerated) + "`n"
            $output += (Format-GroupedPropertyLine -Label 'Source' -Value $evt.Source) + "`n"
            $output += (Format-GroupedPropertyLine -Label 'Message' -Value $msg) + "`n`n"
        }
    }

    return $output
}

function Format-PartitionInfo {
    <#
    .SYNOPSIS Format partition table information.
    #>
    param([Parameter(Mandatory)]$Partitions)

    $output = "DISK PARTITION TABLE`n"
    $output += "===================`n`n"
    $output += "Total Partitions        : $($Partitions.Count)`n`n"

    $partitionIndex = 0
    foreach ($part in $Partitions | Sort-Object { $_.DiskNumber }, { $_.PartitionNumber }) {
        $partitionIndex++
        $driveLtr = if ($part.DriveLetter) { "$($part.DriveLetter):" } else { "(none)" }
        $title = "Disk$($part.DiskNumber) Part$($part.PartitionNumber) $driveLtr"
        $type = "$($part.Type)$(if($part.IsSystem){' [SYS]'})$(if($part.IsBoot){' [BOOT]'})"

        $output += Format-GroupedBlockHeader -Kind 'PARTITION' -Index $partitionIndex -Title $title
        $output += (Format-GroupedPropertyLine -Label 'Drive Letter' -Value $driveLtr) + "`n"
        $output += (Format-GroupedPropertyLine -Label 'Size (GB)' -Value ([math]::Round($part.Size / 1GB, 2))) + "`n"
        $output += (Format-GroupedPropertyLine -Label 'Type' -Value $type) + "`n`n"
    }

    return $output
}

function Get-WindowsUpdateStackSnapshot {
    <#
    .SYNOPSIS Collect status and startup type for core Windows Update services.
    #>
    $names = @('wuauserv', 'UsoSvc', 'bits', 'WaaSMedicSvc')
    foreach ($name in $names) {
        try {
            $svc = Get-Service -Name $name -ErrorAction Stop
            [PSCustomObject]@{
                Name      = $svc.Name
                Status    = [string]$svc.Status
                StartType = [string]$svc.StartType
                Present   = $true
            }
        } catch {
            [PSCustomObject]@{
                Name      = $name
                Status    = 'N/A'
                StartType = 'N/A'
                Present   = $false
                Error     = $_.Exception.Message
            }
        }
    }
}

function Get-WindowsUpdateStackNote {
    param(
        [Parameter(Mandatory)]$Service
    )

    if (-not $Service.Present) {
        return 'Service not installed on this system'
    }

    if ($Service.StartType -eq 'Disabled') {
        return 'Disabled — updates may be blocked'
    }

    switch ($Service.Name) {
        'wuauserv' {
            if ($Service.Status -eq 'Running') { return 'Running' }
            return 'Stopped while idle is normal; starts on-demand for scans/installs'
        }
        'bits' {
            if ($Service.Status -eq 'Running') { return 'Running' }
            return 'Manual trigger-start; idle while no transfer is active'
        }
        'WaaSMedicSvc' {
            if ($Service.Status -eq 'Running') { return 'Running' }
            return 'Manual repair service; starts only when remediation is needed'
        }
        default {
            if ($Service.Status -eq 'Running') { return 'Running' }
            return 'Stopped while idle can be normal for orchestrator-driven services'
        }
    }
}

function Get-WindowsUpdateStackStatus {
    param(
        [Parameter(Mandatory)]$Services
    )

    $present = @($Services | Where-Object { $_.Present })
    if ($present.Count -eq 0) {
        return [PSCustomObject]@{ Status = 'Skip'; Summary = 'No Windows Update services found' }
    }

    $disabled = @($present | Where-Object { $_.StartType -eq 'Disabled' })
    if ($disabled.Count -gt 0) {
        $names = ($disabled | ForEach-Object { $_.Name }) -join ', '
        return [PSCustomObject]@{
            Status  = 'Fail'
            Summary = "Disabled startup type: $names"
        }
    }

    $uso = $present | Where-Object { $_.Name -eq 'UsoSvc' } | Select-Object -First 1
    if (-not $uso) {
        return [PSCustomObject]@{
            Status  = 'Warn'
            Summary = 'UsoSvc (Update Orchestrator) is missing; Windows Update may not run reliably'
        }
    }

    # Modern Windows defaults: UsoSvc Automatic; wuauserv Manual (on-demand) or Automatic.
    # Do not Warn solely because wuauserv is Manual — that is normal on Win10/11.
    if ($uso.StartType -ne 'Automatic') {
        return [PSCustomObject]@{
            Status  = 'Warn'
            Summary = "UsoSvc start type is $($uso.StartType) (expected Automatic)"
        }
    }

    $wuauserv = $present | Where-Object { $_.Name -eq 'wuauserv' } | Select-Object -First 1
    if ($wuauserv -and $wuauserv.StartType -notin @('Manual', 'Automatic')) {
        return [PSCustomObject]@{
            Status  = 'Warn'
            Summary = "wuauserv start type is $($wuauserv.StartType) (expected Manual or Automatic)"
        }
    }

    $bits = $present | Where-Object { $_.Name -eq 'bits' } | Select-Object -First 1
    if ($bits -and $bits.StartType -notin @('Manual', 'Automatic')) {
        return [PSCustomObject]@{
            Status  = 'Warn'
            Summary = "bits start type is $($bits.StartType) (expected Manual or Automatic)"
        }
    }

    $idleCore = @($present | Where-Object {
            $_.Name -in @('wuauserv', 'UsoSvc') -and $_.Status -ne 'Running'
        })
    $corePresent = @($present | Where-Object { $_.Name -in @('wuauserv', 'UsoSvc') })
    if ($corePresent.Count -gt 0 -and $idleCore.Count -eq $corePresent.Count) {
        return [PSCustomObject]@{
            Status  = 'Pass'
            Summary = 'Core update services are idle; startup types match Windows defaults'
        }
    }

    return [PSCustomObject]@{
        Status  = 'Pass'
        Summary = 'Windows Update stack matches expected defaults'
    }
}

function Format-WindowsUpdateStack {
    <#
    .SYNOPSIS Format core Windows Update service status for reports.
    #>
    param(
        [Parameter(Mandatory)]$Services,
        [string]$Summary = ''
    )

    $output = "WINDOWS UPDATE STACK`n"
    $output += "====================`n`n"
    if (-not [string]::IsNullOrWhiteSpace($Summary)) {
        $output += "Summary                 : $Summary`n`n"
    }

    $serviceIndex = 0
    foreach ($svc in $Services) {
        $serviceIndex++
        $title = [string]$svc.Name
        $note = Get-WindowsUpdateStackNote -Service $svc
        $output += Format-GroupedBlockHeader -Kind 'UPDATE' -Index $serviceIndex -Title $title
        $output += (Format-GroupedPropertyLine -Label 'Status' -Value $svc.Status) + "`n"
        $output += (Format-GroupedPropertyLine -Label 'Start Type' -Value $svc.StartType) + "`n"
        $output += (Format-GroupedPropertyLine -Label 'Notes' -Value $note) + "`n`n"
    }

    $output += "Stopped does not mean Disabled. Check the Start Type column for the real configuration.`n"
    return $output
}

function Format-DefenderStatus {
    <#
    .SYNOPSIS Format Windows Defender status information.
    #>
    param([Parameter(Mandatory)]$MpStatus)

    $engineProp = $MpStatus.PSObject.Properties['EngineVersion']
    $amEngineProp = $MpStatus.PSObject.Properties['AMEngineVersion']
    $engineVersion = if ($engineProp -and -not [string]::IsNullOrWhiteSpace([string]$engineProp.Value)) {
        [string]$engineProp.Value
    } elseif ($amEngineProp -and -not [string]::IsNullOrWhiteSpace([string]$amEngineProp.Value)) {
        [string]$amEngineProp.Value
    } else {
        'Unknown'
    }

    @"
WINDOWS DEFENDER STATUS
=======================

Antivirus Enabled           : $($MpStatus.AntivirusEnabled)
Antispyware Enabled         : $($MpStatus.AntiSpywareEnabled)
Real-time Protection Enabled: $($MpStatus.RealTimeProtectionEnabled)
Running Mode                : $($MpStatus.AMRunningMode)
Signature Version           : $($MpStatus.AntivirusSignatureVersion)
Last Signature Update       : $($MpStatus.AntivirusSignatureLastUpdated)
Engine Version              : $engineVersion

"@
}

function Format-AutorunsList {
    <#
    .SYNOPSIS Format autoruns/startup entries with suspicious items highlighted.
    #>
    param([Parameter(Mandatory)]$Entries, [Parameter(Mandatory)]$Suspicious)

    $entriesList = @($Entries | Sort-Object Location, Name)
    $suspiciousList = @($Suspicious | Sort-Object Location, Name)
    $registryCount = @($entriesList | Where-Object { [string]$_.Location -like 'HK*' }).Count
    $folderCount = @($entriesList | Where-Object { [string]$_.Location -notlike 'HK*' }).Count

    $output = "STARTUP/AUTORUNS ENTRIES`n"
    $output += "========================`n`n"
    $output += "Total Entries     : $($entriesList.Count)`n"
    $output += "Registry Entries  : $registryCount`n"
    $output += "Startup Folder Items: $folderCount`n"
    $output += "Suspicious Entries : $($suspiciousList.Count)`n`n"

    if ($entriesList.Count -gt 0) {
        $entryIndex = 0
        $suspiciousKeys = @{}
        foreach ($item in $suspiciousList) {
            $suspiciousKeys["$([string]$item.Location)|$([string]$item.Name)"] = $true
        }

        foreach ($item in $entriesList) {
            $entryIndex++
            $kind = if ([string]$item.Location -like 'HK*') { 'Registry' } else { 'Startup Folder' }
            $target = if ($null -ne $item.Value -and -not [string]::IsNullOrWhiteSpace([string]$item.Value)) { [string]$item.Value } else { '(empty)' }
            $itemKey = "$([string]$item.Location)|$([string]$item.Name)"
            $isSuspicious = $suspiciousKeys.ContainsKey($itemKey)
            $title = if ($isSuspicious) { "[!] $([string]$item.Name)" } else { [string]$item.Name }
            $actionText = if ($kind -eq 'Registry') {
                'Verify the command target is approved, signed, and required. Disable the registry value if it is not.'
            } else {
                'Verify the shortcut or file is approved. Remove the startup item if it is not required.'
            }

            $output += Format-GroupedBlockHeader -Kind 'ENTRY' -Index $entryIndex -Title "[$kind] $title"
            $output += (Format-GroupedPropertyLine -Label 'Location' -Value $item.Location) + "`n"
            $output += (Format-GroupedPropertyLine -Label 'Target' -Value $target) + "`n"
            $output += (Format-GroupedPropertyLine -Label 'Flagged' -Value ($(if ($isSuspicious) { 'Yes - review recommended' } else { 'No' }))) + "`n"
            $output += (Format-GroupedPropertyLine -Label 'Action' -Value $actionText) + "`n`n"
        }
    } else {
        $output += "No autoruns/startup entries were discovered.`n`n"
    }

    if ($suspiciousList.Count -eq 0) {
        $output += "No suspicious startup entries were flagged by the heuristic checks.`n"
    }

    return $output
}

function Format-HostsFileDetail {
    <#
    .SYNOPSIS Format hosts file check results.
    #>
    param([Parameter(Mandatory)]$HostsPath, [Parameter(Mandatory)]$CustomEntries)

    $output = "HOSTS FILE CHECK`n"
    $output += "================`n`n"
    $output += "Hosts File Location     : $HostsPath`n"
    $output += "Non-Default Entries     : $($CustomEntries.Count)`n`n"

    if ($CustomEntries.Count -gt 0) {
        $hostIndex = 0
        foreach ($entry in $CustomEntries) {
            $hostIndex++
            $title = if ($entry.Length -gt 72) { [string]$entry.Substring(0, 72) } else { [string]$entry }
            $output += Format-GroupedBlockHeader -Kind 'HOST' -Index $hostIndex -Title $title
            $output += (Format-GroupedPropertyLine -Label 'Entry' -Value $entry) + "`n`n"
        }
    } else {
        $output += "Hosts file is clean - only default entries present.`n"
    }

    return $output
}

function Format-BrowserExtensionList {
    <#
    .SYNOPSIS Format browser extension scan results.
    #>
    param([Parameter(Mandatory)]$ExtensionInventory)

    $inventory = @($ExtensionInventory)
    $stores = @($inventory | Where-Object { [string]$_.Kind -eq 'Store' })
    $profiles = @($inventory | Where-Object { [string]$_.Kind -eq 'Profile' })
    $extensions = @($inventory | Where-Object { [string]$_.Kind -eq 'Extension' })

    $output = "BROWSER EXTENSIONS SCAN`n"
    $output += "======================`n`n"
    $output += "Extension Stores Found : $($stores.Count)`n"
    $output += "Profiles Found         : $($profiles.Count)`n"
    $output += "Installed Extensions   : $($extensions.Count)`n`n"

    if ($stores.Count -gt 0) {
        $storeIndex = 0
        foreach ($store in $stores) {
            $storeIndex++
            $storeTitle = "[$([string]$store.Browser)] $([string]$store.Location)"
            if ($storeTitle.Length -gt 72) { $storeTitle = $storeTitle.Substring(0, 72) }
            $output += "STORE $storeIndex : $storeTitle`n"
            $output += ('-' * [Math]::Min(72, 8 + $storeTitle.Length)) + "`n"
            if (-not [string]::IsNullOrWhiteSpace([string]$store.User)) {
                $output += "{0,-24}: {1}`n" -f 'User', ([string]$store.User)
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$store.Profile)) {
                $output += "{0,-24}: {1}`n" -f 'Profile', ([string]$store.Profile)
            }
            $output += "{0,-24}: {1}`n" -f 'Location', ([string]$store.Location)
            $output += "{0,-24}: {1}`n" -f 'Action', 'Open the browser extension manager and confirm whether the store contents are approved.'
            $output += "`n"
        }
    } else {
        $output += "No browser extension stores were discovered.`n`n"
    }

    if ($extensions.Count -gt 0) {
        $extensionIndex = 0
        foreach ($extension in $extensions) {
            $extensionIndex++
            $displayName = if (-not [string]::IsNullOrWhiteSpace([string]$extension.ExtensionName)) { [string]$extension.ExtensionName } else { [string]$extension.ExtensionId }
            $extensionTitle = "[$([string]$extension.Browser)] $displayName"
            if ($extensionTitle.Length -gt 72) { $extensionTitle = $extensionTitle.Substring(0, 72) }
            $output += "EXTENSION $extensionIndex : $extensionTitle`n"
            $output += ('-' * [Math]::Min(72, 12 + $extensionTitle.Length)) + "`n"
            $output += "{0,-24}: {1}`n" -f 'ID', ([string]$extension.ExtensionId)
            if (-not [string]::IsNullOrWhiteSpace([string]$extension.Version)) {
                $output += "{0,-24}: {1}`n" -f 'Version', ([string]$extension.Version)
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$extension.User)) {
                $output += "{0,-24}: {1}`n" -f 'User', ([string]$extension.User)
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$extension.Profile)) {
                $output += "{0,-24}: {1}`n" -f 'Profile', ([string]$extension.Profile)
            }
            $output += "{0,-24}: {1}`n" -f 'Path', ([string]$extension.ExtensionPath)
            if (-not [string]::IsNullOrWhiteSpace([string]$extension.ManifestDescription)) {
                $output += "{0,-24}: {1}`n" -f 'Summary', ([string]$extension.ManifestDescription)
            }
            $output += "{0,-24}: {1}`n" -f 'Action', 'Verify the extension owner, publisher, and business need. Remove or disable it if it is not approved.'
            $output += "`n"
        }
    } else {
        $output += "No installed extensions were enumerated from the discovered stores.`n"
    }

    $output += "`nRecommendation: Validate the extension list against your approved baseline and browser policy.`n"

    return $output
}

function Get-ScheduledTaskPrimaryAction {
    param([Parameter(Mandatory)]$Task)

    $actions = @($Task.Actions)
    if ($actions.Count -eq 0) {
        return $null
    }

    return $actions[0]
}

function Get-ScheduledTaskActionExecute {
    param($Action)

    if (-not $Action) { return '' }
    $prop = $Action.PSObject.Properties['Execute']
    if ($prop) { return [string]$prop.Value }
    return ''
}

function Get-ScheduledTaskActionArguments {
    param($Action)

    if (-not $Action) { return '' }
    $prop = $Action.PSObject.Properties['Arguments']
    if ($prop) { return [string]$prop.Value }
    return ''
}

function Get-ScheduledTaskActionClassId {
    param($Action)

    if (-not $Action) { return '' }
    $prop = $Action.PSObject.Properties['ClassId']
    if ($prop -and -not [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
        return [string]$prop.Value
    }
    return ''
}

function Get-ScheduledTaskActionDisplay {
    <#
    .SYNOPSIS Human-readable action line for Exec or COM scheduled-task actions.
    #>
    param($Action)

    if (-not $Action) { return 'Unknown' }

    $exe = Get-ScheduledTaskActionExecute -Action $Action
    if (-not [string]::IsNullOrWhiteSpace($exe)) {
        return $exe
    }

    $classId = Get-ScheduledTaskActionClassId -Action $Action
    if ([string]::IsNullOrWhiteSpace($classId)) {
        return 'Unknown'
    }

    if (Get-Command -Name Resolve-ComHandlerServerPath -ErrorAction SilentlyContinue) {
        try {
            $com = Resolve-ComHandlerServerPath -ClassId $classId
            if ($com -and -not [string]::IsNullOrWhiteSpace([string]$com.ServerPath)) {
                return "COM $classId -> $($com.ServerPath)"
            }
        }
        catch { }
    }

    return "COM $classId"
}

function Format-ScheduledTasksList {
    <#
    .SYNOPSIS Format scheduled tasks with suspicious items highlighted.
    #>
    param([Parameter(Mandatory)]$CustomTasks, [Parameter(Mandatory)]$SuspiciousTasks)

    $customList = @($CustomTasks | Sort-Object TaskPath, TaskName)
    $suspiciousKeys = @{}
    foreach ($task in @($SuspiciousTasks)) {
        $suspiciousKeys["$([string]$task.TaskPath)|$([string]$task.TaskName)"] = $true
    }

    $output = "SCHEDULED TASKS AUDIT`n"
    $output += "====================`n`n"
    $output += "Custom (Non-Microsoft) Tasks: $($customList.Count)`n"
    $output += "Suspicious Tasks            : $($SuspiciousTasks.Count)`n`n"

    if ($customList.Count -gt 0) {
        $taskIndex = 0
        foreach ($task in $customList) {
            $taskIndex++
            $taskKey = "$([string]$task.TaskPath)|$([string]$task.TaskName)"
            $isSuspicious = $suspiciousKeys.ContainsKey($taskKey)
            $taskTitle = if ($isSuspicious) { "[!] $([string]$task.TaskName)" } else { [string]$task.TaskName }
            if ($taskTitle.Length -gt 72) { $taskTitle = $taskTitle.Substring(0, 72) }
            $output += "TASK $taskIndex : $taskTitle`n"
            $output += ('-' * [Math]::Min(72, 7 + $taskTitle.Length)) + "`n"
            $output += "{0,-24}: {1}`n" -f 'Task Path', ([string]$task.TaskPath)
            $actionObj = Get-ScheduledTaskPrimaryAction -Task $task
            $action = Get-ScheduledTaskActionDisplay -Action $actionObj
            $output += "{0,-24}: {1}`n" -f 'Action', $action
            $arguments = Get-ScheduledTaskActionArguments -Action $actionObj
            if (-not [string]::IsNullOrWhiteSpace($arguments)) {
                $output += "{0,-24}: {1}`n" -f 'Arguments', $arguments
            }
            $output += "{0,-24}: {1}`n" -f 'State', ([string]$task.State)
            $flaggedLabel = if ($isSuspicious) { 'Yes - review recommended' } else { 'No' }
            $output += "{0,-24}: {1}`n" -f 'Flagged', $flaggedLabel
            if ($isSuspicious) {
                $reasonProp = $task.PSObject.Properties['SuspiciousReasons']
                if ($reasonProp -and $reasonProp.Value) {
                    $reasonText = (@($reasonProp.Value) | Where-Object { $_ } | Select-Object -Unique) -join '; '
                    if (-not [string]::IsNullOrWhiteSpace($reasonText)) {
                        $output += "{0,-24}: {1}`n" -f 'Review Reason', $reasonText
                    }
                }
            }
            $output += "`n"
        }
    } else {
        $output += "No custom scheduled tasks were found.`n"
    }

    return $output
}

#endregion

#region ─── TOOL PATH RESOLUTION ──────────────────────────────────────────────

function Resolve-ToolPath {
    <#
    .SYNOPSIS Resolves tool paths in the new MRI-like folder structure.
    .DESCRIPTION
        Searches for tools in Diagnostics/, Windows Tools/, and other standard locations.
        Returns the full path to the tool or $null if not found.
    .EXAMPLE
        Resolve-ToolPath -ToolName 'memtest.efi' -Category 'Memory'
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ToolName,
        [string]$Category = $null
    )

    $toolkitRoot = $Script:ToolkitRoot
    $searchPaths = @(
        $(if ($Category) { Join-Path $toolkitRoot "Diagnostics\$Category" }),
        $(Join-Path $toolkitRoot 'Diagnostics'),
        $(Join-Path $toolkitRoot 'Windows Tools'),
        $(Join-Path $toolkitRoot 'Windows Tools\Utilities'),
        $(Join-Path $toolkitRoot 'Windows Tools\Repair'),
        $(Join-Path $toolkitRoot 'boot'),
        $(Join-Path $toolkitRoot 'sources\x64')
    )

    foreach ($path in $searchPaths) {
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path $path)) { continue }
        
        $found = Get-ChildItem -Path $path -Name $ToolName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) {
            return Join-Path $path $found
        }
        
        # Also search recursively one level deep for nested tool folders
        $found = Get-ChildItem -Path $path -Recurse -Name $ToolName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) {
            return Join-Path $path $found
        }
    }

    return $null
}

#endregion

#endregion

#region ─── CAPABILITY MATRIX & STRUCTURED OUTPUT ─────────────────────────────

$Script:CapabilityMatrixCache = $null

function Get-ToolkitCapabilityMatrix {
    if ($null -ne $Script:CapabilityMatrixCache) {
        return $Script:CapabilityMatrixCache
    }

    $path = Join-Path $Script:ToolkitRoot 'Config\EnvironmentCapabilityMatrix.json'
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Environment capability matrix not found: $path"
    }

    $Script:CapabilityMatrixCache = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    return $Script:CapabilityMatrixCache
}

function Get-ToolkitCapabilityColumn {
    <#
    .SYNOPSIS
        Resolves the active column in EnvironmentCapabilityMatrix.json.
    #>
    [OutputType([string])]
    param()

    if ((Get-EnvironmentMode) -eq 'WinPE') {
        $offline = Resolve-OfflineWindowsRoot
        if ($offline) { return 'winpe_offline' }
        return 'winpe_online'
    }

    try {
        $build = [Environment]::OSVersion.Version.Build
        if ($build -ge 22000) { return 'live_win11' }
    } catch {}

    return 'live_win10'
}

function Get-ToolkitCapabilityValue {
    param(
        [Parameter(Mandatory)][string]$Workflow,
        [string]$Action = 'Run'
    )

    $matrix = Get-ToolkitCapabilityMatrix
    $column = Get-ToolkitCapabilityColumn
    $workflowProp = $matrix.workflows.PSObject.Properties[$Workflow]
    if (-not $workflowProp) { return 'supported' }

    $entry = $workflowProp.Value
    $actionProp = $entry.actions.PSObject.Properties[$Action]
    if (-not $actionProp) {
        $actionProp = $entry.actions.PSObject.Properties['Run']
    }
    if (-not $actionProp) { return 'supported' }

    $actionMap = $actionProp.Value
    $valueProp = $actionMap.PSObject.Properties[$column]
    if ($valueProp) { return [string]$valueProp.Value }
    return 'supported'
}

function Test-ToolkitCapability {
    param(
        [Parameter(Mandatory)][string]$Workflow,
        [string]$Action = 'Run'
    )

    $value = Get-ToolkitCapabilityValue -Workflow $Workflow -Action $Action
    switch ($value) {
        'na' { return $false }
        'requires_elevation' {
            if (Get-Command Test-ToolkitIsElevated -ErrorAction SilentlyContinue) {
                return (Test-ToolkitIsElevated)
            }
            return $true
        }
        'requires_offline_registry' {
            return $env:OFFLINE_REGISTRY_LOADED -eq '1'
        }
        'offline_registry' {
            if ((Get-EnvironmentMode) -ne 'WinPE') { return $true }
            return $env:OFFLINE_REGISTRY_LOADED -eq '1'
        }
        default { return $true }
    }
}

function Assert-ToolkitCapability {
    param(
        [Parameter(Mandatory)][string]$Workflow,
        [string]$Action = 'Run'
    )

    $value = Get-ToolkitCapabilityValue -Workflow $Workflow -Action $Action
    $column = Get-ToolkitCapabilityColumn

    switch ($value) {
        'na' {
            throw "$Workflow ($Action) is not available in $column."
        }
        'requires_elevation' {
            if (Get-Command Test-ToolkitIsElevated -ErrorAction SilentlyContinue) {
                if (-not (Test-ToolkitIsElevated)) {
                    throw "$Workflow requires administrator elevation."
                }
            }
        }
        'requires_offline_registry' {
            if ($env:OFFLINE_REGISTRY_LOADED -ne '1') {
                throw "$Workflow requires offline registry hives to be loaded."
            }
        }
        'offline_registry' {
            if ((Get-EnvironmentMode) -eq 'WinPE' -and $env:OFFLINE_REGISTRY_LOADED -ne '1') {
                throw "$Workflow requires offline registry hives in WinPE."
            }
        }
    }
}

function Write-CdeEvent {
    param(
        [Parameter(Mandatory)][hashtable]$Payload
    )

    if (-not $Payload.ContainsKey('type')) {
        $Payload['type'] = 'status'
    }

    $json = $Payload | ConvertTo-Json -Compress -Depth 6
    # Write to stdout without joining the success pipeline (avoids corrupting workflow JSON).
    [Console]::Out.WriteLine("[CDE:EVENT:v1]$json")
}

#endregion

# Auto-load config on module import
Load-Config | Out-Null

Export-ModuleMember -Function @(
    'Get-EnvironmentMode',
    'Get-ToolkitCapabilityMatrix',
    'Get-ToolkitCapabilityColumn',
    'Get-ToolkitCapabilityValue',
    'Test-ToolkitCapability',
    'Assert-ToolkitCapability',
    'Write-CdeEvent',
    'Normalize-OfflineWindowsRoot',
    'Read-OfflineEnvValue',
    'Resolve-OfflineWindowsRoot',
    'Get-ToolkitHostsFilePath',
    'Load-Config',
    'Initialize-SessionLog',
    'Get-SessionReportTimestamp',
    'Write-Log',
    'Format-CdeUptimeSpan',
    'Get-CdeBootUptimeInfo',
    'Get-SystemInfo',
    'Invoke-Tool',
    'Start-Workflow',
    'Get-WorkflowStepCounts',
    'Get-WorkflowOverallHealth',
    'Set-WorkflowOverallHealth',
    'Group-WorkflowEvents',
    'Format-WorkflowEventSummaryText',
    'Generate-Report',
    'Get-NextCaseId',
    'New-WorkOrder',
    'Get-ActiveWorkOrderPointer',
    'Set-ActiveWorkOrderPointer',
    'Clear-ActiveWorkOrderPointer',
    'Update-WorkOrderNotes',
    'Add-WorkOrderRun',
    'Close-WorkOrder',
    'Export-WorkOrderReport',
    'Get-WorkOrder',
    'Format-SizeHuman',
    'Format-SystemDetail',
    'Format-SoftwareList',
    'Format-DriversList',
    'Format-PnPDeviceList',
    'Format-ServicesList',
    'Format-NetworkConfig',
    'Convert-CdeWmiDate',
    'Format-HealthCheckOsVersion',
    'Format-HealthCheckCpuLoad',
    'Format-HealthCheckRam',
    'Format-HealthCheckDiskSpace',
    'Format-HealthCheckActivation',
    'Format-HealthCheckEventErrors',
    'Format-NetworkAdapters',
    'Get-GpuDedicatedVideoRamBytes',
    'Format-GpuInfo',
    'Format-DriverSignatureAudit',
    'Format-EventLogDetail',
    'Format-CriticalEventsDetail',
    'Format-PartitionInfo',
    'Format-WindowsUpdateStack',
    'Get-WindowsUpdateStackSnapshot',
    'Get-WindowsUpdateStackStatus',
    'Format-DefenderStatus',
    'Format-AutorunsList',
    'Format-HostsFileDetail',
    'Format-BrowserExtensionList',
    'Format-ScheduledTasksList',
    'Get-ScheduledTaskActionDisplay',
    'Resolve-ToolPath'
)
