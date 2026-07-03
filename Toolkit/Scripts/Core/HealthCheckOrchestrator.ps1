#Requires -Version 5.1
<#
.SYNOPSIS
    Helpers for SystemHealthCheck orchestration: catalog load, phase/recommendation output, child merge.
#>

function Get-HealthCheckCatalogPath {
    $coreDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $MyInvocation.MyCommand.Path }
    return (Join-Path (Join-Path $coreDir '..\..') 'Config\HealthCheckCatalog.json')
}

function Get-HealthCheckCatalog {
    $path = Get-HealthCheckCatalogPath
    if (-not (Test-Path $path)) {
        throw "Health check catalog not found: $path"
    }
    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}

function Get-HealthCheckCatalogIds {
    param($Catalog)
    $ids = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($cat in @($Catalog.categories)) {
        foreach ($check in @($cat.checks)) {
            if ($check.id) { [void]$ids.Add([string]$check.id) }
        }
    }
    return $ids
}

function Get-HealthCheckLabel {
    param($Catalog, [string]$CheckId)
    foreach ($cat in @($Catalog.categories)) {
        foreach ($check in @($cat.checks)) {
            if ([string]$check.id -eq $CheckId) { return [string]$check.label }
        }
    }
    return $CheckId
}

function Write-HealthPhaseLine {
    param(
        [string]$CheckId,
        [string]$Label,
        [int]$Index,
        [int]$Total
    )
    $payload = @{
        checkId = $CheckId
        label   = $Label
        index   = $Index
        total   = $Total
    } | ConvertTo-Json -Compress
    Write-Host "[HEALTH:PHASE] $payload"
}

function Write-HealthRecommendationLine {
    param(
        [string]$CheckId,
        [string]$NavTarget,
        [string]$Title,
        [string]$Reason
    )
    $payload = @{
        checkId   = $CheckId
        navTarget = $NavTarget
        title     = $Title
        reason    = $Reason
    } | ConvertTo-Json -Compress
    Write-Host "[HEALTH:RECOMMENDATION] $payload"
}

function Add-CheckIdToNewSteps {
    param($WorkflowResult, [int]$BeforeCount, [string]$CheckId)
    for ($i = $BeforeCount; $i -lt $WorkflowResult.Steps.Count; $i++) {
        $step = $WorkflowResult.Steps[$i]
        if ($step.PSObject.Properties.Name -notcontains 'CheckId') {
            $step | Add-Member -NotePropertyName CheckId -NotePropertyValue $CheckId -Force
        }
    }
}

function Get-HealthCheckRuleNavTarget {
    param($Rule)
    $legacy = [string]$Rule.navTarget
    if (-not [string]::IsNullOrWhiteSpace($legacy)) {
        return $legacy.Trim()
    }
    foreach ($action in @($Rule.actions)) {
        $type = ([string]$action.type).Trim().ToLowerInvariant()
        $target = ([string]$action.target).Trim()
        if ($type -eq 'cde' -and -not [string]::IsNullOrWhiteSpace($target)) {
            return $target
        }
    }
    return ''
}

function Test-HealthCheckUsbSmartLimitation {
    param([string]$Detail)
    return -not [string]::IsNullOrWhiteSpace($Detail) `
        -and $Detail.IndexOf('USB bridge does not pass ATA commands', [StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Invoke-HealthCheckRecommendations {
    param(
        $WorkflowResult,
        $Catalog,
        [int]$FromStepIndex
    )
    if (-not $Catalog.recommendations) { return }
    for ($i = $FromStepIndex; $i -lt $WorkflowResult.Steps.Count; $i++) {
        $step = $WorkflowResult.Steps[$i]
        $checkId = if ($step.PSObject.Properties.Name -contains 'CheckId') { [string]$step.CheckId } else { '' }
        $status = [string]$step.Status
        $detail = if ($step.PSObject.Properties.Name -contains 'Detail') { [string]$step.Detail } else { '' }
        if ([string]::IsNullOrWhiteSpace($detail) -and $step.PSObject.Properties.Name -contains 'Output') {
            $detail = [string]$step.Output
        }
        if (Test-HealthCheckUsbSmartLimitation -Detail $detail) { continue }
        foreach ($rule in @($Catalog.recommendations)) {
            if ([string]$rule.whenCheckId -ne $checkId) { continue }
            $statuses = @($rule.whenStatus)
            if ($statuses -notcontains $status) { continue }
            $navTarget = Get-HealthCheckRuleNavTarget -Rule $rule
            if ([string]::IsNullOrWhiteSpace($navTarget)) { continue }
            $reason = [string]$rule.reasonTemplate
            $reason = $reason.Replace('{Detail}', $detail)
            Write-HealthRecommendationLine -CheckId $checkId `
                -NavTarget $navTarget `
                -Title ([string]$rule.title) `
                -Reason $reason
        }
    }
}

