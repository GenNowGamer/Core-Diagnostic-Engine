#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$testsRoot = Split-Path $MyInvocation.MyCommand.Path
$coreDir = Join-Path $testsRoot '..\Core'
function Write-Log { param([string]$Message) }
function Get-WorkflowStepCounts {
    param($Steps)
    [PSCustomObject]@{ Pass = 0; Warn = @($Steps).Count; Fail = 0 }
}
function Get-WorkflowOverallHealth {
    param($Steps)
    'Warning'
}
. (Join-Path $coreDir 'WorkOrder.ps1')

$toolkitRoot = [IO.Path]::GetFullPath((Join-Path $testsRoot '..\..'))
$env:TOOLKIT_ROOT = $toolkitRoot

$tempDir = Join-Path ([IO.Path]::GetTempPath()) ("CDE_WO_Test_" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
$runtimeDir = Join-Path $tempDir 'CDE\Runtime'
$woDir = Join-Path $runtimeDir 'WorkOrders'
New-Item -ItemType Directory -Force -Path $woDir | Out-Null

try {
    $caseId = 'CDE-TEST-00001'
    $order = [PSCustomObject]@{
        CaseId             = $caseId
        Sequence           = 1
        Status             = 'Open'
        CreatedAt          = (Get-Date).ToString('o')
        ClosedAt           = $null
        MachineName        = $env:COMPUTERNAME
        UserName           = $env:USERNAME
        ClientName         = 'Test Client'
        ClientPhone        = '555-0100'
        TechnicianNotes    = 'Phase 3 fixture'
        EnvironmentHistory = @('Windows')
        GuidanceContext    = [PSCustomObject]@{
            LastSymptomId    = 'slow_pc'
            LastHealthPreset = 'slow_pc'
            UpdatedAt        = (Get-Date).ToString('o')
        }
        Runs               = @()
    }

    $orderPath = Join-Path $woDir "$caseId.json"
    $order | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $orderPath -Encoding UTF8

    $pointer = [PSCustomObject]@{
        CaseId        = $caseId
        WorkOrderPath = $orderPath
        ActivatedAt   = (Get-Date).ToString('o')
    }
    $pointerPath = Join-Path $runtimeDir 'active_work_order.json'
    $pointer | ConvertTo-Json | Set-Content -LiteralPath $pointerPath -Encoding UTF8
    $env:CDE_ACTIVE_CASE_ID = $caseId

    $chuArtifact = Join-Path $tempDir 'chu_result.json'
    '{}' | Set-Content -LiteralPath $chuArtifact -Encoding UTF8

    Add-WorkOrderCaseEvent -EventKind 'ChuPreBoot' -DisplayLabel 'CHU pre-boot' `
        -SourceArtifact $chuArtifact -OverallHealth 'Warning' -Summary '1 warn, 0 fail' `
        -ToolkitRoot $tempDir | Out-Null

    $dup = Add-WorkOrderCaseEvent -EventKind 'ChuPreBoot' -DisplayLabel 'CHU pre-boot' `
        -SourceArtifact $chuArtifact -OverallHealth 'Warning' -Summary 'duplicate' `
        -ToolkitRoot $tempDir
    if (@($dup.Runs).Count -ne 1) {
        Write-Error 'ChuPreBoot dedupe by SourceArtifact failed.'
        exit 1
    }

    $cstArtifact = Join-Path $tempDir 'CST_Result_test.json'
    '{}' | Set-Content -LiteralPath $cstArtifact -Encoding UTF8
    Add-WorkOrderCaseEvent -EventKind 'CstScan' -DisplayLabel 'CST scan: notepad.exe' `
        -SourceArtifact $cstArtifact -OverallHealth 'Healthy' -Summary 'Clean' `
        -ToolkitRoot $tempDir | Out-Null

    $loaded = Get-WorkOrder -CaseId $caseId -ToolkitRoot $tempDir
    if (@($loaded.Runs).Count -ne 2) {
        Write-Error "Expected 2 runs, got $(@($loaded.Runs).Count)."
        exit 1
    }

    $chuRun = @($loaded.Runs) | Where-Object { $_.EventKind -eq 'ChuPreBoot' } | Select-Object -First 1
    if (-not $chuRun -or [string]$chuRun.SourceArtifact -ne $chuArtifact) {
        Write-Error 'ChuPreBoot run fields incorrect.'
        exit 1
    }

    $cstRun = @($loaded.Runs) | Where-Object { $_.EventKind -eq 'CstScan' } | Select-Object -First 1
    if (-not $cstRun -or [string]$cstRun.DisplayLabel -notlike 'CST scan:*') {
        Write-Error 'CstScan run fields incorrect.'
        exit 1
    }

    $reportJson = Join-Path $tempDir 'TempFileCleaner_Clean_test.json'
    '{}' | Set-Content -LiteralPath $reportJson -Encoding UTF8
    $workflowResult = [PSCustomObject]@{
        WorkflowName    = 'TempFileCleaner_Clean'
        EndTime         = Get-Date
        Status          = 'Completed'
        EnvironmentMode = 'Windows'
        Steps           = @(
            [PSCustomObject]@{ Name = 'TempFileClean'; Status = 'Warn'; Output = 'Cleaned 1 item.' }
        )
    }

    $afterWorkflow = Add-WorkOrderRun -WorkflowResult $workflowResult -ReportJsonPath $reportJson -ToolkitRoot $tempDir
    if (-not $afterWorkflow) {
        Write-Error 'Add-WorkOrderRun with ReportJsonPath returned null.'
        exit 1
    }

    $dupWorkflow = Add-WorkOrderRun -WorkflowResult $workflowResult -ReportJsonPath $reportJson -ToolkitRoot $tempDir
    $workflowRuns = @($dupWorkflow.Runs) | Where-Object { $_.WorkflowName -eq 'TempFileCleaner_Clean' }
    if (@($workflowRuns).Count -ne 1) {
        Write-Error 'Workflow dedupe by ReportJson failed.'
        exit 1
    }

    Write-Host 'Test-WorkOrderCaseEvents: PASS'
    exit 0
}
finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:CDE_ACTIVE_CASE_ID -ErrorAction SilentlyContinue
}
