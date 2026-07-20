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

function Get-SustainedCpuLoadSample {
    <#
    .SYNOPSIS
        Multi-sample Win32_Processor.LoadPercentage average (not a single snapshot).
    .NOTES
        A single WMI LoadPercentage read is a point-in-time value and is noisy under
        bench load. Averaging several spaced samples reduces false Warns. WMI
        performance counters are interval-based and need refresh spacing for
        meaningful utilization (Microsoft WMI performance monitoring guidance).
    #>
    param(
        [int]$SampleCount = 3,
        [int]$IntervalMs = 2000
    )

    if ($SampleCount -lt 2) { $SampleCount = 2 }
    if ($IntervalMs -lt 500) { $IntervalMs = 500 }

    $samples = New-Object System.Collections.Generic.List[double]
    $processors = @()
    for ($i = 0; $i -lt $SampleCount; $i++) {
        $processors = @(Get-CimInstance Win32_Processor)
        $avg = ($processors | Measure-Object -Property LoadPercentage -Average).Average
        if ($null -eq $avg) { $avg = 0 }
        [void]$samples.Add([double]$avg)
        if ($i -lt ($SampleCount - 1)) {
            Start-Sleep -Milliseconds $IntervalMs
        }
    }

    $arr = @($samples.ToArray())
    $average = ($arr | Measure-Object -Average).Average
    $minimum = ($arr | Measure-Object -Minimum).Minimum
    $highCount = @($arr | Where-Object { $_ -gt 90 }).Count

    return [PSCustomObject]@{
        Samples         = $arr
        Average         = [double]$average
        Minimum         = [double]$minimum
        HighSampleCount = [int]$highCount
        SampleCount     = [int]$SampleCount
        Processors      = $processors
        IsSustainedHigh = ($average -gt 90 -and $highCount -ge 2)
    }
}

