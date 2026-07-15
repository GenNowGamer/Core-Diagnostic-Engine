#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$testsRoot = Split-Path $MyInvocation.MyCommand.Path
$coreDir = Join-Path $testsRoot '..\Core'
. (Join-Path $coreDir 'HijackRepairHelpers.ps1')

function Assert-True {
    param([string]$Name, [bool]$Condition)
    if (-not $Condition) {
        Write-Error "FAIL: $Name"
        exit 1
    }
    Write-Host "  PASS: $Name"
}

Assert-True -Name 'Suspicious extension name pattern' -Condition (
    (Test-HijackSuspiciousExtension -ExtensionName 'Super Search Manager' -ExtensionId 'abc' -Description '')
)
Assert-True -Name 'Benign extension name' -Condition (
    -not (Test-HijackSuspiciousExtension -ExtensionName 'Google Docs Offline' -ExtensionId 'ghbmnn' -Description 'Edit docs')
)
Assert-True -Name 'Suspicious URL detection' -Condition (
    (Test-HijackSuspiciousUrl -Url 'http://search-hijack.example.com')
)
Assert-True -Name 'Trusted URL not flagged' -Condition (
    -not (Test-HijackSuspiciousUrl -Url 'https://www.google.com')
)

Assert-True -Name 'Public DNS is benign' -Condition (
    (Test-HijackBenignDnsServer -Server '8.8.8.8')
)
Assert-True -Name 'Loopback DNS is benign' -Condition (
    (Test-HijackBenignDnsServer -Server '127.0.0.1')
)
Assert-True -Name 'Gateway DNS is benign' -Condition (
    (Test-HijackBenignDnsServer -Server '192.168.86.1' -Gateway '192.168.86.1')
)
Assert-True -Name 'Private DNS without gateway match is flagged' -Condition (
    -not (Test-HijackBenignDnsServer -Server '192.168.86.1' -Gateway '10.0.0.1')
)
Assert-True -Name 'Unknown DNS without gateway is flagged' -Condition (
    -not (Test-HijackBenignDnsServer -Server '203.0.113.53')
)

Assert-True -Name 'NRPT corp rule is benign' -Condition (
    (Test-HijackBenignNrptRule -RuleName 'Contoso.corp DNS Policy')
)
Assert-True -Name 'NRPT unknown rule is not benign' -Condition (
    -not (Test-HijackBenignNrptRule -RuleName 'ScamRedirectRule')
)
Assert-True -Name 'Suspicious browser policy URL' -Condition (
    (Test-HijackSuspiciousBrowserPolicyValue -PropertyName 'HomepageLocation' -Value 'http://evil-search.example')
)
Assert-True -Name 'Benign browser policy search name' -Condition (
    -not (Test-HijackSuspiciousBrowserPolicyValue -PropertyName 'DefaultSearchProviderName' -Value 'Google')
)
Assert-True -Name 'Enabled boolean policy is not search-heuristiced' -Condition (
    -not (Test-HijackSuspiciousBrowserPolicyValue -PropertyName 'DefaultSearchProviderEnabled' -Value '1')
)
Assert-True -Name 'Generic Enabled policy is not search-heuristiced' -Condition (
    -not (Test-HijackSuspiciousBrowserPolicyValue -PropertyName 'HomepageIsNewTabPageEnabled' -Value '0')
)
Assert-True -Name 'Internal proxy is not suspicious' -Condition (
    -not (Test-HijackSuspiciousProxySetting -Url 'http://192.168.1.1:8080/proxy.pac')
)
Assert-True -Name 'Firefox hijacked search engine' -Condition (
    (Test-HijackFirefoxPrefHijacked -PrefName 'browser.search.defaultenginename' -PrefValue 'EvilSearch')
)

