#Requires -Version 5.1
<#
.SYNOPSIS
    Structured hijack findings model, scan emission, and per-finding repair for the Hijack Scanner UI.
#>

function Get-HijackFindingId {
    param([Parameter(Mandatory)][string]$Seed)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Seed)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
        return ([BitConverter]::ToString($hash)).Replace('-', '').Substring(0, 16).ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-HijackCanonicalRepairDataJson {
    param($RepairData)

    if ($null -eq $RepairData) { return '{}' }

    $obj = [ordered]@{}
    if ($RepairData -is [hashtable]) {
        foreach ($key in ($RepairData.Keys | Sort-Object)) {
            $obj[$key] = $RepairData[$key]
        }
    } elseif ($RepairData -is [System.Collections.IDictionary]) {
        foreach ($key in ($RepairData.Keys | Sort-Object)) {
            $obj[$key] = $RepairData[$key]
        }
    } else {
        foreach ($prop in @($RepairData.PSObject.Properties | Sort-Object Name)) {
            $obj[$prop.Name] = $prop.Value
        }
    }

    if ($obj.Count -eq 0) { return '{}' }
    return ($obj | ConvertTo-Json -Compress)
}

function Get-HijackFindingIdSeed {
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Name,
        [string]$Location = '',
        [string]$RepairAction = '',
        $RepairData = @{}
    )

    if (-not [string]::IsNullOrWhiteSpace($RepairAction)) {
        $dataJson = Get-HijackCanonicalRepairDataJson -RepairData $RepairData
        return "$Category|$RepairAction|$Name|$Location|$dataJson"
    }

    return "$Category|$Name|$Location"
}

function Get-HijackScansRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:TOOLKIT_ROOT)) {
        $toolkitRoot = $env:TOOLKIT_ROOT
    } else {
        $toolkitRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    }

    $root = Join-Path $toolkitRoot 'CDE\Runtime\Data\scans'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
    }
    return $root
}

function Get-HijackScanSnapshotPath {
    param([string]$SnapshotPath = '')

    if (-not [string]::IsNullOrWhiteSpace($SnapshotPath)) {
        return $SnapshotPath.Trim()
    }

    $root = Get-HijackScansRoot
    $caseId = ''
    if (Get-Command Get-ActiveWorkOrderPointer -ErrorAction SilentlyContinue) {
        $pointer = Get-ActiveWorkOrderPointer
        if ($pointer -and $pointer.CaseId) {
            $caseId = [string]$pointer.CaseId
        }
    }

    if ([string]::IsNullOrWhiteSpace($caseId)) {
        return Join-Path $root 'hijack_latest.json'
    }

    foreach ($c in [System.IO.Path]::GetInvalidFileNameChars()) {
        $caseId = $caseId.Replace([string]$c, '_')
    }
    return Join-Path $root "hijack_${caseId}_latest.json"
}

function ConvertTo-HijackFindingRecord {
    param($Raw)

    if ($null -eq $Raw) { return $null }

    $repairData = [ordered]@{}
    if ($null -ne $Raw.repairData) {
        if ($Raw.repairData -is [hashtable]) {
            foreach ($key in ($Raw.repairData.Keys | Sort-Object)) {
                $repairData[$key] = $Raw.repairData[$key]
            }
        } elseif ($Raw.repairData -is [System.Collections.IDictionary]) {
            foreach ($key in ($Raw.repairData.Keys | Sort-Object)) {
                $repairData[$key] = $Raw.repairData[$key]
            }
        } else {
            foreach ($prop in @($Raw.repairData.PSObject.Properties | Sort-Object Name)) {
                $repairData[$prop.Name] = $prop.Value
            }
        }
    }

    return [PSCustomObject]@{
        id               = [string]$Raw.id
        category         = [string]$Raw.category
        name             = [string]$Raw.name
        location         = [string]$Raw.location
        currentValue     = [string]$Raw.currentValue
        severity         = [string]$Raw.severity
        isFlagged        = [bool]$Raw.isFlagged
        repairable       = [bool]$Raw.repairable
        repairAction     = [string]$Raw.repairAction
        repairData       = $repairData
        guidance         = [string]$Raw.guidance
        startupEntryName = [string]$Raw.startupEntryName
    }
}

function Save-HijackScanSnapshot {
    param(
        [Parameter(Mandatory)][object[]]$Findings,
        [string]$SnapshotPath = ''
    )

    $path = Get-HijackScanSnapshotPath -SnapshotPath $SnapshotPath
    $parent = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $exportFindings = foreach ($finding in @($Findings)) {
        $dataJson = Get-HijackCanonicalRepairDataJson -RepairData $finding.repairData
        [ordered]@{
            id               = [string]$finding.id
            category         = [string]$finding.category
            name             = [string]$finding.name
            location         = [string]$finding.location
            currentValue     = [string]$finding.currentValue
            severity         = [string]$finding.severity
            isFlagged        = [bool]$finding.isFlagged
            repairable       = [bool]$finding.repairable
            repairAction     = [string]$finding.repairAction
            repairData       = if ($dataJson -eq '{}') { @{} } else { $finding.repairData }
            guidance         = [string]$finding.guidance
            startupEntryName = [string]$finding.startupEntryName
        }
    }

    $payload = [ordered]@{
        schemaVersion = 1
        scannedAt     = (Get-Date).ToString('o')
        machineName   = $env:COMPUTERNAME
        userName      = $env:USERNAME
        findings      = @($exportFindings)
    }

    ($payload | ConvertTo-Json -Depth 8 -Compress) | Set-Content -LiteralPath $path -Encoding UTF8 -Force
    return $path
}

function Get-HijackScanSnapshotFindings {
    param([string]$SnapshotPath = '')

    $path = Get-HijackScanSnapshotPath -SnapshotPath $SnapshotPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return @()
    }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $raw -or $null -eq $raw.findings) { return @() }
        return @($raw.findings | ForEach-Object { ConvertTo-HijackFindingRecord -Raw $_ })
    } catch {
        return @()
    }
}

