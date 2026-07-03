#Requires -Version 5.1
<#
.SYNOPSIS
    Enables the built-in Administrator account on an offline Windows install (enable-only).
    Requires WinPE with offline registry hives loaded (Offline_SAM).
    Does not set or change passwords offline — sign in after reboot and set password in Windows.
#>

$ErrorActionPreference = 'Stop'

$ScriptDir   = Split-Path $MyInvocation.MyCommand.Path
$CoreModule  = Join-Path $ScriptDir '..\Core\Toolkit.Core.psm1'
$SamModule   = Join-Path $ScriptDir '..\Core\OfflineSamAccount.psm1'
Import-Module $CoreModule -Force -DisableNameChecking
Import-Module $SamModule -Force -DisableNameChecking

function Test-OfflineRecoveryReady {
    if ((Get-EnvironmentMode) -ne 'WinPE') {
        throw 'This tool must run in WinPE with the target Windows installation offline (not booted).'
    }
    if ($env:OFFLINE_REGISTRY_LOADED -ne '1') {
        throw 'Offline registry hives are not loaded. Boot CDE WinPE, choose option 2 to attach the offline Windows install, then retry.'
    }
    if (-not (Test-Path -LiteralPath 'HKLM:\Offline_SAM')) {
        throw 'Offline_SAM is not loaded. Re-run offline Windows attachment from WinPE startup.'
    }
    $root = Resolve-OfflineWindowsRoot
    if ([string]::IsNullOrWhiteSpace($root)) {
        $raw = $env:OFFLINE_WINDOWS_ROOT
        if ([string]::IsNullOrWhiteSpace($raw)) {
            $raw = Read-OfflineEnvValue -Key 'OFFLINE_WINDOWS_ROOT'
        }
        throw "OFFLINE_WINDOWS_ROOT is not set or invalid (raw='$raw'). Boot WinPE option 2 to attach the offline install, then retry."
    }
    return $root
}

$workflow = Start-Workflow -WorkflowName 'EnableOfflineAdministrator' -ScriptBlock {
    param($r)
    Write-Log 'Enable Offline Administrator starting (enable-only).' -Level Info
    Write-Log 'This enables the built-in .\Administrator local account. It does not set passwords offline or reset Microsoft account / Entra ID sign-in.' -Level Warning

    $offlineRoot = Test-OfflineRecoveryReady

    $userKey = Get-OfflineSamUserKeyPath -SamRegistryRoot 'HKLM:\Offline_SAM' -RelativeId 500
    if (-not (Test-Path -LiteralPath $userKey)) {
        throw "Built-in Administrator key not found at $userKey. Confirm Offline_SAM is loaded and the target OS has a standard local SAM."
    }
    Write-Log "Pre-flight OK: Administrator SAM key at $userKey" -Level Info

    $backupPath = Backup-OfflineSamHiveFile -OfflineWindowsRoot $offlineRoot
    Write-Log "SAM backup saved: $backupPath" -Level Success

    $beforeState = Test-OfflineSamAccountEnabled -UserKeyPath $userKey
    Write-Log "Pre-change ACB_bits=0x$('{0:X4}' -f $beforeState.AcbBits); disabled=$($beforeState.IsDisabled)" -Level Info

    $result = Enable-OfflineBuiltInAdministrator
    Write-Log "Enabled account: $($result.AccountName) (RID $($result.RelativeId))" -Level Success
    Write-Log "Post-change ACB_bits=0x$('{0:X4}' -f $result.AcbBits)" -Level Success

    if (-not $result.IsEnabled) {
        throw "Verification failed: Administrator ACB_DISABLED is still set (ACB_bits=0x$('{0:X4}' -f $result.AcbBits))."
    }

    $unload = Start-Process -FilePath "$env:SystemRoot\System32\reg.exe" -ArgumentList @('unload', 'HKLM\Offline_SAM') -Wait -PassThru -NoNewWindow
    if ($unload.ExitCode -eq 0) {
        Write-Log 'Offline_SAM hive unloaded so changes are written to disk.' -Level Success
    } else {
        Write-Log 'Could not unload Offline_SAM; reboot from WinPE only after changes are saved.' -Level Warning
    }

    Write-Log 'Reboot into the installed Windows OS (not WinPE) and sign in as .\Administrator.' -Level Info
    Write-Log 'Use the existing account password if one was set before, or a blank password on typical clean installs. Set or change the password in Windows after logon.' -Level Warning

    $stepOutput = "Built-in Administrator enabled (ACB_bits=0x$('{0:X4}' -f $result.AcbBits)). SAM backup: $backupPath"
    $r.Steps.Add([PSCustomObject]@{
        Name   = 'Enable Offline Administrator'
        Status = 'Pass'
        Output = $stepOutput
    })
}

Generate-Report -WorkflowResult $workflow | Out-Null
if ($workflow.Status -eq 'Failed') { exit 1 }
