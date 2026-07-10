#Requires -Version 5.1
# Startup-entry scan orchestration for CST (dot-sourced from CoreSecurityTool.psm1).
# Does not add a new scan Mode — wraps CustomScan + synthetic persistence + cmdline analysis.

function Resolve-CstStartupEntryKind {
    param(
        [string]$RowType = '',
        [string]$SourceGroup = '',
        [string]$Category = ''
    )

    $blob = ('{0} {1} {2}' -f $RowType, $SourceGroup, $Category).ToLowerInvariant()
    if ($blob -match 'schedul|task') { return 'ScheduledTask' }
    if ($blob -match 'service|driver') { return 'Service' }
    if ($blob -match 'folder|startup folder|\.lnk') { return 'StartupFolder' }
    if ($blob -match 'msix') { return 'RunKey' }
    return 'RunKey'
}

function Resolve-CstStartupScanTargets {
    param(
        [Parameter(Mandatory)]$Entry
    )

    $targets = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    $add = {
        param([string]$Path)
        if ([string]::IsNullOrWhiteSpace($Path)) { return }
        $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
        if (-not (Test-Path -LiteralPath $expanded -PathType Leaf -ErrorAction SilentlyContinue)) { return }
        try { $full = (Get-Item -LiteralPath $expanded -ErrorAction Stop).FullName } catch { $full = $expanded }
        if ($seen.Add($full)) { [void]$targets.Add($full) }
    }

    if ($Entry.PSObject.Properties['resolvedPaths']) {
        foreach ($p in @($Entry.resolvedPaths)) { & $add ([string]$p) }
    }

    $commandLine = ''
    if ($Entry.PSObject.Properties['commandLine']) { $commandLine = [string]$Entry.commandLine }
    elseif ($Entry.PSObject.Properties['FilePath']) { $commandLine = [string]$Entry.FilePath }

    if (-not [string]::IsNullOrWhiteSpace($commandLine)) {
        # Prefer -File / -f script payloads.
        $fileMatch = [regex]::Match($commandLine, '(?i)(?:^|\s)(?:-File|/File|-f)\s+(?:"([^"]+)"|(\S+))')
        if ($fileMatch.Success) {
            $scriptPath = if ($fileMatch.Groups[1].Success) { $fileMatch.Groups[1].Value } else { $fileMatch.Groups[2].Value.TrimEnd(',', ';') }
            & $add $scriptPath
        }

        foreach ($m in [regex]::Matches($commandLine, '"([^"]+)"')) {
            & $add $m.Groups[1].Value
        }

        if (Get-Command Get-CstPathFromCommandLine -ErrorAction SilentlyContinue) {
            $parsed = Get-CstPathFromCommandLine -CommandLine $commandLine
            if (-not [string]::IsNullOrWhiteSpace($parsed)) { & $add $parsed }
        }

        # Host exe when distinct from payload (powershell.exe + script).
        $hostMatch = [regex]::Match($commandLine, '(?i)^(?:"(?<q>[^"]+\.exe)"|(?<u>[^\s"]+\.exe))\b')
        if ($hostMatch.Success) {
            $hostPath = if ($hostMatch.Groups['q'].Success) { $hostMatch.Groups['q'].Value } else { $hostMatch.Groups['u'].Value }
            & $add $hostPath
        }
    }

    return @($targets)
}

