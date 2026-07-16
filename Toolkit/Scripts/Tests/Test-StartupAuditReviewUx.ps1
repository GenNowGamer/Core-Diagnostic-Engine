#Requires -Version 5.1
<#
.SYNOPSIS
    Verifies startup audit review labeling and suspicious-entry reasons.
#>

$ErrorActionPreference = 'Stop'

$coreRoot = Join-Path (Split-Path $MyInvocation.MyCommand.Path) '..\Core'
. (Join-Path $coreRoot 'StartupRisk.ps1')

$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) {
        $script:passed++
        Write-Host "PASS: $Name"
        return
    }

    $msg = if ($Detail) { "$Name :: $Detail" } else { $Name }
    $script:failures.Add($msg) | Out-Null
    Write-Host "FAIL: $msg"
}

$assessment = Test-PostOpStartupSuspicious `
    -Name 'OneDriveSetup' `
    -SourceGroup 'HKCU Run' `
    -ResolvedPath 'C:\Windows\System32\cmd.exe' `
    -Publisher 'Microsoft Corporation' `
    -IsSigned:$true `
    -RiskBand 'Safe' `
    -IsRunOnce:$true `
    -TargetExists:$true

Assert-True -Name 'RunOnce entry flagged for review' -Condition $assessment.IsSuspicious
Assert-True -Name 'RunOnce reason present' -Condition ($assessment.Reasons -contains 'RunOnce key')

$shellOk = Test-PostOpStartupSuspicious `
    -Name 'Shell' `
    -SourceGroup 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' `
    -ResolvedPath 'explorer.exe' `
    -Publisher 'Microsoft Corporation' `
    -IsSigned:$false `
    -RiskBand 'Safe' `
    -IsRunOnce:$false `
    -TargetExists:$true `
    -EntryType 'Winlogon' `
    -IsWinlogonDeviated:$false
Assert-True -Name 'Non-deviant Winlogon Shell not flagged unsigned' -Condition (-not $shellOk.IsSuspicious)
Assert-True -Name 'Non-deviant Shell has no unsigned reason' -Condition ($shellOk.Reasons -notcontains 'unsigned')

$shellBad = Test-PostOpStartupSuspicious `
    -Name 'Shell' `
    -SourceGroup 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' `
    -ResolvedPath 'C:\Temp\evil.exe' `
    -Publisher 'Unknown' `
    -IsSigned:$false `
    -RiskBand 'Warning' `
    -IsRunOnce:$false `
    -TargetExists:$true `
    -EntryType 'Winlogon' `
    -IsWinlogonDeviated:$true `
    -WinlogonDeviationReason 'shell is not explorer.exe'
Assert-True -Name 'Deviant Winlogon Shell still flagged' -Condition $shellBad.IsSuspicious
Assert-True -Name 'Deviant Shell includes winlogon reason' -Condition (
    @($shellBad.Reasons | Where-Object { $_ -like 'winlogon:*' }).Count -gt 0
)

$copilotOk = Test-PostOpStartupSuspicious `
    -Name 'Copilot' `
    -SourceGroup 'MSIX Startup Task' `
    -ResolvedPath 'C:\Program Files\WindowsApps\Microsoft.Copilot_1.0.0.0_neutral__8wekyb3d8bbwe\copilot_proxy.exe' `
    -Publisher 'Microsoft Corporation' `
    -IsSigned:$true `
    -RiskBand 'Safe' `
    -IsRunOnce:$false `
    -TargetExists:$false `
    -EntryType 'MsixStartupTask'
Assert-True -Name 'Trusted MSIX with inaccessible path not target-missing' -Condition (-not $copilotOk.IsSuspicious)
Assert-True -Name 'Trusted MSIX has no target missing reason' -Condition ($copilotOk.Reasons -notcontains 'target missing')

$msixUnsignedMissing = Test-PostOpStartupSuspicious `
    -Name 'ShadyApp' `
    -SourceGroup 'MSIX Startup Task' `
    -ResolvedPath 'C:\Program Files\WindowsApps\Contoso.Shady_1.0.0.0_neutral__abc\app.exe' `
    -Publisher 'Unknown' `
    -IsSigned:$false `
    -RiskBand 'Caution' `
    -IsRunOnce:$false `
    -TargetExists:$false `
    -EntryType 'MsixStartupTask'
