#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for vssadmin shadow copy parsing in ShadowCopyBrowse.ps1.
#>

$ErrorActionPreference = 'Stop'

$shadowCopyScript = Join-Path (Split-Path $MyInvocation.MyCommand.Path) '..\Core\ShadowCopyBrowse.ps1'
. $shadowCopyScript

$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0

function Assert-True {
    param(
        [string]$Name,
        [bool]$Condition,
        [string]$Detail = ''
    )

    if ($Condition) {
        $script:passed++
        Write-Host "PASS: $Name"
        return
    }

    $message = $Name
    if (-not [string]::IsNullOrWhiteSpace($Detail)) {
        $message = "$Name :: $Detail"
    }

    $failures.Add($message) | Out-Null
    Write-Host "FAIL: $message" -ForegroundColor Red
}

$sampleVssAdminBlock = @'
Contents of shadow copy set ID: {cdd05c21-2466-44b8-8458-34b0a9f39011}
   Contained 3 shadow copies at creation time: 6/12/2026 12:16:37 PM
      Shadow Copy ID: {f5394042-0b5d-4f38-b54b-b839580b8c02}
         Original Volume: (D:)\\?\Volume{089b09a9-d074-45b8-b697-7f0286af7418}\
         Shadow Copy Volume: \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy13
         Originating Machine: DESKTOP-D18TVI3
      Shadow Copy ID: {a5ce43b8-61aa-46ed-988a-3ef0641d5b42}
         Original Volume: (C:)\\?\Volume{dbe4a19f-8ead-4caa-9030-2f9d1ed6190f}\
         Shadow Copy Volume: \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy14
         Originating Machine: DESKTOP-D18TVI3
      Shadow Copy ID: {63899231-a644-40ae-8570-43358b23db85}
         Original Volume: (F:)\\?\Volume{e04d5eaf-b308-4463-96c9-682b48f58881}\
         Shadow Copy Volume: \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy15
         Originating Machine: DESKTOP-D18TVI3
'@

$parsed = @(Parse-VssAdminShadowCopiesFromBlock -Block $sampleVssAdminBlock)
Assert-True -Name 'Parses all shadows in one restore set' -Condition ($parsed.Count -eq 3) -Detail "Count=$($parsed.Count)"
Assert-True -Name 'Drive D parsed' -Condition ($parsed[0].Drive -eq 'D:') -Detail "Drive=$($parsed[0].Drive)"
Assert-True -Name 'Drive C parsed' -Condition ($parsed[1].Drive -eq 'C:') -Detail "Drive=$($parsed[1].Drive)"
Assert-True -Name 'Drive F parsed' -Condition ($parsed[2].Drive -eq 'F:') -Detail "Drive=$($parsed[2].Drive)"
Assert-True -Name 'Shared install date' -Condition ($parsed[0].InstallDate -eq '6/12/2026 12:16:37 PM')
Assert-True -Name 'C shadow device object' -Condition ($parsed[1].DeviceObject -eq '\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy14')
Assert-True -Name 'F shadow id preserved' -Condition ($parsed[2].ID -eq '{63899231-a644-40ae-8570-43358b23db85}')

Assert-True -Name 'Legacy trailing drive letter format' -Condition ((Get-DriveLetterFromOriginalVolume -OriginalVolume '\\?\Volume{abc}\ (E:)') -eq 'E:')
Assert-True -Name 'Modern leading drive letter format' -Condition ((Get-DriveLetterFromOriginalVolume -OriginalVolume '(C:)\\?\Volume{abc}\') -eq 'C:')

$sortSample = @(
    [PSCustomObject]@{ InstallDate = '6/12/2026 8:53:32 AM'; Drive = 'D:'; ID = 'b' }
    [PSCustomObject]@{ InstallDate = '6/12/2026 12:17:20 PM'; Drive = 'C:'; ID = 'a' }
    [PSCustomObject]@{ InstallDate = '6/11/2026 11:58:20 AM'; Drive = 'F:'; ID = 'c' }
    [PSCustomObject]@{ InstallDate = '6/12/2026 12:16:37 PM'; Drive = 'D:'; ID = 'd' }
)
$sorted = @(Sort-ShadowCopiesForDisplay -Shadows $sortSample)
Assert-True -Name 'Sort newest date first' -Condition ($sorted[0].InstallDate -eq '6/12/2026 12:17:20 PM') -Detail "First=$($sorted[0].InstallDate)"
Assert-True -Name 'Sort second newest set' -Condition ($sorted[1].InstallDate -eq '6/12/2026 12:16:37 PM') -Detail "Second=$($sorted[1].InstallDate)"
Assert-True -Name 'Sort oldest date last' -Condition ($sorted[$sorted.Count - 1].InstallDate -eq '6/11/2026 11:58:20 AM') -Detail "Last=$($sorted[$sorted.Count - 1].InstallDate)"

Write-Host "`n--- SUMMARY ---" -ForegroundColor Cyan
Write-Host "Passed: $passed"
Write-Host "Failed: $($failures.Count)"
if ($failures.Count -gt 0) {
    foreach ($failure in $failures) {
        Write-Host "  $failure" -ForegroundColor Red
    }
    exit 1
}

exit 0
