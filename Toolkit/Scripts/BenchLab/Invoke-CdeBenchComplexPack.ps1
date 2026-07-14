#Requires -Version 5.1
<#
.SYNOPSIS
    Complex multi-infection safe-only BenchLab pack (harder than S01-S24).
.DESCRIPTION
    Each scenario plants several infection *types* at once: content-scan markers
    (inert script text that matches CST YaraLike needles), persistence, hijacks,
    and decoy noise. Nothing downloads, encodes, or executes attack payloads.

    Use only on isolated lab VMs. Inject requires -SafeOnly.

.EXAMPLES
    .\Invoke-CdeBenchComplexPack.ps1 -Action List
    .\Invoke-CdeBenchComplexPack.ps1 -Action Inject -ScenarioId C03 -SafeOnly
    .\Invoke-CdeBenchComplexPack.ps1 -Action Cleanup -ScenarioId ALL
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('List', 'Inject', 'Cleanup')]
    [string]$Action,

    [string]$ScenarioId = 'ALL',

    [switch]$SafeOnly
)

$ErrorActionPreference = 'Stop'

$script:BenchTag = 'CDEBENCHX'
$script:BenchRoot = Join-Path $env:ProgramData 'CDE\BenchLab'
$script:BenchStateRoot = Join-Path $script:BenchRoot 'state\complex'
$script:BenchArtifactRoot = Join-Path $script:BenchRoot 'artifacts\complex'

# Realistic-looking vendor decoy roots (still tracked in state for cleanup).
$script:VendorRoots = @{
    AppSupport   = (Join-Path $env:LOCALAPPDATA 'AppSupport\UpdateService')
    Telemetry    = (Join-Path $env:APPDATA 'TelemetryHost\worker')
    CacheVendor  = (Join-Path $env:ProgramData 'VendorCache\Runtime')
    PublicHidden = (Join-Path $env:PUBLIC 'Documents\.cache')
}

$script:ScenarioMap = [ordered]@{
    C01 = 'Campaign: content drop + Run + Startup + hosts (4 types, 1 decoy cluster)'
    C02 = 'Campaign: dual script IOCs + task + proxy/PAC + Edge hijack'
    C03 = 'Campaign: LOLBin script markers + remote-tool mask + broken Run red herring'
    C04 = 'Campaign: buried hits in noise corpus + multi-persistence chain'
    C05 = 'Campaign: layered AppData nest + RunOnce/Run/Startup/Task + Defender-drift key'
    C06 = 'Campaign: Public/Downloads split + bitsadmin/mshta/regsvr markers + service'
    C07 = 'Campaign: correlated family - same marker family across 6 locations + uninstall mask'
    C08 = 'Campaign: full kitchen-sink (content + persistence + network + browser + noise)'
}

