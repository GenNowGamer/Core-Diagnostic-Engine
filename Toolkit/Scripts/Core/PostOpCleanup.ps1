#Requires -Version 5.1
<#
.SYNOPSIS
    Shared post-operation cleanup helpers for PostOp.ps1.
#>

function Invoke-PostOpCapturedCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @()
    )

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

    $process = [System.Diagnostics.Process]::Start($startInfo)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    $text = (($stdout + "`n" + $stderr).Trim())
    return [PSCustomObject]@{
        ExitCode = $process.ExitCode
        Text     = $text
        Output   = $text
    }
}

function Get-PostOpHostsFilePath {
    <#
    .SYNOPSIS
        Resolves the hosts file for Post-Op restore.
        On a live Windows session, always targets the running OS (not an offline attach).
    #>
    if (Get-Command Get-EnvironmentMode -ErrorAction SilentlyContinue) {
        if ((Get-EnvironmentMode) -eq 'Windows') {
            return Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
        }
    }

    if (Get-Command Get-ToolkitHostsFilePath -ErrorAction SilentlyContinue) {
        return Get-ToolkitHostsFilePath
    }

    if ($env:OFFLINE_WINDOWS_ROOT) {
        $root = $env:OFFLINE_WINDOWS_ROOT.TrimEnd('\')
        return Join-Path $root 'Windows\System32\drivers\etc\hosts'
    }

    return Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
}

function Clear-ToolkitFileReadOnlyAttribute {
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) { return }

    $item = Get-Item -LiteralPath $Path -Force
    $mask = [System.IO.FileAttributes]::ReadOnly -bor [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System
    if (($item.Attributes -band $mask) -ne 0) {
        $item.Attributes = $item.Attributes -band (-bnot $mask)
    }
}

function Get-DefaultHostsFileContent {
    return @(
        '# Copyright (c) 1993-2009 Microsoft Corp.'
        '#'
        '# This is a sample HOSTS file used by Microsoft TCP/IP for Windows.'
        '#'
        '# This file contains the mappings of IP addresses to host names. Each'
        '# entry should be kept on an individual line. The IP address should'
        '# be placed in the first column followed by the corresponding host name.'
        '# The IP address and the host name should be separated by at least one'
        '# space.'
        '#'
        '# Additionally, comments (such as these) may be inserted on individual'
        '# lines or following the machine name denoted by a "#" symbol.'
        '#'
        '# For example:'
        '#'
        '#      102.54.94.97     rhino.acme.com          # source server'
        '#       38.25.63.10     x.acme.com              # x client host'
        ''
        '# localhost name resolution is handled within DNS itself.'
        '#	127.0.0.1       localhost'
        '#	::1             localhost'
        ''
        '127.0.0.1       localhost'
        '::1             localhost'
    ) -join "`r`n"
}

function Invoke-PostOpIconThumbCacheClear {
    $iconPaths = [System.Collections.Generic.List[string]]::new()
    $legacy = Join-Path $env:LOCALAPPDATA 'IconCache.db'
    if (Test-Path -LiteralPath $legacy) { $iconPaths.Add($legacy) | Out-Null }

    $explorerDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'
    if (Test-Path -LiteralPath $explorerDir) {
        Get-ChildItem -LiteralPath $explorerDir -Filter 'iconcache_*.db' -ErrorAction SilentlyContinue |
            ForEach-Object { $iconPaths.Add($_.FullName) | Out-Null }
    }

    $thumbFiles = @()
    if (Test-Path -LiteralPath $explorerDir) {
        $thumbFiles = @(Get-ChildItem -LiteralPath $explorerDir -Filter 'thumbcache_*.db' -ErrorAction SilentlyContinue)
    }

    # Stop Explorer briefly so iconcache_*.db and thumbcache_*.db are not exclusively locked.
    $stoppedExplorer = $false
    $explorers = @(Get-Process -Name explorer -ErrorAction SilentlyContinue)
    if ($explorers.Count -gt 0 -and ($iconPaths.Count -gt 0 -or $thumbFiles.Count -gt 0)) {
        try {
            $explorers | Stop-Process -Force -ErrorAction Stop
            $stoppedExplorer = $true
            Start-Sleep -Milliseconds 500
        } catch { }
    }

    $iconRemoved = 0
    $iconLocked = 0
    foreach ($path in $iconPaths) {
        try {
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
            $iconRemoved++
        } catch {
            $iconLocked++
        }
    }

    $thumbRemoved = 0
    $thumbBefore = $thumbFiles.Count
    $thumbRemaining = 0
    foreach ($file in $thumbFiles) {
        try {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            $thumbRemoved++
        } catch { }
    }
    if (Test-Path -LiteralPath $explorerDir) {
        $thumbRemaining = @(Get-ChildItem -LiteralPath $explorerDir -Filter 'thumbcache_*.db' -ErrorAction SilentlyContinue).Count
    }

    $iconRemaining = 0
    foreach ($path in $iconPaths) {
        if (Test-Path -LiteralPath $path) { $iconRemaining++ }
    }

    $ie4uinit = Join-Path $env:SystemRoot 'System32\ie4uinit.exe'
    if (Test-Path -LiteralPath $ie4uinit) {
        Invoke-PostOpCapturedCommand -FilePath $ie4uinit -ArgumentList @('-ClearIconCache') | Out-Null
        Invoke-PostOpCapturedCommand -FilePath $ie4uinit -ArgumentList @('-show') | Out-Null
    }

    if ($stoppedExplorer) {
        $null = Invoke-PostOpRestartExplorer -SkipStop
    }

    $warn = ($iconLocked -gt 0) -or ($thumbRemaining -gt 0) -or ($iconRemaining -gt 0)
    return [PSCustomObject]@{
        Status  = if ($warn) { 'Warn' } else { 'Pass' }
        Output  = "Icon cache: removed $iconRemoved of $($iconPaths.Count) file(s); thumbnail cache: removed $thumbRemoved of $thumbBefore file(s)."
        Details = @(
            "Icon files remaining: $iconRemaining",
            "Thumbnail files remaining: $thumbRemaining",
            $(if ($stoppedExplorer) { 'Explorer restarted to release cache locks and rebuild caches.' } else { 'Run Restart Explorer or sign out to rebuild icon cache if needed.' })
        )
    }
}

function Invoke-PostOpDnsFlush {
    $before = $null
    try {
        $before = @(Get-DnsClientCache -ErrorAction Stop).Count
    } catch { }

    $result = Invoke-PostOpCapturedCommand -FilePath "$env:SystemRoot\System32\ipconfig.exe" -ArgumentList @('/flushdns')
    $flushed = ($result.Text -match 'Successfully flushed') -or ($result.ExitCode -eq 0)

    $after = $null
    try {
        $after = @(Get-DnsClientCache -ErrorAction Stop).Count
    } catch { }

    if ($flushed) {
        $detail = if ($null -ne $before -and $null -ne $after) {
            "DNS cache entries: $before -> $after"
        } else {
            [string]$result.Text
        }
        return [PSCustomObject]@{
            Status = 'Pass'
            Output = 'DNS resolver cache flushed.'
            Details = @($detail)
        }
    }

    $details = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($result.Text)) {
        $details.Add([string]$result.Text) | Out-Null
    }
    $dnsSvc = Get-Service -Name 'Dnscache' -ErrorAction SilentlyContinue
    if ($dnsSvc -and $dnsSvc.Status -ne 'Running') {
        $details.Add("DNS Client service (Dnscache) is currently $($dnsSvc.Status).") | Out-Null
    }

    return [PSCustomObject]@{
        Status  = 'Fail'
        Output  = 'DNS flush did not complete successfully.'
        Details = @($details)
    }
}