function Test-CstStartupCommandLine {
    param(
        [Parameter(Mandatory)][string]$CommandLine,
        [Parameter(Mandatory)]$Rules,
        [string]$LocationLabel = 'StartupCommandLine'
    )

    $findings = @()
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $findings }

    $cmd = [string]$CommandLine
    $cmdLower = $cmd.ToLowerInvariant()

    # High-signal interpreter abuse patterns (no path gating).
    $builtin = @(
        @{ name = 'PS_EncodedCommand'; type = 'Malware'; severity = 'High'; confidence = 0.9; mode = 'any'; needles = @('-enc', '-encodedcommand', '-ec ') },
        @{ name = 'PS_DownloadCradle'; type = 'Malware'; severity = 'High'; confidence = 0.88; mode = 'any'; needles = @('downloadstring', 'downloadfile', 'invoke-webrequest', 'iwr ', 'wget ', 'curl ') },
        @{ name = 'PS_IEX_Pipeline'; type = 'Malware'; severity = 'High'; confidence = 0.86; mode = 'any'; needles = @('iex ', 'invoke-expression', '| iex', '|iex') },
        @{ name = 'HiddenWindow_Bypass'; type = 'Suspicious'; severity = 'Medium'; confidence = 0.7; mode = 'min2'; needles = @('-windowstyle hidden', '-w hidden', '-noprofile', 'bypass') },
        @{ name = 'Mshta_Remote'; type = 'Malware'; severity = 'High'; confidence = 0.85; mode = 'all'; needles = @('mshta', 'http') },
        @{ name = 'Certutil_UrlCache'; type = 'Malware'; severity = 'High'; confidence = 0.88; mode = 'all'; needles = @('certutil', '-urlcache') },
        @{ name = 'Bitsadmin_Transfer'; type = 'Malware'; severity = 'High'; confidence = 0.86; mode = 'all'; needles = @('bitsadmin', '/transfer') },
        @{ name = 'Regsvr32_Scrobj'; type = 'Malware'; severity = 'High'; confidence = 0.87; mode = 'all'; needles = @('regsvr32', 'scrobj') },
        @{ name = 'Cmd_Echo_Pipe'; type = 'Suspicious'; severity = 'Medium'; confidence = 0.72; mode = 'all'; needles = @('cmd', '/c', 'echo') }
    )

    foreach ($rule in $builtin) {
        $hits = New-Object System.Collections.Generic.List[string]
        foreach ($n in @($rule.needles)) {
            $needle = [string]$n
            if ($cmdLower.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                [void]$hits.Add($needle)
            }
        }
        $matched = $false
        switch ([string]$rule.mode) {
            'all'  { $matched = ($hits.Count -ge @($rule.needles).Count) }
            'min2' { $matched = ($hits.Count -ge 2) }
            default { $matched = ($hits.Count -gt 0) }
        }
        if (-not $matched) { continue }

        $findings += ,(New-CstFinding `
            -Type ([string]$rule.type) `
            -Severity ([string]$rule.severity) `
            -Name ([string]$rule.name) `
            -Location $LocationLabel `
            -Evidence ("Command-line match: {0}" -f ($hits -join ', ')) `
            -Detector 'StartupCommandLine' `
            -Confidence ([double]$rule.confidence) `
            -ObjectType 'CommandLine' `
            -CanRemediate $false)
    }

    $yaraRules = @()
    if ($null -ne $Rules -and $Rules.PSObject.Properties['yaraLikeRules']) {
        $yaraRules = @($Rules.yaraLikeRules)
    }

    foreach ($rule in $yaraRules) {
        if ($null -eq $rule) { continue }
        if ($rule.PSObject.Properties['enabled'] -and -not [bool]$rule.enabled) { continue }
        $ruleName = if ($rule.PSObject.Properties['name']) { [string]$rule.name } else { '' }
        if ([string]::IsNullOrWhiteSpace($ruleName)) { continue }
        if ($ruleName -notmatch '^(LOLBin_|PS_|Cmd_|Script_)') { continue }
        if (-not $rule.PSObject.Properties['containsText']) { continue }

        $needles = @($rule.containsText | ForEach-Object { ([string]$_).ToLowerInvariant() } | Where-Object { $_ })
        if ($needles.Count -eq 0) { continue }

        $logic = if ($rule.PSObject.Properties['logic']) { ([string]$rule.logic).ToLowerInvariant() } else { 'all' }
        $hits = @($needles | Where-Object { $cmdLower.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
        $ok = if ($logic -eq 'any') { $hits.Count -gt 0 } else { $hits.Count -ge $needles.Count }
        if (-not $ok) { continue }

        if (@($findings | Where-Object { [string]$_.name -eq $ruleName }).Count -gt 0) { continue }

        $type = if ($rule.PSObject.Properties['type']) { [string]$rule.type } else { 'Malware' }
        $severity = if ($rule.PSObject.Properties['severity']) { [string]$rule.severity } else { 'High' }
        $confidence = if ($rule.PSObject.Properties['confidence']) { [double]$rule.confidence } else { 0.8 }

        $findings += ,(New-CstFinding `
            -Type $type `
            -Severity $severity `
            -Name $ruleName `
            -Location $LocationLabel `
            -Evidence ("Command-line LOLBin/script rule (path gate bypassed): {0}" -f ($hits -join ', ')) `
            -Detector 'StartupCommandLine' `
            -Confidence $confidence `
            -ObjectType 'CommandLine' `
            -CanRemediate $false)
    }

    return @($findings)
}

