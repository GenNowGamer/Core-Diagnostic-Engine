#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$testsRoot = Split-Path $MyInvocation.MyCommand.Path
$toolkitRoot = Split-Path (Split-Path $testsRoot) -Parent
$flowsPath = Join-Path $toolkitRoot 'Config\SymptomFlows.json'
$catalogPath = Join-Path $toolkitRoot 'Config\HealthCheckCatalog.json'

$navTargets = @(
    'Dashboard', 'SystemHealth', 'SystemAudit', 'ChuResults', 'SmartAnalyzer', 'DiagAndRepair',
    'HardwareDiagnostics', 'OSRepair', 'MalwareCleanup', 'BootloaderRepair', 'HijackRepair',
    'PostOp', 'StartupManager', 'TempFileCleaner', 'UninstallManager', 'FastFixes',
    'ProcessAnalyzer', 'BackupAndImage', 'Settings'
)

Describe 'Symptom flows E2E smoke' {
    It 'loads SymptomFlows.json' {
        Test-Path -LiteralPath $flowsPath | Should -Be $true
        $flows = Get-Content -LiteralPath $flowsPath -Raw | ConvertFrom-Json
        $flows.flows.Count | Should -BeGreaterThan 0
    }

    It 'resolves health presets and follow-up navigation targets' {
        $flows = Get-Content -LiteralPath $flowsPath -Raw | ConvertFrom-Json
        $catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
        $presetNames = @($catalog.presets.PSObject.Properties.Name)

        foreach ($flow in $flows.flows) {
            $presetNames | Should -Contain $flow.healthPreset

            foreach ($followUp in @($flow.followUps)) {
                $target = [string]$followUp.target
                $section = ($target -split ':')[0]
                $navTargets | Should -Contain $section
            }
        }
    }

    It 'validates wont_boot boot tooling prerequisites' {
        $bootCommon = Join-Path $toolkitRoot 'Scripts\Workflows\Bootloader.Common.ps1'
        Test-Path -LiteralPath $bootCommon | Should -Be $true
        $content = Get-Content -LiteralPath $bootCommon -Raw
        $content | Should -Match 'Assert-WinPeOrThrow'
    }
}
