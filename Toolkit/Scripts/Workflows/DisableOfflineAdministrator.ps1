#Requires -Version 5.1
<#
.SYNOPSIS
    Disables the built-in Administrator account on an offline Windows install (disable-only).
    Requires WinPE with offline registry hives loaded (Offline_SAM).
    Sets ACB_DISABLED on SAM user_F at RID 500 - inverse of Enable Offline Administrator.
#>

$ErrorActionPreference = 'Stop'

$ScriptDir   = Split-Path $MyInvocation.MyCommand.Path
$CoreModule  = Join-Path $ScriptDir '..\Core\Toolkit.Core.psm1'
$SamModule   = Join-Path $ScriptDir '..\Core\OfflineSamAccount.psm1'
Import-Module $CoreModule -Force -DisableNameChecking
Import-Module $SamModule -Force -DisableNameChecking

$workflow = Start-Workflow -WorkflowName 'DisableOfflineAdministrator' -ScriptBlock {
    param($r)
    Write-Log 'Disable Offline Administrator starting (disable-only).' -Level Info
    Write-Log 'This disables the built-in .\Administrator local account in offline SAM. It does not change passwords.' -Level Warning

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

    if ($beforeState.IsDisabled) {
        Write-Log 'Administrator is already disabled in offline SAM; applying disable bit again for consistency.' -Level Info
    }

    $result = Disable-OfflineBuiltInAdministrator
    Write-Log "Disabled account: $($result.AccountName) (RID $($result.RelativeId))" -Level Success
    Write-Log "Post-change ACB_bits=0x$('{0:X4}' -f $result.AcbBits)" -Level Success

    if (-not $result.IsDisabled) {
        throw "Verification failed: Administrator ACB_DISABLED is not set (ACB_bits=0x$('{0:X4}' -f $result.AcbBits))."
    }

    Sync-OfflineSamHiveToDisk -OfflineWindowsRoot $offlineRoot

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
