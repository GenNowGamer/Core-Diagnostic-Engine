#Requires -Version 5.1
<#
.SYNOPSIS
    Shared health-check step functions for SystemHealthCheck.
#>

function Add-HealthCheckStep {
    param(
        [Parameter(Mandatory)]$WorkflowResult,
        [Parameter(Mandatory)][hashtable]$Step
    )

    if ([string]::IsNullOrWhiteSpace([string]$Step.Output)) {
        $Step.Output = [string]$Step.Detail
    }

    $WorkflowResult.Steps.Add([PSCustomObject]$Step)
}

function Invoke-HealthCheck_os_version {
    param($r)
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $detail = "$($os.Caption) (Build $($os.BuildNumber))"
        $output = Format-HealthCheckOsVersion -Os $os
        Add-HealthCheckStep $r @{
            Name    = 'OSVersion'
            Status  = 'Pass'
            Detail  = $detail
            Output  = $output
            CheckId = 'os_version'
        }
    } catch {
        Add-HealthCheckStep $r @{
            Name    = 'OSVersion'
            Status  = 'Fail'
            Detail  = $_.Exception.Message
            Output  = $_.Exception.Message
            CheckId = 'os_version'
        }
    }
    Write-Log "OS: $($r.Steps[-1].Detail)"
}

function Invoke-HealthCheck_cpu_load {
    param($r)
    try {
        $processors = @(Get-CimInstance Win32_Processor)
        $cpuLoad = ($processors | Measure-Object -Property LoadPercentage -Average).Average
        $cpuStatus = if ($cpuLoad -gt 90) { 'Warn' } else { 'Pass' }
        $output = Format-HealthCheckCpuLoad -Processors $processors
        Add-HealthCheckStep $r @{
            Name    = 'CPULoad'
            Status  = $cpuStatus
            Detail  = "$([math]::Round($cpuLoad, 1))% average across $($processors.Count) logical processor(s)"
            Output  = $output
            Value   = $cpuLoad
            CheckId = 'cpu_load'
        }
    } catch {
        Add-HealthCheckStep $r @{
            Name    = 'CPULoad'
            Status  = 'Skip'
            Detail  = 'Unable to read'
            Output  = 'Unable to read processor load information.'
            CheckId = 'cpu_load'
        }
    }
    Write-Log "CPU Load: $($r.Steps[-1].Detail)"
}

function Invoke-HealthCheck_ram {
    param($r)
    try {
        $osObj   = Get-CimInstance Win32_OperatingSystem
        $memMods = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue)
        $totalGB = [math]::Round($osObj.TotalVisibleMemorySize / 1MB, 1)
        $freeGB  = [math]::Round($osObj.FreePhysicalMemory / 1MB, 1)
        $usedPct = [math]::Round((($osObj.TotalVisibleMemorySize - $osObj.FreePhysicalMemory) / $osObj.TotalVisibleMemorySize) * 100, 1)
        $ramStatus = if ($usedPct -gt 90) { 'Warn' } else { 'Pass' }
        $output = Format-HealthCheckRam -Os $osObj -PhysicalMemory $memMods
        Add-HealthCheckStep $r @{
            Name    = 'RAM'
            Status  = $ramStatus
            Detail  = "Used $usedPct% | Free ${freeGB}GB of ${totalGB}GB"
            Output  = $output
            UsedPct = $usedPct
            CheckId = 'ram'
        }
    } catch {
        Add-HealthCheckStep $r @{
            Name    = 'RAM'
            Status  = 'Skip'
            Detail  = 'Unable to read'
            Output  = 'Unable to read physical memory information.'
            CheckId = 'ram'
        }
    }
    Write-Log "RAM: $($r.Steps[-1].Detail)"
}

function Invoke-HealthCheck_disk_space {
    param($r)
    try {
        $drives = @(Get-PSDrive -PSProvider FileSystem | Where-Object { $null -ne $_.Used })
        $lowDrives = @($drives | Where-Object {
            $total = $_.Used + $_.Free
            $total -gt 0 -and ($_.Free / $total) -lt 0.10
        })
        $lowNames = @($lowDrives | ForEach-Object { $_.Name })
        $output = Format-HealthCheckDiskSpace -Drives $drives -LowDriveNames $lowNames
        Add-HealthCheckStep $r @{
            Name   = 'DiskSpace'
            Status = if ($lowDrives.Count -gt 0) { 'Warn' } else { 'Pass' }
            Detail = if ($lowDrives.Count -gt 0) { "Low space on: $($lowNames -join ', ')" } else { 'All drives have sufficient space' }
            Output = $output
            Drives = $drives | ForEach-Object {
                $total = $_.Used + $_.Free
                [PSCustomObject]@{
                    Drive   = $_.Name
                    FreeGB  = [math]::Round($_.Free / 1GB, 1)
                    TotalGB = [math]::Round($total / 1GB, 1)
                }
            }
            CheckId = 'disk_space'
        }
    } catch {
        Add-HealthCheckStep $r @{
            Name    = 'DiskSpace'
            Status  = 'Skip'
            Detail  = 'Unable to read drives'
            Output  = 'Unable to read file-system drive free space.'
            CheckId = 'disk_space'
        }
    }
    Write-Log "Disk Space: $($r.Steps[-1].Detail)"
}

