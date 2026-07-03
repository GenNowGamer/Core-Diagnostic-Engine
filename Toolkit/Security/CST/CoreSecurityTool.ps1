#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Scan','Remediate','Rollback')]
    [string]$Operation = 'Scan',
    [ValidateSet('ThreatScan','FullScan','CustomScan')]
    [string]$Mode = 'ThreatScan',
    [string[]]$Target = @(),
    [string]$RulesPath,
    [string]$OutputPath,
    [int]$MaxMinutes = 15,
    [ValidateSet('All','MalwareOnly','VirusOnly')]
    [string]$DetectionScope = 'All',
    [ValidateSet('ScanOnly','ScanAndRemove','ScanAndQuarantine')]
    [string]$ActionMode = 'ScanOnly',
    [string]$FindingsInputPath,
    [string[]]$SelectedFindingId = @(),
    [ValidateSet('Remove','Quarantine')]
    [string]$RemediationAction = 'Quarantine',
    [string]$RollbackManifestPath,
    [string[]]$SelectedRollbackId = @(),
    [switch]$DisablePersistenceCollectors,
    [switch]$OfflineOnly,
    [switch]$RequireElevation,
    [switch]$AutoElevate,
    [switch]$EmitJson,
    [switch]$ExternalizeSkipLog
)

function Test-CstIsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-CstPowerShellArgumentString {
    param([Parameter(Mandatory)][hashtable]$BoundParameters)

    $tokens = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $BoundParameters.GetEnumerator()) {
        $name = [string]$entry.Key
        $value = $entry.Value

        if ($value -is [switch]) {
            if ([bool]$value) {
                $tokens.Add("-$name") | Out-Null
            }
            continue
        }

        if ($value -is [array]) {
            foreach ($item in $value) {
                $tokens.Add("-$name") | Out-Null
                $tokens.Add(('"{0}"' -f ([string]$item).Replace('"', '""'))) | Out-Null
            }
            continue
        }

        if ($null -ne $value) {
            $tokens.Add("-$name") | Out-Null
            $tokens.Add(('"{0}"' -f ([string]$value).Replace('"', '""'))) | Out-Null
        }
    }

    return ($tokens -join ' ')
}

$isElevated = Test-CstIsElevated
if ($RequireElevation -and -not $isElevated) {
    throw 'CoreSecurityTool requires elevated Administrator privileges for this invocation.'
}

if ($AutoElevate -and -not $isElevated) {
    $relayOutputPath = $null
    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $relayOutputPath = Join-Path $env:TEMP ('cst_relay_' + [guid]::NewGuid().ToString('N') + '.json')
        $OutputPath = $relayOutputPath
    }

    $relaunchParameters = @{}
    foreach ($k in $PSBoundParameters.Keys) {
        if ($k -in @('AutoElevate', 'RequireElevation')) { continue }
        $relaunchParameters[$k] = $PSBoundParameters[$k]
    }
    $relaunchParameters['RequireElevation'] = $true
    $relaunchParameters['OutputPath'] = $OutputPath

    $argString = ConvertTo-CstPowerShellArgumentString -BoundParameters $relaunchParameters
    $launchArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $argString"

    try {
        $child = Start-Process -FilePath 'powershell.exe' -ArgumentList $launchArgs -Verb RunAs -Wait -PassThru
    } catch {
        throw "Elevation request was canceled or failed: $($_.Exception.Message)"
    }

    if ($child.ExitCode -ne 0) {
        exit $child.ExitCode
    }

    if (-not [string]::IsNullOrWhiteSpace($OutputPath) -and (Test-Path $OutputPath)) {
        $elevatedResult = Get-Content -Path $OutputPath -Raw | ConvertFrom-Json
        if ($EmitJson) {
            $elevatedResult | ConvertTo-Json -Depth 12
        } else {
            $elevatedResult
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($relayOutputPath) -and (Test-Path $relayOutputPath)) {
        Remove-Item -Path $relayOutputPath -Force -ErrorAction SilentlyContinue
    }

    exit 0
}

$modulePath = Join-Path $PSScriptRoot 'CoreSecurityTool.psm1'
Import-Module $modulePath -Force -DisableNameChecking