function Get-SustainedRamUsageSample {
    param(
        [int]$SampleCount = 3,
        [int]$IntervalMs = 1500
    )

    if ($SampleCount -lt 2) { $SampleCount = 2 }
    if ($IntervalMs -lt 500) { $IntervalMs = 500 }

    $samples = New-Object System.Collections.Generic.List[double]
    $osObj = $null
    for ($i = 0; $i -lt $SampleCount; $i++) {
        $osObj = Get-CimInstance Win32_OperatingSystem
        $total = [double]$osObj.TotalVisibleMemorySize
        $free = [double]$osObj.FreePhysicalMemory
        $usedPct = if ($total -gt 0) { (($total - $free) / $total) * 100.0 } else { 0 }
        [void]$samples.Add([double]$usedPct)
        if ($i -lt ($SampleCount - 1)) {
            Start-Sleep -Milliseconds $IntervalMs
        }
    }

    $arr = @($samples.ToArray())
    $average = ($arr | Measure-Object -Average).Average
    $minimum = ($arr | Measure-Object -Minimum).Minimum
    $highCount = @($arr | Where-Object { $_ -gt 90 }).Count

    return [PSCustomObject]@{
        Samples         = $arr
        Average         = [double]$average
        Minimum         = [double]$minimum
        HighSampleCount = [int]$highCount
        SampleCount     = [int]$SampleCount
        Os              = $osObj
        IsSustainedHigh = ($average -gt 90 -and $highCount -ge 2)
    }
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
        $sample = Get-SustainedCpuLoadSample -SampleCount 3 -IntervalMs 2000
        $processors = @($sample.Processors)
        $cpuLoad = [math]::Round($sample.Average, 1)
        $sampleText = ($sample.Samples | ForEach-Object { '{0:N1}%' -f $_ }) -join ', '
        $cpuStatus = if ($sample.IsSustainedHigh) { 'Warn' } else { 'Pass' }
        $output = Format-HealthCheckCpuLoad -Processors $processors
        $detail = "$cpuLoad% sustained average across $($processors.Count) processor package(s) ($($sample.SampleCount) samples: $sampleText)"
        $findings = @()
        if ($sample.IsSustainedHigh) {
            $findings += New-HealthFinding -FindingId 'health.cpu.high_load' -CheckId 'cpu_load' `
                -Finding 'CPU load is critically high' -Impact 'The system may feel slow or unresponsive under this load.' `
                -Severity 'High' -Confidence 90 -Status 'Warn' -Classification 'CorroboratedSuspect' `
                -Evidence @($detail, ("Minimum sample: {0:N1}%" -f $sample.Minimum)) `
                -Recommendations @('Inspect top CPU consumers in Process Analyzer.', 'Close runaway apps or scan for malware if unexplained.') `
                -Actions @(@{ type = 'cde'; target = 'ProcessAnalyzer:HighCpu'; label = 'Process Analyzer (high CPU)' })
        }
        else {
            $findings += New-HealthFinding -FindingId 'health.cpu.load_ok' -CheckId 'cpu_load' `
                -Finding 'CPU load is within normal range' -Impact 'No sustained CPU pressure indicated across timed samples.' `
                -Severity 'Info' -Confidence 85 -Status 'Pass' -Evidence @($detail)
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
        $sample = Get-SustainedRamUsageSample -SampleCount 3 -IntervalMs 1500
        $osObj = $sample.Os
        $memMods = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue)
        $totalGB = [math]::Round($osObj.TotalVisibleMemorySize / 1MB, 1)
        $freeGB  = [math]::Round($osObj.FreePhysicalMemory / 1MB, 1)
        $usedPct = [math]::Round($sample.Average, 1)
        $sampleText = ($sample.Samples | ForEach-Object { '{0:N1}%' -f $_ }) -join ', '
        $ramStatus = if ($sample.IsSustainedHigh) { 'Warn' } else { 'Pass' }
        $output = Format-HealthCheckRam -Os $osObj -PhysicalMemory $memMods
        $detail = "Used $usedPct% sustained | Free ${freeGB}GB of ${totalGB}GB ($($sample.SampleCount) samples: $sampleText)"
        $findings = @()
        if ($sample.IsSustainedHigh) {
            $findings += New-HealthFinding -FindingId 'health.memory.high_usage' -CheckId 'ram' `
                -Finding 'Memory usage is critically high' -Impact 'Applications may thrash to disk and feel unresponsive.' `
                -Severity 'High' -Confidence 90 -Status 'Warn' -Classification 'CorroboratedSuspect' `
                -Evidence @($detail, ("Minimum sample: {0:N1}%" -f $sample.Minimum)) `
                -Recommendations @('Inspect top memory consumers in Process Analyzer.', 'Consider closing browsers/apps or adding RAM if chronic.') `
                -Actions @(@{ type = 'cde'; target = 'ProcessAnalyzer:HighRam'; label = 'Process Analyzer (high RAM)' })
        }
        else {
            $findings += New-HealthFinding -FindingId 'health.memory.usage_ok' -CheckId 'ram' `
                -Finding 'Memory usage is within normal range' -Impact 'No sustained memory pressure indicated across timed samples.' `
                -Severity 'Info' -Confidence 85 -Status 'Pass' -Evidence @($detail)
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

function Get-BatteryHealthSnapshot {
    <#
    .SYNOPSIS
      Design vs full-charge capacity from ROOT\WMI (powercfg-equivalent sources).
      Win32_Battery DesignCapacity/FullChargeCapacity are often empty on modern PCs.
    #>
    $designed = 0
    $full = 0
    $cycles = $null
    $name = ''

    try {
        $static = @(Get-CimInstance -Namespace 'root\wmi' -ClassName BatteryStaticData -ErrorAction SilentlyContinue)
        if ($static.Count -gt 0) {
            $designed = [int64]($static | Measure-Object -Property DesignedCapacity -Sum).Sum
            $name = [string]($static[0].DeviceName)
            if ([string]::IsNullOrWhiteSpace($name)) { $name = [string]$static[0].ManufactureName }
        }
    } catch { }

    try {
        $fullRows = @(Get-CimInstance -Namespace 'root\wmi' -ClassName BatteryFullChargedCapacity -ErrorAction SilentlyContinue)
        if ($fullRows.Count -gt 0) {
            $full = [int64]($fullRows | Measure-Object -Property FullChargedCapacity -Sum).Sum
        }
    } catch { }

    try {
        $cycleRows = @(Get-CimInstance -Namespace 'root\wmi' -ClassName BatteryCycleCount -ErrorAction SilentlyContinue)
        if ($cycleRows.Count -gt 0) {
            $cycles = [int]($cycleRows | Measure-Object -Property CycleCount -Sum).Sum
        }
    } catch { }

    $hasBattery = ($designed -gt 0 -and $full -gt 0)
    $healthPct = if ($hasBattery) { [math]::Round(100.0 * $full / $designed, 1) } else { $null }
    $wearPct = if ($null -ne $healthPct) { [math]::Round(100.0 - $healthPct, 1) } else { $null }

    return [PSCustomObject]@{
        HasBattery       = $hasBattery
        DesignedCapacity = $designed
        FullCapacity     = $full
        HealthPercent    = $healthPct
        WearPercent      = $wearPct
        CycleCount       = $cycles
        Name             = $name
    }
}

function Invoke-HealthCheck_battery_health {
    param($r)
    if ((Get-EnvironmentMode) -ne 'Windows') { return }

    try {
        $snap = Get-BatteryHealthSnapshot
        $output = ''
        $findings = @()
        $status = 'Pass'
        $detail = ''

        if (-not $snap.HasBattery) {
            $detail = 'No battery capacity data (desktop or battery WMI unavailable)'
            $output = @"
Battery
--------
Present: No / unavailable
"@
            $findings += New-HealthFinding -FindingId 'health.battery.none' -CheckId 'battery_health' `
                -Finding 'No battery health data' -Impact 'Expected on desktops or when ROOT\WMI battery classes are empty.' `
                -Severity 'Info' -Confidence 90 -Status 'Pass' -Classification 'Inventory' `
                -Evidence @($detail)
        }
        else {
            $cycleText = if ($null -ne $snap.CycleCount) { [string]$snap.CycleCount } else { 'n/a' }
            $detail = ("Health {0}% of design (wear {1}%) | cycles {2}" -f $snap.HealthPercent, $snap.WearPercent, $cycleText)
            $output = @"
Battery Health
--------------
Name: $(if ($snap.Name) { $snap.Name } else { 'Battery' })
Designed (mWh): $($snap.DesignedCapacity)
Full charge (mWh): $($snap.FullCapacity)
Health %: $($snap.HealthPercent)
Wear %: $($snap.WearPercent)
Cycle count: $cycleText
"@

            if ($snap.HealthPercent -lt 60) {
                $status = 'Warn'
                $findings += New-HealthFinding -FindingId 'health.battery.worn' -CheckId 'battery_health' `
                    -Finding 'Battery capacity severely degraded' `
                    -Impact 'Runtime will be short; unexpected shutdowns under load are more likely.' `
                    -Severity 'High' -Confidence 88 -Status 'Warn' -Classification 'CorroboratedSuspect' `
                    -Evidence @($detail) `
                    -Recommendations @('Replace the battery if the device must run on AC-off power.', 'Confirm with powercfg /batteryreport if needed.')
            }
            elseif ($snap.HealthPercent -lt 80) {
                $status = 'Warn'
                $findings += New-HealthFinding -FindingId 'health.battery.wear' -CheckId 'battery_health' `
                    -Finding 'Battery capacity below 80% of design' `
                    -Impact 'Reduced unplugged runtime; plan replacement if the user relies on battery.' `
                    -Severity 'Medium' -Confidence 82 -Status 'Warn' -Classification 'SingleSignal' `
                    -Evidence @($detail) `
                    -Recommendations @('Advise the user of reduced runtime.', 'Re-check after a full charge cycle if the reading looks stale.')
            }
            else {
                $findings += New-HealthFinding -FindingId 'health.battery.ok' -CheckId 'battery_health' `
                    -Finding 'Battery capacity within acceptable range' `
                    -Impact 'No significant wear indicated by design vs full-charge capacity.' `
                    -Severity 'Info' -Confidence 85 -Status 'Pass' -Evidence @($detail)
            }
        }

        $step = @{
            Name    = 'BatteryHealth'
            Status  = $status
            Detail  = $detail
            Output  = $output
            CheckId = 'battery_health'
        }
        Add-HealthFindingsToStep -Step $step -Findings $findings -SummaryText $detail
        Add-HealthCheckStep $r $step
    }
    catch {
        Add-HealthCheckStep $r @{
            Name    = 'BatteryHealth'
            Status  = 'Skip'
            Detail  = 'Unable to read battery WMI'
            Output  = $_.Exception.Message
            CheckId = 'battery_health'
        }
    }
    Write-Log "Battery: $($r.Steps[-1].Detail)"
}

function Get-ThermalEventCount7d {
    param([datetime]$Since = (Get-Date).AddDays(-7))

    # Kernel-Power / ACPI thermal-related IDs commonly used for trip and thermal zone noise.
    $ids = @(86, 89, 90, 91, 96, 112, 115, 125, 161, 178, 179, 185)
    $events = @()
    try {
        $events = @(Get-WinEvent -FilterHashtable @{
            LogName      = 'System'
            ProviderName = 'Microsoft-Windows-Kernel-Power'
            Id           = $ids
            StartTime    = $Since
        } -ErrorAction SilentlyContinue)
    } catch {
        try {
            $events = @(Get-WinEvent -FilterHashtable @{
                LogName   = 'System'
                Id        = $ids
                StartTime = $Since
            } -ErrorAction SilentlyContinue | Where-Object {
                $_.ProviderName -match '(?i)Kernel-Power|ACPI'
            })
        } catch { }
    }
    return @($events)
}

function Invoke-HealthCheck_thermal_events {
    param($r)
    if ((Get-EnvironmentMode) -ne 'Windows') { return }

    try {
        $events = @(Get-ThermalEventCount7d)
        $count = $events.Count
        $criticalish = @($events | Where-Object {
            [string]$_.Message -match '(?i)critical|emergency|shutdown|thermal trip|_CRT'
        }).Count

        $sample = @($events | Select-Object -First 5 | ForEach-Object {
            $msg = ([string]$_.Message -replace '\s+', ' ').Trim()
            if ($msg.Length -gt 80) { $msg = $msg.Substring(0, 80) + '...' }
            '{0:u} Id {1}: {2}' -f $_.TimeCreated, $_.Id, $msg
        })

        $output = @"
Thermal Events (7 days)
-----------------------
Kernel-Power/ACPI thermal events: $count
Critical-trip-like messages: $criticalish
"@
        if ($sample.Count -gt 0) {
            $output += "`nRecent:`n" + (($sample | ForEach-Object { "  - $_" }) -join "`n")
        }

        $findings = @()
        $status = 'Pass'
        $detail = "$count thermal-related System events in 7 days ($criticalish critical-like)"

        if ($criticalish -ge 1 -or $count -ge 5) {
            $status = 'Warn'
            $sev = if ($criticalish -ge 1) { 'High' } else { 'Medium' }
            $cls = if ($criticalish -ge 1) { 'CorroboratedSuspect' } else { 'SingleSignal' }
            $findings += New-HealthFinding -FindingId 'health.thermal.events' -CheckId 'thermal_events' `
                -Finding 'Thermal warning events detected' `
                -Impact 'Overheating can cause throttling, unexpected shutdowns, or hardware stress.' `
                -Severity $sev -Confidence 80 -Status 'Warn' -Classification $cls `
                -Evidence (@($detail) + $sample) `
                -Recommendations @('Check vents/dust and ambient temperature.', 'Run Diag & Repair CPU stress and CHU if shutdowns continue.') `
                -Actions @(@{ type = 'cde'; target = 'HardwareDiagnostics'; label = 'Diag & Repair' })
        }
        else {
            $findings += New-HealthFinding -FindingId 'health.thermal.ok' -CheckId 'thermal_events' `
                -Finding 'No significant thermal event volume' `
                -Impact 'No Kernel-Power/ACPI thermal cluster in the last 7 days.' `
                -Severity 'Info' -Confidence 75 -Status 'Pass' -Evidence @($detail)
        }

        $step = @{
            Name    = 'ThermalEvents'
            Status  = $status
            Detail  = $detail
            Output  = $output
            CheckId = 'thermal_events'
        }
        Add-HealthFindingsToStep -Step $step -Findings $findings -SummaryText $detail
        Add-HealthCheckStep $r $step
    }
    catch {
        Add-HealthCheckStep $r @{
            Name    = 'ThermalEvents'
            Status  = 'Skip'
            Detail  = 'Unable to read thermal events'
            Output  = $_.Exception.Message
            CheckId = 'thermal_events'
        }
    }
    Write-Log "Thermal: $($r.Steps[-1].Detail)"
}

function Invoke-HealthCheck_reliability_monitor {
    param($r)
    if ((Get-EnvironmentMode) -ne 'Windows') { return }

    try {
        $since = (Get-Date).AddDays(-7)
        $index = $null
        try {
            $metrics = @(Get-CimInstance -ClassName Win32_ReliabilityStabilityMetrics -ErrorAction SilentlyContinue |
                Sort-Object TimeGenerated -Descending | Select-Object -First 1)
            if ($metrics.Count -gt 0 -and $null -ne $metrics[0].SystemStabilityIndex) {
                $index = [math]::Round([double]$metrics[0].SystemStabilityIndex, 2)
            }
        } catch { }

        $records = @()
        try {
            $records = @(Get-CimInstance -ClassName Win32_ReliabilityRecords -ErrorAction SilentlyContinue |
                Where-Object {
                    $tg = $_.TimeGenerated
                    if ($tg -is [string]) {
                        try { $tg = [System.Management.ManagementDateTimeConverter]::ToDateTime($tg) } catch { $tg = $null }
                    }
                    $tg -and $tg -ge $since -and (
                        [string]$_.SourceName -match '(?i)(BugCheck|Windows Error Reporting|Application Error|WER)' -or
                        [int]$_.EventIdentifier -in @(1001, 1000, 41)
                    )
                })
        } catch { }

        $recCount = $records.Count
        $detailParts = @()
        if ($null -ne $index) { $detailParts += "Stability index $index" }
        $detailParts += "$recCount critical-ish reliability records (7d)"
        $detail = $detailParts -join ' | '

        $output = @"
Reliability Monitor
-------------------
Stability index: $(if ($null -ne $index) { $index } else { 'n/a' })
Critical-ish records (7d): $recCount
"@

        $findings = @()
        $status = 'Pass'

        if ($null -eq $index -and $recCount -eq 0) {
            $status = 'Incomplete'
            $findings += New-HealthFinding -FindingId 'health.reliability.unavailable' -CheckId 'reliability_monitor' `
                -Finding 'Reliability WMI data unavailable' `
                -Impact 'Cannot assess RAC metrics (policy disabled on some Server SKUs).' `
                -Severity 'Info' -Confidence 90 -Status 'N/A' -Classification 'Incomplete' `
                -Evidence @('Win32_ReliabilityStabilityMetrics / Records returned no usable data')
        }
        elseif (($null -ne $index -and $index -lt 5.0) -or $recCount -ge 5) {
            $status = 'Warn'
            $sev = if (($null -ne $index -and $index -lt 3.0) -or $recCount -ge 10) { 'High' } else { 'Medium' }
            $findings += New-HealthFinding -FindingId 'health.reliability.low' -CheckId 'reliability_monitor' `
                -Finding 'Reliability Monitor indicates instability' `
                -Impact 'Frequent failures reduce Stability Index; investigate crashes and application faults.' `
                -Severity $sev -Confidence 78 -Status 'Warn' -Classification 'SingleSignal' `
                -Evidence @($detail) `
                -Recommendations @('Open Reliability Monitor (perfmon /rel) for the failure timeline.', 'Cross-check Critical Events (7 days).') `
                -Actions @(
                    @{ type = 'shell'; target = 'perfmon /rel'; label = 'Reliability Monitor' },
                    @{ type = 'cde'; target = 'SystemHealth'; label = 'System Health Check' }
                )
        }
        else {
            $findings += New-HealthFinding -FindingId 'health.reliability.ok' -CheckId 'reliability_monitor' `
                -Finding 'Reliability metrics look stable' `
                -Impact 'No strong instability signal from RAC metrics in the last 7 days.' `
                -Severity 'Info' -Confidence 75 -Status 'Pass' -Evidence @($detail)
        }

        $step = @{
            Name    = 'ReliabilityMonitor'
            Status  = $status
            Detail  = $detail
            Output  = $output
            CheckId = 'reliability_monitor'
        }
        Add-HealthFindingsToStep -Step $step -Findings $findings -SummaryText $detail
        Add-HealthCheckStep $r $step
    }
    catch {
        Add-HealthCheckStep $r @{
            Name    = 'ReliabilityMonitor'
            Status  = 'Skip'
            Detail  = 'Unable to read reliability WMI'
            Output  = $_.Exception.Message
            CheckId = 'reliability_monitor'
        }
    }
    Write-Log "Reliability: $($r.Steps[-1].Detail)"
}

function Get-HealthCheckStepDispatchMap {
    return @{
        os_version               = { param($r, $ctx) Invoke-HealthCheck_os_version $r }
        cpu_load                 = { param($r, $ctx) Invoke-HealthCheck_cpu_load $r }
        ram                      = { param($r, $ctx) Invoke-HealthCheck_ram $r }
        disk_space               = { param($r, $ctx) Invoke-HealthCheck_disk_space $r }
        activation               = { param($r, $ctx) Invoke-HealthCheck_activation $r }
        battery_health           = { param($r, $ctx) Invoke-HealthCheck_battery_health $r }
        event_errors_24h         = { param($r, $ctx) Invoke-HealthCheck_event_errors_24h $r }
        system_info              = { param($r, $ctx) Invoke-HealthCheck_system_info $r }
        driver_signature_audit   = { param($r, $ctx) Invoke-HealthCheck_driver_signature_audit $r }
        windows_update_service   = { param($r, $ctx) Invoke-HealthCheck_windows_update_service $r }
        network_adapters         = { param($r, $ctx) Invoke-HealthCheck_network_adapters $r }
        gpu_info                 = { param($r, $ctx) Invoke-HealthCheck_gpu_info $r }
        gpu_functional_tests     = { param($r, $ctx) Invoke-HealthCheck_gpu_functional_tests $r }
        thermal_events           = { param($r, $ctx) Invoke-HealthCheck_thermal_events $r }
        reliability_monitor      = { param($r, $ctx) Invoke-HealthCheck_reliability_monitor $r }
        critical_events_7d       = { param($r, $ctx) Invoke-HealthCheck_critical_events_7d -r $r -EventsExportScriptDir $ctx.WorkflowsDir }
    }
}