function Invoke-HealthCheck_activation {
    param($r)
    if ((Get-EnvironmentMode) -ne 'Windows') { return }
    try {
        $lic = Get-CimInstance -ClassName SoftwareLicensingProduct `
            -Filter "PartialProductKey IS NOT NULL AND ApplicationID = '55c92734-d682-4d71-983e-d6ec3f16059f'" `
            -ErrorAction Stop | Select-Object -First 1
        $activated = $lic.LicenseStatus -eq 1
        $output = Format-HealthCheckActivation -License $lic
        Add-HealthCheckStep $r @{
            Name    = 'Activation'
            Status  = if ($activated) { 'Pass' } else { 'Warn' }
            Detail  = if ($activated) { 'Windows is activated' } else { 'Windows is NOT activated' }
            Output  = $output
            CheckId = 'activation'
        }
    } catch {
        Add-HealthCheckStep $r @{
            Name    = 'Activation'
            Status  = 'Skip'
            Detail  = 'Cannot determine activation status'
            Output  = "Cannot determine activation status: $($_.Exception.Message)"
            CheckId = 'activation'
        }
    }
    Write-Log "Activation: $($r.Steps[-1].Detail)"
}

function Invoke-HealthCheck_event_errors_24h {
    param($r)
    if ((Get-EnvironmentMode) -ne 'Windows') { return }
    try {
        $since = (Get-Date).AddHours(-24)
        $errors = @(Get-EventLog -LogName System -EntryType Error -After $since -ErrorAction Stop)
        $errCount = $errors.Count
        $samples = @($errors | Select-Object -First 10 TimeGenerated, Source, EventID, Message)
        $output = Format-HealthCheckEventErrors -ErrorCount $errCount -SampleEvents $samples
        Add-HealthCheckStep $r @{
            Name       = 'EventLogErrors'
            Status     = if ($errCount -gt 50) { 'Warn' } else { 'Pass' }
            Detail     = "$errCount System errors in last 24h"
            Output     = $output
            ErrorCount = $errCount
            CheckId    = 'event_errors_24h'
        }
    } catch {
        Add-HealthCheckStep $r @{
            Name    = 'EventLogErrors'
            Status  = 'Skip'
            Detail  = 'Cannot read event log'
            Output  = "Cannot read System event log: $($_.Exception.Message)"
            CheckId = 'event_errors_24h'
        }
    }
    Write-Log "Event Errors (24h): $($r.Steps[-1].Detail)"
}

function Invoke-HealthCheck_system_info {
    param($r)
    Write-Log 'Collecting full system information...'
    try {
        $os  = Get-CimInstance Win32_OperatingSystem
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        $mb  = Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue
        $sysInfo = Get-SystemInfo
        $output = Format-SystemDetail -Os $os -Cpu $cpu -Motherboard $mb
        Add-HealthCheckStep $r @{
            Name    = 'SystemInfo'
            Status  = 'Pass'
            Detail  = "CPU: $($sysInfo.CpuName) | RAM: $($sysInfo.TotalRamGB)GB | Board: $($sysInfo.Motherboard)"
            Output  = $output
            Data    = $sysInfo
            CheckId = 'system_info'
        }
    } catch {
        Add-HealthCheckStep $r @{
            Name    = 'SystemInfo'
            Status  = 'Fail'
            Detail  = $_.Exception.Message
            Output  = $_.Exception.Message
            CheckId = 'system_info'
        }
    }
}

function Get-CdeWorkflowsDataRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:TOOLKIT_ROOT)) {
        return Join-Path $env:TOOLKIT_ROOT.TrimEnd('\') 'CDE\Runtime\Data\workflows'
    }

    $toolkitRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    return Join-Path $toolkitRoot 'CDE\Runtime\Data\workflows'
}

function Get-ActionableUnsignedPnPDrivers {
    param([Parameter(Mandatory)][array]$Drivers)

    return @($Drivers | Where-Object {
        if ($_.IsSigned -ne $false) { return $false }
        if ([string]::IsNullOrWhiteSpace([string]$_.DeviceName)) { return $false }

        $manufacturer = ([string]$_.Manufacturer).Trim()
        if ($manufacturer -match '^(?i)(Microsoft|Standard|System)(\b|$)') { return $false }

        $deviceName = ([string]$_.DeviceName).Trim()
        if ($deviceName -match '^(?i)(Volume|Generic volume shadow copy|Disk drive|Processor|System board|Motherboard|Monitor|Keyboard|Mouse|HID|USB Root Hub|Composite Bus Enumerator)') {
            return $false
        }

        return $true
    })
}