Assert-True -Name 'Browser shortcut with script target is hijacked' -Condition (
    (Test-HijackBrowserShortcutHijacked -BrowserLabel 'Chrome' -TargetPath 'C:\Users\Public\evil.bat' -PathFragment 'Google\Chrome\Application' -AppPathExe 'chrome.exe')
)
Assert-True -Name 'Legitimate Chrome path is not hijacked' -Condition (
    -not (Test-HijackBrowserShortcutHijacked -BrowserLabel 'Chrome' -TargetPath 'C:\Program Files\Google\Chrome\Application\chrome.exe' -PathFragment 'Google\Chrome\Application' -AppPathExe 'chrome.exe')
)
Assert-True -Name 'Wrong browser exe path is hijacked' -Condition (
    (Test-HijackBrowserShortcutHijacked -BrowserLabel 'Edge' -TargetPath 'C:\Program Files\evil\launcher.exe' -PathFragment 'Microsoft\Edge\Application' -AppPathExe 'msedge.exe')
)

$f1 = New-HijackFinding -Category 'Browser' -Name 'Test' -Location 'HKCU:\Test' -CurrentValue 'x' -RepairAction 'browser.policy.remove' -RepairData @{ policyPath = 'HKCU:\Test'; propertyName = 'Homepage' }
$f2 = New-HijackFinding -Category 'Browser' -Name 'Test' -Location 'HKCU:\Test' -CurrentValue 'x' -RepairAction 'browser.policy.remove' -RepairData @{ policyPath = 'HKCU:\Test'; propertyName = 'Homepage' }
Assert-True -Name 'Finding id is stable' -Condition ($f1.id -eq $f2.id)

$f3 = New-HijackFinding -Category 'Browser' -Name 'Test' -Location 'HKCU:\Test' -CurrentValue 'before' -RepairAction 'browser.policy.remove' -RepairData @{ policyPath = 'HKCU:\Test'; propertyName = 'Homepage' }
$f4 = New-HijackFinding -Category 'Browser' -Name 'Test' -Location 'HKCU:\Test' -CurrentValue 'after' -RepairAction 'browser.policy.remove' -RepairData @{ policyPath = 'HKCU:\Test'; propertyName = 'Homepage' }
Assert-True -Name 'Finding id ignores volatile CurrentValue' -Condition ($f3.id -eq $f4.id)

$review1 = New-HijackFinding -Category 'Startup' -Name 'Foo (Run)' -Location 'Run' -CurrentValue 'cmd.exe [unsigned]' -Repairable $false -RepairAction ''
$review2 = New-HijackFinding -Category 'Startup' -Name 'Foo (Run)' -Location 'Run' -CurrentValue 'cmd.exe [target missing; unsigned]' -Repairable $false -RepairAction ''
Assert-True -Name 'Review-only id ignores volatile CurrentValue' -Condition ($review1.id -eq $review2.id)

$sample = @(
    (New-HijackFinding -Category 'Network' -Name 'DNS server on Wi-Fi' -Location 'InterfaceIndex 12' -CurrentValue '203.0.113.1' -RepairAction 'network.dns.reset' -RepairData @{ interfaceIndex = 12; interfaceAlias = 'Wi-Fi' })
)
$snapshotPath = Save-HijackScanSnapshot -Findings $sample
Assert-True -Name 'Snapshot file is written' -Condition (Test-Path -LiteralPath $snapshotPath)
$loaded = @(Get-HijackScanSnapshotFindings -SnapshotPath $snapshotPath)
Assert-True -Name 'Snapshot reload returns findings' -Condition ($loaded.Count -eq 1)
Assert-True -Name 'Snapshot preserves repair id' -Condition ([string]$loaded[0].id -eq [string]$sample[0].id)
Remove-Item -LiteralPath $snapshotPath -Force -ErrorAction SilentlyContinue

$all = @(Get-HijackStructuredFindings)
Assert-True -Name 'Structured scan returns array' -Condition ($null -ne $all)

Write-Host 'All HijackRepair helper tests passed.'