function New-HijackFinding {
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Name,
        [string]$Location = '',
        [string]$CurrentValue = '',
        [ValidateSet('Hijacked', 'Suspicious', 'Info')]
        [string]$Severity = 'Hijacked',
        [bool]$IsFlagged = $true,
        [bool]$Repairable = $true,
        [string]$RepairAction = '',
        [hashtable]$RepairData = @{},
        [string]$Guidance = '',
        [string]$StartupEntryName = ''
    )

    $repairDataObj = [ordered]@{}
    foreach ($key in ($RepairData.Keys | Sort-Object)) {
        $repairDataObj[$key] = $RepairData[$key]
    }

    $idSeed = Get-HijackFindingIdSeed -Category $Category -Name $Name -Location $Location `
        -RepairAction $RepairAction -RepairData $repairDataObj

    return [PSCustomObject]@{
        id           = Get-HijackFindingId -Seed $idSeed
        category     = $Category
        name         = $Name
        location     = $Location
        currentValue = $CurrentValue
        severity     = $Severity
        isFlagged    = $IsFlagged
        repairable        = $Repairable
        repairAction      = $RepairAction
        repairData        = $repairDataObj
        guidance          = $Guidance
        startupEntryName  = $StartupEntryName
    }
}

function Write-HijackTaggedFinding {
    param([Parameter(Mandatory)]$Finding)
    $json = $Finding | ConvertTo-Json -Compress -Depth 6
    Write-Host "[HIJACK:FINDING] $json"
}

function Write-HijackTaggedScanComplete {
    param(
        [int]$Total,
        [int]$Flagged,
        [int]$Repairable,
        [string]$SnapshotPath = ''
    )
    $payload = @{
        total        = $Total
        flagged      = $Flagged
        repairable   = $Repairable
        snapshotPath = $SnapshotPath
    } | ConvertTo-Json -Compress
    Write-Host "[HIJACK:SCAN] $payload"
}

function Get-HijackStructuredBrowserFindings {
    $findings = [System.Collections.Generic.List[object]]::new()
    $envMode = if (Get-Command Get-EnvironmentMode -ErrorAction SilentlyContinue) { Get-EnvironmentMode } else { 'Windows' }
    if ($envMode -ne 'Windows') { return @() }

    $policyPaths = Get-HijackBrowserPolicyPaths
    $watchProps = Get-HijackBrowserPolicyWatchProperties

    foreach ($entry in $policyPaths) {
        if (-not (Test-Path -LiteralPath $entry.Path)) { continue }
        try {
            $props = Get-ItemProperty -LiteralPath $entry.Path -ErrorAction Stop
            foreach ($prop in $props.PSObject.Properties) {
                if ($prop.Name -in @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider')) { continue }
                if ($watchProps -notcontains $prop.Name) { continue }
                $val = [string]$prop.Value
                if (-not (Test-HijackSuspiciousBrowserPolicyValue -PropertyName $prop.Name -Value $val)) { continue }

                $findings.Add((New-HijackFinding `
                    -Category 'Browser' `
                    -Name "$($entry.Browser) policy $($prop.Name)" `
                    -Location $entry.Path `
                    -CurrentValue $val `
                    -Severity 'Hijacked' `
                    -RepairAction 'browser.policy.remove' `
                    -RepairData @{ policyPath = $entry.Path; propertyName = $prop.Name })) | Out-Null
            }
        } catch { }
    }

    foreach ($store in (Get-HijackChromiumProfileRoots)) {
        $profiles = @(Get-ChildItem -LiteralPath $store.Root -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(Default|Profile \d+)$' })
        foreach ($profile in $profiles) {
            $prefsPath = Join-Path $profile.FullName 'Preferences'
            if (-not (Test-Path -LiteralPath $prefsPath)) { continue }

            $hasIssue = $false
            try {
                $json = Get-Content -LiteralPath $prefsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                $hasIssue = Test-HijackChromiumPrefsHijacked -Json $json
            } catch {
                $findings.Add((New-HijackFinding `
                    -Category 'Browser' `
                    -Name "$($store.Browser) preferences unreadable" `
                    -Location $prefsPath `
                    -CurrentValue $_.Exception.Message `
                    -Severity 'Suspicious' `
                    -IsFlagged $true `
                    -Repairable $false `
                    -RepairAction '')) | Out-Null
                continue
            }

            if ($hasIssue) {
                $label = "$($store.Browser) ($($store.User)/$($profile.Name))"
                $findings.Add((New-HijackFinding `
                    -Category 'Browser' `
                    -Name "$label hijacked preferences" `
                    -Location $prefsPath `
                    -CurrentValue 'homepage, startup URLs, or search provider' `
                    -Severity 'Hijacked' `
                    -RepairAction 'browser.chromium.prefs' `
                    -RepairData @{ prefsPath = $prefsPath; label = $label })) | Out-Null
            }
        }
    }

    $users = @(Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue)
    foreach ($user in $users) {
        if ($user.Name -in @('Public', 'Default', 'Default User', 'All Users')) { continue }
        $ffRoot = Join-Path $user.FullName 'AppData\Roaming\Mozilla\Firefox\Profiles'
        if (-not (Test-Path -LiteralPath $ffRoot)) { continue }
        foreach ($profile in @(Get-ChildItem -LiteralPath $ffRoot -Directory -ErrorAction SilentlyContinue)) {
            $prefsPath = Join-Path $profile.FullName 'prefs.js'
            $watchPrefs = @('browser.startup.homepage', 'browser.startup.page', 'browser.search.defaultenginename', 'browser.newtabpage.enabled')
            if (Test-Path -LiteralPath $prefsPath) {
                foreach ($line in (Get-Content -LiteralPath $prefsPath -ErrorAction SilentlyContinue)) {
                    if ($line -notmatch '^user_pref\("([^"]+)",\s*"?([^"]*)"?\);') { continue }
                    $prefName = $matches[1]
                    $prefValue = $matches[2]
                    if ($watchPrefs -notcontains $prefName) { continue }
                    if (-not (Test-HijackFirefoxPrefHijacked -PrefName $prefName -PrefValue $prefValue)) { continue }
                    $findings.Add((New-HijackFinding `
                        -Category 'Browser' `
                        -Name "Firefox $($user.Name)/$($profile.Name) $prefName" `
                        -Location $prefsPath `
                        -CurrentValue $prefValue `
                        -Severity 'Hijacked' `
                        -RepairAction 'browser.firefox.prefs' `
                        -RepairData @{ prefsPath = $prefsPath; label = "Firefox ($($user.Name)/$($profile.Name))" })) | Out-Null
                }
            }

            $userJs = Join-Path $profile.FullName 'user.js'
            if ((Test-Path -LiteralPath $userJs) -and (Test-HijackFirefoxUserJsSuspicious -UserJsPath $userJs)) {
                $findings.Add((New-HijackFinding `
                    -Category 'Browser' `
                    -Name "Firefox $($user.Name)/$($profile.Name) locked prefs (user.js)" `
                    -Location $userJs `
                    -CurrentValue 'user.js present' `
                    -Severity 'Hijacked' `
                    -RepairAction 'browser.firefox.userjs' `
                    -RepairData @{ userJsPath = $userJs })) | Out-Null
            }
        }
    }

    return @($findings)
}

function Get-HijackStructuredExtensionFindings {
    $findings = [System.Collections.Generic.List[object]]::new()
    foreach ($ext in (Get-HijackBrowserExtensionInventory)) {
        if (-not (Test-HijackSuspiciousExtension -ExtensionName ([string]$ext.ExtensionName) `
                -ExtensionId ([string]$ext.ExtensionId) `
                -Description ([string]$ext.ManifestDescription))) {
            continue
        }
        $displayName = if ([string]::IsNullOrWhiteSpace($ext.ExtensionName)) { $ext.ExtensionId } else { $ext.ExtensionName }
        $findings.Add((New-HijackFinding `
            -Category 'Browser' `
            -Name "$($ext.Browser) extension $displayName" `
            -Location ([string]$ext.Location) `
            -CurrentValue "$($ext.User)/$($ext.Profile) [$($ext.ExtensionId)]" `
            -Severity 'Suspicious' `
            -Repairable $false `
            -RepairAction '')) | Out-Null
    }
    return @($findings)
}

function Get-HijackStructuredNetworkFindings {
    $findings = [System.Collections.Generic.List[object]]::new()
    $envMode = if (Get-Command Get-EnvironmentMode -ErrorAction SilentlyContinue) { Get-EnvironmentMode } else { 'Windows' }

    $hostsPath = if (Get-Command Get-ToolkitHostsFilePath -ErrorAction SilentlyContinue) {
        Get-ToolkitHostsFilePath
    } else {
        "$env:SystemRoot\System32\drivers\etc\hosts"
    }

    if ($envMode -ne 'Windows') {
        $custom = @(Get-HijackHostsCustomEntries -HostsPath $hostsPath)
        if ($custom.Count -gt 0) {
            $findings.Add((New-HijackFinding `
                -Category 'Network' `
                -Name 'Hosts file custom entries' `
                -Location $hostsPath `
                -CurrentValue "$($custom.Count) non-default entries" `
                -Severity 'Hijacked' `
                -Repairable $false `
                -RepairAction 'network.hosts.restore' `
                -RepairData @{} `
                -Guidance 'Review only by default. Use Post-Op Cleanup > Restore hosts (confirm), or Repair Selected with an explicit hosts confirmation.')) | Out-Null
        }
        return @($findings)
    }

    $customHosts = @(Get-HijackHostsCustomEntries -HostsPath $hostsPath)
    if ($customHosts.Count -gt 0) {
        $hostsSeverity = if ($customHosts.Count -gt 10) { 'Hijacked' } else { 'Suspicious' }
        $findings.Add((New-HijackFinding `
            -Category 'Network' `
            -Name 'Hosts file custom entries' `
            -Location $hostsPath `
            -CurrentValue "$($customHosts.Count) non-default entries" `
            -Severity $hostsSeverity `
            -Repairable $false `
            -RepairAction 'network.hosts.restore' `
            -RepairData @{} `
            -Guidance 'Review only by default (FIX checkbox disabled). Use Post-Op Cleanup > Restore hosts with confirm, or pass -ConfirmHostsRestore when repairing via script.')) | Out-Null
    }

    $internetSettings = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    if (Test-Path -LiteralPath $internetSettings) {
        try {
            $props = Get-ItemProperty -LiteralPath $internetSettings -ErrorAction Stop
            if ($props.ProxyEnable -eq 1) {
                $proxyServer = [string]$props.ProxyServer
                $proxySuspicious = Test-HijackSuspiciousProxySetting -Url $proxyServer
                $findings.Add((New-HijackFinding `
                    -Category 'Network' `
                    -Name 'User Internet proxy enabled' `
                    -Location $internetSettings `
                    -CurrentValue $proxyServer `
                    -Severity $(if ($proxySuspicious) { 'Hijacked' } else { 'Info' }) `
                    -IsFlagged $(if ($proxySuspicious) { $true } else { $false }) `
                    -RepairAction 'network.proxy.reset' `
                    -RepairData @{})) | Out-Null
            }
            if ($props.AutoConfigURL) {
                $pacUrl = [string]$props.AutoConfigURL
                $pacSuspicious = Test-HijackSuspiciousProxySetting -Url $pacUrl
                $findings.Add((New-HijackFinding `
                    -Category 'Network' `
                    -Name 'PAC / AutoConfigURL' `
                    -Location $internetSettings `
                    -CurrentValue $pacUrl `
                    -Severity $(if ($pacSuspicious) { 'Hijacked' } else { 'Info' }) `
                    -IsFlagged $(if ($pacSuspicious) { $true } else { $false }) `
                    -RepairAction 'network.proxy.reset' `
                    -RepairData @{})) | Out-Null
            }
        } catch { }
    }

    try {
        $adapters = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.ServerAddresses -and $_.ServerAddresses.Count -gt 0 })
        $gatewayMap = Get-HijackAdapterGatewayMap
        foreach ($adapter in $adapters) {
            $gateway = if ($gatewayMap.ContainsKey([int]$adapter.InterfaceIndex)) {
                [string]$gatewayMap[[int]$adapter.InterfaceIndex]
            } else { '' }
            foreach ($server in @($adapter.ServerAddresses)) {
                if (Test-HijackBenignDnsServer -Server ([string]$server) -Gateway $gateway -InterfaceIndex ([int]$adapter.InterfaceIndex)) { continue }
                $findings.Add((New-HijackFinding `
                    -Category 'Network' `
                    -Name "DNS server on $($adapter.InterfaceAlias)" `
                    -Location "InterfaceIndex $($adapter.InterfaceIndex)" `
                    -CurrentValue $server `
                    -Severity 'Hijacked' `
                    -RepairAction 'network.dns.reset' `
                    -RepairData @{ interfaceIndex = [int]$adapter.InterfaceIndex; interfaceAlias = [string]$adapter.InterfaceAlias })) | Out-Null
            }
        }
    } catch { }

    try {
        $nrpt = @(Get-DnsClientNrptRule -ErrorAction Stop)
        foreach ($rule in $nrpt) {
            if (Test-HijackBenignNrptRule -RuleName ([string]$rule.Name)) { continue }
            $findings.Add((New-HijackFinding `
                -Category 'Network' `
                -Name "NRPT rule $($rule.Name)" `
                -Location 'NRPT' `
                -CurrentValue (($rule.NameServers | ForEach-Object { [string]$_ }) -join ', ') `
                -Severity 'Suspicious' `
                -RepairAction 'network.nrpt.remove' `
                -RepairData @{ ruleName = [string]$rule.Name })) | Out-Null
        }
    } catch { }

    return @($findings)
}

function Get-HijackStructuredSecurityFindings {
    $findings = [System.Collections.Generic.List[object]]::new()
    $envMode = if (Get-Command Get-EnvironmentMode -ErrorAction SilentlyContinue) { Get-EnvironmentMode } else { 'Windows' }
    if ($envMode -ne 'Windows') { return @() }

    $thirdPartyAv = Test-HijackThirdPartyAvActive

    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        if (-not $mp.AntivirusEnabled -and -not $thirdPartyAv) {
            $findings.Add((New-HijackFinding `
                -Category 'Security' `
                -Name 'Windows Defender antivirus disabled' `
                -Location 'WinDefend' `
                -CurrentValue 'AV off' `
                -Severity 'Hijacked' `
                -RepairAction 'security.defender.enable' `
                -RepairData @{})) | Out-Null
        }
        if (-not $mp.RealTimeProtectionEnabled) {
            $rtpOnly = ($mp.AntivirusEnabled -or $thirdPartyAv) -and $mp.AMServiceEnabled -ne $false
            if ($thirdPartyAv -and $mp.AntivirusEnabled -eq $false) {
                # Third-party AV registered; Defender RTP off is often expected.
            } else {
            $findings.Add((New-HijackFinding `
                -Category 'Security' `
                -Name 'Defender real-time protection off' `
                -Location 'WinDefend' `
                -CurrentValue 'RTP off' `
                -Severity $(if ($rtpOnly) { 'Suspicious' } else { 'Hijacked' }) `
                -RepairAction 'security.defender.enable' `
                -RepairData @{})) | Out-Null
            }
        }
        if ($mp.IsTamperProtected -eq $false) {
            if ($thirdPartyAv -and $mp.AntivirusEnabled -eq $false) {
                # Third-party AV owns protection; Defender tamper protection off is expected.
            } else {
            $findings.Add((New-HijackFinding `
                -Category 'Security' `
                -Name 'Defender tamper protection off' `
                -Location 'WinDefend' `
                -CurrentValue 'tamper off' `
                -Severity 'Suspicious' `
                -RepairAction 'security.defender.enable' `
                -RepairData @{} `
                -Guidance 'CDE can attempt to re-enable tamper protection. If it remains off after repair, turn it on manually in Windows Security > Virus & threat protection > Manage settings.')) | Out-Null
            }
        }
        if ($mp.AMServiceEnabled -eq $false -and -not $thirdPartyAv) {
            $findings.Add((New-HijackFinding `
                -Category 'Security' `
                -Name 'Defender antimalware service disabled' `
                -Location 'WinDefend' `
                -CurrentValue 'service off' `
                -Severity 'Hijacked' `
                -RepairAction 'security.defender.enable' `
                -RepairData @{})) | Out-Null
        }
    } catch {
        $msg = [string]$_.Exception.Message
        $hr = 0
        try { $hr = [int]$_.Exception.HResult } catch { }
        $defenderUnavailable = $false
        if (Get-Command Test-HijackDefenderUnavailableError -ErrorAction SilentlyContinue) {
            $defenderUnavailable = [bool](Test-HijackDefenderUnavailableError -HResult $hr -Message $msg)
        }
        if (-not ($thirdPartyAv -or $defenderUnavailable)) {
            $findings.Add((New-HijackFinding `
                -Category 'Security' `
                -Name 'Defender status unavailable' `
                -CurrentValue $msg `
                -Severity 'Suspicious' `
                -Repairable $false `
                -RepairAction '')) | Out-Null
        }
    }

    try {
        foreach ($profile in @(Get-NetFirewallProfile -ErrorAction Stop)) {
            if (-not $profile.Enabled) {
                $findings.Add((New-HijackFinding `
                    -Category 'Security' `
                    -Name "Firewall $($profile.Name) disabled" `
                    -Location 'NetFirewallProfile' `
                    -CurrentValue 'disabled' `
                    -Severity 'Hijacked' `
                    -RepairAction 'security.firewall.enable' `
                    -RepairData @{ profileName = [string]$profile.Name })) | Out-Null
            }
        }
    } catch { }

    $uacKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    if (Test-Path -LiteralPath $uacKey) {
        try {
            $uac = Get-ItemProperty -LiteralPath $uacKey -ErrorAction Stop
            if (($null -ne $uac.EnableLUA -and [int]$uac.EnableLUA -eq 0) -or ($null -ne $uac.ConsentPromptBehaviorAdmin -and [int]$uac.ConsentPromptBehaviorAdmin -eq 0)) {
                $findings.Add((New-HijackFinding `
                    -Category 'Security' `
                    -Name 'UAC weakened' `
                    -Location $uacKey `
                    -CurrentValue "EnableLUA=$($uac.EnableLUA); Consent=$($uac.ConsentPromptBehaviorAdmin)" `
                    -Severity 'Hijacked' `
                    -RepairAction 'security.uac.restore' `
                    -RepairData @{})) | Out-Null
            }
        } catch { }
    }

    $smartScreen = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer'
    if (Test-Path -LiteralPath $smartScreen) {
        try {
            $ss = Get-ItemProperty -LiteralPath $smartScreen -ErrorAction Stop
            if ($null -ne $ss.SmartScreenEnabled -and [string]$ss.SmartScreenEnabled -eq 'Off') {
                $findings.Add((New-HijackFinding `
                    -Category 'Security' `
                    -Name 'SmartScreen disabled' `
                    -Location $smartScreen `
                    -CurrentValue 'Off' `
                    -Severity 'Hijacked' `
                    -RepairAction 'security.smartscreen.restore' `
                    -RepairData @{})) | Out-Null
            }
        } catch { }
    }

    return @($findings)
}

