#Requires -Version 5.1
<#
.SYNOPSIS
    Hijack/scam audit checks for System Health Check dispatch.
#>

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $MyInvocation.MyCommand.Path }
$HelpersScript = Join-Path $ScriptDir 'HijackRepairHelpers.ps1'
if (Test-Path $HelpersScript) { . $HelpersScript }

function Add-HijackHealthStep {
    param(
        $WorkflowResult,
        [string]$Name,
        [string]$CheckId,
        [string]$FindingIdPrefix,
        [string]$FindingTitle,
        [string]$Impact,
        $AuditResult,
        [string[]]$Recommendations,
        [object[]]$Actions
    )

    $issues = @()
    if ($AuditResult.PSObject.Properties.Name -contains 'Issues') {
        $issues = @($AuditResult.Issues)
    }
    elseif ($AuditResult.PSObject.Properties.Name -contains 'Details') {
        $issues = @($AuditResult.Details)
    }

    $status = [string]$AuditResult.Status
    $findings = Convert-IssueListToHealthFindings `
        -CheckId $CheckId `
        -FindingIdPrefix $FindingIdPrefix `
        -FindingTitle $FindingTitle `
        -Impact $Impact `
        -Severity $(if ($status -eq 'Fail') { 'High' } else { 'Medium' }) `
        -Status $(if ($status -in @('Fail', 'Warn')) { $status } else { 'Pass' }) `
        -Issues $issues `
        -Recommendations $Recommendations `
        -Actions $Actions `
        -PassFinding ("No {0} issues detected" -f $FindingTitle.ToLowerInvariant())

    $step = @{
        Name    = $Name
        Status  = $status
        Output  = [string]$AuditResult.Output
        CheckId = $CheckId
    }
    Add-HealthFindingsToStep -Step $step -Findings $findings -SummaryText ([string]$AuditResult.Output)
    $WorkflowResult.Steps.Add([PSCustomObject]$step)
}

function Invoke-BrowserHijackCheck {
    param($r)
    Write-Log 'Auditing browser homepage, search, and policy hijacks...'
    try {
        $result = Invoke-HijackBrowserAudit
        Write-Log $result.Output
        Add-HijackHealthStep -WorkflowResult $r -Name 'BrowserHijackAudit' -CheckId 'sec_browser_hijack' `
            -FindingIdPrefix 'hijack.browser' -FindingTitle 'Browser hijack indicator' `
            -Impact 'Homepage, search, startup URLs, or browser policies may redirect the user.' `
            -AuditResult $result `
            -Recommendations @('Open Hijack & Scam Repair to reset browser policies and preferences.') `
            -Actions @(@{ type = 'cde'; target = 'HijackRepair'; label = 'Hijack & Scam Repair' })
    } catch {
        $r.Steps.Add([PSCustomObject]@{
            Name   = 'BrowserHijackAudit'
            Status = 'Warn'
            Output = $_.Exception.Message
            CheckId = 'sec_browser_hijack'
        })
    }
}

function Invoke-NetworkHijackCheck {
    param($r)
    Write-Log 'Auditing DNS, proxy, and NRPT hijacks...'
    try {
        $result = Invoke-HijackNetworkAudit
        Write-Log $result.Output
        Add-HijackHealthStep -WorkflowResult $r -Name 'NetworkHijackAudit' -CheckId 'sec_network_hijack' `
            -FindingIdPrefix 'hijack.network' -FindingTitle 'Network hijack indicator' `
            -Impact 'Proxy, PAC, DNS, or NRPT settings may redirect or intercept traffic.' `
            -AuditResult $result `
            -Recommendations @('Repair network hijack settings and verify DNS resolves to expected servers.') `
            -Actions @(
                @{ type = 'cde'; target = 'HijackRepair'; label = 'Hijack & Scam Repair' }
                @{ type = 'cde'; target = 'PostOp'; label = 'Post-Op Cleanup' }
            )
    } catch {
        $r.Steps.Add([PSCustomObject]@{
            Name   = 'NetworkHijackAudit'
            Status = 'Warn'
            Output = $_.Exception.Message
            CheckId = 'sec_network_hijack'
        })
    }
}

function Invoke-SecurityTamperingCheck {
    param($r)
    Write-Log 'Auditing Defender, firewall, UAC, and SmartScreen tampering...'
    try {
        $result = Invoke-HijackSecurityTamperingAudit
        Write-Log $result.Output
        Add-HijackHealthStep -WorkflowResult $r -Name 'SecurityTamperingAudit' -CheckId 'sec_security_tampering' `
            -FindingIdPrefix 'hijack.security' -FindingTitle 'Security tampering indicator' `
            -Impact 'Defender, firewall, UAC, or SmartScreen may be disabled or weakened.' `
            -AuditResult $result `
            -Recommendations @('Restore security settings via Hijack Repair and Fast Fixes.') `
            -Actions @(
                @{ type = 'cde'; target = 'HijackRepair'; label = 'Hijack & Scam Repair' }
                @{ type = 'cde'; target = 'FastFixes'; label = 'Fast Fixes (Enable Defender)' }
            )
    } catch {
        $r.Steps.Add([PSCustomObject]@{
            Name   = 'SecurityTamperingAudit'
            Status = 'Warn'
            Output = $_.Exception.Message
            CheckId = 'sec_security_tampering'
        })
    }
}

function Invoke-RemoteAccessCheck {
    param($r)
    Write-Log 'Inventorying remote-access tools and RDP exposure...'
    try {
        $result = Invoke-HijackRemoteAccessAudit
        Write-Log $result.Output
        Add-HijackHealthStep -WorkflowResult $r -Name 'RemoteAccessAudit' -CheckId 'sec_remote_access' `
            -FindingIdPrefix 'hijack.remote' -FindingTitle 'Remote access exposure' `
            -Impact 'Remote support tools or RDP exposure can be abused by scammers.' `
            -AuditResult $result `
            -Recommendations @('Remove unexpected remote tools and review RDP exposure.') `
            -Actions @(
                @{ type = 'cde'; target = 'UninstallManager'; label = 'Uninstall Manager' }
                @{ type = 'cde'; target = 'StartupManager'; label = 'Startup Manager' }
            )
    } catch {
        $r.Steps.Add([PSCustomObject]@{
            Name   = 'RemoteAccessAudit'
            Status = 'Warn'
            Output = $_.Exception.Message
            CheckId = 'sec_remote_access'
        })
    }
}

function Get-HijackRepairCheckDispatchMap {
    return @{
        sec_browser_hijack     = { param($r) Invoke-BrowserHijackCheck $r }
        sec_network_hijack     = { param($r) Invoke-NetworkHijackCheck $r }
        sec_security_tampering = { param($r) Invoke-SecurityTamperingCheck $r }
        sec_remote_access      = { param($r) Invoke-RemoteAccessCheck $r }
    }
}