Assert-True -Name 'Untrusted MSIX missing target still flagged' -Condition $msixUnsignedMissing.IsSuspicious
Assert-True -Name 'Untrusted MSIX keeps target missing reason' -Condition ($msixUnsignedMissing.Reasons -contains 'target missing')

# Live inventory: Shell / Copilot should not be review-flagged when present as defaults.
$msixScript = Join-Path $coreRoot 'MsixStartup.ps1'
if (Test-Path -LiteralPath $msixScript) { . $msixScript }
$liveEntries = @(Get-PostOpStartupEntries)
$liveShell = @($liveEntries | Where-Object { $_.Name -eq 'Shell' -and $_.EntryType -eq 'Winlogon' } | Select-Object -First 1)
if ($liveShell.Count -gt 0) {
    $shellEntry = $liveShell[0]
    $shellDeviated = [bool]$shellEntry.IsDeviated
    $liveShellAssess = Test-PostOpStartupSuspicious `
        -Name $shellEntry.Name `
        -SourceGroup $shellEntry.SourceGroup `
        -ResolvedPath $shellEntry.ResolvedPath `
        -Publisher $shellEntry.Publisher `
        -IsSigned:([bool]$shellEntry.IsSigned) `
        -RiskBand $shellEntry.RiskBand `
        -IsRunOnce:([bool]$shellEntry.IsRunOnce) `
        -TargetExists:([bool]$shellEntry.TargetExists) `
        -EntryType $shellEntry.EntryType `
        -IsWinlogonDeviated:$shellDeviated `
        -WinlogonDeviationReason ([string]$shellEntry.DeviationReason)
    Assert-True -Name 'Live Shell inventory not review-flagged when default' -Condition (
        $shellDeviated -or (-not $liveShellAssess.IsSuspicious)
    )
    Assert-True -Name 'Live Shell IsSigned when not deviant' -Condition (
        $shellDeviated -or [bool]$shellEntry.IsSigned
    )
}

$liveCopilot = @($liveEntries | Where-Object { $_.Name -eq 'Copilot' -and $_.EntryType -eq 'MsixStartupTask' } | Select-Object -First 1)
if ($liveCopilot.Count -gt 0) {
    $copilotEntry = $liveCopilot[0]
    $liveCopilotAssess = Test-PostOpStartupSuspicious `
        -Name $copilotEntry.Name `
        -SourceGroup $copilotEntry.SourceGroup `
        -ResolvedPath $copilotEntry.ResolvedPath `
        -Publisher $copilotEntry.Publisher `
        -IsSigned:([bool]$copilotEntry.IsSigned) `
        -RiskBand $copilotEntry.RiskBand `
        -IsRunOnce:([bool]$copilotEntry.IsRunOnce) `
        -TargetExists:([bool]$copilotEntry.TargetExists) `
        -EntryType $copilotEntry.EntryType
    Assert-True -Name 'Live Copilot not flagged target missing when signed' -Condition (
        -not [bool]$copilotEntry.IsSigned -or ($liveCopilotAssess.Reasons -notcontains 'target missing')
    )
}

$auditScript = Get-Content -LiteralPath (Join-Path $coreRoot 'SystemAuditChecks.ps1') -Raw
Assert-True -Name 'Startup audit uses Review summary label' -Condition ($auditScript -match '\| Review: \$reviewCount \|')
Assert-True -Name 'Startup audit uses REVIEW tag' -Condition ($auditScript -match "'\[REVIEW\]'")
Assert-True -Name 'Startup audit no longer uses Suspicious summary label' -Condition ($auditScript -notmatch '\| Suspicious: \$')

Write-Host ''
Write-Host "Passed: $passed"
Write-Host "Failed: $($failures.Count)"

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) {
        Write-Host $failure
    }
    exit 1
}

exit 0