function Get-HijackStructuredBrowserLnkFindings {
    $findings = [System.Collections.Generic.List[object]]::new()
    $envMode = if (Get-Command Get-EnvironmentMode -ErrorAction SilentlyContinue) { Get-EnvironmentMode } else { 'Windows' }
    if ($envMode -ne 'Windows') { return @() }

    foreach ($item in (Get-HijackBrowserShortcutInventory)) {
        if (-not (Test-HijackBrowserShortcutHijacked -BrowserLabel $item.BrowserLabel `
                -TargetPath $item.TargetPath -Arguments $item.Arguments `
                -PathFragment $item.PathFragment -AppPathExe $item.AppPathExe)) {
            continue
        }

        $displayTarget = if ([string]::IsNullOrWhiteSpace($item.TargetPath)) { '(unresolved)' } else { $item.TargetPath }
        if ($item.Arguments) { $displayTarget = "$displayTarget $($item.Arguments)".Trim() }

        $findings.Add((New-HijackFinding `
            -Category 'Browser' `
            -Name "$($item.BrowserLabel) shortcut hijacked" `
            -Location $item.ShortcutPath `
            -CurrentValue $displayTarget `
            -Severity 'Hijacked' `
            -RepairAction 'browser.lnk.reset' `
            -RepairData @{
                shortcutPath = [string]$item.ShortcutPath
                browserLabel = [string]$item.BrowserLabel
            })) | Out-Null
    }

    return @($findings)
}

function Get-HijackStructuredStartupFindings {
    $findings = [System.Collections.Generic.List[object]]::new()
    $envMode = if (Get-Command Get-EnvironmentMode -ErrorAction SilentlyContinue) { Get-EnvironmentMode } else { 'Windows' }
    if ($envMode -ne 'Windows') { return @() }
    if (-not (Import-HijackStartupRiskModule)) { return @() }

    foreach ($entry in @(Get-PostOpStartupEntries)) {
        $isDeviated = $false
        $deviationReason = ''
        if ($entry.PSObject.Properties['IsDeviated']) { $isDeviated = [bool]$entry.IsDeviated }
        if ($entry.PSObject.Properties['DeviationReason']) { $deviationReason = [string]$entry.DeviationReason }

        $susp = Test-PostOpStartupSuspicious `
            -Name ([string]$entry.Name) `
            -SourceGroup ([string]$entry.SourceGroup) `
            -ResolvedPath ([string]$entry.ResolvedPath) `
            -Publisher ([string]$entry.Publisher) `
            -IsSigned ([bool]$entry.IsSigned) `
            -RiskBand ([string]$entry.RiskBand) `
            -IsRunOnce ([bool]$entry.IsRunOnce) `
            -TargetExists ([bool]$entry.TargetExists) `
            -EntryType ([string]$entry.EntryType) `
            -IsWinlogonDeviated $isDeviated `
            -WinlogonDeviationReason $deviationReason

        if (-not $susp.IsSuspicious) { continue }

        $severity = if ($entry.EntryType -eq 'Winlogon' -and $isDeviated) { 'Hijacked' }
                    elseif ([string]$entry.RiskBand -eq 'Warning') { 'Hijacked' }
                    else { 'Suspicious' }

        $repairable = ($entry.EntryType -eq 'Winlogon' -and $isDeviated)
        $repairAction = if ($repairable) { 'startup.winlogon.reset' } else { '' }
        $repairData = if ($repairable) { @{ valueName = [string]$entry.Name } } else { @{} }

        $valueText = [string]$entry.Command
        if ($entry.ResolvedPath -and $entry.ResolvedPath -ne $entry.Command) {
            $valueText = "$($entry.Command) -> $($entry.ResolvedPath)"
        }
        if ($susp.Reasons.Count -gt 0) {
            $valueText = "$valueText [$($susp.Reasons -join '; ')]"
        }

        $guidance = if ($repairable) {
            ''
        } else {
            'Review only - use Startup Manager to disable, delete, or investigate this entry.'
        }

        $findings.Add((New-HijackFinding `
            -Category 'Startup' `
            -Name "$($entry.Name) ($($entry.SourceGroup))" `
            -Location ([string]$entry.SourceGroup) `
            -CurrentValue $valueText `
            -Severity $severity `
            -Repairable $repairable `
            -RepairAction $repairAction `
            -RepairData $repairData `
            -Guidance $guidance `
            -StartupEntryName ([string]$entry.Name))) | Out-Null
    }

    return @($findings)
}

function Get-HijackStructuredRemoteFindings {
    $findings = [System.Collections.Generic.List[object]]::new()
    $envMode = if (Get-Command Get-EnvironmentMode -ErrorAction SilentlyContinue) { Get-EnvironmentMode } else { 'Windows' }
    if ($envMode -ne 'Windows') { return @() }

    foreach ($rat in $Script:KnownRemoteAccessPatterns) {
        $procHits = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $rat.Process })
        if ($procHits.Count -gt 0) {
            $findings.Add((New-HijackFinding `
                -Category 'Remote' `
                -Name "$($rat.Label) running" `
                -Location 'Process' `
                -CurrentValue "$($procHits.Count) process(es)" `
                -Severity 'Suspicious' `
                -IsFlagged $true `
                -Repairable $false `
                -RepairAction '')) | Out-Null
        }

        $svc = Get-Service -Name $rat.Service -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            $findings.Add((New-HijackFinding `
                -Category 'Remote' `
                -Name "$($rat.Label) service running" `
                -Location $svc.Name `
                -CurrentValue 'Running' `
                -Severity 'Suspicious' `
                -Repairable $false `
                -RepairAction '')) | Out-Null
        }

        $uninstallRoots = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        foreach ($root in $uninstallRoots) {
            $apps = @(Get-ItemProperty $root -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -and $_.DisplayName -match [regex]::Escape($rat.Uninstall) })
            foreach ($app in $apps) {
                $findings.Add((New-HijackFinding `
                    -Category 'Remote' `
                    -Name "$($rat.Label) installed" `
                    -Location 'Uninstall' `
                    -CurrentValue ([string]$app.DisplayName) `
                    -Severity 'Info' `
                    -IsFlagged $true `
                    -Repairable $false `
                    -RepairAction '')) | Out-Null
            }
        }
    }

    try {
        $rdp = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -ErrorAction SilentlyContinue
        if ($rdp -and [int]$rdp.fDenyTSConnections -eq 0) {
            $findings.Add((New-HijackFinding `
                -Category 'Remote' `
                -Name 'Remote Desktop allowed' `
                -Location 'Terminal Server' `
                -CurrentValue 'fDenyTSConnections=0' `
                -Severity 'Info' `
                -IsFlagged $false `
                -Repairable $false `
                -RepairAction '')) | Out-Null
        }
    } catch { }

    return @($findings)
}

function Get-HijackStructuredFindings {
    $all = [System.Collections.Generic.List[object]]::new()
    foreach ($f in (Get-HijackStructuredBrowserFindings)) { $all.Add($f) | Out-Null }
    foreach ($f in (Get-HijackStructuredBrowserLnkFindings)) { $all.Add($f) | Out-Null }
    foreach ($f in (Get-HijackStructuredExtensionFindings)) { $all.Add($f) | Out-Null }
    foreach ($f in (Get-HijackStructuredNetworkFindings)) { $all.Add($f) | Out-Null }
    foreach ($f in (Get-HijackStructuredSecurityFindings)) { $all.Add($f) | Out-Null }
    foreach ($f in (Get-HijackStructuredStartupFindings)) { $all.Add($f) | Out-Null }
    foreach ($f in (Get-HijackStructuredRemoteFindings)) { $all.Add($f) | Out-Null }
    return @($all)
}

function Invoke-HijackSingleFindingRepair {
    param([Parameter(Mandatory)]$Finding)

    $action = [string]$Finding.repairAction
    $data = $Finding.repairData
    $details = [System.Collections.Generic.List[string]]::new()

    switch ($action) {
        'browser.policy.remove' {
            $path = [string]$data.policyPath
            $prop = [string]$data.propertyName
            try {
                $current = Get-ItemProperty -LiteralPath $path -Name $prop -ErrorAction Stop
                $backupFile = Backup-HijackRegistryProperty -PolicyPath $path -PropertyName $prop -Value $current.$prop
                Remove-ItemProperty -LiteralPath $path -Name $prop -ErrorAction Stop
                $details.Add("Removed $path\$prop") | Out-Null
                if ($backupFile) { $details.Add("Policy backup: $backupFile") | Out-Null }
                return @{ Status = 'Pass'; Details = @($details) }
            } catch {
                return @{ Status = 'Warn'; Details = @("Failed $path\$prop : $($_.Exception.Message)") }
            }
        }
        'browser.chromium.prefs' {
            $work = Repair-HijackChromiumPreferences -PrefsPath ([string]$data.prefsPath) -Label ([string]$data.label) -OnlyIfHijacked
            return @{ Status = if ($work.Changed) { 'Pass' } else { 'Warn' }; Details = $work.Details }
        }
        'browser.firefox.prefs' {
            $work = Repair-HijackFirefoxPrefs -PrefsPath ([string]$data.prefsPath) -Label ([string]$data.label)
            return @{ Status = if ($work.Changed) { 'Pass' } else { 'Warn' }; Details = $work.Details }
        }
        'browser.firefox.userjs' {
            $userJs = [string]$data.userJsPath
            $bak = "$userJs.hijackbak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
            try {
                Move-Item -LiteralPath $userJs -Destination $bak -Force -ErrorAction Stop
                $details.Add("Moved $userJs to $bak") | Out-Null
                return @{ Status = 'Pass'; Details = @($details) }
            } catch {
                return @{ Status = 'Warn'; Details = @($_.Exception.Message) }
            }
        }
        'browser.lnk.reset' {
            $work = Repair-HijackBrowserShortcut -ShortcutPath ([string]$data.shortcutPath) -BrowserLabel ([string]$data.browserLabel)
            return @{ Status = if ($work.Changed) { 'Pass' } else { 'Warn' }; Details = $work.Details }
        }
        'network.hosts.restore' {
            if (Get-Command Invoke-PostOpHostsFileRestore -ErrorAction SilentlyContinue) {
                $hostsConfirmed = [bool]$script:HijackConfirmHostsRestore
                if (-not $hostsConfirmed) {
                    return @{
                        Status  = 'Warn'
                        Details = @(
                            'Hosts file restore requires explicit confirmation.',
                            'Re-run with -ConfirmHostsRestore (or confirm in the GUI) to replace hosts with Windows defaults (backup created first).'
                        )
                    }
                }
                $r = Invoke-PostOpHostsFileRestore -Confirmed
                return @{ Status = [string]$r.Status; Details = @([string]$r.Output) + @($r.Details) }
            }
            return @{ Status = 'Warn'; Details = @('Hosts restore helper unavailable.') }
        }
        'network.proxy.reset' {
            if (Get-Command Invoke-PostOpProxyReset -ErrorAction SilentlyContinue) {
                $r = Invoke-PostOpProxyReset
                return @{ Status = [string]$r.Status; Details = @([string]$r.Output) + @($r.Details) }
            }
            return @{ Status = 'Warn'; Details = @('Proxy reset helper unavailable.') }
        }
        'network.dns.reset' {
            $idx = [int]$data.interfaceIndex
            $alias = [string]$data.interfaceAlias
            try {
                Set-DnsClientServerAddress -InterfaceIndex $idx -ResetServerAddresses -ErrorAction Stop
                $details.Add("Reset DNS on $alias") | Out-Null
                Start-Sleep -Milliseconds 400
                $gateway = Get-HijackGatewayForInterface -InterfaceIndex $idx
                $after = Get-DnsClientServerAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue
                $stillBad = @(
                    @($after.ServerAddresses) |
                        Where-Object { -not (Test-HijackBenignDnsServer -Server ([string]$_) -Gateway $gateway -InterfaceIndex $idx) }
                )
                if ($stillBad.Count -gt 0) {
                    $details.Add("DNS still lists non-default server(s): $($stillBad -join ', ')") | Out-Null
                    $details.Add('Run CDE as Administrator or check Group Policy / router DNS settings.') | Out-Null
                    return @{ Status = 'Warn'; Details = @($details) }
                }
                if (-not [string]::IsNullOrWhiteSpace($gateway)) {
                    $details.Add("DNS is using DHCP / router gateway ($gateway), which is normal.") | Out-Null
                }
                return @{ Status = 'Pass'; Details = @($details) }
            } catch {
                return @{ Status = 'Warn'; Details = @("DNS reset failed on ${alias}: $($_.Exception.Message)") }
            }
        }
        'network.nrpt.remove' {
            $ruleName = [string]$data.ruleName
            try {
                Remove-DnsClientNrptRule -Name $ruleName -Force -ErrorAction Stop
                $details.Add("Removed NRPT rule $ruleName") | Out-Null
                return @{ Status = 'Pass'; Details = @($details) }
            } catch {
                return @{ Status = 'Warn'; Details = @("NRPT remove failed: $($_.Exception.Message)") }
            }
        }
        'security.defender.enable' {
            $warn = $false
            $details = [System.Collections.Generic.List[string]]::new()

            if (Test-HijackThirdPartyAvActive) {
                return @{
                    Status  = 'Warn'
                    Details = @(
                        'Third-party antivirus is active. Skipping WinDefend Automatic / RTP force-enable to avoid conflicting with the installed AV.',
                        'Review Windows Security / the third-party product before changing Defender settings.'
                    )
                }
            }

            if (Get-Command Test-ToolkitIsElevated -ErrorAction SilentlyContinue) {
                if (-not (Test-ToolkitIsElevated)) {
                    $details.Add('Administrator elevation is required for Defender service changes.') | Out-Null
                    $warn = $true
                }
            }

            try {
                Set-Service -Name 'WinDefend' -StartupType Automatic -ErrorAction Stop
                Start-Service -Name 'WinDefend' -ErrorAction SilentlyContinue
                $details.Add('WinDefend service set to Automatic.') | Out-Null
            } catch {
                $details.Add("WinDefend service: $($_.Exception.Message)") | Out-Null
                $warn = $true
            }

            try {
                Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction SilentlyContinue
                Set-MpPreference -DisableTamperProtection $false -ErrorAction SilentlyContinue
                $details.Add('Defender RTP and tamper protection restore attempted.') | Out-Null
            } catch {
                $details.Add("Defender preferences: $($_.Exception.Message)") | Out-Null
                $warn = $true
            }

            Start-Sleep -Seconds 2
            try {
                $mp = Get-MpComputerStatus -ErrorAction Stop
                if ($mp.RealTimeProtectionEnabled -eq $false) {
                    $details.Add('Real-time protection is still off.') | Out-Null
                    $warn = $true
                }
                if ($mp.IsTamperProtected -eq $false) {
                    $details.Add('Tamper protection is still off.') | Out-Null
                    $details.Add('Enable manually: Windows Security > Virus & threat protection > Manage settings > Tamper protection ON.') | Out-Null
                    $warn = $true
                }
            } catch {
                $details.Add("Defender status check after repair: $($_.Exception.Message)") | Out-Null
                $warn = $true
            }

            return @{ Status = if ($warn) { 'Warn' } else { 'Pass' }; Details = @($details) }
        }
        'security.firewall.enable' {
            $profileName = [string]$data.profileName
            try {
                Set-NetFirewallProfile -Name $profileName -Enabled True -ErrorAction Stop
                $details.Add("Enabled firewall profile $profileName") | Out-Null
                return @{ Status = 'Pass'; Details = @($details) }
            } catch {
                return @{ Status = 'Warn'; Details = @($_.Exception.Message) }
            }
        }
        'security.uac.restore' {
            $uacKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
            try {
                Set-ItemProperty -LiteralPath $uacKey -Name EnableLUA -Value 1 -Type DWord -Force -ErrorAction Stop
                Set-ItemProperty -LiteralPath $uacKey -Name ConsentPromptBehaviorAdmin -Value 5 -Type DWord -Force -ErrorAction Stop
                $details.Add('UAC defaults restored.') | Out-Null
                return @{ Status = 'Pass'; Details = @($details) }
            } catch {
                return @{ Status = 'Warn'; Details = @($_.Exception.Message) }
            }
        }
        'security.smartscreen.restore' {
            $smartScreen = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer'
            try {
                Set-ItemProperty -LiteralPath $smartScreen -Name SmartScreenEnabled -Value 'RequireAdmin' -Force -ErrorAction Stop
                $details.Add('SmartScreen set to RequireAdmin.') | Out-Null
                return @{ Status = 'Pass'; Details = @($details) }
            } catch {
                return @{ Status = 'Warn'; Details = @($_.Exception.Message) }
            }
        }
        'startup.winlogon.reset' {
            $valueName = [string]$data.valueName
            if ($valueName -notin @('Userinit', 'Shell')) {
                return @{ Status = 'Warn'; Details = @("Unsupported Winlogon value: $valueName") }
            }
            $work = Repair-HijackWinlogonValue -ValueName $valueName
            return @{ Status = [string]$work.Status; Details = @($work.Details) }
        }
        default {
            return @{ Status = 'Skip'; Details = @('Finding is not auto-repairable.') }
        }
    }
}

function Invoke-HijackEmitScan {
    param([string]$SnapshotPath = '')

    $findings = @(Get-HijackStructuredFindings)
    $savedSnapshotPath = Save-HijackScanSnapshot -Findings $findings -SnapshotPath $SnapshotPath
    foreach ($finding in $findings) {
        Write-HijackTaggedFinding -Finding $finding
    }
    $flagged = @($findings | Where-Object { $_.isFlagged }).Count
    $repairable = @($findings | Where-Object { $_.repairable }).Count
    Write-HijackTaggedScanComplete -Total $findings.Count -Flagged $flagged -Repairable $repairable -SnapshotPath $savedSnapshotPath
    return $findings
}

function Resolve-HijackRepairFindingsById {
    param(
        [Parameter(Mandatory)][string[]]$FindingIds,
        [string]$SnapshotPath = ''
    )

    $idSet = @{}
    foreach ($id in $FindingIds) {
        if (-not [string]::IsNullOrWhiteSpace($id)) { $idSet[$id.Trim().ToLowerInvariant()] = $true }
    }

    $selected = [System.Collections.Generic.List[object]]::new()
    $seenIds = @{}

    foreach ($finding in @(Get-HijackScanSnapshotFindings -SnapshotPath $SnapshotPath)) {
        $findingId = [string]$finding.id
        if ([string]::IsNullOrWhiteSpace($findingId)) { continue }
        $key = $findingId.ToLowerInvariant()
        if (-not $idSet.ContainsKey($key)) { continue }
        if ($seenIds.ContainsKey($key)) { continue }
        $seenIds[$key] = $true
        $selected.Add($finding) | Out-Null
    }

    $usedSnapshot = $selected.Count -gt 0
    foreach ($finding in @(Get-HijackStructuredFindings)) {
        $findingId = [string]$finding.id
        if ([string]::IsNullOrWhiteSpace($findingId)) { continue }
        $key = $findingId.ToLowerInvariant()
        if (-not $idSet.ContainsKey($key)) { continue }
        if ($seenIds.ContainsKey($key)) { continue }
        $seenIds[$key] = $true
        $selected.Add($finding) | Out-Null
    }

    return [PSCustomObject]@{
        Findings     = @($selected)
        UsedSnapshot = $usedSnapshot
    }
}

function Invoke-HijackRepairSelectedFindings {
    param(
        [Parameter(Mandatory)][string[]]$FindingIds,
        [string]$SnapshotPath = ''
    )

    $resolved = Resolve-HijackRepairFindingsById -FindingIds $FindingIds -SnapshotPath $SnapshotPath
    $selected = @($resolved.Findings)
    if ($selected.Count -eq 0) {
        return [PSCustomObject]@{
            Status  = 'Warn'
            Output  = 'No matching findings in the saved scan snapshot or live inventory. Re-run scan and try again.'
            Details = @()
        }
    }

    $details = [System.Collections.Generic.List[string]]::new()
    if ($resolved.UsedSnapshot) {
        $details.Add('Using saved scan snapshot for repair targets.') | Out-Null
    }

    $warn = $false
    $executed = @{}
    $repairedCount = 0
    $skippedCount = 0

    foreach ($finding in $selected) {
        if (-not $finding.repairable) {
            $skippedCount++
            $details.Add("Skipped (review only): $($finding.name)") | Out-Null
            continue
        }

        $dedupeKey = "$($finding.repairAction)|$(Get-HijackCanonicalRepairDataJson -RepairData $finding.repairData)"
        if ($executed.ContainsKey($dedupeKey)) { continue }
        $executed[$dedupeKey] = $true

        $result = Invoke-HijackSingleFindingRepair -Finding $finding
        $repairedCount++
        $details.Add("[$($finding.name)] status=$($result.Status)") | Out-Null
        foreach ($line in @($result.Details)) {
            if ($line) { $details.Add("  $line") | Out-Null }
        }
        if ($result.Status -ne 'Pass') { $warn = $true }
    }

    if (Get-Command Invoke-PostOpDnsFlush -ErrorAction SilentlyContinue) {
        $hadNetwork = @($selected | Where-Object { [string]$_.category -eq 'Network' -and $_.repairable }).Count -gt 0
        if ($hadNetwork) {
            $dns = Invoke-PostOpDnsFlush
            $details.Add([string]$dns.Output) | Out-Null
        }
    }

    $summary = if ($repairedCount -gt 0) {
        "Repaired $repairedCount selected finding(s)."
    } elseif ($skippedCount -gt 0) {
        'No auto-repairable items were in the selection (review-only rows were skipped).'
    } else {
        'No repair actions were executed for the selected findings.'
    }

    return [PSCustomObject]@{
        Status  = if ($warn) { 'Warn' } else { 'Pass' }
        Output  = $summary
        Details = @($details)
    }
}
