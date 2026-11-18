#Requires -Version 5.1
<#
.SYNOPSIS
    PostOp.ps1 - Post-operation cleanup tools dispatcher.
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
    $cacheSubdirs = @('Cache', 'Code Cache', 'GPUCache')

    $userRoots = [System.Collections.Generic.List[object]]::new()
    $userRoots.Add([PSCustomObject]@{
        LocalAppData = $env:LOCALAPPDATA
        AppData      = $env:APPDATA
    }) | Out-Null

    $isElevated = $false
    if (Get-Command Test-ToolkitIsElevated -ErrorAction SilentlyContinue) {
        $isElevated = Test-ToolkitIsElevated
    }
    if ($isElevated -and (Test-Path -LiteralPath 'C:\Users')) {
        $skipUsers = @('Public', 'Default', 'Default User', 'All Users')
        foreach ($dir in (Get-ChildItem -LiteralPath 'C:\Users' -Directory -ErrorAction SilentlyContinue)) {
            if ($dir.Name -in $skipUsers) { continue }
            $userRoots.Add([PSCustomObject]@{
                LocalAppData = Join-Path $dir.FullName 'AppData\Local'
                AppData      = Join-Path $dir.FullName 'AppData\Roaming'
            }) | Out-Null
        }
    }

    $seenPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($rootSet in $userRoots) {
        $chromiumBases = @(
            @{ Label = 'Edge';   Root = (Join-Path $rootSet.LocalAppData 'Microsoft\Edge\User Data') },
            @{ Label = 'Chrome'; Root = (Join-Path $rootSet.LocalAppData 'Google\Chrome\User Data') }
        )

        foreach ($browser in $chromiumBases) {
            if (-not (Test-Path -LiteralPath $browser.Root)) { continue }
            Get-ChildItem -LiteralPath $browser.Root -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notin $skipProfileNames } |
                ForEach-Object {
                    foreach ($sub in $cacheSubdirs) {
                        $path = Join-Path $_.FullName $sub
                        if ((Test-Path -LiteralPath $path) -and $seenPaths.Add($path)) {
                            $targets.Add([PSCustomObject]@{ Label = $browser.Label; Profile = $_.Name; Path = $path }) | Out-Null
                        }
                    }
                }
        }

        $firefoxProfiles = Join-Path $rootSet.AppData 'Mozilla\Firefox\Profiles'
        if (Test-Path -LiteralPath $firefoxProfiles) {
            Get-ChildItem -LiteralPath $firefoxProfiles -Directory -ErrorAction SilentlyContinue |
                ForEach-Object {
                    foreach ($sub in @('cache2', 'startupCache', 'thumbnails')) {
                        $path = Join-Path $_.FullName $sub
                        if ((Test-Path -LiteralPath $path) -and $seenPaths.Add($path)) {
                            $targets.Add([PSCustomObject]@{ Label = 'Firefox'; Profile = $_.Name; Path = $path }) | Out-Null
                        }
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
    ) | Select-Object -Unique | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_) }

    $totalDeleted = 0
    $totalLocked  = 0
    $totalBytes   = [long]0

    foreach ($path in $paths) {
        Write-Log "  Cleaning: $path"
        try {
            $beforeFiles = @(Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue)
            $beforeBytes = [long](($beforeFiles | Measure-Object Length -Sum -ErrorAction SilentlyContinue).Sum)

            Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

            $afterFiles = @(Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue)
            $afterBytes = [long](($afterFiles | Measure-Object Length -Sum -ErrorAction SilentlyContinue).Sum)

            $freedBytes = [math]::Max([long]0, $beforeBytes - $afterBytes)
            $deletedCount = [math]::Max(0, $beforeFiles.Count - $afterFiles.Count)
            $lockedCount = $afterFiles.Count

            $totalBytes   += $freedBytes
            $totalDeleted += $deletedCount
            $totalLocked  += $lockedCount
            Write-Log "  Removed $deletedCount file(s) ($(Format-SizeHuman -Bytes $freedBytes)); $lockedCount locked/remaining"
        } catch {
            $totalLocked++
            Write-Log "  [WARN] $path - $_"
        }
    }

    Write-Log "Total freed: ~$(Format-SizeHuman -Bytes $totalBytes)"
    $status = Get-ToolkitWorkflowStepStatus -Succeeded $totalDeleted -Skipped $totalLocked
    Add-ToolkitWorkflowStep -WorkflowResult $r -Name 'TempCleanup' -Status $status `
        -Output "Removed $totalDeleted file(s) (~$(Format-SizeHuman -Bytes $totalBytes)), $totalLocked locked/remaining"
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
            $beforeFiles = @(Get-ChildItem -LiteralPath $target.Path -Recurse -File -Force -ErrorAction SilentlyContinue)
            $beforeBytes = [long](($beforeFiles | Measure-Object Length -Sum -ErrorAction SilentlyContinue).Sum)

            Get-ChildItem -LiteralPath $target.Path -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

            $afterFiles = @(Get-ChildItem -LiteralPath $target.Path -Recurse -File -Force -ErrorAction SilentlyContinue)
            $afterBytes = [long](($afterFiles | Measure-Object Length -Sum -ErrorAction SilentlyContinue).Sum)

            $freedBytes = [math]::Max([long]0, $beforeBytes - $afterBytes)
            $freedText = Format-SizeHuman -Bytes $freedBytes
            if ($beforeFiles.Count -gt 0 -and $afterFiles.Count -eq $beforeFiles.Count -and $freedBytes -eq 0) {
                $skipped++
                Write-Log "  $($target.Label) [$($target.Profile)]\$([IO.Path]::GetFileName($target.Path)): locked ($($afterFiles.Count) file(s))"
                $results += "$($target.Label)/$($target.Profile): locked"
            } else {
                $cleared++
                Write-Log "  $($target.Label) [$($target.Profile)]\$([IO.Path]::GetFileName($target.Path)): ~$freedText ($($afterFiles.Count) remaining)"
                $results += "$($target.Label)/$($target.Profile): ~$freedText"
            }
        } catch {
            $skipped++
            Write-Log "  $($target.Label) [$($target.Profile)]: skipped - $_"
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
    $alreadyOk = 0
    $protectedSkipped = 0
    $skipped = 0

    foreach ($svc in $defaults.GetEnumerator()) {
        try {
            $serviceObj = Get-Service -Name $svc.Key -ErrorAction Stop
            if ($serviceObj.StartType.ToString() -eq $svc.Value) {
                Write-Log "  $($svc.Key): already $($svc.Value)"
                $alreadyOk++
                continue
            }

            Set-Service -Name $svc.Key -StartupType $svc.Value -ErrorAction Stop
            Write-Log "  $($svc.Key): set to $($svc.Value)"
            $fixed++
        } catch {
            $errMsg = $_.Exception.Message
            if ($_.CategoryInfo.Category -eq 'PermissionDenied' -or $errMsg -match 'Access is denied|protected') {
                $protectedSkipped++
                Write-Log "  $($svc.Key): protected by Windows (skipped) - $errMsg"
            } else {
                $skipped++
                Write-Log "  $($svc.Key): skipped - $errMsg"
            }
        }
    }

    $okTotal = $fixed + $alreadyOk
    Write-Log "Services adjusted: $fixed | Already default: $alreadyOk | Protected: $protectedSkipped | Skipped: $skipped"
    $status = Get-ToolkitWorkflowStepStatus -Succeeded $okTotal -Skipped $skipped -RequireSuccess
    $output = if ($okTotal -eq 0) {
        "$fixed service(s) restored, $skipped skipped. Run CDE as Administrator."
    } else {
        "$fixed service(s) restored, $alreadyOk already default, $protectedSkipped protected, $skipped skipped"
    }
    Add-ToolkitWorkflowStep -WorkflowResult $r -Name 'RestoreDefaultServices' -Status $status -Output $output
}

function Invoke-CmdAssoc {
    param([string]$CommandLine)
    $output = & cmd.exe /c $CommandLine 2>&1
    $text = (($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
    return [PSCustomObject]@{
        ExitCode = $LASTEXITCODE
        Output   = $text
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
        "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes\$Extension"
    )
    foreach ($path in $targets) {
        try {
            if (-not (Test-Path -LiteralPath $path)) {
                New-Item -LiteralPath $path -Force | Out-Null
            }
            Set-ItemProperty -LiteralPath $path -Name '(default)' -Value $ProgId -ErrorAction Stop
            $fixed++
        } catch {
            Write-Log "  [WARN] $path - $_"
        }
    }

    # Only repair HKCU\Software\Classes\<ext> if it already exists and was hijacked; avoid creating new HKCU keys.
    $hkcuPath = "Registry::HKEY_CURRENT_USER\Software\Classes\$Extension"
    if (Test-Path -LiteralPath $hkcuPath) {
        try {
            $hkcuVal = (Get-ItemProperty -LiteralPath $hkcuPath -Name '(default)' -ErrorAction SilentlyContinue).'(default)'
            if ($hkcuVal -and $hkcuVal -ne $ProgId) {
                Set-ItemProperty -LiteralPath $hkcuPath -Name '(default)' -Value $ProgId -ErrorAction Stop
                $fixed++
            }
        } catch {
            Write-Log "  [WARN] $hkcuPath - $_"
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
    if ($FileType -eq 'lnkfile') {
        # lnkfile uses Explorer shell handlers, not shell\open\command; remove any hijacked command key.
        if (Test-Path -LiteralPath $commandPath) {
            try {
                Remove-Item -LiteralPath $commandPath -Recurse -Force -ErrorAction Stop
                return $true
            } catch {
                Write-Log "  [WARN] $commandPath - $_"
                return $false
            }
        }
        return $true
    }

    try {
        if (-not (Test-Path -LiteralPath $commandPath)) {
            New-Item -LiteralPath $commandPath -Force | Out-Null
        }
        Set-ItemProperty -LiteralPath $commandPath -Name '(default)' -Value $Command -ErrorAction Stop
        return $true
    } catch {
        Write-Log "  [WARN] $commandPath - $_"
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

        if ($item.FileType -ne 'lnkfile') {
            $ftypeCmd = "ftype $($item.FileType)=`"%1`" %*"
            $ftypeResult = Invoke-CmdAssoc -CommandLine $ftypeCmd
            Write-Log "  ftype $($item.FileType): $($ftypeResult.Output)"
            if ($ftypeResult.ExitCode -eq 0) { $repairs++ }
        }

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
    if (-not [string]::IsNullOrWhiteSpace($result.Output)) {
        $level = switch ([string]$result.Status) {
            'Fail' { 'Error' }
            'Warn' { 'Warning' }
            default { 'Info' }
        }
        Write-Log "  $($result.Output)" -Level $level
    }
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

# --- Dispatch ---------------------------------------------------------------
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
    if ($workflow.Status -eq 'Failed' -or @($workflow.Steps | Where-Object { $_.Status -eq 'Fail' }).Count -gt 0) {
        exit 1
    }
} catch {
    Write-Error "PostOp workflow failed: $($_.Exception.Message)"
    exit 1
}
