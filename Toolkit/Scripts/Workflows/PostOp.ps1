#Requires -Version 5.1
<#
.SYNOPSIS
    PostOp.ps1 — Post-operation cleanup tools dispatcher.
    Pass -ToolName to run a specific tool.
#>
param(
    [string]$ToolName = 'All',
    [switch]$ElevatedRelay,
    [switch]$ConfirmHostsRestore
    # TempCleanup | BrowserCacheClean | RestoreDefaultServices | FileAssociationFix |
    # IconThumbCacheClear | DnsFlush | ProxyReset | HostsFileRestore | RestartExplorer | All
)

$ErrorActionPreference = 'Stop'

$Script:PostOpScriptPath = $MyInvocation.MyCommand.Path
$ScriptDir  = Split-Path $Script:PostOpScriptPath
$CoreModule = Join-Path $ScriptDir '..\Core\Toolkit.Core.psm1'
$ElevationModule = Join-Path $ScriptDir '..\Core\Toolkit.Elevation.psm1'
$PostOpCleanupScript = Join-Path $ScriptDir '..\Core\PostOpCleanup.ps1'
Import-Module $CoreModule -Force -DisableNameChecking
Import-Module $ElevationModule -Force -DisableNameChecking
. $PostOpCleanupScript

function Get-BrowserCacheTargetPaths {
    $targets = [System.Collections.Generic.List[object]]::new()
    $skipProfileNames = @('System Profile', 'Guest Profile', 'Crashpad', 'ShaderCache', 'GrShaderCache')

    $chromiumBases = @(
        @{ Label = 'Edge';   Root = "$env:LOCALAPPDATA\Microsoft\Edge\User Data" },
        @{ Label = 'Chrome'; Root = "$env:LOCALAPPDATA\Google\Chrome\User Data" }
    )
    $cacheSubdirs = @('Cache', 'Code Cache', 'GPUCache')

    foreach ($browser in $chromiumBases) {
        if (-not (Test-Path $browser.Root)) { continue }
        Get-ChildItem -LiteralPath $browser.Root -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notin $skipProfileNames } |
            ForEach-Object {
                foreach ($sub in $cacheSubdirs) {
                    $path = Join-Path $_.FullName $sub
                    if (Test-Path -LiteralPath $path) {
                        $targets.Add([PSCustomObject]@{ Label = $browser.Label; Profile = $_.Name; Path = $path }) | Out-Null
                    }
                }
            }
    }

    $firefoxProfiles = "$env:APPDATA\Mozilla\Firefox\Profiles"
    if (Test-Path -LiteralPath $firefoxProfiles) {
        Get-ChildItem -LiteralPath $firefoxProfiles -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                foreach ($sub in @('cache2', 'startupCache', 'thumbnails')) {
                    $path = Join-Path $_.FullName $sub
                    if (Test-Path -LiteralPath $path) {
                        $targets.Add([PSCustomObject]@{ Label = 'Firefox'; Profile = $_.Name; Path = $path }) | Out-Null
                    }
                }
            }
    }

    return @($targets)
}

function Test-BrowserProcessesRunning {
    $names = @('msedge', 'chrome', 'firefox')
    foreach ($name in $names) {
        if (Get-Process -Name $name -ErrorAction SilentlyContinue) {
            return $true
        }
    }
    return $false
}

