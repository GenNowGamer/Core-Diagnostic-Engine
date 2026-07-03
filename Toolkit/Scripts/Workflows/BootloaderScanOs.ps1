#Requires -Version 5.1
param()

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $ScriptDir '..\Core\Toolkit.Core.psm1') -Force -DisableNameChecking
. (Join-Path $ScriptDir 'Bootloader.Common.ps1')

$workflow = Start-Workflow -WorkflowName 'Bootloader_ScanOS' -ScriptBlock {
    param($r)

    Assert-WinPeOrThrow -Result $r
    $targets = @(Get-BootloaderTargets)
    $efiVolumes = @(Get-EfiSystemVolumes)

    # bootrec /scanos is not available in ADK WinPE (WinRE-only).
    # Build equivalent output from the PowerShell scan already performed above.
    $scanLines = @('Scanning all drives for Windows installations...', '')
    $idx = 1
    foreach ($t in $targets) {
        $bcdTag = if     (Test-Path -LiteralPath $t.EfiBcdPath  -PathType Leaf) { 'EFI BCD found' }
                  elseif (Test-Path -LiteralPath $t.BiosBcdPath -PathType Leaf) { 'BIOS BCD found' }
                  else                                                          { 'No BCD store found' }
        $scanLines += "[$idx] $($t.WindowsDir)  ($bcdTag)"
        $idx++
    }
    $scanLines += ''
    $scanLines += "Total identified Windows installations: $($targets.Count)"

    if ($efiVolumes.Count -gt 0) {
        $scanLines += ''
        $scanLines += 'EFI system volumes:'
        foreach ($efi in $efiVolumes) {
            $kind = if ($efi.HasWindows) { 'Windows+EFI' } else { 'EFI only' }
            $scanLines += "  $($efi.DriveRoot)  [$kind]  $($efi.EfiBcdPath)"
        }
        $scanLines += "Total EFI system volumes: $($efiVolumes.Count)"
    }

    $step = [PSCustomObject]@{
        Name     = 'ScanOS'
        Status   = 'Pass'
        ExitCode = 0
        Output   = $scanLines -join "`n"
    }
    foreach ($line in $scanLines) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            Write-Log -Message $line -Level Info
        }
    }
    Add-BootloaderStep -Result $r -Step $step
}

Generate-Report -WorkflowResult $workflow | Out-Null
