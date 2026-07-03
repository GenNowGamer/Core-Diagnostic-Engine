#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$testsRoot = Split-Path $MyInvocation.MyCommand.Path
$toolkitRoot = Split-Path (Split-Path $testsRoot) -Parent
$coreModule = Join-Path $toolkitRoot 'Scripts\Core\Toolkit.Core.psm1'
Import-Module $coreModule -Force -DisableNameChecking

Describe 'Environment capability matrix' {
    It 'loads matrix JSON' {
        { Get-ToolkitCapabilityMatrix | Out-Null } | Should -Not -Throw
    }

    It 'includes FastFixes Apply as na in WinPE columns' {
        $matrix = Get-ToolkitCapabilityMatrix
        $apply = $matrix.workflows.FastFixes.actions.Apply
        $apply.winpe_online | Should -Be 'na'
        $apply.winpe_offline | Should -Be 'na'
    }

    It 'maps every workflow ps1 to a matrix row' {
        $matrix = Get-ToolkitCapabilityMatrix
        $workflowDir = Join-Path $toolkitRoot 'Scripts\Workflows'
        $scripts = Get-ChildItem -LiteralPath $workflowDir -Filter '*.ps1' |
            Where-Object {
                $_.Name -notlike 'Test-*' -and
                $_.Name -ne 'Bootloader.Common.ps1' -and
                $_.Name -ne 'HardwareCommon.ps1'
            }

        foreach ($script in $scripts) {
            $name = [System.IO.Path]::GetFileNameWithoutExtension($script.Name)
            $matrix.workflows.PSObject.Properties.Name | Should -Contain $name
        }
    }

    It 'blocks FastFixes Apply in WinPE via Assert' {
        Mock Get-EnvironmentMode { return 'WinPE' }
        { Assert-ToolkitCapability -Workflow 'FastFixes' -Action 'Apply' } | Should -Throw '*not available*'
    }
}