function Invoke-TempCleanup {
    param($r)
    Write-Log "Cleaning temporary files..."
    $paths = @(
        $env:TEMP,
        [System.IO.Path]::GetTempPath(),
        'C:\Windows\Temp',
        "$env:LOCALAPPDATA\Temp"
    ) | Select-Object -Unique | Where-Object { Test-Path $_ }

    $totalDeleted = 0
    $totalBytes   = 0

    foreach ($path in $paths) {
        Write-Log "  Cleaning: $path"
        try {
            $items = Get-ChildItem $path -Recurse -Force -ErrorAction SilentlyContinue
            $bytes = ($items | Measure-Object Length -Sum -ErrorAction SilentlyContinue).Sum
            Remove-Item "$path\*" -Recurse -Force -ErrorAction SilentlyContinue
            $safeBytes = if ($bytes) { [long]$bytes } else { 0 }
            $totalBytes   += $safeBytes
            $totalDeleted += $items.Count
            Write-Log "  Removed $($items.Count) item(s) ($(Format-SizeHuman -Bytes $safeBytes))"
        } catch {
            Write-Log "  [WARN] $path — $_"
        }
    }

    Write-Log "Total freed: ~$(Format-SizeHuman -Bytes ([long]$totalBytes))"
    $status = Get-ToolkitWorkflowStepStatus -Succeeded $totalDeleted -Skipped 0
    Add-ToolkitWorkflowStep -WorkflowResult $r -Name 'TempCleanup' -Status $status `
        -Output "Removed $totalDeleted items (~$(Format-SizeHuman -Bytes ([long]$totalBytes)))"
}

function Invoke-BrowserCacheClean {
    param($r)

    if ((Get-EnvironmentMode) -eq 'WinPE') {
        Add-ToolkitWorkflowStep -WorkflowResult $r -Name 'BrowserCacheClean' -Status 'N/A' `
            -Output 'Not applicable in WinPE. Requires live user profile paths.'
        return
    }

    Write-Log "Clearing browser disk cache (not cookies or saved passwords)..."
    $targets = Get-BrowserCacheTargetPaths
    if ($targets.Count -eq 0) {
        Add-ToolkitWorkflowStep -WorkflowResult $r -Name 'BrowserCacheClean' -Status 'Warn' `
            -Output 'No browser cache directories found.'
        return
    }

    $browserRunning = Test-BrowserProcessesRunning
    if ($browserRunning) {
        Write-Log "  [WARN] A browser process is running; some files may remain locked."
    }

    $results = @()
    $cleared = 0
    $skipped = 0

    foreach ($target in $targets) {
        try {
            $items = Get-ChildItem -LiteralPath $target.Path -Recurse -Force -ErrorAction SilentlyContinue
            $bytes = ($items | Measure-Object Length -Sum -ErrorAction SilentlyContinue).Sum
            $safeBytes = if ($bytes) { [long]$bytes } else { 0 }
            Remove-Item -LiteralPath "$($target.Path)\*" -Recurse -Force -ErrorAction SilentlyContinue
            $freedText = Format-SizeHuman -Bytes $safeBytes
            Write-Log "  $($target.Label) [$($target.Profile)]\$([IO.Path]::GetFileName($target.Path)): ~$freedText"
            $results += "$($target.Label)/$($target.Profile): ~$freedText"
            $cleared++
        } catch {
            $skipped++
            Write-Log "  $($target.Label) [$($target.Profile)]: skipped — $_"
            $results += "$($target.Label)/$($target.Profile): skipped"
        }
    }

    $status = Get-ToolkitWorkflowStepStatus -Succeeded $cleared -Skipped $skipped
    if ($browserRunning -and $status -eq 'Pass') { $status = 'Warn' }
    Add-ToolkitWorkflowStep -WorkflowResult $r -Name 'BrowserCacheClean' -Status $status `
        -Output ($results -join ' | ')
}

