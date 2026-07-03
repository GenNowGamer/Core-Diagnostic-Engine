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
    if (Get-Command Get-ToolkitHostsFilePath -ErrorAction SilentlyContinue) {
        return Get-ToolkitHostsFilePath
    }

    if ($env:OFFLINE_WINDOWS_ROOT) {
        $root = $env:OFFLINE_WINDOWS_ROOT.TrimEnd('\')
        return Join-Path $root 'Windows\System32\drivers\etc\hosts'
    }

    return Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
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

    $ie4uinit = Join-Path $env:SystemRoot 'System32\ie4uinit.exe'
    if (Test-Path -LiteralPath $ie4uinit) {
        Invoke-PostOpCapturedCommand -FilePath $ie4uinit -ArgumentList @('-ClearIconCache') | Out-Null
    }

    $thumbRemoved = 0
    $thumbBefore = 0
    $thumbRemaining = 0
    if (Test-Path -LiteralPath $explorerDir) {
        $thumbFiles = @(Get-ChildItem -LiteralPath $explorerDir -Filter 'thumbcache_*.db' -ErrorAction SilentlyContinue)
        $thumbBefore = $thumbFiles.Count
        foreach ($file in $thumbFiles) {
            try {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                $thumbRemoved++
            } catch { }
        }
        $thumbRemaining = @(Get-ChildItem -LiteralPath $explorerDir -Filter 'thumbcache_*.db' -ErrorAction SilentlyContinue).Count
    }

    $iconRemaining = 0
    foreach ($path in $iconPaths) {
        if (Test-Path -LiteralPath $path) { $iconRemaining++ }
    }

    $warn = ($iconLocked -gt 0) -or ($thumbRemaining -gt 0) -or ($iconRemaining -gt 0)
    return [PSCustomObject]@{
        Status  = if ($warn) { 'Warn' } else { 'Pass' }
        Output  = "Icon cache: removed $iconRemoved of $($iconPaths.Count) file(s); thumbnail cache: removed $thumbRemoved of $thumbBefore file(s)."
        Details = @(
            "Icon files remaining: $iconRemaining",
            "Thumbnail files remaining: $thumbRemaining",
            'Run Restart Explorer or sign out to rebuild icon cache if needed.'
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

    return [PSCustomObject]@{
        Status  = 'Fail'
        Output  = 'DNS flush did not complete successfully.'
        Details = @([string]$result.Text)
    }
}

function Invoke-PostOpProxyReset {
    $details = [System.Collections.Generic.List[string]]::new()
    $warn = $false

    $internetSettings = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    if (-not (Test-Path -LiteralPath $internetSettings)) {
        New-Item -Path $internetSettings -Force | Out-Null
    }

    try {
        Set-ItemProperty -LiteralPath $internetSettings -Name ProxyEnable -Value 0 -Type DWord -Force -ErrorAction Stop
        $details.Add('User Internet Settings: ProxyEnable set to 0.') | Out-Null
    } catch {
        $warn = $true
        $details.Add("User Internet Settings: failed to disable proxy - $($_.Exception.Message)") | Out-Null
    }

    foreach ($name in @('ProxyServer', 'AutoConfigURL', 'ProxyOverride')) {
        try {
            Remove-ItemProperty -LiteralPath $internetSettings -Name $name -ErrorAction Stop
            $details.Add("Removed Internet Settings value: $name") | Out-Null
        } catch { }
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
    if (-not (Test-Path -LiteralPath (Split-Path $hostsPath -Parent))) {
        return [PSCustomObject]@{
            Status  = 'Fail'
            Output  = "Hosts directory not found for: $hostsPath"
            Details = @()
        }
    }

    $backupPath = "$hostsPath.backup_$(Get-Date -Format 'yyyyMMddHHmmss')"
    try {
        if (Test-Path -LiteralPath $hostsPath) {
            Copy-Item -LiteralPath $hostsPath -Destination $backupPath -Force -ErrorAction Stop
        }

        $content = Get-DefaultHostsFileContent
        Set-Content -LiteralPath $hostsPath -Value $content -Encoding ASCII -Force -ErrorAction Stop

        return [PSCustomObject]@{
            Status  = 'Pass'
            Output  = 'Hosts file restored to Windows default entries.'
            Details = @(
                "Hosts path: $hostsPath",
                "Backup: $backupPath"
            )
        }
    } catch {
        return [PSCustomObject]@{
            Status  = 'Fail'
            Output  = "Hosts file restore failed: $($_.Exception.Message)"
            Details = @()
        }
    }
}

function Invoke-PostOpRestartExplorer {
    $stopped = $false
    try {
        $explorers = @(Get-Process -Name explorer -ErrorAction SilentlyContinue)
        if ($explorers.Count -gt 0) {
            $explorers | Stop-Process -Force -ErrorAction Stop
            $stopped = $true
            Start-Sleep -Milliseconds 500
        }
    } catch {
        return [PSCustomObject]@{
            Status  = 'Fail'
            Output  = "Could not restart Explorer: $($_.Exception.Message)"
            Details = @()
        }
    }

    try {
        $shell = Join-Path $env:SystemRoot 'explorer.exe'
        Start-Process -FilePath $shell -ErrorAction Stop | Out-Null
        return [PSCustomObject]@{
            Status  = 'Pass'
            Output  = if ($stopped) { 'Windows Explorer restarted.' } else { 'Windows Explorer was not running; started a new instance.' }
            Details = @()
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
