#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for MSIX / UWP startup task discovery and state helpers.
#>

$ErrorActionPreference = 'Stop'

$coreRoot = Join-Path (Split-Path $MyInvocation.MyCommand.Path) '..\Core'
. (Join-Path $coreRoot 'MsixStartup.ps1')

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

Assert-True -Name 'State 2 is enabled' -Condition (Test-MsixStartupStateEnabled -State 2)
Assert-True -Name 'State 3 is enabled' -Condition (Test-MsixStartupStateEnabled -State 3)
Assert-True -Name 'State 1 is disabled' -Condition (-not (Test-MsixStartupStateEnabled -State 1))
Assert-True -Name 'State 0 is disabled' -Condition (-not (Test-MsixStartupStateEnabled -State 0))
Assert-True -Name 'Null state is disabled' -Condition (-not (Test-MsixStartupStateEnabled -State $null))

$samplePsPath = 'Microsoft.PowerShell.Core\Registry::HKEY_CURRENT_USER\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData\MSTeams_8wekyb3d8bbwe\TeamsTfwStartupTask'
$converted = ConvertTo-MsixStartupRegistryPath -PsPath $samplePsPath
Assert-True -Name 'Registry path converts to HKCU form' -Condition ($converted -eq 'HKCU\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData\MSTeams_8wekyb3d8bbwe\TeamsTfwStartupTask')

$resolved = Resolve-MsixStartupRegistryPsPath -RawPath $converted
Assert-True -Name 'Registry path resolves to PS drive path' -Condition ($resolved -like 'HKCU:*TeamsTfwStartupTask')

$joined = Join-MsixPackageExecutablePath -InstallLocation 'C:\Apps\Contoso' -RelativeExecutable 'app.exe'
Assert-True -Name 'Join package executable path' -Condition ($joined -eq 'C:\Apps\Contoso\app.exe')

$packagePublisherSig = Get-MsixPackagePublisherSignatureInfo -Publisher 'Microsoft Corporation'
Assert-True -Name 'Package publisher signature display' -Condition ($packagePublisherSig.SignedDisplay -eq 'Package (Microsoft Corporation)')
Assert-True -Name 'Package publisher signature status' -Condition ($packagePublisherSig.SignatureStatus -eq 'PackagePublisher')
Assert-True -Name 'Package publisher treated as signed for audit' -Condition ($packagePublisherSig.IsSigned -eq $true)

$unknownPublisherSig = Get-MsixPackagePublisherSignatureInfo -Publisher 'Unknown'
Assert-True -Name 'Unknown package publisher remains unsigned' -Condition ($unknownPublisherSig.IsSigned -eq $false)

$teamsPkg = Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.PackageFamilyName -eq 'MSTeams_8wekyb3d8bbwe' } | Select-Object -First 1
if ($teamsPkg) {
    $teamsResolved = Resolve-MsixStartupExecutablePath `
        -PackageFamilyName 'MSTeams_8wekyb3d8bbwe' `
        -TaskId 'TeamsTfwStartupTask' `
        -AppxPackage $teamsPkg
    Assert-True -Name 'Teams startup task resolves manifest executable' -Condition (
        $teamsResolved.ResolutionMethod -eq 'StartupTaskManifest' -and
        $teamsResolved.ManifestExecutable -eq 'msteams_autostarter.exe'
    )
    if ($teamsResolved.Exists) {
        $teamsSig = Get-MsixStartupSignatureInfo `
            -PackageFamilyName 'MSTeams_8wekyb3d8bbwe' `
            -TaskId 'TeamsTfwStartupTask' `
            -Publisher 'Microsoft Corporation' `
            -AppxPackage $teamsPkg
        Assert-True -Name 'Teams accessible executable has signature status' -Condition (
            -not [string]::IsNullOrWhiteSpace($teamsSig.SignatureStatus) -and
            $teamsSig.SignedDisplay -ne 'Not found'
        )
    }
}

$copilotPkg = Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.PackageFamilyName -eq 'Microsoft.Copilot_8wekyb3d8bbwe' } | Select-Object -First 1
if ($copilotPkg) {
    $copilotResolved = Resolve-MsixStartupExecutablePath `
        -PackageFamilyName 'Microsoft.Copilot_8wekyb3d8bbwe' `
        -TaskId 'Copilot.StartupTaskId' `
        -AppxPackage $copilotPkg
    Assert-True -Name 'Copilot startup task falls back to application executable' -Condition (
        $copilotResolved.ManifestExecutable -eq 'mscopilot_proxy.exe'
    )
    $copilotSig = Get-MsixStartupSignatureInfo `
        -PackageFamilyName 'Microsoft.Copilot_8wekyb3d8bbwe' `
        -TaskId 'Copilot.StartupTaskId' `
        -Publisher 'Microsoft Corporation' `
        -AppxPackage $copilotPkg
    Assert-True -Name 'Copilot uses package publisher fallback when file inaccessible' -Condition (
        $copilotSig.SignedDisplay -eq 'Package (Microsoft Corporation)' -or $copilotSig.SignatureStatus -eq 'Valid'
    )
    Assert-True -Name 'Copilot package-publisher fallback is signed for audit' -Condition (
        $copilotSig.IsSigned -eq $true
    )
    $copilotAnalysis = Get-MsixStartupAnalysisInfo `
        -PackageFamilyName 'Microsoft.Copilot_8wekyb3d8bbwe' `
        -TaskId 'Copilot.StartupTaskId' `
        -Publisher 'Microsoft Corporation' `
        -AppxPackage $copilotPkg
    Assert-True -Name 'Copilot analysis avoids false warning' -Condition (-not $copilotAnalysis.HasWarning)
}

$rows = @(Get-MsixStartupTaskRows)
Assert-True -Name 'Discovery returns array' -Condition ($null -ne $rows)

if ($rows.Count -gt 0) {
    $first = $rows[0]
    Assert-True -Name 'Row type is MsixStartupTask' -Condition ($first.RowType -eq 'MsixStartupTask')
    Assert-True -Name 'Row has registry path' -Condition (-not [string]::IsNullOrWhiteSpace($first.RegistryPath))
    Assert-True -Name 'Row has MSIX task id' -Condition (-not [string]::IsNullOrWhiteSpace($first.MsixTaskId))
    Assert-True -Name 'Delete not supported' -Condition ($first.SupportsDelete -eq $false)
}

$startupScript = Join-Path (Split-Path $MyInvocation.MyCommand.Path) '..\Workflows\StartupManager.ps1'
$startupScriptText = Get-Content -LiteralPath $startupScript -Raw
Assert-True -Name 'StartupManager wires MSIX discovery' -Condition ($startupScriptText -match 'Get-MsixStartupTaskRows')
Assert-True -Name 'StartupManager wires MSIX disable' -Condition ($startupScriptText -match "'MsixStartupTask'")
Assert-True -Name 'StartupManager wires MSIX signature helpers' -Condition ($startupScriptText -match 'Get-MsixStartupSignatureInfo')

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
