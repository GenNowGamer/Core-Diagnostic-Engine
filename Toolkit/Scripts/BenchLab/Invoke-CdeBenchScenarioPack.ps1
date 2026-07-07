#Requires -Version 5.1
<#
.SYNOPSIS
    Safe-only scenario injection and cleanup pack for CDE bench validation.
.DESCRIPTION
    Injects and cleans 24 simulation scenarios defined in BenchLab docs.
    No real malware execution is performed.

.EXAMPLES
    .\Invoke-CdeBenchScenarioPack.ps1 -Action List
    .\Invoke-CdeBenchScenarioPack.ps1 -Action Inject -ScenarioId ALL -SafeOnly
    .\Invoke-CdeBenchScenarioPack.ps1 -Action Cleanup -ScenarioId ALL
    .\Invoke-CdeBenchScenarioPack.ps1 -Action Inject -ScenarioId S18 -SafeOnly -OfflineSoftwareHivePath D:\Offline\Windows\System32\config\SOFTWARE
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('List','Inject','Cleanup')]
    [string]$Action,

    [string]$ScenarioId = 'ALL',

    [switch]$SafeOnly,

    [string]$OfflineWindowsRoot = '',
    [string]$OfflineSoftwareHivePath = ''
)

$ErrorActionPreference = 'Stop'

$script:BenchTag = 'CDEBENCH'
$script:BenchRoot = Join-Path $env:ProgramData 'CDE\BenchLab'
$script:BenchStateRoot = Join-Path $script:BenchRoot 'state'
$script:BenchArtifactRoot = Join-Path $script:BenchRoot 'artifacts'

$script:ScenarioMap = [ordered]@{
    S01 = 'Single marker drop in Downloads'
    S02 = 'Multi-path marker drop'
    S03 = 'Unsigned AppData Run key entry'
    S04 = 'Logon scheduled task persistence'
    S05 = 'Service ImagePath rogue binary (inert)'
    S06 = 'Startup folder script link'
    S07 = 'Hosts redirect injection'
    S08 = 'Proxy + PAC hijack simulation'
    S09 = 'Browser policy hijack keys'
    S10 = 'Suspicious browser extension metadata'
    S11 = 'Security tampering simulation'
    S12 = 'Remote access tooling exposure simulation'
    S13 = 'Broken autorun to missing binary'
    S14 = 'MSIX startup odd path/signature case simulation'
    S15 = 'Suspicious command-line style startup simulation'
    S16 = 'Script pattern marker simulation'
    S17 = 'Benign dev cache stress corpus'
    S18 = 'Offline hive startup persistence only'
    S19 = 'Offline scheduled task XML persistence'
    S20 = 'Malformed MBR signature fixture'
    S21 = 'Protective MBR and GPT mismatch fixture'
    S22 = 'Large mixed corpus runtime stability'
    S23 = 'Remediation rollback validation fixture'
    S24 = 'Repeatability run x5 (S01/S03/S06)'
}

