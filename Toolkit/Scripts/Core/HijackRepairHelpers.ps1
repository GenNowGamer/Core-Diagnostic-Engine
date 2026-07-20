#Requires -Version 5.1
<#
.SYNOPSIS
    Shared hijack/scam audit and repair helpers for HijackRepair.ps1 and System Health Check.
#>

$Script:KnownRemoteAccessPatterns = @(
    @{ Label = 'AnyDesk';     Process = 'anydesk';     Service = 'AnyDesk';     Uninstall = 'AnyDesk' }
    @{ Label = 'TeamViewer';  Process = 'teamviewer';  Service = 'TeamViewer';  Uninstall = 'TeamViewer' }
    @{ Label = 'UltraViewer'; Process = 'ultraviewer'; Service = 'UltraViewer'; Uninstall = 'UltraViewer' }
    @{ Label = 'RustDesk';    Process = 'rustdesk';    Service = 'RustDesk';    Uninstall = 'RustDesk' }
    @{ Label = 'ScreenConnect'; Process = 'screenconnect'; Service = 'ScreenConnect'; Uninstall = 'ScreenConnect' }
    @{ Label = 'Splashtop';   Process = 'splashtop';   Service = 'Splashtop';   Uninstall = 'Splashtop' }
    @{ Label = 'LogMeIn';     Process = 'lmiguardian'; Service = 'LogMeIn';     Uninstall = 'LogMeIn' }
    @{ Label = 'GoToAssist';  Process = 'gotoassist';  Service = 'GoToAssist';  Uninstall = 'GoToAssist' }
)

$Script:SuspiciousExtensionNamePatterns = @(
    '(?i)coupon|cashback|shopping|price\s*compare|search\s*protect|search\s*manager',
    '(?i)hijack|adware|toolbar|converter|download\s*helper|easy\s*search',
    '(?i)video\s*download|driver\s*updat|pc\s*clean|speed\s*up|registry\s*clean'
)

$Script:TrustedSearchProviderHosts = @(
    'google.com', 'bing.com', 'duckduckgo.com', 'yahoo.com', 'search.yahoo.com',
    'ecosia.org', 'startpage.com', 'qwant.com', 'brave.com'
)

function Get-HijackChromiumProfileRoots {
    $roots = [System.Collections.Generic.List[object]]::new()
    $users = @(Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue)
    foreach ($user in $users) {
        if ($user.Name -in @('Public', 'Default', 'Default User', 'All Users')) { continue }
        $userRoot = $user.FullName
        foreach ($pair in @(
            @{ Browser = 'Chrome'; Root = Join-Path $userRoot 'AppData\Local\Google\Chrome\User Data' }
            @{ Browser = 'Edge';   Root = Join-Path $userRoot 'AppData\Local\Microsoft\Edge\User Data' }
        )) {
            if (Test-Path -LiteralPath $pair.Root) {
                $roots.Add([PSCustomObject]@{
                    Browser  = $pair.Browser
                    User     = $user.Name
                    Root     = $pair.Root
                }) | Out-Null
            }
        }
    }
    return @($roots)
}

function Test-HijackSuspiciousUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    $lower = $Url.ToLowerInvariant()
    if ($lower -match '^(chrome://|edge://|about:blank|chrome-search://|microsoft-edge://)') { return $false }
    if ($lower -match '^(https?://)?(www\.)?(google|bing|duckduckgo|microsoft|msn)\.') { return $false }
    if ($lower -match 'newtab') { return $false }
    return $true
}

function Get-HijackTrustedPublicDnsServers {
    return @(
        '8.8.8.8', '8.8.4.4',
        '1.1.1.1', '1.0.0.1',
        '9.9.9.9', '149.112.112.112',
        '208.67.222.222', '208.67.220.220'
    )
}

function Get-HijackAdapterGatewayMap {
    $map = @{}
    try {
        foreach ($cfg in @(Get-NetIPConfiguration -ErrorAction SilentlyContinue)) {
            if ($null -eq $cfg.IPv4DefaultGateway -or -not $cfg.IPv4DefaultGateway.NextHop) { continue }
            $map[[int]$cfg.InterfaceIndex] = [string]$cfg.IPv4DefaultGateway.NextHop
        }
    } catch { }
    return $map
}

function Get-HijackGatewayForInterface {
    param([Parameter(Mandatory)][int]$InterfaceIndex)

    $map = Get-HijackAdapterGatewayMap
    if ($map.ContainsKey($InterfaceIndex)) {
        return [string]$map[$InterfaceIndex]
    }

    try {
        $route = @(Get-NetRoute -InterfaceIndex $InterfaceIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Sort-Object RouteMetric, InterfaceMetric |
            Select-Object -First 1)
        if ($route -and $route.NextHop -and [string]$route.NextHop -ne '0.0.0.0') {
            return [string]$route.NextHop
        }
    } catch { }

    return ''
}

function Test-HijackBenignDnsServer {
    param(
        [Parameter(Mandatory)][string]$Server,
        [string]$Gateway = '',
        [int]$InterfaceIndex = 0
    )

    if ([string]::IsNullOrWhiteSpace($Server)) { return $true }
    if ((Get-HijackTrustedPublicDnsServers) -contains $Server) { return $true }
    if ($Server -match '^(127\.|0\.|169\.254\.)') { return $true }

    if ([string]::IsNullOrWhiteSpace($Gateway) -and $InterfaceIndex -gt 0) {
        $Gateway = Get-HijackGatewayForInterface -InterfaceIndex $InterfaceIndex
    }

    if (-not [string]::IsNullOrWhiteSpace($Gateway) -and $Server -eq $Gateway) { return $true }
    return $false
}

function Test-HijackBenignNrptRule {
    param([string]$RuleName)
    if ([string]::IsNullOrWhiteSpace($RuleName)) { return $false }
    return [bool]($RuleName -match '(?i)microsoft|msft|directaccess|corp')
}