function Invoke-PostOpProxyReset {
    $details = [System.Collections.Generic.List[string]]::new()
    $warn = $false

    $targetPaths = [System.Collections.Generic.List[string]]::new()
    $targetPaths.Add('HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings') | Out-Null
    try {
        foreach ($sidKey in (Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue)) {
            $sidName = $sidKey.PSChildName
            if ($sidName -match '^S-1-(?:5-21|12-1)-[\d-]+$' -and $sidName -notlike '*_Classes') {
                $candidate = "Registry::HKEY_USERS\$sidName\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
                if (Test-Path -LiteralPath $candidate) {
                    $targetPaths.Add($candidate) | Out-Null
                }
            }
        }
    } catch { }

    foreach ($internetSettings in ($targetPaths | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $internetSettings)) {
            if ($internetSettings -like 'HKCU:*') {
                New-Item -Path $internetSettings -Force | Out-Null
            } else {
                continue
            }
        }

        try {
            Set-ItemProperty -LiteralPath $internetSettings -Name ProxyEnable -Value 0 -Type DWord -Force -ErrorAction Stop
            $details.Add("Internet Settings ($internetSettings): ProxyEnable set to 0.") | Out-Null
        } catch {
            $warn = $true
            $details.Add("Internet Settings ($internetSettings): failed to disable proxy - $($_.Exception.Message)") | Out-Null
        }

        foreach ($name in @('ProxyServer', 'AutoConfigURL', 'ProxyOverride')) {
            try {
                Remove-ItemProperty -LiteralPath $internetSettings -Name $name -ErrorAction Stop
                $details.Add("Removed Internet Settings value ($internetSettings): $name") | Out-Null
            } catch { }
        }

        $connectionsPath = Join-Path $internetSettings 'Connections'
        if (Test-Path -LiteralPath $connectionsPath) {
            foreach ($connProp in @('DefaultConnectionSettings', 'SavedLegacySettings')) {
                try {
                    $connObj = Get-ItemProperty -LiteralPath $connectionsPath -Name $connProp -ErrorAction Stop
                    $bytes = [byte[]]$connObj.$connProp
                    if ($bytes -and $bytes.Length -ge 9 -and (($bytes[8] -band 0x0E) -ne 0)) {
                        # Bitmask in byte 8: 0x01=Direct, 0x02=ManualProxy, 0x04=AutoConfigURL, 0x08=AutoDetect
                        $bytes[8] = 0x01
                        Set-ItemProperty -LiteralPath $connectionsPath -Name $connProp -Value $bytes -Type Binary -Force -ErrorAction Stop
                        $details.Add("Reset $connProp flags ($connectionsPath).") | Out-Null
                    }
                } catch { }
            }
        }
    }

    $winhttp = Invoke-PostOpCapturedCommand -FilePath "$env:SystemRoot\System32\netsh.exe" -ArgumentList @('winhttp', 'reset', 'proxy')
    if ($winhttp.ExitCode -eq 0 -or $winhttp.Text -match 'success|reset') {
        $details.Add('WinHTTP proxy reset completed.') | Out-Null
    } else {
        $warn = $true
        $details.Add("WinHTTP proxy reset issue: $($winhttp.Text)") | Out-Null
    }

    return [PSCustomObject]@{
        Status  = if ($warn) { 'Warn' } else { 'Pass' }
        Output  = 'User proxy and WinHTTP proxy settings reset to defaults.'
        Details = @($details)
    }
}