if ($Operation -eq 'Scan') {
    $result = Invoke-CstScan -Mode $Mode -Target $Target -RulesPath $RulesPath -MaxMinutes $MaxMinutes -DetectionScope $DetectionScope -ActionMode $ActionMode -EnablePersistenceCollectors:(-not $DisablePersistenceCollectors) -OfflineOnly:$OfflineOnly
} elseif ($Operation -eq 'Remediate') {
    if ([string]::IsNullOrWhiteSpace($FindingsInputPath) -or -not (Test-Path $FindingsInputPath)) {
        throw "FindingsInputPath is required for remediation and must exist: $FindingsInputPath"
    }

    $scanResult = Get-Content -Path $FindingsInputPath -Raw | ConvertFrom-Json
    if (-not $scanResult.findings) {
        throw "No findings were present in the supplied findings file: $FindingsInputPath"
    }

    $result = Invoke-CstRemediation -Findings $scanResult.findings -Action $RemediationAction -SelectedFindingId $SelectedFindingId
} else {
    if ([string]::IsNullOrWhiteSpace($RollbackManifestPath) -or -not (Test-Path $RollbackManifestPath)) {
        throw "RollbackManifestPath is required for rollback and must exist: $RollbackManifestPath"
    }

    $result = Invoke-CstRollback -RollbackManifestPath $RollbackManifestPath -SelectedRollbackId $SelectedRollbackId
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $dir = Split-Path $OutputPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    if ($Operation -eq 'Scan' -and $result.PSObject.Properties['skipLog'] -and @($result.skipLog).Count -gt 0) {
        $reasonCategoryCounts = [ordered]@{}
        if ($result.summary -and $result.summary.PSObject.Properties['skipReasonCategoryCounts'] -and $null -ne $result.summary.skipReasonCategoryCounts) {
            foreach ($prop in $result.summary.skipReasonCategoryCounts.PSObject.Properties) {
                $reasonCategoryCounts[[string]$prop.Name] = [int]$prop.Value
            }
        }

        $skipEntryCount = @($result.skipLog).Count
        $result | Add-Member -NotePropertyName skipLogSummary -NotePropertyValue ([PSCustomObject]@{
            totalEntries = $skipEntryCount
            truncated = [bool]$result.skipLogTruncated
            reasonCategoryCounts = [PSCustomObject]$reasonCategoryCounts
            externalized = $false
        }) -Force

        if ($ExternalizeSkipLog) {
            $skipLogPath = [System.IO.Path]::ChangeExtension($OutputPath, $null) + '_skiplog.json'
            $skipLogDoc = [PSCustomObject]@{
                timestampUtc = (Get-Date).ToUniversalTime().ToString('o')
                scanMode = [string]$result.scanMode
                summary = [PSCustomObject]@{
                    totalEntries = $skipEntryCount
                    truncated = [bool]$result.skipLogTruncated
                    reasonCategoryCounts = [PSCustomObject]$reasonCategoryCounts
                }
                entries = @($result.skipLog)
            }

            $skipLogDoc | ConvertTo-Json -Depth 8 | Set-Content -Path $skipLogPath -Encoding UTF8

            $artifactList = @($result.artifacts)
            $artifactList += [PSCustomObject]@{
                kind = 'SkipLog'
                source = 'CST'
                name = 'SkipTelemetry'
                location = $skipLogPath
                path = $skipLogPath
                objectType = 'Telemetry'
                state = 'Generated'
                evidence = 'Structured skip reasons externalized from scan result.'
            }
            $result.artifacts = @($artifactList)
            if ($result.PSObject.Properties['artifactSummary']) {
                $result.artifactSummary.totalArtifacts = @($result.artifacts).Count
            }
            $result | Add-Member -NotePropertyName skipLogArtifact -NotePropertyValue $skipLogPath -Force
            $result.skipLogSummary.externalized = $true
        }

        $result.skipLog = @()
    }

    $result | ConvertTo-Json -Depth 12 | Set-Content -Path $OutputPath -Encoding UTF8
}

if ($EmitJson) {
    $result | ConvertTo-Json -Depth 12
} else {
    $result
}