function Write-Info([string]$Message) { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-WarnLine([string]$Message) { Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-PassLine([string]$Message) { Write-Host "[OK]   $Message" -ForegroundColor Green }

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
    ($State | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath (Get-ScenarioStatePath $Id) -Encoding UTF8
}

function Get-ScenarioState([string]$Id) {
    $path = Get-ScenarioStatePath $Id
    if (-not (Test-Path -LiteralPath $path)) { return @{} }
    try { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable) }
    catch { return @{} }
}

function Remove-ScenarioState([string]$Id) {
    $path = Get-ScenarioStatePath $Id
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function New-DirectoryForFile([string]$Path) {
    $dir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
}

function Write-InertFile([string]$Path, [string]$Content) {
    New-DirectoryForFile $Path
    Set-Content -LiteralPath $Path -Value $Content -Encoding ASCII
}

function Add-TrackedFile([hashtable]$State, [string]$Path) {
    if (-not $State.ContainsKey('Files')) { $State.Files = @() }
    $State.Files = @($State.Files) + @($Path)
}

function Add-TrackedPath([hashtable]$State, [string]$Path) {
    if (-not $State.ContainsKey('Paths')) { $State.Paths = @() }
    $State.Paths = @($State.Paths) + @($Path)
}

function Set-RegistryBackup {
    param([string]$HivePath, [string]$Name, [hashtable]$State, [string]$StateKey)
    $exists = $false
    $value = $null
    $kind = ''
    try {
        $item = Get-ItemProperty -Path $HivePath -Name $Name -ErrorAction Stop
        $exists = $true
        $value = $item.$Name
        $kind = (Get-Item -LiteralPath $HivePath).GetValueKind($Name).ToString()
    } catch { $exists = $false }

    $State[$StateKey] = @{
        Exists = $exists
        Value  = $value
        Kind   = $kind
        Path   = $HivePath
        Name   = $Name
    }
}

function Restore-RegistryBackup {
    param([hashtable]$Backup)
    if ($null -eq $Backup -or -not $Backup.ContainsKey('Path')) { return }
    $path = [string]$Backup.Path
    $name = [string]$Backup.Name
    if ([bool]$Backup.Exists) {
        $kind = [string]$Backup.Kind
        if ([string]::IsNullOrWhiteSpace($kind)) { $kind = 'String' }
        New-Item -Path $path -Force | Out-Null
        Set-ItemProperty -Path $path -Name $name -Value $Backup.Value -Type $kind -Force
    } else {
        try { Remove-ItemProperty -Path $path -Name $name -ErrorAction Stop } catch { }
    }
}

# --- Inert CST content markers (comments only; exit immediately if run) ---

function Get-Marker_IwrEnc {
    param([string]$Campaign)
    @"
# SAFE_SIMULATION campaign=$Campaign
# Inert CST YaraLike needles (PS_Download_And_Encoded_Exec). No network calls.
# invoke-webrequest
# -enc
Write-Output 'SAFE_SIMULATION'
exit 0
"@
}

function Get-Marker_WebClientIex {
    param([string]$Campaign)
    @"
# SAFE_SIMULATION campaign=$Campaign
# Inert CST needles (PS_WebClient_IEX). Strings only — not executed.
# new-object net.webclient
# iex
Write-Output 'SAFE_SIMULATION'
exit 0
"@
}

function Get-Marker_FromBase64Iex {
    param([string]$Campaign)
    @"
# SAFE_SIMULATION campaign=$Campaign
# Inert CST needles (PS_FromBase64_IEX).
# [convert]::frombase64string
# iex
Write-Output 'SAFE_SIMULATION'
exit 0
"@
}

function Get-Marker_DownloadStringIex {
    param([string]$Campaign)
    @"
# SAFE_SIMULATION campaign=$Campaign
# Inert CST needles (PS_DownloadString_IEX).
# downloadstring
# iex
Write-Output 'SAFE_SIMULATION'
exit 0
"@
}

function Get-Marker_HiddenEnc {
    param([string]$Campaign)
    @"
# SAFE_SIMULATION campaign=$Campaign
# Inert CST needles (PS_HiddenWindow_Encoded).
# powershell
# -windowstyle hidden
# -enc
Write-Output 'SAFE_SIMULATION'
exit 0
"@
}

function Get-Marker_Certutil {
    param([string]$Campaign)
    @"
@echo off
REM SAFE_SIMULATION campaign=$Campaign
REM Inert CST needles (LOLBin_Certutil_Download).
REM certutil
REM -urlcache
echo SAFE_SIMULATION
exit /b 0
"@
}

function Get-Marker_Mshta {
    param([string]$Campaign)
    @"
@echo off
REM SAFE_SIMULATION campaign=$Campaign
REM Inert CST needles (LOLBin_Mshta_Remote).
REM mshta
REM http
echo SAFE_SIMULATION
exit /b 0
"@
}

function Get-Marker_Regsvr {
    param([string]$Campaign)
    @"
@echo off
REM SAFE_SIMULATION campaign=$Campaign
REM Inert CST needles (LOLBin_Regsvr32_Scrobj).
REM regsvr32
REM scrobj
echo SAFE_SIMULATION
exit /b 0
"@
}

function Get-Marker_Bitsadmin {
    param([string]$Campaign)
    @"
@echo off
REM SAFE_SIMULATION campaign=$Campaign
REM Inert CST needles (LOLBin_Bitsadmin_Transfer).
REM bitsadmin
REM /transfer
echo SAFE_SIMULATION
exit /b 0
"@
}

function Get-Marker_PowershellNop {
    param([string]$Campaign)
    @"
# SAFE_SIMULATION campaign=$Campaign
# Inert CST needles (Script_HighRisk_Path_Execution_Chain) — needs AppData Temp/Roaming path.
# powershell -nop
Write-Output 'SAFE_SIMULATION'
exit 0
"@
}

function Get-InertCmd {
    "@echo off`r`nREM SAFE_SIMULATION inert launcher`r`nexit /b 0"
}

function New-DecoyNoise {
    param(
        [string]$Root,
        [int]$Count,
        [hashtable]$State,
        [int]$PlantHitAt = -1,
        [string]$HitName = '',
        [string]$HitContent = ''
    )
    New-Item -Path $Root -ItemType Directory -Force | Out-Null
    Add-TrackedPath $State $Root
    1..$Count | ForEach-Object {
        $isHit = ($PlantHitAt -eq $_)
        if ($isHit -and $HitName -and $HitContent) {
            $p = Join-Path $Root $HitName
            Write-InertFile $p $HitContent
            Add-TrackedFile $State $p
        } else {
            $p = Join-Path $Root ("cache_{0:D4}.txt" -f $_)
            Write-InertFile $p ("vendor cache metadata $_ SAFE_SIMULATION")
            Add-TrackedFile $State $p
        }
    }
}

function Set-RunValue {
    param([hashtable]$State, [string]$BackupKey, [string]$Name, [string]$Value)
    $runPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    Set-RegistryBackup -HivePath $runPath -Name $Name -State $State -StateKey $BackupKey
    New-Item -Path $runPath -Force | Out-Null
    Set-ItemProperty -Path $runPath -Name $Name -Value $Value -Type String -Force
}

function Set-RunOnceValue {
    param([hashtable]$State, [string]$BackupKey, [string]$Name, [string]$Value)
    $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    Set-RegistryBackup -HivePath $path -Name $Name -State $State -StateKey $BackupKey
    New-Item -Path $path -Force | Out-Null
    Set-ItemProperty -Path $path -Name $Name -Value $Value -Type String -Force
}

function New-LogonTask {
    param([string]$TaskName, [string]$Command)
    schtasks /Create /TN $TaskName /SC ONLOGON /TR $Command /F | Out-Null
}

function Remove-LogonTask([string]$TaskName) {
    schtasks /Delete /TN $TaskName /F 2>$null | Out-Null
}

function Inject-HostsBlock {
    param([hashtable]$State, [string]$Campaign, [string[]]$Lines)
    if (-not (Test-IsAdmin)) {
        Write-WarnLine "$Campaign hosts injection skipped (admin required)."
        return
    }
    $hosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $backup = Join-Path $script:BenchArtifactRoot ("{0}_hosts_backup.txt" -f $Campaign)
    Copy-Item -LiteralPath $hosts -Destination $backup -Force
    $State.HostsBackup = $backup
    $begin = "# ${script:BenchTag}_${Campaign}_BEGIN"
    $end = "# ${script:BenchTag}_${Campaign}_END"
    $text = Get-Content -LiteralPath $hosts -Raw -ErrorAction Stop
    if ($text -notmatch [regex]::Escape($begin)) {
        $block = @($begin) + $Lines + @($end)
        Add-Content -LiteralPath $hosts -Value ("`r`n" + ($block -join "`r`n") + "`r`n")
    }
}

function Restore-HostsBlock {
    param([hashtable]$State)
    if (-not $State.ContainsKey('HostsBackup')) { return }
    $hosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    if (Test-Path -LiteralPath ([string]$State.HostsBackup)) {
        Copy-Item -LiteralPath $State.HostsBackup -Destination $hosts -Force
        Remove-Item -LiteralPath $State.HostsBackup -Force -ErrorAction SilentlyContinue
    }
}

function Clear-TrackedFiles([hashtable]$State) {
    if ($State.ContainsKey('Files')) {
        foreach ($f in @($State.Files)) {
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        }
    }
    if ($State.ContainsKey('Paths')) {
        foreach ($p in @($State.Paths)) {
            Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Clear-CommonPersistence([hashtable]$State) {
    if ($State.ContainsKey('Tasks')) {
        foreach ($t in @($State.Tasks)) { Remove-LogonTask $t }
    }
    if ($State.ContainsKey('Service')) {
        sc.exe delete ([string]$State.Service) | Out-Null
    }
    foreach ($key in @($State.Keys)) {
        if ($key -like '*Backup' -or $key -like 'Reg*') {
            try { Restore-RegistryBackup -Backup $State[$key] } catch { }
        }
    }
    if ($State.ContainsKey('UninstallPath')) {
        Remove-Item -LiteralPath ([string]$State.UninstallPath) -Recurse -Force -ErrorAction SilentlyContinue
    }
    Restore-HostsBlock -State $State
    Clear-TrackedFiles -State $State
}

# ===================== Scenarios =====================

function Invoke-C01 {
    param([string]$Mode)
    $id = 'C01'
    $downloads = [Environment]::GetFolderPath('UserProfile') + '\Downloads'
    $tempHit = Join-Path $env:TEMP 'OfficeSyncHelper.ps1'
    $runPayload = Join-Path $script:VendorRoots.Telemetry 'sync_worker.cmd'
    $startupDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
    $startupFile = Join-Path $startupDir 'UserProfileHealth.cmd'
    $decoyRoot = Join-Path $downloads 'AdobeCache'

    if ($Mode -eq 'Inject') {
        $state = @{}
        # Type 1: content IOC in Temp
        Write-InertFile $tempHit (Get-Marker_IwrEnc $id)
        Add-TrackedFile $state $tempHit
        # Type 2: Run persistence
        Write-InertFile $runPayload (Get-InertCmd)
        Add-TrackedFile $state $runPayload
        Add-TrackedPath $state $script:VendorRoots.Telemetry
        Set-RunValue $state 'RunBackup' 'OneDriveSyncHelper' ('"' + $runPayload + '"')
        # Type 3: Startup folder
        Write-InertFile $startupFile (Get-Marker_Mshta $id)
        Add-TrackedFile $state $startupFile
        # Type 4: hosts hijack
        Inject-HostsBlock $state $id @(
            '127.0.0.1 update.microsoft.com',
            '127.0.0.1 malware-test.invalid'
        )
        # Decoy noise in Downloads
        New-DecoyNoise -Root $decoyRoot -Count 40 -State $state
        Save-ScenarioState $id $state
        Write-PassLine "$id injected (content + Run + Startup + hosts + decoys)"
        return
    }

    Clear-CommonPersistence (Get-ScenarioState $id)
    Remove-ScenarioState $id
    Write-PassLine "$id cleaned"
}

function Invoke-C02 {
    param([string]$Mode)
    $id = 'C02'
    $hit1 = Join-Path $env:PUBLIC 'update_check.ps1'
    $hit2 = Join-Path $env:TEMP 'RuntimeBrokerHelper.ps1'
    $taskScript = Join-Path $script:VendorRoots.AppSupport 'healthcheck.cmd'
    $taskName = 'Microsoft\Windows\Maintenance\CacheHealth'
    $inet = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $edge = 'HKCU:\Software\Policies\Microsoft\Edge'

    if ($Mode -eq 'Inject') {
        $state = @{}
        Write-InertFile $hit1 (Get-Marker_WebClientIex $id)
        Write-InertFile $hit2 (Get-Marker_FromBase64Iex $id)
        Add-TrackedFile $state $hit1
        Add-TrackedFile $state $hit2

        Write-InertFile $taskScript (Get-InertCmd)
        Add-TrackedFile $state $taskScript
        Add-TrackedPath $state $script:VendorRoots.AppSupport
        New-LogonTask $taskName ('"' + $taskScript + '"')
        $state.Tasks = @($taskName)

        Set-RegistryBackup -HivePath $inet -Name 'ProxyEnable' -State $state -StateKey 'ProxyEnableBackup'
        Set-RegistryBackup -HivePath $inet -Name 'ProxyServer' -State $state -StateKey 'ProxyServerBackup'
        Set-RegistryBackup -HivePath $inet -Name 'AutoConfigURL' -State $state -StateKey 'AutoConfigURLBackup'
        New-Item -Path $inet -Force | Out-Null
        Set-ItemProperty -Path $inet -Name 'ProxyEnable' -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $inet -Name 'ProxyServer' -Value '127.0.0.1:3128' -Type String -Force
        Set-ItemProperty -Path $inet -Name 'AutoConfigURL' -Value 'http://127.0.0.1/vendor.pac' -Type String -Force

        Set-RegistryBackup -HivePath $edge -Name 'HomepageLocation' -State $state -StateKey 'EdgeHomeBackup'
        Set-RegistryBackup -HivePath $edge -Name 'RestoreOnStartup' -State $state -StateKey 'EdgeRestoreBackup'
        New-Item -Path $edge -Force | Out-Null
        Set-ItemProperty -Path $edge -Name 'HomepageLocation' -Value 'http://search.example.invalid/home' -Type String -Force
        Set-ItemProperty -Path $edge -Name 'RestoreOnStartup' -Value 4 -Type DWord -Force

        Save-ScenarioState $id $state
        Write-PassLine "$id injected (2 script IOCs + task + proxy/PAC + Edge)"
        return
    }

    Clear-CommonPersistence (Get-ScenarioState $id)
    Remove-ScenarioState $id
    Write-PassLine "$id cleaned"
}

function Invoke-C03 {
    param([string]$Mode)
    $id = 'C03'
    $downloads = [Environment]::GetFolderPath('UserProfile') + '\Downloads'
    $cert = Join-Path $env:TEMP 'cert_repair.cmd'
    $mshta = Join-Path $downloads 'help_launcher.cmd'
    $regsvr = Join-Path $env:TEMP 'com_register.cmd'
    $uninstall = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\SupportAssistPro'
    $runBroken = 'SupportAssistUpdater'
    $runRealName = 'SupportAssistCore'
    $realPayload = Join-Path $script:VendorRoots.CacheVendor 'core_agent.cmd'

    if ($Mode -eq 'Inject') {
        $state = @{}
        Write-InertFile $cert (Get-Marker_Certutil $id)
        Write-InertFile $mshta (Get-Marker_Mshta $id)
        Write-InertFile $regsvr (Get-Marker_Regsvr $id)
        Add-TrackedFile $state $cert
        Add-TrackedFile $state $mshta
        Add-TrackedFile $state $regsvr

        Write-InertFile $realPayload (Get-InertCmd)
        Add-TrackedFile $state $realPayload
        Add-TrackedPath $state $script:VendorRoots.CacheVendor
        Set-RunValue $state 'RunRealBackup' $runRealName ('"' + $realPayload + '"')
        # Red herring: broken Run pointing at missing binary
        Set-RunValue $state 'RunBrokenBackup' $runBroken '"C:\Program Files\SupportAssist\missing_agent.exe"'

        New-Item -Path $uninstall -Force | Out-Null
        Set-ItemProperty -Path $uninstall -Name 'DisplayName' -Value 'Support Assist Pro (Remote)' -Type String -Force
        Set-ItemProperty -Path $uninstall -Name 'Publisher' -Value 'Assist Labs LLC' -Type String -Force
        Set-ItemProperty -Path $uninstall -Name 'InstallLocation' -Value 'C:\Program Files\SupportAssist' -Type String -Force
        $state.UninstallPath = $uninstall

        Save-ScenarioState $id $state
        Write-PassLine "$id injected (3 LOLBin markers + real Run + broken Run + uninstall mask)"
        return
    }

    Clear-CommonPersistence (Get-ScenarioState $id)
    Remove-ScenarioState $id
    Write-PassLine "$id cleaned"
}

function Invoke-C04 {
    param([string]$Mode)
    $id = 'C04'
    $noiseRoot = Join-Path $script:VendorRoots.PublicHidden 'blob'
    $roamingHit = Join-Path $env:APPDATA 'Microsoft\Windows\Themes\theme_sync.ps1'
    $startupDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
    $startup = Join-Path $startupDir 'ThemeService.cmd'
    $taskName = 'Microsoft\Windows\Themes\ThemeMaintenance'
    $taskCmd = Join-Path $env:TEMP 'theme_maint.cmd'

    if ($Mode -eq 'Inject') {
        $state = @{}
        # Bury WebClient IOC inside ~180 decoy files
        New-DecoyNoise -Root $noiseRoot -Count 180 -State $state `
            -PlantHitAt 137 -HitName 'svc_bootstrap.ps1' -HitContent (Get-Marker_WebClientIex $id)

        # Second hit in Roaming (high-risk path for -nop rule)
        Write-InertFile $roamingHit (Get-Marker_PowershellNop $id)
        Add-TrackedFile $state $roamingHit

        Write-InertFile $startup (Get-Marker_Bitsadmin $id)
        Add-TrackedFile $state $startup

        Write-InertFile $taskCmd (Get-InertCmd)
        Add-TrackedFile $state $taskCmd
        New-LogonTask $taskName ('"' + $taskCmd + '"')
        $state.Tasks = @($taskName)

        Set-RunOnceValue $state 'RunOnceBackup' 'ThemeMigrate' ('"' + $taskCmd + '"')
        Set-RunValue $state 'RunBackup' 'ThemeHealth' ('"' + $startup + '"')

        Save-ScenarioState $id $state
        Write-PassLine "$id injected (buried IOC + Roaming marker + Startup + Task + Run/RunOnce)"
        return
    }

    Clear-CommonPersistence (Get-ScenarioState $id)
    Remove-ScenarioState $id
    Write-PassLine "$id cleaned"
}

function Invoke-C05 {
    param([string]$Mode)
    $id = 'C05'
    # Must stay under Local\Temp (or Public/Downloads/Startup) for CST YaraLike pathRegex.
    $deep = Join-Path $env:LOCALAPPDATA 'Temp\Microsoft.DesktopAppInstaller\.cache\stage'
    $hit = Join-Path $deep 'payload_stage.ps1'
    $cmd = Join-Path $deep 'stage_runner.cmd'
    $startupDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
    $startup = Join-Path $startupDir 'AppXBroker.cmd'
    $taskName = $script:BenchTag + '_C05_StageTask'
    $secPath = 'HKLM:\SOFTWARE\CDEBench\SecurityState'

    if ($Mode -eq 'Inject') {
        $state = @{}
        Write-InertFile $hit (Get-Marker_DownloadStringIex $id)
        Write-InertFile $cmd (Get-InertCmd)
        Write-InertFile $startup (Get-Marker_HiddenEnc $id)
        Add-TrackedFile $state $hit
        Add-TrackedFile $state $cmd
        Add-TrackedFile $state $startup
        Add-TrackedPath $state $deep

        Set-RunOnceValue $state 'RunOnceBackup' 'AppXStageOnce' ('"' + $cmd + '"')
        Set-RunValue $state 'RunBackup' 'AppXStagePersist' ('"' + $cmd + '"')
        New-LogonTask $taskName ('"' + $cmd + '"')
        $state.Tasks = @($taskName)

        if (Test-IsAdmin) {
            Set-RegistryBackup -HivePath $secPath -Name 'SimulatedDefenderDrift' -State $state -StateKey 'DefenderDriftBackup'
            New-Item -Path $secPath -Force | Out-Null
            Set-ItemProperty -Path $secPath -Name 'SimulatedDefenderDrift' -Value 1 -Type DWord -Force
        } else {
            Write-WarnLine "$id Defender-drift key skipped (admin required)."
        }

        Save-ScenarioState $id $state
        Write-PassLine "$id injected (nested AppData + RunOnce/Run/Startup/Task + optional Defender drift)"
        return
    }

    Clear-CommonPersistence (Get-ScenarioState $id)
    Remove-ScenarioState $id
    Write-PassLine "$id cleaned"
}

function Invoke-C06 {
    param([string]$Mode)
    $id = 'C06'
    $downloads = [Environment]::GetFolderPath('UserProfile') + '\Downloads'
    $bits = Join-Path $downloads 'job_transfer.cmd'
    $mshta = Join-Path $env:PUBLIC 'open_help.cmd'
    $regsvr = Join-Path $env:TEMP 'dll_host.cmd'
    $iwr = Join-Path $env:TEMP 'cfg_fetch.ps1'
    $svcName = $script:BenchTag + '_C06_CacheSvc'
    $runPayload = Join-Path $script:VendorRoots.CacheVendor 'svc_host.cmd'

    if ($Mode -eq 'Inject') {
        $state = @{}
        Write-InertFile $bits (Get-Marker_Bitsadmin $id)
        Write-InertFile $mshta (Get-Marker_Mshta $id)
        Write-InertFile $regsvr (Get-Marker_Regsvr $id)
        Write-InertFile $iwr (Get-Marker_IwrEnc $id)
        Add-TrackedFile $state $bits
        Add-TrackedFile $state $mshta
        Add-TrackedFile $state $regsvr
        Add-TrackedFile $state $iwr

        Write-InertFile $runPayload (Get-InertCmd)
        Add-TrackedFile $state $runPayload
        Add-TrackedPath $state $script:VendorRoots.CacheVendor
        Set-RunValue $state 'RunBackup' 'CacheHost' ('"' + $runPayload + '"')

        if (Test-IsAdmin) {
            sc.exe create $svcName binPath= "cmd.exe /c exit 0" start= demand DisplayName= "Vendor Cache Host" | Out-Null
            $state.Service = $svcName
        } else {
            Write-WarnLine "$id service skipped (admin required)."
        }

        Inject-HostsBlock $state $id @(
            '127.0.0.1 download.windowsupdate.com',
            '127.0.0.1 cdn.example.invalid'
        )

        Save-ScenarioState $id $state
        Write-PassLine "$id injected (4 content markers + Run + optional service + hosts)"
        return
    }

    Clear-CommonPersistence (Get-ScenarioState $id)
    Remove-ScenarioState $id
    Write-PassLine "$id cleaned"
}

function Invoke-C07 {
    param([string]$Mode)
    $id = 'C07'
    $family = 'NetUpdate'
    $downloads = [Environment]::GetFolderPath('UserProfile') + '\Downloads'
    $startupDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
    # All six content drops stay inside CST YaraLike pathRegex zones.
    $locations = @(
        (Join-Path $env:TEMP ("{0}_agent.ps1" -f $family)),
        (Join-Path $env:PUBLIC ("{0}_agent.ps1" -f $family)),
        (Join-Path $downloads ("{0}_agent.ps1" -f $family)),
        (Join-Path $env:LOCALAPPDATA ("Temp\NetUpdate\{0}_agent.ps1" -f $family)),
        (Join-Path $env:PUBLIC ("Documents\NetUpdate\{0}_agent.ps1" -f $family)),
        (Join-Path $startupDir ("{0}_agent.ps1" -f $family))
    )
    $uninstall = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\NetUpdateAgent'
    $taskName = 'Microsoft\Windows\NetUpdate\AgentHealth'
    $taskCmd = Join-Path $env:TEMP 'netupdate_health.cmd'

    if ($Mode -eq 'Inject') {
        $state = @{}
        $i = 0
        foreach ($loc in $locations) {
            $i++
            $content = switch ($i % 3) {
                1 { Get-Marker_WebClientIex $id }
                2 { Get-Marker_FromBase64Iex $id }
                default { Get-Marker_IwrEnc $id }
            }
            Write-InertFile $loc $content
            Add-TrackedFile $state $loc
        }
        Add-TrackedPath $state (Join-Path $env:LOCALAPPDATA 'Temp\NetUpdate')
        Add-TrackedPath $state (Join-Path $env:PUBLIC 'Documents\NetUpdate')

        Write-InertFile $taskCmd (Get-InertCmd)
        Add-TrackedFile $state $taskCmd
        New-LogonTask $taskName ('"' + $taskCmd + '"')
        $state.Tasks = @($taskName)
        Set-RunValue $state 'RunBackup' 'NetUpdateAgent' ('"' + $taskCmd + '"')

        New-Item -Path $uninstall -Force | Out-Null
        Set-ItemProperty -Path $uninstall -Name 'DisplayName' -Value 'NetUpdate Agent' -Type String -Force
        Set-ItemProperty -Path $uninstall -Name 'Publisher' -Value 'Network Update Inc' -Type String -Force
        $state.UninstallPath = $uninstall

        Save-ScenarioState $id $state
        Write-PassLine "$id injected (6 correlated content drops + task + Run + uninstall mask)"
        return
    }

    Clear-CommonPersistence (Get-ScenarioState $id)
    Remove-ScenarioState $id
    Write-PassLine "$id cleaned"
}

function Invoke-C08 {
    param([string]$Mode)
    $id = 'C08'
    $downloads = [Environment]::GetFolderPath('UserProfile') + '\Downloads'
    $noise = Join-Path $downloads 'SystemReports'
    $inet = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $edge = 'HKCU:\Software\Policies\Microsoft\Edge'
    $extRoot = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Default\Extensions\nupdthelper\2.4.1'
    $startupDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
    $items = @{
        Iwr     = (Join-Path $env:TEMP 'cfg_pull.ps1')
        Wc      = (Join-Path $env:PUBLIC 'svc_bootstrap.ps1')
        B64     = (Join-Path $downloads 'mail_preview.ps1')
        Hidden  = (Join-Path $env:TEMP 'silent_run.cmd')
        Bits    = (Join-Path $env:TEMP 'xfer.cmd')
        Cert    = (Join-Path $downloads 'cert_fix.cmd')
        Startup = (Join-Path $startupDir 'ReportUploader.cmd')
        RunFile = (Join-Path $script:VendorRoots.CacheVendor 'uploader.cmd')
    }
    $taskName = 'Microsoft\Windows\Reporting\DailyUpload'
    $svcName = $script:BenchTag + '_C08_UploadSvc'

    if ($Mode -eq 'Inject') {
        $state = @{}
        Write-InertFile $items.Iwr (Get-Marker_IwrEnc $id)
        Write-InertFile $items.Wc (Get-Marker_WebClientIex $id)
        Write-InertFile $items.B64 (Get-Marker_FromBase64Iex $id)
        Write-InertFile $items.Hidden (Get-Marker_HiddenEnc $id)
        Write-InertFile $items.Bits (Get-Marker_Bitsadmin $id)
        Write-InertFile $items.Cert (Get-Marker_Certutil $id)
        Write-InertFile $items.Startup (Get-Marker_Mshta $id)
        Write-InertFile $items.RunFile (Get-InertCmd)
        foreach ($p in $items.Values) { Add-TrackedFile $state $p }
        Add-TrackedPath $state $script:VendorRoots.CacheVendor

        New-DecoyNoise -Root $noise -Count 120 -State $state `
            -PlantHitAt 88 -HitName 'internal_probe.ps1' -HitContent (Get-Marker_DownloadStringIex $id)

        Set-RunValue $state 'RunBackup' 'ReportUploader' ('"' + $items.RunFile + '"')
        Set-RunOnceValue $state 'RunOnceBackup' 'ReportMigrate' ('"' + $items.RunFile + '"')
        New-LogonTask $taskName ('"' + $items.RunFile + '"')
        $state.Tasks = @($taskName)

        Set-RegistryBackup -HivePath $inet -Name 'ProxyEnable' -State $state -StateKey 'ProxyEnableBackup'
        Set-RegistryBackup -HivePath $inet -Name 'ProxyServer' -State $state -StateKey 'ProxyServerBackup'
        Set-RegistryBackup -HivePath $inet -Name 'AutoConfigURL' -State $state -StateKey 'AutoConfigURLBackup'
        New-Item -Path $inet -Force | Out-Null
        Set-ItemProperty -Path $inet -Name 'ProxyEnable' -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $inet -Name 'ProxyServer' -Value '127.0.0.1:8888' -Type String -Force
        Set-ItemProperty -Path $inet -Name 'AutoConfigURL' -Value 'http://127.0.0.1/reports.pac' -Type String -Force

        Set-RegistryBackup -HivePath $edge -Name 'HomepageLocation' -State $state -StateKey 'EdgeHomeBackup'
        New-Item -Path $edge -Force | Out-Null
        Set-ItemProperty -Path $edge -Name 'HomepageLocation' -Value 'http://reports.example.invalid' -Type String -Force

        New-Item -Path $extRoot -ItemType Directory -Force | Out-Null
        Write-InertFile (Join-Path $extRoot 'manifest.json') (@'
{
  "name": "Net Update Helper",
  "description": "SAFE_SIMULATION extension metadata",
  "version": "2.4.1",
  "manifest_version": 3
}
'@)
        Add-TrackedPath $state (Split-Path -Parent (Split-Path -Parent $extRoot))

        Inject-HostsBlock $state $id @(
            '127.0.0.1 update.microsoft.com',
            '127.0.0.1 telemetry.example.invalid',
            '127.0.0.1 login.live.com'
        )

        if (Test-IsAdmin) {
            sc.exe create $svcName binPath= "cmd.exe /c exit 0" start= demand DisplayName= "Report Upload Host" | Out-Null
            $state.Service = $svcName
        } else {
            Write-WarnLine "$id service skipped (admin required)."
        }

        Save-ScenarioState $id $state
        Write-PassLine "$id injected (kitchen-sink multi-type campaign)"
        return
    }

    Clear-CommonPersistence (Get-ScenarioState $id)
    Remove-ScenarioState $id
    Write-PassLine "$id cleaned"
}

function Invoke-Scenario {
    param([string]$Id, [string]$Mode)
    if (-not $script:ScenarioMap.Contains($Id)) { throw "Unknown scenario id: $Id" }
    Write-Info ("{0} - {1} [{2}]" -f $Id, $script:ScenarioMap[$Id], $Mode)
    switch ($Id) {
        'C01' { Invoke-C01 -Mode $Mode }
        'C02' { Invoke-C02 -Mode $Mode }
        'C03' { Invoke-C03 -Mode $Mode }
        'C04' { Invoke-C04 -Mode $Mode }
        'C05' { Invoke-C05 -Mode $Mode }
        'C06' { Invoke-C06 -Mode $Mode }
        'C07' { Invoke-C07 -Mode $Mode }
        'C08' { Invoke-C08 -Mode $Mode }
    }
}

Initialize-BenchFolders

if ($Action -eq 'List') {
    Write-Host 'CDE Complex Bench Scenarios (multi-infection, safe-only)' -ForegroundColor Cyan
    foreach ($k in $script:ScenarioMap.Keys) {
        Write-Host ("{0} - {1}" -f $k, $script:ScenarioMap[$k])
    }
    exit 0
}

if ($Action -eq 'Inject' -and -not $SafeOnly) {
    throw 'Inject action requires -SafeOnly acknowledgement. Isolated lab VMs only.'
}

$ids = @()
if ($ScenarioId -eq 'ALL') {
    $ids = @($script:ScenarioMap.Keys)
} else {
    $idNorm = $ScenarioId.ToUpperInvariant()
    if (-not $script:ScenarioMap.Contains($idNorm)) {
        throw "Invalid -ScenarioId '$ScenarioId'. Use -Action List."
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

Write-PassLine "Complex pack action '$Action' completed."
exit 0