function Get-HijackBackupRoot {
    $dir = Join-Path $env:ProgramData 'CDE\HijackBackups'
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function Set-HijackUtf8FileNoBom {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Test-HijackSuspiciousBrowserPolicyValue {
    param(
        [Parameter(Mandatory)][string]$PropertyName,
        [string]$Value = ''
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }

    # Skip Search/URL heuristics for known boolean/enum-style policy names.
    if ($PropertyName -match '(?i)Enabled$|Disabled$') {
        return $false
    }

    if ($PropertyName -match 'URL|Homepage|Restore') {
        return (Test-HijackSuspiciousUrl -Url $Value)
    }
    if ($PropertyName -match 'Search') {
        return $Value -notmatch '(?i)google|bing|duckduckgo|yahoo|microsoft'
    }
    return $false
}

function Test-HijackChromiumSearchHijacked {
    param($Json)

    if ($null -eq $Json) { return $false }
    if (-not $Json.PSObject.Properties['default_search_provider_data']) { return $false }
    $dsp = $Json.default_search_provider_data
    if ($null -eq $dsp -or -not $dsp.PSObject.Properties['template_url_data']) { return $false }

    $tpl = $dsp.template_url_data
    if ($null -eq $tpl -or -not $tpl.PSObject.Properties['short_name']) { return $false }

    $short = [string]$tpl.short_name
    $hostOk = $false
    if ($tpl.PSObject.Properties['url']) {
        $searchUrl = [string]$tpl.url
        foreach ($trusted in $Script:TrustedSearchProviderHosts) {
            if ($searchUrl -match [regex]::Escape($trusted)) { $hostOk = $true; break }
        }
    }
    if (-not $hostOk -and $short -notmatch '(?i)^(Google|Bing|DuckDuckGo|Yahoo|Microsoft)') {
        return $true
    }
    return $false
}

function Test-HijackChromiumPrefsHijacked {
    param($Json)

    if ($null -eq $Json) { return $false }

    if ($Json.PSObject.Properties['homepage']) {
        $hp = [string]$Json.homepage
        if (Test-HijackSuspiciousUrl -Url $hp) { return $true }
    }
    if ($Json.PSObject.Properties['session'] -and $Json.session.PSObject.Properties['startup_urls']) {
        foreach ($url in @($Json.session.startup_urls)) {
            if (Test-HijackSuspiciousUrl -Url ([string]$url)) { return $true }
        }
    }
    if (Test-HijackChromiumSearchHijacked -Json $Json) { return $true }
    return $false
}

function Test-HijackSecurityCenterAvEnabled {
    <#
    .SYNOPSIS
      Decode WMI AntiVirusProduct.productState — middle byte 10 = enabled/on-access.
    #>
    param($ProductState)

    if ($null -eq $ProductState) { return $false }
    try {
        $hex = ('{0:X6}' -f [int]$ProductState)
        if ($hex.Length -lt 4) { return $false }
        return ($hex.Substring($hex.Length - 4, 2) -eq '10')
    } catch {
        return $false
    }
}

function Get-HijackThirdPartyAvProducts {
    <#
    .SYNOPSIS
      Non-Defender Security Center AV products that report as enabled.
    #>
    $active = New-Object System.Collections.Generic.List[object]
    try {
        $products = @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop)
        foreach ($product in $products) {
            $name = [string]$product.displayName
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($name -match '(?i)windows defender|microsoft defender') { continue }
            if (-not (Test-HijackSecurityCenterAvEnabled -ProductState $product.productState)) { continue }
            $active.Add([PSCustomObject]@{
                DisplayName  = $name
                ProductState = $product.productState
                InstanceGuid = [string]$product.instanceGuid
            }) | Out-Null
        }
    } catch { }
    # PS 5.1: @($genericList) can throw "Argument types do not match"
    if ($active.Count -eq 0) { return @() }
    return [object[]]$active.ToArray()
}

function Test-HijackThirdPartyAvActive {
    return (@(Get-HijackThirdPartyAvProducts).Count -gt 0)
}

function Test-HijackDefenderUnavailableError {
    param(
        [int]$HResult = 0,
        [string]$Message = ''
    )

    return (
        $HResult -eq -2147416390 -or
        $Message -match '(?i)0x800106ba|service.*(disabled|not available|not started|cannot be started)|failed to initialize|operation failed'
    )
}

function Test-HijackSuspiciousProxySetting {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    $lower = $Url.ToLowerInvariant()
    if ($lower -match '^(https?://)?(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)') { return $false }
    if ($lower -match 'localhost|\.local[:/]|\.corp[:/]|\.internal[:/]|wpad|pac\.') { return $false }
    return (Test-HijackSuspiciousUrl -Url $Url)
}

function Test-HijackFirefoxPrefHijacked {
    param(
        [Parameter(Mandatory)][string]$PrefName,
        [string]$PrefValue = ''
    )

    if ($PrefName -match 'homepage' -and (Test-HijackSuspiciousUrl -Url $PrefValue)) { return $true }
    if ($PrefName -eq 'browser.search.defaultenginename' -and $PrefValue -notmatch '(?i)^(google|bing|duckduckgo|yahoo)') { return $true }
    if ($PrefName -eq 'browser.startup.page' -and $PrefValue -eq '3' -and (Test-HijackSuspiciousUrl -Url $PrefValue)) { return $true }
    return $false
}

function Test-HijackFirefoxUserJsSuspicious {
    param([Parameter(Mandatory)][string]$UserJsPath)

    if (-not (Test-Path -LiteralPath $UserJsPath)) { return $false }
    $watchPrefs = @(
        'browser.startup.homepage',
        'browser.startup.page',
        'browser.search.defaultenginename',
        'browser.newtabpage.enabled'
    )
    foreach ($line in @(Get-Content -LiteralPath $UserJsPath -ErrorAction SilentlyContinue)) {
        if ($line -notmatch '^user_pref\("([^"]+)",\s*"?([^"]*)"?\);') { continue }
        $prefName = $matches[1]
        $prefValue = $matches[2]
        if ($watchPrefs -notcontains $prefName) { continue }
        if (Test-HijackFirefoxPrefHijacked -PrefName $prefName -PrefValue $prefValue) { return $true }
    }
    return $false
}

function Backup-HijackRegistryProperty {
    param(
        [Parameter(Mandatory)][string]$PolicyPath,
        [Parameter(Mandatory)][string]$PropertyName,
        $Value
    )

    $backupRoot = Get-HijackBackupRoot
    $safePath = ($PolicyPath -replace '[\\:]+', '_')
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backupFile = Join-Path $backupRoot "policy_${safePath}_${PropertyName}_${timestamp}.json"
    $record = [ordered]@{
        policyPath   = $PolicyPath
        propertyName = $PropertyName
        value        = $Value
        backedUpAt   = (Get-Date).ToString('o')
    }
    try {
        ($record | ConvertTo-Json -Compress) | Set-Content -LiteralPath $backupFile -Encoding UTF8 -Force
        return $backupFile
    } catch {
        return $null
    }
}

function Get-HijackBrowserPolicyWatchProperties {
    return @(
        'HomepageLocation', 'NewTabPageLocation', 'RestoreOnStartupURLs',
        'DefaultSearchProviderEnabled', 'DefaultSearchProviderName',
        'DefaultSearchProviderSearchURL', 'ShowHomeButton'
    )
}

function Get-HijackBrowserPolicyPaths {
    return @(
        @{ Browser = 'Chrome'; Path = 'HKLM:\SOFTWARE\Policies\Google\Chrome' }
        @{ Browser = 'Chrome'; Path = 'HKCU:\SOFTWARE\Policies\Google\Chrome' }
        @{ Browser = 'Edge';   Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' }
        @{ Browser = 'Edge';   Path = 'HKCU:\SOFTWARE\Policies\Microsoft\Edge' }
    )
}

function Get-HijackHostsCustomEntries {
    param([string]$HostsPath = '')

    if ([string]::IsNullOrWhiteSpace($HostsPath)) {
        if (Get-Command Get-ToolkitHostsFilePath -ErrorAction SilentlyContinue) {
            $HostsPath = Get-ToolkitHostsFilePath
        } else {
            $HostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
        }
    }

    if (-not (Test-Path -LiteralPath $HostsPath)) { return @() }
    return @(
        Get-Content -LiteralPath $HostsPath -ErrorAction SilentlyContinue |
            Where-Object {
                $_ -notmatch '^\s*#' -and $_ -match '\S' -and
                    $_ -notmatch '127\.0\.0\.1\s+localhost' -and
                    $_ -notmatch '::1\s+localhost'
            }
    )
}

function Get-HijackBrowserPolicyIssues {
    $issues = [System.Collections.Generic.List[string]]::new()
    $watchProps = Get-HijackBrowserPolicyWatchProperties
    foreach ($entry in (Get-HijackBrowserPolicyPaths)) {
        if (-not (Test-Path -LiteralPath $entry.Path)) { continue }
        try {
            $props = Get-ItemProperty -LiteralPath $entry.Path -ErrorAction Stop
            foreach ($prop in $props.PSObject.Properties) {
                if ($prop.Name -in @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider')) { continue }
                if ($watchProps -notcontains $prop.Name) { continue }
                $val = [string]$prop.Value
                if (-not (Test-HijackSuspiciousBrowserPolicyValue -PropertyName $prop.Name -Value $val)) { continue }
                $issues.Add("$($entry.Browser) policy $($entry.Path) :: $($prop.Name) = $val") | Out-Null
            }
        } catch { }
    }
    return @($issues)
}

function Get-HijackChromiumPreferenceIssues {
    param([string]$Browser, [string]$ProfilePath, [string]$User)

    $issues = [System.Collections.Generic.List[string]]::new()
    $prefsPath = Join-Path $ProfilePath 'Preferences'
    if (-not (Test-Path -LiteralPath $prefsPath)) { return @() }

    try {
        $json = Get-Content -LiteralPath $prefsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $issues.Add("$Browser ($User): could not parse Preferences at $prefsPath") | Out-Null
        return @($issues)
    }

    if ($json.PSObject.Properties['homepage']) {
        $hp = [string]$json.homepage
        if ((Test-HijackSuspiciousUrl -Url $hp)) {
            $issues.Add("$Browser ($User): homepage = $hp") | Out-Null
        }
    }

    if ($json.PSObject.Properties['session'] -and $json.session.PSObject.Properties['startup_urls']) {
        foreach ($url in @($json.session.startup_urls)) {
            if ((Test-HijackSuspiciousUrl -Url ([string]$url))) {
                $issues.Add("$Browser ($User): startup URL = $url") | Out-Null
            }
        }
    }

    if (Test-HijackChromiumSearchHijacked -Json $json) {
        $short = ''
        if ($json.default_search_provider_data.template_url_data.short_name) {
            $short = [string]$json.default_search_provider_data.template_url_data.short_name
        }
        $issues.Add("$Browser ($User): search provider = $short") | Out-Null
    }

    return @($issues)
}

function Get-HijackFirefoxPreferenceIssues {
    param([string]$ProfileDir, [string]$User, [string]$ProfileName)

    $issues = [System.Collections.Generic.List[string]]::new()
    $prefsPath = Join-Path $ProfileDir 'prefs.js'
    if (-not (Test-Path -LiteralPath $prefsPath)) { return @() }

    $watchPrefs = @(
        'browser.startup.homepage',
        'browser.startup.page',
        'browser.search.defaultenginename',
        'browser.newtabpage.enabled'
    )

    foreach ($line in (Get-Content -LiteralPath $prefsPath -ErrorAction SilentlyContinue)) {
        if ($line -notmatch '^user_pref\("([^"]+)",\s*"?([^"]*)"?\);') { continue }
        $name = $matches[1]
        $value = $matches[2]
        if ($watchPrefs -notcontains $name) { continue }
        if (Test-HijackFirefoxPrefHijacked -PrefName $name -PrefValue $value) {
            $issues.Add("Firefox ($User / $ProfileName): $name = $value") | Out-Null
        }
    }

    if ((Test-Path -LiteralPath (Join-Path $ProfileDir 'user.js')) -and
        (Test-HijackFirefoxUserJsSuspicious -UserJsPath (Join-Path $ProfileDir 'user.js'))) {
        $issues.Add("Firefox ($User / $ProfileName): user.js present (may lock hijacked prefs)") | Out-Null
    }

    return @($issues)
}

function Invoke-HijackBrowserAudit {
    if ((Get-Command Get-EnvironmentMode -ErrorAction SilentlyContinue) -and (Get-EnvironmentMode) -ne 'Windows') {
        return [PSCustomObject]@{
            Status  = 'N/A'
            Output  = 'Not applicable in WinPE. Browser profiles require a live user session.'
            Details = @()
            Issues  = @()
        }
    }

    $issues = [System.Collections.Generic.List[string]]::new()
    foreach ($policyIssue in (Get-HijackBrowserPolicyIssues)) { $issues.Add($policyIssue) | Out-Null }

    foreach ($store in (Get-HijackChromiumProfileRoots)) {
        $profiles = @(Get-ChildItem -LiteralPath $store.Root -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(Default|Profile \d+)$' })
        foreach ($profile in $profiles) {
            foreach ($item in (Get-HijackChromiumPreferenceIssues -Browser $store.Browser -ProfilePath $profile.FullName -User $store.User)) {
                $issues.Add($item) | Out-Null
            }
        }
    }

    $users = @(Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue)
    foreach ($user in $users) {
        if ($user.Name -in @('Public', 'Default', 'Default User', 'All Users')) { continue }
        $ffRoot = Join-Path $user.FullName 'AppData\Roaming\Mozilla\Firefox\Profiles'
        if (-not (Test-Path -LiteralPath $ffRoot)) { continue }
        foreach ($profile in @(Get-ChildItem -LiteralPath $ffRoot -Directory -ErrorAction SilentlyContinue)) {
            foreach ($item in (Get-HijackFirefoxPreferenceIssues -ProfileDir $profile.FullName -User $user.Name -ProfileName $profile.Name)) {
                $issues.Add($item) | Out-Null
            }
        }
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('BROWSER HIJACK AUDIT') | Out-Null
    $lines.Add('====================') | Out-Null
    $lines.Add('') | Out-Null
    if ($issues.Count -eq 0) {
        $lines.Add('No homepage, search, startup URL, or policy hijacks were detected.') | Out-Null
    } else {
        $lines.Add("Issues found: $($issues.Count)") | Out-Null
        $lines.Add('') | Out-Null
        $index = 0
        foreach ($issue in $issues) {
            $index++
            $lines.Add("[$index] $issue") | Out-Null
        }
        $lines.Add('') | Out-Null
        $lines.Add('Repair: run Hijack and Scam Repair - Browser Hijack Repair (backs up prefs before changes).') | Out-Null
    }

    $status = if ($issues.Count -gt 0) { 'Warn' } else { 'Pass' }
    return [PSCustomObject]@{
        Status  = $status
        Output  = ($lines -join "`n")
        Details = @($issues)
        Issues  = @($issues)
    }
}

function Invoke-HijackNetworkAudit {
    $issues = [System.Collections.Generic.List[string]]::new()
    $envMode = if (Get-Command Get-EnvironmentMode -ErrorAction SilentlyContinue) { Get-EnvironmentMode } else { 'Windows' }

    if ($envMode -ne 'Windows') {
        $custom = @(Get-HijackHostsCustomEntries)
        if ($custom.Count -gt 0) {
            $issues.Add("Hosts file has $($custom.Count) non-default entries (offline audit).") | Out-Null
        }
        $status = if ($issues.Count -gt 0) { 'Warn' } else { 'Pass' }
        $output = if ($issues.Count -gt 0) { ($issues -join "`n") } else { 'Offline: hosts file looks default. Run live Windows for full DNS/proxy audit.' }
        return [PSCustomObject]@{ Status = $status; Output = $output; Details = @($issues); Issues = @($issues) }
    }

    $customHosts = @(Get-HijackHostsCustomEntries)
    if ($customHosts.Count -gt 0) {
        $issues.Add("Hosts file has $($customHosts.Count) non-default entries.") | Out-Null
    }

    $internetSettings = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    if (Test-Path -LiteralPath $internetSettings) {
        try {
            $props = Get-ItemProperty -LiteralPath $internetSettings -ErrorAction Stop
            if ($props.ProxyEnable -eq 1) {
                $server = [string]$props.ProxyServer
                $issues.Add("User proxy enabled: $server") | Out-Null
            }
            if ($props.AutoConfigURL) {
                $issues.Add("PAC / AutoConfigURL: $($props.AutoConfigURL)") | Out-Null
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
                $issues.Add("Adapter $($adapter.InterfaceAlias): non-default DNS server $server") | Out-Null
            }
        }
    } catch {
        $issues.Add("DNS adapter query failed: $($_.Exception.Message)") | Out-Null
    }

    try {
        $nrpt = @(Get-DnsClientNrptRule -ErrorAction Stop)
        foreach ($rule in $nrpt) {
            if (Test-HijackBenignNrptRule -RuleName ([string]$rule.Name)) { continue }
            $issues.Add("NRPT rule: $($rule.Name) -> $($rule.NameServers -join ', ')") | Out-Null
        }
    } catch { }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('NETWORK HIJACK AUDIT') | Out-Null
    $lines.Add('=====================') | Out-Null
    $lines.Add('') | Out-Null
    if ($issues.Count -eq 0) {
        $lines.Add('No proxy, PAC, or suspicious NRPT rules detected. DNS servers listed per adapter look routine.') | Out-Null
    } else {
        $lines.Add("Review $($issues.Count) item(s):") | Out-Null
        $lines.Add('') | Out-Null
        foreach ($issue in $issues) { $lines.Add(" - $issue") | Out-Null }
        $lines.Add('') | Out-Null
        $lines.Add('Repair: Hijack and Scam Repair - Network Hijack Repair (resets DNS to DHCP, proxy, NRPT cleanup).') | Out-Null
    }

    $status = if ($issues.Count -gt 0) { 'Warn' } else { 'Pass' }
    return [PSCustomObject]@{
        Status  = $status
        Output  = ($lines -join "`n")
        Details = @($issues)
        Issues  = @($issues)
    }
}

function Test-HijackRiskyDefenderExclusion {
    param(
        [Parameter(Mandatory)][string]$ExclusionType,
        [Parameter(Mandatory)][string]$Value
    )

    $trimmed = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) { return $false }
    $lower = $trimmed.ToLowerInvariant()

    if ($ExclusionType -in @('Path', 'Process')) {
        if ($lower -match '\\temp\\|\\appdata\\|\\users\\public\\|\\programdata\\' -or $lower -match '^[a-z]:\\?$') {
            return $true
        }
    }

    if ($ExclusionType -eq 'Extension') {
        if ($trimmed -match '(?i)^\.?((exe)|(dll)|(bat)|(cmd)|(ps1)|(js)|(vbs)|(scr))$') {
            return $true
        }
    }

    return $false
}

function Invoke-HijackSecurityTamperingAudit {
    $issues = [System.Collections.Generic.List[string]]::new()
    $notes = [System.Collections.Generic.List[string]]::new()
    $envMode = if (Get-Command Get-EnvironmentMode -ErrorAction SilentlyContinue) { Get-EnvironmentMode } else { 'Windows' }

    if ($envMode -ne 'Windows') {
        return [PSCustomObject]@{
            Status  = 'N/A'
            Output  = 'Not applicable in WinPE. Security tampering audit requires live Windows Defender and firewall APIs.'
            Details = @()
            Issues  = @()
        }
    }

    $thirdPartyAvProducts = @(Get-HijackThirdPartyAvProducts)
    $thirdPartyAv = $thirdPartyAvProducts.Count -gt 0
    $thirdPartyNames = @($thirdPartyAvProducts | ForEach-Object { [string]$_.DisplayName } | Sort-Object -Unique)
    if ($thirdPartyAv) {
        $notes.Add(("Third-party antivirus active ({0}); Defender passive/disabled state is expected coexistence, not treated as tampering." -f ($thirdPartyNames -join ', '))) | Out-Null
    }

    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        if (-not $mp.AntivirusEnabled) {
            if ($thirdPartyAv) {
                $notes.Add('Windows Defender antivirus is disabled while third-party AV is active (expected).') | Out-Null
            } else {
                $issues.Add('Windows Defender antivirus is disabled.') | Out-Null
            }
        }
        if (-not $mp.RealTimeProtectionEnabled) {
            if ($thirdPartyAv -and $mp.AntivirusEnabled -eq $false) {
                $notes.Add('Windows Defender real-time protection is off while third-party AV is active (expected).') | Out-Null
            } else {
                $issues.Add('Windows Defender real-time protection is off.') | Out-Null
            }
        }
        if ($mp.IsTamperProtected -eq $false) {
            if ($thirdPartyAv -and $mp.AntivirusEnabled -eq $false) {
                $notes.Add('Defender tamper protection is off while third-party AV owns protection (expected).') | Out-Null
            } else {
                $issues.Add('Defender tamper protection is off.') | Out-Null
            }
        }
        if ($mp.AMServiceEnabled -eq $false) {
            if ($thirdPartyAv) {
                $notes.Add('Defender antimalware service is disabled while third-party AV is active (expected).') | Out-Null
            } else {
                $issues.Add('Defender antimalware service is disabled.') | Out-Null
            }
        }
    } catch {
        $msg = [string]$_.Exception.Message
        $hr = 0
        try { $hr = [int]$_.Exception.HResult } catch { }
        if ($thirdPartyAv -or (Test-HijackDefenderUnavailableError -HResult $hr -Message $msg)) {
            if ($thirdPartyAv) {
                $notes.Add("Defender status unavailable while third-party AV is active (expected): $msg") | Out-Null
            } else {
                $notes.Add("Defender status unavailable (service not usable): $msg") | Out-Null
                $issues.Add("Defender status unavailable: $msg") | Out-Null
            }
        } else {
            $issues.Add("Defender status unavailable: $msg") | Out-Null
        }
    }

    try {
        if (Get-Command Get-MpPreference -ErrorAction SilentlyContinue) {
            $pref = Get-MpPreference -ErrorAction Stop
            $exclusionGroups = @(
                @{ Type = 'Path'; Values = @($pref.ExclusionPath) },
                @{ Type = 'Process'; Values = @($pref.ExclusionProcess) },
                @{ Type = 'Extension'; Values = @($pref.ExclusionExtension) },
                @{ Type = 'IpAddress'; Values = @($pref.ExclusionIpAddress) }
            )
            foreach ($group in $exclusionGroups) {
                foreach ($value in @($group.Values)) {
                    if ([string]::IsNullOrWhiteSpace([string]$value)) { continue }
                    if (Test-HijackRiskyDefenderExclusion -ExclusionType $group.Type -Value ([string]$value)) {
                        $issues.Add("Risky Defender $($group.Type) exclusion: $value") | Out-Null
                    } else {
                        $issues.Add("Defender $($group.Type) exclusion present (review): $value") | Out-Null
                    }
                }
            }
        }
    } catch {
        $msg = [string]$_.Exception.Message
        $hr = 0
        try { $hr = [int]$_.Exception.HResult } catch { }
        # Only suppress when another AV owns protection. Alone, 0x800106BA still warrants review.
        if ($thirdPartyAv -and (Test-HijackDefenderUnavailableError -HResult $hr -Message $msg)) {
            $notes.Add("Defender exclusion audit skipped (Defender API unavailable under third-party AV): $msg") | Out-Null
        } elseif ($thirdPartyAv) {
            $notes.Add("Defender exclusion audit skipped while third-party AV is active: $msg") | Out-Null
        } else {
            $issues.Add("Defender exclusion audit unavailable: $msg") | Out-Null
        }
    }

    try {
        $profiles = @(Get-NetFirewallProfile -ErrorAction Stop)
        foreach ($profile in $profiles) {
            if (-not $profile.Enabled) {
                $issues.Add("Windows Firewall $($profile.Name) profile is disabled.") | Out-Null
            }
        }
    } catch {
        $issues.Add("Firewall status unavailable: $($_.Exception.Message)") | Out-Null
    }

    $uacKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    if (Test-Path -LiteralPath $uacKey) {
        try {
            $uac = Get-ItemProperty -LiteralPath $uacKey -ErrorAction Stop
            if ($null -ne $uac.EnableLUA -and [int]$uac.EnableLUA -eq 0) {
                $issues.Add('UAC (EnableLUA) is disabled.') | Out-Null
            }
            if ($null -ne $uac.ConsentPromptBehaviorAdmin -and [int]$uac.ConsentPromptBehaviorAdmin -eq 0) {
                $issues.Add('UAC admin consent prompt is set to never notify.') | Out-Null
            }
        } catch { }
    }

    $smartScreen = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer'
    if (Test-Path -LiteralPath $smartScreen) {
        try {
            $ss = Get-ItemProperty -LiteralPath $smartScreen -ErrorAction Stop
            if ($null -ne $ss.SmartScreenEnabled -and [string]$ss.SmartScreenEnabled -eq 'Off') {
                $issues.Add('SmartScreen (Explorer) is off.') | Out-Null
            }
        } catch { }
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('SECURITY TAMPERING AUDIT') | Out-Null
    $lines.Add('========================') | Out-Null
    $lines.Add('') | Out-Null
    if ($thirdPartyAv) {
        $lines.Add(("Third-party antivirus (active): {0}" -f ($thirdPartyNames -join ', '))) | Out-Null
        $lines.Add('Windows Defender is disabled/passive because this product is providing protection.') | Out-Null
        $lines.Add('That coexistence is expected and is not treated as security tampering.') | Out-Null
        $lines.Add('') | Out-Null
    }
    if ($notes.Count -gt 0) {
        $lines.Add('Notes:') | Out-Null
        foreach ($note in $notes) { $lines.Add(" - $note") | Out-Null }
        $lines.Add('') | Out-Null
    }
    if ($issues.Count -eq 0) {
        if ($thirdPartyAv) {
            $lines.Add('Result: Pass - no tampering indicators. Defender passive state explained by third-party AV above.') | Out-Null
        } else {
            $lines.Add('Defender, firewall, UAC, SmartScreen, and exclusion settings look intact.') | Out-Null
        }
    } else {
        foreach ($issue in $issues) { $lines.Add(" - $issue") | Out-Null }
        $lines.Add('') | Out-Null
        $lines.Add('Repair: Hijack and Scam Repair - Security Settings Restore (exclusions are review-only).') | Out-Null
    }

    $status = if ($issues.Count -gt 0) { 'Warn' } else { 'Pass' }
    return [PSCustomObject]@{
        Status  = $status
        Output  = ($lines -join "`n")
        Details = @($issues)
        Issues  = @($issues)
        Notes   = @($notes)
        ThirdPartyAvActive = $thirdPartyAv
        ThirdPartyAvNames  = @($thirdPartyNames)
    }
}

function Invoke-HijackRemoteAccessAudit {
    $findings = [System.Collections.Generic.List[string]]::new()
    $envMode = if (Get-Command Get-EnvironmentMode -ErrorAction SilentlyContinue) { Get-EnvironmentMode } else { 'Windows' }

    if ($envMode -ne 'Windows') {
        return [PSCustomObject]@{
            Status  = 'N/A'
            Output  = 'Not applicable in WinPE. Remote-access inventory requires live processes and services.'
            Details = @()
            Issues  = @()
        }
    }

    foreach ($rat in $Script:KnownRemoteAccessPatterns) {
        $procHits = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $rat.Process })
        if ($procHits.Count -gt 0) {
            $findings.Add("$($rat.Label): running $($procHits.Count) process(es)") | Out-Null
        }

        $svc = Get-Service -Name $rat.Service -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            $findings.Add("$($rat.Label): service $($svc.Name) is running") | Out-Null
        }

        $uninstallRoots = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        foreach ($root in $uninstallRoots) {
            $apps = @(Get-ItemProperty $root -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -and $_.DisplayName -match [regex]::Escape($rat.Uninstall) })
            foreach ($app in $apps) {
                $findings.Add("$($rat.Label): installed ($($app.DisplayName))") | Out-Null
            }
        }
    }

    try {
        $rdp = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -ErrorAction SilentlyContinue
        if ($rdp -and [int]$rdp.fDenyTSConnections -eq 0) {
            $findings.Add('Remote Desktop: incoming connections are allowed (fDenyTSConnections=0).') | Out-Null
        }
    } catch { }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('REMOTE ACCESS INVENTORY') | Out-Null
    $lines.Add('=======================') | Out-Null
    $lines.Add('') | Out-Null
    if ($findings.Count -eq 0) {
        $lines.Add('No common remote-access tools or open RDP were detected.') | Out-Null
    } else {
        $lines.Add("Found $($findings.Count) item(s) to review with the customer:") | Out-Null
        $lines.Add('') | Out-Null
        foreach ($f in $findings) { $lines.Add(" - $f") | Out-Null }
        $lines.Add('') | Out-Null
        $lines.Add('CDE does not auto-remove remote tools - verify legitimacy before uninstalling.') | Out-Null
    }

    $status = if ($findings.Count -gt 0) { 'Warn' } else { 'Pass' }
    return [PSCustomObject]@{
        Status  = $status
        Output  = ($lines -join "`n")
        Details = @($findings)
        Issues  = @($findings)
    }
}

