#Requires -Version 5.1
param(
    [string]$Action = 'List',
    [string]$FixKey = '',
    [switch]$ElevatedRelay
)
$ErrorActionPreference = 'Stop'

$Script:FastFixesScriptPath = $MyInvocation.MyCommand.Path
$ScriptDir  = Split-Path $Script:FastFixesScriptPath
$CoreModule = Join-Path $ScriptDir '..\Core\Toolkit.Core.psm1'
$ElevationModule = Join-Path $ScriptDir '..\Core\Toolkit.Elevation.psm1'
Import-Module $CoreModule -Force -DisableNameChecking
Import-Module $ElevationModule -Force -DisableNameChecking

$Script:FastFixesRequiringElevation = @(
    'ResetWinsock',
    'DisableIPv6',
    'ClearEventLogs',
    'EnableWuauserv',
    'EnableBits',
    'EnableDefender',
    'SetHighPerf'
)

function Get-FastFixesRelayArgumentString {
    param([Parameter(Mandatory)][string]$Key)

    $parts = [System.Collections.Generic.List[string]]::new()
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'Action' -Value 'Apply'
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'FixKey' -Value $Key
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'ElevatedRelay' -IsSwitch
    return Join-ToolkitRelayArgumentString -Parts $parts
}

function Invoke-FastFixElevationRelay {
    param([Parameter(Mandatory)][string]$Key)

    if ($ElevatedRelay) { return $false }
    if (Test-ToolkitIsElevated) { return $false }
    if ($Script:FastFixesRequiringElevation -notcontains $Key) { return $false }

    $relay = Invoke-ToolkitElevatedRelay -ScriptPath $Script:FastFixesScriptPath `
        -ArgumentString (Get-FastFixesRelayArgumentString -Key $Key)
    if ($null -eq $relay) { return $false }
    if ($relay.ExitCode -ne 0) {
        throw "Elevated fast fix failed (exit code $($relay.ExitCode))."
    }
    return $true
}

$FixDefinitions = @(
    # Networking
    @{ Key='ResetWinsock';    Category='Networking'; Name='Reset Winsock';              Risk='Caution'; Desc='Resets Winsock catalog — may require reboot' },
    @{ Key='RenewIp';         Category='Networking'; Name='Release & Renew IP';         Risk='Safe';    Desc='ipconfig /release then /renew' },
    @{ Key='DisableIPv6';     Category='Networking'; Name='Disable IPv6';               Risk='Caution'; Desc='Disables IPv6 on all adapters' },
    # OS
    @{ Key='ClearEventLogs';  Category='OS';         Name='Clear All Event Logs';       Risk='Caution'; Desc='Wipes Application, System, Security logs' },
    # Services
    @{ Key='EnableWuauserv';  Category='Services';   Name='Enable Windows Update Svc';  Risk='Safe';    Desc='Sets wuauserv to Automatic and starts it' },
    @{ Key='EnableBits';      Category='Services';   Name='Enable BITS';                Risk='Safe';    Desc='Sets BITS to Automatic and starts it' },
    @{ Key='EnableDefender';  Category='Services';   Name='Enable Windows Defender';    Risk='Safe';    Desc='Restores WinDefend service, real-time protection, and tamper protection (UAC/admin required)' },
    # Browsers
    @{ Key='ResetEdge';       Category='Browsers';   Name='Reset Microsoft Edge';       Risk='Caution'; Desc='Clears Edge cache, cookies, and local state' },
    @{ Key='ResetChrome';     Category='Browsers';   Name='Reset Google Chrome';        Risk='Caution'; Desc='Clears Chrome cache and local state' },
    @{ Key='FixBrowserAssoc'; Category='Browsers';   Name='Fix Browser File Associations'; Risk='Caution'; Desc='Resets .htm/.html/.url file associations' },
    # Performance
    @{ Key='DisableAnimations'; Category='Performance'; Name='Disable UI Animations';  Risk='Safe';    Desc='Turns off window/menu animations for speed' },
    @{ Key='CleanStartMenu';  Category='Performance'; Name='Clean Start Menu Cache';    Risk='Safe';    Desc='Removes broken start menu entries' },
    @{ Key='SetHighPerf';     Category='Performance'; Name='Set High Performance Plan'; Risk='Safe';    Desc='Switches power plan to High Performance' }
)

function New-FixResult {
    param(
        [ValidateSet('Pass', 'Fail')]
        [string]$Status,
        [string]$Summary,
        [string[]]$Details = @()
    )
    [PSCustomObject]@{
        Status  = $Status
        Summary = $Summary
        Details = $Details
    }
}

function Write-FixLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success', 'Verbose')]
        [string]$Level = 'Info'
    )
    Write-Log -Message $Message -Level $Level
}

function Invoke-FixCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [switch]$Quiet
    )
    # Start-Process -RedirectStandard* expects file paths in Windows PowerShell 5.1,
    # not $true — boolean splats coerce to "True" and collide for stdout/stderr.
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    if ($ArgumentList -and $ArgumentList.Count -gt 0) {
        $startInfo.Arguments = (
            $ArgumentList | ForEach-Object {
                $arg = [string]$_
                if ($arg -match '[\s"]') {
                    '"' + ($arg -replace '"', '\"') + '"'
                } else {
                    $arg
                }
            }
        ) -join ' '
    }
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $startInfo
    $null = $proc.Start()
    $stdoutText = $proc.StandardOutput.ReadToEnd()
    $stderrText = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    $stdout = @(($stdoutText -split "`r?`n") | Where-Object { $_ -ne '' })
    $stderr = @(($stderrText -split "`r?`n") | Where-Object { $_ -ne '' })
    if (-not $Quiet) {
        foreach ($line in $stdout) { Write-FixLog $line }
        foreach ($line in $stderr) { Write-FixLog $line -Level Warning }
    }
    return [PSCustomObject]@{
        ExitCode = $proc.ExitCode
        Output   = @($stdout + $stderr)
        Text     = (($stdout + $stderr) -join [Environment]::NewLine)
    }
}

function Get-EventLogRecordCount {
    param([Parameter(Mandatory)][string]$LogName)
    $gli = Invoke-FixCommand -FilePath 'wevtutil.exe' -ArgumentList @('gli', $LogName) -Quiet
    if ($gli.Text -match 'numberOfLogRecords:\s*(\d+)') {
        return [int]$Matches[1]
    }
    return $null
}

function Test-EventLogCleared {
    param(
        $Before,
        $After,
        [int]$ExitCode
    )
    if ($ExitCode -ne 0) { return $false }
    if ($null -eq $After -or $After -eq 0) { return $true }
    # wevtutil cl succeeded but Windows may leave 1–10 immediate post-clear events
    # (common on System/Security, especially when the log was already small).
    if ($After -le 10) {
        if ($null -eq $Before -or $Before -le 10) { return $true }
        if ($After -lt $Before) { return $true }
    }
    return $false
}

function Test-ServiceReady {
    param([Parameter(Mandatory)][string]$ServiceName)
    $svc = Get-Service -Name $ServiceName -ErrorAction Stop
    $cfg = Get-CimInstance -ClassName Win32_Service -Filter "Name='$ServiceName'" -ErrorAction Stop
    $startOk = $cfg.StartMode -in @('Auto', 'Automatic')
    $runOk   = $svc.Status -in @('Running', 'StartPending')
    [PSCustomObject]@{
        ServiceName = $ServiceName
        StartMode   = $cfg.StartMode
        Status      = $svc.Status
        Ready       = ($startOk -and $runOk)
        Detail      = "StartMode=$($cfg.StartMode), Status=$($svc.Status)"
    }
}

function Get-HighPerformanceSchemeGuid {
    $list = Invoke-FixCommand -FilePath 'powercfg.exe' -ArgumentList @('/list')
    foreach ($line in $list.Output) {
        if ($line -match 'High performance' -and $line -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') {
            return $Matches[1]
        }
    }
    return '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
}

function Remove-BrowserProfileData {
    param(
        [Parameter(Mandatory)][string]$ProfileRoot,
        [string[]]$ProcessNames
    )
    $details = [System.Collections.Generic.List[string]]::new()
    foreach ($procName in $ProcessNames) {
        Get-Process -Name $procName -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                Stop-Process -Id $_.Id -Force -ErrorAction Stop
                $details.Add("Stopped process: $procName (PID $($_.Id))")
            } catch {
                $details.Add("Could not stop $procName (PID $($_.Id)): $($_.Exception.Message)")
            }
        }
    }
    if ($ProcessNames.Count -gt 0) { Start-Sleep -Seconds 1 }

    $targets = @(
        'Cache', 'Code Cache', 'GPUCache', 'Service Worker',
        'Cookies', 'Local Storage', 'Session Storage', 'IndexedDB', 'WebStorage'
    )
    $removed = 0
    $locked  = 0
    foreach ($name in $targets) {
        $path = Join-Path $ProfileRoot $name
        if (-not (Test-Path -LiteralPath $path)) { continue }
        try {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
            $removed++
            $details.Add("Removed: $name")
        } catch {
            $locked++
            $details.Add("Locked or failed: $name ($($_.Exception.Message))")
        }
    }
    return [PSCustomObject]@{ Removed = $removed; Locked = $locked; Details = $details }
}

function Invoke-Fix {
    param([Parameter(Mandatory)][string]$Key)

    switch ($Key) {
        'ResetWinsock' {
            $result = Invoke-FixCommand -FilePath "$env:SystemRoot\System32\netsh.exe" -ArgumentList @('winsock', 'reset')
            $ok = ($result.ExitCode -eq 0) -or ($result.Text -match 'successfully')
            if ($ok) {
                return New-FixResult -Status Pass -Summary 'Winsock catalog reset — reboot required' -Details @(
                    'Winsock reset command completed successfully.',
                    'Reboot the computer to finish applying the change.'
                )
            }
            return New-FixResult -Status Fail -Summary 'Winsock reset failed' -Details $result.Output
        }

        'RenewIp' {
            $release = Invoke-FixCommand -FilePath "$env:SystemRoot\System32\ipconfig.exe" -ArgumentList @('/release')
            $renew   = Invoke-FixCommand -FilePath "$env:SystemRoot\System32\ipconfig.exe" -ArgumentList @('/renew')
            $adapters = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -notlike '127.*' -and $_.PrefixOrigin -ne 'WellKnown' })
            # Lease evidence: DHCP Preferred address, or renew text that confirms a lease — not merely leftover IPv4.
            $leaseAdapters = @($adapters | Where-Object {
                $_.PrefixOrigin -eq 'Dhcp' -and (
                    -not $_.PSObject.Properties['AddressState'] -or
                    $_.AddressState -eq 'Preferred' -or
                    [string]::IsNullOrWhiteSpace([string]$_.AddressState)
                )
            })
            $leaseFromText = $renew.Text -match '(?i)lease|renewed|successfully'
            $renewExitOk = ($renew.ExitCode -eq 0)
            $hasLeaseEvidence = ($leaseAdapters.Count -gt 0) -or $leaseFromText
            $primaryRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' } |
                Sort-Object RouteMetric |
                Select-Object -First 1
            $primaryDetail = $null
            if ($primaryRoute) {
                $primaryIp = $adapters | Where-Object { $_.InterfaceIndex -eq $primaryRoute.InterfaceIndex } | Select-Object -First 1
                if ($primaryIp) {
                    $nic = Get-NetAdapter -InterfaceIndex $primaryRoute.InterfaceIndex -ErrorAction SilentlyContinue
                    $nicName = if ($nic) { $nic.Name } else { "ifindex $($primaryRoute.InterfaceIndex)" }
                    $primaryDetail = "Primary adapter: $nicName — $($primaryIp.IPAddress) (gateway $($primaryRoute.NextHop))"
                }
            }
            if ($renewExitOk -and $hasLeaseEvidence) {
                $details = @(
                    "ipconfig /renew exit code: $($renew.ExitCode)",
                    "DHCP lease adapters after renew: $($leaseAdapters.Count)"
                )
                if ($primaryDetail) {
                    $details += $primaryDetail
                } elseif ($leaseAdapters.Count -gt 0) {
                    $details += "DHCP IPv4 addresses: $($leaseAdapters.IPAddress -join ', ')"
                }
                if ($release.ExitCode -ne 0) {
                    $details += "Note: ipconfig /release exited $($release.ExitCode); renew still obtained a lease."
                }
                return New-FixResult -Status Pass -Summary 'IP release and renew completed' -Details $details
            }
            $failDetails = @($renew.Output)
            if (-not $renewExitOk) {
                $failDetails = @("ipconfig /renew exit code: $($renew.ExitCode)") + $failDetails
            }
            if (-not $hasLeaseEvidence) {
                $failDetails += "No DHCP lease evidence after renew (leftover non-DHCP IPv4 is not sufficient)."
            }
            return New-FixResult -Status Fail -Summary 'IP renew did not complete successfully' -Details $failDetails
        }

        'DisableIPv6' {
            $adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -ne 'Disabled' })
            $disabled = 0
            $failed   = [System.Collections.Generic.List[string]]::new()
            foreach ($adapter in $adapters) {
                $binding = Get-NetAdapterBinding -Name $adapter.Name -ComponentID 'ms_tcpip6' -ErrorAction SilentlyContinue
                if (-not $binding) { continue }
                if (-not $binding.Enabled) {
                    $disabled++
                    continue
                }
                try {
                    Disable-NetAdapterBinding -Name $adapter.Name -ComponentID 'ms_tcpip6' -ErrorAction Stop
                    $disabled++
                    Write-FixLog "Disabled IPv6 on adapter: $($adapter.Name)"
                } catch {
                    $failed.Add("$($adapter.Name): $($_.Exception.Message)")
                    Write-FixLog "Failed to disable IPv6 on $($adapter.Name): $($_.Exception.Message)" -Level Warning
                }
            }

            $stillEnabled = @(
                foreach ($adapter in $adapters) {
                    $binding = Get-NetAdapterBinding -Name $adapter.Name -ComponentID 'ms_tcpip6' -ErrorAction SilentlyContinue
                    if ($binding -and $binding.Enabled) { $adapter.Name }
                }
            )
            if ($stillEnabled.Count -eq 0) {
                return New-FixResult -Status Pass -Summary 'IPv6 disabled on all active adapters' -Details @(
                    "Adapters processed: $($adapters.Count)",
                    "Bindings disabled or already off: $disabled"
                )
            }
            return New-FixResult -Status Fail -Summary 'IPv6 still enabled on one or more adapters' -Details @(
                "Still enabled on: $($stillEnabled -join ', ')"
            ) + $failed
        }

        'ClearEventLogs' {
            $logs = @('Application', 'System', 'Security')
            $results = foreach ($logName in $logs) {
                $before = Get-EventLogRecordCount -LogName $logName
                $clear = Invoke-FixCommand -FilePath 'wevtutil.exe' -ArgumentList @('cl', $logName)
                $after = Get-EventLogRecordCount -LogName $logName
                $cleared = Test-EventLogCleared -Before $before -After $after -ExitCode $clear.ExitCode
                [PSCustomObject]@{
                    LogName  = $logName
                    Before   = $before
                    After    = $after
                    ExitCode = $clear.ExitCode
                    Ok       = $cleared
                    Output   = $clear.Output
                }
            }
            foreach ($r in $results) {
                $note = if ($r.After -gt 0 -and $r.Before -gt 0 -and $r.Ok) { ' (residual post-clear events — expected)' } else { '' }
                Write-FixLog "$($r.LogName): records before=$($r.Before), after=$($r.After), exit=$($r.ExitCode)$note"
            }
            $failed = @($results | Where-Object { -not $_.Ok })
            if ($failed.Count -eq 0) {
                return New-FixResult -Status Pass -Summary 'Application, System, and Security event logs cleared' -Details @(
                    ($results | ForEach-Object {
                        $suffix = if ($_.After -gt 0) { ' (new events may appear immediately after clear)' } else { '' }
                        "$($_.LogName): $($_.Before) -> $($_.After) records$suffix"
                    })
                )
            }
            $denied = @($failed | Where-Object { $_.ExitCode -ne 0 })
            $summary = if ($denied.Count -gt 0) {
                'One or more event logs could not be cleared (elevation may be required)'
            } else {
                'One or more event logs were not sufficiently cleared'
            }
            return New-FixResult -Status Fail -Summary $summary -Details @(
                ($failed | ForEach-Object {
                    $msg = "$($_.LogName): $($_.Before) -> $($_.After) records, exit code $($_.ExitCode)"
                    if ($_.Output) { $msg += " — $($_.Output -join ' ')" }
                    $msg
                })
            )
        }

        'EnableWuauserv' {
            Set-Service -Name 'wuauserv' -StartupType Automatic -ErrorAction Stop
            Start-Service -Name 'wuauserv' -ErrorAction Stop
            $check = Test-ServiceReady -ServiceName 'wuauserv'
            Write-FixLog $check.Detail
            if ($check.Ready) {
                return New-FixResult -Status Pass -Summary 'Windows Update service enabled and running' -Details @($check.Detail)
            }
            return New-FixResult -Status Fail -Summary 'Windows Update service is not running' -Details @($check.Detail)
        }

        'EnableBits' {
            Set-Service -Name 'bits' -StartupType Automatic -ErrorAction Stop
            Start-Service -Name 'bits' -ErrorAction Stop
            $check = Test-ServiceReady -ServiceName 'bits'
            Write-FixLog $check.Detail
            if ($check.Ready) {
                return New-FixResult -Status Pass -Summary 'BITS enabled and running' -Details @($check.Detail)
            }
            return New-FixResult -Status Fail -Summary 'BITS is not running' -Details @($check.Detail)
        }

        'EnableDefender' {
            $details = [System.Collections.Generic.List[string]]::new()
            $warn = $false

            try {
                Set-Service -Name 'WinDefend' -StartupType Automatic -ErrorAction Stop
                Start-Service -Name 'WinDefend' -ErrorAction SilentlyContinue
                $details.Add('WinDefend service set to Automatic and start attempted.') | Out-Null
            } catch {
                $details.Add("WinDefend service: $($_.Exception.Message)") | Out-Null
                $warn = $true
            }

            try {
                Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction SilentlyContinue
                Set-MpPreference -DisableTamperProtection $false -ErrorAction SilentlyContinue
                $details.Add('Defender real-time protection and tamper protection restore attempted.') | Out-Null
            } catch {
                $details.Add("Defender preferences: $($_.Exception.Message)") | Out-Null
                $warn = $true
            }

            Start-Sleep -Seconds 2
            $check = Test-ServiceReady -ServiceName 'WinDefend'
            $details.Add($check.Detail) | Out-Null

            try {
                $mp = Get-MpComputerStatus -ErrorAction Stop
                if ($mp.RealTimeProtectionEnabled -eq $false) {
                    $details.Add('Real-time protection is still off.') | Out-Null
                    $warn = $true
                }
                if ($mp.IsTamperProtected -eq $false) {
                    $details.Add('Tamper protection is still off. Enable manually: Windows Security > Virus & threat protection > Manage settings > Tamper protection ON.') | Out-Null
                    $warn = $true
                }
            } catch {
                $details.Add("Defender status check: $($_.Exception.Message)") | Out-Null
                $warn = $true
            }

            if ($check.Ready -and -not $warn) {
                return New-FixResult -Status Pass -Summary 'Windows Defender service and protection settings restored' -Details @($details)
            }
            if ($check.Ready) {
                return New-FixResult -Status Fail -Summary 'Windows Defender service is running but some protection settings could not be restored' -Details @($details)
            }
            if ($check.StartMode -in @('Auto', 'Automatic') -and $check.Status -ne 'Running') {
                return New-FixResult -Status Fail -Summary 'Windows Defender is enabled but not running (policy or third-party AV may block it)' -Details @($details)
            }
            return New-FixResult -Status Fail -Summary 'Windows Defender service could not be enabled (administrator approval required)' -Details @($details)
        }

        'ResetEdge' {
            $profile = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data\Default'
            if (-not (Test-Path -LiteralPath $profile)) {
                return New-FixResult -Status Pass -Summary 'Microsoft Edge profile not found (nothing to clear)' -Details @($profile)
            }
            $work = Remove-BrowserProfileData -ProfileRoot $profile -ProcessNames @('msedge', 'msedgewebview2')
            foreach ($line in $work.Details) { Write-FixLog $line }
            if ($work.Removed -gt 0 -and $work.Locked -eq 0) {
                return New-FixResult -Status Pass -Summary 'Microsoft Edge cache and local state cleared' -Details @(
                    "Removed items: $($work.Removed)"
                )
            }
            if ($work.Removed -gt 0) {
                return New-FixResult -Status Fail -Summary 'Microsoft Edge data partially cleared (close Edge and retry)' -Details @(
                    "Removed: $($work.Removed)",
                    "Locked/failed: $($work.Locked)"
                )
            }
            return New-FixResult -Status Fail -Summary 'No Microsoft Edge data could be cleared' -Details $work.Details
        }

        'ResetChrome' {
            $profile = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Default'
            if (-not (Test-Path -LiteralPath $profile)) {
                return New-FixResult -Status Pass -Summary 'Google Chrome profile not found (nothing to clear)' -Details @($profile)
            }
            $work = Remove-BrowserProfileData -ProfileRoot $profile -ProcessNames @('chrome')
            foreach ($line in $work.Details) { Write-FixLog $line }
            if ($work.Removed -gt 0 -and $work.Locked -eq 0) {
                return New-FixResult -Status Pass -Summary 'Google Chrome cache and local state cleared' -Details @(
                    "Removed items: $($work.Removed)"
                )
            }
            if ($work.Removed -gt 0) {
                return New-FixResult -Status Fail -Summary 'Google Chrome data partially cleared (close Chrome and retry)' -Details @(
                    "Removed: $($work.Removed)",
                    "Locked/failed: $($work.Locked)"
                )
            }
            return New-FixResult -Status Fail -Summary 'No Google Chrome data could be cleared' -Details $work.Details
        }

        'FixBrowserAssoc' {
            $exts = @('.htm', '.html', '.url')
            $before = 0
            $cleared = 0
            foreach ($ext in $exts) {
                $userChoice = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$ext\UserChoice"
                if (Test-Path -LiteralPath $userChoice) {
                    $before++
                    Remove-Item -LiteralPath $userChoice -Recurse -Force -ErrorAction Stop
                    $cleared++
                    Write-FixLog "Removed UserChoice override for $ext"
                }
            }
            $remaining = @(
                foreach ($ext in $exts) {
                    $userChoice = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$ext\UserChoice"
                    if (Test-Path -LiteralPath $userChoice) { $ext }
                }
            )
            if ($remaining.Count -gt 0) {
                return New-FixResult -Status Fail -Summary 'Browser association overrides could not be fully cleared' -Details @(
                    "Remaining: $($remaining -join ', ')"
                )
            }
            if ($before -eq 0) {
                return New-FixResult -Status Pass -Summary 'No browser UserChoice overrides were present' -Details @(
                    'Windows will use default handlers for .htm, .html, and .url.'
                )
            }
            return New-FixResult -Status Pass -Summary 'Browser file association overrides cleared' -Details @(
                "Cleared UserChoice keys: $cleared",
                'Re-open the file type or use Settings > Default apps to pick a browser.'
            )
        }

        'DisableAnimations' {
            $windowMetrics = 'HKCU:\Control Panel\Desktop\WindowMetrics'
            $visualEffects = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'
            if (-not (Test-Path -LiteralPath $visualEffects)) {
                New-Item -Path $visualEffects -Force | Out-Null
            }
            Set-ItemProperty -LiteralPath $windowMetrics -Name 'MinAnimate' -Value '0' -Type String -ErrorAction Stop
            Set-ItemProperty -LiteralPath $visualEffects -Name 'VisualFXSetting' -Value 2 -Type DWord -ErrorAction Stop
            $minAnimate = (Get-ItemProperty -LiteralPath $windowMetrics -Name 'MinAnimate' -ErrorAction Stop).MinAnimate
            $visualFx   = (Get-ItemProperty -LiteralPath $visualEffects -Name 'VisualFXSetting' -ErrorAction Stop).VisualFXSetting
            Write-FixLog "MinAnimate=$minAnimate, VisualFXSetting=$visualFx"
            if ($minAnimate -eq '0' -and $visualFx -eq 2) {
                return New-FixResult -Status Pass -Summary 'UI animations disabled' -Details @(
                    'MinAnimate set to 0',
                    'VisualFXSetting set to 2 (adjust for best performance)'
                )
            }
            return New-FixResult -Status Fail -Summary 'Animation registry settings were not applied' -Details @(
                "MinAnimate=$minAnimate",
                "VisualFXSetting=$visualFx"
            )
        }

        'CleanStartMenu' {
            $startMenuRoot = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu'
            $removed = 0
            $skipped = 0
            $shell = New-Object -ComObject WScript.Shell
            $shortcuts = @(Get-ChildItem -LiteralPath $startMenuRoot -Recurse -Filter '*.lnk' -ErrorAction SilentlyContinue)
            Write-FixLog "Scanning $($shortcuts.Count) Start Menu shortcut(s)"
            foreach ($shortcut in $shortcuts) {
                try {
                    $target = $shell.CreateShortcut($shortcut.FullName).TargetPath
                    if ([string]::IsNullOrWhiteSpace($target)) { continue }
                    if (Test-Path -LiteralPath $target) { continue }
                    Remove-Item -LiteralPath $shortcut.FullName -Force -ErrorAction Stop
                    $removed++
                    Write-FixLog "Removed broken shortcut: $($shortcut.Name) -> $target"
                } catch {
                    $skipped++
                    Write-FixLog "Skipped shortcut $($shortcut.Name): $($_.Exception.Message)" -Level Warning
                }
            }
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
            return New-FixResult -Status Pass -Summary 'Start Menu broken shortcuts cleaned' -Details @(
                "Shortcuts scanned: $($shortcuts.Count)",
                "Broken shortcuts removed: $removed",
                $(if ($skipped -gt 0) { "Shortcuts skipped due to errors: $skipped" })
            )
        }

        'SetHighPerf' {
            $guid = Get-HighPerformanceSchemeGuid
            Write-FixLog "Activating power scheme: $guid"
            $activate = Invoke-FixCommand -FilePath 'powercfg.exe' -ArgumentList @('/setactive', $guid)
            $active = Invoke-FixCommand -FilePath 'powercfg.exe' -ArgumentList @('/getactivescheme')
            $isHighPerf = ($active.Text -match [regex]::Escape($guid)) -or ($active.Text -match 'High performance')
            if ($isHighPerf) {
                return New-FixResult -Status Pass -Summary 'High Performance power plan activated' -Details @($active.Text)
            }
            return New-FixResult -Status Fail -Summary 'High Performance power plan was not activated' -Details @(
                "Requested GUID: $guid",
                $active.Text
            ) + $activate.Output
        }

        default {
            return New-FixResult -Status Fail -Summary "Unknown fix key: $Key"
        }
    }
}

switch ($Action) {
    'List' {
        $FixDefinitions | ForEach-Object { [PSCustomObject]$_ } | ConvertTo-Json -Depth 2
    }
    'Apply' {
        Assert-ToolkitCapability -Workflow 'FastFixes' -Action 'Apply'

        $fixDef  = $FixDefinitions | Where-Object { $_.Key -eq $FixKey } | Select-Object -First 1
        if (-not $fixDef) {
            Write-Error "Unknown fix key: $FixKey"
            exit 1
        }

        if ((Get-EnvironmentMode) -eq 'WinPE') {
            $workflow = Start-Workflow -WorkflowName "FastFix_$FixKey" -ScriptBlock {
                param($r)
                $r.Steps.Add([PSCustomObject]@{
                    Name   = $fixDef.Name
                    Status = 'N/A'
                    Output = 'Not applicable in WinPE. Fast fixes target the running Windows installation.'
                }) | Out-Null
            }
            $workflow | ConvertTo-Json -Depth 6
            Generate-Report -WorkflowResult $workflow | Out-Null
            exit 0
        }

        if (Invoke-FastFixElevationRelay -Key $FixKey) {
            exit 0
        }

        $fixName = $fixDef.Name
        $workflow = Start-Workflow -WorkflowName "FastFix_$FixKey" -ScriptBlock {
            param($r)
            Write-FixLog "Applying fix: $fixName ($FixKey)"
            $fixResult = $null
            try {
                $fixResult = Invoke-Fix -Key $FixKey
                foreach ($detail in $fixResult.Details) {
                    if ($detail) { Write-FixLog $detail }
                }
                $stepOutput = $fixResult.Summary
                $detailText = @($fixResult.Details | Where-Object { $_ })
                if ($detailText.Count -gt 0) {
                    $stepOutput += ' | ' + ($detailText -join '; ')
                }
                $r.Steps.Add([PSCustomObject]@{
                    Name   = $fixName
                    Status = $fixResult.Status
                    Output = $stepOutput
                })
                if ($fixResult.Status -eq 'Fail') {
                    $r.Errors.Add($fixResult.Summary)
                    throw [System.InvalidOperationException]::new($fixResult.Summary)
                }
            } catch {
                if (-not @($r.Steps | Where-Object { $_.Name -eq $fixName }).Count) {
                    $r.Steps.Add([PSCustomObject]@{
                        Name   = $fixName
                        Status = 'Fail'
                        Output = $_.Exception.Message
                    })
                    $r.Errors.Add($_.Exception.Message)
                }
                throw
            }
        }
        Generate-Report -WorkflowResult $workflow | Out-Null
        if ($workflow.Status -eq 'Failed') { exit 1 }
    }
}
