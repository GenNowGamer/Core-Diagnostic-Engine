#Requires -Version 5.1
<#
.SYNOPSIS
    USB-local work order / case ID management for CDE technician jobs.
#>

function Get-WorkOrderToolkitRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:TOOLKIT_ROOT) -and (Test-Path -LiteralPath $env:TOOLKIT_ROOT)) {
        return $env:TOOLKIT_ROOT.TrimEnd('\')
    }

    $fromScript = Get-ToolkitRootFromScript -ScriptRoot $PSScriptRoot
    if (-not [string]::IsNullOrWhiteSpace($fromScript)) {
        return $fromScript
    }

    return ''
}

function Get-WorkOrderRuntimeDirectory {
    param([string]$ToolkitRoot = '')

    if ([string]::IsNullOrWhiteSpace($ToolkitRoot)) {
        $ToolkitRoot = Get-WorkOrderToolkitRoot
    }

    if (Get-Command Get-OfflineRuntimeDirectory -ErrorAction SilentlyContinue) {
        return Get-OfflineRuntimeDirectory -ToolkitRoot $ToolkitRoot
    }

    return Join-Path $ToolkitRoot 'CDE\Runtime'
}

function Get-OperatorWorkOrdersDirectory {
    param([string]$ToolkitRoot = '')

    if ([string]::IsNullOrWhiteSpace($ToolkitRoot)) {
        $ToolkitRoot = Get-WorkOrderToolkitRoot
    }

    return Join-Path $ToolkitRoot 'WorkOrders'
}

function Get-InternalWorkOrdersDirectory {
    param([string]$ToolkitRoot = '')

    if ([string]::IsNullOrWhiteSpace($ToolkitRoot)) {
        $ToolkitRoot = Get-WorkOrderToolkitRoot
    }

    $dir = Join-Path (Get-WorkOrderRuntimeDirectory -ToolkitRoot $ToolkitRoot) 'WorkOrders'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    return $dir
}

function Get-WorkOrdersDirectory {
    param([string]$ToolkitRoot = '')

    return Get-OperatorWorkOrdersDirectory -ToolkitRoot $ToolkitRoot
}

function Get-CaseCounterFilePath {
    param([string]$ToolkitRoot = '')

    if ([string]::IsNullOrWhiteSpace($ToolkitRoot)) {
        $ToolkitRoot = Get-WorkOrderToolkitRoot
    }

    return Join-Path $ToolkitRoot 'Config\case_counter.json'
}

function Get-ActiveWorkOrderPointerPath {
    param([string]$ToolkitRoot = '')

    if ([string]::IsNullOrWhiteSpace($ToolkitRoot)) {
        $ToolkitRoot = Get-WorkOrderToolkitRoot
    }

    return Join-Path (Get-WorkOrderRuntimeDirectory -ToolkitRoot $ToolkitRoot) 'active_work_order.json'
}

function Read-CaseCounterState {
    param([string]$ToolkitRoot = '')

    $path = Get-CaseCounterFilePath -ToolkitRoot $ToolkitRoot
    $default = [PSCustomObject]@{
        Prefix       = 'CDE'
        LastSequence = 0
    }

    if (-not (Test-Path -LiteralPath $path)) {
        return $default
    }

    try {
        $raw = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        return [PSCustomObject]@{
            Prefix       = if ($raw.Prefix) { [string]$raw.Prefix } else { 'CDE' }
            LastSequence = [int]$raw.LastSequence
        }
    } catch {
        return $default
    }
}

function Save-CaseCounterState {
    param(
        [Parameter(Mandatory)]
        $State,
        [string]$ToolkitRoot = ''
    )

    $path = Get-CaseCounterFilePath -ToolkitRoot $ToolkitRoot
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    [PSCustomObject]@{
        Prefix       = [string]$State.Prefix
        LastSequence = [int]$State.LastSequence
    } | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8
}