function Repair-HijackChromiumPreferences {
    param(
        [string]$PrefsPath,
        [string]$Label,
        [switch]$OnlyIfHijacked
    )

    $details = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath $PrefsPath)) {
        return @{ Changed = $false; Details = @("No Preferences at $PrefsPath") }
    }

    try {
        $raw = Get-Content -LiteralPath $PrefsPath -Raw -ErrorAction Stop
        $json = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($OnlyIfHijacked -and -not (Test-HijackChromiumPrefsHijacked -Json $json)) {
            return @{ Changed = $false; Details = @("${Label}: no hijacked preference keys detected.") }
        }
    } catch {
        $details.Add("$Label read error: $($_.Exception.Message)") | Out-Null
        return @{ Changed = $false; Details = @($details) }
    }

    $backup = "$PrefsPath.hijackbak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    try {
        Copy-Item -LiteralPath $PrefsPath -Destination $backup -Force -ErrorAction Stop
        $details.Add("Backup: $backup") | Out-Null
    } catch {
        $details.Add("Backup failed: $($_.Exception.Message)") | Out-Null
        return @{ Changed = $false; Details = @($details) }
    }

    try {
        $json = Get-Content -LiteralPath $PrefsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $changed = $false

        if ($json.PSObject.Properties['homepage']) {
            $json.PSObject.Properties.Remove('homepage')
            $changed = $true
            $details.Add('Removed homepage override.') | Out-Null
        }
        if ($json.PSObject.Properties['homepage_is_newtabpage']) {
            $json.homepage_is_newtabpage = $true
            $changed = $true
        }
        if ($json.PSObject.Properties['session']) {
            if ($json.session.PSObject.Properties['startup_urls']) {
                $json.session.startup_urls = @()
                $changed = $true
                $details.Add('Cleared startup_urls.') | Out-Null
            }
            if ($json.session.PSObject.Properties['restore_on_startup']) {
                $json.session.restore_on_startup = 1
                $changed = $true
            }
        }
        foreach ($searchKey in @('default_search_provider_data', 'default_search_provider')) {
            if ($json.PSObject.Properties[$searchKey]) {
                $json.PSObject.Properties.Remove($searchKey)
                $changed = $true
                $details.Add("Removed $searchKey.") | Out-Null
            }
        }

        if ($changed) {
            $out = $json | ConvertTo-Json -Depth 20 -Compress
            Set-HijackUtf8FileNoBom -Path $PrefsPath -Content $out
            $details.Add("$Label preferences reset.") | Out-Null
        } else {
            $details.Add("${Label}: no preference changes needed.") | Out-Null
        }

        return @{ Changed = $changed; Details = @($details) }
    } catch {
        $details.Add("$Label repair error: $($_.Exception.Message)") | Out-Null
        return @{ Changed = $false; Details = @($details) }
    }
}

