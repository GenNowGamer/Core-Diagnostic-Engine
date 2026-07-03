#Requires -Version 5.1
<#
.SYNOPSIS
    Hijack/scam audit checks for System Health Check dispatch.
#>

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $MyInvocation.MyCommand.Path }
$HelpersScript = Join-Path $ScriptDir 'HijackRepairHelpers.ps1'
if (Test-Path $HelpersScript) { . $HelpersScript }

function Invoke-BrowserHijackCheck {
    param($r)
    Write-Log 'Auditing browser homepage, search, and policy hijacks...'
    try {
        $result = Invoke-HijackBrowserAudit
        Write-Log $result.Output
        $r.Steps.Add([PSCustomObject]@{
            Name   = 'BrowserHijackAudit'
            Status = $result.Status
            Output = $result.Output
        })
    } catch {
        $r.Steps.Add([PSCustomObject]@{
            Name   = 'BrowserHijackAudit'
            Status = 'Warn'
            Output = $_.Exception.Message
        })
    }
}

function Invoke-NetworkHijackCheck {
    param($r)
    Write-Log 'Auditing DNS, proxy, and NRPT hijacks...'
    try {
        $result = Invoke-HijackNetworkAudit
        Write-Log $result.Output
        $r.Steps.Add([PSCustomObject]@{
            Name   = 'NetworkHijackAudit'
            Status = $result.Status
            Output = $result.Output
        })
    } catch {
        $r.Steps.Add([PSCustomObject]@{
            Name   = 'NetworkHijackAudit'
            Status = 'Warn'
            Output = $_.Exception.Message
        })
    }
}

function Invoke-SecurityTamperingCheck {
    param($r)
    Write-Log 'Auditing Defender, firewall, UAC, and SmartScreen tampering...'
    try {
        $result = Invoke-HijackSecurityTamperingAudit
        Write-Log $result.Output
        $r.Steps.Add([PSCustomObject]@{
            Name   = 'SecurityTamperingAudit'
            Status = $result.Status
            Output = $result.Output
        })
    } catch {
        $r.Steps.Add([PSCustomObject]@{
            Name   = 'SecurityTamperingAudit'
            Status = 'Warn'
            Output = $_.Exception.Message
        })
    }
}

function Invoke-RemoteAccessCheck {
    param($r)
    Write-Log 'Inventorying remote-access tools and RDP exposure...'
    try {
        $result = Invoke-HijackRemoteAccessAudit
        Write-Log $result.Output
        $r.Steps.Add([PSCustomObject]@{
            Name   = 'RemoteAccessAudit'
            Status = $result.Status
            Output = $result.Output
        })
    } catch {
        $r.Steps.Add([PSCustomObject]@{
            Name   = 'RemoteAccessAudit'
            Status = 'Warn'
            Output = $_.Exception.Message
        })
    }
}

function Get-HijackRepairCheckDispatchMap {
    return @{
        sec_browser_hijack      = { param($r) Invoke-BrowserHijackCheck $r }
        sec_network_hijack      = { param($r) Invoke-NetworkHijackCheck $r }
        sec_security_tampering  = { param($r) Invoke-SecurityTamperingCheck $r }
        sec_remote_access       = { param($r) Invoke-RemoteAccessCheck $r }
    }
}