function Get-NextCaseId {
    param(
        [string]$ToolkitRoot = '',
        [string]$Prefix = ''
    )

    if ([string]::IsNullOrWhiteSpace($ToolkitRoot)) {
        $ToolkitRoot = Get-WorkOrderToolkitRoot
    }

    $counterPath = Get-CaseCounterFilePath -ToolkitRoot $ToolkitRoot
    $lockPath = "$counterPath.lock"
    $dir = Split-Path -Parent $counterPath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    $maxWaitMs = 10000
    $waited = 0
    while ($waited -lt $maxWaitMs) {
        try {
            $lockStream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            break
        } catch {
            Start-Sleep -Milliseconds 50
            $waited += 50
        }
    }

    if (-not $lockStream) {
        throw 'Timed out waiting for case counter lock.'
    }

    try {
        $state = Read-CaseCounterState -ToolkitRoot $ToolkitRoot
        if (-not [string]::IsNullOrWhiteSpace($Prefix)) {
            $state.Prefix = $Prefix
        }

        $state.LastSequence = [int]$state.LastSequence + 1
        Save-CaseCounterState -State $state -ToolkitRoot $ToolkitRoot

        $datePart = Get-Date -Format 'yyyyMMdd'
        $seqPart = '{0:D5}' -f $state.LastSequence
        return [PSCustomObject]@{
            CaseId       = "$($state.Prefix)-$datePart-$seqPart"
            Sequence     = $state.LastSequence
            CounterPath  = $counterPath
        }
    } finally {
        $lockStream.Close()
        if (Test-Path -LiteralPath $lockPath) {
            Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-ValidCaseId {
    param([string]$CaseId)

    if ([string]::IsNullOrWhiteSpace($CaseId)) {
        return $false
    }

    $trimmed = $CaseId.Trim()
    if ($trimmed -match '[\\/]' -or $trimmed.Contains('..')) {
        return $false
    }

    # Match CreateWorkOrder / Get-NextCaseId: PREFIX-yyyyMMdd-#####
    return [bool]($trimmed -match '^[A-Za-z0-9]+-\d{8}-\d{5}$')
}

function Assert-ValidCaseId {
    param(
        [Parameter(Mandatory)][string]$CaseId
    )

    $trimmed = $CaseId.Trim()
    if (-not (Test-ValidCaseId -CaseId $trimmed)) {
        throw "Invalid CaseId format: '$CaseId'."
    }

    return $trimmed
}

function Assert-PathUnderWorkOrdersRoot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ToolkitRoot = ''
    )

    if ([string]::IsNullOrWhiteSpace($ToolkitRoot)) {
        $ToolkitRoot = Get-WorkOrderToolkitRoot
    }

    $full = [System.IO.Path]::GetFullPath($Path)
    $roots = @(
        (Get-InternalWorkOrdersDirectory -ToolkitRoot $ToolkitRoot),
        (Get-OperatorWorkOrdersDirectory -ToolkitRoot $ToolkitRoot)
    )

    foreach ($rootDir in $roots) {
        $rootFull = [System.IO.Path]::GetFullPath($rootDir).TrimEnd('\', '/') + '\'
        if ($full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $full
        }
    }

    throw "Work order path escapes WorkOrders root: $full"
}

function Resolve-WorkOrderFilePath {
    param(
        [Parameter(Mandatory)][string]$CaseId,
        [string]$ToolkitRoot = ''
    )

    if ([string]::IsNullOrWhiteSpace($ToolkitRoot)) {
        $ToolkitRoot = Get-WorkOrderToolkitRoot
    }

    $CaseId = Assert-ValidCaseId -CaseId $CaseId

    $runtimePath = Join-Path (Get-InternalWorkOrdersDirectory -ToolkitRoot $ToolkitRoot) "$CaseId.json"
    $legacyPath = Join-Path (Get-OperatorWorkOrdersDirectory -ToolkitRoot $ToolkitRoot) "$CaseId.json"

    if (Test-Path -LiteralPath $runtimePath) {
        return Assert-PathUnderWorkOrdersRoot -Path $runtimePath -ToolkitRoot $ToolkitRoot
    }
    if (Test-Path -LiteralPath $legacyPath) {
        return Assert-PathUnderWorkOrdersRoot -Path $legacyPath -ToolkitRoot $ToolkitRoot
    }

    return Assert-PathUnderWorkOrdersRoot -Path $runtimePath -ToolkitRoot $ToolkitRoot
}

function Get-WorkOrderFilePath {
    param(
        [Parameter(Mandatory)][string]$CaseId,
        [string]$ToolkitRoot = ''
    )

    return Resolve-WorkOrderFilePath -CaseId $CaseId -ToolkitRoot $ToolkitRoot
}

function Get-ActiveWorkOrderPointer {
    param([string]$ToolkitRoot = '')

    if ([string]::IsNullOrWhiteSpace($ToolkitRoot)) {
        $ToolkitRoot = Get-WorkOrderToolkitRoot
    }

    # Pointer file is source of truth. Env is only accepted when it matches the pointer
    # and the work order Status is Open.
    $pointerCaseId = $null
    $pointerPath = Get-ActiveWorkOrderPointerPath -ToolkitRoot $ToolkitRoot
    if (Test-Path -LiteralPath $pointerPath) {
        try {
            $ptr = Get-Content -LiteralPath $pointerPath -Raw | ConvertFrom-Json
            $pointerCaseId = [string]$ptr.CaseId
            if (-not [string]::IsNullOrWhiteSpace($pointerCaseId) -and (Test-ValidCaseId -CaseId $pointerCaseId)) {
                # Re-resolve from CaseId; do not trust ptr.WorkOrderPath.
                $workPath = Get-WorkOrderFilePath -CaseId $pointerCaseId -ToolkitRoot $ToolkitRoot
                if (Test-Path -LiteralPath $workPath) {
                    $order = Get-Content -LiteralPath $workPath -Raw | ConvertFrom-Json
                    if ([string]$order.Status -eq 'Open') {
                        $env:CDE_ACTIVE_CASE_ID = $pointerCaseId
                        return [PSCustomObject]@{
                            CaseId        = $pointerCaseId
                            WorkOrderPath = $workPath
                            Source        = 'PointerFile'
                        }
                    }
                }
            }
        } catch {
            # fall through
        }
    }

    $envCase = if (-not [string]::IsNullOrWhiteSpace($env:CDE_ACTIVE_CASE_ID)) { $env:CDE_ACTIVE_CASE_ID.Trim() } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($envCase) -and
        -not [string]::IsNullOrWhiteSpace($pointerCaseId) -and
        $envCase -eq $pointerCaseId -and
        (Test-ValidCaseId -CaseId $envCase)) {
        try {
            $path = Get-WorkOrderFilePath -CaseId $envCase -ToolkitRoot $ToolkitRoot
            if (Test-Path -LiteralPath $path) {
                $order = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
                if ([string]$order.Status -eq 'Open') {
                    return [PSCustomObject]@{
                        CaseId        = $envCase
                        WorkOrderPath = $path
                        Source        = 'Environment'
                    }
                }
            }
        } catch {
            return $null
        }
    }

    return $null
}

function Set-ActiveWorkOrderPointer {
    param(
        [Parameter(Mandatory)][string]$CaseId,
        [string]$WorkOrderPath = '',
        [string]$ToolkitRoot = ''
    )

    if ([string]::IsNullOrWhiteSpace($ToolkitRoot)) {
        $ToolkitRoot = Get-WorkOrderToolkitRoot
    }

    $CaseId = Assert-ValidCaseId -CaseId $CaseId
    # Always re-resolve under known roots; do not persist caller-supplied absolute paths unverified.
    $WorkOrderPath = Get-WorkOrderFilePath -CaseId $CaseId -ToolkitRoot $ToolkitRoot

    $runtimeDir = Get-WorkOrderRuntimeDirectory -ToolkitRoot $ToolkitRoot
    if (-not (Test-Path -LiteralPath $runtimeDir)) {
        New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
    }

    $pointerPath = Get-ActiveWorkOrderPointerPath -ToolkitRoot $ToolkitRoot
    [PSCustomObject]@{
        CaseId        = $CaseId
        WorkOrderPath = $WorkOrderPath
        ActivatedAt   = (Get-Date).ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $pointerPath -Encoding UTF8

    $env:CDE_ACTIVE_CASE_ID = $CaseId
}

function Clear-ActiveWorkOrderPointer {
    param([string]$ToolkitRoot = '')

    if ([string]::IsNullOrWhiteSpace($ToolkitRoot)) {
        $ToolkitRoot = Get-WorkOrderToolkitRoot
    }

    $pointerPath = Get-ActiveWorkOrderPointerPath -ToolkitRoot $ToolkitRoot
    if (Test-Path -LiteralPath $pointerPath) {
        Remove-Item -LiteralPath $pointerPath -Force -ErrorAction SilentlyContinue
    }

    $env:CDE_ACTIVE_CASE_ID = $null
}

function Get-WorkOrderKeyFindingsFromWorkflow {
    param(
        [Parameter(Mandatory)]
        $WorkflowResult
    )

    $findings = [System.Collections.Generic.List[object]]::new()
    foreach ($step in @($WorkflowResult.Steps)) {
        if ($step.Status -notin @('Warn', 'Fail')) {
            continue
        }

        $detail = if ($step.Output) { [string]$step.Output } elseif ($step.Detail) { [string]$step.Detail } else { '' }
        if ($detail.Length -gt 280) { $detail = $detail.Substring(0, 280) + '...' }
        $findings.Add([PSCustomObject]@{
            Step   = if ($step.Name) { [string]$step.Name } else { 'Step' }
            Status = [string]$step.Status
            Detail = $detail
        }) | Out-Null

        if ($findings.Count -ge 8) {
            break
        }
    }

    if ($findings.Count -eq 0) {
        $overall = if ($WorkflowResult.PSObject.Properties.Name -contains 'OverallHealth' -and $WorkflowResult.OverallHealth) {
            [string]$WorkflowResult.OverallHealth
        } else {
            'Healthy'
        }
        $findings.Add([PSCustomObject]@{
            Step   = 'Overall'
            Status = 'Pass'
            Detail = "No warnings or failures recorded. Health: $overall."
        }) | Out-Null
    }

    return @($findings)
}

function Get-WorkOrderSummaryFromWorkflow {
    param(
        [Parameter(Mandatory)]
        $WorkflowResult
    )

    $steps = @($WorkflowResult.Steps)
    $counts = Get-WorkflowStepCounts -Steps $steps
    $overall = if ($WorkflowResult.PSObject.Properties.Name -contains 'OverallHealth' -and $WorkflowResult.OverallHealth) {
        [string]$WorkflowResult.OverallHealth
    } else {
        Get-WorkflowOverallHealth -Steps $steps
    }

    $issueLines = [System.Collections.Generic.List[string]]::new()
    foreach ($step in $steps) {
        if ($step.Status -in @('Warn', 'Fail')) {
            $detail = if ($step.Output) { [string]$step.Output } elseif ($step.Detail) { [string]$step.Detail } else { '' }
            if ($detail.Length -gt 180) { $detail = $detail.Substring(0, 180) + '...' }
            $issueLines.Add("$($step.Name): $($step.Status) - $detail") | Out-Null
        }
    }

    $summary = if ($issueLines.Count -gt 0) {
        ($issueLines | Select-Object -First 3) -join ' | '
    } else {
        "Completed - $overall ($($counts.Pass) pass, $($counts.Warn) warn, $($counts.Fail) fail)"
    }

    return [PSCustomObject]@{
        OverallHealth = $overall
        Pass          = $counts.Pass
        Warn          = $counts.Warn
        Fail          = $counts.Fail
        Summary       = $summary
    }
}

function New-WorkOrder {
    param(
        [string]$TechnicianNotes = '',
        [string]$ClientName = '',
        [string]$ClientPhone = '',
        [string]$ToolkitRoot = ''
    )

    if ([string]::IsNullOrWhiteSpace($ToolkitRoot)) {
        $ToolkitRoot = Get-WorkOrderToolkitRoot
    }

    $existing = Get-ActiveWorkOrderPointer -ToolkitRoot $ToolkitRoot
    if ($existing -and (Test-Path -LiteralPath $existing.WorkOrderPath)) {
        # Get-ActiveWorkOrderPointer already requires Status -eq Open.
        throw "Work order already active: $($existing.CaseId). Close it before starting a new one."
    }

    $idInfo = Get-NextCaseId -ToolkitRoot $ToolkitRoot
    $ordersDir = Get-InternalWorkOrdersDirectory -ToolkitRoot $ToolkitRoot
    if (-not (Test-Path -LiteralPath $ordersDir)) {
        New-Item -ItemType Directory -Force -Path $ordersDir | Out-Null
    }

    $workPath = Get-WorkOrderFilePath -CaseId $idInfo.CaseId -ToolkitRoot $ToolkitRoot
    $envMode = if (Get-Command Get-EnvironmentMode -ErrorAction SilentlyContinue) {
        Get-EnvironmentMode
    } else {
        'Windows'
    }

    $order = [PSCustomObject]@{
        CaseId             = $idInfo.CaseId
        Sequence           = $idInfo.Sequence
        Status             = 'Open'
        CreatedAt          = (Get-Date).ToString('o')
        ClosedAt           = $null
        MachineName        = $env:COMPUTERNAME
        UserName           = $env:USERNAME
        ClientName         = $ClientName
        ClientPhone        = $ClientPhone
        TechnicianNotes    = $TechnicianNotes
        EnvironmentHistory = @($envMode)
        Runs               = @()
    }

    $order | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $workPath -Encoding UTF8
    Set-ActiveWorkOrderPointer -CaseId $idInfo.CaseId -WorkOrderPath $workPath -ToolkitRoot $ToolkitRoot

    return [PSCustomObject]@{
        CaseId        = $idInfo.CaseId
        WorkOrderPath = $workPath
        WorkOrder     = $order
    }
}

function Get-WorkOrder {
    param(
        [Parameter(Mandatory)][string]$CaseId,
        [string]$ToolkitRoot = ''
    )

    $path = Get-WorkOrderFilePath -CaseId $CaseId -ToolkitRoot $ToolkitRoot
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Work order not found: $CaseId"
    }

    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}

function Save-WorkOrder {
    param(
        [Parameter(Mandatory)]
        $WorkOrder,
        [string]$ToolkitRoot = ''
    )

    $path = Get-WorkOrderFilePath -CaseId $WorkOrder.CaseId -ToolkitRoot $ToolkitRoot
    $WorkOrder | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path -Encoding UTF8
}

function Update-WorkOrderNotes {
    param(
        [string]$TechnicianNotes = '',
        [string]$ClientName = '',
        [string]$ClientPhone = '',
        [string]$ToolkitRoot = ''
    )

    $active = Get-ActiveWorkOrderPointer -ToolkitRoot $ToolkitRoot
    if (-not $active) {
        throw 'No active work order.'
    }

    $order = Get-WorkOrder -CaseId $active.CaseId -ToolkitRoot $ToolkitRoot
    $order.TechnicianNotes = $TechnicianNotes
    if ($PSBoundParameters.ContainsKey('ClientName')) {
        $order.ClientName = $ClientName
    }
    if ($PSBoundParameters.ContainsKey('ClientPhone')) {
        $order.ClientPhone = $ClientPhone
    }
    Save-WorkOrder -WorkOrder $order -ToolkitRoot $ToolkitRoot
    return $order
}

function Add-WorkOrderRun {
    param(
        [Parameter(Mandatory)]
        $WorkflowResult,
        [string]$ReportJsonPath = '',
        [string]$ReportHtmlPath = '',
        [string]$ToolkitRoot = ''
    )

    $active = Get-ActiveWorkOrderPointer -ToolkitRoot $ToolkitRoot
    if (-not $active) {
        return $null
    }

    $order = Get-WorkOrder -CaseId $active.CaseId -ToolkitRoot $ToolkitRoot
    if ($order.Status -ne 'Open') {
        return $null
    }

    if ($ReportJsonPath) {
        foreach ($existingRun in @($order.Runs)) {
            $existingJson = $existingRun.PSObject.Properties['ReportJson'].Value
            if ($existingJson -and $existingJson -eq $ReportJsonPath) {
                return $order
            }
        }
    }

    $meta = Get-WorkOrderSummaryFromWorkflow -WorkflowResult $WorkflowResult
    $keyFindings = Get-WorkOrderKeyFindingsFromWorkflow -WorkflowResult $WorkflowResult
    $envMode = if ($WorkflowResult.EnvironmentMode) { [string]$WorkflowResult.EnvironmentMode } else { 'Unknown' }
    if (@($order.EnvironmentHistory) -notcontains $envMode) {
        $order.EnvironmentHistory = @(@($order.EnvironmentHistory) + $envMode)
    }

    $run = [PSCustomObject]@{
        WorkflowName   = [string]$WorkflowResult.WorkflowName
        CompletedAt    = if ($WorkflowResult.EndTime) { $WorkflowResult.EndTime.ToString('o') } else { (Get-Date).ToString('o') }
        Status         = [string]$WorkflowResult.Status
        OverallHealth  = $meta.OverallHealth
        Pass           = $meta.Pass
        Warn           = $meta.Warn
        Fail           = $meta.Fail
        Summary        = $meta.Summary
        KeyFindings    = @($keyFindings)
        ReportJson     = $ReportJsonPath
        ReportHtml     = $ReportHtmlPath
        Environment    = $envMode
        EventKind      = 'Workflow'
        DisplayLabel   = [string]$WorkflowResult.WorkflowName
        SourceArtifact = ''
    }

    $runs = [System.Collections.Generic.List[object]]::new()
    foreach ($r in @($order.Runs)) { $runs.Add($r) | Out-Null }
    $runs.Add($run) | Out-Null
    $order.Runs = @($runs)

    Save-WorkOrder -WorkOrder $order -ToolkitRoot $ToolkitRoot
    Write-Log "Work order $($order.CaseId): recorded run $($run.WorkflowName)"
    return $order
}

function Add-WorkOrderCaseEvent {
    <#
    .SYNOPSIS Appends a non-workflow case event (CHU pre-boot, CST scan, etc.) to the active work order.
    #>
    param(
        [Parameter(Mandatory)][string]$EventKind,
        [Parameter(Mandatory)][string]$DisplayLabel,
        [string]$SourceArtifact = '',
        [string]$OverallHealth = 'Healthy',
        [string]$Summary = '',
        [string]$WorkflowName = '',
        [string]$ToolkitRoot = ''
    )

    $active = Get-ActiveWorkOrderPointer -ToolkitRoot $ToolkitRoot
    if (-not $active) {
        return $null
    }

    $order = Get-WorkOrder -CaseId $active.CaseId -ToolkitRoot $ToolkitRoot
    if ($order.Status -ne 'Open') {
        return $null
    }

    if ($SourceArtifact) {
        $duplicate = @($order.Runs) | Where-Object { $_.SourceArtifact -eq $SourceArtifact } | Select-Object -First 1
        if ($duplicate) {
            return $order
        }
    }

    $wfName = if ([string]::IsNullOrWhiteSpace($WorkflowName)) { $EventKind } else { $WorkflowName }
    $run = [PSCustomObject]@{
        WorkflowName   = $wfName
        CompletedAt    = (Get-Date).ToString('o')
        Status         = 'Completed'
        OverallHealth  = $OverallHealth
        Pass           = 0
        Warn           = 0
        Fail           = 0
        Summary        = $Summary
        KeyFindings    = @()
        ReportJson     = ''
        ReportHtml     = ''
        Environment    = if ($env:CDE_WINPE -eq '1') { 'WinPE' } else { 'Windows' }
        EventKind      = $EventKind
        DisplayLabel   = $DisplayLabel
        SourceArtifact = $SourceArtifact
    }

    $runs = [System.Collections.Generic.List[object]]::new()
    foreach ($r in @($order.Runs)) { $runs.Add($r) | Out-Null }
    $runs.Add($run) | Out-Null
    $order.Runs = @($runs)

    Save-WorkOrder -WorkOrder $order -ToolkitRoot $ToolkitRoot
    Write-Log "Work order $($order.CaseId): recorded case event $EventKind"
    return $order
}

function Close-WorkOrder {
    param(
        [string]$CaseId = '',
        [string]$TechnicianNotes = '',
        [string]$ToolkitRoot = ''
    )

    if ([string]::IsNullOrWhiteSpace($ToolkitRoot)) {
        $ToolkitRoot = Get-WorkOrderToolkitRoot
    }

    $active = Get-ActiveWorkOrderPointer -ToolkitRoot $ToolkitRoot
    if ([string]::IsNullOrWhiteSpace($CaseId) -and $active) {
        $CaseId = $active.CaseId
    }

    if ([string]::IsNullOrWhiteSpace($CaseId)) {
        throw 'No active work order to close.'
    }

    $CaseId = Assert-ValidCaseId -CaseId $CaseId
    $order = Get-WorkOrder -CaseId $CaseId -ToolkitRoot $ToolkitRoot
    if (-not [string]::IsNullOrWhiteSpace($TechnicianNotes)) {
        $order.TechnicianNotes = $TechnicianNotes
        Save-WorkOrder -WorkOrder $order -ToolkitRoot $ToolkitRoot
    }

    # Export PDF first while Status stays Open on disk. On PDF failure do not mark Closed
    # or clear the pointer (aligns with C# CloseActiveWorkOrder).
    $result = Export-WorkOrderReport -WorkOrder $order -ToolkitRoot $ToolkitRoot

    $order = Get-WorkOrder -CaseId $CaseId -ToolkitRoot $ToolkitRoot
    $order.Status = 'Closed'
    $order.ClosedAt = (Get-Date).ToString('o')
    $order | Add-Member -NotePropertyName FinalReportPdf -NotePropertyValue $result.PdfPath -Force
    Save-WorkOrder -WorkOrder $order -ToolkitRoot $ToolkitRoot
    Clear-ActiveWorkOrderPointer -ToolkitRoot $ToolkitRoot

    return [PSCustomObject]@{
        CaseId    = $CaseId
        WorkOrder = $order
        PdfPath   = $result.PdfPath
        JsonPath  = $result.JsonPath
    }
}

function Export-WorkOrderReport {
    param(
        [Parameter(Mandatory)]
        $WorkOrder,
        [string]$ToolkitRoot = ''
    )

    if ([string]::IsNullOrWhiteSpace($ToolkitRoot)) {
        $ToolkitRoot = Get-WorkOrderToolkitRoot
    }

    $operatorDir = Get-OperatorWorkOrdersDirectory -ToolkitRoot $ToolkitRoot
    if (-not (Test-Path -LiteralPath $operatorDir)) {
        New-Item -ItemType Directory -Force -Path $operatorDir | Out-Null
    }

    $jsonPath = Get-WorkOrderFilePath -CaseId $WorkOrder.CaseId -ToolkitRoot $ToolkitRoot
    $pdfPath = Assert-PathUnderWorkOrdersRoot -Path (Join-Path $operatorDir "$($WorkOrder.CaseId).pdf") -ToolkitRoot $ToolkitRoot

    $errorMessage = ''
    $generated = Invoke-WorkOrderReportPdf -OrderJsonPath $jsonPath -PdfPath $pdfPath -ToolkitRoot $ToolkitRoot -ErrorMessage ([ref]$errorMessage)
    if (-not $generated) {
        throw "Unable to generate work order PDF: $errorMessage"
    }

    $WorkOrder | Add-Member -NotePropertyName FinalReportPdf -NotePropertyValue $pdfPath -Force
    Save-WorkOrder -WorkOrder $WorkOrder -ToolkitRoot $ToolkitRoot
    Write-Log "Work order final report saved: $pdfPath"

    return [PSCustomObject]@{
        PdfPath  = $pdfPath
        JsonPath = $jsonPath
    }
}

function Invoke-WorkOrderReportPdf {
    param(
        [Parameter(Mandatory)][string]$OrderJsonPath,
        [Parameter(Mandatory)][string]$PdfPath,
        [string]$ToolkitRoot = '',
        [ref]$ErrorMessage = ([ref]'')
    )

    if ([string]::IsNullOrWhiteSpace($ToolkitRoot)) {
        $ToolkitRoot = Get-WorkOrderToolkitRoot
    }

    $candidates = @(
        (Join-Path $ToolkitRoot 'CDE\ToolkitGUI\bin\Release\net8.0-windows\ToolkitGUI.dll'),
        (Join-Path $ToolkitRoot 'App\ToolkitGUI\bin\Release\net8.0-windows\ToolkitGUI.dll')
    )

    foreach ($dllPath in $candidates) {
        if (-not (Test-Path -LiteralPath $dllPath)) {
            continue
        }

        try {
            $assembly = [Reflection.Assembly]::LoadFrom($dllPath)
            $type = $assembly.GetType('ToolkitGUI.Services.WorkOrderReportPdfService')
            if (-not $type) {
                continue
            }

            $method = $type.GetMethod('TryGenerateFromJsonFile')
            if (-not $method) {
                continue
            }

            $errorOut = ''
            $args = @($OrderJsonPath, $PdfPath, [ref]$errorOut)
            $ok = [bool]$method.Invoke($null, $args)
            if ($ok) {
                return $true
            }

            $ErrorMessage.Value = $errorOut
            return $false
        } catch {
            $ErrorMessage.Value = $_.Exception.Message
            return $false
        }
    }

    $ErrorMessage.Value = 'ToolkitGUI.dll not found. Publish the toolkit before closing work orders from PowerShell.'
    return $false
}
