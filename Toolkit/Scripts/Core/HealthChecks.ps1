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
        $step = @{
            Name    = 'OSVersion'
            Status  = 'Pass'
            Detail  = $detail
            Output  = $output
            CheckId = 'os_version'
        }
        Add-HealthFindingsToStep -Step $step -Findings @(
            New-InventoryHealthFinding -CheckId 'os_version' -Finding $detail -Evidence @($detail)
        ) -SummaryText $detail
        Add-HealthCheckStep $r $step
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
        $detail = "$([math]::Round($cpuLoad, 1))% average across $($processors.Count) logical processor(s)"
        $findings = @()
        if ($cpuLoad -gt 90) {
            $findings += New-HealthFinding -FindingId 'health.cpu.high_load' -CheckId 'cpu_load' `
                -Finding 'CPU load is critically high' -Impact 'The system may feel slow or unresponsive under this load.' `
                -Severity 'High' -Confidence 85 -Status 'Warn' -Evidence @($detail) `
                -Recommendations @('Inspect top CPU consumers in Process Analyzer.', 'Close runaway apps or scan for malware if unexplained.') `
                -Actions @(@{ type = 'cde'; target = 'ProcessAnalyzer:HighCpu'; label = 'Process Analyzer (high CPU)' })
        }
        else {
            $findings += New-HealthFinding -FindingId 'health.cpu.load_ok' -CheckId 'cpu_load' `
                -Finding 'CPU load is within normal range' -Impact 'No CPU pressure indicated by this snapshot.' `
                -Severity 'Info' -Confidence 80 -Status 'Pass' -Evidence @($detail)
        }
        $step = @{
            Name    = 'CPULoad'
            Status  = $cpuStatus
            Detail  = $detail
            Output  = $output
            Value   = $cpuLoad
            CheckId = 'cpu_load'
        }
        Add-HealthFindingsToStep -Step $step -Findings $findings -SummaryText $detail
        Add-HealthCheckStep $r $step
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
        $detail = "Used $usedPct% | Free ${freeGB}GB of ${totalGB}GB"
        $findings = @()
        if ($usedPct -gt 90) {
            $findings += New-HealthFinding -FindingId 'health.memory.high_usage' -CheckId 'ram' `
                -Finding 'Memory usage is critically high' -Impact 'Applications may thrash to disk and feel unresponsive.' `
                -Severity 'High' -Confidence 85 -Status 'Warn' -Evidence @($detail) `
                -Recommendations @('Inspect top memory consumers in Process Analyzer.', 'Consider closing browsers/apps or adding RAM if chronic.') `
                -Actions @(@{ type = 'cde'; target = 'ProcessAnalyzer:HighRam'; label = 'Process Analyzer (high RAM)' })
        }
        else {
            $findings += New-HealthFinding -FindingId 'health.memory.usage_ok' -CheckId 'ram' `
                -Finding 'Memory usage is within normal range' -Impact 'No memory pressure indicated by this snapshot.' `
                -Severity 'Info' -Confidence 80 -Status 'Pass' -Evidence @($detail)
        }
        $step = @{
            Name    = 'RAM'
            Status  = $ramStatus
            Detail  = $detail
            Output  = $output
            UsedPct = $usedPct
            CheckId = 'ram'
        }
        Add-HealthFindingsToStep -Step $step -Findings $findings -SummaryText $detail
        Add-HealthCheckStep $r $step
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
        $findings = @()
        foreach ($d in $drives) {
            $total = $d.Used + $d.Free
            if ($total -le 0) { continue }
            $freePct = [math]::Round(($d.Free / $total) * 100, 1)
            $freeGB = [math]::Round($d.Free / 1GB, 1)
            $totalGB = [math]::Round($total / 1GB, 1)
            $evidence = @("$($d.Name): ${freeGB} GB free of ${totalGB} GB ($freePct%)")
            if ($freePct -lt 10) {
                $sev = if ($freePct -lt 5 -or $d.Name -eq 'C') { 'High' } else { 'Medium' }
                $findings += New-HealthFinding -FindingId 'health.disk.low_space' -CheckId 'disk_space' `
                    -Subject ("{0}:" -f $d.Name) `
                    -Finding 'Drive has low free space' `
                    -Impact 'Updates, paging, and application writes may fail on this volume.' `
                    -Severity $sev -Confidence 90 -Status 'Warn' -Evidence $evidence `
                    -Recommendations @('Free space on this volume.', 'Run Temp File Cleaner for temporary files.') `
                    -Actions @(
                        @{ type = 'cde'; target = 'TempFileCleaner'; label = 'Temp File Cleaner' }
                        @{ type = 'shell'; target = 'cleanmgr'; label = 'Disk Cleanup (Windows)' }
                    )
            }
        }
        if ($findings.Count -eq 0) {
            $findings += New-HealthFinding -FindingId 'health.disk.space_ok' -CheckId 'disk_space' `
                -Finding 'All scanned drives have sufficient free space' `
                -Impact 'No low-space condition detected.' `
                -Severity 'Info' -Confidence 85 -Status 'Pass' `
                -Evidence @('All drives above 10% free.')
        }
        $detail = if ($lowDrives.Count -gt 0) { "Low space on: $($lowNames -join ', ')" } else { 'All drives have sufficient space' }
        $step = @{
            Name   = 'DiskSpace'
            Status = if ($lowDrives.Count -gt 0) { 'Warn' } else { 'Pass' }
            Detail = $detail
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
        Add-HealthFindingsToStep -Step $step -Findings $findings -SummaryText $detail
        Add-HealthCheckStep $r $step
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
        $detail = if ($activated) { 'Windows is activated' } else { 'Windows is NOT activated' }
        $findings = @()
        if ($activated) {
            $findings += New-HealthFinding -FindingId 'health.activation.licensed' -CheckId 'activation' `
                -Finding 'Windows is activated' -Impact 'Licensing is healthy.' `
                -Severity 'Info' -Confidence 95 -Status 'Pass' -Evidence @($detail)
        }
        else {
            $findings += New-HealthFinding -FindingId 'health.activation.not_licensed' -CheckId 'activation' `
                -Finding 'Windows is not activated' -Impact 'Personalization and some features may be limited; activation reminders will appear.' `
                -Severity 'Medium' -Confidence 90 -Status 'Warn' -Evidence @($detail) `
                -Recommendations @('Open Activation Settings and verify the product key or digital license.', 'Use Fast Fixes if reactivation after hardware change is needed.') `
                -Actions @(
                    @{ type = 'cde'; target = 'FastFixes'; label = 'Fast Fixes' }
                    @{ type = 'shell'; target = 'ms-settings:activation'; label = 'Activation Settings' }
                )
        }
        $step = @{
            Name    = 'Activation'
            Status  = if ($activated) { 'Pass' } else { 'Warn' }
            Detail  = $detail
            Output  = $output
            CheckId = 'activation'
        }
        Add-HealthFindingsToStep -Step $step -Findings $findings -SummaryText $detail
        Add-HealthCheckStep $r $step
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
        $findings = @(Invoke-EventFindingClustering -CheckId 'event_errors_24h' -Events $errors -DefaultLogName 'System')
        $step = @{
            Name       = 'EventLogErrors'
            Status     = if ($errCount -gt 50) { 'Warn' } else { 'Pass' }
            Detail     = "$errCount System errors in last 24h"
            Output     = $output
            ErrorCount = $errCount
            CheckId    = 'event_errors_24h'
        }
        if ($findings.Count -gt 0) {
            Add-HealthFindingsToStep -Step $step -Findings $findings -SummaryText $step.Detail
        }
        elseif ($errCount -eq 0) {
            Add-HealthFindingsToStep -Step $step -Findings @(
                New-HealthFinding -FindingId 'event.errors_24h.none' -CheckId 'event_errors_24h' `
                    -Finding 'No System errors in the last 24 hours' -Impact 'No recent System log errors were recorded.' `
                    -Severity 'Info' -Confidence 100 -Status 'Pass' -Evidence @('Error count: 0')
            ) -SummaryText $step.Detail
        }
        Add-HealthCheckStep $r $step
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
        $detail = "CPU: $($sysInfo.CpuName) | RAM: $($sysInfo.TotalRamGB)GB | Board: $($sysInfo.Motherboard)"
        $step = @{
            Name    = 'SystemInfo'
            Status  = 'Pass'
            Detail  = $detail
            Output  = $output
            Data    = $sysInfo
            CheckId = 'system_info'
        }
        Add-HealthFindingsToStep -Step $step -Findings @(
            New-InventoryHealthFinding -CheckId 'system_info' -Finding $detail -Evidence @($detail)
        ) -SummaryText $detail
        Add-HealthCheckStep $r $step
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
            $detail = "$($drivers.Count) drivers | $($unsignedDrivers.Count) unsigned"
            $findings = @()
            if ($unsignedDrivers.Count -eq 0) {
                $findings += New-HealthFinding -FindingId 'driver.signature.ok' -CheckId 'driver_signature_audit' `
                    -Finding 'No actionable unsigned drivers detected' -Impact 'Driver signing looks healthy for reviewable devices.' `
                    -Severity 'Info' -Confidence 85 -Status 'Pass' -Evidence @($detail)
            }
            else {
                foreach ($u in $unsignedDrivers) {
                    $findings += New-HealthFinding -FindingId 'driver.signature.unsigned' -CheckId 'driver_signature_audit' `
                        -Subject ([string]$u.DeviceName) `
                        -Finding 'Unsigned driver detected' `
                        -Impact 'Unsigned drivers can indicate outdated, third-party, or tampered kernel modules.' `
                        -Severity 'Medium' -Confidence 80 -Status 'Warn' `
                        -Evidence @("Device: $($u.DeviceName)", "Manufacturer: $($u.Manufacturer)", "Version: $($u.DriverVersion)") `
                        -Recommendations @('Verify the publisher and update or replace the driver from the OEM.') `
                        -Actions @(@{ type = 'shell'; target = 'devmgmt.msc'; label = 'Device Manager' })
                }
            }

            # Shared allowlist with CST rules.json (stock Windows + known security products).
            $allowFilters = @(Get-CdeDriverFilterAllowlistNames)
            $unexpectedFilters = [System.Collections.Generic.List[string]]::new()
            try {
                $fltOut = & fltmc.exe filters 2>&1 | Out-String
                foreach ($line in ($fltOut -split "`r?`n")) {
                    if ($line -match '^\s*Filter\s+Name' -or $line -match '^-{3,}' -or [string]::IsNullOrWhiteSpace($line)) { continue }
                    if ($line -match '^\s*(\S+)\s+\d+') {
                        $fname = $Matches[1]
                        if (-not (Test-CdeDriverFilterAllowlisted -FilterName $fname -Allowlist $allowFilters)) {
                            $unexpectedFilters.Add($fname) | Out-Null
                        }
                    }
                }
            } catch { }

            foreach ($fname in $unexpectedFilters) {
                $findings += New-HealthFinding -FindingId 'driver.filter.unexpected' -CheckId 'driver_signature_audit' `
                    -Subject $fname -Finding 'Unexpected minifilter' `
                    -Impact 'Unexpected filter drivers warrant review; wording is inventory, not confirmed rootkit.' `
                    -Severity 'Medium' -Confidence 60 -Status 'Warn' `
                    -Evidence @("fltmc filter: $fname") `
                    -Recommendations @('Verify the filter publisher and unload only if confirmed malicious.') `
                    -Actions @(@{ type = 'cde'; target = 'CoreSecurityTool'; label = 'Core Security Tool' })
            }

            $filterKeys = @(
                'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e967-e325-11ce-bfc1-08002be10318}', # DiskDrive
                'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e96a-e325-11ce-bfc1-08002be10318}', # CDROM
                'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{71a27cdd-812a-11d0-bec7-08002be2092f}'  # Volume
            )
            foreach ($key in $filterKeys) {
                if (-not (Test-Path -LiteralPath $key)) { continue }
                try {
                    $item = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
                    foreach ($propName in @('UpperFilters', 'LowerFilters')) {
                        if (-not $item.PSObject.Properties[$propName]) { continue }
                        foreach ($val in @($item.$propName)) {
                            if ([string]::IsNullOrWhiteSpace([string]$val)) { continue }
                            if (-not (Test-CdeDriverFilterAllowlisted -FilterName ([string]$val) -Allowlist $allowFilters)) {
                                $findings += New-HealthFinding -FindingId 'driver.filter.registry' -CheckId 'driver_signature_audit' `
                                    -Subject ([string]$val) -Finding ("Unexpected $propName entry") `
                                    -Impact 'Unexpected class filter registrations should be reviewed.' `
                                    -Severity 'Medium' -Confidence 58 -Status 'Warn' `
                                    -Evidence @("$key\$propName = $val")
                            }
                        }
                    }
                } catch { }
            }

            $warnCount = @($findings | Where-Object { $_.Status -eq 'Warn' }).Count
            $detail = "$($drivers.Count) drivers | $($unsignedDrivers.Count) unsigned | $($unexpectedFilters.Count) unexpected filters"
            $step = @{
                Name            = 'DriverAudit'
                Status          = if ($warnCount -gt 0) { 'Warn' } else { 'Pass' }
                Detail          = $detail
                Output          = $output
                UnsignedDrivers = $unsignedDrivers
                CheckId         = 'driver_signature_audit'
            }
            Add-HealthFindingsToStep -Step $step -Findings $findings -SummaryText $detail
            Add-HealthCheckStep $r $step
            Write-Log "Drivers: $($drivers.Count) total, $($unsignedDrivers.Count) unsigned, $($unexpectedFilters.Count) unexpected filters"
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
        $findings = @()
        if ($evaluation.Status -in @('Warn', 'Fail')) {
            $findings += New-HealthFinding -FindingId 'update.service.stack' -CheckId 'windows_update_service' `
                -Finding 'Windows Update stack needs attention' -Impact 'Updates may fail to download or install.' `
                -Severity $(if ($evaluation.Status -eq 'Fail') { 'High' } else { 'Medium' }) `
                -Confidence 85 -Status $evaluation.Status -Evidence @([string]$evaluation.Summary) `
                -Recommendations @('Use Fast Fixes / Windows Update Repair to restore wuauserv, BITS, and UsoSvc.') `
                -Actions @(
                    @{ type = 'cde'; target = 'FastFixes'; label = 'Fast Fixes' }
                    @{ type = 'cde'; target = 'WindowsUpdateRepair'; label = 'Windows Update Repair' }
                )
        }
        else {
            $findings += New-HealthFinding -FindingId 'update.service.ok' -CheckId 'windows_update_service' `
                -Finding 'Windows Update stack looks healthy' -Impact 'Core update services are in an expected state.' `
                -Severity 'Info' -Confidence 85 -Status 'Pass' -Evidence @([string]$evaluation.Summary)
        }
        $step = @{
            Name    = 'WindowsUpdateService'
            Status  = $evaluation.Status
            Detail  = $evaluation.Summary
            Output  = $formatted
            Services = $services
            CheckId = 'windows_update_service'
        }
        Add-HealthFindingsToStep -Step $step -Findings $findings -SummaryText $evaluation.Summary
        $r.Steps.Add([PSCustomObject]$step)
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
        $detail = "$($adapters.Count) adapter(s) found ($upCount up)"
        $step = @{
            Name     = 'NetworkAdapters'
            Status   = 'Pass'
            Detail   = $detail
            Output   = $output
            Adapters = $adapters | Select-Object Name, InterfaceDescription, Status, LinkSpeed, MacAddress, MediaType, DriverVersion, DriverDate, ifIndex
            CheckId  = 'network_adapters'
        }
        Add-HealthFindingsToStep -Step $step -Findings @(
            New-InventoryHealthFinding -CheckId 'network_adapters' -Finding $detail -Evidence @($detail)
        ) -SummaryText $detail
        Add-HealthCheckStep $r $step
    } catch {
        try {
            $adapters = @(Get-CimInstance -ClassName Win32_NetworkAdapter | Where-Object { $_.NetEnabled })
            $output = Format-NetworkAdapters -Adapters $adapters
            $detail = "$($adapters.Count) adapter(s) found (via WMI)"
            $step = @{
                Name    = 'NetworkAdapters'
                Status  = 'Pass'
                Detail  = $detail
                Output  = $output
                CheckId = 'network_adapters'
            }
            Add-HealthFindingsToStep -Step $step -Findings @(
                New-InventoryHealthFinding -CheckId 'network_adapters' -Finding $detail -Evidence @($detail)
            ) -SummaryText $detail
            Add-HealthCheckStep $r $step
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
        # AdapterRAM from Win32_VideoController is uint32 and saturates near 4 GB.
        # Enrich with registry QWORD (HardwareInformation.qwMemorySize) when available.
        $gpus = @(Get-CimInstance -ClassName Win32_VideoController | ForEach-Object {
            $vramBytes = Get-GpuDedicatedVideoRamBytes -Gpu $_
            $_ | Add-Member -NotePropertyName DedicatedVideoRAM -NotePropertyValue $vramBytes -Force -PassThru
        })
        $output = Format-GpuInfo -Gpus $gpus
        $names = ($gpus | ForEach-Object { $_.Caption }) -join '; '
        $detail = if ($gpus.Count -gt 0) { $names } else { 'No video controllers reported' }
        $step = @{
            Name    = 'GPUInfo'
            Status  = 'Pass'
            Detail  = $detail
            Output  = $output
            GPUs    = $gpus | Select-Object Caption, DriverVersion, DriverDate,
                @{ Name = 'VideoRAM'; Expression = { $_.DedicatedVideoRAM } },
                @{ Name = 'AdapterRAM'; Expression = { $_.DedicatedVideoRAM } },
                VideoProcessor, CurrentHorizontalResolution, CurrentVerticalResolution,
                CurrentRefreshRate, VideoModeDescription, Status, PNPDeviceID
            CheckId = 'gpu_info'
        }
        Add-HealthFindingsToStep -Step $step -Findings @(
            New-InventoryHealthFinding -CheckId 'gpu_info' -Finding $detail -Evidence @(
                foreach ($g in $gpus) { "{0} | Driver {1}" -f $g.Caption, $g.DriverVersion }
            )
        ) -SummaryText $detail
        Add-HealthCheckStep $r $step
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

function Get-CdeGpuDiagCliPath {
    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($env:TOOLKIT_ROOT)) {
        $root = $env:TOOLKIT_ROOT.TrimEnd('\')
        $candidates.Add((Join-Path $root 'CDE\ToolkitGUI\bin\Release\net8.0-windows\CdeGpuDiagCli.exe'))
        $candidates.Add((Join-Path $root 'App\ToolkitGUI\bin\Release\net8.0-windows\CdeGpuDiagCli.exe'))
    }
    $coreDir = $PSScriptRoot
    $candidates.Add((Join-Path $coreDir '..\..\CDE\ToolkitGUI\bin\Release\net8.0-windows\CdeGpuDiagCli.exe'))
    $candidates.Add((Join-Path $coreDir '..\..\App\ToolkitGUI\bin\Release\net8.0-windows\CdeGpuDiagCli.exe'))
    foreach ($rel in $candidates) {
        try {
            $full = [IO.Path]::GetFullPath($rel)
            if (Test-Path -LiteralPath $full) { return $full }
        } catch { }
    }
    return $null
}

function Invoke-CdeGpuDiagCli {
    param(
        [Parameter(Mandatory)][string]$Arguments,
        [int]$TimeoutMs = 120000
    )

    $cli = Get-CdeGpuDiagCliPath
    if (-not $cli) {
        return [PSCustomObject]@{ Ok = $false; ExitCode = 3; StdOut = ''; StdErr = 'CdeGpuDiagCli.exe not found in toolkit payload.'; TimedOut = $false }
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $cli
    $psi.Arguments = $Arguments
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($TimeoutMs)) {
        try { $proc.Kill($true) } catch { try { $proc.Kill() } catch { } }
        return [PSCustomObject]@{ Ok = $false; ExitCode = -1; StdOut = ''; StdErr = "CdeGpuDiagCli timed out after $($TimeoutMs)ms."; TimedOut = $true }
    }
    return [PSCustomObject]@{
        Ok = ($proc.ExitCode -eq 0)
        ExitCode = $proc.ExitCode
        StdOut = $stdoutTask.Result
        StdErr = $stderrTask.Result
        TimedOut = $false
    }
}

function Invoke-HealthCheck_gpu_functional_tests {
    param($r)
    Write-Log 'Running GPU functional tests...'
    try {
        if ((Get-EnvironmentMode) -ne 'Windows') {
            $step = @{
                Name = 'GpuFunctionalTests'; Status = 'N/A'
                Detail = 'GPU functional tests require a live Windows session.'
                Output = 'GPU functional tests are not available in WinPE.'
                CheckId = 'gpu_functional_tests'
            }
            Add-HealthFindingsToStep -Step $step -Findings @(
                New-HealthFinding -FindingId 'gpu.functional.unavailable_winpe' -CheckId 'gpu_functional_tests' `
                    -Finding 'GPU functional tests unavailable in WinPE' `
                    -Impact 'Active DirectX/OpenGL/Vulkan tests need a full Windows graphics stack.' `
                    -Severity 'Info' -Confidence 100 -Status 'N/A' -Evidence @('Environment: WinPE')
            ) -SummaryText $step.Detail
            Add-HealthCheckStep $r $step
            return
        }

        $result = Invoke-CdeGpuDiagCli -Arguments 'test-all' -TimeoutMs 180000
        if ($result.TimedOut -or $result.ExitCode -eq 3 -or [string]::IsNullOrWhiteSpace($result.StdOut)) {
            $msg = if ($result.StdErr) { $result.StdErr } else { 'GPU diagnostic helper returned no output.' }
            $step = @{
                Name = 'GpuFunctionalTests'; Status = 'Skip'; Detail = $msg; Output = $msg; CheckId = 'gpu_functional_tests'
            }
            Add-HealthFindingsToStep -Step $step -Findings @(
                New-HealthFinding -FindingId 'gpu.functional.helper_unavailable' -CheckId 'gpu_functional_tests' `
                    -Finding 'GPU diagnostic helper unavailable' -Impact 'Functional GPU tests could not run.' `
                    -Severity 'Low' -Confidence 70 -Status 'Skip' -Evidence @($msg) `
                    -Recommendations @('Republish the toolkit so CdeGpuDiagCli.exe is present beside ToolkitGUI.')
            ) -SummaryText $msg
            Add-HealthCheckStep $r $step
            return
        }

        $payload = $result.StdOut | ConvertFrom-Json
        $findings = New-Object System.Collections.Generic.List[object]
        $summaryLines = New-Object System.Collections.Generic.List[string]
        foreach ($adapter in @($payload.adapters)) {
            $adapterName = [string]$adapter.name
            if ([string]::IsNullOrWhiteSpace($adapterName)) { $adapterName = 'Unknown GPU' }
            $summaryLines.Add($adapterName)
            foreach ($test in @($adapter.tests)) {
                $testName = [string]$test.name
                $testStatus = [string]$test.status
                $detail = [string]$test.detail
                $summaryLines.Add(("  {0}: {1}{2}" -f $testName, $testStatus, $(if ($detail) { " - $detail" } else { '' })))
                $findingStatus = switch -Regex ($testStatus) {
                    '^(?i)fail$' { 'Fail' }
                    '^(?i)warn$' { 'Warn' }
                    '^(?i)pass$' { 'Pass' }
                    '^(?i)n/?a$' { 'N/A' }
                    default { 'Info' }
                }
                $severity = switch ($findingStatus) {
                    'Fail' { 'High' }
                    'Warn' { 'Medium' }
                    default { 'Info' }
                }
                $safeId = ($testName -replace '[^\w]+', '_').ToLowerInvariant()
                $recs = @()
                if ($test.recommendations) { $recs = @($test.recommendations) }
                $impact = if ($findingStatus -eq 'Fail') { [string]$test.impact } elseif ($findingStatus -eq 'N/A') { 'Test not applicable on this adapter/environment.' } else { 'Test completed.' }
                $findings.Add((New-HealthFinding `
                    -FindingId ("gpu.functional.{0}" -f $safeId) `
                    -CheckId 'gpu_functional_tests' `
                    -Subject $adapterName `
                    -Finding ("{0}: {1}" -f $testName, $testStatus) `
                    -Impact $impact `
                    -Severity $severity `
                    -Confidence $(if ($test.confidence) { [int]$test.confidence } else { 80 }) `
                    -Status $findingStatus `
                    -Evidence @($(if ($detail) { $detail } else { "$testName=$testStatus" })) `
                    -Recommendations $recs `
                    -Actions $(if ($findingStatus -eq 'Fail') { @(@{ type = 'shell'; target = 'devmgmt.msc'; label = 'Device Manager' }) } else { @() })))
            }
        }

        if ($findings.Count -eq 0) {
            $findings.Add((New-HealthFinding -FindingId 'gpu.functional.none' -CheckId 'gpu_functional_tests' `
                -Finding 'No GPU adapters were tested' -Impact 'No video controllers were available for functional testing.' `
                -Severity 'Low' -Confidence 70 -Status 'Warn' -Evidence @('adapters: 0')))
        }

        $step = @{
            Name = 'GpuFunctionalTests'; Status = 'Pass'
            Detail = "GPU functional tests completed for $(@($payload.adapters).Count) adapter(s)."
            Output = ($summaryLines -join "`n")
            CheckId = 'gpu_functional_tests'
        }
        Add-HealthFindingsToStep -Step $step -Findings @($findings.ToArray()) -SummaryText $step.Detail
        Add-HealthCheckStep $r $step
    } catch {
        Add-HealthCheckStep $r @{
            Name = 'GpuFunctionalTests'; Status = 'Skip'
            Detail = $_.Exception.Message; Output = $_.Exception.Message; CheckId = 'gpu_functional_tests'
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

        $findings = @(Invoke-EventFindingClustering -CheckId 'critical_events_7d' -Events $critical)
        $step = @{
            Name             = 'CriticalEvents'
            Status           = if ($eventCount -gt 20) { 'Warn' } else { 'Pass' }
            Detail           = $detailText
            Output           = $summaryText
            EventCount       = $eventCount
            EventSummary     = @($eventSummary)
            Events           = $critical | Select-Object TimeCreated, ProviderName, Id, Message -First 20
            EventsExportPath = $eventsExportPath
            CheckId          = 'critical_events_7d'
        }
        if ($findings.Count -gt 0) {
            Add-HealthFindingsToStep -Step $step -Findings $findings -SummaryText $detailText
        }
        $r.Steps.Add([PSCustomObject]$step)
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
        gpu_functional_tests     = { param($r, $ctx) Invoke-HealthCheck_gpu_functional_tests $r }
        critical_events_7d       = { param($r, $ctx) Invoke-HealthCheck_critical_events_7d -r $r -EventsExportScriptDir $ctx.WorkflowsDir }
    }
}