function Write-Info([string]$Message) {
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-WarnLine([string]$Message) {
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-PassLine([string]$Message) {
    Write-Host "[OK]   $Message" -ForegroundColor Green
}

function Initialize-BenchFolders {
    New-Item -Path $script:BenchRoot -ItemType Directory -Force | Out-Null
    New-Item -Path $script:BenchStateRoot -ItemType Directory -Force | Out-Null
    New-Item -Path $script:BenchArtifactRoot -ItemType Directory -Force | Out-Null
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ScenarioStatePath([string]$Id) {
    return (Join-Path $script:BenchStateRoot ("{0}.json" -f $Id))
}

function Save-ScenarioState([string]$Id, [hashtable]$State) {
    $path = Get-ScenarioStatePath $Id
    ($State | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $path -Encoding UTF8
}

function Get-ScenarioState([string]$Id) {
    $path = Get-ScenarioStatePath $Id
    if (-not (Test-Path -LiteralPath $path)) {
        return @{}
    }
    try {
        return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable)
    } catch {
        return @{}
    }
}

function Remove-ScenarioState([string]$Id) {
    $path = Get-ScenarioStatePath $Id
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function Get-SimMarkerContent {
    param([string]$Scenario)
    return "CDE_BENCH_SIMULATION_MARKER:$Scenario"
}

function New-InertPlaceholderFile([string]$Path, [string]$Content) {
    $dir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
    Set-Content -LiteralPath $Path -Value $Content -Encoding ASCII
}

function Set-RegistryBackup {
    param(
        [string]$HivePath,
        [string]$Name,
        [hashtable]$State,
        [string]$StateKey
    )

    $exists = $false
    $value = $null
    $kind = ''

    try {
        $item = Get-ItemProperty -Path $HivePath -Name $Name -ErrorAction Stop
        $exists = $true
        $value = $item.$Name
        $kind = (Get-Item -LiteralPath $HivePath).GetValueKind($Name).ToString()
    } catch {
        $exists = $false
    }

    $State[$StateKey] = @{
        Exists = $exists
        Value = $value
        Kind = $kind
        Path = $HivePath
        Name = $Name
    }
}

function Restore-RegistryBackup {
    param(
        [hashtable]$Backup
    )

    if ($null -eq $Backup -or -not $Backup.ContainsKey('Path')) {
        return
    }

    $path = [string]$Backup.Path
    $name = [string]$Backup.Name
    $exists = [bool]$Backup.Exists

    if ($exists) {
        $kind = [string]$Backup.Kind
        if ([string]::IsNullOrWhiteSpace($kind)) { $kind = 'String' }
        New-Item -Path $path -Force | Out-Null
        Set-ItemProperty -Path $path -Name $name -Value $Backup.Value -Type $kind -Force
    } else {
        try { Remove-ItemProperty -Path $path -Name $name -ErrorAction Stop } catch { }
    }
}

function Invoke-S01 {
    param([string]$Mode)
    $id = 'S01'
    $downloads = [Environment]::GetFolderPath('UserProfile') + '\Downloads'
    $file = Join-Path $downloads ($script:BenchTag + '_S01_MARKER.txt')

    if ($Mode -eq 'Inject') {
        $state = @{}
        New-InertPlaceholderFile -Path $file -Content (Get-SimMarkerContent -Scenario $id)
        $state.Files = @($file)
        Save-ScenarioState $id $state
        Write-PassLine "$id injected: $file"
        return
    }

    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    Remove-ScenarioState $id
    Write-PassLine "$id cleaned"
}

function Invoke-S02 {
    param([string]$Mode)
    $id = 'S02'
    $targets = @(
        (Join-Path $env:TEMP ($script:BenchTag + '_S02_TEMP.txt')),
        (Join-Path $env:PUBLIC ($script:BenchTag + '_S02_PUBLIC.txt')),
        (Join-Path ([Environment]::GetFolderPath('Desktop')) ($script:BenchTag + '_S02_DESKTOP.txt'))
    )

    if ($Mode -eq 'Inject') {
        foreach ($f in $targets) {
            New-InertPlaceholderFile -Path $f -Content (Get-SimMarkerContent -Scenario $id)
        }
        Save-ScenarioState $id @{ Files = $targets }
        Write-PassLine "$id injected: $($targets.Count) files"
        return
    }

    foreach ($f in $targets) {
        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
    }
    Remove-ScenarioState $id
    Write-PassLine "$id cleaned"
}

function Invoke-S03 {
    param([string]$Mode)
    $id = 'S03'
    $dir = Join-Path $env:LOCALAPPDATA ($script:BenchTag + '\S03')
    $file = Join-Path $dir 'startup_inert.cmd'
    $runPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $runName = $script:BenchTag + '_S03_Run'

    if ($Mode -eq 'Inject') {
        $state = @{}
        Set-RegistryBackup -HivePath $runPath -Name $runName -State $state -StateKey 'RunBackup'
        New-InertPlaceholderFile -Path $file -Content '@echo off`r`nexit /b 0'
        New-Item -Path $runPath -Force | Out-Null
        Set-ItemProperty -Path $runPath -Name $runName -Value ('"' + $file + '"') -Type String -Force
        $state.Files = @($file)
        Save-ScenarioState $id $state
        Write-PassLine "$id injected"
        return
    }

    $state = Get-ScenarioState $id
    try { Restore-RegistryBackup -Backup $state.RunBackup } catch { }
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-ScenarioState $id
    Write-PassLine "$id cleaned"
}

function Invoke-S04 {
    param([string]$Mode)
    $id = 'S04'
    $taskName = $script:BenchTag + '_S04_LogonTask'
    $scriptFile = Join-Path $script:BenchArtifactRoot 'S04_task.cmd'

    if ($Mode -eq 'Inject') {
        New-InertPlaceholderFile -Path $scriptFile -Content '@echo off`r`nexit /b 0'
        schtasks /Create /TN $taskName /SC ONLOGON /TR ('"' + $scriptFile + '"') /F | Out-Null
        Save-ScenarioState $id @{ Task = $taskName; Files = @($scriptFile) }
        Write-PassLine "$id injected: task $taskName"
        return
    }

    schtasks /Delete /TN $taskName /F 2>$null | Out-Null
    Remove-Item -LiteralPath $scriptFile -Force -ErrorAction SilentlyContinue
    Remove-ScenarioState $id
    Write-PassLine "$id cleaned"
}

function Invoke-S05 {
    param([string]$Mode)
    $id = 'S05'
    $serviceName = $script:BenchTag + '_S05_Service'

    if (-not (Test-IsAdmin)) {
        Write-WarnLine "$id requires Administrator rights (service create/delete). Skipped."
        return
    }

    if ($Mode -eq 'Inject') {
        sc.exe create $serviceName binPath= "cmd.exe /c exit 0" start= demand DisplayName= "CDE Bench Inert Service" | Out-Null
        Save-ScenarioState $id @{ Service = $serviceName }
        Write-PassLine "$id injected: service $serviceName"
        return
    }

    sc.exe delete $serviceName | Out-Null
    Remove-ScenarioState $id
    Write-PassLine "$id cleaned"
}

function Invoke-S06 {
    param([string]$Mode)
    $id = 'S06'
    $startupDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
    $file = Join-Path $startupDir ($script:BenchTag + '_S06_Startup.cmd')

    if ($Mode -eq 'Inject') {
        New-InertPlaceholderFile -Path $file -Content '@echo off`r`nrem CDE bench startup simulation`r`nexit /b 0'
        Save-ScenarioState $id @{ Files = @($file) }
        Write-PassLine "$id injected"
        return
    }

    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    Remove-ScenarioState $id
    Write-PassLine "$id cleaned"
}

function Invoke-S07 {
    param([string]$Mode)
    $id = 'S07'
    $hosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $startMarker = '# CDEBENCH_S07_BEGIN'
    $endMarker = '# CDEBENCH_S07_END'
    $payload = @(
        $startMarker,
        '127.0.0.1 update.microsoft.com',
        '127.0.0.1 download.windowsupdate.com',
        $endMarker
    )

    if (-not (Test-IsAdmin)) {
        Write-WarnLine "$id requires Administrator rights (hosts file). Skipped."
        return
    }

    if ($Mode -eq 'Inject') {
        $state = @{}
        $backup = Join-Path $script:BenchArtifactRoot 'S07_hosts_backup.txt'
        Copy-Item -LiteralPath $hosts -Destination $backup -Force
        $state.HostsBackup = $backup

        $text = Get-Content -LiteralPath $hosts -Raw -ErrorAction Stop
        if ($text -notmatch [regex]::Escape($startMarker)) {
            Add-Content -LiteralPath $hosts -Value ("`r`n" + ($payload -join "`r`n") + "`r`n")
        }
        Save-ScenarioState $id $state
        Write-PassLine "$id injected"
        return
    }

    $state = Get-ScenarioState $id
    if ($state.ContainsKey('HostsBackup') -and (Test-Path -LiteralPath $state.HostsBackup)) {
        Copy-Item -LiteralPath $state.HostsBackup -Destination $hosts -Force
        Remove-Item -LiteralPath $state.HostsBackup -Force -ErrorAction SilentlyContinue
    } else {
        $lines = @(Get-Content -LiteralPath $hosts -ErrorAction SilentlyContinue)
        $out = New-Object System.Collections.Generic.List[string]
        $skip = $false
        foreach ($line in $lines) {
            if ($line -eq $startMarker) { $skip = $true; continue }
            if ($line -eq $endMarker) { $skip = $false; continue }
            if (-not $skip) { $out.Add($line) | Out-Null }
        }
        Set-Content -LiteralPath $hosts -Value $out -Encoding ASCII
    }
    Remove-ScenarioState $id
    Write-PassLine "$id cleaned"
}

function Invoke-S08 {
    param([string]$Mode)
    $id = 'S08'
    $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'

    if ($Mode -eq 'Inject') {
        $state = @{}
        Set-RegistryBackup -HivePath $path -Name 'ProxyEnable' -State $state -StateKey 'ProxyEnable'
        Set-RegistryBackup -HivePath $path -Name 'ProxyServer' -State $state -StateKey 'ProxyServer'
        Set-RegistryBackup -HivePath $path -Name 'AutoConfigURL' -State $state -StateKey 'AutoConfigURL'

        New-Item -Path $path -Force | Out-Null
        Set-ItemProperty -Path $path -Name 'ProxyEnable' -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $path -Name 'ProxyServer' -Value '127.0.0.1:8080' -Type String -Force
        Set-ItemProperty -Path $path -Name 'AutoConfigURL' -Value 'http://127.0.0.1/proxy.pac' -Type String -Force

        Save-ScenarioState $id $state
        Write-PassLine "$id injected"
        return
    }

    $state = Get-ScenarioState $id
    Restore-RegistryBackup -Backup $state.ProxyEnable
    Restore-RegistryBackup -Backup $state.ProxyServer
    Restore-RegistryBackup -Backup $state.AutoConfigURL
    Remove-ScenarioState $id
    Write-PassLine "$id cleaned"
}

function Invoke-S09 {
    param([string]$Mode)
    $id = 'S09'
    $path = 'HKCU:\Software\Policies\Microsoft\Edge'

    if ($Mode -eq 'Inject') {
        $state = @{}
        Set-RegistryBackup -HivePath $path -Name 'HomepageLocation' -State $state -StateKey 'HomepageLocation'
        Set-RegistryBackup -HivePath $path -Name 'RestoreOnStartup' -State $state -StateKey 'RestoreOnStartup'

        New-Item -Path $path -Force | Out-Null
        Set-ItemProperty -Path $path -Name 'HomepageLocation' -Value 'http://example.invalid/bench' -Type String -Force
        Set-ItemProperty -Path $path -Name 'RestoreOnStartup' -Value 4 -Type DWord -Force

        Save-ScenarioState $id $state
        Write-PassLine "$id injected"
        return
    }

    $state = Get-ScenarioState $id
    Restore-RegistryBackup -Backup $state.HomepageLocation
    Restore-RegistryBackup -Backup $state.RestoreOnStartup
    Remove-ScenarioState $id
    Write-PassLine "$id cleaned"
}

function Invoke-S10 {
    param([string]$Mode)
    $id = 'S10'
    $extRoot = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Default\Extensions\cdebenchs10\1.0.0'
    $manifest = Join-Path $extRoot 'manifest.json'

    if ($Mode -eq 'Inject') {
        New-Item -Path $extRoot -ItemType Directory -Force | Out-Null
        @'
{
  "name": "CDE Bench Extension Simulation",
  "description": "Safe simulation metadata for extension audit.",
  "version": "1.0.0",
  "manifest_version": 3
}
'@ | Set-Content -LiteralPath $manifest -Encoding UTF8
        Save-ScenarioState $id @{ Paths = @($extRoot) }
        Write-PassLine "$id injected"
        return
    }

    Remove-Item -LiteralPath (Split-Path -Parent (Split-Path -Parent $manifest)) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-ScenarioState $id
    Write-PassLine "$id cleaned"
}

function Invoke-S11 {
    param([string]$Mode)
    $id = 'S11'
    $path = 'HKLM:\SOFTWARE\CDEBench\SecurityState'

    if (-not (Test-IsAdmin)) {
        Write-WarnLine "$id requires Administrator rights (HKLM policy simulation). Skipped."
        return
    }

    if ($Mode -eq 'Inject') {
        $state = @{}
        Set-RegistryBackup -HivePath $path -Name 'SimulatedDefenderDrift' -State $state -StateKey 'SimulatedDefenderDrift'

        New-Item -Path $path -Force | Out-Null
        Set-ItemProperty -Path $path -Name 'SimulatedDefenderDrift' -Value 1 -Type DWord -Force

        Save-ScenarioState $id $state
        Write-PassLine "$id injected"
        return
    }

    $state = Get-ScenarioState $id
    Restore-RegistryBackup -Backup $state.SimulatedDefenderDrift
    Remove-ScenarioState $id
    Write-PassLine "$id cleaned"
}

function Invoke-S12 {
    param([string]$Mode)
    $id = 'S12'
    $uninstallPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\CDEBENCH_RemoteTool'
    $runPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $runName = $script:BenchTag + '_S12_RemoteAgent'

    if ($Mode -eq 'Inject') {
        $state = @{}
        Set-RegistryBackup -HivePath $runPath -Name $runName -State $state -StateKey 'RunBackup'

        New-Item -Path $uninstallPath -Force | Out-Null
        Set-ItemProperty -Path $uninstallPath -Name 'DisplayName' -Value 'Remote Assist Agent (Bench Simulation)' -Type String -Force
        Set-ItemProperty -Path $uninstallPath -Name 'Publisher' -Value 'CDE Bench Lab' -Type String -Force

        New-Item -Path $runPath -Force | Out-Null
        Set-ItemProperty -Path $runPath -Name $runName -Value '"C:\\Program Files\\RemoteAssist\\agent.exe" --silent' -Type String -Force

        Save-ScenarioState $id $state
        Write-PassLine "$id injected"
        return
    }

    Remove-Item -LiteralPath $uninstallPath -Recurse -Force -ErrorAction SilentlyContinue
    $state = Get-ScenarioState $id
    Restore-RegistryBackup -Backup $state.RunBackup
    Remove-ScenarioState $id
    Write-PassLine "$id cleaned"
}

function Invoke-S13 {
    param([string]$Mode)
    $id = 'S13'
    $runPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $runName = $script:BenchTag + '_S13_BrokenRun'

    if ($Mode -eq 'Inject') {
        $state = @{}
        Set-RegistryBackup -HivePath $runPath -Name $runName -State $state -StateKey 'RunBackup'
        New-Item -Path $runPath -Force | Out-Null
        Set-ItemProperty -Path $runPath -Name $runName -Value '"C:\\NoSuchPath\\missing.exe"' -Type String -Force
        Save-ScenarioState $id $state
        Write-PassLine "$id injected"
        return
    }

    $state = Get-ScenarioState $id
    Restore-RegistryBackup -Backup $state.RunBackup
    Remove-ScenarioState $id
    Write-PassLine "$id cleaned"
}

function Invoke-S14 {
    param([string]$Mode)
    $id = 'S14'
    $runPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $runName = $script:BenchTag + '_S14_MsixLike'

    if ($Mode -eq 'Inject') {
        $state = @{}
        Set-RegistryBackup -HivePath $runPath -Name $runName -State $state -StateKey 'RunBackup'
        New-Item -Path $runPath -Force | Out-Null
        Set-ItemProperty -Path $runPath -Name $runName -Value '"C:\\Program Files\\WindowsApps\\Fake.App_1.0.0_x64__8wekyb3d8bbwe\\FakeLauncher.exe"' -Type String -Force
        Save-ScenarioState $id $state
        Write-PassLine "$id injected"
        return
    }

    $state = Get-ScenarioState $id
    Restore-RegistryBackup -Backup $state.RunBackup
    Remove-ScenarioState $id
    Write-PassLine "$id cleaned"
}

function Invoke-S15 {
    param([string]$Mode)
    $id = 'S15'
    $runPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $runName = $script:BenchTag + '_S15_LolbinLike'

    if ($Mode -eq 'Inject') {
        $state = @{}
        Set-RegistryBackup -HivePath $runPath -Name $runName -State $state -StateKey 'RunBackup'
        New-Item -Path $runPath -Force | Out-Null
        Set-ItemProperty -Path $runPath -Name $runName -Value 'cmd.exe /c echo CDE_BENCH_SIM' -Type String -Force
        Save-ScenarioState $id $state
        Write-PassLine "$id injected"
        return
    }

    $state = Get-ScenarioState $id
    Restore-RegistryBackup -Backup $state.RunBackup
    Remove-ScenarioState $id
    Write-PassLine "$id cleaned"
}

function Invoke-S16 {
    param([string]$Mode)
    $id = 'S16'
    $dir = Join-Path $script:BenchArtifactRoot 'S16'
    $file = Join-Path $dir 'dropper_like.ps1'

    if ($Mode -eq 'Inject') {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
        @'
    # CDE bench pattern simulation
    # PATTERN_MARKER_DOWNLOAD_BEHAVIOR
    Write-Output "SAFE_SIMULATION"
    '@ | Set-Content -LiteralPath $file -Encoding UTF8
        Save-ScenarioState $id @{ Files = @($file) }
        Write-PassLine "$id injected"
        return
    }

    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-ScenarioState $id
    Write-PassLine "$id cleaned"
}

function Invoke-S17 {
    param([string]$Mode)
    $id = 'S17'
    $dir = Join-Path $script:BenchArtifactRoot 'S17_BenignCorpus'

    if ($Mode -eq 'Inject') {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
        1..300 | ForEach-Object {
            $p = Join-Path $dir ("benign_{0:D4}.txt" -f $_)
            Set-Content -LiteralPath $p -Value "CDE bench benign corpus line $_" -Encoding ASCII
        }
        Save-ScenarioState $id @{ Root = $dir; Count = 300 }
        Write-PassLine "$id injected: benign corpus created"
        return
    }

    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-ScenarioState $id
    Write-PassLine "$id cleaned"
}

function Invoke-S18 {
    param([string]$Mode)
    $id = 'S18'

    if ([string]::IsNullOrWhiteSpace($OfflineSoftwareHivePath) -or -not (Test-Path -LiteralPath $OfflineSoftwareHivePath)) {
        Write-WarnLine "$id requires -OfflineSoftwareHivePath for offline hive simulation. Skipped."
        return
    }

    $mount = 'HKLM\\CDEBENCH_OFFLINE_SOFTWARE'

    if ($Mode -eq 'Inject') {
        reg.exe load $mount "$OfflineSoftwareHivePath" | Out-Null
        reg.exe add ($mount + '\\Microsoft\\Windows\\CurrentVersion\\Run') /v CDEBENCH_S18_OfflineRun /t REG_SZ /d 'C:\\OfflineBench\\inert.exe' /f | Out-Null
        reg.exe unload $mount | Out-Null
        Save-ScenarioState $id @{ Hive = $OfflineSoftwareHivePath }
        Write-PassLine "$id injected"
        return
    }

    reg.exe load $mount "$OfflineSoftwareHivePath" | Out-Null
    reg.exe delete ($mount + '\\Microsoft\\Windows\\CurrentVersion\\Run') /v CDEBENCH_S18_OfflineRun /f 2>$null | Out-Null
    reg.exe unload $mount | Out-Null
    Remove-ScenarioState $id
    Write-PassLine "$id cleaned"
}

function Invoke-S19 {
    param([string]$Mode)
    $id = 'S19'

    if ([string]::IsNullOrWhiteSpace($OfflineWindowsRoot) -or -not (Test-Path -LiteralPath $OfflineWindowsRoot)) {
        Write-WarnLine "$id requires -OfflineWindowsRoot for offline task simulation. Skipped."
        return
    }

    $tasksDir = Join-Path $OfflineWindowsRoot 'System32\\Tasks\\CDEBench'
    $taskFile = Join-Path $tasksDir 'S19_OfflineTask'

    if ($Mode -eq 'Inject') {
        New-Item -Path $tasksDir -ItemType Directory -Force | Out-Null
        @'
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>CDE bench offline task simulation</Description></RegistrationInfo>
  <Triggers><LogonTrigger><Enabled>true</Enabled></LogonTrigger></Triggers>
  <Principals><Principal id="Author"><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
  <Settings><Enabled>true</Enabled></Settings>
  <Actions Context="Author"><Exec><Command>cmd.exe</Command><Arguments>/c exit 0</Arguments></Exec></Actions>
</Task>
'@ | Set-Content -LiteralPath $taskFile -Encoding Unicode
        Save-ScenarioState $id @{ File = $taskFile }
        Write-PassLine "$id injected"
        return
    }

    Remove-Item -LiteralPath $taskFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tasksDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-ScenarioState $id
    Write-PassLine "$id cleaned"
}

function Invoke-S20 {
    param([string]$Mode)
    $id = 'S20'
    $file = Join-Path $script:BenchArtifactRoot 'S20_malformed_mbr.bin'

    if ($Mode -eq 'Inject') {
        $bytes = New-Object byte[] 512
        $bytes[450] = 0xEE
        $bytes[510] = 0x00
        $bytes[511] = 0x00
        [System.IO.File]::WriteAllBytes($file, $bytes)
        Save-ScenarioState $id @{ File = $file }
        Write-PassLine "$id injected fixture created"
        return
    }

    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    Remove-ScenarioState $id
    Write-PassLine "$id cleaned"
}

function Invoke-S21 {
    param([string]$Mode)
    $id = 'S21'
    $mbrFile = Join-Path $script:BenchArtifactRoot 'S21_mbr.bin'
    $gptFile = Join-Path $script:BenchArtifactRoot 'S21_gpt.bin'

    if ($Mode -eq 'Inject') {
        $mbr = New-Object byte[] 512
        $mbr[450] = 0x07
        $mbr[510] = 0x55
        $mbr[511] = 0xAA

        $gpt = New-Object byte[] 512
        $sig = [System.Text.Encoding]::ASCII.GetBytes('EFI PART')
        [Array]::Copy($sig, 0, $gpt, 0, $sig.Length)

        [System.IO.File]::WriteAllBytes($mbrFile, $mbr)
        [System.IO.File]::WriteAllBytes($gptFile, $gpt)
        Save-ScenarioState $id @{ Files = @($mbrFile, $gptFile) }
        Write-PassLine "$id injected fixtures created"
        return
    }

    Remove-Item -LiteralPath $mbrFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $gptFile -Force -ErrorAction SilentlyContinue
    Remove-ScenarioState $id
    Write-PassLine "$id cleaned"
}

function Invoke-S22 {
    param([string]$Mode)
    $id = 'S22'
    $dir = Join-Path $script:BenchArtifactRoot 'S22_MixedCorpus'

    if ($Mode -eq 'Inject') {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
        1..1200 | ForEach-Object {
            $name = if ($_ % 10 -eq 0) { "mixed_{0:D4}.ps1" -f $_ } else { "mixed_{0:D4}.txt" -f $_ }
            $content = if ($name.EndsWith('.ps1')) { 'Write-Output "safe bench payload"' } else { "bench item $_" }
            Set-Content -LiteralPath (Join-Path $dir $name) -Value $content -Encoding ASCII
        }
        Save-ScenarioState $id @{ Root = $dir; Count = 1200 }
        Write-PassLine "$id injected"
        return
    }

    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-ScenarioState $id
    Write-PassLine "$id cleaned"
}

function Invoke-S23 {
    param([string]$Mode)
    $id = 'S23'
    $runPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $runName = $script:BenchTag + '_S23_Rollback'
    $file = Join-Path $script:BenchArtifactRoot 'S23_inert_payload.cmd'

    if ($Mode -eq 'Inject') {
        $state = @{}
        Set-RegistryBackup -HivePath $runPath -Name $runName -State $state -StateKey 'RunBackup'

        New-InertPlaceholderFile -Path $file -Content '@echo off`r`nexit /b 0'
        New-Item -Path $runPath -Force | Out-Null
        Set-ItemProperty -Path $runPath -Name $runName -Value ('"' + $file + '"') -Type String -Force

        Save-ScenarioState $id $state
        Write-PassLine "$id injected"
        return
    }

    $state = Get-ScenarioState $id
    Restore-RegistryBackup -Backup $state.RunBackup
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    Remove-ScenarioState $id
    Write-PassLine "$id cleaned"
}

function Invoke-S24 {
    param([string]$Mode)
    $id = 'S24'

    if ($Mode -eq 'Inject') {
        Write-Info "$id orchestrates repeatability for S01/S03/S06 (safe-only)."
        1..5 | ForEach-Object {
            Write-Info "$id pass $_/5 inject sequence"
            Invoke-S01 -Mode Inject
            Invoke-S03 -Mode Inject
            Invoke-S06 -Mode Inject
            Invoke-S06 -Mode Cleanup
            Invoke-S03 -Mode Cleanup
            Invoke-S01 -Mode Cleanup
        }
        Save-ScenarioState $id @{ CompletedPasses = 5; Notes = 'Repeatability orchestration completed.' }
        Write-PassLine "$id completed"
        return
    }

    Remove-ScenarioState $id
    Write-PassLine "$id cleaned (state only)"
}

function Invoke-Scenario {
    param(
        [string]$Id,
        [string]$Mode
    )

    if (-not $script:ScenarioMap.Contains($Id)) {
        throw "Unknown scenario id: $Id"
    }

    Write-Info ("{0} - {1} [{2}]" -f $Id, $script:ScenarioMap[$Id], $Mode)

    switch ($Id) {
        'S01' { Invoke-S01 -Mode $Mode }
        'S02' { Invoke-S02 -Mode $Mode }
        'S03' { Invoke-S03 -Mode $Mode }
        'S04' { Invoke-S04 -Mode $Mode }
        'S05' { Invoke-S05 -Mode $Mode }
        'S06' { Invoke-S06 -Mode $Mode }
        'S07' { Invoke-S07 -Mode $Mode }
        'S08' { Invoke-S08 -Mode $Mode }
        'S09' { Invoke-S09 -Mode $Mode }
        'S10' { Invoke-S10 -Mode $Mode }
        'S11' { Invoke-S11 -Mode $Mode }
        'S12' { Invoke-S12 -Mode $Mode }
        'S13' { Invoke-S13 -Mode $Mode }
        'S14' { Invoke-S14 -Mode $Mode }
        'S15' { Invoke-S15 -Mode $Mode }
        'S16' { Invoke-S16 -Mode $Mode }
        'S17' { Invoke-S17 -Mode $Mode }
        'S18' { Invoke-S18 -Mode $Mode }
        'S19' { Invoke-S19 -Mode $Mode }
        'S20' { Invoke-S20 -Mode $Mode }
        'S21' { Invoke-S21 -Mode $Mode }
        'S22' { Invoke-S22 -Mode $Mode }
        'S23' { Invoke-S23 -Mode $Mode }
        'S24' { Invoke-S24 -Mode $Mode }
    }
}

Initialize-BenchFolders

if ($Action -eq 'List') {
    Write-Host "CDE Bench Scenarios" -ForegroundColor Cyan
    foreach ($k in $script:ScenarioMap.Keys) {
        Write-Host ("{0} - {1}" -f $k, $script:ScenarioMap[$k])
    }
    exit 0
}

if ($Action -eq 'Inject' -and -not $SafeOnly) {
    throw 'Inject action requires -SafeOnly acknowledgement. This pack is safe-only and should be used in isolated test VMs.'
}

$ids = @()
if ($ScenarioId -eq 'ALL') {
    $ids = @($script:ScenarioMap.Keys)
} else {
    $idNorm = $ScenarioId.ToUpperInvariant()
    if (-not $script:ScenarioMap.Contains($idNorm)) {
        throw "Invalid -ScenarioId '$ScenarioId'. Use -Action List to view valid IDs."
    }
    $ids = @($idNorm)
}

if ($Action -eq 'Cleanup' -and $ScenarioId -eq 'ALL') {
    $ids = @($script:ScenarioMap.Keys | Sort-Object -Descending)
}

foreach ($id in $ids) {
    try {
        Invoke-Scenario -Id $id -Mode $Action
    } catch {
        Write-WarnLine ("{0} failed: {1}" -f $id, $_.Exception.Message)
    }
}

Write-PassLine "Scenario pack action '$Action' completed."
exit 0
