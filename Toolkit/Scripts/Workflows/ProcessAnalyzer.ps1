#Requires -Version 5.1
param(
    [string]$Action = 'List',
    [int]$TargetPid = 0,
    [string]$TargetPath = '',
    [string]$TargetPathsFile = '',
    [string]$StartupEntryMetadataPath = '',
    [int]$SampleMs = 1000,
    [switch]$DeepScan,
    [string]$OutputPath = '',
    [string]$Format = 'Json',
    [switch]$ElevatedRelay
)

$ErrorActionPreference = if ($Action -in @('List', 'Detail', 'MatchStartup', 'CstScan', 'StartupEntryCstScan', 'PathCstScan', 'Export')) { 'SilentlyContinue' } else { 'Stop' }

$Script:ProcessAnalyzerScriptPath = $MyInvocation.MyCommand.Path
$ScriptDir = Split-Path $Script:ProcessAnalyzerScriptPath
$ElevationModule = Join-Path $ScriptDir '..\Core\Toolkit.Elevation.psm1'
Import-Module $ElevationModule -Force -DisableNameChecking
. (Join-Path $ScriptDir '..\Core\ProcessAnalyzer.Core.ps1')

$ToolkitRoot = Get-ToolkitRootFromScript -WorkflowScriptRoot $ScriptDir

function Get-ProcessAnalyzerRelayArgumentString {
    $parts = [System.Collections.Generic.List[string]]::new()
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'Action' -Value $Action
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'ElevatedRelay' -IsSwitch
    if ($TargetPid -gt 0) {
        Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'TargetPid' -Value ([string]$TargetPid)
    }
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'TargetPath' -Value $TargetPath
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'TargetPathsFile' -Value $TargetPathsFile
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'StartupEntryMetadataPath' -Value $StartupEntryMetadataPath
    if ($SampleMs -ne 1000) {
        Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'SampleMs' -Value ([string]$SampleMs)
    }
    if ($DeepScan) {
        Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'DeepScan' -IsSwitch
    }
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'OutputPath' -Value $OutputPath
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'Format' -Value $Format
    return Join-ToolkitRelayArgumentString -Parts $parts
}