function Invoke-RestoreDefaultServices {
    param($r)

    if ((Get-EnvironmentMode) -eq 'WinPE') {
        Add-ToolkitWorkflowStep -WorkflowResult $r -Name 'RestoreDefaultServices' -Status 'N/A' `
            -Output 'Not applicable in WinPE. Service start types apply to the running OS.'
        return
    }

    Write-Log "Restoring default service start types for critical Windows services..."

    $defaults = @{
        'wuauserv'          = 'Automatic'
        'bits'              = 'Automatic'
        'cryptsvc'          = 'Automatic'
        'msiserver'         = 'Manual'
        'TrustedInstaller'  = 'Manual'
        'WinDefend'         = 'Automatic'
        'wscsvc'            = 'Automatic'
        'EventLog'          = 'Automatic'
        'LanmanWorkstation' = 'Automatic'
        'RpcSs'             = 'Automatic'
        'Dhcp'              = 'Automatic'
        'DnsCache'          = 'Automatic'
    }

    $fixed = 0
    $skipped = 0

    foreach ($svc in $defaults.GetEnumerator()) {
        try {
            $null = Get-Service -Name $svc.Key -ErrorAction Stop
            Set-Service -Name $svc.Key -StartupType $svc.Value -ErrorAction Stop
            Write-Log "  $($svc.Key): set to $($svc.Value)"
            $fixed++
        } catch {
            $skipped++
            Write-Log "  $($svc.Key): skipped — $_"
        }
    }

    Write-Log "Services adjusted: $fixed | Skipped: $skipped"
    $status = Get-ToolkitWorkflowStepStatus -Succeeded $fixed -Skipped $skipped -RequireSuccess
    $output = if ($fixed -eq 0) {
        "$fixed service(s) restored, $skipped skipped. Run CDE as Administrator."
    } else {
        "$fixed service(s) restored to defaults, $skipped skipped"
    }
    Add-ToolkitWorkflowStep -WorkflowResult $r -Name 'RestoreDefaultServices' -Status $status -Output $output
}

function Invoke-CmdAssoc {
    param([string]$CommandLine)
    $output = & cmd.exe /c $CommandLine 2>&1
    return [PSCustomObject]@{
        ExitCode = $LASTEXITCODE
        Output   = ([string]$output).Trim()
    }
}

function Get-RegistryDefaultProgId {
    param([string]$Extension)

    $paths = @(
        "Registry::HKEY_CLASSES_ROOT\$Extension",
        "Registry::HKEY_CURRENT_USER\Software\Classes\$Extension",
        "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes\$Extension"
    )
    foreach ($path in $paths) {
        try {
            if (Test-Path -LiteralPath $path) {
                $val = (Get-ItemProperty -LiteralPath $path -Name '(default)' -ErrorAction Stop).'(default)'
                if ($val) { return [string]$val }
            }
        } catch { }
    }
    return ''
}

function Set-RegistryProgIdDefault {
    param(
        [string]$Extension,
        [string]$ProgId
    )

    $fixed = 0
    $targets = @(
        "Registry::HKEY_CLASSES_ROOT\$Extension",
        "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes\$Extension",
        "Registry::HKEY_CURRENT_USER\Software\Classes\$Extension"
    )
    foreach ($path in $targets) {
        try {
            if (-not (Test-Path -LiteralPath $path)) {
                New-Item -LiteralPath $path -Force | Out-Null
            }
            Set-ItemProperty -LiteralPath $path -Name '(default)' -Value $ProgId -ErrorAction Stop
            $fixed++
        } catch {
            Write-Log "  [WARN] $path — $_"
        }
    }
    return $fixed
}

function Repair-CriticalFileTypeOpenCommand {
    param(
        [string]$FileType,
        [string]$Command = '"%1" %*'
    )

    $commandPath = "Registry::HKEY_CLASSES_ROOT\$FileType\shell\open\command"
    try {
        if (-not (Test-Path -LiteralPath $commandPath)) {
            New-Item -LiteralPath $commandPath -Force | Out-Null
        }
        Set-ItemProperty -LiteralPath $commandPath -Name '(default)' -Value $Command -ErrorAction Stop
        return $true
    } catch {
        Write-Log "  [WARN] $commandPath — $_"
        return $false
    }
}

function Invoke-FileAssociationFix {
    param($r)

    if ((Get-EnvironmentMode) -eq 'WinPE') {
        Add-ToolkitWorkflowStep -WorkflowResult $r -Name 'FileAssociationFix' -Status 'N/A' `
            -Output 'Not applicable in WinPE. File association repair targets the running Windows installation.'
        return
    }

    Write-Log "Repairing critical system file handlers (.exe, .lnk, .bat, .cmd, .com)..."

    $critical = @(
        @{ Ext = '.exe'; FileType = 'exefile' },
        @{ Ext = '.com'; FileType = 'comfile' },
        @{ Ext = '.bat'; FileType = 'batfile' },
        @{ Ext = '.cmd'; FileType = 'cmdfile' },
        @{ Ext = '.lnk'; FileType = 'lnkfile' }
    )

    $allowedProgIds = @('exefile', 'comfile', 'batfile', 'cmdfile', 'lnkfile')
    $repairs = 0
    $hijacks = 0
    $logLines = [System.Collections.Generic.List[string]]::new()

    foreach ($item in $critical) {
        $before = Get-RegistryDefaultProgId -Extension $item.Ext
        if ($before -and $before -notin $allowedProgIds) {
            $hijacks++
            Write-Log "  $($item.Ext) hijacked: $before -> $($item.FileType)"
            Set-RegistryProgIdDefault -Extension $item.Ext -ProgId $item.FileType | Out-Null
        }

        $assocResult = Invoke-CmdAssoc -CommandLine "assoc $($item.Ext)=$($item.FileType)"
        Write-Log "  assoc $($item.Ext): $($assocResult.Output)"
        if ($assocResult.ExitCode -eq 0) { $repairs++ }

        $ftypeCmd = if ($item.FileType -eq 'lnkfile') { "ftype $($item.FileType)=`"%1`" %*" } else { "ftype $($item.FileType)=`"%1`" %*" }
        $ftypeResult = Invoke-CmdAssoc -CommandLine $ftypeCmd
        Write-Log "  ftype $($item.FileType): $($ftypeResult.Output)"
        if ($ftypeResult.ExitCode -eq 0) { $repairs++ }

        if (Repair-CriticalFileTypeOpenCommand -FileType $item.FileType) {
            $repairs++
        }
    }

    $afterExe = (Invoke-CmdAssoc -CommandLine 'assoc .exe').Output
    $afterFtype = (Invoke-CmdAssoc -CommandLine 'ftype exefile').Output
    $logLines.Add("After: $afterExe | $afterFtype") | Out-Null
    $logLines.Add("Repairs applied: $repairs; hijacks corrected: $hijacks") | Out-Null
    $logLines.Add('Note: User default apps for documents/browsers are managed by Settings; UserChoice keys were not modified.') | Out-Null

    $verified = $afterExe -match 'exefile' -and $afterFtype -match '%1'
    $status = if ($verified) {
        if ($hijacks -gt 0) { 'Warn' } else { 'Pass' }
    } elseif ($repairs -gt 0) {
        'Warn'
    } else {
        'Fail'
    }

    Add-ToolkitWorkflowStep -WorkflowResult $r -Name 'FileAssociationFix' -Status $status `
        -Output ($logLines -join "`n")
}

function Invoke-IconThumbCacheClear {
    param($r)

    if ((Get-EnvironmentMode) -eq 'WinPE') {
        Add-ToolkitWorkflowStep -WorkflowResult $r -Name 'IconThumbCacheClear' -Status 'N/A' `
            -Output 'Not applicable in WinPE. Requires live user profile caches.'
        return
    }

    Write-Log 'Clearing icon and thumbnail caches...'
    $result = Invoke-PostOpIconThumbCacheClear
    foreach ($line in @($result.Details)) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            Write-Log "  $line"
        }
    }
    Add-PostOpToolStep -WorkflowResult $r -StepName 'IconThumbCacheClear' -Result $result
}

function Invoke-DnsFlush {
    param($r)

    if ((Get-EnvironmentMode) -eq 'WinPE') {
        Add-ToolkitWorkflowStep -WorkflowResult $r -Name 'DnsFlush' -Status 'N/A' `
            -Output 'Not applicable in WinPE. Requires live DNS client stack.'
        return
    }

    Write-Log 'Flushing DNS resolver cache...'
    $result = Invoke-PostOpDnsFlush
    foreach ($line in @($result.Details)) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            Write-Log "  $line"
        }
    }
    Add-PostOpToolStep -WorkflowResult $r -StepName 'DnsFlush' -Result $result
}