function Repair-HijackFirefoxPrefs {
    param([string]$PrefsPath, [string]$Label)

    $details = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath $PrefsPath)) {
        return @{ Changed = $false; Details = @("No prefs.js at $PrefsPath") }
    }

    $watchPrefs = @(
        'browser.startup.homepage',
        'browser.startup.page',
        'browser.search.defaultenginename',
        'browser.newtabpage.enabled'
    )
    $lines = @(Get-Content -LiteralPath $PrefsPath -ErrorAction Stop)
    $removeLines = [System.Collections.Generic.List[int]]::new()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -notmatch '^user_pref\("([^"]+)",\s*"?([^"]*)"?\);') { continue }
        $prefName = $matches[1]
        $prefValue = $matches[2]
        if ($watchPrefs -notcontains $prefName) { continue }
        if (Test-HijackFirefoxPrefHijacked -PrefName $prefName -PrefValue $prefValue) {
            $removeLines.Add($i) | Out-Null
        }
    }

    if ($removeLines.Count -eq 0) {
        return @{ Changed = $false; Details = @("${Label}: no hijacked prefs.js lines found.") }
    }

    $backup = "$PrefsPath.hijackbak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    try {
        Copy-Item -LiteralPath $PrefsPath -Destination $backup -Force -ErrorAction Stop
        $details.Add("Backup: $backup") | Out-Null
    } catch {
        $details.Add("Backup failed: $($_.Exception.Message)") | Out-Null
        return @{ Changed = $false; Details = @($details) }
    }

    $kept = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($removeLines -contains $i) { continue }
        $kept.Add($lines[$i]) | Out-Null
    }
    Set-HijackUtf8FileNoBom -Path $PrefsPath -Content (($kept -join "`n") + "`n")
    $details.Add("$Label removed $($removeLines.Count) hijacked prefs.js line(s).") | Out-Null
    return @{ Changed = $true; Details = @($details) }
}