function Invoke-HealthCheck_driver_signature_audit {
    param($r)
    Write-Log 'Auditing drivers...'
    $env = Get-EnvironmentMode
    if ($env -eq 'Windows') {
        try {
            $drivers = @(Get-CimInstance -ClassName Win32_PnPSignedDriver |
                Where-Object { $_.DeviceName } |
                Select-Object DeviceName, DriverVersion, DriverDate, Manufacturer, IsSigned)
            $unsignedDrivers = @(Get-ActionableUnsignedPnPDrivers -Drivers $drivers)
            $output = Format-DriverSignatureAudit -Drivers $drivers -UnsignedDrivers $unsignedDrivers
            Add-HealthCheckStep $r @{
                Name            = 'DriverAudit'
                Status          = if ($unsignedDrivers.Count -gt 0) { 'Warn' } else { 'Pass' }
                Detail          = "$($drivers.Count) drivers | $($unsignedDrivers.Count) unsigned"
                Output          = $output
                UnsignedDrivers = $unsignedDrivers
                CheckId         = 'driver_signature_audit'
            }
            Write-Log "Drivers: $($drivers.Count) total, $($unsignedDrivers.Count) unsigned"
        } catch {
            Add-HealthCheckStep $r @{
                Name    = 'DriverAudit'
                Status  = 'Skip'
                Detail  = $_.Exception.Message
                Output  = $_.Exception.Message
                CheckId = 'driver_signature_audit'
            }
        }
    } else {
        Add-HealthCheckStep $r @{
            Name    = 'DriverAudit'
            Status  = 'Skip'
            Detail  = 'Not available in WinPE'
            Output  = 'Driver signature audit is not available in WinPE.'
            CheckId = 'driver_signature_audit'
        }
    }
}

function Invoke-HealthCheck_windows_update_service {
    param($r)
    if ((Get-EnvironmentMode) -ne 'Windows') { return }
    Write-Log 'Checking Windows Update stack...'
    try {
        $services = @(Get-WindowsUpdateStackSnapshot)
        $evaluation = Get-WindowsUpdateStackStatus -Services $services
        $formatted = Format-WindowsUpdateStack -Services $services -Summary $evaluation.Summary
        Write-Log $formatted

        $r.Steps.Add([PSCustomObject]@{
            Name    = 'WindowsUpdateService'
            Status  = $evaluation.Status
            Detail  = $evaluation.Summary
            Output  = $formatted
            Services = $services
            CheckId = 'windows_update_service'
        })
    } catch {
        $r.Steps.Add([PSCustomObject]@{
            Name    = 'WindowsUpdateService'
            Status  = 'Skip'
            Detail  = "Cannot query Windows Update stack: $($_.Exception.Message)"
            CheckId = 'windows_update_service'
        })
    }
}

function Invoke-HealthCheck_network_adapters {
    param($r)
    Write-Log 'Enumerating network adapters...'
    try {
        $adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -ne 'Not Present' })
        $ipConfigs = @()
        try {
            $ipConfigs = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue)
        } catch {
            Write-Log "Get-NetIPConfiguration unavailable: $($_.Exception.Message)"
        }
        $output = Format-NetworkAdapters -Adapters $adapters -IpConfigs $ipConfigs
        $upCount = @($adapters | Where-Object { $_.Status -eq 'Up' }).Count
        Add-HealthCheckStep $r @{
            Name     = 'NetworkAdapters'
            Status   = 'Pass'
            Detail   = "$($adapters.Count) adapter(s) found ($upCount up)"
            Output   = $output
            Adapters = $adapters | Select-Object Name, InterfaceDescription, Status, LinkSpeed, MacAddress, MediaType, DriverVersion, DriverDate, ifIndex
            CheckId  = 'network_adapters'
        }
    } catch {
        try {
            $adapters = @(Get-CimInstance -ClassName Win32_NetworkAdapter | Where-Object { $_.NetEnabled })
            $output = Format-NetworkAdapters -Adapters $adapters
            Add-HealthCheckStep $r @{
                Name    = 'NetworkAdapters'
                Status  = 'Pass'
                Detail  = "$($adapters.Count) adapter(s) found (via WMI)"
                Output  = $output
                CheckId = 'network_adapters'
            }
        } catch {
            Add-HealthCheckStep $r @{
                Name    = 'NetworkAdapters'
                Status  = 'Skip'
                Detail  = 'Cannot enumerate adapters'
                Output  = 'Cannot enumerate network adapters.'
                CheckId = 'network_adapters'
            }
        }
    }
}