function Invoke-ProcessAnalyzerElevationRelay {
    if ($ElevatedRelay) { return $false }
    if ($Action -ne 'Kill') { return $false }
    if ($TargetPid -le 0) { return $false }
    return (Invoke-ToolkitWorkflowElevationRelay -ScriptPath $Script:ProcessAnalyzerScriptPath `
        -ArgumentString (Get-ProcessAnalyzerRelayArgumentString) -ElevatedRelay:$ElevatedRelay)
}

if (Invoke-ProcessAnalyzerElevationRelay) { exit 0 }

function Get-ProcessListPayload {
    param(
        [int]$CpuSampleMs,
        [switch]$IncludeDeepScan
    )

    $wmiProcs = @{}
    try {
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | ForEach-Object {
            $wmiProcs[[int]$_.ProcessId] = $_
        }
    }
    catch { }

    $cpuMap = Get-ProcessCpuPercentMap -SampleMs $CpuSampleMs

    $rows = [System.Collections.Generic.List[object]]::new()
    $seenPids = @{}
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        $processId = [int]$p.Id
        if ($processId -le 0) { continue }
        if ($seenPids.ContainsKey($processId)) { continue }
        $seenPids[$processId] = $true

        $wmi = $wmiProcs[$processId]
        $path = ''
        $company = ''
        try { $path = [string]$p.Path } catch { }
        try { $company = [string]$p.Company } catch { }

        if ([string]::IsNullOrWhiteSpace($path) -and $wmi) {
            $path = [string]$wmi.ExecutablePath
        }

        $commandLine = ''
        $parentPid = 0
        $sessionId = 0
        $startTime = ''
        if ($wmi) {
            $commandLine = [string]$wmi.CommandLine
            $parentPid = [int]$wmi.ParentProcessId
            $sessionId = [int]$wmi.SessionId
            if ($wmi.CreationDate) {
                $startTime = Format-ProcessCreationTime -CreationDate $wmi.CreationDate
            }
        }

        $userName = Get-ProcessOwnerName -WmiProcess $wmi
        if ([string]::IsNullOrWhiteSpace($userName)) {
            $userName = '(unknown)'
        }

        $arch = if ($path) { Get-PeMachineArch -Path $path } else { '' }
        if ([string]::IsNullOrWhiteSpace($arch)) { $arch = '?' }

        $cpuPercent = 0.0
        if ($cpuMap.ContainsKey($processId)) {
            $cpuPercent = [double]$cpuMap[$processId]
        }

        $ramMb = 0.0
        try { $ramMb = [math]::Round($p.WorkingSet64 / 1MB, 1) } catch { }

        $status = 'Running'
        try {
            if ($p.Responding -eq $false) { $status = 'Not Responding' }
        }
        catch { }

        $signed = $null
        if ($IncludeDeepScan -and $path) {
            $signed = Test-ProcessPathSigned -Path $path
        }

        $risk = Get-ProcessRiskInfo -Name $p.ProcessName -FilePath $path -CommandLine $commandLine `
            -IsSigned $signed -CpuPercent $cpuPercent -RamMB $ramMb -Status $status

        $inStartup = $false
        if ($path) {
            $inStartup = Test-ProcessPathInStartup -ExePath $path
        }

        $rows.Add([PSCustomObject]@{
            Pid               = $processId
            Name              = $p.ProcessName
            Company           = if ($company) { $company } else { 'Unknown' }
            FilePath          = if ($path) { $path } else { '' }
            Arch              = $arch
            UserName          = $userName
            RamMB             = $ramMb
            CpuPercent        = $cpuPercent
            Status            = $status
            IsSigned          = $signed
            SignatureChecked  = ($null -ne $signed)
            CommandLine       = $commandLine
            ParentPid         = $parentPid
            SessionId         = $sessionId
            StartTime         = $startTime
            RiskScore         = [int]$risk.Score
            RiskBand          = [string]$risk.Band
            RiskFlags         = [string]$risk.Flags
            InStartup         = $inStartup
        }) | Out-Null
    }

    return @($rows)
}