function Invoke-PostOpHostsFileRestore {
    param(
        [switch]$Confirmed
    )

    if (-not $Confirmed) {
        return [PSCustomObject]@{
            Status  = 'Warn'
            Output  = 'Hosts file restore was not confirmed.'
            Details = @('Re-run with confirmation to replace the hosts file with Windows defaults (backup created first).')
        }
    }

    $hostsPath = Get-PostOpHostsFilePath
    $hostsDir = Split-Path $hostsPath -Parent
    if (-not (Test-Path -LiteralPath $hostsDir)) {
        return [PSCustomObject]@{
            Status  = 'Fail'
            Output  = "Hosts directory not found for: $hostsPath"
            Details = @()
        }
    }

    $backupPath = "$hostsPath.backup_$(Get-Date -Format 'yyyyMMddHHmmss')"
    $details = [System.Collections.Generic.List[string]]::new()
    $details.Add("Hosts path: $hostsPath") | Out-Null

    try {
        if (Test-Path -LiteralPath $hostsPath) {
            Clear-ToolkitFileReadOnlyAttribute -Path $hostsPath
            Copy-Item -LiteralPath $hostsPath -Destination $backupPath -Force -ErrorAction Stop
            $details.Add("Backup: $backupPath") | Out-Null
        }

        $content = Get-DefaultHostsFileContent
        Clear-ToolkitFileReadOnlyAttribute -Path $hostsPath
        [System.IO.File]::WriteAllText($hostsPath, $content, [System.Text.Encoding]::ASCII)

        return [PSCustomObject]@{
            Status  = 'Pass'
            Output  = 'Hosts file restored to Windows default entries.'
            Details = @($details)
        }
    } catch {
        $message = $_.Exception.Message
        if (Get-Command Test-ToolkitIsElevated -ErrorAction SilentlyContinue) {
            if (-not (Test-ToolkitIsElevated)) {
                $message = "$message (Administrator elevation is required to modify the hosts file.)"
            }
        }

        return [PSCustomObject]@{
            Status  = 'Fail'
            Output  = "Hosts file restore failed: $message"
            Details = @($details)
        }
    }
}

