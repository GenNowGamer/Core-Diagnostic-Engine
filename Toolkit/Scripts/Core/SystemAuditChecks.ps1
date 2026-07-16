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
        $r.Steps.Add([PSCustomObject]@{ Name='InstalledSoftware'; Status='Pass'; Output=$formatted })
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
        $r.Steps.Add([PSCustomObject]@{ Name='Drivers'; Status=$status; Output=$formatted })
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
        $r.Steps.Add([PSCustomObject]@{ Name='PnPDevices'; Status='N/A'; Output='Not applicable in WinPE. Plug-and-Play cmdlet is not available against offline Windows.' })
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
        $status = if ($problems.Count -gt 0) { 'Warn' } else { 'Pass' }
        $r.Steps.Add([PSCustomObject]@{ Name='PnPDevices'; Status=$status; Output=$formatted })
    } catch {
        $r.Steps.Add([PSCustomObject]@{ Name='PnPDevices'; Status='N/A'; Output='PnP cmdlet unavailable' })
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
                $r.Steps.Add([PSCustomObject]@{ Name='Services'; Status='N/A'; Output='Offline SYSTEM hive is loaded, but services key was not found.' })
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
            $r.Steps.Add([PSCustomObject]@{ Name='Services'; Status='Pass'; Output=$output })
            return
        }

        $services = Get-Service | Where-Object { $_.StartType -eq 'Automatic' }
        $stopped  = $services | Where-Object { $_.Status -ne 'Running' }

        $formatted = Format-ServicesList -Services $services -Stopped $stopped
        Write-Log $formatted
        $status = if ($stopped.Count -gt 10) { 'Warn' } else { 'Pass' }
        $r.Steps.Add([PSCustomObject]@{ Name='Services'; Status=$status; Output=$formatted })
    } catch {
        $r.Steps.Add([PSCustomObject]@{ Name='Services'; Status='Warn'; Output=$_.Exception.Message })
    }
}

function Invoke-NetworkConfigAudit {
    param($r)
    Write-Log "Capturing network configuration..."
    try {
        $ipConfig = Get-NetIPConfiguration -ErrorAction Stop
        
        $formatted = Format-NetworkConfig -IpConfig $ipConfig
        Write-Log $formatted
        $r.Steps.Add([PSCustomObject]@{ Name='NetworkConfig'; Status='Pass'; Output=$formatted })
    } catch {
        try {
            $adapters = Get-CimInstance Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled }
            Write-Log "  Active adapters (WMI): $($adapters.Count)"
            $r.Steps.Add([PSCustomObject]@{ Name='NetworkConfig'; Status='Pass'; Output="$($adapters.Count) active adapter(s):`n$(($adapters | ForEach-Object { "  $($_.Description): $($_.IPAddress -join ', ')" }) -join "`n")" })
        } catch {
            $r.Steps.Add([PSCustomObject]@{ Name='NetworkConfig'; Status='Skip'; Output=$_.Exception.Message })
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

        $output = Add-EventLogStructuredOutput -FormattedText $formatted -DedupedEntries $deduped
        $status = if (@($deduped).Count -gt 0) { 'Warn' } else { 'Pass' }

        Write-Log $formatted
        Write-Log "Unique errors (last 24h): $(@($deduped).Count)"
        $r.Steps.Add([PSCustomObject]@{ Name='EventLogs'; Status=$status; Output=$output })
    } catch {
        $r.Steps.Add([PSCustomObject]@{ Name='EventLogs'; Status='Warn'; Output=$_.Exception.Message })
    }
}

function Invoke-PartitionTableAudit {
    param($r)
    Write-Log "Reading partition table..."
    try {
        $parts = Get-Partition -ErrorAction Stop
        
        $formatted = Format-PartitionInfo -Partitions $parts
        Write-Log $formatted
        $r.Steps.Add([PSCustomObject]@{ Name='PartitionTable'; Status='Pass'; Output=$formatted })
    } catch {
        $r.Steps.Add([PSCustomObject]@{ Name='PartitionTable'; Status='Skip'; Output='Get-Partition unavailable' })
    }
}

function Invoke-StartupAudit {
    param($r)

    $envMode = Get-EnvironmentMode
    if ($envMode -eq 'WinPE' -and $env:OFFLINE_REGISTRY_LOADED -ne '1') {
        $r.Steps.Add([PSCustomObject]@{
            Name   = 'StartupAudit'
            Status = 'N/A'
            Output = 'WinPE: load an offline Windows installation to audit startup registry hives.'
        })
        return
    }

    Write-Log "Auditing startup entries..."
    $entries = Get-PostOpStartupEntries
    if ($entries.Count -eq 0) {
        $r.Steps.Add([PSCustomObject]@{
            Name   = 'StartupAudit'
            Status = 'Pass'
            Output = 'No startup entries found.'
        })
        return
    }

    $lines = [System.Collections.Generic.List[string]]::new()
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
        $line = "$tag [$($entry.SourceGroup)] $($entry.Name) — $($entry.RiskBand)$reasonText — $pathText"
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
        }
    }

    Write-Log "Total: $($entries.Count) | Review: $reviewCount | OK: $safe"
    $status = if ($reviewCount -gt 0) { 'Warn' } else { 'Pass' }
    $summary = "Total: $($entries.Count) | Review: $reviewCount | OK: $safe`n$($lines -join "`n")"
    $r.Steps.Add([PSCustomObject]@{
        Name   = 'StartupAudit'
        Status = $status
        Output = $summary
    })
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
