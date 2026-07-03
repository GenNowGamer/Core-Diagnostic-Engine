#Requires -Version 5.1
param(
    [string]$Action = 'List',
    [string]$UninstallKey = '',
    [string]$UninstallStr = '',
    [switch]$ElevatedRelay
)

$ErrorActionPreference = if ($Action -eq 'List') { 'SilentlyContinue' } else { 'Stop' }

$Script:UninstallManagerScriptPath = $MyInvocation.MyCommand.Path
$ScriptDir = Split-Path $Script:UninstallManagerScriptPath
$ElevationModule = Join-Path $ScriptDir '..\Core\Toolkit.Elevation.psm1'
Import-Module $ElevationModule -Force -DisableNameChecking

function Get-UninstallManagerRelayArgumentString {
    $parts = [System.Collections.Generic.List[string]]::new()
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'Action' -Value $Action
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'ElevatedRelay' -IsSwitch
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'UninstallKey' -Value $UninstallKey
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'UninstallStr' -Value $UninstallStr
    return Join-ToolkitRelayArgumentString -Parts $parts
}

function Test-UninstallKeyRequiresElevation {
    param([string]$Key)

    if ([string]::IsNullOrWhiteSpace($Key)) { return $false }
    return ($Key -match '(?i)(?:^HKLM:|\\HKEY_LOCAL_MACHINE\\|Registry::HKEY_LOCAL_MACHINE)')
}

function Invoke-UninstallManagerElevationRelay {
    if ($ElevatedRelay) { return $false }
    if ($Action -ne 'ForceRemove') { return $false }
    if (-not (Test-UninstallKeyRequiresElevation -Key $UninstallKey)) { return $false }
    return (Invoke-ToolkitWorkflowElevationRelay -ScriptPath $Script:UninstallManagerScriptPath `
        -ArgumentString (Get-UninstallManagerRelayArgumentString) -ElevatedRelay:$ElevatedRelay)
}

if (Invoke-UninstallManagerElevationRelay) { exit 0 }

function Format-SizeHuman {
    param([Parameter(Mandatory)][long]$Bytes)

    if ($Bytes -lt 0) { $Bytes = 0 }

    $units = @('B', 'KB', 'MB', 'GB', 'TB')
    $value = [double]$Bytes
    $unitIndex = 0
    while ($value -ge 1024 -and $unitIndex -lt ($units.Count - 1)) {
        $value /= 1024
        $unitIndex++
    }

    $decimals = if ($unitIndex -le 1) { 0 } else { 1 }
    return ('{0:N' + $decimals + '} {1}') -f $value, $units[$unitIndex]
}

function Get-InstalledPrograms {
    $regPaths = @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; Arch = 'x64' },
        @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Arch = 'x86' },
        @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; Arch = 'x64' }
    )

    $programs = [System.Collections.Generic.List[object]]::new()

    foreach ($reg in $regPaths) {
        if (Test-Path $reg.Path) {
            Get-ChildItem $reg.Path -ErrorAction SilentlyContinue | ForEach-Object {
                $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                if ($props -and $props.DisplayName) {
                    $sizeDisplay = ''
                    if ($props.EstimatedSize) {
                        $bytes = [long]$props.EstimatedSize * 1KB
                        $sizeDisplay = Format-SizeHuman -Bytes $bytes
                    }
                    $programs.Add([PSCustomObject]@{
                        Name         = $props.DisplayName
                        Publisher    = if ($props.Publisher)    { $props.Publisher }    else { '' }
                        Version      = if ($props.DisplayVersion) { $props.DisplayVersion } else { '' }
                        InstallDate  = if ($props.InstallDate)  { $props.InstallDate }  else { '' }
                        SizeDisplay  = $sizeDisplay
                        UninstallKey = $_.PSPath
                        UninstallStr = if ($props.UninstallString) { $props.UninstallString } else { '' }
                        Arch         = $reg.Arch
                    })
                }
            }
        }
    }

    $programs | Sort-Object Name | ConvertTo-Json -Depth 2
}

switch ($Action) {
    'List' { Get-InstalledPrograms }
    'Uninstall' {
        if ($UninstallStr) {
            $cmd = $UninstallStr.Trim()
            $exe = $null
            $args = ''

            if ($cmd -match '^\s*"(?<exe>[^"]+)"\s*(?<args>.*)$') {
                $exe = $matches['exe']
                $args = $matches['args']
            } elseif ($cmd -match '^\s*(?<exe>\S+)\s*(?<args>.*)$') {
                $exe = $matches['exe']
                $args = $matches['args']
            }

            if (-not $exe) {
                Write-Error "Unable to parse uninstall command: $UninstallStr"
                break
            }

            Start-Process -FilePath $exe -ArgumentList $args -Wait -ErrorAction SilentlyContinue
            Write-Output "Uninstaller launched"
        }
    }
    'ForceRemove' {
        if ($UninstallKey) {
            Remove-Item $UninstallKey -Recurse -Force -ErrorAction SilentlyContinue
            Write-Output "Registry key removed: $UninstallKey"
        }
    }
}