function Get-ProcessDetailPayload {
    param([int]$ProcessId)

    if ($ProcessId -le 0) {
        throw 'Detail requires -TargetPid.'
    }

    $wmi = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $wmi) {
        throw "Process not found: PID $ProcessId"
    }

    $path = Get-ProcessImagePath -ProcessId $ProcessId -WmiProcess $wmi
    $signed = if ($path) { Test-ProcessPathSigned -Path $path } else { $null }
    $parentChain = Get-ProcessParentChain -ProcessId $ProcessId
    $services = Get-SvchostServiceNames -ProcessId $ProcessId
    $modules = Get-ProcessLoadedModules -ProcessId $ProcessId
    $inStartup = if ($path) { Test-ProcessPathInStartup -ExePath $path } else { $false }
    $connections = @(Get-ProcessNetworkSnapshot -ProcessId $ProcessId -MaxRows 80)
    $moduleAnomalies = @(Get-ProcessModuleAnomalies -ProcessId $ProcessId -ProcessPath $path)

    $fileHash = ''
    if ($path -and (Test-Path -LiteralPath $path)) {
        try {
            $fileHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash
        }
        catch { }
    }

    $ramMb = 0.0
    $status = 'Running'
    try {
        $proc = Get-Process -Id $ProcessId -ErrorAction Stop
        $ramMb = [math]::Round($proc.WorkingSet64 / 1MB, 1)
        if ($proc.Responding -eq $false) { $status = 'Not Responding' }
    }
    catch { }

    $risk = Get-ProcessRiskInfo -Name ([string]$wmi.Name) -FilePath $path -CommandLine ([string]$wmi.CommandLine) `
        -IsSigned $signed -CpuPercent 0 -RamMB $ramMb -Status $status

    return [PSCustomObject]@{
        Pid              = $ProcessId
        Name             = [string]$wmi.Name
        FilePath         = $path
        CommandLine      = [string]$wmi.CommandLine
        ParentPid        = [int]$wmi.ParentProcessId
        SessionId        = [int]$wmi.SessionId
        StartTime        = Format-ProcessCreationTime -CreationDate $wmi.CreationDate
        UserName         = (Get-ProcessOwnerName -WmiProcess $wmi)
        IsSigned         = $signed
        SignatureChecked = ($null -ne $signed)
        Arch             = if ($path) { Get-PeMachineArch -Path $path } else { '' }
        RamMB            = $ramMb
        Status           = $status
        RiskScore        = [int]$risk.Score
        RiskBand         = [string]$risk.Band
        RiskFlags        = [string]$risk.Flags
        InStartup        = $inStartup
        ParentChain      = @($parentChain)
        Services         = @($services)
        Modules          = @($modules)
        Connections      = @($connections)
        ModuleAnomalies  = @($moduleAnomalies)
        Sha256           = $fileHash
    }
}

function Export-ProcessListPayload {
    param(
        [Parameter(Mandatory)][object[]]$Processes,
        [Parameter(Mandatory)][string]$Path,
        [string]$ExportFormat = 'Json'
    )

    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    if ($ExportFormat -eq 'Csv') {
        $Processes | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
        return $Path
    }

    $payload = [PSCustomObject]@{
        ExportedAt = (Get-Date).ToString('o')
        Machine    = $env:COMPUTERNAME
        Count      = @($Processes).Count
        Processes  = @($Processes)
    }
    $payload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
    return $Path
}

switch ($Action) {
    'List' {
        $rows = Get-ProcessListPayload -CpuSampleMs $SampleMs -IncludeDeepScan:$DeepScan
        @($rows) | ConvertTo-Json -Depth 4
    }
    'Detail' {
        (Get-ProcessDetailPayload -ProcessId $TargetPid) | ConvertTo-Json -Depth 6
    }
    'Kill' {
        Stop-Process -Id $TargetPid -Force -ErrorAction SilentlyContinue
        Write-Output "Terminated PID $TargetPid"
    }
    'MatchStartup' {
        $match = Test-ProcessPathInStartup -ExePath $TargetPath
        [PSCustomObject]@{ Path = $TargetPath; InStartup = $match } | ConvertTo-Json
    }
    'CstScan' {
        (Invoke-ProcessCstCustomScan -TargetPath $TargetPath -ToolkitRoot $ToolkitRoot) | ConvertTo-Json -Depth 6
    }
    'PathCstScan' {
        (Invoke-PathCstScan -TargetPath $TargetPath -TargetPathsFile $TargetPathsFile -ToolkitRoot $ToolkitRoot) | ConvertTo-Json -Depth 8 -Compress:$false
    }
    'StartupEntryCstScan' {
        (Invoke-StartupEntryCstScan -MetadataPath $StartupEntryMetadataPath -ToolkitRoot $ToolkitRoot) | ConvertTo-Json -Depth 12 -Compress:$false
    }
    'Export' {
        $rows = Get-ProcessListPayload -CpuSampleMs $SampleMs -IncludeDeepScan:$DeepScan
        if ([string]::IsNullOrWhiteSpace($OutputPath)) {
            throw 'Export requires -OutputPath.'
        }
        $saved = Export-ProcessListPayload -Processes $rows -Path $OutputPath -ExportFormat $Format
        [PSCustomObject]@{ SavedTo = $saved; Count = @($rows).Count } | ConvertTo-Json
    }
    default {
        throw "Unknown action: $Action"
    }
}