function ConvertFrom-ChildWorkflowJsonText {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    try {
        $parsed = $Text | ConvertFrom-Json
        if ($parsed.Steps) { return $parsed }
    } catch {}

    $marker = '"WorkflowName"'
    $searchAt = $Text.Length
    while ($true) {
        $markerIndex = $Text.LastIndexOf($marker, $searchAt - 1, [System.StringComparison]::Ordinal)
        if ($markerIndex -lt 0) { break }

        $start = $Text.LastIndexOf('{', $markerIndex)
        if ($start -ge 0) {
            $slice = Get-JsonObjectSlice -Text $Text -StartIndex $start
            if ($slice) {
                try {
                    $parsed = $slice | ConvertFrom-Json
                    if ($parsed.Steps) { return $parsed }
                } catch {}
            }
        }

        if ($markerIndex -eq 0) { break }
        $searchAt = $markerIndex
    }

    return $null
}

function Get-JsonObjectSlice {
    param(
        [string]$Text,
        [int]$StartIndex
    )

    if ($StartIndex -lt 0 -or $StartIndex -ge $Text.Length) { return $null }
    if ($Text[$StartIndex] -ne '{') { return $null }

    $depth = 0
    $inString = $false
    $escape = $false
    for ($i = $StartIndex; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($inString) {
            if ($escape) {
                $escape = $false
                continue
            }
            if ($ch -eq '\') {
                $escape = $true
                continue
            }
            if ($ch -eq '"') {
                $inString = $false
            }
            continue
        }

        if ($ch -eq '"') {
            $inString = $true
            continue
        }
        if ($ch -eq '{') { $depth++ }
        elseif ($ch -eq '}') {
            $depth--
            if ($depth -eq 0) {
                return $Text.Substring($StartIndex, $i - $StartIndex + 1)
            }
        }
    }

    return $null
}

function Merge-ChildWorkflowJson {
    param(
        $WorkflowResult,
        [string]$ScriptPath,
        [hashtable]$Arguments = @{},
        [string]$CheckId
    )
    $before = $WorkflowResult.Steps.Count
    try {
        $output = if ($Arguments.Count -gt 0) {
            & $ScriptPath @Arguments 2>&1 | ForEach-Object { "$_" }
        } else {
            & $ScriptPath 2>&1 | ForEach-Object { "$_" }
        }
        $text = ($output -join "`n").Trim()
        if ([string]::IsNullOrWhiteSpace($text)) {
            $WorkflowResult.Steps.Add([PSCustomObject]@{
                Name    = $CheckId
                Status  = 'Fail'
                Detail  = 'Child workflow returned no output.'
                Output  = 'Child workflow returned no output.'
                CheckId = $CheckId
            })
            return
        }

        $json = ConvertFrom-ChildWorkflowJsonText -Text $text

        if ($null -eq $json -or -not $json.Steps) {
            $WorkflowResult.Steps.Add([PSCustomObject]@{
                Name    = $CheckId
                Status  = 'Fail'
                Detail  = if (Test-Path -LiteralPath $ScriptPath) {
                    'Failed to parse child workflow JSON.'
                } else {
                    "Child workflow script not found: $ScriptPath"
                }
                Output  = if ($text.Length -gt 500) { $text.Substring(0, 500) } else { $text }
                CheckId = $CheckId
            })
            return
        }

        foreach ($step in @($json.Steps)) {
            if ($step.PSObject.Properties.Name -notcontains 'CheckId') {
                $step | Add-Member -NotePropertyName CheckId -NotePropertyValue $CheckId -Force
            }
            $WorkflowResult.Steps.Add($step)
        }
    } catch {
        $WorkflowResult.Steps.Add([PSCustomObject]@{
            Name    = $CheckId
            Status  = 'Fail'
            Detail  = $_.Exception.Message
            Output  = $_.Exception.Message
            CheckId = $CheckId
        })
    }
    Add-CheckIdToNewSteps -WorkflowResult $WorkflowResult -BeforeCount $before -CheckId $CheckId
}

function Normalize-WorkflowStepOutput {
    param($WorkflowResult)
    foreach ($step in $WorkflowResult.Steps) {
        if ($step.PSObject.Properties.Name -contains 'Detail') {
            $detail = [string]$step.Detail
            if ($step.PSObject.Properties.Name -notcontains 'Output' -or [string]::IsNullOrWhiteSpace([string]$step.Output)) {
                $step | Add-Member -NotePropertyName Output -NotePropertyValue $detail -Force
            }
        }
    }
}