function Repair-HijackBrowserPolicies {
    $details = [System.Collections.Generic.List[string]]::new()
    $changed = $false
    $watchProps = Get-HijackBrowserPolicyWatchProperties

    foreach ($entry in (Get-HijackBrowserPolicyPaths)) {
        $path = $entry.Path
        if (-not (Test-Path -LiteralPath $path)) { continue }
        foreach ($prop in $watchProps) {
            try {
                $current = Get-ItemProperty -LiteralPath $path -Name $prop -ErrorAction Stop
                $val = [string]$current.$prop
            } catch { continue }

            if (-not (Test-HijackSuspiciousBrowserPolicyValue -PropertyName $prop -Value $val)) { continue }

            $backupFile = Backup-HijackRegistryProperty -PolicyPath $path -PropertyName $prop -Value $val
            try {
                Remove-ItemProperty -LiteralPath $path -Name $prop -ErrorAction Stop
                $details.Add("Removed $path\$prop") | Out-Null
                if ($backupFile) { $details.Add("Policy backup: $backupFile") | Out-Null }
                $changed = $true
            } catch { }
        }
    }

    return @{ Changed = $changed; Details = @($details) }
}

function Invoke-HijackBrowserRepair {
    $envMode = if (Get-Command Get-EnvironmentMode -ErrorAction SilentlyContinue) { Get-EnvironmentMode } else { 'Windows' }
    if ($envMode -ne 'Windows') {
        return [PSCustomObject]@{ Status = 'N/A'; Output = 'Not applicable in WinPE.'; Details = @() }
    }

    $details = [System.Collections.Generic.List[string]]::new()
    $warn = $false

    $policyWork = Repair-HijackBrowserPolicies
    foreach ($line in $policyWork.Details) { $details.Add($line) | Out-Null }

    foreach ($store in (Get-HijackChromiumProfileRoots)) {
        $profiles = @(Get-ChildItem -LiteralPath $store.Root -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(Default|Profile \d+)$' })
        foreach ($profile in $profiles) {
            $prefs = Join-Path $profile.FullName 'Preferences'
            $label = "$($store.Browser) ($($store.User)/$($profile.Name))"
            $work = Repair-HijackChromiumPreferences -PrefsPath $prefs -Label $label -OnlyIfHijacked
            foreach ($line in $work.Details) { $details.Add($line) | Out-Null }
            if (-not $work.Changed -and $work.Details -match 'error|failed') { $warn = $true }
        }
    }

    $users = @(Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue)
    foreach ($user in $users) {
        if ($user.Name -in @('Public', 'Default', 'Default User', 'All Users')) { continue }
        $ffRoot = Join-Path $user.FullName 'AppData\Roaming\Mozilla\Firefox\Profiles'
        if (-not (Test-Path -LiteralPath $ffRoot)) { continue }
        foreach ($profile in @(Get-ChildItem -LiteralPath $ffRoot -Directory -ErrorAction SilentlyContinue)) {
            $prefsJs = Join-Path $profile.FullName 'prefs.js'
            if (Test-Path -LiteralPath $prefsJs) {
                $ffLabel = "Firefox ($($user.Name)/$($profile.Name))"
                $prefWork = Repair-HijackFirefoxPrefs -PrefsPath $prefsJs -Label $ffLabel
                foreach ($line in $prefWork.Details) { $details.Add($line) | Out-Null }
                if (-not $prefWork.Changed -and $prefWork.Details -match 'error|failed') { $warn = $true }
            }

            $userJs = Join-Path $profile.FullName 'user.js'
            if ((Test-Path -LiteralPath $userJs) -and (Test-HijackFirefoxUserJsSuspicious -UserJsPath $userJs)) {
                $bak = "$userJs.hijackbak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
                try {
                    Move-Item -LiteralPath $userJs -Destination $bak -Force -ErrorAction Stop
                    $details.Add("Firefox: moved user.js to $bak") | Out-Null
                } catch {
                    $warn = $true
                    $details.Add("Firefox user.js move failed: $($_.Exception.Message)") | Out-Null
                }
            }
        }
    }

    if ($details.Count -eq 0) { $details.Add('No browser profiles found to repair.') | Out-Null }

    return [PSCustomObject]@{
        Status  = if ($warn) { 'Warn' } else { 'Pass' }
        Output  = 'Browser hijack repair completed. Close and reopen browsers to verify homepage and search.'
        Details = @($details)
    }
}

function Invoke-HijackNetworkRepair {
    $details = [System.Collections.Generic.List[string]]::new()
    $warn = $false
    $envMode = if (Get-Command Get-EnvironmentMode -ErrorAction SilentlyContinue) { Get-EnvironmentMode } else { 'Windows' }

    if ($envMode -ne 'Windows') {
        return [PSCustomObject]@{ Status = 'N/A'; Output = 'Not applicable in WinPE.'; Details = @() }
    }

    # Bulk network repair: proxy + DNS flush always. Adapter DHCP reset only for flagged DNS.
    # NRPT deletes stay on selected findings (network.nrpt.remove), not Repair All Network.
    if (Get-Command Invoke-PostOpProxyReset -ErrorAction SilentlyContinue) {
        $proxy = Invoke-PostOpProxyReset
        $details.Add([string]$proxy.Output) | Out-Null
        if ($proxy.Status -eq 'Warn') { $warn = $true }
    }

    if (Get-Command Invoke-PostOpDnsFlush -ErrorAction SilentlyContinue) {
        $dns = Invoke-PostOpDnsFlush
        $details.Add([string]$dns.Output) | Out-Null
        if ($dns.Status -ne 'Pass') { $warn = $true }
    }

    try {
        $gatewayMap = if (Get-Command Get-HijackAdapterGatewayMap -ErrorAction SilentlyContinue) {
            Get-HijackAdapterGatewayMap
        } else {
            @{}
        }
        $adapters = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.ServerAddresses -and $_.ServerAddresses.Count -gt 0 })
        $resetIndexes = @{}
        foreach ($adapter in $adapters) {
            $idx = [int]$adapter.InterfaceIndex
            $gateway = if ($gatewayMap -is [hashtable] -and $gatewayMap.ContainsKey($idx)) {
                [string]$gatewayMap[$idx]
            } else { '' }
            $flagged = $false
            foreach ($server in @($adapter.ServerAddresses)) {
                if (-not (Test-HijackBenignDnsServer -Server ([string]$server) -Gateway $gateway -InterfaceIndex $idx)) {
                    $flagged = $true
                    break
                }
            }
            if (-not $flagged) { continue }
            if ($resetIndexes.ContainsKey($idx)) { continue }
            $resetIndexes[$idx] = $true
            try {
                Set-DnsClientServerAddress -InterfaceIndex $idx -ResetServerAddresses -ErrorAction Stop
                $details.Add("Reset DNS to DHCP on $($adapter.InterfaceAlias) (flagged DNS finding).") | Out-Null
            } catch {
                $warn = $true
                $details.Add("DNS reset failed on $($adapter.InterfaceAlias): $($_.Exception.Message)") | Out-Null
            }
        }
        if ($resetIndexes.Count -eq 0) {
            $details.Add('No flagged DNS adapters required DHCP reset.') | Out-Null
        }
    } catch {
        $warn = $true
        $details.Add("DNS adapter enumeration failed: $($_.Exception.Message)") | Out-Null
    }

    $details.Add('NRPT rules were not bulk-deleted; use Repair Selected on network.nrpt findings.') | Out-Null

    return [PSCustomObject]@{
        Status  = if ($warn) { 'Warn' } else { 'Pass' }
        Output  = 'Network hijack repair completed (proxy, DNS flush, flagged adapter DNS). NRPT requires selected repair.'
        Details = @($details)
    }
}