function Invoke-PostOpRestartExplorer {
    param(
        [switch]$SkipStop
    )

    $stopped = $SkipStop.IsPresent
    if (-not $SkipStop) {
        try {
            $explorers = @(Get-Process -Name explorer -ErrorAction SilentlyContinue)
            if ($explorers.Count -gt 0) {
                $explorers | Stop-Process -Force -ErrorAction Stop
                $stopped = $true
            }
        } catch {
            return [PSCustomObject]@{
                Status  = 'Fail'
                Output  = "Could not restart Explorer: $($_.Exception.Message)"
                Details = @()
            }
        }
    }

    if ($stopped) {
        # Give Windows AutoRestartShell up to 1.5s to respawn Explorer so we don't open a duplicate window.
        for ($i = 0; $i -lt 3; $i++) {
            Start-Sleep -Milliseconds 500
            if (@(Get-Process -Name explorer -ErrorAction SilentlyContinue).Count -gt 0) {
                return [PSCustomObject]@{
                    Status  = 'Pass'
                    Output  = 'Windows Explorer restarted.'
                    Details = @()
                }
            }
        }
    }

    try {
        $shell = Join-Path $env:SystemRoot 'explorer.exe'
        Start-Process -FilePath $shell -ErrorAction Stop | Out-Null
        $details = @()
        if (Get-Command Test-ToolkitIsElevated -ErrorAction SilentlyContinue) {
            if (Test-ToolkitIsElevated) {
                $details = @('Note: Explorer was started from an elevated CDE session.')
            }
        }
        return [PSCustomObject]@{
            Status  = 'Pass'
            Output  = if ($stopped) { 'Windows Explorer restarted.' } else { 'Windows Explorer was not running; started a new instance.' }
            Details = $details
        }
    } catch {
        return [PSCustomObject]@{
            Status  = 'Fail'
            Output  = "Explorer start failed: $($_.Exception.Message)"
            Details = @()
        }
    }
}

function Add-PostOpToolStep {
    param(
        $WorkflowResult,
        [string]$StepName,
        [object]$Result
    )

    $output = [string]$Result.Output
    if ($Result.Details -and @($Result.Details).Count -gt 0) {
        $output = $output + "`n" + (($Result.Details | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n")
    }

    Add-ToolkitWorkflowStep -WorkflowResult $WorkflowResult -Name $StepName -Status ([string]$Result.Status) -Output $output
}