function Invoke-ProxyReset {
    param($r)

    if ((Get-EnvironmentMode) -eq 'WinPE') {
        Add-ToolkitWorkflowStep -WorkflowResult $r -Name 'ProxyReset' -Status 'N/A' `
            -Output 'Not applicable in WinPE. Requires live user Internet Settings.'
        return
    }

    Write-Log 'Resetting user proxy and WinHTTP proxy settings...'
    $result = Invoke-PostOpProxyReset
    foreach ($line in @($result.Details)) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            Write-Log "  $line"
        }
    }
    Add-PostOpToolStep -WorkflowResult $r -StepName 'ProxyReset' -Result $result
}

function Invoke-HostsFileRestore {
    param($r)

    if (-not $ConfirmHostsRestore) {
        Add-ToolkitWorkflowStep -WorkflowResult $r -Name 'HostsFileRestore' -Status 'Warn' `
            -Output 'Hosts file restore requires confirmation. Approve the prompt in the GUI or pass -ConfirmHostsRestore.'
        return
    }

    Write-Log 'Restoring hosts file to Windows defaults (backup first)...'
    $result = Invoke-PostOpHostsFileRestore -Confirmed
    foreach ($line in @($result.Details)) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            Write-Log "  $line"
        }
    }
    Add-PostOpToolStep -WorkflowResult $r -StepName 'HostsFileRestore' -Result $result
}