function New-CstStartupEntryContextFindings {
    param(
        [Parameter(Mandatory)]$Entry,
        [string]$LocationLabel = 'StartupEntryContext'
    )

    $findings = @()
    $risk = ''
    if ($Entry.PSObject.Properties['riskLevel']) { $risk = [string]$Entry.riskLevel }
    $analysis = ''
    if ($Entry.PSObject.Properties['analysisDetail']) { $analysis = [string]$Entry.analysisDetail }
    $signed = $null
    if ($Entry.PSObject.Properties['isSigned']) { $signed = [bool]$Entry.isSigned }
    $hijack = $false
    if ($Entry.PSObject.Properties['isHijackSuspicious']) { $hijack = [bool]$Entry.isHijackSuspicious }
    $deviation = ''
    if ($Entry.PSObject.Properties['deviationReason']) { $deviation = [string]$Entry.deviationReason }

    if ($hijack -or ($risk -match '(?i)warning|caution|high|critical')) {
        $findings += ,(New-CstFinding `
            -Type 'Suspicious' `
            -Severity $(if ($risk -match '(?i)warning|high|critical') { 'High' } else { 'Medium' }) `
            -Name 'StartupManager_RiskContext' `
            -Location $LocationLabel `
            -Evidence ("Startup Manager risk={0}; analysis={1}" -f $(if ($risk) { $risk } else { 'n/a' }), $(if ($analysis) { $analysis } else { 'n/a' })) `
            -Detector 'StartupEntryContext' `
            -Confidence 0.65 `
            -ObjectType 'Persistence' `
            -CanRemediate $false)
    }

    if ($signed -eq $false -and ($risk -match '(?i)warning|caution' -or $hijack)) {
        $findings += ,(New-CstFinding `
            -Type 'Suspicious' `
            -Severity 'Medium' `
            -Name 'StartupManager_UnsignedRisky' `
            -Location $LocationLabel `
            -Evidence 'Unsigned target combined with elevated Startup Manager risk/hijack heuristic.' `
            -Detector 'StartupEntryContext' `
            -Confidence 0.62 `
            -ObjectType 'Persistence' `
            -CanRemediate $false)
    }

    if (-not [string]::IsNullOrWhiteSpace($deviation)) {
        $findings += ,(New-CstFinding `
            -Type 'PUM' `
            -Severity 'High' `
            -Name 'StartupManager_WinlogonDeviation' `
            -Location $LocationLabel `
            -Evidence $deviation `
            -Detector 'StartupEntryContext' `
            -Confidence 0.8 `
            -ObjectType 'Persistence' `
            -CanRemediate $false)
    }

    return @($findings)
}

function Invoke-CstStartupEntryScan {
    param(
        [Parameter(Mandatory)]$StartupEntry,
        [string]$RulesPath,
        [int]$MaxMinutes = 3,
        [switch]$OfflineOnly
    )

    if ($StartupEntry -is [string]) {
        if (-not (Test-Path -LiteralPath $StartupEntry -PathType Leaf)) {
            throw "StartupEntry metadata file not found: $StartupEntry"
        }
        $StartupEntry = Get-Content -LiteralPath $StartupEntry -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($StartupEntry.PSObject.Properties['startupEntry']) {
            $StartupEntry = $StartupEntry.startupEntry
        }
    }

    if ([string]::IsNullOrWhiteSpace($RulesPath)) {
        $RulesPath = Join-Path $PSScriptRoot 'rules\rules.json'
    }
    $rules = Get-CstRuleSet -RulesPath $RulesPath

    $name = if ($StartupEntry.PSObject.Properties['name']) { [string]$StartupEntry.name } else { 'StartupEntry' }
    $commandLine = if ($StartupEntry.PSObject.Properties['commandLine']) { [string]$StartupEntry.commandLine } `
        elseif ($StartupEntry.PSObject.Properties['FilePath']) { [string]$StartupEntry.FilePath } else { '' }
    $registryPath = if ($StartupEntry.PSObject.Properties['registryPath']) { [string]$StartupEntry.registryPath } else { '' }
    $valueName = if ($StartupEntry.PSObject.Properties['valueName']) { [string]$StartupEntry.valueName } else { $name }
    $rowType = if ($StartupEntry.PSObject.Properties['rowType']) { [string]$StartupEntry.rowType } else { '' }
    $sourceGroup = if ($StartupEntry.PSObject.Properties['sourceGroup']) { [string]$StartupEntry.sourceGroup } else { '' }
    $category = if ($StartupEntry.PSObject.Properties['category']) { [string]$StartupEntry.category } else { '' }
    $kind = Resolve-CstStartupEntryKind -RowType $rowType -SourceGroup $sourceGroup -Category $category

    $targets = @(Resolve-CstStartupScanTargets -Entry $StartupEntry)
    $primaryPath = if ($targets.Count -gt 0) { [string]$targets[0] } else { '' }

    $workDir = Join-Path $env:TEMP ('cst-startup-entry-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $workDir | Out-Null
    $artifactPath = Join-Path $workDir 'startup-entry-artifact.json'
    $cmdlineProbePath = $null

    try {
        # Temp probe file so existing yaraLike rules can also fire on cmdline text when extension matches.
        if (-not [string]::IsNullOrWhiteSpace($commandLine)) {
            $cmdlineProbePath = Join-Path $workDir 'startup-cmdline-probe.ps1'
            @(
                '# CST startup-entry command-line probe (synthetic)'
                $commandLine
            ) | Set-Content -LiteralPath $cmdlineProbePath -Encoding UTF8
            if ($targets -notcontains $cmdlineProbePath) {
                $targets = @($targets + $cmdlineProbePath)
            }
        }

        $artifact = New-CstArtifact `
            -Kind $kind `
            -Source 'StartupEntryScan' `
            -Path $(if ($primaryPath) { $primaryPath } else { $commandLine }) `
            -TargetPath $primaryPath `
            -CommandLine $commandLine `
            -Name $valueName `
            -Location $(if ($registryPath) { $registryPath } else { $sourceGroup }) `
            -ObjectType 'Persistence' `
            -Evidence 'Injected from CDE Startup Manager entry scan.' `
            -EntityType 'RegistryPersistence' `
            -SourceChannel 'StartupManager' `
            -EvidenceKind 'SyntheticStartupEntry' `
            -RiskTags @('autorun_persistence', 'startup_entry_scan') `
            -EdgeType 'registered_autorun' `
            -CorrelationStrength 1.0 `
            -ConfidenceDelta 0.2 `
            -Publisher $(if ($StartupEntry.PSObject.Properties['publisher']) { [string]$StartupEntry.publisher } else { '' }) `
            -SignerStatus $(if ($StartupEntry.PSObject.Properties['isSigned'] -and [bool]$StartupEntry.isSigned) { 'Valid' } else { 'Unknown' })

        @{ artifacts = @($artifact) } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $artifactPath -Encoding UTF8

        $cmdlineFindings = @(Test-CstStartupCommandLine -CommandLine $commandLine -Rules $rules -LocationLabel $(if ($commandLine) { $commandLine } else { 'StartupCommandLine' }))
        $contextFindings = @(New-CstStartupEntryContextFindings -Entry $StartupEntry -LocationLabel $(if ($registryPath) { $registryPath } else { $sourceGroup }))

        $customScan = $null
        if ($targets.Count -gt 0) {
            $customScan = Invoke-CstScan `
                -Mode CustomScan `
                -Target $targets `
                -BehaviorArtifactsPath @($artifactPath) `
                -RulesPath $RulesPath `
                -MaxMinutes $MaxMinutes `
                -DetectionScope All `
                -ActionMode ScanOnly `
                -EnablePersistenceCollectors:$false `
                -OfflineOnly:$OfflineOnly
        } else {
            # No file targets — still correlate cmdline/context findings against synthetic artifact.
            $merged = @(Invoke-CstArtifactCorrelation -Findings @($cmdlineFindings + $contextFindings) -Artifacts @($artifact) -Rules $rules)
            $merged = @(Invoke-CstScoreAndDeduplicateFindings -Findings $merged)
            $status = Get-CstStatus -Findings $merged -ScanErrors 0
            $customScan = [PSCustomObject]@{
                status = $status
                exitCode = switch ($status) { 'Fail' { 2 } 'Warn' { 1 } default { 0 } }
                scanMode = 'CustomScan'
                findings = $merged
                suppressedAuditFindings = @()
                summary = [PSCustomObject]@{
                    itemsScanned = 0
                    threatsFound = @($merged | Where-Object { $_.type -eq 'Malware' }).Count
                    warningsFound = @($merged | Where-Object { $_.type -in @('PUP','PUM','Suspicious') }).Count
                    scanErrors = 0
                }
                coverageReason = 'No resolvable file targets for startup entry; command-line/context analysis only.'
                actionSummary = 'Startup entry scan completed without file targets.'
                scanErrorDetails = @()
            }
        }

        # Merge cmdline/context findings when CustomScan ran (avoid duplicates by name+detector).
        if ($targets.Count -gt 0) {
            $existingKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            foreach ($f in @($customScan.findings)) {
                [void]$existingKeys.Add(('{0}|{1}' -f [string]$f.detector, [string]$f.name))
            }
            $extra = @()
            foreach ($f in @($cmdlineFindings + $contextFindings)) {
                $key = '{0}|{1}' -f [string]$f.detector, [string]$f.name
                if ($existingKeys.Add($key)) { $extra += $f }
            }
            if ($extra.Count -gt 0) {
                $all = @(Invoke-CstArtifactCorrelation -Findings @($customScan.findings + $extra) -Artifacts @($artifact) -Rules $rules)
                $all = @(Invoke-CstScoreAndDeduplicateFindings -Findings $all)
                $customScan.findings = $all
                $customScan.summary.threatsFound = @($all | Where-Object { $_.type -eq 'Malware' }).Count
                $customScan.summary.warningsFound = @($all | Where-Object { $_.type -in @('PUP','PUM','Suspicious') }).Count
                $status = Get-CstStatus -Findings $all -ScanErrors $(if ($customScan.summary.PSObject.Properties['scanErrors']) { [int]$customScan.summary.scanErrors } else { 0 })
                $customScan.status = $status
                $customScan.exitCode = switch ($status) { 'Fail' { 2 } 'Warn' { 1 } default { 0 } }
            }
        }

        $findings = @($customScan.findings)
        $fileFindings = @($findings | Where-Object {
            [string]$_.objectType -eq 'File' -or
            ([string]$_.detector -in @('HashIoc','YaraLike','PatternEngine','HeuristicEngine','SignerTrust','ArchiveScan','PeMetadata') -and
             [string]$_.detector -ne 'StartupCommandLine' -and
             [string]$_.detector -ne 'StartupEntryContext')
        } | Where-Object {
            $loc = [string]$_.location
            # Exclude synthetic cmdline probe from "file" bucket when detector is YaraLike on probe only — still count as commandLine if path is probe.
            -not ($cmdlineProbePath -and $loc -and ($loc.Equals($cmdlineProbePath, [StringComparison]::OrdinalIgnoreCase)))
        })

        $probeFindings = @()
        if ($cmdlineProbePath) {
            $probeFindings = @($findings | Where-Object {
                [string]$_.location -and ([string]$_.location).Equals($cmdlineProbePath, [StringComparison]::OrdinalIgnoreCase)
            })
        }

        $cmdFindings = @($findings | Where-Object {
            [string]$_.detector -eq 'StartupCommandLine' -or
            [string]$_.objectType -eq 'CommandLine'
        }) + $probeFindings

        $persistFindings = @($findings | Where-Object {
            (-not [string]::IsNullOrWhiteSpace([string]$_.correlationId)) -or
            [string]$_.detector -eq 'StartupEntryContext' -or
            [string]$_.objectType -eq 'Persistence' -or
            (@($_.correlatedArtifacts).Count -gt 0)
        })

        $rank = {
            param($list)
            if (@($list | Where-Object { $_.type -eq 'Malware' -or $_.severity -match '(?i)critical|high' }).Count -gt 0) { return 'Threat' }
            if (@($list).Count -gt 0) { return 'Suspicious' }
            return 'Clean'
        }

        $fileVerdict = & $rank $fileFindings
        $cmdVerdict = & $rank $cmdFindings
        $persistVerdict = & $rank $persistFindings
        if ($persistFindings.Count -gt 0 -and $persistVerdict -eq 'Suspicious') {
            # Correlated persistence without malware type still surfaces as Correlated for UI clarity.
            if (@($persistFindings | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.correlationId) }).Count -gt 0 -and
                (@($persistFindings | Where-Object { $_.type -eq 'Malware' }).Count -eq 0)) {
                $persistVerdict = 'Correlated'
            }
        }

        $overall = 'Clean'
        foreach ($v in @($fileVerdict, $cmdVerdict, $persistVerdict)) {
            if ($v -eq 'Threat') { $overall = 'Threat'; break }
            if ($v -in @('Suspicious', 'Correlated', 'Review') -and $overall -eq 'Clean') { $overall = 'Suspicious' }
        }
        if ($overall -eq 'Clean' -and [string]$customScan.status -in @('Fail', 'Warn')) {
            $overall = if ([string]$customScan.status -eq 'Fail') { 'Threat' } else { 'Suspicious' }
        }

        $detailFor = {
            param($verdict, $list, $emptyDetail)
            $count = @($list).Count
            if ($count -eq 0) { return $emptyDetail }
            $names = @($list | Select-Object -First 3 | ForEach-Object { [string]$_.name }) -join ', '
            return ('{0}: {1} finding(s) ({2})' -f $verdict, $count, $names)
        }

        return [PSCustomObject]@{
            scanKind = 'StartupEntryScan'
            status = [string]$customScan.status
            exitCode = [int]$customScan.exitCode
            overallVerdict = $overall
            startupEntry = [PSCustomObject]@{
                name = $name
                commandLine = $commandLine
                resolvedPaths = @($targets | Where-Object { $_ -ne $cmdlineProbePath })
                rowType = $rowType
                sourceGroup = $sourceGroup
                registryPath = $registryPath
                valueName = $valueName
                riskLevel = $(if ($StartupEntry.PSObject.Properties['riskLevel']) { [string]$StartupEntry.riskLevel } else { '' })
            }
            targetsScanned = @($targets | Where-Object { $_ -ne $cmdlineProbePath })
            verdicts = [PSCustomObject]@{
                file = [PSCustomObject]@{
                    verdict = $fileVerdict
                    detail = (& $detailFor $fileVerdict $fileFindings 'No file-based threats on resolved targets.')
                    findingIds = @($fileFindings | ForEach-Object { [string]$_.id })
                }
                commandLine = [PSCustomObject]@{
                    verdict = $cmdVerdict
                    detail = (& $detailFor $cmdVerdict $cmdFindings 'No suspicious command-line patterns detected.')
                    findingIds = @($cmdFindings | ForEach-Object { [string]$_.id })
                }
                persistence = [PSCustomObject]@{
                    verdict = $persistVerdict
                    detail = (& $detailFor $persistVerdict $persistFindings 'No persistence correlation or Startup Manager risk context.')
                    findingIds = @($persistFindings | ForEach-Object { [string]$_.id })
                }
            }
            findings = $findings
            suppressedAuditFindings = @($customScan.suppressedAuditFindings)
            customScan = $customScan
            summary = $customScan.summary
            actionSummary = [string]$customScan.actionSummary
            coverageReason = [string]$customScan.coverageReason
            scanErrorDetails = @(
                @($customScan.scanErrorDetails) | ForEach-Object {
                    if ($_ -is [string]) { $_ }
                    elseif ($null -ne $_ -and $_.PSObject.Properties['message']) { [string]$_.message }
                    else { "$_" }
                } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            )
            timestamp = (Get-Date).ToUniversalTime().ToString('o')
        }
    }
    finally {
        try {
            if (Test-Path -LiteralPath $workDir) {
                Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        } catch { }
    }
}