function Invoke-HijackSecurityTamperingRepair {
    $details = [System.Collections.Generic.List[string]]::new()
    $warn = $false
    $envMode = if (Get-Command Get-EnvironmentMode -ErrorAction SilentlyContinue) { Get-EnvironmentMode } else { 'Windows' }

    if ($envMode -ne 'Windows') {
        return [PSCustomObject]@{ Status = 'N/A'; Output = 'Not applicable in WinPE.'; Details = @() }
    }

    $thirdPartyAv = Test-HijackThirdPartyAvActive
    if ($thirdPartyAv) {
        $details.Add('Third-party antivirus is active. Skipping WinDefend Automatic / RTP force-enable.') | Out-Null
        $warn = $true
    } else {
        try {
            Set-Service -Name 'WinDefend' -StartupType Automatic -ErrorAction Stop
            Start-Service -Name 'WinDefend' -ErrorAction SilentlyContinue
            $details.Add('WinDefend set to Automatic and start attempted.') | Out-Null
        } catch {
            $warn = $true
            $details.Add("WinDefend: $($_.Exception.Message)") | Out-Null
        }

        try {
            Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction SilentlyContinue
            Set-MpPreference -DisableTamperProtection $false -ErrorAction SilentlyContinue
            $details.Add('Defender real-time monitoring and tamper protection enable attempted.') | Out-Null
        } catch { }
    }

    try {
        Set-NetFirewallProfile -Profile Domain, Public, Private -Enabled True -ErrorAction Stop
        $details.Add('Windows Firewall enabled on all profiles.') | Out-Null
    } catch {
        $warn = $true
        $details.Add("Firewall: $($_.Exception.Message)") | Out-Null
    }

    $uacKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    if (Test-Path -LiteralPath $uacKey) {
        try {
            Set-ItemProperty -LiteralPath $uacKey -Name EnableLUA -Value 1 -Type DWord -Force -ErrorAction Stop
            Set-ItemProperty -LiteralPath $uacKey -Name ConsentPromptBehaviorAdmin -Value 5 -Type DWord -Force -ErrorAction Stop
            $details.Add('UAC restored to default (EnableLUA=1, ConsentPromptBehaviorAdmin=5).') | Out-Null
        } catch {
            $warn = $true
            $details.Add("UAC restore: $($_.Exception.Message)") | Out-Null
        }
    }

    $smartScreen = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer'
    if (Test-Path -LiteralPath $smartScreen) {
        try {
            Set-ItemProperty -LiteralPath $smartScreen -Name SmartScreenEnabled -Value 'RequireAdmin' -Force -ErrorAction SilentlyContinue
            $details.Add('SmartScreen set to RequireAdmin.') | Out-Null
        } catch { }
    }

    return [PSCustomObject]@{
        Status  = if ($warn) { 'Warn' } else { 'Pass' }
        Output  = 'Security settings restore completed. Reboot if Defender or firewall still report issues.'
        Details = @($details)
    }
}