function Invoke-RestartExplorer {
    param($r)

    if ((Get-EnvironmentMode) -eq 'WinPE') {
        Add-ToolkitWorkflowStep -WorkflowResult $r -Name 'RestartExplorer' -Status 'N/A' `
            -Output 'Not applicable in WinPE.'
        return
    }

    Write-Log 'Restarting Windows Explorer...'
    $result = Invoke-PostOpRestartExplorer
    Add-PostOpToolStep -WorkflowResult $r -StepName 'RestartExplorer' -Result $result
}

$Script:PostOpElevationTools = @(
    'TempCleanup',
    'RestoreDefaultServices',
    'FileAssociationFix',
    'ProxyReset',
    'HostsFileRestore',
    'All'
)

function Get-PostOpRelayArgumentString {
    $parts = [System.Collections.Generic.List[string]]::new()
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'ToolName' -Value $ToolName
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'ElevatedRelay' -IsSwitch
    if ($ConfirmHostsRestore) {
        Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'ConfirmHostsRestore' -IsSwitch
    }
    return Join-ToolkitRelayArgumentString -Parts $parts
}

function Invoke-PostOpElevationRelay {
    if ($ElevatedRelay) { return $false }
    if ((Get-EnvironmentMode) -eq 'WinPE') { return $false }
    if ($Script:PostOpElevationTools -notcontains $ToolName) { return $false }
    return (Invoke-ToolkitWorkflowElevationRelay -ScriptPath $Script:PostOpScriptPath `
        -ArgumentString (Get-PostOpRelayArgumentString) -ElevatedRelay:$ElevatedRelay)
}

# ─── Dispatch ───────────────────────────────────────────────────────────────
$workflowName = if ($ToolName -eq 'All') { 'PostOp_All' } else { "PostOp_$ToolName" }

if (Invoke-PostOpElevationRelay) { exit 0 }

try {
    $workflow = Start-Workflow -WorkflowName $workflowName -ScriptBlock {
        param($r)
        switch ($ToolName) {
            'TempCleanup'            { Invoke-TempCleanup $r }
            'BrowserCacheClean'      { Invoke-BrowserCacheClean $r }
            'RestoreDefaultServices' { Invoke-RestoreDefaultServices $r }
            'FileAssociationFix'     { Invoke-FileAssociationFix $r }
            'IconThumbCacheClear'    { Invoke-IconThumbCacheClear $r }
            'DnsFlush'               { Invoke-DnsFlush $r }
            'ProxyReset'             { Invoke-ProxyReset $r }
            'HostsFileRestore'       { Invoke-HostsFileRestore $r }
            'RestartExplorer'        { Invoke-RestartExplorer $r }
            default {
                Invoke-TempCleanup $r
                Invoke-BrowserCacheClean $r
                Invoke-RestoreDefaultServices $r
                Invoke-FileAssociationFix $r
                Invoke-IconThumbCacheClear $r
                Invoke-DnsFlush $r
                Invoke-ProxyReset $r
                Invoke-RestartExplorer $r
            }
        }
        Write-Log "Post-Op cleanup complete: $(Get-Date -Format 'HH:mm:ss')"
    }

    Generate-Report -WorkflowResult $workflow | Out-Null
} catch {
    Write-Error "PostOp workflow failed: $($_.Exception.Message)"
    exit 1
}
