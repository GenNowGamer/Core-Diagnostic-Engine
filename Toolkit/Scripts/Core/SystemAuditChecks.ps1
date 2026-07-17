#Requires -Version 5.1
<#
.SYNOPSIS
    System audit check functions used by SystemHealthCheck.ps1.
#>

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $MyInvocation.MyCommand.Path }
$StartupRiskScript = Join-Path $ScriptDir 'StartupRisk.ps1'
if (Test-Path $StartupRiskScript) { . $StartupRiskScript }
function Get-OfflineWindowsRoot {
    $root = $env:OFFLINE_WINDOWS_ROOT
    if ([string]::IsNullOrWhiteSpace($root)) {
        return ''
    }

    $normalized = $root.Trim()
    if (-not $normalized.EndsWith('\')) {
        $normalized += '\'
    }

    if (Test-Path (Join-Path $normalized 'Windows')) {
        return $normalized
    }

    return ''
}

function Get-OfflineControlSet {
    $controlSet = 'ControlSet001'
    try {
        $select = Get-ItemProperty -Path 'HKLM:\Offline_SYSTEM\Select' -ErrorAction Stop
        if ($null -ne $select.Current) {
            $controlSet = ('ControlSet{0:d3}' -f [int]$select.Current)
        }
    } catch {
        # Keep default fallback.
    }

    return $controlSet
}

function Invoke-InstalledSoftwareAudit {
    param($r)
    Write-Log "Enumerating installed software..."
    try {
        $isWinPe = ((Get-EnvironmentMode) -eq 'WinPE')
        $offlineLoaded = ($env:OFFLINE_REGISTRY_LOADED -eq '1')
        $regPaths = @()

        if ($isWinPe -and $offlineLoaded) {
            Write-Log "Using offline registry hives for installed software audit."
            $regPaths += 'HKLM:\Offline_SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
            $regPaths += 'HKLM:\Offline_SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'

            $offlineUsers = Get-ChildItem -Path 'HKU:' -ErrorAction SilentlyContinue |
                Where-Object { $_.PSChildName -like 'Offline_*' }

            foreach ($userHive in $offlineUsers) {
                $regPaths += ("HKU:\{0}\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" -f $userHive.PSChildName)
            }
        } else {
            $regPaths += 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
            $regPaths += 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
            $regPaths += 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        }

        $software = foreach ($p in $regPaths) {
            if (Test-Path ($p -replace '\\\*','')) {
                Get-ItemProperty $p -ErrorAction SilentlyContinue |
                    Where-Object {
                        $_.DisplayName -and
                        [string]$_.DisplayName -notmatch '\$\{\{'
                    } |
                    Select-Object DisplayName, DisplayVersion, Publisher, InstallLocation, InstallDate, DisplayIcon, UninstallString
            }
        }
        $software = $software | Sort-Object DisplayName -Unique

        if ($null -eq $software) {
            $software = @()
        }
        
        $formatted = Format-SoftwareList -Software $software
        Write-Log $formatted
        $step = @{ Name='InstalledSoftware'; Status='Pass'; Output=$formatted; Detail = "$($software.Count) application(s)" }
        Add-HealthFindingsToStep -Step $step -Findings @(
            New-InventoryHealthFinding -CheckId 'audit_installed_software' -Finding ("Installed software inventory: {0} item(s)" -f $software.Count) `
                -Evidence @("$($software.Count) applications enumerated")
        ) -SummaryText $step.Detail
        $r.Steps.Add([PSCustomObject]$step)
    } catch {
        $r.Steps.Add([PSCustomObject]@{ Name='InstalledSoftware'; Status='Warn'; Output=$_.Exception.Message })
    }
}

function Invoke-DriversAudit {
    param($r)
    Write-Log "Enumerating drivers..."
    try {
        $drivers = @(Get-CimInstance Win32_SystemDriver | Select-Object Name, DisplayName, State, StartMode)
        $stopped = @($drivers | Where-Object { $_.State -ne 'Running' -and $_.StartMode -eq 'Auto' })

        $formatted = Format-DriversList -Drivers $drivers -Stopped $stopped
        Write-Log $formatted
        $status = if (@($stopped).Count -gt 5) { 'Warn' } else { 'Pass' }
        $findings = @()
        if (@($stopped).Count -gt 5) {
            foreach ($s in @($stopped | Select-Object -First 12)) {
                $findings += New-HealthFinding -FindingId 'driver.service.auto_stopped' -CheckId 'audit_drivers' `
                    -Subject ([string]$s.DisplayName) -Finding 'Automatic driver is stopped' `
                    -Impact 'Auto-start drivers that remain stopped can break devices or boot features.' `
                    -Severity 'Medium' -Confidence 75 -Status 'Warn' `
                    -Evidence @("Name=$($s.Name); State=$($s.State); StartMode=$($s.StartMode)") `
                    -Recommendations @('Review the driver in Device Manager / services and repair or reinstall if unexpected.') `
                    -Actions @(@{ type = 'shell'; target = 'devmgmt.msc'; label = 'Device Manager' })
            }
        }
        else {
            $findings += New-HealthFinding -FindingId 'driver.service.ok' -CheckId 'audit_drivers' `
                -Finding 'Driver service states look acceptable' -Impact 'No large set of stopped auto-start drivers.' `
                -Severity 'Info' -Confidence 80 -Status 'Pass' -Evidence @("Stopped auto drivers: $(@($stopped).Count)")
        }
        $step = @{ Name='Drivers'; Status=$status; Output=$formatted; Detail = "Stopped auto drivers: $(@($stopped).Count)" }
        Add-HealthFindingsToStep -Step $step -Findings $findings -SummaryText $step.Detail
        $r.Steps.Add([PSCustomObject]$step)
    } catch {
        $r.Steps.Add([PSCustomObject]@{ Name='Drivers'; Status='Skip'; Output=$_.Exception.Message })
    }
}

function Test-PnPAuditExcludedDevice {
    param($Device)

    $class = [string]$Device.Class
    if ($class -in @('VolumeSnapshot', 'Firmware')) {
        return $true
    }

    $name = [string]$Device.FriendlyName
    $instanceId = [string]$Device.InstanceId

    if ($name -match '(?i)^(Microsoft Virtual (Disk|DVD-ROM|HDC)|Microsoft VHD Loopback)') {
        return $true
    }
    if ($name -match '(?i)(Hyper-V|VMware|VirtualBox|VBox|QEMU|Virtual Machine|Xen)') {
        return $true
    }
    if ($instanceId -match '(?i)(\\VBox\\|VMWARE|qemu|virtio|vmbus\\|hyper-v)') {
        return $true
    }

    return $false
}

function Test-PnPAuditProblemDevice {
    param($Device)

    $status = [string]$Device.Status
    if ($status -eq 'Error' -or $status -eq 'Degraded') {
        return $true
    }

    if ($Device.PSObject.Properties['Problem']) {
        $problem = $Device.Problem
        if ($null -eq $problem) {
            return $false
        }

        $problemText = [string]$problem
        if ($problemText -match '^(CM_PROB_NONE|NoProblem)$') {
            return $false
        }
        if ($problemText -match '^\d+$') {
            return [int]$problemText -ne 0
        }

        return $true
    }

    return $false
}

function Invoke-PnPDevicesAudit {
    param($r)
    if ((Get-EnvironmentMode) -eq 'WinPE') {
        $step = @{
            Name = 'PnPDevices'; Status = 'N/A'; CheckId = 'audit_pnp_devices'
            Output = 'Not applicable in WinPE. Plug-and-Play cmdlet is not available against offline Windows.'
        }
        Add-HealthFindingsToStep -Step $step -Findings @(
            New-HealthFinding -FindingId 'device.pnp.na_winpe' -CheckId 'audit_pnp_devices' `
                -Finding 'PnP device audit unavailable in WinPE' -Impact 'Live Plug-and-Play status cannot be queried offline.' `
                -Severity 'Info' -Confidence 95 -Status 'N/A' -Evidence @('Environment=WinPE')
        ) -SummaryText $step.Output
        $r.Steps.Add([PSCustomObject]$step)
        return
    }

    Write-Log "Checking PnP device health..."
    try {
        $pnpPresent = @(Get-PnpDevice -PresentOnly -ErrorAction Stop)
        $inScope = @(
            $pnpPresent | Where-Object { -not (Test-PnPAuditExcludedDevice $_) }
        )
        $problems = @(
            $inScope | Where-Object { Test-PnPAuditProblemDevice $_ }
        )
        $excludedCount = $pnpPresent.Count - $inScope.Count

        $formatted = Format-PnPDeviceList -Devices $inScope -Problems $problems -ExcludedCount $excludedCount
        Write-Log $formatted
        $findings = @()
        if ($problems.Count -gt 0) {
            foreach ($dev in @($problems | Select-Object -First 15)) {
                $name = [string]$dev.FriendlyName
                if ([string]::IsNullOrWhiteSpace($name)) { $name = [string]$dev.InstanceId }
                $statusText = [string]$dev.Status
                $problemText = if ($dev.PSObject.Properties['Problem']) { [string]$dev.Problem } else { '' }
                $findings += New-HealthFinding -FindingId 'device.pnp.problem' -CheckId 'audit_pnp_devices' `
                    -Subject $name -Finding 'PnP device reports a problem state' `
                    -Impact 'Problem devices can cause missing hardware, yellow bangs, or intermittent failures.' `
                    -Severity 'Medium' -Confidence 85 -Status 'Warn' `
                    -Evidence @("Status=$statusText", "Problem=$problemText", "InstanceId=$($dev.InstanceId)") `
                    -Recommendations @('Open Device Manager, update/reinstall the driver, or replace the device if hardware-faulted.') `
                    -Actions @(@{ type = 'shell'; target = 'devmgmt.msc'; label = 'Device Manager' })
            }
        }
        else {
            $findings += New-HealthFinding -FindingId 'device.pnp.ok' -CheckId 'audit_pnp_devices' `
                -Finding 'No problem PnP devices detected' `
                -Impact 'Present devices are reporting healthy status.' `
                -Severity 'Info' -Confidence 80 -Status 'Pass' `
                -Evidence @("In-scope devices: $($inScope.Count)", "Excluded: $excludedCount")
        }
        $step = @{
            Name = 'PnPDevices'; Status = 'Pass'; Output = $formatted; CheckId = 'audit_pnp_devices'
            Detail = "Problems: $($problems.Count) / in-scope $($inScope.Count)"
        }
        Add-HealthFindingsToStep -Step $step -Findings $findings -SummaryText $step.Detail
        $r.Steps.Add([PSCustomObject]$step)
    } catch {
        $r.Steps.Add([PSCustomObject]@{ Name='PnPDevices'; Status='N/A'; Output='PnP cmdlet unavailable'; CheckId='audit_pnp_devices' })
    }
}

function Invoke-ServicesAudit {
    param($r)
    Write-Log "Auditing auto-start services..."
    try {
        $isWinPe = ((Get-EnvironmentMode) -eq 'WinPE')
        $offlineLoaded = ($env:OFFLINE_REGISTRY_LOADED -eq '1')

        if ($isWinPe -and $offlineLoaded) {
            $controlSet = Get-OfflineControlSet
            $servicesKey = "HKLM:\Offline_SYSTEM\$controlSet\Services"

            if (-not (Test-Path $servicesKey)) {
                $r.Steps.Add([PSCustomObject]@{ Name='Services'; Status='N/A'; Output='Offline SYSTEM hive is loaded, but services key was not found.'; CheckId='audit_services' })
                return
            }

            $serviceItems = Get-ChildItem -Path $servicesKey -ErrorAction SilentlyContinue | ForEach-Object {
                $svc = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
                if ($null -eq $svc) { return }

                $startValue = if ($null -eq $svc.Start) { -1 } else { [int]$svc.Start }
                if ($startValue -ne 2) { return }

                [PSCustomObject]@{
                    Name = $_.PSChildName
                    DisplayName = if ([string]::IsNullOrWhiteSpace($svc.DisplayName)) { $_.PSChildName } else { [string]$svc.DisplayName }
                    Start = $startValue
                    ImagePath = [string]$svc.ImagePath
                }
            }

            if ($null -eq $serviceItems) {
                $serviceItems = @()
            }

            $output = "OFFLINE WINDOWS SERVICES (Auto-Start from Registry)`n"
            $output += "==============================================`n`n"
            $output += "Control Set: $controlSet`n"
            $output += "Total Auto-Start Services: $($serviceItems.Count)`n`n"
            $output += "{0,-52} {1}`n" -f 'Service Name', 'Image Path'
            $output += "{0,-52} {1}`n" -f ('-' * 48), ('-' * 80)

            foreach ($svc in ($serviceItems | Sort-Object DisplayName | Select-Object -First 200)) {
                $display = [string]$svc.DisplayName
                if ($display.Length -gt 50) { $display = $display.Substring(0, 50) + '..' }
                $image = if ([string]::IsNullOrWhiteSpace($svc.ImagePath)) { 'Unknown' } else { $svc.ImagePath }
                $output += "{0,-52} {1}`n" -f $display, $image
            }

            Write-Log $output
            $step = @{ Name='Services'; Status='Pass'; Output=$output; CheckId='audit_services'; Detail="Offline auto-start services: $($serviceItems.Count)" }
            Add-HealthFindingsToStep -Step $step -Findings @(
                New-InventoryHealthFinding -CheckId 'audit_services' -Finding ("Offline auto-start service inventory: {0}" -f @($serviceItems).Count) `
                    -Evidence @("ControlSet=$controlSet", "Count=$(@($serviceItems).Count)")
            ) -SummaryText $step.Detail
            $r.Steps.Add([PSCustomObject]$step)
            return
        }

        $services = @(Get-Service | Where-Object { $_.StartType -eq 'Automatic' })
        $stopped  = @($services | Where-Object { $_.Status -ne 'Running' })

        $formatted = Format-ServicesList -Services $services -Stopped $stopped
        Write-Log $formatted
        $findings = @()
        if ($stopped.Count -gt 10) {
            foreach ($svc in @($stopped | Select-Object -First 12)) {
                $findings += New-HealthFinding -FindingId 'service.auto_stopped' -CheckId 'audit_services' `
                    -Subject ([string]$svc.DisplayName) -Finding 'Automatic service is not running' `
                    -Impact 'Stopped auto-start services can break updates, networking, security, or hardware features.' `
                    -Severity 'Medium' -Confidence 75 -Status 'Warn' `
                    -Evidence @("Name=$($svc.Name); Status=$($svc.Status); StartType=$($svc.StartType)") `
                    -Recommendations @('Start the service if required, or change StartType if it is intentionally disabled.') `
                    -Actions @(@{ type = 'shell'; target = 'services.msc'; label = 'Services' })
            }
        }
        else {
            $findings += New-HealthFinding -FindingId 'service.auto_ok' -CheckId 'audit_services' `
                -Finding 'Automatic service states look acceptable' `
                -Impact 'Stopped auto-start count is within a normal range.' `
                -Severity 'Info' -Confidence 80 -Status 'Pass' `
                -Evidence @("Automatic: $($services.Count)", "Stopped: $($stopped.Count)")
        }
        $step = @{ Name='Services'; Status='Pass'; Output=$formatted; CheckId='audit_services'; Detail="Stopped auto services: $($stopped.Count)" }
        Add-HealthFindingsToStep -Step $step -Findings $findings -SummaryText $step.Detail
        $r.Steps.Add([PSCustomObject]$step)
    } catch {
        $r.Steps.Add([PSCustomObject]@{ Name='Services'; Status='Warn'; Output=$_.Exception.Message; CheckId='audit_services' })
    }
}

function Invoke-NetworkConfigAudit {
    param($r)
    Write-Log "Capturing network configuration..."
    try {
        $ipConfig = Get-NetIPConfiguration -ErrorAction Stop
        
        $formatted = Format-NetworkConfig -IpConfig $ipConfig
        Write-Log $formatted
        $count = @($ipConfig).Count
        $step = @{ Name='NetworkConfig'; Status='Pass'; Output=$formatted; CheckId='audit_network_config'; Detail="$count interface configuration(s)" }
        Add-HealthFindingsToStep -Step $step -Findings @(
            New-InventoryHealthFinding -CheckId 'audit_network_config' -Finding ("Network configuration inventory: {0} interface(s)" -f $count) `
                -Evidence @("$count interface configuration(s)")
        ) -SummaryText $step.Detail
        $r.Steps.Add([PSCustomObject]$step)
    } catch {
        try {
            $adapters = @(Get-CimInstance Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled })
            Write-Log "  Active adapters (WMI): $($adapters.Count)"
            $output = "$($adapters.Count) active adapter(s):`n$(($adapters | ForEach-Object { "  $($_.Description): $($_.IPAddress -join ', ')" }) -join "`n")"
            $step = @{ Name='NetworkConfig'; Status='Pass'; Output=$output; CheckId='audit_network_config'; Detail="$($adapters.Count) active adapter(s) (WMI)" }
            Add-HealthFindingsToStep -Step $step -Findings @(
                New-InventoryHealthFinding -CheckId 'audit_network_config' -Finding $step.Detail -Evidence @($step.Detail)
            ) -SummaryText $step.Detail
            $r.Steps.Add([PSCustomObject]$step)
        } catch {
            $r.Steps.Add([PSCustomObject]@{ Name='NetworkConfig'; Status='Skip'; Output=$_.Exception.Message; CheckId='audit_network_config' })
        }
    }
}

function Get-NormalizedEventMessage {
    param([string]$Message)
    $text = ($Message -replace '\s+', ' ').Trim()
    if ($text.Length -gt 200) {
        $text = $text.Substring(0, 200) + '...'
    }
    return $text
}

function Get-EventLogRecordFields {
    param($Event, [string]$LogName)

    $source = ''
    if ($Event.PSObject.Properties.Name -contains 'Source' -and -not [string]::IsNullOrWhiteSpace([string]$Event.Source)) {
        $source = [string]$Event.Source
    }
    elseif ($Event.PSObject.Properties.Name -contains 'ProviderName' -and -not [string]::IsNullOrWhiteSpace([string]$Event.ProviderName)) {
        $source = [string]$Event.ProviderName
    }
    else {
        $source = 'Unknown'
    }

    $eventId = 0
    if ($Event.PSObject.Properties.Name -contains 'EventID' -and $null -ne $Event.EventID) {
        $eventId = [int]$Event.EventID
    }
    elseif ($Event.PSObject.Properties.Name -contains 'Id' -and $null -ne $Event.Id) {
        $eventId = [int]$Event.Id
    }

    $time = $null
    if ($Event.PSObject.Properties.Name -contains 'TimeGenerated') { $time = $Event.TimeGenerated }
    elseif ($Event.PSObject.Properties.Name -contains 'TimeCreated') { $time = $Event.TimeCreated }

    $message = Get-NormalizedEventMessage -Message ([string]$Event.Message)
    $dedupKey = "$LogName|$source|$eventId|$message"

    [PSCustomObject]@{
        LogName         = $LogName
        Source          = $source
        EventId         = $eventId
        Message         = $message
        TimeGenerated   = $time
        DedupKey        = $dedupKey
    }
}

function Get-DedupedEventLogErrors {
    param(
        [array]$SystemEvents,
        [array]$ApplicationEvents
    )

    $tagged = @()
    foreach ($evt in ($SystemEvents | Where-Object { $_ })) {
        $tagged += Get-EventLogRecordFields -Event $evt -LogName 'System'
    }
    foreach ($evt in ($ApplicationEvents | Where-Object { $_ })) {
        $tagged += Get-EventLogRecordFields -Event $evt -LogName 'Application'
    }

    $deduped = foreach ($group in ($tagged | Group-Object -Property DedupKey)) {
        $sample = $group.Group | Sort-Object { $_.TimeGenerated } -Descending | Select-Object -First 1
        [PSCustomObject]@{
            LogName       = $sample.LogName
            Source        = $sample.Source
            EventId       = $sample.EventId
            Message       = $sample.Message
            Count         = $group.Count
            LastTime      = $sample.TimeGenerated
        }
    }

    return @($deduped | Sort-Object { $_.LastTime } -Descending)
}

function Get-SafeEventLogErrors {
    param(
        [Parameter(Mandatory)][string]$LogName,
        [Parameter(Mandatory)][datetime]$Since
    )

    try {
        return @(Get-EventLog -LogName $LogName -EntryType Error -After $Since -Newest 1000 -ErrorAction Stop)
    }
    catch {
        if ($_.Exception.Message -match 'No matches|cannot find|not find') {
            return @()
        }
        throw
    }
}

function Add-EventLogStructuredOutput {
    param(
        [string]$FormattedText,
        [array]$DedupedEntries
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add($FormattedText)
    $lines.Add('')

    foreach ($entry in $DedupedEntries) {
        $payload = @{
            log     = [string]$entry.LogName
            source  = [string]$entry.Source
            eventId = [int]$entry.EventId
            message = [string]$entry.Message
            count   = [int]$entry.Count
        } | ConvertTo-Json -Compress
        $lines.Add("[AUDIT:EVENT] $payload")
    }

    return ($lines -join "`n")
}

function Invoke-EventLogsAudit {
    param($r)
    Write-Log "Harvesting event logs (last 24h errors, deduplicated)..."

    try {
        $since  = (Get-Date).AddHours(-24)

        if ((Get-EnvironmentMode) -eq 'WinPE') {
            $offlineRoot = Get-OfflineWindowsRoot
            if ([string]::IsNullOrWhiteSpace($offlineRoot)) {
                $r.Steps.Add([PSCustomObject]@{ Name='EventLogs'; Status='N/A'; Output='Not applicable in WinPE without an offline Windows root. Use boot option 2 to load offline OS first.' })
                return
            }

            $systemLogPath = Join-Path $offlineRoot 'Windows\System32\winevt\Logs\System.evtx'
            $appLogPath = Join-Path $offlineRoot 'Windows\System32\winevt\Logs\Application.evtx'

            if (-not (Test-Path $systemLogPath) -and -not (Test-Path $appLogPath)) {
                $r.Steps.Add([PSCustomObject]@{ Name='EventLogs'; Status='N/A'; Output='Offline EVTX logs were not found for the selected offline Windows root.' })
                return
            }

            $sysErr = @()
            $appErr = @()

            if (Test-Path $systemLogPath) {
                $sysErr = Get-WinEvent -Path $systemLogPath -ErrorAction Stop |
                    Where-Object { $_.LevelDisplayName -eq 'Error' -and $_.TimeCreated -ge $since } |
                    Select-Object -First 1000 |
                    ForEach-Object {
                        [PSCustomObject]@{
                            EntryType       = $_.LevelDisplayName
                            TimeGenerated   = $_.TimeCreated
                            Source          = $_.ProviderName
                            Message         = $_.Message
                            EventID         = $_.Id
                        }
                    }
            }

            if (Test-Path $appLogPath) {
                $appErr = Get-WinEvent -Path $appLogPath -ErrorAction Stop |
                    Where-Object { $_.LevelDisplayName -eq 'Error' -and $_.TimeCreated -ge $since } |
                    Select-Object -First 1000 |
                    ForEach-Object {
                        [PSCustomObject]@{
                            EntryType       = $_.LevelDisplayName
                            TimeGenerated   = $_.TimeCreated
                            Source          = $_.ProviderName
                            Message         = $_.Message
                            EventID         = $_.Id
                        }
                    }
            }
        } else {
            $sysErr = Get-SafeEventLogErrors -LogName 'System' -Since $since
            $appErr = Get-SafeEventLogErrors -LogName 'Application' -Since $since
        }

        if ($null -eq $sysErr) { $sysErr = @() }
        if ($null -eq $appErr) { $appErr = @() }

        $deduped = @(Get-DedupedEventLogErrors -SystemEvents $sysErr -ApplicationEvents $appErr)
        $formatted = Format-EventLogDetail -SystemEvents @($sysErr) -AppEvents @($appErr)
        if ((Get-EnvironmentMode) -eq 'WinPE') {
            $formatted = "SOURCE: Offline Windows EVTX`n`n" + $formatted
        }

        $clusterInputs = @()
        foreach ($e in @($sysErr)) { if ($e) { $clusterInputs += $e } }
        foreach ($e in @($appErr)) { if ($e) { $clusterInputs += $e } }
        if ($clusterInputs.Count -eq 0 -and $deduped.Count -gt 0) {
            $clusterInputs = $deduped
        }

        $findings = @(Invoke-EventFindingClustering -CheckId 'audit_event_logs' -Events $clusterInputs)
        $output = Add-EventLogStructuredOutput -FormattedText $formatted -DedupedEntries $deduped
        $step = @{
            Name    = 'EventLogs'
            Status  = if (@($deduped).Count -gt 0) { 'Warn' } else { 'Pass' }
            Detail  = "Unique errors (last 24h): $(@($deduped).Count)"
            Output  = $output
        }
        if ($findings.Count -gt 0) {
            Add-HealthFindingsToStep -Step $step -Findings $findings -SummaryText ("Correlated {0} finding cluster(s) from {1} unique error group(s)." -f @(
                @($findings | Where-Object { $_.findingId -notlike 'event.unclassified.*' }).Count
                @($deduped).Count
            ))
        }
        $r.Steps.Add([PSCustomObject]$step)
        Write-Log $formatted
        Write-Log "Unique errors (last 24h): $(@($deduped).Count)"
    } catch {
        $r.Steps.Add([PSCustomObject]@{ Name='EventLogs'; Status='Warn'; Output=$_.Exception.Message })
    }
}

function Invoke-PartitionTableAudit {
    param($r)
    Write-Log "Reading partition table..."
    try {
        $parts = @(Get-Partition -ErrorAction Stop)
        
        $formatted = Format-PartitionInfo -Partitions $parts
        Write-Log $formatted
        $step = @{ Name='PartitionTable'; Status='Pass'; Output=$formatted; CheckId='audit_partition_table'; Detail="$($parts.Count) partition(s)" }
        Add-HealthFindingsToStep -Step $step -Findings @(
            New-InventoryHealthFinding -CheckId 'audit_partition_table' -Finding ("Partition table inventory: {0} partition(s)" -f $parts.Count) `
                -Evidence @("$($parts.Count) partition(s)")
        ) -SummaryText $step.Detail
        $r.Steps.Add([PSCustomObject]$step)
    } catch {
        $r.Steps.Add([PSCustomObject]@{ Name='PartitionTable'; Status='Skip'; Output='Get-Partition unavailable'; CheckId='audit_partition_table' })
    }
}

function Invoke-StartupAudit {
    param($r)

    $envMode = Get-EnvironmentMode
    if ($envMode -eq 'WinPE' -and $env:OFFLINE_REGISTRY_LOADED -ne '1') {
        $step = @{
            Name = 'StartupAudit'; Status = 'N/A'; CheckId = 'audit_startup'
            Output = 'WinPE: load an offline Windows installation to audit startup registry hives.'
        }
        Add-HealthFindingsToStep -Step $step -Findings @(
            New-HealthFinding -FindingId 'startup.na_winpe' -CheckId 'audit_startup' `
                -Finding 'Startup audit unavailable without offline hives' -Impact 'Cannot review Run keys offline until a Windows hive is loaded.' `
                -Severity 'Info' -Confidence 95 -Status 'N/A' -Evidence @('Environment=WinPE', 'OFFLINE_REGISTRY_LOADED!=1')
        ) -SummaryText $step.Output
        $r.Steps.Add([PSCustomObject]$step)
        return
    }

    Write-Log "Auditing startup entries..."
    $entries = @(Get-PostOpStartupEntries)
    if ($entries.Count -eq 0) {
        $step = @{ Name='StartupAudit'; Status='Pass'; Output='No startup entries found.'; CheckId='audit_startup'; Detail='No startup entries found.' }
        Add-HealthFindingsToStep -Step $step -Findings @(
            New-HealthFinding -FindingId 'startup.none' -CheckId 'audit_startup' `
                -Finding 'No startup entries found' -Impact 'Nothing to review in Run/Startup locations.' `
                -Severity 'Info' -Confidence 85 -Status 'Pass' -Evidence @('Entry count: 0')
        ) -SummaryText $step.Detail
        $r.Steps.Add([PSCustomObject]$step)
        return
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $findings = [System.Collections.Generic.List[object]]::new()
    $reviewCount = 0
    $safe = 0

    foreach ($entry in $entries) {
        $entryType = if ($entry.PSObject.Properties['EntryType']) { [string]$entry.EntryType } else { '' }
        $isWinlogonDeviated = $false
        $winlogonDeviationReason = ''
        if ($entry.PSObject.Properties['IsDeviated']) {
            $isWinlogonDeviated = [bool]$entry.IsDeviated
        }
        if ($entry.PSObject.Properties['DeviationReason']) {
            $winlogonDeviationReason = [string]$entry.DeviationReason
        }

        $assessment = Test-PostOpStartupSuspicious `
            -Name $entry.Name `
            -SourceGroup $entry.SourceGroup `
            -ResolvedPath $entry.ResolvedPath `
            -Publisher $entry.Publisher `
            -IsSigned:$entry.IsSigned `
            -RiskBand $entry.RiskBand `
            -IsRunOnce:$entry.IsRunOnce `
            -TargetExists:$entry.TargetExists `
            -EntryType $entryType `
            -IsWinlogonDeviated:$isWinlogonDeviated `
            -WinlogonDeviationReason $winlogonDeviationReason

        $tag = if ($assessment.IsSuspicious) { '[REVIEW]' } else { '[OK]' }
        if ($assessment.IsSuspicious) { $reviewCount++ } else { $safe++ }

        $reasonText = if ($assessment.Reasons.Count -gt 0) { " ($($assessment.Reasons -join ', '))" } else { '' }
        $pathText = if ($entry.ResolvedPath) { $entry.ResolvedPath } else { $entry.Command }
        $line = "$tag [$($entry.SourceGroup)] $($entry.Name) - $($entry.RiskBand)$reasonText - $pathText"
        Write-Log "  $line"
        $lines.Add($line) | Out-Null

        if ($assessment.IsSuspicious) {
            $payload = @{
                name     = $entry.Name
                location = $entry.SourceGroup
                risk     = $entry.RiskBand
                reasons  = ($assessment.Reasons -join ', ')
                path     = $pathText
            }
            $startupJson = ($payload | ConvertTo-Json -Compress)
            Write-Host "[POSTOP:STARTUP] $startupJson"
            $lines.Add("[POSTOP:STARTUP] $startupJson") | Out-Null

            $sev = switch -Regex ([string]$entry.RiskBand) {
                '(?i)high|critical' { 'High' }
                '(?i)medium' { 'Medium' }
                default { 'Medium' }
            }
            $findings.Add((New-HealthFinding `
                -FindingId 'startup.review' `
                -CheckId 'audit_startup' `
                -Subject ([string]$entry.Name) `
                -Finding 'Startup entry needs review' `
                -Impact 'Suspicious or high-risk startup items can persist malware or unwanted software.' `
                -Severity $sev `
                -Confidence 80 `
                -Status 'Warn' `
                -Evidence @(
                    "Location=$($entry.SourceGroup)",
                    "Risk=$($entry.RiskBand)",
                    "Reasons=$($assessment.Reasons -join ', ')",
                    "Path=$pathText"
                ) `
                -Recommendations @('Disable or remove the entry in Startup Manager if unexpected.', 'Run Hijack and Scam Repair if browser/search hijack is also present.') `
                -Actions @(@{ type = 'cde'; target = 'StartupManager'; label = 'Startup Manager' })
            )) | Out-Null
        }
    }

    if ($reviewCount -eq 0) {
        $findings.Add((New-HealthFinding -FindingId 'startup.ok' -CheckId 'audit_startup' `
            -Finding 'Startup entries look acceptable' `
            -Impact 'No suspicious startup persistence was flagged.' `
            -Severity 'Info' -Confidence 80 -Status 'Pass' `
            -Evidence @("Total: $($entries.Count)", "OK: $safe"))) | Out-Null
    }

    Write-Log "Total: $($entries.Count) | Review: $reviewCount | OK: $safe"
    $summary = "Total: $($entries.Count) | Review: $reviewCount | OK: $safe`n$($lines -join "`n")"
    $step = @{
        Name = 'StartupAudit'; Status = 'Pass'; Output = $summary; CheckId = 'audit_startup'
        Detail = "Total: $($entries.Count) | Review: $reviewCount | OK: $safe"
    }
    Add-HealthFindingsToStep -Step $step -Findings @($findings.ToArray()) -SummaryText $summary
    $r.Steps.Add([PSCustomObject]$step)
}
function Get-SystemAuditCheckDispatchMap {
    return @{
        audit_installed_software = { param($r) Invoke-InstalledSoftwareAudit $r }
        audit_drivers          = { param($r) Invoke-DriversAudit $r }
        audit_pnp_devices      = { param($r) Invoke-PnPDevicesAudit $r }
        audit_services         = { param($r) Invoke-ServicesAudit $r }
        audit_startup          = { param($r) Invoke-StartupAudit $r }
        audit_network_config   = { param($r) Invoke-NetworkConfigAudit $r }
        audit_event_logs       = { param($r) Invoke-EventLogsAudit $r }
        audit_partition_table  = { param($r) Invoke-PartitionTableAudit $r }
    }
}
