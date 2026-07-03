#Requires -Version 5.1
<#
.SYNOPSIS
    Disables the built-in Administrator account on an offline Windows install (disable-only).
    Requires WinPE with offline registry hives loaded (Offline_SAM).
    Sets ACB_DISABLED on SAM user_F at RID 500 — inverse of Enable Offline Administrator.
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

$workflow = Start-Workflow -WorkflowName 'DisableOfflineAdministrator' -ScriptBlock {
    param($r)
    Write-Log 'Disable Offline Administrator starting (disable-only).' -Level Info
    Write-Log 'This disables the built-in .\Administrator local account in offline SAM. It does not change passwords.' -Level Warning

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

    if ($beforeState.IsDisabled) {
        Write-Log 'Administrator is already disabled in offline SAM; applying disable bit again for consistency.' -Level Info
    }

    $result = Disable-OfflineBuiltInAdministrator
    Write-Log "Disabled account: $($result.AccountName) (RID $($result.RelativeId))" -Level Success
    Write-Log "Post-change ACB_bits=0x$('{0:X4}' -f $result.AcbBits)" -Level Success

    if (-not $result.IsDisabled) {
        throw "Verification failed: Administrator ACB_DISABLED is not set (ACB_bits=0x$('{0:X4}' -f $result.AcbBits))."
    }

    $unload = Start-Process -FilePath "$env:SystemRoot\System32\reg.exe" -ArgumentList @('unload', 'HKLM\Offline_SAM') -Wait -PassThru -NoNewWindow
    if ($unload.ExitCode -eq 0) {
        Write-Log 'Offline_SAM hive unloaded so changes are written to disk.' -Level Success
    } else {
        Write-Log 'Could not unload Offline_SAM; reboot from WinPE only after changes are saved.' -Level Warning
    }

    Write-Log 'Reboot into the installed Windows OS (not WinPE). .\Administrator will not be available for sign-in until enabled again.' -Level Info
    Write-Log 'To disable while Windows is running instead, use: net user administrator /active:no' -Level Info

    $stepOutput = "Built-in Administrator disabled (ACB_bits=0x$('{0:X4}' -f $result.AcbBits)). SAM backup: $backupPath"
    $r.Steps.Add([PSCustomObject]@{
        Name   = 'Disable Offline Administrator'
        Status = 'Pass'
        Output = $stepOutput
    })
}

Generate-Report -WorkflowResult $workflow | Out-Null
if ($workflow.Status -eq 'Failed') { exit 1 }