function Get-HijackBrowserExtensionInventory {
    $inventory = [System.Collections.Generic.List[object]]::new()
    $envMode = if (Get-Command Get-EnvironmentMode -ErrorAction SilentlyContinue) { Get-EnvironmentMode } else { 'Windows' }
    if ($envMode -ne 'Windows') { return @() }

    foreach ($store in (Get-HijackChromiumProfileRoots)) {
        $profiles = @(Get-ChildItem -LiteralPath $store.Root -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(Default|Profile \d+)$' })
        foreach ($profile in $profiles) {
            $extRoot = Join-Path $profile.FullName 'Extensions'
            if (-not (Test-Path -LiteralPath $extRoot)) { continue }
            foreach ($extensionFolder in @(Get-ChildItem -LiteralPath $extRoot -Directory -ErrorAction SilentlyContinue)) {
                $extensionId = $extensionFolder.Name
                $versionFolders = @(Get-ChildItem -LiteralPath $extensionFolder.FullName -Directory -ErrorAction SilentlyContinue | Sort-Object Name)
                $manifestName = ''
                $manifestDescription = ''
                if ($versionFolders.Count -gt 0) {
                    $versionPath = $versionFolders[$versionFolders.Count - 1].FullName
                    $manifestPath = Join-Path $versionPath 'manifest.json'
                    if (Test-Path -LiteralPath $manifestPath) {
                        try {
                            $manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                            if ($manifest.PSObject.Properties['name']) { $manifestName = [string]$manifest.name }
                            if ($manifest.PSObject.Properties['description']) { $manifestDescription = [string]$manifest.description }
                        } catch { }
                    }
                }
                $inventory.Add([PSCustomObject]@{
                    Browser             = $store.Browser
                    User                = $store.User
                    Profile             = $profile.Name
                    ExtensionId         = $extensionId
                    ExtensionName       = $manifestName
                    ManifestDescription = $manifestDescription
                    Location            = $extensionFolder.FullName
                }) | Out-Null
            }
        }
    }

    $users = @(Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue)
    foreach ($user in $users) {
        if ($user.Name -in @('Public', 'Default', 'Default User', 'All Users')) { continue }
        $ffRoot = Join-Path $user.FullName 'AppData\Roaming\Mozilla\Firefox\Profiles'
        if (-not (Test-Path -LiteralPath $ffRoot)) { continue }
        foreach ($profile in @(Get-ChildItem -LiteralPath $ffRoot -Directory -ErrorAction SilentlyContinue)) {
            $extensionsJson = Join-Path $profile.FullName 'extensions.json'
            if (-not (Test-Path -LiteralPath $extensionsJson)) { continue }
            try {
                $addonData = Get-Content -LiteralPath $extensionsJson -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                if (-not $addonData.PSObject.Properties['addons']) { continue }
                foreach ($addon in @($addonData.addons)) {
                    $addonId = if ($addon.PSObject.Properties['id']) { [string]$addon.id } else { '' }
                    $addonName = ''
                    $addonSummary = ''
                    if ($addon.PSObject.Properties['defaultLocale'] -and $addon.defaultLocale -and $addon.defaultLocale.PSObject.Properties['name']) {
                        $addonName = [string]$addon.defaultLocale.name
                    }
                    if ($addon.PSObject.Properties['description']) { $addonSummary = [string]$addon.description }
                    $inventory.Add([PSCustomObject]@{
                        Browser             = 'Firefox'
                        User                = $user.Name
                        Profile             = $profile.Name
                        ExtensionId         = $addonId
                        ExtensionName       = $addonName
                        ManifestDescription = $addonSummary
                        Location            = $extensionsJson
                    }) | Out-Null
                }
            } catch { }
        }
    }

    return @($inventory)
}

function Test-HijackSuspiciousExtension {
    param(
        [string]$ExtensionName,
        [string]$ExtensionId,
        [string]$Description
    )

    $blob = "$ExtensionName $Description $ExtensionId"
    foreach ($pattern in $Script:SuspiciousExtensionNamePatterns) {
        if ($blob -match $pattern) { return $true }
    }
    return $false
}

function Import-HijackStartupRiskModule {
    return [bool]$Script:HijackStartupRiskLoaded
}

$hijackHelperRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $MyInvocation.MyCommand.Path }
$startupRiskScript = Join-Path $hijackHelperRoot 'StartupRisk.ps1'
if (Test-Path -LiteralPath $startupRiskScript) {
    . $startupRiskScript
    $Script:HijackStartupRiskLoaded = $true
}

function Get-HijackBrowserShortcutProfiles {
    return @(
        @{ Label = 'Chrome'; NamePattern = '(?i)^(Google )?Chrome'; AppPathExe = 'chrome.exe'; PathFragment = 'Google\Chrome\Application' }
        @{ Label = 'Edge'; NamePattern = '(?i)^(Microsoft )?Edge'; AppPathExe = 'msedge.exe'; PathFragment = 'Microsoft\Edge\Application' }
        @{ Label = 'Firefox'; NamePattern = '(?i)^Mozilla Firefox'; AppPathExe = 'firefox.exe'; PathFragment = 'Mozilla Firefox' }
        @{ Label = 'Internet Explorer'; NamePattern = '(?i)^Internet Explorer'; AppPathExe = 'iexplore.exe'; PathFragment = 'Internet Explorer' }
    )
}

