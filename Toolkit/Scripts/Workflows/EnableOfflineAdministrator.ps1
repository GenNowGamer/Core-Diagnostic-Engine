#Requires -Version 5.1
<#
.SYNOPSIS
    Enables the built-in Administrator account on an offline Windows install (enable-only).
    Requires WinPE with offline registry hives loaded (Offline_SAM).
    Does not set or change passwords offline - sign in after reboot and set password in Windows.
#>

$ErrorActionPreference = 'Stop'

$ScriptDir   = Split-Path $MyInvocation.MyCommand.Path
$CoreModule  = Join-Path $ScriptDir '..\Core\Toolkit.Core.psm1'
$SamModule   = Join-Path $ScriptDir '..\Core\OfflineSamAccount.psm1'
Import-Module $CoreModule -Force -DisableNameChecking
Import-Module $SamModule -Force -DisableNameChecking

$workflow = Start-Workflow -WorkflowName 'EnableOfflineAdministrator' -ScriptBlock {
    param($r)
    Write-Log 'Enable Offline Administrator starting (enable-only).' -Level Info
    Write-Log 'This enables the built-in .\Administrator local account. It does not set passwords offline or reset Microsoft account / Entra ID sign-in.' -Level Warning

    $offlineRoot = Test-OfflineSamRecoveryReady

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

    Sync-OfflineSamHiveToDisk -OfflineWindowsRoot $offlineRoot

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