function Invoke-HealthCheck_gpu_info {
    param($r)
    Write-Log 'Reading GPU information...'
    try {
        $gpus = @(Get-CimInstance -ClassName Win32_VideoController)
        $output = Format-GpuInfo -Gpus $gpus
        $names = ($gpus | ForEach-Object { $_.Caption }) -join '; '
        Add-HealthCheckStep $r @{
            Name    = 'GPUInfo'
            Status  = 'Pass'
            Detail  = if ($gpus.Count -gt 0) { $names } else { 'No video controllers reported' }
            Output  = $output
            GPUs    = $gpus | Select-Object Caption, DriverVersion, DriverDate, VideoRAM, VideoProcessor, CurrentHorizontalResolution, CurrentVerticalResolution, CurrentRefreshRate, VideoModeDescription, Status, PNPDeviceID
            CheckId = 'gpu_info'
        }
    } catch {
        Add-HealthCheckStep $r @{
            Name    = 'GPUInfo'
            Status  = 'Skip'
            Detail  = 'Cannot enumerate GPUs'
            Output  = "Cannot enumerate GPUs: $($_.Exception.Message)"
            CheckId = 'gpu_info'
        }
    }
}

function Invoke-HealthCheck_critical_events_7d {
    param($r, [string]$EventsExportScriptDir)
    if ((Get-EnvironmentMode) -ne 'Windows') { return }
    Write-Log 'Harvesting critical event log entries...'
    try {
        $since = (Get-Date).AddDays(-7)
        $critical = @(Get-WinEvent -FilterHashtable @{
            LogName   = 'System', 'Application'
            Level     = 1, 2
            StartTime = $since
        } -MaxEvents 50 -ErrorAction Stop)
        $eventCount = $critical.Count
        $eventSummary = Group-WorkflowEvents -Events $critical
        $summaryText = Format-CriticalEventsDetail -EventCount $eventCount -EventSummary $eventSummary -Events ($critical | Select-Object -First 20)
        $detailText = "$eventCount critical/error events in last 7 days"

        $eventsExportPath = $null
        if ($eventCount -gt 20 -and -not [string]::IsNullOrWhiteSpace($EventsExportScriptDir)) {
            $dataRoot = Get-CdeWorkflowsDataRoot
            $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
            $eventsExportPath = Join-Path $dataRoot "HealthCheck_Events_$ts.json"
            if (-not (Test-Path $dataRoot)) {
                New-Item -ItemType Directory -Force -Path $dataRoot | Out-Null
            }
            $critical | Select-Object TimeCreated, ProviderName, Id, Message |
                ConvertTo-Json -Depth 6 |
                Set-Content -Path $eventsExportPath -Encoding UTF8
            Write-Log "Full critical event export saved: $eventsExportPath"
        }

        $r.Steps.Add([PSCustomObject]@{
            Name             = 'CriticalEvents'
            Status           = if ($eventCount -gt 20) { 'Warn' } else { 'Pass' }
            Detail           = $detailText
            Output           = $summaryText
            EventCount       = $eventCount
            EventSummary     = @($eventSummary)
            Events           = $critical | Select-Object TimeCreated, ProviderName, Id, Message -First 20
            EventsExportPath = $eventsExportPath
            CheckId          = 'critical_events_7d'
        })
    } catch {
        $r.Steps.Add([PSCustomObject]@{ Name = 'CriticalEvents'; Status = 'Skip'; Detail = 'Cannot read event logs'; CheckId = 'critical_events_7d' })
    }
}

function Get-HealthCheckStepDispatchMap {
    return @{
        os_version               = { param($r, $ctx) Invoke-HealthCheck_os_version $r }
        cpu_load                 = { param($r, $ctx) Invoke-HealthCheck_cpu_load $r }
        ram                      = { param($r, $ctx) Invoke-HealthCheck_ram $r }
        disk_space               = { param($r, $ctx) Invoke-HealthCheck_disk_space $r }
        activation               = { param($r, $ctx) Invoke-HealthCheck_activation $r }
        event_errors_24h         = { param($r, $ctx) Invoke-HealthCheck_event_errors_24h $r }
        system_info              = { param($r, $ctx) Invoke-HealthCheck_system_info $r }
        driver_signature_audit   = { param($r, $ctx) Invoke-HealthCheck_driver_signature_audit $r }
        windows_update_service   = { param($r, $ctx) Invoke-HealthCheck_windows_update_service $r }
        network_adapters         = { param($r, $ctx) Invoke-HealthCheck_network_adapters $r }
        gpu_info                 = { param($r, $ctx) Invoke-HealthCheck_gpu_info $r }
        critical_events_7d       = { param($r, $ctx) Invoke-HealthCheck_critical_events_7d -r $r -EventsExportScriptDir $ctx.WorkflowsDir }
    }
}