function Get-HijackBrowserShortcutSearchRoots {
    $roots = [System.Collections.Generic.List[string]]::new()
    $users = @(Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue)
    foreach ($user in $users) {
        if ($user.Name -in @('Public', 'Default', 'Default User', 'All Users')) { continue }
        foreach ($sub in @('Desktop', 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs')) {
            $path = Join-Path $user.FullName $sub
            if (Test-Path -LiteralPath $path) { $roots.Add($path) | Out-Null }
        }
    }

    $publicDesktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
    $commonStart = [Environment]::GetFolderPath('CommonPrograms')
    if ($publicDesktop -and (Test-Path -LiteralPath $publicDesktop)) { $roots.Add($publicDesktop) | Out-Null }
    if ($commonStart -and (Test-Path -LiteralPath $commonStart)) { $roots.Add($commonStart) | Out-Null }

    return @($roots | Select-Object -Unique)
}

function Get-HijackBrowserShortcutInventory {
    if (-not (Import-HijackStartupRiskModule)) { return @() }

    $inventory = [System.Collections.Generic.List[object]]::new()
    $profiles = @(Get-HijackBrowserShortcutProfiles)

    foreach ($root in (Get-HijackBrowserShortcutSearchRoots)) {
        $shortcuts = @(Get-ChildItem -LiteralPath $root -Filter '*.lnk' -File -ErrorAction SilentlyContinue)
        foreach ($shortcut in $shortcuts) {
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($shortcut.Name)
            $profile = $profiles | Where-Object { $baseName -match $_.NamePattern } | Select-Object -First 1
            if (-not $profile) { continue }

            $lnk = Get-LnkShortcutTarget -LnkPath $shortcut.FullName
            $inventory.Add([PSCustomObject]@{
                ShortcutPath = $shortcut.FullName
                BrowserLabel = [string]$profile.Label
                TargetPath   = [string]$lnk.TargetPath
                Arguments    = [string]$lnk.Arguments
                AppPathExe   = [string]$profile.AppPathExe
                PathFragment = [string]$profile.PathFragment
            }) | Out-Null
        }
    }

    return @($inventory)
}

function Test-HijackBrowserShortcutHijacked {
    param(
        [Parameter(Mandatory)][string]$BrowserLabel,
        [string]$TargetPath = '',
        [string]$Arguments = '',
        [string]$PathFragment = '',
        [string]$AppPathExe = ''
    )

    if ($TargetPath -match '(?i)\.(bat|cmd|vbs|vbe|js|jse|wsf|ps1|scr|com)(\s|$|\\)') {
        return $true
    }
    if (-not [string]::IsNullOrWhiteSpace($Arguments) -and (Test-HijackSuspiciousUrl -Url $Arguments)) {
        return $true
    }

    if ([string]::IsNullOrWhiteSpace($TargetPath)) { return $true }

    $normalized = $TargetPath.Replace('/', '\')
    if (-not [string]::IsNullOrWhiteSpace($PathFragment) -and $normalized -notmatch [regex]::Escape($PathFragment)) {
        if (-not [string]::IsNullOrWhiteSpace($AppPathExe) -and $normalized -notmatch [regex]::Escape($AppPathExe)) {
            return $true
        }
        if ([string]::IsNullOrWhiteSpace($AppPathExe)) { return $true }
    }

    if (-not [string]::IsNullOrWhiteSpace($AppPathExe) -and $normalized -notmatch [regex]::Escape($AppPathExe)) {
        return $true
    }

    return $false
}

function Repair-HijackBrowserShortcut {
    param(
        [Parameter(Mandatory)][string]$ShortcutPath,
        [Parameter(Mandatory)][string]$BrowserLabel
    )

    $details = [System.Collections.Generic.List[string]]::new()
    if (-not (Import-HijackStartupRiskModule)) {
        return @{ Changed = $false; Details = @('Startup helpers unavailable.') }
    }
    if (-not (Test-Path -LiteralPath $ShortcutPath)) {
        return @{ Changed = $false; Details = @("Shortcut not found: $ShortcutPath") }
    }

    $profile = @(Get-HijackBrowserShortcutProfiles) | Where-Object { $_.Label -eq $BrowserLabel } | Select-Object -First 1
    if (-not $profile) {
        return @{ Changed = $false; Details = @("Unknown browser label: $BrowserLabel") }
    }

    $expectedPath = Find-StartupExecutableAppPaths -ExeName $profile.AppPathExe
    if ([string]::IsNullOrWhiteSpace($expectedPath) -or -not (Test-Path -LiteralPath $expectedPath)) {
        return @{ Changed = $false; Details = @("Could not resolve default path for $($profile.AppPathExe).") }
    }

    $backupRoot = Get-HijackBackupRoot
    $safeName = ([System.IO.Path]::GetFileName($ShortcutPath) -replace '[^\w\-.]+', '_')
    $backupFile = Join-Path $backupRoot "lnk_${safeName}_$(Get-Date -Format 'yyyyMMdd_HHmmss').lnk"
    try {
        Copy-Item -LiteralPath $ShortcutPath -Destination $backupFile -Force -ErrorAction Stop
        $details.Add("Backup: $backupFile") | Out-Null
    } catch {
        return @{ Changed = $false; Details = @("Backup failed: $($_.Exception.Message)") }
    }

    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($ShortcutPath)
        $shortcut.TargetPath = $expectedPath
        $shortcut.Arguments = ''
        $shortcut.WorkingDirectory = Split-Path $expectedPath -Parent
        $shortcut.Save()
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
        $details.Add("Reset target to $expectedPath") | Out-Null
        return @{ Changed = $true; Details = @($details) }
    } catch {
        return @{ Changed = $false; Details = @("Shortcut repair failed: $($_.Exception.Message)") }
    }
}

function Repair-HijackWinlogonValue {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Userinit', 'Shell')]
        [string]$ValueName
    )

    if (-not (Import-HijackStartupRiskModule)) {
        return @{ Status = 'Warn'; Details = @('Startup helpers unavailable.') }
    }
    if ($env:OFFLINE_WINDOWS_ROOT) {
        return @{ Status = 'Warn'; Details = @('Winlogon reset is not supported in offline registry mode.') }
    }

    $ctx = Get-WinlogonRegistryContext
    $currentValue = Get-WinlogonRegistryValueText -Path $ctx.PsPath -Name $ValueName
    $deviation = Test-WinlogonValueDeviation -ValueName $ValueName -CurrentValue $currentValue
    if (-not $deviation.IsDeviated) {
        return @{ Status = 'Warn'; Details = @("No confirmed deviation for $ValueName.") }
    }

    $defaultValue = Get-WinlogonDefaultValue -ValueName $ValueName
    $backup = [PSCustomObject]@{
        valueName      = $ValueName
        registryPath   = $ctx.RegistryPath
        previousValue  = $currentValue
        resetToDefault = $defaultValue
        backedUpAt     = (Get-Date).ToString('o')
        machineName    = $env:COMPUTERNAME
    }

    $backupPath = Get-WinlogonBackupFilePath -ValueName $ValueName
    try {
        $backup | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $backupPath -Encoding UTF8 -Force
        Set-WinlogonRegistryProperty -Path $ctx.PsPath -ValueName $ValueName -Value $defaultValue
        $verify = Get-WinlogonRegistryValueText -Path $ctx.PsPath -Name $ValueName
        if (-not (Test-WinlogonValueMatchesDefault -ValueName $ValueName -CurrentValue $verify)) {
            return @{ Status = 'Warn'; Details = @("Reset verification failed for $ValueName.") }
        }
        return @{
            Status  = 'Pass'
            Details = @(
                "Restored Winlogon $ValueName to default.",
                "Backup: $backupPath"
            )
        }
    } catch {
        return @{ Status = 'Warn'; Details = @($_.Exception.Message) }
    }
}

$FindingsScript = Join-Path $hijackHelperRoot 'HijackRepairFindings.ps1'
if (Test-Path -LiteralPath $FindingsScript) { . $FindingsScript }
