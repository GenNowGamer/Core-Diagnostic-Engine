# Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
$knownGoodHelper = Join-Path $PSScriptRoot 'Cst.KnownGood.ps1'
$script:CstKnownGoodHelperTrusted = $false
$script:CstKnownGoodHelperStatus = 'NotLoaded'
$script:CstKnownGoodHelperMessage = ''

function Get-CstKnownGoodHelperIntegrityState {
    param(
        [Parameter(Mandatory)][string]$HelperPath,
        [ValidateSet('WarnOnly', 'Enforce')][string]$IntegrityMode = 'WarnOnly'
    )

    if (-not (Test-Path -LiteralPath $HelperPath -PathType Leaf)) {
        return [PSCustomObject]@{
            exists = $false
            trusted = $false
            shouldLoad = $false
            message = "Known-good helper not found: $HelperPath"
        }
    }

    $signatureValid = $false
    $signatureStatus = 'NotEvaluated'
    $expectedHash = ''
    $hashValid = $false
    $hashFilePath = "$HelperPath.sha256"

    if (Get-Command Get-AuthenticodeSignature -ErrorAction SilentlyContinue) {
        try {
            $sig = Get-AuthenticodeSignature -FilePath $HelperPath -ErrorAction Stop
            $signatureStatus = [string]$sig.Status
            $signatureValid = ($signatureStatus -eq 'Valid')
        } catch {
            $signatureStatus = 'Error'
        }
    }

    if (Test-Path -LiteralPath $hashFilePath -PathType Leaf) {
        try {
            $hashLine = (Get-Content -LiteralPath $hashFilePath -ErrorAction Stop | Select-Object -First 1)
            if ($hashLine -match '([A-Fa-f0-9]{64})') {
                $expectedHash = $Matches[1].ToUpperInvariant()
            }
        } catch { }
    }

    if (-not [string]::IsNullOrWhiteSpace($expectedHash)) {
        try {
            $actualHash = (Get-FileHash -LiteralPath $HelperPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
            $hashValid = ($actualHash -eq $expectedHash)
        } catch {
            $hashValid = $false
        }
    }

    $trusted = ($signatureValid -or $hashValid)
    $shouldLoad = if ($trusted) { $true } else { ($IntegrityMode -eq 'WarnOnly') }

    $msg = if ($trusted) {
        "Known-good helper integrity verified (signatureStatus=$signatureStatus, hashValidated=$hashValid)."
    } elseif ($IntegrityMode -eq 'WarnOnly') {
        "Known-good helper integrity could not be verified (signatureStatus=$signatureStatus, hashValidated=$hashValid). Continuing in warn-only mode."
    } else {
        "Known-good helper integrity could not be verified (signatureStatus=$signatureStatus, hashValidated=$hashValid). Helper load blocked by enforce mode."
    }

    return [PSCustomObject]@{
        exists = $true
        trusted = $trusted
        shouldLoad = $shouldLoad
        message = $msg
    }
}

$helperIntegrityModeRaw = [string]$env:CST_HELPER_INTEGRITY_MODE
$helperIntegrityMode = if ($helperIntegrityModeRaw -match '^(?i:enforce)$') { 'Enforce' } else { 'WarnOnly' }
$helperIntegrityState = Get-CstKnownGoodHelperIntegrityState -HelperPath $knownGoodHelper -IntegrityMode $helperIntegrityMode
$script:CstKnownGoodHelperTrusted = [bool]$helperIntegrityState.trusted
$script:CstKnownGoodHelperStatus = if (-not $helperIntegrityState.exists) { 'Missing' } elseif ($helperIntegrityState.trusted) { 'Trusted' } elseif ($helperIntegrityState.shouldLoad) { 'LoadedUntrusted' } else { 'Blocked' }
$script:CstKnownGoodHelperMessage = [string]$helperIntegrityState.message

if ($helperIntegrityState.shouldLoad) {
    . $knownGoodHelper
} else {
    Write-Warning $script:CstKnownGoodHelperMessage
}

$script:CstAuthenticodeProbeCompleted = $false
$script:CstAuthenticodeProbeAvailable = $true
$script:CstAuthenticodeProbeMessage = ''

function Get-CstEnvironmentMode {
    if (Test-Path 'X:\Windows\System32') { return 'WinPE' }
    return 'Windows'
}

function New-CstFallbackRulesDocument {
    param([string]$Reason = '')

    $fallback = [PSCustomObject]@{
        rulesVersion = 'fallback-emergency'
        updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }

    if (-not [string]::IsNullOrWhiteSpace($Reason)) {
        $fallback | Add-Member -NotePropertyName __cstFallbackReason -NotePropertyValue $Reason -Force
    }

    return $fallback
}

function Test-CstWindowsRootMarker {
    param([string]$RootPath)

    $root = Normalize-CstScanRootPath -Path $RootPath
    if ([string]::IsNullOrWhiteSpace($root)) { return $false }

    if ($root -match '^[A-Za-z]:\\$') {
        if (-not (Test-Path -LiteralPath $root -ErrorAction SilentlyContinue)) {
            return $false
        }
    }

    $system32Path = "$root\Windows\System32"
    if (-not (Test-Path -LiteralPath $system32Path -ErrorAction SilentlyContinue)) { return $false }

    $winsxsPath = "$root\Windows\WinSxS"
    $samPath = "$root\Windows\System32\Config\SAM"
    return (
        (Test-Path -LiteralPath $winsxsPath -ErrorAction SilentlyContinue) -or
        (Test-Path -LiteralPath $samPath -ErrorAction SilentlyContinue)
    )
}

function Get-CstDiscoveredWindowsRoots {
    $candidateRoots = New-Object System.Collections.Generic.List[string]
    $seenCandidates = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    $addCandidate = {
        param([string]$RootPath)
        $normalized = Normalize-CstScanRootPath -Path $RootPath
        if ([string]::IsNullOrWhiteSpace($normalized)) { return }
        if ($normalized -eq 'X:\') { return }
        if ($seenCandidates.Add($normalized)) {
            [void]$candidateRoots.Add($normalized)
        }
    }

    foreach ($drive in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if ($null -eq $drive -or [string]::IsNullOrWhiteSpace([string]$drive.Root)) { continue }
        & $addCandidate ([string]$drive.Root)
    }

    if (Get-Command Get-Volume -ErrorAction SilentlyContinue) {
        try {
            foreach ($volume in @(Get-Volume -ErrorAction SilentlyContinue)) {
                if ($null -eq $volume -or -not $volume.DriveLetter) { continue }
                & $addCandidate ("{0}:\" -f [string]$volume.DriveLetter)
            }
        } catch { }
    }

    for ($d = [int][char]'C'; $d -le [int][char]'Z'; $d++) {
        $driveLetter = [char]$d
        if ($driveLetter -eq 'X') { continue }
        & $addCandidate ("$driveLetter`:\")
    }

    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @($candidateRoots)) {
        if (Test-CstWindowsRootMarker -RootPath $candidate) {
            [void]$roots.Add($candidate)
        }
    }

    return @($roots | Select-Object -Unique)
}

function Get-CstRuleSet {
    param([Parameter(Mandatory)][string]$RulesPath)

    $rules = $null
    if (-not (Test-Path -LiteralPath $RulesPath)) {
        $rules = New-CstFallbackRulesDocument -Reason ("Rules file not found: {0}" -f $RulesPath)
    } else {
        try {
            $rules = Get-Content -Path $RulesPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
            $rules = New-CstFallbackRulesDocument -Reason ("Rules parse failed: {0}" -f $_.Exception.Message)
        }
    }

    if (-not $rules -or -not $rules.rulesVersion) {
        $rules = New-CstFallbackRulesDocument -Reason 'Rules missing required rulesVersion; fallback rules activated.'
    }

    # Backward compatible migration: preserve legacy patterns while requiring
    # the new sectioned schema for future detector layers.
    if (-not $rules.hashes) { $rules | Add-Member -NotePropertyName hashes -NotePropertyValue @() -Force }
    if (-not $rules.yaraLikeRules) { $rules | Add-Member -NotePropertyName yaraLikeRules -NotePropertyValue @() -Force }
    if (-not $rules.signerPolicies) {
        $rules | Add-Member -NotePropertyName signerPolicies -NotePropertyValue ([PSCustomObject]@{
            allowPublishers = @()
            denyPublishers = @()
        }) -Force
    }
    if (-not $rules.heuristicThresholds) {
        $rules | Add-Member -NotePropertyName heuristicThresholds -NotePropertyValue ([PSCustomObject]@{
            maxQuickHashFileSizeMb = 16
            maxFullHashFileSizeMb = 64
            maxEntropyFileSizeMb = 8
            highEntropyThreshold = 7.2
            minCombinedSignals = 2
            suspiciousSectionNames = @('.upx', '.aspack', '.packed', '.petite', '.themida', '.vmp')
        }) -Force
    }
    if (-not $rules.heuristicThresholds.PSObject.Properties['maxQuickHashFileSizeMb']) { $rules.heuristicThresholds | Add-Member -NotePropertyName maxQuickHashFileSizeMb -NotePropertyValue 16 -Force }
    if (-not $rules.heuristicThresholds.PSObject.Properties['maxFullHashFileSizeMb']) { $rules.heuristicThresholds | Add-Member -NotePropertyName maxFullHashFileSizeMb -NotePropertyValue 64 -Force }
    if (-not $rules.heuristicThresholds.PSObject.Properties['maxEntropyFileSizeMb']) { $rules.heuristicThresholds | Add-Member -NotePropertyName maxEntropyFileSizeMb -NotePropertyValue 8 -Force }
    if (-not $rules.heuristicThresholds.PSObject.Properties['highEntropyThreshold']) { $rules.heuristicThresholds | Add-Member -NotePropertyName highEntropyThreshold -NotePropertyValue 7.2 -Force }
    if (-not $rules.heuristicThresholds.PSObject.Properties['minCombinedSignals']) { $rules.heuristicThresholds | Add-Member -NotePropertyName minCombinedSignals -NotePropertyValue 2 -Force }
    if (-not $rules.heuristicThresholds.PSObject.Properties['suspiciousSectionNames']) { $rules.heuristicThresholds | Add-Member -NotePropertyName suspiciousSectionNames -NotePropertyValue @('.upx', '.aspack', '.packed', '.petite', '.themida', '.vmp') -Force }
    if (-not $rules.heuristicThresholds.PSObject.Properties['maxQuickArchiveFileSizeMb']) { $rules.heuristicThresholds | Add-Member -NotePropertyName maxQuickArchiveFileSizeMb -NotePropertyValue 8 -Force }
    if (-not $rules.heuristicThresholds.PSObject.Properties['maxFullArchiveFileSizeMb']) { $rules.heuristicThresholds | Add-Member -NotePropertyName maxFullArchiveFileSizeMb -NotePropertyValue 32 -Force }
    if (-not $rules.heuristicThresholds.PSObject.Properties['maxArchiveEntryCount']) { $rules.heuristicThresholds | Add-Member -NotePropertyName maxArchiveEntryCount -NotePropertyValue 150 -Force }
    if (-not $rules.heuristicThresholds.PSObject.Properties['maxArchiveEntrySizeMb']) { $rules.heuristicThresholds | Add-Member -NotePropertyName maxArchiveEntrySizeMb -NotePropertyValue 8 -Force }
    if (-not $rules.heuristicThresholds.PSObject.Properties['maxPerFileAnalysisMsThreat']) { $rules.heuristicThresholds | Add-Member -NotePropertyName maxPerFileAnalysisMsThreat -NotePropertyValue 1200 -Force }
    if (-not $rules.heuristicThresholds.PSObject.Properties['maxPerFileAnalysisMsFull']) { $rules.heuristicThresholds | Add-Member -NotePropertyName maxPerFileAnalysisMsFull -NotePropertyValue 3200 -Force }
    if (-not $rules.heuristicThresholds.PSObject.Properties['maxYaraTextFileSizeMb']) { $rules.heuristicThresholds | Add-Member -NotePropertyName maxYaraTextFileSizeMb -NotePropertyValue 4 -Force }
    if (-not $rules.heuristicThresholds.PSObject.Properties['maxYaraByteFileSizeMb']) { $rules.heuristicThresholds | Add-Member -NotePropertyName maxYaraByteFileSizeMb -NotePropertyValue 8 -Force }
    if (-not $rules.heuristicThresholds.PSObject.Properties['maxSignatureVerificationMs']) { $rules.heuristicThresholds | Add-Member -NotePropertyName maxSignatureVerificationMs -NotePropertyValue 500 -Force }
    if (-not $rules.heuristicThresholds.PSObject.Properties['signatureTimeoutAdaptiveEnabled']) { $rules.heuristicThresholds | Add-Member -NotePropertyName signatureTimeoutAdaptiveEnabled -NotePropertyValue $true -Force }
    if (-not $rules.heuristicThresholds.PSObject.Properties['signatureTimeoutMinMs']) { $rules.heuristicThresholds | Add-Member -NotePropertyName signatureTimeoutMinMs -NotePropertyValue 150 -Force }
    if (-not $rules.heuristicThresholds.PSObject.Properties['signatureTimeoutMaxMs']) { $rules.heuristicThresholds | Add-Member -NotePropertyName signatureTimeoutMaxMs -NotePropertyValue 1500 -Force }
    if (-not $rules.heuristicThresholds.PSObject.Properties['signatureTimeoutBudgetFraction']) { $rules.heuristicThresholds | Add-Member -NotePropertyName signatureTimeoutBudgetFraction -NotePropertyValue 0.35 -Force }
    if (-not $rules.heuristicThresholds.PSObject.Properties['signatureTimeoutThreatMultiplier']) { $rules.heuristicThresholds | Add-Member -NotePropertyName signatureTimeoutThreatMultiplier -NotePropertyValue 0.8 -Force }
    if (-not $rules.heuristicThresholds.PSObject.Properties['signatureTimeoutCustomMultiplier']) { $rules.heuristicThresholds | Add-Member -NotePropertyName signatureTimeoutCustomMultiplier -NotePropertyValue 0.9 -Force }
    if (-not $rules.heuristicThresholds.PSObject.Properties['signatureTimeoutWinPeMultiplier']) { $rules.heuristicThresholds | Add-Member -NotePropertyName signatureTimeoutWinPeMultiplier -NotePropertyValue 0.7 -Force }
    if (-not $rules.heuristicThresholds.PSObject.Properties['maxArchiveAnalysisMs']) { $rules.heuristicThresholds | Add-Member -NotePropertyName maxArchiveAnalysisMs -NotePropertyValue 400 -Force }
    if (-not $rules.heuristicThresholds.PSObject.Properties['maxEntropyBytesToScan']) { $rules.heuristicThresholds | Add-Member -NotePropertyName maxEntropyBytesToScan -NotePropertyValue 65536 -Force }
    if (-not $rules.heuristicThresholds.PSObject.Properties['slowFileThresholdMs']) { $rules.heuristicThresholds | Add-Member -NotePropertyName slowFileThresholdMs -NotePropertyValue 1500 -Force }
    if (-not $rules.heuristicThresholds.PSObject.Properties['maxSlowFileTelemetryEntries']) { $rules.heuristicThresholds | Add-Member -NotePropertyName maxSlowFileTelemetryEntries -NotePropertyValue 25 -Force }
    if (-not $rules.heuristicThresholds.PSObject.Properties['maxQuickScanFiles']) { $rules.heuristicThresholds | Add-Member -NotePropertyName maxQuickScanFiles -NotePropertyValue 4000 -Force }
    if (-not $rules.heuristicThresholds.PSObject.Properties['dependencyTrustPolicy'] -or $null -eq $rules.heuristicThresholds.dependencyTrustPolicy) {
        $rules.heuristicThresholds | Add-Member -NotePropertyName dependencyTrustPolicy -NotePropertyValue ([PSCustomObject]@{
            enabled = $true
            minDllSignalsOutsideRiskPath = 3
            ignoreMissingVersionMetadataInTrustedPaths = $true
            trustedInstallPathRegex = '(\\program files\\|\\program files \(x86\)\\|appdata\\local\\programs\\|^c:\\windows\\system32\\|^c:\\windows\\syswow64\\)'
            siblingSignedExeTrust = $true
            dependencyExtensions = @('.dll')
        }) -Force
    } else {
        $depPolicy = $rules.heuristicThresholds.dependencyTrustPolicy
        if (-not $depPolicy.PSObject.Properties['enabled']) { $depPolicy | Add-Member -NotePropertyName enabled -NotePropertyValue $true -Force }
        if (-not $depPolicy.PSObject.Properties['minDllSignalsOutsideRiskPath']) { $depPolicy | Add-Member -NotePropertyName minDllSignalsOutsideRiskPath -NotePropertyValue 3 -Force }
        if (-not $depPolicy.PSObject.Properties['ignoreMissingVersionMetadataInTrustedPaths']) { $depPolicy | Add-Member -NotePropertyName ignoreMissingVersionMetadataInTrustedPaths -NotePropertyValue $true -Force }
        if (-not $depPolicy.PSObject.Properties['trustedInstallPathRegex']) { $depPolicy | Add-Member -NotePropertyName trustedInstallPathRegex -NotePropertyValue '(\\program files\\|\\program files \(x86\)\\|appdata\\local\\programs\\|^c:\\windows\\system32\\|^c:\\windows\\syswow64\\)' -Force }
        if (-not $depPolicy.PSObject.Properties['siblingSignedExeTrust']) { $depPolicy | Add-Member -NotePropertyName siblingSignedExeTrust -NotePropertyValue $true -Force }
        if (-not $depPolicy.PSObject.Properties['dependencyExtensions']) { $depPolicy | Add-Member -NotePropertyName dependencyExtensions -NotePropertyValue @('.dll') -Force }
    }
    if (-not $rules.correlationRules) {
        $rules | Add-Member -NotePropertyName correlationRules -NotePropertyValue ([PSCustomObject]@{
            enabled = $true
            promoteOnPersistence = $true
            promoteOnProcessLaunch = $true
        }) -Force
    }

    if (-not $rules.patterns) {
        $rules | Add-Member -NotePropertyName patterns -NotePropertyValue ([PSCustomObject]@{
            malware = @()
            pup = @()
            pum = @()
            hostsSuspicious = @()
        }) -Force
    }

    if (-not $rules.bootPolicies) {
        $rules | Add-Member -NotePropertyName bootPolicies -NotePropertyValue ([PSCustomObject]@{
            enabled = $true
            strictnessProfile = 'Balanced'
            applyBalancedToCustomScan = $false
            customScanGuardEnabled = $true
            enableMbrVbrChecks = $true
            enableBootCodeHash = $true
        }) -Force
    }
    if (-not $rules.bootPolicies.PSObject.Properties['enabled']) { $rules.bootPolicies | Add-Member -NotePropertyName enabled -NotePropertyValue $true -Force }
    if (-not $rules.bootPolicies.PSObject.Properties['strictnessProfile']) { $rules.bootPolicies | Add-Member -NotePropertyName strictnessProfile -NotePropertyValue 'Balanced' -Force }
    if (-not $rules.bootPolicies.PSObject.Properties['applyBalancedToCustomScan']) { $rules.bootPolicies | Add-Member -NotePropertyName applyBalancedToCustomScan -NotePropertyValue $false -Force }
    if (-not $rules.bootPolicies.PSObject.Properties['customScanGuardEnabled']) { $rules.bootPolicies | Add-Member -NotePropertyName customScanGuardEnabled -NotePropertyValue $true -Force }
    if (-not $rules.bootPolicies.PSObject.Properties['enableMbrVbrChecks']) { $rules.bootPolicies | Add-Member -NotePropertyName enableMbrVbrChecks -NotePropertyValue $true -Force }
    if (-not $rules.bootPolicies.PSObject.Properties['enableBootCodeHash']) { $rules.bootPolicies | Add-Member -NotePropertyName enableBootCodeHash -NotePropertyValue $true -Force }

    if (-not $rules.bootFilePolicies) {
        $rules | Add-Member -NotePropertyName bootFilePolicies -NotePropertyValue ([PSCustomObject]@{
            enabled = $true
            integrityMode = 'SignerPlusHash'
            requiredPaths = @('EFI\\Microsoft\\Boot\\bootmgfw.efi', 'EFI\\Boot\\bootx64.efi')
            allowedSigners = @('Microsoft Windows', 'Microsoft Corporation')
            hashAllowlist = @()
            hashAllowlistProfiles = @()
            enforceHashAllowlist = $false
        }) -Force
    }
    if (-not $rules.bootFilePolicies.PSObject.Properties['enabled']) { $rules.bootFilePolicies | Add-Member -NotePropertyName enabled -NotePropertyValue $true -Force }
    if (-not $rules.bootFilePolicies.PSObject.Properties['integrityMode']) { $rules.bootFilePolicies | Add-Member -NotePropertyName integrityMode -NotePropertyValue 'SignerPlusHash' -Force }
    if (-not $rules.bootFilePolicies.PSObject.Properties['requiredPaths']) { $rules.bootFilePolicies | Add-Member -NotePropertyName requiredPaths -NotePropertyValue @('EFI\\Microsoft\\Boot\\bootmgfw.efi', 'EFI\\Boot\\bootx64.efi') -Force }
    if (-not $rules.bootFilePolicies.PSObject.Properties['allowedSigners']) { $rules.bootFilePolicies | Add-Member -NotePropertyName allowedSigners -NotePropertyValue @('Microsoft Windows', 'Microsoft Corporation') -Force }
    if (-not $rules.bootFilePolicies.PSObject.Properties['hashAllowlist']) { $rules.bootFilePolicies | Add-Member -NotePropertyName hashAllowlist -NotePropertyValue @() -Force }
    if (-not $rules.bootFilePolicies.PSObject.Properties['hashAllowlistProfiles']) { $rules.bootFilePolicies | Add-Member -NotePropertyName hashAllowlistProfiles -NotePropertyValue @() -Force }
    if (-not $rules.bootFilePolicies.PSObject.Properties['enforceHashAllowlist']) { $rules.bootFilePolicies | Add-Member -NotePropertyName enforceHashAllowlist -NotePropertyValue $false -Force }

    if (-not $rules.bcdPolicies) {
        $rules | Add-Member -NotePropertyName bcdPolicies -NotePropertyValue ([PSCustomObject]@{
            enabled = $true
            forbiddenFlags = @('testsigning', 'debug', 'nointegritychecks')
            suspiciousLoaderPathRegex = @('\\temp\\', '\\users\\public\\', '\\appdata\\', '\\programdata\\')
        }) -Force
    }
    if (-not $rules.bcdPolicies.PSObject.Properties['enabled']) { $rules.bcdPolicies | Add-Member -NotePropertyName enabled -NotePropertyValue $true -Force }
    if (-not $rules.bcdPolicies.PSObject.Properties['forbiddenFlags']) { $rules.bcdPolicies | Add-Member -NotePropertyName forbiddenFlags -NotePropertyValue @('testsigning', 'debug', 'nointegritychecks') -Force }
    if (-not $rules.bcdPolicies.PSObject.Properties['suspiciousLoaderPathRegex']) { $rules.bcdPolicies | Add-Member -NotePropertyName suspiciousLoaderPathRegex -NotePropertyValue @('\\temp\\', '\\users\\public\\', '\\appdata\\', '\\programdata\\') -Force }

    if (-not $rules.sectorPolicies) {
        $rules | Add-Member -NotePropertyName sectorPolicies -NotePropertyValue ([PSCustomObject]@{
            enabled = $true
            requireMbrSignature = $true
            checkGptProtectiveMbr = $true
            bootCodeHashAlgorithm = 'SHA256'
            knownBootCodeHashes = @()
        }) -Force
    }
    if (-not $rules.sectorPolicies.PSObject.Properties['enabled']) { $rules.sectorPolicies | Add-Member -NotePropertyName enabled -NotePropertyValue $true -Force }
    if (-not $rules.sectorPolicies.PSObject.Properties['requireMbrSignature']) { $rules.sectorPolicies | Add-Member -NotePropertyName requireMbrSignature -NotePropertyValue $true -Force }
    if (-not $rules.sectorPolicies.PSObject.Properties['checkGptProtectiveMbr']) { $rules.sectorPolicies | Add-Member -NotePropertyName checkGptProtectiveMbr -NotePropertyValue $true -Force }
    if (-not $rules.sectorPolicies.PSObject.Properties['bootCodeHashAlgorithm']) { $rules.sectorPolicies | Add-Member -NotePropertyName bootCodeHashAlgorithm -NotePropertyValue 'SHA256' -Force }
    if (-not $rules.sectorPolicies.PSObject.Properties['knownBootCodeHashes']) { $rules.sectorPolicies | Add-Member -NotePropertyName knownBootCodeHashes -NotePropertyValue @() -Force }

    if (-not $rules.PSObject.Properties['pathExclusions'] -or $null -eq $rules.pathExclusions) {
        $rules | Add-Member -NotePropertyName pathExclusions -NotePropertyValue ([PSCustomObject]@{
            applyToModes = @('ThreatScan', 'FullScan', 'CustomScan')
            patterns = @()
            customModePolicy = 'Tier1Only'
            tiers = [PSCustomObject]@{
                tier1 = [PSCustomObject]@{
                    applyToModes = @('ThreatScan', 'FullScan', 'CustomScan')
                    patterns = @()
                }
                tier2 = [PSCustomObject]@{
                    applyToModes = @('ThreatScan', 'FullScan')
                    patterns = @()
                }
                tier3 = [PSCustomObject]@{
                    applyToModes = @('ThreatScan', 'FullScan')
                    patterns = @()
                }
            }
        }) -Force
    }
    if (-not $rules.pathExclusions.PSObject.Properties['applyToModes']) { $rules.pathExclusions | Add-Member -NotePropertyName applyToModes -NotePropertyValue @('ThreatScan', 'FullScan', 'CustomScan') -Force }
    if (-not $rules.pathExclusions.PSObject.Properties['patterns']) { $rules.pathExclusions | Add-Member -NotePropertyName patterns -NotePropertyValue @() -Force }
    if (-not $rules.pathExclusions.PSObject.Properties['customModePolicy']) { $rules.pathExclusions | Add-Member -NotePropertyName customModePolicy -NotePropertyValue 'Tier1Only' -Force }
    if (-not $rules.pathExclusions.PSObject.Properties['tiers'] -or $null -eq $rules.pathExclusions.tiers) {
        $rules.pathExclusions | Add-Member -NotePropertyName tiers -NotePropertyValue ([PSCustomObject]@{
            tier1 = [PSCustomObject]@{
                applyToModes = @('ThreatScan', 'FullScan', 'CustomScan')
                patterns = @($rules.pathExclusions.patterns)
            }
            tier2 = [PSCustomObject]@{
                applyToModes = @('ThreatScan', 'FullScan')
                patterns = @()
            }
            tier3 = [PSCustomObject]@{
                applyToModes = @('ThreatScan', 'FullScan')
                patterns = @()
            }
        }) -Force
    }
    if (-not $rules.pathExclusions.tiers.PSObject.Properties['tier1']) {
        $rules.pathExclusions.tiers | Add-Member -NotePropertyName tier1 -NotePropertyValue ([PSCustomObject]@{
            applyToModes = @('ThreatScan', 'FullScan', 'CustomScan')
            patterns = @($rules.pathExclusions.patterns)
        }) -Force
    }
    if (-not $rules.pathExclusions.tiers.PSObject.Properties['tier2']) {
        $rules.pathExclusions.tiers | Add-Member -NotePropertyName tier2 -NotePropertyValue ([PSCustomObject]@{
            applyToModes = @('ThreatScan', 'FullScan')
            patterns = @()
        }) -Force
    }
    if (-not $rules.pathExclusions.tiers.PSObject.Properties['tier3']) {
        $rules.pathExclusions.tiers | Add-Member -NotePropertyName tier3 -NotePropertyValue ([PSCustomObject]@{
            applyToModes = @('ThreatScan', 'FullScan')
            patterns = @()
        }) -Force
    }
    foreach ($tierName in @('tier1','tier2','tier3')) {
        $tierObj = $rules.pathExclusions.tiers.$tierName
        if (-not $tierObj.PSObject.Properties['applyToModes']) {
            $defaultModes = if ($tierName -eq 'tier1') { @('ThreatScan', 'FullScan', 'CustomScan') } else { @('ThreatScan', 'FullScan') }
            $tierObj | Add-Member -NotePropertyName applyToModes -NotePropertyValue $defaultModes -Force
        }
        if (-not $tierObj.PSObject.Properties['patterns']) {
            $defaultPatterns = if ($tierName -eq 'tier1') { @($rules.pathExclusions.patterns) } else { @() }
            $tierObj | Add-Member -NotePropertyName patterns -NotePropertyValue $defaultPatterns -Force
        }
    }

    if (-not $rules.PSObject.Properties['onlineReputation'] -or $null -eq $rules.onlineReputation) {
        $rules | Add-Member -NotePropertyName onlineReputation -NotePropertyValue ([PSCustomObject]@{
            enabled = $false
            provider = 'circl'
            endpoint = 'https://hashlookup.circl.lu/bulk/sha1'
            applyToModes = @('FullScan', 'CustomScan')
            batchSize = 25
            timeoutSeconds = 15
            minTrustScore = 90
            skipInWinPE = $true
        }) -Force
    }
    if (-not $rules.onlineReputation.PSObject.Properties['enabled']) { $rules.onlineReputation | Add-Member -NotePropertyName enabled -NotePropertyValue $false -Force }
    if (-not $rules.onlineReputation.PSObject.Properties['provider']) { $rules.onlineReputation | Add-Member -NotePropertyName provider -NotePropertyValue 'circl' -Force }
    if (-not $rules.onlineReputation.PSObject.Properties['endpoint']) { $rules.onlineReputation | Add-Member -NotePropertyName endpoint -NotePropertyValue 'https://hashlookup.circl.lu/bulk/sha1' -Force }
    if (-not $rules.onlineReputation.PSObject.Properties['applyToModes']) { $rules.onlineReputation | Add-Member -NotePropertyName applyToModes -NotePropertyValue @('FullScan', 'CustomScan') -Force }
    if (-not $rules.onlineReputation.PSObject.Properties['batchSize']) { $rules.onlineReputation | Add-Member -NotePropertyName batchSize -NotePropertyValue 25 -Force }
    if (-not $rules.onlineReputation.PSObject.Properties['timeoutSeconds']) { $rules.onlineReputation | Add-Member -NotePropertyName timeoutSeconds -NotePropertyValue 15 -Force }
    if (-not $rules.onlineReputation.PSObject.Properties['minTrustScore']) { $rules.onlineReputation | Add-Member -NotePropertyName minTrustScore -NotePropertyValue 90 -Force }
    if (-not $rules.onlineReputation.PSObject.Properties['skipInWinPE']) { $rules.onlineReputation | Add-Member -NotePropertyName skipInWinPE -NotePropertyValue $true -Force }
    if (-not $rules.onlineReputation.PSObject.Properties['enabledForThreatScan']) { $rules.onlineReputation | Add-Member -NotePropertyName enabledForThreatScan -NotePropertyValue $false -Force }
    if (-not $rules.onlineReputation.PSObject.Properties['maxLookupsPerScan']) { $rules.onlineReputation | Add-Member -NotePropertyName maxLookupsPerScan -NotePropertyValue 5000 -Force }
    if (-not $rules.onlineReputation.PSObject.Properties['sha256ProviderNote']) {
        $rules.onlineReputation | Add-Member -NotePropertyName sha256ProviderNote -NotePropertyValue 'CIRCL bulk POST expects JSON {"hashes":["<sha1>",...]} at /bulk/sha1; SHA-256 reputation requires a future provider.' -Force
    }

    if (-not $rules.PSObject.Properties['knownGoodPolicy'] -or $null -eq $rules.knownGoodPolicy) {
        $rules | Add-Member -NotePropertyName knownGoodPolicy -NotePropertyValue ([PSCustomObject]@{
            enabled = $true
            storageMode = 'Memory'
            skipContentScan = $true
            hashAllowlist = @()
            hashAllowlistProfiles = @(
                [PSCustomObject]@{
                    name = 'Win11_26200_AMD64'
                    osBuildRegex = '^26200$'
                    productRegex = 'Windows 10|Windows 11'
                    files = @('baselines/win11_26200_amd64.json')
                }
            )
            sqlitePath = 'goodware.db'
            fuzzyHashEnabled = $false
            trustedSignerEarlyExit = [PSCustomObject]@{
                enabled = $true
                extensions = @('.exe', '.dll', '.sys')
                requireValidSignature = $true
            }
        }) -Force
    }
    if (-not $rules.knownGoodPolicy.PSObject.Properties['enabled']) { $rules.knownGoodPolicy | Add-Member -NotePropertyName enabled -NotePropertyValue $true -Force }
    if (-not $rules.knownGoodPolicy.PSObject.Properties['storageMode']) { $rules.knownGoodPolicy | Add-Member -NotePropertyName storageMode -NotePropertyValue 'Memory' -Force }
    if (-not $rules.knownGoodPolicy.PSObject.Properties['skipContentScan']) { $rules.knownGoodPolicy | Add-Member -NotePropertyName skipContentScan -NotePropertyValue $true -Force }
    if (-not $rules.knownGoodPolicy.PSObject.Properties['hashAllowlist']) { $rules.knownGoodPolicy | Add-Member -NotePropertyName hashAllowlist -NotePropertyValue @() -Force }
    if (-not $rules.knownGoodPolicy.PSObject.Properties['hashAllowlistProfiles']) { $rules.knownGoodPolicy | Add-Member -NotePropertyName hashAllowlistProfiles -NotePropertyValue @() -Force }
    if (-not $rules.knownGoodPolicy.PSObject.Properties['sqlitePath']) { $rules.knownGoodPolicy | Add-Member -NotePropertyName sqlitePath -NotePropertyValue 'goodware.db' -Force }
    if (-not $rules.knownGoodPolicy.PSObject.Properties['fuzzyHashEnabled']) { $rules.knownGoodPolicy | Add-Member -NotePropertyName fuzzyHashEnabled -NotePropertyValue $false -Force }
    if (-not $rules.knownGoodPolicy.PSObject.Properties['trustedSignerEarlyExit']) {
        $rules.knownGoodPolicy | Add-Member -NotePropertyName trustedSignerEarlyExit -NotePropertyValue ([PSCustomObject]@{
            enabled = $true
            extensions = @('.exe', '.dll', '.sys')
            requireValidSignature = $true
        }) -Force
    }

    return $rules
}

function Get-CstTargets {
    param(
        [Parameter(Mandatory)][ValidateSet('ThreatScan','FullScan','CustomScan')][string]$Mode,
        [string[]]$Target
    )

    if ($Mode -eq 'CustomScan') {
        if (-not $Target -or $Target.Count -eq 0) {
            throw 'CustomScan requires at least one target path.'
        }
        return $Target
    }

    $resolution = Resolve-CstTargets -Mode $Mode -Target $Target
    return @($resolution.existingTargets)
}

function Normalize-CstScanRootPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }

    $raw = [string]$Path.Trim()
    if ($raw -match '^[A-Za-z]:$') {
        return ($raw.Substring(0, 2) + '\')
    }
    if ($raw -match '^[A-Za-z]:\\?$') {
        return ($raw.Substring(0, 2) + '\')
    }

    if ($raw.StartsWith('\\?\')) {
        return $raw.TrimEnd('\', '/')
    }

    if ($raw.StartsWith('\\')) {
        return $raw.TrimEnd('\', '/')
    }

    try {
        $fullPath = [System.IO.Path]::GetFullPath($raw)
    } catch {
        $fullPath = $raw
    }

    if ($fullPath -match '^[A-Za-z]:\\?$') {
        return ($fullPath.Substring(0, 2) + '\')
    }

    return $fullPath.TrimEnd('\', '/')
}

function Test-CstIsDriveLetterTarget {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $trimmed = [string]$Path.Trim().TrimEnd('\', '/')
    return ($trimmed -match '^[A-Za-z]:\\?$')
}

function Expand-CstDriveScanRoots {
    param(
        [Parameter(Mandatory)][string]$DriveRoot,
        [ValidateSet('ThreatScan', 'FullScan', 'CustomScan')][string]$Mode = 'CustomScan'
    )

    $scanRoot = Normalize-CstScanRootPath -Path $DriveRoot
    if ([string]::IsNullOrWhiteSpace($scanRoot)) { return @() }

    $roots = New-Object System.Collections.Generic.List[string]
    $addRoot = {
        param([string]$RootPath)
        if ([string]::IsNullOrWhiteSpace($RootPath)) { return }
        $resolved = [string]$RootPath.TrimEnd('\', '/')
        if (-not (Test-Path -LiteralPath $resolved)) { return }
        foreach ($existing in @($roots)) {
            if ([string]$existing -eq $resolved) { return }
        }
        [void]$roots.Add($resolved)
    }

    & $addRoot (Join-Path $scanRoot 'ProgramData')
    & $addRoot (Join-Path $scanRoot 'Windows\Temp')
    & $addRoot (Join-Path $scanRoot 'Windows\System32\Tasks')

    $skipUserProfiles = @('public', 'default', 'default user', 'all users')
    $usersPath = Join-Path $scanRoot 'Users'
    if (Test-Path -LiteralPath $usersPath) {
        foreach ($userDir in @(Get-ChildItem -LiteralPath $usersPath -Directory -ErrorAction SilentlyContinue)) {
            if ($userDir.Name.ToLowerInvariant() -in $skipUserProfiles) { continue }
            $u = [string]$userDir.FullName
            & $addRoot (Join-Path $u 'AppData\Local\Temp')
            & $addRoot (Join-Path $u 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup')
            & $addRoot (Join-Path $u 'Downloads')
            & $addRoot (Join-Path $u 'AppData\Roaming')
            & $addRoot (Join-Path $u 'AppData\Local\Microsoft\Windows\INetCache')
        }
    }

    if ($Mode -in @('FullScan', 'CustomScan')) {
        & $addRoot (Join-Path $scanRoot 'Program Files')
        & $addRoot (Join-Path $scanRoot 'Program Files (x86)')
        & $addRoot (Join-Path $scanRoot 'Windows\System32')
    }

    & $addRoot (Join-Path $scanRoot 'ProgramData\Microsoft\Windows\Start Menu\Programs\Startup')

    return @($roots)
}

function Get-CstScanOverallPercent {
    param(
        [int]$Scanned,
        [int]$MaxFiles,
        [double]$MinimumPercent = 10.0,
        [double]$MaximumPercent = 95.0
    )

    if ($MaxFiles -le 0) { return $MinimumPercent }
    $scanPortion = [math]::Min(1.0, ($Scanned / [double]$MaxFiles))
    return [math]::Min($MaximumPercent, [math]::Round($MinimumPercent + ($scanPortion * ($MaximumPercent - $MinimumPercent)), 1))
}

function Get-CstSignatureTimeoutProfile {
    param(
        [Parameter(Mandatory)][ValidateSet('ThreatScan','FullScan','CustomScan')][string]$Mode,
        [Parameter(Mandatory)][ValidateSet('Windows','WinPE')][string]$EnvironmentMode,
        [Parameter(Mandatory)][int]$BaseTimeoutMs,
        [Parameter(Mandatory)][int]$MaxPerFileAnalysisMs,
        [bool]$AdaptiveEnabled = $true,
        [int]$MinTimeoutMs = 150,
        [int]$MaxTimeoutMs = 1500,
        [double]$BudgetFraction = 0.35,
        [double]$ThreatMultiplier = 0.8,
        [double]$CustomMultiplier = 0.9,
        [double]$WinPeMultiplier = 0.7
    )

    if ($BaseTimeoutMs -lt 1) { $BaseTimeoutMs = 1 }
    if ($MaxPerFileAnalysisMs -lt 1) { $MaxPerFileAnalysisMs = 1 }
    if ($MinTimeoutMs -lt 50) { $MinTimeoutMs = 50 }
    if ($MaxTimeoutMs -lt $MinTimeoutMs) { $MaxTimeoutMs = $MinTimeoutMs }
    if ($BudgetFraction -lt 0.1) { $BudgetFraction = 0.1 }
    if ($BudgetFraction -gt 0.9) { $BudgetFraction = 0.9 }

    $modeMultiplier = 1.0
    if ($Mode -eq 'ThreatScan') {
        $modeMultiplier = $ThreatMultiplier
    } elseif ($Mode -eq 'CustomScan') {
        $modeMultiplier = $CustomMultiplier
    }
    if ($modeMultiplier -lt 0.25) { $modeMultiplier = 0.25 }
    if ($modeMultiplier -gt 2.0) { $modeMultiplier = 2.0 }

    $environmentMultiplier = if ($EnvironmentMode -eq 'WinPE') { $WinPeMultiplier } else { 1.0 }
    if ($environmentMultiplier -lt 0.25) { $environmentMultiplier = 0.25 }
    if ($environmentMultiplier -gt 2.0) { $environmentMultiplier = 2.0 }

    $budgetCeilingMs = [int][math]::Floor($MaxPerFileAnalysisMs * $BudgetFraction)
    if ($budgetCeilingMs -lt $MinTimeoutMs) { $budgetCeilingMs = $MinTimeoutMs }

    $effectiveTimeoutMs = $BaseTimeoutMs
    if ($AdaptiveEnabled) {
        $scaled = [int][math]::Round($BaseTimeoutMs * $modeMultiplier * $environmentMultiplier, 0)
        $effectiveTimeoutMs = $scaled
    }

    if ($effectiveTimeoutMs -lt $MinTimeoutMs) { $effectiveTimeoutMs = $MinTimeoutMs }
    if ($effectiveTimeoutMs -gt $MaxTimeoutMs) { $effectiveTimeoutMs = $MaxTimeoutMs }
    if ($effectiveTimeoutMs -gt $budgetCeilingMs) { $effectiveTimeoutMs = $budgetCeilingMs }

    return [PSCustomObject]@{
        adaptiveEnabled = [bool]$AdaptiveEnabled
        baseTimeoutMs = [int]$BaseTimeoutMs
        effectiveTimeoutMs = [int]$effectiveTimeoutMs
        minTimeoutMs = [int]$MinTimeoutMs
        maxTimeoutMs = [int]$MaxTimeoutMs
        budgetFraction = [double]$BudgetFraction
        budgetCeilingMs = [int]$budgetCeilingMs
        modeMultiplier = [double]$modeMultiplier
        environmentMultiplier = [double]$environmentMultiplier
    }
}

function Resolve-CstTargets {
    param(
        [Parameter(Mandatory)][ValidateSet('ThreatScan','FullScan','CustomScan')][string]$Mode,
        [string[]]$Target
    )

    $discoveredWindowsRoots = @()
    $offlineRoot = $null
    $preferredRoot = 'C:\'
    $rawTargets = @()

    $offlineEnvRoot = [string]$env:OFFLINE_WINDOWS_ROOT
    if (-not [string]::IsNullOrWhiteSpace($offlineEnvRoot)) {
        $offlineCandidate = $offlineEnvRoot.TrimEnd('\') + '\'
        if (Test-Path ($offlineCandidate + 'Windows\System32') -ErrorAction SilentlyContinue) {
            $offlineRoot = $offlineCandidate
            $discoveredWindowsRoots += $offlineCandidate
        }
    }

    $discoveredWindowsRoots += @(Get-CstDiscoveredWindowsRoots)

    $discoveredWindowsRoots = @($discoveredWindowsRoots | Select-Object -Unique)

    if ($offlineRoot) {
        $preferredRoot = Normalize-CstScanRootPath -Path $offlineRoot
    } elseif ($discoveredWindowsRoots.Count -gt 0) {
        $preferredRoot = $discoveredWindowsRoots[0]
    } elseif (Test-Path 'C:\' -ErrorAction SilentlyContinue) {
        $preferredRoot = 'C:\'
    }

    if ($Mode -eq 'CustomScan') {
        if (-not $Target -or $Target.Count -eq 0) {
            throw 'CustomScan requires at least one target path.'
        }
        $rawTargets = @($Target | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    } elseif ($Mode -eq 'FullScan') {
        if ($Target -and $Target.Count -gt 0) {
            $rawTargets = @($Target | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        } else {
            $rawTargets = @($preferredRoot)
        }
    } else {
            $riskTargets = @(
                (Join-Path $preferredRoot 'ProgramData'),
                (Join-Path $preferredRoot 'Windows\Temp'),
                (Join-Path $preferredRoot 'Windows\System32\Tasks')
            )

            $skipUserProfiles = @('public', 'default', 'default user', 'all users')
            $usersPath = Join-Path $preferredRoot 'Users'
            if (Test-Path $usersPath -ErrorAction SilentlyContinue) {
                Get-ChildItem $usersPath -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name.ToLowerInvariant() -notin $skipUserProfiles } | ForEach-Object {
                    $u = $_.FullName
                    $riskTargets += @(
                        (Join-Path $u 'AppData\Local\Temp'),
                        (Join-Path $u 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'),
                        (Join-Path $u 'Downloads'),
                        (Join-Path $u 'AppData\Roaming'),
                        (Join-Path $u 'AppData\Local\Microsoft\Windows\INetCache')
                    )
                }
            }

        if ($Target -and $Target.Count -gt 0) {
            $riskTargets += $Target
        }

        $rawTargets = @($riskTargets)
    }

    $rawTargets = @($rawTargets | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    $includesDriveRootScan = $false
    $expandedTargets = New-Object System.Collections.Generic.List[string]
    foreach ($rawTarget in @($rawTargets)) {
        if ($Mode -in @('CustomScan', 'FullScan') -and (Test-CstIsDriveLetterTarget -Path $rawTarget)) {
            $includesDriveRootScan = $true
            foreach ($expandedRoot in @(Expand-CstDriveScanRoots -DriveRoot $rawTarget -Mode $Mode)) {
                [void]$expandedTargets.Add([string]$expandedRoot)
            }
            continue
        }

        $normalizedTarget = if ($Mode -in @('CustomScan', 'FullScan')) {
            Normalize-CstScanRootPath -Path $rawTarget
        } else {
            [string]$rawTarget
        }
        if (-not [string]::IsNullOrWhiteSpace($normalizedTarget)) {
            [void]$expandedTargets.Add([string]$normalizedTarget.TrimEnd('\'))
        }
    }
    $rawTargets = @($expandedTargets | Select-Object -Unique)
    $existingTargets = @($rawTargets | Where-Object { Test-Path $_ -ErrorAction SilentlyContinue } | Select-Object -Unique)
    $missingTargets = @($rawTargets | Where-Object { -not (Test-Path $_ -ErrorAction SilentlyContinue) })

    if ($existingTargets.Count -eq 0 -and $Mode -eq 'ThreatScan' -and -not [string]::IsNullOrWhiteSpace($preferredRoot)) {
        $fallbackTargets = New-Object System.Collections.Generic.List[string]
        foreach ($expandedRoot in @(Expand-CstDriveScanRoots -DriveRoot $preferredRoot -Mode 'ThreatScan')) {
            if (Test-Path -LiteralPath $expandedRoot -ErrorAction SilentlyContinue) {
                [void]$fallbackTargets.Add([string]$expandedRoot)
            }
        }
        if ($fallbackTargets.Count -gt 0) {
            $existingTargets = @($fallbackTargets | Select-Object -Unique)
            $rawTargets = @($existingTargets)
            $missingTargets = @()
        }
    }

    $noTargetReason = ''
    if ($existingTargets.Count -eq 0) {
        if ($Mode -eq 'CustomScan') {
            $noTargetReason = 'No existing custom target paths were found. Verify the selected path exists in this WinPE session.'
        } elseif ($discoveredWindowsRoots.Count -eq 0) {
            $noTargetReason = 'No offline Windows installation was discovered on C:-Z: (excluding X:). Load an offline Windows root first or provide explicit scan targets.'
        } else {
            $noTargetReason = 'A scan root was discovered, but no eligible target directories existed for the selected scan mode.'
        }
    }

    return [PSCustomObject]@{
        preferredRoot = $preferredRoot
        offlineRoot = $offlineRoot
        discoveredWindowsRoots = @($discoveredWindowsRoots)
        rawTargets = @($rawTargets)
        existingTargets = @($existingTargets)
        missingTargets = @($missingTargets)
        noTargetReason = $noTargetReason
        includesDriveRootScan = [bool]$includesDriveRootScan
    }
}

function Get-CstScanPolicy {
    param(
        [Parameter(Mandatory)][ValidateSet('ThreatScan','FullScan','CustomScan')][string]$Mode,
        [Parameter(Mandatory)]$Rules,
        [ValidateSet('Windows','WinPE')][string]$EnvironmentMode = 'Windows'
    )

    $quickMaxFiles = 4000
    if ($Rules.heuristicThresholds -and $Rules.heuristicThresholds.PSObject.Properties['maxQuickScanFiles']) {
        $quickMaxFiles = [int]$Rules.heuristicThresholds.maxQuickScanFiles
    }

    $maxFiles = if ($Mode -eq 'FullScan') { 60000 } elseif ($Mode -eq 'ThreatScan') { $quickMaxFiles } else { 30000 }
    $filePatterns = @('*.exe','*.dll','*.sys','*.ps1','*.vbs','*.js','*.jse','*.wsf','*.bat','*.cmd','*.scr','*.pif','*.docm','*.xlsm','*.pptm','*.lnk','*.zip','*.jar')
    $hashEligibleExt = @('.exe','.dll','.sys','.ps1','.vbs','.js','.jse','.wsf','.bat','.cmd','.scr','.pif','.docm','.xlsm','.pptm','.lnk')
    if ($Mode -eq 'ThreatScan') {
        $filePatterns = @('*.exe','*.ps1','*.vbs','*.js','*.jse','*.wsf','*.bat','*.cmd','*.scr','*.pif','*.docm','*.xlsm','*.pptm','*.lnk')
        $hashEligibleExt = @('.exe','.ps1','.vbs','.js','.jse','.wsf','.bat','.cmd','.scr','.pif','.docm','.xlsm','.pptm','.lnk')
    }

    $quickHashMb = 16
    if ($Rules.heuristicThresholds -and $Rules.heuristicThresholds.PSObject.Properties['maxQuickHashFileSizeMb']) {
        $quickHashMb = [int]$Rules.heuristicThresholds.maxQuickHashFileSizeMb
    }

    $fullHashMb = 64
    if ($Rules.heuristicThresholds -and $Rules.heuristicThresholds.PSObject.Properties['maxFullHashFileSizeMb']) {
        $fullHashMb = [int]$Rules.heuristicThresholds.maxFullHashFileSizeMb
    }

    $quickArchiveMb = 8
    if ($Rules.heuristicThresholds -and $Rules.heuristicThresholds.PSObject.Properties['maxQuickArchiveFileSizeMb']) {
        $quickArchiveMb = [int]$Rules.heuristicThresholds.maxQuickArchiveFileSizeMb
    }

    $fullArchiveMb = 32
    if ($Rules.heuristicThresholds -and $Rules.heuristicThresholds.PSObject.Properties['maxFullArchiveFileSizeMb']) {
        $fullArchiveMb = [int]$Rules.heuristicThresholds.maxFullArchiveFileSizeMb
    }

    $maxArchiveEntryCount = 150
    if ($Rules.heuristicThresholds -and $Rules.heuristicThresholds.PSObject.Properties['maxArchiveEntryCount']) {
        $maxArchiveEntryCount = [int]$Rules.heuristicThresholds.maxArchiveEntryCount
    }

    $maxArchiveEntrySizeMb = 8
    if ($Rules.heuristicThresholds -and $Rules.heuristicThresholds.PSObject.Properties['maxArchiveEntrySizeMb']) {
        $maxArchiveEntrySizeMb = [int]$Rules.heuristicThresholds.maxArchiveEntrySizeMb
    }

    $maxPerFileThreatMs = 1200
    if ($Rules.heuristicThresholds -and $Rules.heuristicThresholds.PSObject.Properties['maxPerFileAnalysisMsThreat']) {
        $maxPerFileThreatMs = [int]$Rules.heuristicThresholds.maxPerFileAnalysisMsThreat
    }

    $maxPerFileFullMs = 3200
    if ($Rules.heuristicThresholds -and $Rules.heuristicThresholds.PSObject.Properties['maxPerFileAnalysisMsFull']) {
        $maxPerFileFullMs = [int]$Rules.heuristicThresholds.maxPerFileAnalysisMsFull
        $maxYaraTextFileSizeMb = 4
        if ($Rules.heuristicThresholds -and $Rules.heuristicThresholds.PSObject.Properties['maxYaraTextFileSizeMb']) {
            $maxYaraTextFileSizeMb = [int]$Rules.heuristicThresholds.maxYaraTextFileSizeMb
        }

        $maxYaraByteFileSizeMb = 8
        if ($Rules.heuristicThresholds -and $Rules.heuristicThresholds.PSObject.Properties['maxYaraByteFileSizeMb']) {
            $maxYaraByteFileSizeMb = [int]$Rules.heuristicThresholds.maxYaraByteFileSizeMb
        }

        $maxSignatureVerificationMs = 500
        if ($Rules.heuristicThresholds -and $Rules.heuristicThresholds.PSObject.Properties['maxSignatureVerificationMs']) {
            $maxSignatureVerificationMs = [int]$Rules.heuristicThresholds.maxSignatureVerificationMs
        }

        $maxArchiveAnalysisMs = 400
        if ($Rules.heuristicThresholds -and $Rules.heuristicThresholds.PSObject.Properties['maxArchiveAnalysisMs']) {
            $maxArchiveAnalysisMs = [int]$Rules.heuristicThresholds.maxArchiveAnalysisMs
        }

        $maxEntropyBytesToScan = 65536
        if ($Rules.heuristicThresholds -and $Rules.heuristicThresholds.PSObject.Properties['maxEntropyBytesToScan']) {
            $maxEntropyBytesToScan = [int]$Rules.heuristicThresholds.maxEntropyBytesToScan
        }

        $slowFileThresholdMs = 1500
        if ($Rules.heuristicThresholds -and $Rules.heuristicThresholds.PSObject.Properties['slowFileThresholdMs']) {
            $slowFileThresholdMs = [int]$Rules.heuristicThresholds.slowFileThresholdMs
        }

        $maxSlowFileTelemetryEntries = 25
        if ($Rules.heuristicThresholds -and $Rules.heuristicThresholds.PSObject.Properties['maxSlowFileTelemetryEntries']) {
            $maxSlowFileTelemetryEntries = [int]$Rules.heuristicThresholds.maxSlowFileTelemetryEntries
        }

    }

    $signatureTimeoutAdaptiveEnabled = $true
    if ($Rules.heuristicThresholds -and $Rules.heuristicThresholds.PSObject.Properties['signatureTimeoutAdaptiveEnabled']) {
        $signatureTimeoutAdaptiveEnabled = [bool]$Rules.heuristicThresholds.signatureTimeoutAdaptiveEnabled
    }
    $signatureTimeoutMinMs = 150
    if ($Rules.heuristicThresholds -and $Rules.heuristicThresholds.PSObject.Properties['signatureTimeoutMinMs']) {
        $signatureTimeoutMinMs = [int]$Rules.heuristicThresholds.signatureTimeoutMinMs
    }
    $signatureTimeoutMaxMs = 1500
    if ($Rules.heuristicThresholds -and $Rules.heuristicThresholds.PSObject.Properties['signatureTimeoutMaxMs']) {
        $signatureTimeoutMaxMs = [int]$Rules.heuristicThresholds.signatureTimeoutMaxMs
    }
    $signatureTimeoutBudgetFraction = 0.35
    if ($Rules.heuristicThresholds -and $Rules.heuristicThresholds.PSObject.Properties['signatureTimeoutBudgetFraction']) {
        $signatureTimeoutBudgetFraction = [double]$Rules.heuristicThresholds.signatureTimeoutBudgetFraction
    }
    $signatureTimeoutThreatMultiplier = 0.8
    if ($Rules.heuristicThresholds -and $Rules.heuristicThresholds.PSObject.Properties['signatureTimeoutThreatMultiplier']) {
        $signatureTimeoutThreatMultiplier = [double]$Rules.heuristicThresholds.signatureTimeoutThreatMultiplier
    }
    $signatureTimeoutCustomMultiplier = 0.9
    if ($Rules.heuristicThresholds -and $Rules.heuristicThresholds.PSObject.Properties['signatureTimeoutCustomMultiplier']) {
        $signatureTimeoutCustomMultiplier = [double]$Rules.heuristicThresholds.signatureTimeoutCustomMultiplier
    }
    $signatureTimeoutWinPeMultiplier = 0.7
    if ($Rules.heuristicThresholds -and $Rules.heuristicThresholds.PSObject.Properties['signatureTimeoutWinPeMultiplier']) {
        $signatureTimeoutWinPeMultiplier = [double]$Rules.heuristicThresholds.signatureTimeoutWinPeMultiplier
    }

    $maxPerFileMs = if ($Mode -eq 'ThreatScan') { $maxPerFileThreatMs } else { $maxPerFileFullMs }
    $signatureTimeoutProfile = Get-CstSignatureTimeoutProfile -Mode $Mode -EnvironmentMode $EnvironmentMode -BaseTimeoutMs $maxSignatureVerificationMs -MaxPerFileAnalysisMs $maxPerFileMs -AdaptiveEnabled $signatureTimeoutAdaptiveEnabled -MinTimeoutMs $signatureTimeoutMinMs -MaxTimeoutMs $signatureTimeoutMaxMs -BudgetFraction $signatureTimeoutBudgetFraction -ThreatMultiplier $signatureTimeoutThreatMultiplier -CustomMultiplier $signatureTimeoutCustomMultiplier -WinPeMultiplier $signatureTimeoutWinPeMultiplier

    $threatScanRiskRegex = Get-CstThreatScanRiskPathRegex

    $exclusionPatterns = @()
    $exclusionsEnabled = $false
    $exclusionTiersApplied = @()
    $exclusionTierPatternCounts = [ordered]@{ tier1 = 0; tier2 = 0; tier3 = 0 }
    if ($Rules.PSObject.Properties['pathExclusions'] -and $null -ne $Rules.pathExclusions) {
        $globalApplyModes = @('ThreatScan', 'FullScan', 'CustomScan')
        if ($Rules.pathExclusions.PSObject.Properties['applyToModes']) {
            $globalApplyModes = @($Rules.pathExclusions.applyToModes)
        }

        $globalModeEnabled = ($Mode -in $globalApplyModes)
        $customModePolicy = 'Tier1Only'
        if ($Rules.pathExclusions.PSObject.Properties['customModePolicy'] -and -not [string]::IsNullOrWhiteSpace([string]$Rules.pathExclusions.customModePolicy)) {
            $customModePolicy = [string]$Rules.pathExclusions.customModePolicy
        }

        foreach ($tierName in @('tier1', 'tier2', 'tier3')) {
            $tierPatterns = @()
            $tierApplyModes = @()

            if ($Rules.pathExclusions.PSObject.Properties['tiers'] -and $null -ne $Rules.pathExclusions.tiers -and $Rules.pathExclusions.tiers.PSObject.Properties[$tierName]) {
                $tierRule = $Rules.pathExclusions.tiers.$tierName
                if ($tierRule.PSObject.Properties['patterns']) {
                    $tierPatterns = @($tierRule.patterns | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                }
                if ($tierRule.PSObject.Properties['applyToModes']) {
                    $tierApplyModes = @($tierRule.applyToModes)
                }
            } elseif ($tierName -eq 'tier1' -and $Rules.pathExclusions.PSObject.Properties['patterns']) {
                $tierPatterns = @($Rules.pathExclusions.patterns | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            }

            if ($tierApplyModes.Count -eq 0) {
                $tierApplyModes = if ($tierName -eq 'tier1') { @('ThreatScan', 'FullScan', 'CustomScan') } else { @('ThreatScan', 'FullScan') }
            }

            if ($Mode -eq 'CustomScan' -and $customModePolicy -eq 'Tier1Only' -and $tierName -ne 'tier1') {
                continue
            }

            if ($globalModeEnabled -and ($Mode -in $tierApplyModes) -and $tierPatterns.Count -gt 0) {
                $exclusionTierPatternCounts[$tierName] = $tierPatterns.Count
                $exclusionTiersApplied += $tierName
                $exclusionPatterns += $tierPatterns
            }
        }

        $exclusionPatterns = @($exclusionPatterns | Select-Object -Unique)
        $exclusionsEnabled = ($exclusionPatterns.Count -gt 0)
    }

    $onlineEnabled = $false
    $onlineProvider = 'circl'
    $onlineEndpoint = 'https://hashlookup.circl.lu/bulk/sha1'
    $onlineApplyToModes = @('FullScan', 'CustomScan')
    $onlineBatchSize = 25
    $onlineTimeoutSeconds = 15
    $onlineMinTrustScore = 90
    $onlineSkipInWinPE = $true
    $onlineEnabledForThreatScan = $false
    $onlineMaxLookupsPerScan = 5000
    if ($Rules.PSObject.Properties['onlineReputation'] -and $null -ne $Rules.onlineReputation) {
        if ($Rules.onlineReputation.PSObject.Properties['enabled']) { $onlineEnabled = [bool]$Rules.onlineReputation.enabled }
        if ($Rules.onlineReputation.PSObject.Properties['provider'] -and -not [string]::IsNullOrWhiteSpace([string]$Rules.onlineReputation.provider)) { $onlineProvider = [string]$Rules.onlineReputation.provider }
        if ($Rules.onlineReputation.PSObject.Properties['endpoint'] -and -not [string]::IsNullOrWhiteSpace([string]$Rules.onlineReputation.endpoint)) { $onlineEndpoint = [string]$Rules.onlineReputation.endpoint }
        if ($Rules.onlineReputation.PSObject.Properties['applyToModes']) { $onlineApplyToModes = @($Rules.onlineReputation.applyToModes) }
        if ($Rules.onlineReputation.PSObject.Properties['batchSize']) { $onlineBatchSize = [int]$Rules.onlineReputation.batchSize }
        if ($Rules.onlineReputation.PSObject.Properties['timeoutSeconds']) { $onlineTimeoutSeconds = [int]$Rules.onlineReputation.timeoutSeconds }
        if ($Rules.onlineReputation.PSObject.Properties['minTrustScore']) { $onlineMinTrustScore = [int]$Rules.onlineReputation.minTrustScore }
        if ($Rules.onlineReputation.PSObject.Properties['skipInWinPE']) { $onlineSkipInWinPE = [bool]$Rules.onlineReputation.skipInWinPE }
        if ($Rules.onlineReputation.PSObject.Properties['enabledForThreatScan']) { $onlineEnabledForThreatScan = [bool]$Rules.onlineReputation.enabledForThreatScan }
        if ($Rules.onlineReputation.PSObject.Properties['maxLookupsPerScan']) { $onlineMaxLookupsPerScan = [int]$Rules.onlineReputation.maxLookupsPerScan }
    }
    if ($onlineEnabledForThreatScan -and ($onlineApplyToModes -notcontains 'ThreatScan')) {
        $onlineApplyToModes = @($onlineApplyToModes) + @('ThreatScan')
    }
    if ($onlineBatchSize -lt 1) { $onlineBatchSize = 1 }
    if ($onlineTimeoutSeconds -lt 1) { $onlineTimeoutSeconds = 1 }
    if ($onlineMinTrustScore -lt 1) { $onlineMinTrustScore = 1 }
    if ($onlineMinTrustScore -gt 100) { $onlineMinTrustScore = 100 }
    $onlineModeEnabled = $Mode -in $onlineApplyToModes

    return [PSCustomObject]@{
        maxFiles = $maxFiles
        filePatterns = @($filePatterns)
        hashEligibleExtensions = @($hashEligibleExt)
        threatScanRiskRegex = $threatScanRiskRegex
        hashGateMb = if ($Mode -eq 'ThreatScan') { $quickHashMb } else { $fullHashMb }
        enableSignerTrust = $true
        riskPathFilterEnabled = ($Mode -eq 'ThreatScan')
        archiveInspectionEnabled = ($Mode -ne 'ThreatScan')
        archiveExtensions = @('.zip', '.jar')
        archiveMaxFileSizeMb = if ($Mode -eq 'ThreatScan') { $quickArchiveMb } else { $fullArchiveMb }
        maxArchiveEntryCount = $maxArchiveEntryCount
        maxArchiveEntrySizeMb = $maxArchiveEntrySizeMb
        maxPerFileAnalysisMs = $maxPerFileMs
        maxYaraTextFileSizeMb = $maxYaraTextFileSizeMb
        maxYaraByteFileSizeMb = $maxYaraByteFileSizeMb
        maxSignatureVerificationMs = [int]$signatureTimeoutProfile.effectiveTimeoutMs
        maxSignatureVerificationMsBase = [int]$signatureTimeoutProfile.baseTimeoutMs
        signatureTimeoutAdaptiveProfile = [PSCustomObject]@{
            enabled = [bool]$signatureTimeoutProfile.adaptiveEnabled
            minMs = [int]$signatureTimeoutProfile.minTimeoutMs
            maxMs = [int]$signatureTimeoutProfile.maxTimeoutMs
            budgetFraction = [double]$signatureTimeoutProfile.budgetFraction
            budgetCeilingMs = [int]$signatureTimeoutProfile.budgetCeilingMs
            modeMultiplier = [double]$signatureTimeoutProfile.modeMultiplier
            environmentMultiplier = [double]$signatureTimeoutProfile.environmentMultiplier
        }
        maxArchiveAnalysisMs = $maxArchiveAnalysisMs
        maxEntropyBytesToScan = $maxEntropyBytesToScan
        slowFileThresholdMs = $slowFileThresholdMs
        maxSlowFileTelemetryEntries = $maxSlowFileTelemetryEntries
        exclusionPatterns = @($exclusionPatterns)
        exclusionsEnabled = $exclusionsEnabled
        exclusionTiersApplied = @($exclusionTiersApplied)
        exclusionTierPatternCounts = [PSCustomObject]$exclusionTierPatternCounts
        onlineReputation = [PSCustomObject]@{
            enabled = $onlineEnabled
            provider = $onlineProvider
            endpoint = $onlineEndpoint
            applyToModes = @($onlineApplyToModes)
            modeEnabled = $onlineModeEnabled
            batchSize = $onlineBatchSize
            timeoutSeconds = $onlineTimeoutSeconds
            minTrustScore = $onlineMinTrustScore
            skipInWinPE = $onlineSkipInWinPE
            enabledForThreatScan = $onlineEnabledForThreatScan
            maxLookupsPerScan = $onlineMaxLookupsPerScan
        }
    }
}

function New-CstFinding {
    param(
        [string]$Id = ([guid]::NewGuid().ToString('N')),
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Severity,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$Evidence,
        [string]$Detector = 'Unknown',
        [double]$Confidence = 0.0,
        [string]$ObjectType = 'File',
        [string]$Hash = '',
        [string]$Publisher = '',
        [string]$SignerStatus = 'Unknown',
        [double]$Entropy = 0.0,
        [string]$CorrelationId = '',
        [string]$SelectedAction = 'None',
        [string]$ActionState = 'None',
        [string]$RemediationState = 'None',
        [bool]$CanRemediate = $true
    )

    [PSCustomObject]@{
        id = $Id
        type = $Type
        severity = $Severity
        name = $Name
        location = $Location
        evidence = $Evidence
        detector = $Detector
        confidence = [math]::Round($Confidence, 2)
        objectType = $ObjectType
        hash = $Hash
        publisher = $Publisher
        signerStatus = $SignerStatus
        entropy = [math]::Round($Entropy, 2)
        correlationId = $CorrelationId
        selectedAction = $SelectedAction
        actionState = $ActionState
        canRemediate = $CanRemediate
        remediationState = $RemediationState
        remediationNote = ''
    }
}

function Ensure-CstFindingContract {
    param(
        [Parameter(Mandatory)]$Finding,
        [string]$DefaultSelectedAction = 'None',
        [string]$DefaultActionState = 'None'
    )

    if (-not $Finding.PSObject.Properties['detector']) {
        $Finding | Add-Member -NotePropertyName detector -NotePropertyValue 'Unknown' -Force
    }
    if (-not $Finding.PSObject.Properties['confidence']) {
        $Finding | Add-Member -NotePropertyName confidence -NotePropertyValue 0.0 -Force
    }
    if (-not $Finding.PSObject.Properties['objectType']) {
        $Finding | Add-Member -NotePropertyName objectType -NotePropertyValue 'File' -Force
    }
    if (-not $Finding.PSObject.Properties['hash']) {
        $Finding | Add-Member -NotePropertyName hash -NotePropertyValue '' -Force
    }
    if (-not $Finding.PSObject.Properties['publisher']) {
        $Finding | Add-Member -NotePropertyName publisher -NotePropertyValue '' -Force
    }
    if (-not $Finding.PSObject.Properties['signerStatus']) {
        $Finding | Add-Member -NotePropertyName signerStatus -NotePropertyValue 'Unknown' -Force
    }
    if (-not $Finding.PSObject.Properties['entropy']) {
        $Finding | Add-Member -NotePropertyName entropy -NotePropertyValue 0.0 -Force
    }
    if (-not $Finding.PSObject.Properties['correlationId']) {
        $Finding | Add-Member -NotePropertyName correlationId -NotePropertyValue '' -Force
    }
    if (-not $Finding.PSObject.Properties['selectedAction']) {
        $Finding | Add-Member -NotePropertyName selectedAction -NotePropertyValue $DefaultSelectedAction -Force
    }
    if (-not $Finding.PSObject.Properties['actionState']) {
        $Finding | Add-Member -NotePropertyName actionState -NotePropertyValue $DefaultActionState -Force
    }
    if (-not $Finding.PSObject.Properties['canRemediate']) {
        $Finding | Add-Member -NotePropertyName canRemediate -NotePropertyValue $true -Force
    }
    if (-not $Finding.PSObject.Properties['remediationState']) {
        $Finding | Add-Member -NotePropertyName remediationState -NotePropertyValue 'None' -Force
    }
    if (-not $Finding.PSObject.Properties['remediationNote']) {
        $Finding | Add-Member -NotePropertyName remediationNote -NotePropertyValue '' -Force
    }

    return $Finding
}

function Get-CstStorageRoot {
    $envMode = Get-CstEnvironmentMode
    if ($envMode -eq 'WinPE') {
        return 'X:\CoreSecurityTool'
    }
    return Join-Path $env:ProgramData 'CoreSecurityTool'
}

function Initialize-CstStorage {
    $root = Get-CstStorageRoot
    $quarantine = Join-Path $root 'Quarantine'
    $rollback = Join-Path $root 'Rollback'

    foreach ($path in @($root, $quarantine, $rollback)) {
        if (-not (Test-Path $path)) {
            New-Item -Path $path -ItemType Directory -Force | Out-Null
        }
    }

    return [PSCustomObject]@{
        root = $root
        quarantine = $quarantine
        rollback = $rollback
    }
}

function Test-CstFileHashReadable {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.PSIsContainer) { return $false }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
        return $true
    } catch {
        return $false
    }
}

function Test-CstSha256HashFormat {
    param([string]$Hash)

    if ([string]::IsNullOrWhiteSpace($Hash)) { return $false }
    return ([string]$Hash).Trim().ToUpperInvariant() -match '^[A-F0-9]{64}$'
}

function Test-CstSha1HashFormat {
    param([string]$Hash)

    if ([string]::IsNullOrWhiteSpace($Hash)) { return $false }
    return ([string]$Hash).Trim().ToUpperInvariant() -match '^[A-F0-9]{40}$'
}

function Get-CstFileHashSafe {
    param([string]$Path)

    try {
        if (Test-CstFileHashReadable -Path $Path) {
            $computed = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path -ErrorAction Stop).Hash
            if (Test-CstSha256HashFormat -Hash $computed) {
                return ([string]$computed).Trim().ToUpperInvariant()
            }
        }
    } catch {}

    return ''
}

function Get-CstFileHashSafeByAlgorithm {
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('SHA1', 'SHA256')][string]$Algorithm = 'SHA256'
    )

    try {
        if (Test-CstFileHashReadable -Path $Path) {
            $computed = (Get-FileHash -Algorithm $Algorithm -LiteralPath $Path -ErrorAction Stop).Hash
            if ($Algorithm -eq 'SHA1') {
                if (Test-CstSha1HashFormat -Hash $computed) {
                    return ([string]$computed).Trim().ToUpperInvariant()
                }
            } elseif (Test-CstSha256HashFormat -Hash $computed) {
                return ([string]$computed).Trim().ToUpperInvariant()
            }
        }
    } catch {}

    return ''
}

function Get-CstOnlineReputationStatus {
    param(
        [Parameter(Mandatory)][bool]$Enabled,
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][string]$Endpoint,
        [Parameter(Mandatory)][int]$BatchSize,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [Parameter(Mandatory)][int]$MinTrustScore,
        [Parameter(Mandatory)][bool]$ModeEnabled,
        [Parameter(Mandatory)][bool]$SkippedInEnvironment,
        [Parameter(Mandatory)][bool]$OfflineOnly
    )

    return [PSCustomObject]@{
        enabled = $Enabled
        provider = $Provider
        endpoint = $Endpoint
        batchSize = $BatchSize
        timeoutSeconds = $TimeoutSeconds
        minTrustScore = $MinTrustScore
        modeEnabled = $ModeEnabled
        skippedInEnvironment = $SkippedInEnvironment
        offlineOnly = $OfflineOnly
        active = $false
        requestsAttempted = 0
        requestsSucceeded = 0
        requestsFailed = 0
        requestTimeouts = 0
        eligibleFiles = 0
        knownGoodHits = 0
        suppressedFindings = 0
        parseErrors = 0
        lastError = ''
    }
}

function Invoke-CstCirclBulkSha1Lookup {
    param(
        [Parameter(Mandatory)][string[]]$Hashes,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [Parameter(Mandatory)][int]$MinTrustScore,
        [string]$Endpoint = 'https://hashlookup.circl.lu/bulk/sha1'
    )

    $result = [PSCustomObject]@{
        attempted = $false
        succeeded = $false
        timedOut = $false
        errorMessage = ''
        parseErrors = 0
        knownGoodMap = @{}
    }

    $normalizedHashes = @($Hashes | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [string]$_.Trim().ToUpperInvariant() } | Where-Object { $_ -match '^[A-F0-9]{40}$' } | Select-Object -Unique)
    if ($normalizedHashes.Count -eq 0) {
        return $result
    }

    try {
        $body = (@{ hashes = @($normalizedHashes) } | ConvertTo-Json -Compress -Depth 3)
        $response = Invoke-RestMethod -Method Post -Uri $Endpoint -Body $body -ContentType 'application/json' -TimeoutSec $TimeoutSeconds -ErrorAction Stop
        $result.attempted = $true
        $result.succeeded = $true

        $records = @()
        if ($null -eq $response) {
            $records = @()
        } elseif ($response -is [System.Array]) {
            $records = @($response)
        } elseif ($response -is [System.Collections.IDictionary]) {
            foreach ($k in $response.Keys) {
                $v = $response[$k]
                if ($null -eq $v) { continue }
                if ($v -is [System.Collections.IDictionary] -or $v.PSObject.Properties.Count -gt 0) {
                    if (-not $v.PSObject.Properties['sha1'] -and -not $v.PSObject.Properties['SHA-1']) {
                        $v | Add-Member -NotePropertyName sha1 -NotePropertyValue ([string]$k) -Force
                    }
                }
                $records += $v
            }
        } elseif ($response.PSObject.Properties['results']) {
            $records = @($response.results)
        } elseif ($response.PSObject.Properties['response']) {
            $records = @($response.response)
        } else {
            $records = @($response)
        }

        foreach ($record in @($records)) {
            if ($null -eq $record) { continue }

            $sha1 = ''
            foreach ($hashKey in @('SHA-1', 'sha-1', 'sha1', 'SHA1', 'hash')) {
                if ($record.PSObject.Properties[$hashKey]) {
                    $sha1 = [string]$record.PSObject.Properties[$hashKey].Value
                    break
                }
            }
            $sha1 = $sha1.Trim().ToUpperInvariant()
            if ($sha1 -notmatch '^[A-F0-9]{40}$') {
                $result.parseErrors++
                continue
            }

            $trust = 100
            foreach ($trustKey in @('hashlookup:trust', 'trust', 'reputation', 'score')) {
                if ($record.PSObject.Properties[$trustKey]) {
                    $rawTrust = $record.PSObject.Properties[$trustKey].Value
                    try {
                        $trust = [int]$rawTrust
                    } catch {
                        $trust = 100
                    }
                    break
                }
            }

            $known = $true
            foreach ($knownKey in @('known', 'found', 'exists', 'present')) {
                if ($record.PSObject.Properties[$knownKey]) {
                    $known = [bool]$record.PSObject.Properties[$knownKey].Value
                    break
                }
            }

            $malicious = $false
            foreach ($malKey in @('malicious', 'isMalicious', 'is_malicious', 'threat', 'blacklisted')) {
                if ($record.PSObject.Properties[$malKey]) {
                    $malicious = [bool]$record.PSObject.Properties[$malKey].Value
                    break
                }
            }

            $knownGood = $known -and -not $malicious -and ($trust -ge $MinTrustScore)
            $result.knownGoodMap[$sha1] = [PSCustomObject]@{
                knownGood = $knownGood
                trust = $trust
            }
        }

        foreach ($requestedHash in $normalizedHashes) {
            if (-not $result.knownGoodMap.ContainsKey($requestedHash)) {
                $result.knownGoodMap[$requestedHash] = [PSCustomObject]@{
                    knownGood = $false
                    trust = 0
                }
            }
        }
    } catch {
        $result.attempted = $true
        $result.succeeded = $false
        $result.errorMessage = [string]$_.Exception.Message
        if ($result.errorMessage.ToLowerInvariant() -match 'timed out|timeout') {
            $result.timedOut = $true
        }
    }

    return $result
}

function Write-CstLiveEvent {
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)]$Payload
    )

    $json = $Payload | ConvertTo-Json -Compress -Depth 8
    # Use host output so workflow wrappers that capture pipeline output do not swallow live telemetry.
    Write-Host "[CST:$Kind] $json"
}

function Write-CstLiveProgress {
    param(
        [Parameter(Mandatory)][int]$Scanned,
        [Parameter(Mandatory)][int]$ProgressTotal,
        [AllowEmptyString()][string]$CurrentPath = '',
        [Parameter(Mandatory)][double]$ElapsedSec,
        [double]$RecentAverageSec = 0,
        [int]$MinEtaSampleSize = 25,
        [int]$MaxBudgetSec = 0,
        [ValidateSet('TargetPrep', 'Enumerating', 'Scanning', 'Completed')][string]$Phase = 'Scanning',
        [double]$PhasePercent = -1,
        [double]$OverallPercent = -1,
        [int]$TargetIndex = 0,
        [int]$TargetCount = 0,
        [int]$EnumeratedCandidates = 0,
        [int]$FilteredByRiskPath = 0,
        [int]$FilteredByExclusion = 0,
        [string]$Detail = ''
    )

    $computedPercent = if ($ProgressTotal -gt 0) {
        [math]::Min(100.0, [math]::Round(($Scanned / [double]$ProgressTotal) * 100.0, 1))
    } else {
        0.0
    }

    $percent = if ($OverallPercent -ge 0) {
        [math]::Min(100.0, [math]::Max(0.0, [math]::Round($OverallPercent, 1)))
    } else {
        $computedPercent
    }

    $phasePercentValue = if ($PhasePercent -ge 0) {
        [math]::Min(100.0, [math]::Max(0.0, [math]::Round($PhasePercent, 1)))
    } else {
        $computedPercent
    }

    $etaSec = 0.0
    if ($Scanned -ge $MinEtaSampleSize -and $Scanned -lt $ProgressTotal) {
        $globalPerFileSec = if ($Scanned -gt 0) { ($ElapsedSec / $Scanned) } else { 0.0 }
        $effectivePerFileSec = if ($RecentAverageSec -gt 0.0) {
            (($globalPerFileSec * 0.35) + ($RecentAverageSec * 0.65))
        } else {
            $globalPerFileSec
        }

        $remainingCount = [math]::Max(0, ($ProgressTotal - $Scanned))
        $etaSec = [math]::Max(0.0, [math]::Round(($effectivePerFileSec * $remainingCount), 1))

        if ($MaxBudgetSec -gt 0) {
            $budgetRemainingSec = [math]::Max(0.0, [math]::Round(($MaxBudgetSec - $ElapsedSec), 1))
            $etaSec = [math]::Min($etaSec, $budgetRemainingSec)
        }
    }

    Write-CstLiveEvent -Kind 'PROGRESS' -Payload ([PSCustomObject]@{
        scanned = $Scanned
        progressTotal = $ProgressTotal
        percent = $percent
        phase = $Phase
        phasePercent = $phasePercentValue
        overallPercent = $percent
        targetIndex = $TargetIndex
        targetCount = $TargetCount
        enumeratedCandidates = $EnumeratedCandidates
        filteredByRiskPath = $FilteredByRiskPath
        filteredByExclusion = $FilteredByExclusion
        detail = $Detail
        currentPath = $CurrentPath
        elapsedSec = $ElapsedSec
        etaSec = $etaSec
    })
}

function Write-CstLiveFinding {
    param([Parameter(Mandatory)]$Finding)

    Write-CstLiveEvent -Kind 'FINDING' -Payload ([PSCustomObject]@{
        id = [string]$Finding.id
        type = [string]$Finding.type
        severity = [string]$Finding.severity
        name = [string]$Finding.name
        location = [string]$Finding.location
        evidence = [string]$Finding.evidence
        detector = [string]$Finding.detector
        confidence = [double]$Finding.confidence
        objectType = [string]$Finding.objectType
        publisher = [string]$Finding.publisher
        signerStatus = [string]$Finding.signerStatus
        entropy = [double]$Finding.entropy
        hash = [string]$Finding.hash
    })
}

function Get-CstPathFromCommandLine {
    param([string]$CommandLine)

    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return '' }

    $cmd = $CommandLine.Trim()
    if ($cmd -match '^"([A-Za-z]:\\[^\"]+)"') {
        return [string]$matches[1]
    }
    if ($cmd -match '^([A-Za-z]:\\[^\s]+)') {
        return [string]$matches[1]
    }

    return ''
}

function Invoke-CstDisableRunKeyEntry {
    param([Parameter(Mandatory)]$Artifact)

    $regPath = [string]$Artifact.location
    $valueName = [string]$Artifact.name
    if ([string]::IsNullOrWhiteSpace($regPath) -or [string]::IsNullOrWhiteSpace($valueName)) {
        throw 'Run key artifact is missing registry path or value name.'
    }

    if (-not (Test-Path $regPath)) {
        throw "Registry path not found: $regPath"
    }

    $value = Get-ItemPropertyValue -Path $regPath -Name $valueName -ErrorAction Stop
    $disabledKey = Join-Path $regPath 'AutorunsDisabled'
    if (-not (Test-Path -LiteralPath $disabledKey)) {
        New-Item -Path $disabledKey -Force -ErrorAction Stop | Out-Null
    }

    Set-ItemProperty -Path $disabledKey -Name $valueName -Value $value -ErrorAction Stop
    Remove-ItemProperty -Path $regPath -Name $valueName -ErrorAction Stop
    return "Disabled run key value '$valueName' in $regPath (stored under AutorunsDisabled)"
}

function Invoke-CstRestoreRunKeyEntry {
    param([Parameter(Mandatory)]$Artifact)

    $regPath = [string]$Artifact.location
    $valueName = [string]$Artifact.name
    if ([string]::IsNullOrWhiteSpace($regPath) -or [string]::IsNullOrWhiteSpace($valueName)) {
        throw 'Run key artifact is missing registry path or value name.'
    }

    $disabledKey = Join-Path $regPath 'AutorunsDisabled'
    if (-not (Test-Path -LiteralPath $disabledKey)) {
        throw "Disabled run key store not found: $disabledKey"
    }

    $value = Get-ItemPropertyValue -Path $disabledKey -Name $valueName -ErrorAction Stop
    Set-ItemProperty -Path $regPath -Name $valueName -Value $value -ErrorAction Stop
    Remove-ItemProperty -Path $disabledKey -Name $valueName -ErrorAction Stop
    return "Restored run key value '$valueName' to $regPath"
}

function Invoke-CstDisableScheduledTaskEntry {
    param([Parameter(Mandatory)]$Artifact)

    $taskName = [string]$Artifact.name
    $taskLocation = [string]$Artifact.location
    $taskPath = '\\'
    if ($taskLocation -match '^(.*\\)[^\\]+$') {
        $taskPath = [string]$matches[1]
    }

    if ([string]::IsNullOrWhiteSpace($taskName)) {
        throw 'Scheduled task artifact is missing task name.'
    }

    Disable-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop | Out-Null
    return "Disabled scheduled task '$taskPath$taskName'"
}

function Invoke-CstDisableServiceEntry {
    param([Parameter(Mandatory)]$Artifact)

    $serviceName = [string]$Artifact.name
    if ([string]::IsNullOrWhiteSpace($serviceName)) {
        throw 'Service artifact is missing service name.'
    }

    Set-Service -Name $serviceName -StartupType Disabled -ErrorAction Stop
    try {
        Stop-Service -Name $serviceName -Force -ErrorAction Stop
    } catch {}
    return "Disabled service '$serviceName'"
}

function Invoke-CstRemediation {
    param(
        [Parameter(Mandatory)]$Findings,
        [Parameter(Mandatory)][ValidateSet('Remove','Quarantine')][string]$Action,
        [string[]]$SelectedFindingId = @()
    )

    $storage = Initialize-CstStorage
    $envMode = Get-CstEnvironmentMode
    $batchId = [guid]::NewGuid().ToString('N')
    $selectedSet = @{}
    foreach ($id in @($SelectedFindingId)) {
        if (-not [string]::IsNullOrWhiteSpace($id)) {
            $selectedSet[$id] = $true
        }
    }

    $processed = New-Object System.Collections.Generic.List[object]
    $records = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[string]

    foreach ($finding in (ConvertTo-CstFindingArray -InputObject $Findings)) {
        $f = $finding.PSObject.Copy()
        $f = Ensure-CstFindingContract -Finding $f
        $f.selectedAction = $Action
        $f.actionState = 'Pending'
        $fId = [string]$f.id
        if ([string]::IsNullOrWhiteSpace($fId)) {
            $fId = [guid]::NewGuid().ToString('N')
            $f | Add-Member -NotePropertyName id -NotePropertyValue $fId -Force
        }

        if ($selectedSet.Count -gt 0 -and -not $selectedSet.ContainsKey($fId)) {
            $f.actionState = 'NotSelected'
            $processed.Add($f)
            continue
        }

        if (-not [bool]$f.canRemediate) {
            $f.remediationState = 'Skipped'
            $f.actionState = 'Skipped'
            $f.remediationNote = 'Finding is not eligible for remediation.'
            $processed.Add($f)
            continue
        }

        $location = [string]$f.location

        $record = [PSCustomObject]@{
            rollbackId = [guid]::NewGuid().ToString('N')
            batchId = $batchId
            findingId = $fId
            action = $Action
            type = [string]$f.type
            severity = [string]$f.severity
            detector = [string]$f.detector
            confidence = [double]$f.confidence
            objectType = [string]$f.objectType
            correlationId = [string]$f.correlationId
            originalPath = $location
            originalHash = ''
            quarantinedPath = ''
            persistenceActions = @()
            environmentMode = $envMode
            startedUtc = (Get-Date).ToUniversalTime().ToString('o')
            completedUtc = ''
            status = 'Pending'
            note = ''
        }

        try {
            $didFileAction = $false
            $didPersistenceAction = $false

            if (-not [string]::IsNullOrWhiteSpace($location) -and (Test-Path -LiteralPath $location -PathType Leaf)) {
                $record.originalHash = Get-CstFileHashSafe -Path $location
                $didFileAction = $true
            }

            $correlatedArtifacts = @()
            if ($f.PSObject.Properties['correlatedArtifacts']) {
                $correlatedArtifacts = @($f.correlatedArtifacts)
            }

            if ($correlatedArtifacts.Count -gt 0) {
                foreach ($artifact in $correlatedArtifacts) {
                    $kind = [string]$artifact.kind
                    if ($envMode -eq 'WinPE' -and $kind -in @('Process','ProcessModule','Service','ScheduledTask','RunKey')) {
                        $record.persistenceActions += [PSCustomObject]@{ kind = $kind; status = 'Skipped'; note = 'Live persistence action not applicable in WinPE.' }
                        continue
                    }

                    try {
                        switch ($kind) {
                            'RunKey' {
                                $msg = Invoke-CstDisableRunKeyEntry -Artifact $artifact
                                $record.persistenceActions += [PSCustomObject]@{
                                    kind     = $kind
                                    status   = 'Success'
                                    note     = $msg
                                    location = [string]$artifact.location
                                    name     = [string]$artifact.name
                                    artifact = $artifact
                                }
                                $didPersistenceAction = $true
                            }
                            'ScheduledTask' {
                                $msg = Invoke-CstDisableScheduledTaskEntry -Artifact $artifact
                                $record.persistenceActions += [PSCustomObject]@{ kind = $kind; status = 'Success'; note = $msg }
                                $didPersistenceAction = $true
                            }
                            'Service' {
                                $msg = Invoke-CstDisableServiceEntry -Artifact $artifact
                                $record.persistenceActions += [PSCustomObject]@{ kind = $kind; status = 'Success'; note = $msg }
                                $didPersistenceAction = $true
                            }
                        }
                    } catch {
                        $record.persistenceActions += [PSCustomObject]@{ kind = $kind; status = 'Failed'; note = $_.Exception.Message }
                    }
                }
            }

            if ($didFileAction) {
                if ($Action -eq 'Quarantine') {
                    $ext = [System.IO.Path]::GetExtension($location)
                    $qName = '{0}_{1}{2}' -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $fId, $ext
                    $qPath = Join-Path $storage.quarantine $qName
                    Move-Item -LiteralPath $location -Destination $qPath -Force

                    $record.quarantinedPath = $qPath
                    $record.note = 'File moved to quarantine store.'
                    $f.remediationState = 'Quarantined'
                    $f.actionState = 'Completed'
                    $f.remediationNote = "Moved to $qPath"
                } else {
                    Remove-Item -LiteralPath $location -Force
                    $record.note = 'File removed from original location.'
                    $f.remediationState = 'Removed'
                    $f.actionState = 'Completed'
                    $f.remediationNote = 'File deleted.'
                }
            } else {
                if ($didPersistenceAction) {
                    $f.remediationState = 'Removed'
                    $f.actionState = 'Completed'
                    $f.remediationNote = 'Persistence entries disabled.'
                    if ([string]::IsNullOrWhiteSpace($record.note)) {
                        $record.note = 'Persistence entries disabled.'
                    }
                } else {
                    $f.remediationState = 'Skipped'
                    $f.actionState = 'Skipped'
                    $f.remediationNote = 'No applicable file or persistence action target found.'
                    $record.note = 'No applicable file or persistence action target found.'
                }
            }

            $record.status = if ($f.remediationState -in @('Removed','Quarantined')) { 'Success' } elseif ($f.remediationState -eq 'Skipped') { 'Skipped' } else { 'Failed' }
            $record.completedUtc = (Get-Date).ToUniversalTime().ToString('o')

            $records.Add($record)
        } catch {
            $f.remediationState = 'Failed'
            $f.actionState = 'Failed'
            $f.remediationNote = $_.Exception.Message
            $record.status = 'Failed'
            $record.note = $_.Exception.Message
            $record.completedUtc = (Get-Date).ToUniversalTime().ToString('o')
            $records.Add($record)
            $errors.Add("${fId}: $($_.Exception.Message)")
        }

        $processed.Add($f)
    }

    $manifestPath = Join-Path $storage.rollback ("rollback_{0}.json" -f $batchId)
    $manifest = [PSCustomObject]@{
        batchId = $batchId
        createdUtc = (Get-Date).ToUniversalTime().ToString('o')
        action = $Action
        storageRoot = $storage.root
        quarantinePath = $storage.quarantine
        recordCount = $records.Count
        records = [object[]]$records.ToArray()
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -Path $manifestPath -Encoding UTF8

    return [PSCustomObject]@{
        action = $Action
        batchId = $batchId
        storageRoot = $storage.root
        quarantinePath = $storage.quarantine
        rollbackManifestPath = $manifestPath
        selectedCount = $selectedSet.Count
        processedFindings = [object[]]$processed.ToArray()
        succeeded = @($processed.ToArray() | Where-Object { $_.remediationState -in @('Removed','Quarantined') }).Count
        failed = @($processed.ToArray() | Where-Object { $_.remediationState -eq 'Failed' }).Count
        skipped = @($processed.ToArray() | Where-Object { $_.remediationState -eq 'Skipped' }).Count
        errors = [string[]]$errors.ToArray()
    }
}

function Invoke-CstRollback {
    param(
        [Parameter(Mandatory)][string]$RollbackManifestPath,
        [string[]]$SelectedRollbackId = @()
    )

    if (-not (Test-Path -LiteralPath $RollbackManifestPath -PathType Leaf)) {
        throw "Rollback manifest not found: $RollbackManifestPath"
    }

    $manifest = Get-Content -Path $RollbackManifestPath -Raw | ConvertFrom-Json
    if (-not $manifest.records) {
        throw "Rollback manifest is missing records: $RollbackManifestPath"
    }

    $selectedSet = @{}
    foreach ($id in @($SelectedRollbackId)) {
        if (-not [string]::IsNullOrWhiteSpace($id)) {
            $selectedSet[$id] = $true
        }
    }

    $updatedRecords = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[string]
    $restored = 0
    $failed = 0
    $skipped = 0

    foreach ($record in @($manifest.records)) {
        $current = $record.PSObject.Copy()
        $rollbackId = [string]$current.rollbackId

        if ($selectedSet.Count -gt 0 -and -not $selectedSet.ContainsKey($rollbackId)) {
            $current | Add-Member -NotePropertyName rollbackStatus -NotePropertyValue 'NotSelected' -Force
            $updatedRecords.Add($current)
            continue
        }

        $action = [string]$current.action
        $source = [string]$current.quarantinedPath
        $destination = [string]$current.originalPath
        $findingId = [string]$current.findingId

        $persistenceActions = @()
        if ($current.PSObject.Properties['persistenceActions']) {
            $persistenceActions = @($current.persistenceActions)
        }

        $runKeyRollbackAttempted = $false
        foreach ($persistenceAction in $persistenceActions) {
            if ([string]$persistenceAction.kind -ne 'RunKey' -or [string]$persistenceAction.status -ne 'Success') {
                continue
            }

            $artifact = $null
            if ($persistenceAction.PSObject.Properties['artifact']) {
                $artifact = $persistenceAction.artifact
            }
            if ($null -eq $artifact) {
                $artifact = [PSCustomObject]@{
                    location = if ($persistenceAction.PSObject.Properties['location']) { [string]$persistenceAction.location } else { '' }
                    name     = if ($persistenceAction.PSObject.Properties['name']) { [string]$persistenceAction.name } else { '' }
                }
            }

            try {
                $restoreMsg = Invoke-CstRestoreRunKeyEntry -Artifact $artifact
                $current | Add-Member -NotePropertyName rollbackStatus -NotePropertyValue 'Restored' -Force
                $current | Add-Member -NotePropertyName rollbackNote -NotePropertyValue $restoreMsg -Force
                $current | Add-Member -NotePropertyName rollbackTimestamp -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
                $updatedRecords.Add($current)
                $restored++
                $runKeyRollbackAttempted = $true
                break
            } catch {
                $current | Add-Member -NotePropertyName rollbackStatus -NotePropertyValue 'Failed' -Force
                $current | Add-Member -NotePropertyName rollbackNote -NotePropertyValue $_.Exception.Message -Force
                $updatedRecords.Add($current)
                $failed++
                $errors.Add("${rollbackId}: $($_.Exception.Message)")
                $runKeyRollbackAttempted = $true
                break
            }
        }

        if ($runKeyRollbackAttempted) {
            continue
        }

        if ($action -ne 'Quarantine') {
            $current | Add-Member -NotePropertyName rollbackStatus -NotePropertyValue 'Skipped' -Force
            $current | Add-Member -NotePropertyName rollbackNote -NotePropertyValue 'Only quarantine and disabled run key actions are reversible.' -Force
            $updatedRecords.Add($current)
            $skipped++
            continue
        }

        if ([string]::IsNullOrWhiteSpace($source) -or -not (Test-Path -LiteralPath $source -PathType Leaf)) {
            $quarantineRoot = [string]$manifest.quarantinePath
            if ([string]::IsNullOrWhiteSpace($quarantineRoot)) {
                $quarantineRoot = Join-Path (Get-CstStorageRoot) 'Quarantine'
            }

            if (-not [string]::IsNullOrWhiteSpace($findingId) -and (Test-Path -LiteralPath $quarantineRoot -PathType Container)) {
                $fallback = Get-ChildItem -Path $quarantineRoot -File -Filter "*$findingId*" -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($null -ne $fallback) {
                    $source = $fallback.FullName
                    $current | Add-Member -NotePropertyName rollbackSourceRecovered -NotePropertyValue $source -Force
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($source) -or -not (Test-Path -LiteralPath $source -PathType Leaf)) {
            $current | Add-Member -NotePropertyName rollbackStatus -NotePropertyValue 'Failed' -Force
            $current | Add-Member -NotePropertyName rollbackNote -NotePropertyValue 'Quarantine source file is missing.' -Force
            $updatedRecords.Add($current)
            $failed++
            $errors.Add("${rollbackId}: Quarantine source file is missing.")
            continue
        }

        if ([string]::IsNullOrWhiteSpace($destination)) {
            $current | Add-Member -NotePropertyName rollbackStatus -NotePropertyValue 'Failed' -Force
            $current | Add-Member -NotePropertyName rollbackNote -NotePropertyValue 'Original destination path is missing in manifest.' -Force
            $updatedRecords.Add($current)
            $failed++
            $errors.Add("${rollbackId}: Original destination path is missing in manifest.")
            continue
        }

        try {
            $destParent = Split-Path -Path $destination -Parent
            if (-not [string]::IsNullOrWhiteSpace($destParent) -and -not (Test-Path -LiteralPath $destParent)) {
                New-Item -Path $destParent -ItemType Directory -Force | Out-Null
            }

            if (Test-Path -LiteralPath $destination -PathType Leaf) {
                $conflictPath = "{0}.pre_restore_{1}" -f $destination, (Get-Date -Format 'yyyyMMdd_HHmmss')
                Move-Item -LiteralPath $destination -Destination $conflictPath -Force
                $current | Add-Member -NotePropertyName rollbackConflictPath -NotePropertyValue $conflictPath -Force
            }

            Move-Item -LiteralPath $source -Destination $destination -Force
            $current | Add-Member -NotePropertyName rollbackStatus -NotePropertyValue 'Restored' -Force
            $current | Add-Member -NotePropertyName rollbackNote -NotePropertyValue 'Quarantined file restored to original path.' -Force
            $current | Add-Member -NotePropertyName rollbackTimestamp -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
            $restored++
        } catch {
            $current | Add-Member -NotePropertyName rollbackStatus -NotePropertyValue 'Failed' -Force
            $current | Add-Member -NotePropertyName rollbackNote -NotePropertyValue $_.Exception.Message -Force
            $failed++
            $errors.Add("${rollbackId}: $($_.Exception.Message)")
        }

        $updatedRecords.Add($current)
    }

    $history = @()
    if ($manifest.PSObject.Properties['rollbackHistory']) {
        $history += @($manifest.rollbackHistory)
    }
    $history += [PSCustomObject]@{
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
        restored = $restored
        failed = $failed
        skipped = $skipped
    }

    $updatedManifest = [PSCustomObject]@{
        batchId = $manifest.batchId
        createdUtc = $manifest.createdUtc
        action = $manifest.action
        storageRoot = $manifest.storageRoot
        quarantinePath = $manifest.quarantinePath
        recordCount = $updatedRecords.Count
        records = [object[]]$updatedRecords.ToArray()
        rollbackHistory = $history
    }

    $updatedManifest | ConvertTo-Json -Depth 10 | Set-Content -Path $RollbackManifestPath -Encoding UTF8

    return [PSCustomObject]@{
        rollbackManifestPath = $RollbackManifestPath
        restored = $restored
        failed = $failed
        skipped = $skipped
        selectedCount = $selectedSet.Count
        errors = [string[]]$errors.ToArray()
    }
}

function Test-CstPatternMatch {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string[]]$Patterns
    )

    foreach ($pattern in $Patterns) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        if ($Value -match $pattern) { return $pattern }
    }
    return $null
}

function Get-CstRiskyPathRegex {
    return '(appdata\\(local\\)?temp|\\windows\\temp|\\users\\public\\|\\downloads\\|startup|programdata\\microsoft\\windows\\start menu\\programs\\startup)'
}

function Get-CstThreatScanRiskPathRegex {
    return 'appdata\\local\\temp\\|\\windows\\temp\\|\\users\\public\\|\\downloads\\|appdata\\roaming\\microsoft\\windows\\start menu\\programs\\startup\\|\\programdata\\coresecuritytool\\quarantine\\|\\programdata\\microsoft\\windows\\start menu\\programs\\startup\\|appdata\\roaming\\|\\windows\\system32\\tasks\\|appdata\\local\\microsoft\\windows\\inetcache\\'
}

function Test-CstThreatScanRiskPathIncluded {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$RiskPathRegex = (Get-CstThreatScanRiskPathRegex)
    )

    $pathLower = [string]$Path.ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($pathLower)) { return $false }
    return [bool]($pathLower -match $RiskPathRegex)
}

function Test-CstPathExcludedByPolicy {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$ScanPolicy
    )

    if (-not [bool]$ScanPolicy.exclusionsEnabled) { return $false }
    $pathLower = [string]$Path.ToLowerInvariant()
    foreach ($pat in @($ScanPolicy.exclusionPatterns)) {
        if ($pathLower -like $pat) { return $true }
    }

    return $false
}

function Get-CstFullScanPriorityBucket {
    param([Parameter(Mandatory)][string]$Path)

    $pathLower = [string]$Path.ToLowerInvariant()
    if (
        $pathLower -like '*\appdata\local\temp\*' -or
        $pathLower -like '*\windows\temp\*' -or
        $pathLower -like '*\users\public\downloads\*' -or
        $pathLower -like '*\appdata\roaming\microsoft\windows\start menu\programs\startup\*' -or
        $pathLower -like '*\programdata\microsoft\windows\start menu\programs\startup\*' -or
        $pathLower -like '*\windows\system32\tasks\*'
    ) {
        return 'high'
    }

    if (
        $pathLower -like '*\appdata\roaming\*' -or
        $pathLower -like '*\appdata\local\microsoft\windows\inetcache\*' -or
        $pathLower -like '*\programdata\*' -or
        $pathLower -like '*\downloads\*'
    ) {
        return 'medium'
    }

    return 'low'
}

function Test-CstScanCandidateIncluded {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('ThreatScan', 'FullScan', 'CustomScan')][string]$Mode,
        [Parameter(Mandatory)]$ScanPolicy
    )

    if ($Mode -eq 'ThreatScan' -and -not (Test-CstThreatScanRiskPathIncluded -Path $Path -RiskPathRegex ([string]$ScanPolicy.threatScanRiskRegex))) {
        return $false
    }

    return -not (Test-CstPathExcludedByPolicy -Path $Path -ScanPolicy $ScanPolicy)
}

function Test-CstIsRiskyPath {
    param([Parameter(Mandatory)][string]$Path)

    $pathLower = [string]$Path.ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($pathLower)) { return $false }
    return [bool]($pathLower -match (Get-CstRiskyPathRegex))
}

function Get-CstDependencyTrustPolicy {
    param([Parameter(Mandatory)]$Rules)

    $defaults = [PSCustomObject]@{
        enabled = $true
        minDllSignalsOutsideRiskPath = 3
        ignoreMissingVersionMetadataInTrustedPaths = $true
        trustedInstallPathRegex = '(\\program files\\|\\program files \(x86\)\\|appdata\\local\\programs\\|^c:\\windows\\system32\\|^c:\\windows\\syswow64\\)'
        siblingSignedExeTrust = $true
        dependencyExtensions = @('.dll')
    }

    if (-not $Rules.heuristicThresholds -or -not $Rules.heuristicThresholds.PSObject.Properties['dependencyTrustPolicy']) {
        return $defaults
    }

    $policy = $Rules.heuristicThresholds.dependencyTrustPolicy
    return [PSCustomObject]@{
        enabled = if ($policy.PSObject.Properties['enabled']) { [bool]$policy.enabled } else { $defaults.enabled }
        minDllSignalsOutsideRiskPath = if ($policy.PSObject.Properties['minDllSignalsOutsideRiskPath']) { [int]$policy.minDllSignalsOutsideRiskPath } else { $defaults.minDllSignalsOutsideRiskPath }
        ignoreMissingVersionMetadataInTrustedPaths = if ($policy.PSObject.Properties['ignoreMissingVersionMetadataInTrustedPaths']) { [bool]$policy.ignoreMissingVersionMetadataInTrustedPaths } else { $defaults.ignoreMissingVersionMetadataInTrustedPaths }
        trustedInstallPathRegex = if ($policy.PSObject.Properties['trustedInstallPathRegex']) { [string]$policy.trustedInstallPathRegex } else { $defaults.trustedInstallPathRegex }
        siblingSignedExeTrust = if ($policy.PSObject.Properties['siblingSignedExeTrust']) { [bool]$policy.siblingSignedExeTrust } else { $defaults.siblingSignedExeTrust }
        dependencyExtensions = if ($policy.PSObject.Properties['dependencyExtensions']) { @($policy.dependencyExtensions) } else { @($defaults.dependencyExtensions) }
    }
}

function Test-CstIsTrustedInstallPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$TrustedInstallPathRegex = ''
    )

    if ([string]::IsNullOrWhiteSpace($TrustedInstallPathRegex)) {
        $TrustedInstallPathRegex = '(\\program files\\|\\program files \(x86\)\\|appdata\\local\\programs\\|^c:\\windows\\system32\\|^c:\\windows\\syswow64\\)'
    }

    $pathLower = [string]$Path.ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($pathLower)) { return $false }
    return [bool]($pathLower -match $TrustedInstallPathRegex)
}

function Test-CstDirectoryHasSiblingTrustedSignedExecutable {
    param(
        [Parameter(Mandatory)][string]$DirectoryPath,
        [Parameter(Mandatory)]$Rules,
        [Parameter(Mandatory)][ValidateSet('Windows', 'WinPE')][string]$EnvironmentMode,
        [Parameter(Mandatory)]$SignatureCache,
        [Parameter(Mandatory)]$TrustedSiblingDirCache,
        [int]$SignatureTimeoutMs = 500
    )

    $dirKey = [string]$DirectoryPath.ToLowerInvariant().TrimEnd('\')
    if ($TrustedSiblingDirCache.ContainsKey($dirKey)) {
        return [bool]$TrustedSiblingDirCache[$dirKey]
    }

    $found = $false
    try {
        if (Test-Path -LiteralPath $DirectoryPath -PathType Container) {
            $exes = Get-ChildItem -LiteralPath $DirectoryPath -Filter '*.exe' -File -ErrorAction Stop
            foreach ($exe in @($exes)) {
                $sig = Get-CstAuthenticodeInfo -Path $exe.FullName -EnvironmentMode $EnvironmentMode -Cache $SignatureCache -TimeoutMs $SignatureTimeoutMs
                if ([string]$sig.signerStatus -eq 'Valid' -and (Test-CstPublisherIsAllowlisted -Publisher ([string]$sig.publisher) -Rules $Rules)) {
                    $found = $true
                    break
                }
            }
        }
    } catch {}

    $TrustedSiblingDirCache[$dirKey] = $found
    return $found
}

function Test-CstHasDependencyTrustContext {
    param(
        [Parameter(Mandatory)]$FileInfo,
        [Parameter(Mandatory)]$Rules,
        [Parameter(Mandatory)][ValidateSet('Windows', 'WinPE')][string]$EnvironmentMode,
        [Parameter(Mandatory)]$SignatureCache,
        [Parameter(Mandatory)]$TrustedSiblingDirCache,
        [int]$SignatureTimeoutMs = 500
    )

    $policy = Get-CstDependencyTrustPolicy -Rules $Rules
    if (-not [bool]$policy.enabled) { return $false }

    $extLower = [string]$FileInfo.Extension.ToLowerInvariant()
    $depExts = @($policy.dependencyExtensions | ForEach-Object { ([string]$_).ToLowerInvariant() })
    if ($depExts -notcontains $extLower) { return $false }

    $pathLower = [string]$FileInfo.FullName.ToLowerInvariant()
    if (Test-CstIsTrustedInstallPath -Path $pathLower -TrustedInstallPathRegex ([string]$policy.trustedInstallPathRegex)) {
        return $true
    }

    if ([bool]$policy.siblingSignedExeTrust) {
        $dir = [System.IO.Path]::GetDirectoryName([string]$FileInfo.FullName)
        if (-not [string]::IsNullOrWhiteSpace($dir)) {
            return (Test-CstDirectoryHasSiblingTrustedSignedExecutable -DirectoryPath $dir -Rules $Rules -EnvironmentMode $EnvironmentMode -SignatureCache $SignatureCache -TrustedSiblingDirCache $TrustedSiblingDirCache -SignatureTimeoutMs $SignatureTimeoutMs)
        }
    }

    return $false
}

function Get-CstHeuristicMinCombinedSignals {
    param(
        [Parameter(Mandatory)]$FileInfo,
        [Parameter(Mandatory)]$Rules
    )

    $base = 2
    if ($Rules.heuristicThresholds -and $Rules.heuristicThresholds.PSObject.Properties['minCombinedSignals']) {
        $base = [math]::Max(1, [int]$Rules.heuristicThresholds.minCombinedSignals)
    }

    $policy = Get-CstDependencyTrustPolicy -Rules $Rules
    if (-not [bool]$policy.enabled) { return $base }

    $extLower = [string]$FileInfo.Extension.ToLowerInvariant()
    if ($extLower -ne '.dll') { return $base }

    $pathLower = [string]$FileInfo.FullName.ToLowerInvariant()
    if (Test-CstIsRiskyPath -Path $pathLower) { return $base }

    return [math]::Max($base, [math]::Max(1, [int]$policy.minDllSignalsOutsideRiskPath))
}

function Test-CstHeuristicSignalsAreDependencyWeakOnly {
    param([Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Signals)

    if ($Signals.Count -eq 0) { return $false }

    foreach ($signal in @($Signals)) {
        $text = [string]$signal
        if ($text.StartsWith('high entropy (', [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($text.Equals('missing version metadata', [StringComparison]::OrdinalIgnoreCase)) { continue }
        return $false
    }

    return $true
}

function Test-CstPublisherIsTrustedVendor {
    param([string]$Publisher)

    if ([string]::IsNullOrWhiteSpace($Publisher)) { return $false }
    $pubLower = [string]$Publisher.ToLowerInvariant()
    if ($pubLower -eq '.net' -or $pubLower.Contains('microsoft')) {
        return $true
    }

    return $false
}

function Test-CstPublisherIsAllowlisted {
    param(
        [string]$Publisher,
        [Parameter(Mandatory)]$Rules
    )

    if ([string]::IsNullOrWhiteSpace($Publisher)) { return $false }
    if (Test-CstPublisherIsTrustedVendor -Publisher $Publisher) { return $true }
    if (-not $Rules.signerPolicies -or -not $Rules.signerPolicies.PSObject.Properties['allowPublishers']) {
        return $false
    }

    $pubLower = [string]$Publisher.ToLowerInvariant()
    foreach ($allowed in @($Rules.signerPolicies.allowPublishers)) {
        $allowedText = [string]$allowed
        if ([string]::IsNullOrWhiteSpace($allowedText)) { continue }
        if ($pubLower.Contains($allowedText.ToLowerInvariant())) {
            return $true
        }
    }

    return $false
}

function Test-CstShouldSuppressWeakContentFinding {
    param(
        [bool]$OnlineKnownGood,
        [string]$SignerStatus,
        [string]$Publisher,
        [Parameter(Mandatory)]$Rules
    )

    if ($OnlineKnownGood) { return $true }
    if ([string]$SignerStatus -eq 'Valid' -and (Test-CstPublisherIsAllowlisted -Publisher $Publisher -Rules $Rules)) {
        return $true
    }

    return $false
}

function Get-CstAdjustedContentClassification {
    param(
        [Parameter(Mandatory)][string]$Severity,
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][double]$Confidence,
        [Parameter(Mandatory)][string]$PathLower
    )

    if ($Severity -eq 'Critical' -and $Type -eq 'Malware' -and -not (Test-CstIsRiskyPath -Path $PathLower)) {
        return [PSCustomObject]@{
            severity = 'High'
            type = 'Suspicious'
            confidence = [math]::Min($Confidence, 0.78)
        }
    }

    return [PSCustomObject]@{
        severity = $Severity
        type = $Type
        confidence = $Confidence
    }
}

function ConvertTo-CstHashIocIndex {
    param([Parameter(Mandatory)]$Rules)

    $index = @{}
    foreach ($entry in @($Rules.hashes)) {
        if ($null -eq $entry) { continue }
        $rawHash = ''
        if ($entry.PSObject.Properties['sha256']) { $rawHash = [string]$entry.sha256 }
        elseif ($entry.PSObject.Properties['hash']) { $rawHash = [string]$entry.hash }
        $normalizedHash = $rawHash.Trim().ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace($normalizedHash)) { continue }
        if ($normalizedHash -notmatch '^[A-F0-9]{64}$') { continue }
        $index[$normalizedHash] = $entry
    }
    return $index
}

function Test-CstBytePattern {
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][byte[]]$Pattern
    )

    if ($Pattern.Length -eq 0) { return $false }
    if ($Pattern.Length -gt $Bytes.Length) { return $false }

    for ($i = 0; $i -le ($Bytes.Length - $Pattern.Length); $i++) {
        $matched = $true
        for ($j = 0; $j -lt $Pattern.Length; $j++) {
            if ($Bytes[$i + $j] -ne $Pattern[$j]) {
                $matched = $false
                break
            }
        }
        if ($matched) { return $true }
    }

    return $false
}

function ConvertTo-CstHexBytes {
    param([Parameter(Mandatory)][string]$Hex)

    $normalized = ($Hex -replace '\s+', '').Trim()
    if ([string]::IsNullOrWhiteSpace($normalized)) { return @() }
    if (($normalized.Length % 2) -ne 0) { return @() }
    if ($normalized -notmatch '^[0-9A-Fa-f]+$') { return @() }

    $bytes = New-Object byte[] ($normalized.Length / 2)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $bytes[$i] = [Convert]::ToByte($normalized.Substring($i * 2, 2), 16)
    }

    return $bytes
}

function Get-CstPeMetadataBlob {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Cache
    )

    if ($Cache.ContainsKey($Path)) {
        return [string]$Cache[$Path]
    }

    $blob = ''
    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        $vi = $item.VersionInfo
        if ($null -ne $vi) {
            $parts = @(
                [string]$vi.CompanyName,
                [string]$vi.FileDescription,
                [string]$vi.ProductName,
                [string]$vi.OriginalFilename,
                [string]$vi.InternalName,
                [string]$vi.Comments
            ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            if ($parts.Count -gt 0) {
                $blob = ($parts -join ' | ').ToLowerInvariant()
            }
        }
    } catch {}

    $Cache[$Path] = $blob
    return $blob
}

function Get-CstFileTextContent {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Cache,
        [int]$MaxBytes = 0
    )

    $cacheKey = if ($MaxBytes -gt 0) { "{0}|{1}" -f $Path, $MaxBytes } else { "{0}|full" -f $Path }
    if ($Cache.ContainsKey($cacheKey)) {
        return [string]$Cache[$cacheKey]
    }

    $text = ''
    try {
        if ($MaxBytes -gt 0) {
            $item = Get-Item -LiteralPath $Path -ErrorAction Stop
            if ($item.Length -le [long]$MaxBytes) {
                $text = (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop).ToLowerInvariant()
            }
        } else {
            $text = (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop).ToLowerInvariant()
        }
    } catch {}

    $Cache[$cacheKey] = $text
    return $text
}

function Get-CstFileBytes {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Cache,
        [int]$MaxBytes = 0
    )

    $cacheKey = if ($MaxBytes -gt 0) { "{0}|{1}" -f $Path, $MaxBytes } else { "{0}|full" -f $Path }
    if ($Cache.ContainsKey($cacheKey)) {
        return [byte[]]$Cache[$cacheKey]
    }

    $bytes = @()
    try {
        if ($MaxBytes -gt 0) {
            $item = Get-Item -LiteralPath $Path -ErrorAction Stop
            if ($item.Length -le [long]$MaxBytes) {
                $bytes = [System.IO.File]::ReadAllBytes($Path)
            }
        } else {
            $bytes = [System.IO.File]::ReadAllBytes($Path)
        }
    } catch {}

    $Cache[$cacheKey] = $bytes
    return [byte[]]$bytes
}

function Find-CstYaraLikeMatch {
    param(
        [Parameter(Mandatory)]$FileInfo,
        [Parameter(Mandatory)]$Rules,
        [Parameter(Mandatory)]$TextCache,
        [Parameter(Mandatory)]$ByteCache,
        [Parameter(Mandatory)]$PeMetaCache,
        [int]$MaxTextBytes = 0,
        [int]$MaxByteScanBytes = 0
    )

    $fileName = [string]$FileInfo.Name
    $fullPath = [string]$FileInfo.FullName
    $extLower = [string]$FileInfo.Extension.ToLowerInvariant()
    $nameLower = $fileName.ToLowerInvariant()
    $pathLower = $fullPath.ToLowerInvariant()

    foreach ($rule in @($Rules.yaraLikeRules)) {
        if ($null -eq $rule) { continue }

        $ruleName = if ($rule.PSObject.Properties['name']) { [string]$rule.name } else { 'UnnamedRule' }
        $logic = if ($rule.PSObject.Properties['logic']) { [string]$rule.logic } else { 'any' }
        $logicLower = $logic.ToLowerInvariant()
        if ($logicLower -notin @('all','any')) { $logicLower = 'any' }

        if ($rule.PSObject.Properties['enabled'] -and -not [bool]$rule.enabled) { continue }

        if ($rule.PSObject.Properties['excludePathRegex']) {
            $excludeRegex = [string]$rule.excludePathRegex
            if (-not [string]::IsNullOrWhiteSpace($excludeRegex)) {
                try {
                    if ($pathLower -match $excludeRegex.ToLowerInvariant()) { continue }
                } catch { }
            }
        }

        $extensions = @()
        if ($rule.PSObject.Properties['extensions']) {
            $extensions = @($rule.extensions | ForEach-Object { ([string]$_).ToLowerInvariant() })
        }
        if ($extensions.Count -gt 0 -and -not ($extensions -contains $extLower)) { continue }

        $checks = New-Object System.Collections.Generic.List[object]
        $matchSignals = New-Object System.Collections.Generic.List[string]

        if ($rule.PSObject.Properties['filenameRegex']) {
            $regex = [string]$rule.filenameRegex
            if (-not [string]::IsNullOrWhiteSpace($regex)) {
                $isMatch = $false
                try { $isMatch = [bool]($nameLower -match $regex.ToLowerInvariant()) } catch {}
                $checks.Add($isMatch)
                if ($isMatch) { $matchSignals.Add("filenameRegex=$regex") }
            }
        }

        if ($rule.PSObject.Properties['pathRegex']) {
            $regex = [string]$rule.pathRegex
            if (-not [string]::IsNullOrWhiteSpace($regex)) {
                $isMatch = $false
                try { $isMatch = [bool]($pathLower -match $regex.ToLowerInvariant()) } catch {}
                $checks.Add($isMatch)
                if ($isMatch) { $matchSignals.Add("pathRegex=$regex") }
            }
        }

        $containsText = @()
        if ($rule.PSObject.Properties['containsText']) { $containsText = @($rule.containsText) }
        if ($containsText.Count -gt 0) {
            $content = Get-CstFileTextContent -Path $fullPath -Cache $TextCache -MaxBytes $MaxTextBytes
            foreach ($needle in $containsText) {
                $n = [string]$needle
                if ([string]::IsNullOrWhiteSpace($n)) { continue }
                $hit = (-not [string]::IsNullOrWhiteSpace($content)) -and $content.Contains($n.ToLowerInvariant())
                $checks.Add($hit)
                if ($hit) { $matchSignals.Add("containsText=$n") }
            }
        }

        $containsBytes = @()
        if ($rule.PSObject.Properties['containsBytes']) { $containsBytes = @($rule.containsBytes) }
        if ($containsBytes.Count -gt 0) {
            $bytes = Get-CstFileBytes -Path $fullPath -Cache $ByteCache -MaxBytes $MaxByteScanBytes
            foreach ($hex in $containsBytes) {
                $hexStr = [string]$hex
                if ([string]::IsNullOrWhiteSpace($hexStr)) { continue }
                $patternBytes = ConvertTo-CstHexBytes -Hex $hexStr
                $hit = $false
                if ($patternBytes.Count -gt 0 -and $bytes.Count -gt 0) {
                    $hit = Test-CstBytePattern -Bytes $bytes -Pattern $patternBytes
                }
                $checks.Add($hit)
                if ($hit) { $matchSignals.Add("containsBytes=$hexStr") }
            }
        }

        $peMetadataStrings = @()
        if ($rule.PSObject.Properties['peMetadataStrings']) { $peMetadataStrings = @($rule.peMetadataStrings) }
        if ($peMetadataStrings.Count -gt 0 -and $extLower -in @('.exe','.dll','.sys')) {
            $meta = Get-CstPeMetadataBlob -Path $fullPath -Cache $PeMetaCache
            $peMetadataHitCount = 0
            foreach ($needle in $peMetadataStrings) {
                $n = [string]$needle
                if ([string]::IsNullOrWhiteSpace($n)) { continue }
                $hit = (-not [string]::IsNullOrWhiteSpace($meta)) -and $meta.Contains($n.ToLowerInvariant())
                if ($hit) {
                    $peMetadataHitCount++
                    $matchSignals.Add("peMetadata=$n")
                }
            }

            $peMetadataMinHits = 1
            if ($rule.PSObject.Properties['peMetadataMinHits']) {
                $peMetadataMinHits = [math]::Max(1, [int]$rule.peMetadataMinHits)
            }
            $checks.Add(($peMetadataHitCount -ge $peMetadataMinHits))
        }

        if ($checks.Count -eq 0) { continue }

        $ruleMatched = $false
        if ($logicLower -eq 'all') {
            $ruleMatched = ($checks -notcontains $false)
        } else {
            $ruleMatched = ($checks -contains $true)
        }

        if ($ruleMatched) {
            return [PSCustomObject]@{
                ruleName = $ruleName
                logic = $logicLower
                severity = if ($rule.PSObject.Properties['severity']) { [string]$rule.severity } else { 'High' }
                type = if ($rule.PSObject.Properties['type']) { [string]$rule.type } else { 'Malware' }
                confidence = if ($rule.PSObject.Properties['confidence']) { [double]$rule.confidence } else { 0.9 }
                objectType = if ($rule.PSObject.Properties['class'] -and ([string]$rule.class).ToLowerInvariant() -eq 'virus') { 'Virus' } else { 'File' }
                matchSummary = ($matchSignals -join '; ')
            }
        }
    }

    return $null
}

function Get-CstPublisherFromSubject {
    param([string]$Subject)

    if ([string]::IsNullOrWhiteSpace($Subject)) { return '' }
    if ($Subject -match 'CN\s*=\s*([^,]+)') {
        return $matches[1].Trim()
    }
    return $Subject.Trim()
}

function Get-CstAuthenticodeInfo {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('Windows','WinPE')][string]$EnvironmentMode,
        [Parameter(Mandatory)]$Cache,
        [int]$TimeoutMs = 0
    )

    if ($Cache.ContainsKey($Path)) {
        return $Cache[$Path]
    }

    if (-not $script:CstAuthenticodeProbeCompleted -and $EnvironmentMode -eq 'Windows') {
        $script:CstAuthenticodeProbeCompleted = $true
        try {
            $null = Get-AuthenticodeSignature -FilePath (Join-Path $env:WINDIR 'System32\notepad.exe') -ErrorAction Stop
            $script:CstAuthenticodeProbeAvailable = $true
            $script:CstAuthenticodeProbeMessage = ''
        } catch {
            $script:CstAuthenticodeProbeAvailable = $false
            $script:CstAuthenticodeProbeMessage = [string]$_.Exception.Message
        }
    }

    if ($EnvironmentMode -eq 'Windows' -and -not $script:CstAuthenticodeProbeAvailable) {
        $result = [PSCustomObject]@{
            available = $false
            signerStatus = 'InspectionUnavailable'
            publisher = ''
            statusCode = 'InspectionUnavailable'
            statusMessage = if ([string]::IsNullOrWhiteSpace($script:CstAuthenticodeProbeMessage)) { 'Authenticode inspection unavailable in current runtime.' } else { [string]$script:CstAuthenticodeProbeMessage }
        }
        $Cache[$Path] = $result
        return $result
    }

    if ($EnvironmentMode -eq 'WinPE') {
        $result = [PSCustomObject]@{
            available = $false
            signerStatus = 'UnavailableInWinPE'
            publisher = ''
            statusCode = ''
            statusMessage = 'Authenticode inspection is limited in WinPE.'
        }
        $Cache[$Path] = $result
        return $result
    }

    try {
        $sig = $null
        if ($TimeoutMs -gt 0) {
            $ps = [powershell]::Create()
            try {
                $null = $ps.AddScript('param($p) Get-AuthenticodeSignature -FilePath $p -ErrorAction Stop').AddArgument($Path)
                $async = $ps.BeginInvoke()
                $completed = $async.AsyncWaitHandle.WaitOne($TimeoutMs)
                if (-not $completed) {
                    try { $ps.Stop() } catch {}
                    $result = [PSCustomObject]@{
                        available = $false
                        signerStatus = 'TimeoutDuringInspection'
                        publisher = ''
                        statusCode = 'TimeoutDuringInspection'
                        statusMessage = "Authenticode inspection timed out after $TimeoutMs ms."
                    }
                    $Cache[$Path] = $result
                    return $result
                }

                $sigResult = $ps.EndInvoke($async)
                if ($sigResult -and $sigResult.Count -gt 0) {
                    $sig = $sigResult[0]
                }
            } finally {
                $ps.Dispose()
            }
        } else {
            $sig = Get-AuthenticodeSignature -FilePath $Path -ErrorAction Stop
        }

        if ($null -eq $sig) {
            throw "Authenticode inspection returned no result."
        }

        $publisher = ''
        if ($null -ne $sig.SignerCertificate) {
            $publisher = Get-CstPublisherFromSubject -Subject ([string]$sig.SignerCertificate.Subject)
        }

        $statusCode = [string]$sig.Status
        $signerStatus = if ($sig.Status -eq [System.Management.Automation.SignatureStatus]::Valid) { 'Valid' } else { $statusCode }

        $result = [PSCustomObject]@{
            available = $true
            signerStatus = $signerStatus
            publisher = $publisher
            statusCode = $statusCode
            statusMessage = [string]$sig.StatusMessage
        }
        $Cache[$Path] = $result
        return $result
    } catch {
        $result = [PSCustomObject]@{
            available = $false
            signerStatus = 'InspectionFailed'
            publisher = ''
            statusCode = 'InspectionFailed'
            statusMessage = $_.Exception.Message
        }
        $Cache[$Path] = $result
        return $result
    }
}

function Find-CstSignerPolicyMatch {
    param(
        [AllowNull()][string]$Publisher,
        [Parameter(Mandatory)]$Rules
    )

    if ([string]::IsNullOrWhiteSpace($Publisher)) {
        return [PSCustomObject]@{
            allowHit = $false
            denyHit = $false
            allowTerm = ''
            denyTerm = ''
        }
    }

    $pubLower = $Publisher.ToLowerInvariant()
    $allowHit = $false
    $denyHit = $false
    $allowTerm = ''
    $denyTerm = ''

    if ($Rules.signerPolicies) {
        foreach ($entry in @($Rules.signerPolicies.allowPublishers)) {
            $term = [string]$entry
            if ([string]::IsNullOrWhiteSpace($term)) { continue }
            if ($pubLower.Contains($term.ToLowerInvariant())) {
                $allowHit = $true
                $allowTerm = $term
                break
            }
        }

        foreach ($entry in @($Rules.signerPolicies.denyPublishers)) {
            $term = [string]$entry
            if ([string]::IsNullOrWhiteSpace($term)) { continue }
            if ($pubLower.Contains($term.ToLowerInvariant())) {
                $denyHit = $true
                $denyTerm = $term
                break
            }
        }
    }

    return [PSCustomObject]@{
        allowHit = $allowHit
        denyHit = $denyHit
        allowTerm = $allowTerm
        denyTerm = $denyTerm
    }
}

function Find-CstSignerTrustFinding {
    param(
        [Parameter(Mandatory)]$FileInfo,
        [Parameter(Mandatory)]$Rules,
        [Parameter(Mandatory)][ValidateSet('Windows','WinPE')][string]$EnvironmentMode,
        [Parameter(Mandatory)]$SignatureCache,
        [int]$SignatureTimeoutMs = 0,
        $SignatureInfo = $null
    )

    $extLower = [string]$FileInfo.Extension.ToLowerInvariant()
    if ($extLower -notin @('.exe','.dll','.sys')) {
        return $null
    }

    $fullPath = [string]$FileInfo.FullName
    $pathLower = $fullPath.ToLowerInvariant()
    $riskyPath = (Test-CstIsRiskyPath -Path $pathLower)
    $systemPath = ($pathLower -match '^c:\\windows\\system32\\' -or $pathLower -match '^c:\\program files')

    $sigInfo = $SignatureInfo
    if ($null -eq $sigInfo) {
        $sigInfo = Get-CstAuthenticodeInfo -Path $fullPath -EnvironmentMode $EnvironmentMode -Cache $SignatureCache -TimeoutMs $SignatureTimeoutMs
    }
    if (-not $sigInfo.available -and $EnvironmentMode -eq 'WinPE') {
        return $null
    }

    if (-not $sigInfo.available -and [string]$sigInfo.statusCode -eq 'InspectionUnavailable') {
        # Do not mass-flag executables when signature APIs are unavailable in this runtime.
        return $null
    }

    $publisher = [string]$sigInfo.publisher
    $signerStatus = [string]$sigInfo.signerStatus
    if ($EnvironmentMode -eq 'WinPE' -and $signerStatus -eq 'UnavailableInWinPE') {
        return $null
    }
    $policy = Find-CstSignerPolicyMatch -Publisher $publisher -Rules $Rules

    if ($policy.denyHit) {
        return [PSCustomObject]@{
            type = 'Malware'
            severity = 'High'
            confidence = 0.9
            evidence = "Signer policy denylist hit: $($policy.denyTerm)"
            publisher = $publisher
            signerStatus = $signerStatus
        }
    }

    if (-not $sigInfo.available) {
        $statusCode = [string]$sigInfo.statusCode
        if ($systemPath -and -not $riskyPath -and $statusCode -in @('TimeoutDuringInspection', 'InspectionFailed')) {
            # Avoid noisy signer findings for trusted install paths when Authenticode probing times out/fails.
            return $null
        }

        return [PSCustomObject]@{
            type = 'Suspicious'
            severity = 'Low'
            confidence = 0.3
            evidence = "Signer inspection unavailable: $($sigInfo.statusMessage)"
            publisher = $publisher
            signerStatus = $signerStatus
        }
    }

    if ($signerStatus -eq 'NotSigned' -and $riskyPath) {
        return [PSCustomObject]@{
            type = 'Suspicious'
            severity = 'Medium'
            confidence = 0.68
            evidence = 'Unsigned executable in risky path.'
            publisher = $publisher
            signerStatus = $signerStatus
        }
    }

    if ($signerStatus -eq 'Valid') {
        if (Test-CstPublisherIsAllowlisted -Publisher $publisher -Rules $Rules) {
            return $null
        }

        if (-not $riskyPath) {
            return $null
        }
    }

    if ($signerStatus -ne 'Valid' -and $signerStatus -ne 'NotSigned') {
        if ($systemPath -and -not $riskyPath -and $signerStatus -eq 'UnknownError') {
            # UnknownError is frequently transient for legitimate binaries in trusted install paths.
            return $null
        }

        $sev = if ($riskyPath) { 'High' } else { 'Medium' }
        $conf = if ($riskyPath) { 0.78 } else { 0.62 }
        return [PSCustomObject]@{
            type = 'Suspicious'
            severity = $sev
            confidence = $conf
            evidence = "Invalid signature status: $signerStatus"
            publisher = $publisher
            signerStatus = $signerStatus
        }
    }

    $hasAllowlist = @($Rules.signerPolicies.allowPublishers).Count -gt 0
    if ($systemPath -and $hasAllowlist -and -not $policy.allowHit -and -not [string]::IsNullOrWhiteSpace($publisher) -and $riskyPath) {
        return [PSCustomObject]@{
            type = 'Suspicious'
            severity = 'Medium'
            confidence = 0.57
            evidence = 'Signer/path mismatch: unallowlisted publisher in risky system-adjacent path.'
            publisher = $publisher
            signerStatus = $signerStatus
        }
    }

    return $null
}

function Get-CstShannonEntropy {
    param([Parameter(Mandatory)][byte[]]$Bytes)

    if ($Bytes.Length -eq 0) { return 0.0 }

    $freq = @{}
    foreach ($b in $Bytes) {
        if ($freq.ContainsKey($b)) { $freq[$b]++ } else { $freq[$b] = 1 }
    }

    $entropy = 0.0
    $len = [double]$Bytes.Length
    foreach ($count in $freq.Values) {
        $p = [double]$count / $len
        $entropy += (-1.0 * $p * ([math]::Log($p, 2)))
    }

    return $entropy
}

function Find-CstHeuristicFinding {
    param(
        [Parameter(Mandatory)]$FileInfo,
        [Parameter(Mandatory)]$Rules,
        [Parameter(Mandatory)]$ByteCache,
        [Parameter(Mandatory)]$PeMetaCache,
        [int]$MaxByteScanBytes = 0,
        [bool]$DependencyTrustContext = $false
    )

    $extLower = [string]$FileInfo.Extension.ToLowerInvariant()
    $nameLower = [string]$FileInfo.Name.ToLowerInvariant()
    $pathLower = [string]$FileInfo.FullName.ToLowerInvariant()
    $isPe = $extLower -in @('.exe','.dll','.sys')
    $isScript = $extLower -in @('.ps1','.vbs','.js','.jse','.wsf','.bat','.cmd','.lnk')

    if (-not $isPe -and -not $isScript) {
        return $null
    }

    $dependencyPolicy = Get-CstDependencyTrustPolicy -Rules $Rules
    $signals = New-Object System.Collections.Generic.List[string]
    $entropyValue = 0.0

    $entropyMb = 8
    if ($Rules.heuristicThresholds -and $Rules.heuristicThresholds.PSObject.Properties['maxEntropyFileSizeMb']) {
        $entropyMb = [int]$Rules.heuristicThresholds.maxEntropyFileSizeMb
    }
    $entropyThreshold = 7.2
    if ($Rules.heuristicThresholds -and $Rules.heuristicThresholds.PSObject.Properties['highEntropyThreshold']) {
        $entropyThreshold = [double]$Rules.heuristicThresholds.highEntropyThreshold
    }

    $maxEntropyBytes = $entropyMb * 1MB
    if ($MaxByteScanBytes -gt 0 -and $maxEntropyBytes -gt $MaxByteScanBytes) {
        $maxEntropyBytes = $MaxByteScanBytes
    }
    if ($FileInfo.Length -le $maxEntropyBytes) {
        $bytes = Get-CstFileBytes -Path $FileInfo.FullName -Cache $ByteCache -MaxBytes $maxEntropyBytes
        if ($bytes.Count -gt 0) {
            $entropyValue = Get-CstShannonEntropy -Bytes $bytes
            if ($entropyValue -ge $entropyThreshold) {
                $signals.Add(("high entropy ({0})" -f ([math]::Round($entropyValue, 2))))
            }
        }
    }

    if ($isPe) {
        $skipMissingMetadataSignal = $false
        if ([bool]$dependencyPolicy.enabled -and [bool]$dependencyPolicy.ignoreMissingVersionMetadataInTrustedPaths -and $extLower -eq '.dll') {
            if (Test-CstIsTrustedInstallPath -Path $pathLower -TrustedInstallPathRegex ([string]$dependencyPolicy.trustedInstallPathRegex)) {
                $skipMissingMetadataSignal = $true
            }
        }

        $meta = Get-CstPeMetadataBlob -Path $FileInfo.FullName -Cache $PeMetaCache
        if ([string]::IsNullOrWhiteSpace($meta) -and -not $skipMissingMetadataSignal) {
            $signals.Add('missing version metadata')
        }

        $sectionCandidates = @('.upx', '.aspack', '.packed', '.petite', '.themida', '.vmp')
        if ($Rules.heuristicThresholds -and $Rules.heuristicThresholds.PSObject.Properties['suspiciousSectionNames']) {
            $sectionCandidates = @($Rules.heuristicThresholds.suspiciousSectionNames)
        }

        $bytes = Get-CstFileBytes -Path $FileInfo.FullName -Cache $ByteCache -MaxBytes $MaxByteScanBytes
        if ($bytes.Count -gt 0) {
            foreach ($sectionName in $sectionCandidates) {
                $candidate = [string]$sectionName
                if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
                $needle = [System.Text.Encoding]::ASCII.GetBytes($candidate.ToLowerInvariant())
                if (Test-CstBytePattern -Bytes $bytes -Pattern $needle) {
                    $signals.Add("suspicious section marker ($candidate)")
                    break
                }
            }
        }
    }

    if ($nameLower -match '\.(txt|jpg|jpeg|png|gif|pdf|doc|docx|xls|xlsx|ppt|pptx)\.(exe|scr|pif|js|jse|vbs|wsf|bat|cmd)$') {
        $signals.Add('double extension masquerading')
    }

    if ($isScript -and $pathLower -match 'appdata\\(local\\temp|roaming)|\\windows\\temp\\|\\users\\public\\|\\downloads\\') {
        $signals.Add('script in high-risk temp/user path')
    }

    $minCombinedSignals = Get-CstHeuristicMinCombinedSignals -FileInfo $FileInfo -Rules $Rules
    if ($DependencyTrustContext -and (Test-CstHeuristicSignalsAreDependencyWeakOnly -Signals $signals)) {
        return $null
    }

    if ($signals.Count -lt $minCombinedSignals) {
        return $null
    }

    $severity = if ($signals.Count -ge 3) { 'High' } else { 'Medium' }
    $confidence = [math]::Min(0.88, (0.55 + ($signals.Count * 0.11)))

    return [PSCustomObject]@{
        type = 'Suspicious'
        severity = $severity
        confidence = $confidence
        evidence = "Heuristic composite ($($signals.Count) signals): $($signals -join '; ')"
        entropy = [math]::Round($entropyValue, 2)
    }
}

function Test-CstPerFileBudgetExceeded {
    param(
        [Parameter(Mandatory)][datetime]$StartedUtc,
        [Parameter(Mandatory)][int]$MaxMilliseconds
    )

    if ($MaxMilliseconds -le 0) { return $false }
    return (((Get-Date) - $StartedUtc).TotalMilliseconds -ge $MaxMilliseconds)
}

function Get-CstArchiveEntryText {
    param(
        [Parameter(Mandatory)]$ZipEntry,
        [int]$MaxBytes = 65536
    )

    try {
        $stream = $ZipEntry.Open()
        try {
            $bufferSize = [math]::Max(1, $MaxBytes)
            $buffer = New-Object byte[] $bufferSize
            $read = $stream.Read($buffer, 0, $bufferSize)
            if ($read -le 0) { return '' }
            return [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read).ToLowerInvariant()
        } finally {
            $stream.Dispose()
        }
    } catch {
        return ''
    }
}

function Find-CstArchiveFindings {
    param(
        [Parameter(Mandatory)]$FileInfo,
        [Parameter(Mandatory)]$Rules,
        [Parameter(Mandatory)]$Policy,
        [bool]$SuppressWeakContent = $false
    )

    $archiveFindings = New-Object System.Collections.Generic.List[object]
    if ($SuppressWeakContent) {
        return @($archiveFindings.ToArray())
    }

    if (-not [bool]$Policy.archiveInspectionEnabled) {
        return @($archiveFindings.ToArray())
    }

    $ext = [string]$FileInfo.Extension.ToLowerInvariant()
    if (-not (@($Policy.archiveExtensions) -contains $ext)) {
        return @($archiveFindings.ToArray())
    }

    $maxArchiveBytes = [int]$Policy.archiveMaxFileSizeMb * 1MB
    if ($FileInfo.Length -gt $maxArchiveBytes) {
        return @($archiveFindings.ToArray())
    }

    $maxEntries = [math]::Max(1, [int]$Policy.maxArchiveEntryCount)
    $maxEntryBytes = [long]([int]$Policy.maxArchiveEntrySizeMb * 1MB)
    $maxArchiveAnalysisMs = [math]::Max(1, [int]$Policy.maxArchiveAnalysisMs)
    $archiveStartedUtc = Get-Date
    if ($maxEntryBytes -lt 1) { $maxEntryBytes = 1 }
    $hits = 0
    $maxHits = 10

    try {
        Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue | Out-Null
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue | Out-Null
        $zip = [System.IO.Compression.ZipFile]::OpenRead([string]$FileInfo.FullName)
        try {
            $entryCount = 0
            foreach ($entry in @($zip.Entries)) {
                if (((Get-Date) - $archiveStartedUtc).TotalMilliseconds -ge $maxArchiveAnalysisMs) { break }
                if ($entryCount -ge $maxEntries -or $hits -ge $maxHits) { break }
                $entryCount++
                if ([string]::IsNullOrWhiteSpace([string]$entry.Name)) { continue }
                if ($entry.Length -gt $maxEntryBytes) { continue }

                $entryName = [string]$entry.Name
                $entryNameLower = $entryName.ToLowerInvariant()
                $archiveLocation = "{0}::{1}" -f $FileInfo.FullName, $entry.FullName

                $malwareHit = Test-CstPatternMatch -Value $entryNameLower -Patterns @($Rules.patterns.malware)
                if ($malwareHit) {
                    $archiveFindings.Add((New-CstFinding -Type 'Malware' -Severity 'High' -Name $entryName -Location $archiveLocation -Evidence "Archive entry name matched malware pattern: $malwareHit" -Detector 'ArchiveInspector' -Confidence 0.88 -ObjectType 'ArchiveEntry' -SignerStatus 'NotEvaluated' -CanRemediate $false))
                    $hits++
                    continue
                }

                $pupHit = Test-CstPatternMatch -Value $entryNameLower -Patterns @($Rules.patterns.pup)
                if ($pupHit) {
                    $archiveFindings.Add((New-CstFinding -Type 'PUP' -Severity 'Medium' -Name $entryName -Location $archiveLocation -Evidence "Archive entry name matched PUP pattern: $pupHit" -Detector 'ArchiveInspector' -Confidence 0.67 -ObjectType 'ArchiveEntry' -SignerStatus 'NotEvaluated' -CanRemediate $false))
                    $hits++
                    continue
                }

                if ($entryNameLower -match '\.(txt|jpg|jpeg|png|gif|pdf|doc|docx|xls|xlsx|ppt|pptx)\.(exe|scr|pif|js|jse|vbs|wsf|bat|cmd)$') {
                    $archiveFindings.Add((New-CstFinding -Type 'Suspicious' -Severity 'Medium' -Name $entryName -Location $archiveLocation -Evidence 'Archive entry has double-extension masquerading pattern.' -Detector 'ArchiveInspector' -Confidence 0.62 -ObjectType 'ArchiveEntry' -SignerStatus 'NotEvaluated' -CanRemediate $false))
                    $hits++
                    continue
                }

                $scriptExt = [System.IO.Path]::GetExtension($entryNameLower)
                if ($scriptExt -in @('.ps1','.vbs','.js','.jse','.wsf','.bat','.cmd')) {
                    $entryText = Get-CstArchiveEntryText -ZipEntry $entry -MaxBytes 65536
                    if (-not [string]::IsNullOrWhiteSpace($entryText) -and ($entryText.Contains('invoke-webrequest') -or $entryText.Contains('powershell -nop') -or $entryText.Contains(' -enc '))) {
                        $archiveFindings.Add((New-CstFinding -Type 'Suspicious' -Severity 'Medium' -Name $entryName -Location $archiveLocation -Evidence 'Archive script entry contains high-risk execution markers.' -Detector 'ArchiveInspector' -Confidence 0.7 -ObjectType 'ArchiveEntry' -SignerStatus 'NotEvaluated' -CanRemediate $false))
                        $hits++
                    }
                }
            }
        } finally {
            $zip.Dispose()
        }
    } catch {
        return @($archiveFindings.ToArray())
    }

    return @($archiveFindings.ToArray())
}

function Get-CstFilePatternExtensionSet {
    param([Parameter(Mandatory)][string[]]$FilePatterns)

    $extensions = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($pattern in @($FilePatterns)) {
        $normalized = [string]$pattern
        if ($normalized.StartsWith('*.', [StringComparison]::OrdinalIgnoreCase) -and $normalized.Length -gt 2) {
            [void]$extensions.Add($normalized.Substring(1).ToLowerInvariant())
        }
    }

    return $extensions
}

function Get-CstEnumerateCandidateFilePaths {
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][System.Collections.Generic.HashSet[string]]$Extensions
    )

    $root = Normalize-CstScanRootPath -Path $RootPath
    if ($root -match '^[A-Za-z]:\\?$') {
        $root = Normalize-CstScanRootPath -Path $root
    }
    $root = [string]$root.TrimEnd('\', '/')
    if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root)) {
        return
    }

    if (Test-Path -LiteralPath $root -PathType Leaf) {
        try {
            $ext = [System.IO.Path]::GetExtension($root)
            if ($Extensions.Contains($ext)) {
                Write-Output $root
            }
        } catch { }
        return
    }

    $enumerator = $null
    try {
        $enumOptions = [System.IO.EnumerationOptions]::new()
        $enumOptions.IgnoreInaccessible = $true
        $enumOptions.RecurseSubdirectories = $true
        $enumOptions.ReturnSpecialDirectories = $false
        $enumerator = [System.IO.Directory]::EnumerateFiles($root, '*', $enumOptions)
    } catch {
        try {
            $enumerator = [System.IO.Directory]::EnumerateFiles($root, '*', [System.IO.SearchOption]::AllDirectories)
        } catch {
            return
        }
    }

    if ($null -eq $enumerator) { return }

    try {
        foreach ($fullPath in $enumerator) {
            try {
                $ext = [System.IO.Path]::GetExtension($fullPath)
                if ($Extensions.Contains($ext)) {
                    Write-Output $fullPath
                }
            } catch {
                continue
            }
        }
    } catch {
        return
    }
}

function Find-CstFileFindings {
    param(
        [Parameter(Mandatory)][ValidateSet('ThreatScan','FullScan','CustomScan')][string]$Mode,
        [Parameter(Mandatory)][ValidateSet('Windows','WinPE')][string]$EnvironmentMode,
        [Parameter(Mandatory)][string[]]$Targets,
        [Parameter(Mandatory)]$Rules,
        [string]$RulesPath = '',
        [int]$MaxFiles = 15000,
        [int]$MaxMinutes = 15,
        [bool]$OfflineOnly = $false,
        [bool]$IncludesDriveRootScan = $false
    )

    if ([string]::IsNullOrWhiteSpace($RulesPath)) {
        $RulesPath = Join-Path $PSScriptRoot 'rules\rules.json'
    }

    $findings = New-Object System.Collections.Generic.List[object]
    $scanned = 0
    $errors = 0
    $scanErrorDetails = New-Object System.Collections.ArrayList
    $maxScanErrorDetails = 25
    $hashCache = @{}
    $sha1Cache = @{}
    $textCache = @{}
    $byteCache = @{}
    $peMetaCache = @{}
    $signatureCache = @{}
    $trustedSiblingDirCache = @{}
    $hashIocIndex = ConvertTo-CstHashIocIndex -Rules $Rules
    $knownGoodSkips = 0
    $trustedSignerSkips = 0
    $dependencyTrustSkips = 0
    $contentScansPerformed = 0
    $onlineLookupsPerformed = 0
    $knownGoodContext = Get-CstBootHashProfileContext -EnvironmentMode $EnvironmentMode -TargetResolution ([PSCustomObject]@{})
    $knownGoodStore = $null
    try {
        $knownGoodStore = Initialize-CstKnownGoodStore -Rules $Rules -RulesPath $RulesPath -Context $knownGoodContext -MalwareIocIndex $hashIocIndex
    } catch {
        Write-Warning ("CST known-good store initialization failed: {0}" -f $_.Exception.Message)
    }

    try {
    $progressTotal = 1
    $enumeratedCandidates = 0
    $filteredByRiskPath = 0
    $filteredByExclusion = 0
    $policy = Get-CstScanPolicy -Mode $Mode -Rules $Rules -EnvironmentMode $EnvironmentMode
    $filePatterns = @($policy.filePatterns)
    $extensionSet = Get-CstFilePatternExtensionSet -FilePatterns $filePatterns
    $visitedCandidatePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $hashEligibleExt = @($policy.hashEligibleExtensions)
    $threatScanRiskRegex = [string]$policy.threatScanRiskRegex
    $onlinePolicy = $policy.onlineReputation
    $onlineSkippedInEnvironment = ([bool]$onlinePolicy.skipInWinPE -and $EnvironmentMode -eq 'WinPE')
    $onlineStatus = Get-CstOnlineReputationStatus -Enabled ([bool]$onlinePolicy.enabled) -Provider ([string]$onlinePolicy.provider) -Endpoint ([string]$onlinePolicy.endpoint) -BatchSize ([int]$onlinePolicy.batchSize) -TimeoutSeconds ([int]$onlinePolicy.timeoutSeconds) -MinTrustScore ([int]$onlinePolicy.minTrustScore) -ModeEnabled ([bool]$onlinePolicy.modeEnabled) -SkippedInEnvironment $onlineSkippedInEnvironment -OfflineOnly $OfflineOnly
    $onlineActive = [bool]$onlinePolicy.enabled -and [bool]$onlinePolicy.modeEnabled -and -not $onlineSkippedInEnvironment -and -not $OfflineOnly
    $onlineMaxLookupsPerScan = 0
    if ($onlinePolicy.PSObject.Properties['maxLookupsPerScan']) {
        $onlineMaxLookupsPerScan = [int]$onlinePolicy.maxLookupsPerScan
    }
    if ($onlineMaxLookupsPerScan -lt 0) { $onlineMaxLookupsPerScan = 0 }
    $onlineStatus.active = $onlineActive
    $onlinePending = New-Object System.Collections.Generic.List[string]
    $onlineKnownGoodMap = @{}
    $skipLog = New-Object System.Collections.ArrayList
    $maxSkipLogEntries = 5000
    $fullScanPrioritizationApplied = $false
    $fullScanFirstCandidatePath = ''
    $fullScanPriorityBucketCounts = [ordered]@{
        high = 0
        medium = 0
        low = 0
    }
    $enumTargetCount = [math]::Max(1, @($Targets).Count)
    $enumTargetIndex = 0
    $lastEnumProgressUtc = [DateTime]::MinValue
    $lastEnumProgressCandidates = 0
    $enumExpectedCandidates = [math]::Max(1000, [int]([math]::Round($MaxFiles * 0.75)))
    $lastEnumPhasePercent = 0.0
    $addSkipEntry = {
        param(
            [Parameter(Mandatory)][string]$Reason,
            [string]$Path,
            [string]$Detail = '',
            [hashtable]$DetailPayload = $null
        )

        if ($skipLog.Count -ge $maxSkipLogEntries) { return }
        $reasonCategory = switch ($Reason) {
            'RiskPathFilter' { 'risk_path_filter' }
            'PathExclusion' { 'path_exclusion' }
            'MaxFilesCap' { 'max_files_cap' }
            'MaxMinutesCap' { 'max_minutes_cap' }
            'PerFileBudget' { 'per_file_budget' }
            default { 'other' }
        }

        $boundedPayload = $null
        if ($null -ne $DetailPayload) {
            $bounded = [ordered]@{}
            $keys = @($DetailPayload.Keys | Select-Object -First 5)
            foreach ($k in $keys) {
                $value = [string]$DetailPayload[$k]
                if ($value.Length -gt 120) {
                    $value = $value.Substring(0, 120)
                }
                $bounded[[string]$k] = $value
            }
            $boundedPayload = [PSCustomObject]$bounded
        }

        $entry = [ordered]@{
            reason = $Reason
            reasonCategory = $reasonCategory
            path = [string]$Path
            detail = [string]$Detail
        }
        if ($null -ne $boundedPayload) {
            $entry.detailPayload = $boundedPayload
        }

        [void]$skipLog.Add([PSCustomObject]$entry)
    }
    $getFullScanPriorityBucket = {
        param([string]$PathLower)
        Get-CstFullScanPriorityBucket -Path $PathLower
    }

    $scanStart = Get-Date
    $enablePipelineScan = $true
    $stopEnumeration = $false

    $maxHashBytes = [int]$policy.hashGateMb * 1MB
    $maxYaraTextBytes = [int]$policy.maxYaraTextFileSizeMb * 1MB
    $maxYaraByteScanBytes = [int]$policy.maxYaraByteFileSizeMb * 1MB
    $maxEntropyScanBytes = [int]$policy.maxEntropyBytesToScan
    $signatureTimeoutMs = [int]$policy.maxSignatureVerificationMs
    $slowFileThresholdMs = [math]::Max(1, [int]$policy.slowFileThresholdMs)
    $maxSlowFileEntries = [math]::Max(1, [int]$policy.maxSlowFileTelemetryEntries)
    $enableSignerTrust = [bool]$policy.enableSignerTrust
    $perFileBudgetMs = [int]$policy.maxPerFileAnalysisMs
    $perFileBudgetSkips = 0
    $slowFiles = New-Object System.Collections.ArrayList
    $effectiveMaxMinutes = if ($Mode -eq 'ThreatScan' -and $MaxMinutes -gt 0) { [int]$MaxMinutes } else { 0 }
    $timeLimitSec = if ($effectiveMaxMinutes -gt 0) { [math]::Max(1, [int]([math]::Ceiling($effectiveMaxMinutes * 60))) } else { 0 }
    $timeBudgetExceeded = $false
    $recentDurations = New-Object System.Collections.Generic.Queue[double]
    $recentAverageSec = 0.0
    $progressTotal = [math]::Max(1, $MaxFiles)

    $flushOnlineBatch = {
        if (-not $onlineActive) { return }
        if ($onlinePending.Count -eq 0) { return }

        $lookupResult = Invoke-CstCirclBulkSha1Lookup -Hashes @($onlinePending.ToArray()) -TimeoutSeconds ([int]$onlinePolicy.timeoutSeconds) -MinTrustScore ([int]$onlinePolicy.minTrustScore) -Endpoint ([string]$onlinePolicy.endpoint)
        $onlineStatus.requestsAttempted++
        if ($lookupResult.succeeded) {
            $onlineStatus.requestsSucceeded++
            $onlineStatus.parseErrors += [int]$lookupResult.parseErrors
            foreach ($k in $lookupResult.knownGoodMap.Keys) {
                $onlineKnownGoodMap[[string]$k] = $lookupResult.knownGoodMap[$k]
            }
        } else {
            $onlineStatus.requestsFailed++
            if ($lookupResult.timedOut) {
                $onlineStatus.requestTimeouts++
            }
            $onlineStatus.lastError = [string]$lookupResult.errorMessage
        }

        $onlinePending.Clear()
    }

    $analyzeCandidateFile = {
        param([Parameter(Mandatory)]$FileInfo)

        if ($scanned -ge $MaxFiles) {
            & $addSkipEntry -Reason 'MaxFilesCap' -Path $FileInfo.FullName -Detail ("Stopped at maxFiles cap ({0})." -f $MaxFiles) -DetailPayload @{
                phase = 'ScanLoop'
                scanned = $scanned
                maxFiles = $MaxFiles
            }
            return
        }
        if ($timeLimitSec -gt 0 -and (((Get-Date) - $scanStart).TotalSeconds -ge $timeLimitSec)) {
            & $addSkipEntry -Reason 'MaxMinutesCap' -Path $FileInfo.FullName -Detail ("Stopped at MaxMinutes cap ({0})." -f $effectiveMaxMinutes) -DetailPayload @{
                phase = 'ScanLoop'
                maxMinutes = $effectiveMaxMinutes
                mode = $Mode
            }
            return
        }

        $full = [string]$FileInfo.FullName
        $fileAnalysisStart = Get-Date
        try {
            $scanned++
            $scanPhasePercent = if ($progressTotal -gt 0) {
                [math]::Min(100.0, [math]::Round(($scanned / [double]$progressTotal) * 100.0, 1))
            } else {
                0.0
            }
            $scanOverallPercent = Get-CstScanOverallPercent -Scanned $scanned -MaxFiles $MaxFiles
            Write-CstLiveProgress -Scanned $scanned -ProgressTotal $progressTotal -CurrentPath $full -ElapsedSec (((Get-Date) - $scanStart).TotalSeconds) -RecentAverageSec $recentAverageSec -MinEtaSampleSize 25 -MaxBudgetSec $timeLimitSec -Phase 'Scanning' -PhasePercent $scanPhasePercent -OverallPercent $scanOverallPercent -TargetIndex $enumTargetIndex -TargetCount $enumTargetCount -EnumeratedCandidates $enumeratedCandidates -FilteredByRiskPath $filteredByRiskPath -FilteredByExclusion $filteredByExclusion -Detail ("Scanning {0:N0}/{1:N0}" -f $scanned, $progressTotal)

            $name = $FileInfo.Name
            $nameLower = $name.ToLowerInvariant()
            $pathLower = $full.ToLowerInvariant()
            $extLower = $FileInfo.Extension.ToLowerInvariant()

            if (Test-CstPerFileBudgetExceeded -StartedUtc $fileAnalysisStart -MaxMilliseconds $perFileBudgetMs) {
                $perFileBudgetSkips++
                & $addSkipEntry -Reason 'PerFileBudget' -Path $full -Detail ("Skipped before hash IOC phase; maxPerFileAnalysisMs={0}." -f $perFileBudgetMs) -DetailPayload @{
                    phase = 'HashIOC'
                    maxPerFileAnalysisMs = $perFileBudgetMs
                }
                return
            }

            if ($hashIocIndex.Count -gt 0 -and $hashEligibleExt -contains $extLower -and $FileInfo.Length -le $maxHashBytes) {
                $fileHash = ''
                if ($hashCache.ContainsKey($full)) {
                    $fileHash = [string]$hashCache[$full]
                } else {
                    $fileHash = Get-CstFileHashSafe -Path $full
                    $hashCache[$full] = $fileHash
                }

                $lookupHash = $fileHash.Trim().ToUpperInvariant()
                if ($hashIocIndex.ContainsKey($lookupHash)) {
                    $ioc = $hashIocIndex[$lookupHash]
                    $family = if ($ioc.PSObject.Properties['family']) { [string]$ioc.family } else { 'UnknownFamily' }
                    $severity = if ($ioc.PSObject.Properties['severity']) { [string]$ioc.severity } else { 'Critical' }
                    $evidenceText = if ($ioc.PSObject.Properties['evidence']) { [string]$ioc.evidence } else { 'Exact SHA256 IOC match.' }
                    $iocClass = if ($ioc.PSObject.Properties['class']) { [string]$ioc.class } else { '' }
                    $objectType = if ($iocClass.ToLowerInvariant() -eq 'virus') { 'Virus' } else { 'File' }
                    $finding = New-CstFinding -Type 'Malware' -Severity $severity -Name $name -Location $full -Evidence "SHA256 IOC hit ($family): $evidenceText" -Detector 'HashIOC' -Confidence 1.0 -ObjectType $objectType -Hash $lookupHash -SignerStatus 'NotEvaluated'
                    $findings.Add($finding)
                    Write-CstLiveFinding -Finding $finding
                    return
                }
            }

            $knownGoodHashHit = $false
            $trustedSignerEarlySkip = $false
            if ($Rules.knownGoodPolicy -and [bool]$Rules.knownGoodPolicy.enabled) {
                if ($hashEligibleExt -contains $extLower -and $FileInfo.Length -le $maxHashBytes) {
                    $kgHash = ''
                    if ($hashCache.ContainsKey($full)) {
                        $kgHash = [string]$hashCache[$full]
                    } else {
                        $kgHash = Get-CstFileHashSafe -Path $full
                        $hashCache[$full] = $kgHash
                    }
                    if (Test-CstSha256HashFormat -Hash $kgHash) {
                        $knownGoodHashHit = Test-CstKnownGoodHash -Sha256 $kgHash -MalwareIocIndex $hashIocIndex
                    }
                }

                if (-not $knownGoodHashHit) {
                    $earlyExitPolicy = $Rules.knownGoodPolicy.trustedSignerEarlyExit
                    if ($earlyExitPolicy -and [bool]$earlyExitPolicy.enabled) {
                        $earlyExts = @('.exe', '.dll', '.sys')
                        if ($earlyExitPolicy.PSObject.Properties['extensions']) {
                            $earlyExts = @($earlyExitPolicy.extensions | ForEach-Object { ([string]$_).ToLowerInvariant() })
                        }
                        if ($extLower -in $earlyExts) {
                            $earlySig = Get-CstAuthenticodeInfo -Path $full -EnvironmentMode $EnvironmentMode -Cache $signatureCache -TimeoutMs $signatureTimeoutMs
                            $trustedSignerEarlySkip = Test-CstTrustedSignerEarlyExit -Extension $extLower -SignerStatus ([string]$earlySig.signerStatus) -Publisher ([string]$earlySig.publisher) -Rules $Rules -EnvironmentMode $EnvironmentMode
                        }
                    }
                }

                if (Test-CstShouldSkipContentScan -KnownGoodHash $knownGoodHashHit -TrustedSignerSkip $trustedSignerEarlySkip -Rules $Rules) {
                    if ($knownGoodHashHit) {
                        $knownGoodSkips++
                    } elseif ($trustedSignerEarlySkip) {
                        $trustedSignerSkips++
                    }
                    return
                }
            }

            $contentScansPerformed++

            $onlineKnownGood = $false
            $fileSignerStatus = 'NotEvaluated'
            $filePublisher = ''
            $fileSigInfo = $null
            if (Test-CstPerFileBudgetExceeded -StartedUtc $fileAnalysisStart -MaxMilliseconds $perFileBudgetMs) {
                $perFileBudgetSkips++
                & $addSkipEntry -Reason 'PerFileBudget' -Path $full -Detail ("Skipped before online reputation phase; maxPerFileAnalysisMs={0}." -f $perFileBudgetMs) -DetailPayload @{
                    phase = 'OnlineReputation'
                    maxPerFileAnalysisMs = $perFileBudgetMs
                }
                return
            }

            if ($onlineActive -and $hashEligibleExt -contains $extLower -and $FileInfo.Length -le $maxHashBytes) {
                $onlineStatus.eligibleFiles++
                $sha1 = ''
                if ($sha1Cache.ContainsKey($full)) {
                    $sha1 = [string]$sha1Cache[$full]
                } else {
                    $sha1 = Get-CstFileHashSafeByAlgorithm -Path $full -Algorithm 'SHA1'
                    $sha1Cache[$full] = $sha1
                }

                $sha1Lookup = $sha1.Trim().ToUpperInvariant()
                if ($sha1Lookup -match '^[A-F0-9]{40}$') {
                    $onlineLookupAllowed = ($onlineMaxLookupsPerScan -le 0) -or ($onlineLookupsPerformed -lt $onlineMaxLookupsPerScan)
                    if (-not $onlineKnownGoodMap.ContainsKey($sha1Lookup)) {
                        if ($onlineLookupAllowed -and -not ($onlinePending -contains $sha1Lookup)) {
                            $onlinePending.Add($sha1Lookup)
                            $onlineLookupsPerformed++
                        }
                        if ($onlinePending.Count -ge [int]$onlinePolicy.batchSize) {
                            & $flushOnlineBatch
                        }
                    }

                    if ($onlineKnownGoodMap.ContainsKey($sha1Lookup)) {
                        $onlineState = $onlineKnownGoodMap[$sha1Lookup]
                        $onlineKnownGood = [bool]$onlineState.knownGood
                        if ($onlineKnownGood) {
                            $onlineStatus.knownGoodHits++
                        }
                    }
                }
            }

            if (($enableSignerTrust -or $onlineActive) -and $extLower -in @('.exe', '.dll', '.sys')) {
                $fileSigInfo = Get-CstAuthenticodeInfo -Path $full -EnvironmentMode $EnvironmentMode -Cache $signatureCache -TimeoutMs $signatureTimeoutMs
                $fileSignerStatus = [string]$fileSigInfo.signerStatus
                $filePublisher = [string]$fileSigInfo.publisher
            }

            $suppressWeakContent = Test-CstShouldSuppressWeakContentFinding -OnlineKnownGood $onlineKnownGood -SignerStatus $fileSignerStatus -Publisher $filePublisher -Rules $Rules
            $dependencyTrustContext = Test-CstHasDependencyTrustContext -FileInfo $FileInfo -Rules $Rules -EnvironmentMode $EnvironmentMode -SignatureCache $signatureCache -TrustedSiblingDirCache $trustedSiblingDirCache -SignatureTimeoutMs $signatureTimeoutMs

            if (Test-CstPerFileBudgetExceeded -StartedUtc $fileAnalysisStart -MaxMilliseconds $perFileBudgetMs) {
                $perFileBudgetSkips++
                & $addSkipEntry -Reason 'PerFileBudget' -Path $full -Detail ("Skipped before YARA/pattern phase; maxPerFileAnalysisMs={0}." -f $perFileBudgetMs) -DetailPayload @{
                    phase = 'YaraPattern'
                    maxPerFileAnalysisMs = $perFileBudgetMs
                }
                return
            }

            if ($FileInfo.Length -gt $maxYaraTextBytes) {
                & $addSkipEntry -Reason 'PerFileBudget' -Path $full -Detail ("Capped text inspection for oversized file (> {0} MB)." -f [int]$policy.maxYaraTextFileSizeMb) -DetailPayload @{
                    phase = 'YaraTextReadCap'
                    maxYaraTextFileSizeMb = [int]$policy.maxYaraTextFileSizeMb
                }
            }
            if ($FileInfo.Length -gt $maxYaraByteScanBytes) {
                & $addSkipEntry -Reason 'PerFileBudget' -Path $full -Detail ("Capped byte inspection for oversized file (> {0} MB)." -f [int]$policy.maxYaraByteFileSizeMb) -DetailPayload @{
                    phase = 'YaraByteReadCap'
                    maxYaraByteFileSizeMb = [int]$policy.maxYaraByteFileSizeMb
                }
            }

            $yaraMatch = Find-CstYaraLikeMatch -FileInfo $FileInfo -Rules $Rules -TextCache $textCache -ByteCache $byteCache -PeMetaCache $peMetaCache -MaxTextBytes $maxYaraTextBytes -MaxByteScanBytes $maxYaraByteScanBytes
            if ($null -ne $yaraMatch) {
                if (-not $suppressWeakContent) {
                    $fileHash = ''
                    if ($hashCache.ContainsKey($full)) {
                        $fileHash = [string]$hashCache[$full]
                    } elseif ($hashEligibleExt -contains $extLower -and $FileInfo.Length -le $maxHashBytes) {
                        $fileHash = Get-CstFileHashSafe -Path $full
                        $hashCache[$full] = $fileHash
                    }

                    $adjusted = Get-CstAdjustedContentClassification -Severity $yaraMatch.severity -Type $yaraMatch.type -Confidence $yaraMatch.confidence -PathLower $pathLower
                    $finding = New-CstFinding -Type $adjusted.type -Severity $adjusted.severity -Name $name -Location $full -Evidence "YARA-like rule hit [$($yaraMatch.ruleName)] ($($yaraMatch.logic)): $($yaraMatch.matchSummary)" -Detector 'YaraLike' -Confidence $adjusted.confidence -ObjectType $yaraMatch.objectType -Hash $fileHash -SignerStatus $fileSignerStatus -Publisher $filePublisher
                    $findings.Add($finding)
                    Write-CstLiveFinding -Finding $finding
                } elseif ($onlineKnownGood) {
                    $onlineStatus.suppressedFindings++
                }
                return
            }

            if (-not $suppressWeakContent) {
                $malwareHit = Test-CstPatternMatch -Value $nameLower -Patterns @($Rules.patterns.malware)
                if ($malwareHit) {
                    $fileHash = Get-CstFileHashSafe -Path $full
                    $adjusted = Get-CstAdjustedContentClassification -Severity 'Critical' -Type 'Malware' -Confidence 0.95 -PathLower $pathLower
                    $finding = New-CstFinding -Type $adjusted.type -Severity $adjusted.severity -Name $name -Location $full -Evidence "Matched malware pattern: $malwareHit" -Detector 'PatternEngine' -Confidence $adjusted.confidence -ObjectType 'File' -Hash $fileHash -SignerStatus $fileSignerStatus -Publisher $filePublisher
                    $findings.Add($finding)
                    Write-CstLiveFinding -Finding $finding
                    return
                }

                $pupHit = Test-CstPatternMatch -Value $nameLower -Patterns @($Rules.patterns.pup)
                if ($pupHit) {
                    $fileHash = Get-CstFileHashSafe -Path $full
                    $finding = New-CstFinding -Type 'PUP' -Severity 'Medium' -Name $name -Location $full -Evidence "Matched PUP pattern: $pupHit" -Detector 'PatternEngine' -Confidence 0.72 -ObjectType 'File' -Hash $fileHash -SignerStatus $fileSignerStatus -Publisher $filePublisher
                    $findings.Add($finding)
                    Write-CstLiveFinding -Finding $finding
                    return
                }
            } elseif ($onlineKnownGood) {
                $onlineStatus.suppressedFindings++
            }

            if ($enableSignerTrust) {
                if (Test-CstPerFileBudgetExceeded -StartedUtc $fileAnalysisStart -MaxMilliseconds $perFileBudgetMs) {
                    $perFileBudgetSkips++
                    & $addSkipEntry -Reason 'PerFileBudget' -Path $full -Detail ("Skipped before signer-trust phase; maxPerFileAnalysisMs={0}." -f $perFileBudgetMs) -DetailPayload @{
                        phase = 'SignerTrust'
                        maxPerFileAnalysisMs = $perFileBudgetMs
                    }
                    return
                }

                $prefetchedSig = $fileSigInfo

                $signerFinding = Find-CstSignerTrustFinding -FileInfo $FileInfo -Rules $Rules -EnvironmentMode $EnvironmentMode -SignatureCache $signatureCache -SignatureTimeoutMs $signatureTimeoutMs -SignatureInfo $prefetchedSig
                if ($null -ne $signerFinding) {
                    if ($suppressWeakContent -or ($dependencyTrustContext -and [string]$signerFinding.severity -in @('Low') -and [double]$signerFinding.confidence -lt 0.7)) {
                        if ($dependencyTrustContext) { $dependencyTrustSkips++ }
                        $onlineStatus.suppressedFindings++
                        return
                    }
                    $fileHash = ''
                    if ($hashCache.ContainsKey($full)) {
                        $fileHash = [string]$hashCache[$full]
                    } elseif ($hashEligibleExt -contains $extLower -and $FileInfo.Length -le $maxHashBytes) {
                        $fileHash = Get-CstFileHashSafe -Path $full
                        $hashCache[$full] = $fileHash
                    }

                    $finding = New-CstFinding -Type $signerFinding.type -Severity $signerFinding.severity -Name $name -Location $full -Evidence $signerFinding.evidence -Detector 'SignerTrust' -Confidence $signerFinding.confidence -ObjectType 'File' -Hash $fileHash -Publisher $signerFinding.publisher -SignerStatus $signerFinding.signerStatus
                    $findings.Add($finding)
                    Write-CstLiveFinding -Finding $finding
                }
            }

            if (Test-CstPerFileBudgetExceeded -StartedUtc $fileAnalysisStart -MaxMilliseconds $perFileBudgetMs) {
                $perFileBudgetSkips++
                & $addSkipEntry -Reason 'PerFileBudget' -Path $full -Detail ("Skipped before heuristic phase; maxPerFileAnalysisMs={0}." -f $perFileBudgetMs) -DetailPayload @{
                    phase = 'Heuristic'
                    maxPerFileAnalysisMs = $perFileBudgetMs
                }
                return
            }

            $heuristicFinding = Find-CstHeuristicFinding -FileInfo $FileInfo -Rules $Rules -ByteCache $byteCache -PeMetaCache $peMetaCache -MaxByteScanBytes $maxEntropyScanBytes -DependencyTrustContext $dependencyTrustContext
            if ($null -ne $heuristicFinding) {
                if ($suppressWeakContent) {
                    $onlineStatus.suppressedFindings++
                    return
                }
                $fileHash = ''
                if ($hashCache.ContainsKey($full)) {
                    $fileHash = [string]$hashCache[$full]
                } elseif ($hashEligibleExt -contains $extLower -and $FileInfo.Length -le $maxHashBytes) {
                    $fileHash = Get-CstFileHashSafe -Path $full
                    $hashCache[$full] = $fileHash
                }

                $finding = New-CstFinding -Type $heuristicFinding.type -Severity $heuristicFinding.severity -Name $name -Location $full -Evidence $heuristicFinding.evidence -Detector 'HeuristicEngine' -Confidence $heuristicFinding.confidence -ObjectType 'File' -Hash $fileHash -SignerStatus 'NotEvaluated' -Entropy $heuristicFinding.entropy
                $findings.Add($finding)
                Write-CstLiveFinding -Finding $finding
                return
            }

            if (-not (Test-CstPerFileBudgetExceeded -StartedUtc $fileAnalysisStart -MaxMilliseconds $perFileBudgetMs)) {
                $archiveFindings = Find-CstArchiveFindings -FileInfo $FileInfo -Rules $Rules -Policy $policy -SuppressWeakContent $suppressWeakContent
                foreach ($archiveFinding in @($archiveFindings)) {
                    $findings.Add($archiveFinding)
                    Write-CstLiveFinding -Finding $archiveFinding
                }
            } else {
                $perFileBudgetSkips++
                & $addSkipEntry -Reason 'PerFileBudget' -Path $full -Detail ("Skipped before archive inspection phase; maxPerFileAnalysisMs={0}." -f $perFileBudgetMs) -DetailPayload @{
                    phase = 'ArchiveInspection'
                    maxPerFileAnalysisMs = $perFileBudgetMs
                }
                return
            }

            $isRiskScriptPath = (
                $pathLower -like '*\appdata\local\temp\*' -or
                $pathLower -like '*\appdata\roaming\microsoft\windows\start menu\programs\startup\*' -or
                $pathLower -like '*\users\public\downloads\*' -or
                $pathLower -like '*\windows\temp\*'
            )
            if ($isRiskScriptPath -and $nameLower -match '\.(ps1|vbs|js|jse|wsf|bat|cmd)$') {
                if ($suppressWeakContent) {
                    $onlineStatus.suppressedFindings++
                    return
                }
                $finding = New-CstFinding -Type 'Suspicious' -Severity 'Low' -Name $name -Location $full -Evidence 'Script file located in high-risk user path' -Detector 'PathHeuristic' -Confidence 0.45 -ObjectType 'File' -SignerStatus 'NotEvaluated'
                $findings.Add($finding)
                Write-CstLiveFinding -Finding $finding
            }
        } catch {
            $errors++
            $errorType = if ($_.Exception -and $_.Exception.GetType()) { $_.Exception.GetType().FullName } else { 'UnknownException' }
            $errorMessage = [string]$_.Exception.Message
            if ($scanErrorDetails.Count -lt $maxScanErrorDetails) {
                [void]$scanErrorDetails.Add([PSCustomObject]@{
                    stage = 'PerFileAnalysis'
                    target = ''
                    path = [string]$full
                    message = "[$errorType] $errorMessage"
                })
            }
        } finally {
            $fileDurationSec = ((Get-Date) - $fileAnalysisStart).TotalSeconds
            if ($fileDurationSec -ge 0) {
                $fileDurationMs = [int][math]::Round($fileDurationSec * 1000)
                if ($fileDurationMs -ge $slowFileThresholdMs -and $slowFiles.Count -lt $maxSlowFileEntries) {
                    [void]$slowFiles.Add([PSCustomObject]@{
                        path = [string]$full
                        durationMs = $fileDurationMs
                        sizeBytes = [int64]$FileInfo.Length
                    })
                }

                $recentDurations.Enqueue([double]$fileDurationSec)
                if ($recentDurations.Count -gt 40) {
                    [void]$recentDurations.Dequeue()
                }

                $avg = ($recentDurations.ToArray() | Measure-Object -Average).Average
                if ($null -ne $avg) {
                    $recentAverageSec = [double]$avg
                }
            }
        }
    }

    $candidateFiles = New-Object System.Collections.Generic.List[object]
    foreach ($target in $Targets) {
        if ($stopEnumeration) { break }
        $enumTargetIndex++
        if (-not (Test-Path $target)) { continue }

        $enumTargetCandidateCount = 0
        $enumTargetExpectedCandidates = [math]::Max(200, [int]([math]::Round($enumExpectedCandidates / [double]$enumTargetCount)))
        $enumTargetFloor = [math]::Round((($enumTargetIndex - 1) / [double]$enumTargetCount) * 100.0, 1)
        if ($enumTargetFloor -gt $lastEnumPhasePercent) {
            $lastEnumPhasePercent = $enumTargetFloor
        }

        $targetStartDetail = if ($enablePipelineScan) {
            ("Starting target {0}/{1}: {2}" -f $enumTargetIndex, $enumTargetCount, $target)
        } else {
            ("Enumerating target {0}/{1}: {2}" -f $enumTargetIndex, $enumTargetCount, $target)
        }
        $targetStartPhase = if ($enablePipelineScan) { 'Scanning' } else { 'Enumerating' }
        $targetStartScanned = if ($enablePipelineScan) { $scanned } else { $enumeratedCandidates }
        $targetStartOverall = Get-CstScanOverallPercent -Scanned $scanned -MaxFiles $MaxFiles
        Write-CstLiveProgress -Scanned $targetStartScanned -ProgressTotal $progressTotal -CurrentPath $target -ElapsedSec (((Get-Date) - $scanStart).TotalSeconds) -Phase $targetStartPhase -PhasePercent $lastEnumPhasePercent -OverallPercent $targetStartOverall -TargetIndex $enumTargetIndex -TargetCount $enumTargetCount -EnumeratedCandidates $enumeratedCandidates -FilteredByRiskPath $filteredByRiskPath -FilteredByExclusion $filteredByExclusion -Detail $targetStartDetail

        $walkRoot = [string]$target.TrimEnd('\', '/')
        try {
            foreach ($candidatePath in (Get-CstEnumerateCandidateFilePaths -RootPath $walkRoot -Extensions $extensionSet)) {
                if (-not $visitedCandidatePaths.Add([string]$candidatePath)) { continue }

                $candidate = Get-Item -LiteralPath $candidatePath -Force -ErrorAction SilentlyContinue
                if ($null -eq $candidate -or $candidate.PSIsContainer) { continue }

                $enumeratedCandidates++
                $enumTargetCandidateCount++
                $enumTargetCeiling = [math]::Round(($enumTargetIndex / [double]$enumTargetCount) * 100.0, 1)
                $enumTargetRatio = [math]::Min(0.95, ($enumTargetCandidateCount / [double]$enumTargetExpectedCandidates))
                $enumPhasePercent = [math]::Round($enumTargetFloor + (($enumTargetCeiling - $enumTargetFloor) * $enumTargetRatio), 1)
                if ($enumPhasePercent -gt 99.0) { $enumPhasePercent = 99.0 }
                if ($enumPhasePercent -lt $lastEnumPhasePercent) { $enumPhasePercent = $lastEnumPhasePercent }
                $lastEnumPhasePercent = $enumPhasePercent

                $walkProgressStep = if ($enablePipelineScan -and $scanned -eq 0) { 15 } else { 200 }
                $walkProgressMs = if ($enablePipelineScan -and $scanned -eq 0) { 200 } else { 450 }
                $shouldEmitEnumProgress = ($enumeratedCandidates - $lastEnumProgressCandidates -ge $walkProgressStep) -or ((([DateTime]::UtcNow) - $lastEnumProgressUtc).TotalMilliseconds -ge $walkProgressMs)
                if ($shouldEmitEnumProgress) {
                    if ($enablePipelineScan) {
                        $walkScanPhasePercent = if ($progressTotal -gt 0) {
                            [math]::Min(100.0, [math]::Round(($scanned / [double]$progressTotal) * 100.0, 1))
                        } else {
                            0.0
                        }
                        $walkScanOverall = Get-CstScanOverallPercent -Scanned $scanned -MaxFiles $MaxFiles
                        Write-CstLiveProgress -Scanned $scanned -ProgressTotal $progressTotal -CurrentPath $candidate.FullName -ElapsedSec (((Get-Date) - $scanStart).TotalSeconds) -RecentAverageSec $recentAverageSec -MinEtaSampleSize 25 -MaxBudgetSec $timeLimitSec -Phase 'Scanning' -PhasePercent $walkScanPhasePercent -OverallPercent $walkScanOverall -TargetIndex $enumTargetIndex -TargetCount $enumTargetCount -EnumeratedCandidates $enumeratedCandidates -FilteredByRiskPath $filteredByRiskPath -FilteredByExclusion $filteredByExclusion -Detail ("Scanning {0:N0}/{1:N0} • walked {2:N0} paths (target {3}/{4})" -f $scanned, $progressTotal, $enumeratedCandidates, $enumTargetIndex, $enumTargetCount)
                    } else {
                        Write-CstLiveProgress -Scanned $enumeratedCandidates -ProgressTotal ([math]::Max(1, $enumExpectedCandidates)) -CurrentPath $candidate.FullName -ElapsedSec (((Get-Date) - $scanStart).TotalSeconds) -Phase 'Enumerating' -PhasePercent $enumPhasePercent -OverallPercent (10.0 + ($enumPhasePercent * 0.25)) -TargetIndex $enumTargetIndex -TargetCount $enumTargetCount -EnumeratedCandidates $enumeratedCandidates -FilteredByRiskPath $filteredByRiskPath -FilteredByExclusion $filteredByExclusion -Detail ("Enumerating target {0}/{1} ({2:N0} candidates found)" -f $enumTargetIndex, $enumTargetCount, $enumeratedCandidates)
                    }
                    $lastEnumProgressUtc = [DateTime]::UtcNow
                    $lastEnumProgressCandidates = $enumeratedCandidates
                }

                $candidatePathLower = [string]$candidate.FullName.ToLowerInvariant()
                if ($Mode -eq 'ThreatScan') {
                    if (-not (Test-CstThreatScanRiskPathIncluded -Path $candidatePathLower -RiskPathRegex $threatScanRiskRegex)) {
                        $filteredByRiskPath++
                        & $addSkipEntry -Reason 'RiskPathFilter' -Path $candidate.FullName -Detail 'Candidate is outside ThreatScan risk-path filter.' -DetailPayload @{
                            phase = 'TargetEnumeration'
                            filter = 'ThreatScanRiskPath'
                            mode = $Mode
                        }
                        continue
                    }
                }
                if (Test-CstPathExcludedByPolicy -Path $candidatePathLower -ScanPolicy $policy) {
                    $filteredByExclusion++
                    & $addSkipEntry -Reason 'PathExclusion' -Path $candidate.FullName -Detail ("Excluded by pathExclusions tiers: {0}" -f (@($policy.exclusionTiersApplied) -join ',')) -DetailPayload @{
                        phase = 'TargetEnumeration'
                        tiers = (@($policy.exclusionTiersApplied) -join ',')
                        mode = $Mode
                    }
                    continue
                }

                $priorityBucket = 'low'
                if ($Mode -eq 'FullScan') {
                    $priorityBucket = & $getFullScanPriorityBucket -PathLower $candidatePathLower
                    $fullScanPriorityBucketCounts[$priorityBucket] = [int]$fullScanPriorityBucketCounts[$priorityBucket] + 1
                    if (-not $fullScanPrioritizationApplied) {
                        $fullScanPrioritizationApplied = $true
                    }
                }

                if ($enablePipelineScan) {
                    $deferForFullScanSort = ($Mode -eq 'FullScan' -and $priorityBucket -ne 'high')
                    if ($deferForFullScanSort) {
                        if (($scanned + $candidateFiles.Count) -lt $MaxFiles) {
                            $candidateFiles.Add($candidate)
                        }
                    } else {
                        if ([string]::IsNullOrWhiteSpace($fullScanFirstCandidatePath)) {
                            $fullScanFirstCandidatePath = [string]$candidate.FullName
                        }
                        . $analyzeCandidateFile $candidate
                        if ($scanned -ge $MaxFiles) {
                            $stopEnumeration = $true
                            break
                        }
                        if ($timeLimitSec -gt 0 -and (((Get-Date) - $scanStart).TotalSeconds -ge $timeLimitSec)) {
                            $timeBudgetExceeded = $true
                            $stopEnumeration = $true
                            break
                        }
                    }
                    if ($stopEnumeration) { break }
                    continue
                }

                $candidateFiles.Add($candidate)
                }
                if ($stopEnumeration) { break }
        } catch {
            $errors++
            if ($scanErrorDetails.Count -lt $maxScanErrorDetails) {
                [void]$scanErrorDetails.Add([PSCustomObject]@{
                    stage = 'TargetEnumeration'
                    target = [string]$walkRoot
                    path = ''
                    message = [string]$_.Exception.Message
                })
            }
        }
        if ($stopEnumeration) { break }
    }

    if ($candidateFiles.Count -gt 0) {
        $enumCompleteDetail = if ($enablePipelineScan) {
            ("Deferred sort pending ({0:N0} walked, {1:N0} scanned, {2:N0} queued)" -f $enumeratedCandidates, $scanned, $candidateFiles.Count)
        } else {
            ("Enumeration complete ({0:N0} candidates)" -f $enumeratedCandidates)
        }
        $enumCompletePhase = if ($enablePipelineScan) { 'Scanning' } else { 'Enumerating' }
        $enumCompleteScanned = if ($enablePipelineScan) { $scanned } else { $enumeratedCandidates }
        $enumCompleteOverall = Get-CstScanOverallPercent -Scanned $enumCompleteScanned -MaxFiles $MaxFiles
        Write-CstLiveProgress -Scanned $enumCompleteScanned -ProgressTotal $progressTotal -CurrentPath '' -ElapsedSec (((Get-Date) - $scanStart).TotalSeconds) -Phase $enumCompletePhase -PhasePercent 100.0 -OverallPercent $enumCompleteOverall -TargetIndex $enumTargetCount -TargetCount $enumTargetCount -EnumeratedCandidates $enumeratedCandidates -FilteredByRiskPath $filteredByRiskPath -FilteredByExclusion $filteredByExclusion -Detail $enumCompleteDetail
    }

    if ($Mode -eq 'FullScan' -and $candidateFiles.Count -gt 0) {
        $sequencedCandidates = New-Object System.Collections.Generic.List[object]
        $sequence = 0
        foreach ($candidate in $candidateFiles) {
            $bucketName = & $getFullScanPriorityBucket -PathLower ([string]$candidate.FullName.ToLowerInvariant())
            $bucketOrder = if ($bucketName -eq 'high') { 0 } elseif ($bucketName -eq 'medium') { 1 } else { 2 }
            [void]$sequencedCandidates.Add([PSCustomObject]@{
                bucketOrder = $bucketOrder
                sequence = $sequence
                file = $candidate
            })
            $sequence++
        }

        $sortedCandidates = @($sequencedCandidates | Sort-Object -Property bucketOrder, sequence)
        $candidateFiles = New-Object System.Collections.Generic.List[object]
        foreach ($entry in $sortedCandidates) {
            [void]$candidateFiles.Add($entry.file)
        }

        $fullScanPrioritizationApplied = $true
        if ([string]::IsNullOrWhiteSpace($fullScanFirstCandidatePath) -and $candidateFiles.Count -gt 0) {
            $fullScanFirstCandidatePath = [string]$candidateFiles[0].FullName
        }
    }

    $deferredRemaining = [math]::Max(0, [math]::Min($candidateFiles.Count, $MaxFiles - $scanned))
    $progressTotal = [math]::Max(1, $scanned + $deferredRemaining)

    foreach ($fileInfo in $candidateFiles) {
        if ($scanned -ge $MaxFiles) { break }
        if ($timeLimitSec -gt 0 -and (((Get-Date) - $scanStart).TotalSeconds -ge $timeLimitSec)) {
            $timeBudgetExceeded = $true
            break
        }
        . $analyzeCandidateFile $fileInfo
    }


    if ($onlineActive -and $onlinePending.Count -gt 0) {
        & $flushOnlineBatch
    }

    $coverage = 'Complete'
    $capCoverageReasons = New-Object System.Collections.Generic.List[string]
    $otherCoverageReasons = New-Object System.Collections.Generic.List[string]
    if ($scanned -ge $MaxFiles) {
        $coverage = 'Partial'
        [void]$capCoverageReasons.Add("Hit MaxFiles cap ($MaxFiles).")
    }
    if ($timeBudgetExceeded) {
        $coverage = 'Partial'
        [void]$capCoverageReasons.Add("Hit MaxMinutes cap ($effectiveMaxMinutes).")
    }
    if ($errors -gt 0) {
        $coverage = 'Partial'
        [void]$otherCoverageReasons.Add("Enumeration errors occurred on one or more scan roots ($errors).")
    }
    if ($IncludesDriveRootScan -and $scanned -lt 100 -and $scanned -lt $MaxFiles -and -not $timeBudgetExceeded) {
        $coverage = 'Partial'
        [void]$otherCoverageReasons.Add("Drive-root scan analyzed fewer than 100 files ($scanned); one or more roots may have failed or been skipped.")
    }
    $coverageReasons = New-Object System.Collections.Generic.List[string]
    foreach ($reason in @($capCoverageReasons)) { [void]$coverageReasons.Add($reason) }
    foreach ($reason in @($otherCoverageReasons)) { [void]$coverageReasons.Add($reason) }

    $skipReasonCategoryCounts = [ordered]@{}
    foreach ($entry in @($skipLog)) {
        $category = 'other'
        if ($entry.PSObject.Properties['reasonCategory'] -and -not [string]::IsNullOrWhiteSpace([string]$entry.reasonCategory)) {
            $category = [string]$entry.reasonCategory
        }
        if (-not $skipReasonCategoryCounts.Contains($category)) {
            $skipReasonCategoryCounts[$category] = 0
        }
        $skipReasonCategoryCounts[$category] = [int]$skipReasonCategoryCounts[$category] + 1
    }

    [PSCustomObject]@{
        findings = $findings
        scanned = $scanned
        scanErrors = $errors
        scanErrorDetails = @($scanErrorDetails)
        coverage = $coverage
        coverageReason = ($coverageReasons -join ' ')
        timeBudgetExceeded = $timeBudgetExceeded
        perFileBudgetSkips = $perFileBudgetSkips
        enumeratedCandidates = $enumeratedCandidates
        filteredByRiskPath = $filteredByRiskPath
        filteredByExclusion = $filteredByExclusion
        fullScanPrioritizationApplied = [bool]$fullScanPrioritizationApplied
        fullScanFirstCandidatePath = [string]$fullScanFirstCandidatePath
        fullScanPriorityBucketCounts = [PSCustomObject]$fullScanPriorityBucketCounts
        skipReasonCategoryCounts = [PSCustomObject]$skipReasonCategoryCounts
        onlineReputation = $onlineStatus
        slowFileThresholdMs = $slowFileThresholdMs
        slowFiles = @($slowFiles)
        slowFileCount = @($slowFiles).Count
        skipLog = @($skipLog)
        skipLogTruncated = ($skipLog.Count -ge $maxSkipLogEntries)
        knownGoodSkips = $knownGoodSkips
        trustedSignerSkips = $trustedSignerSkips
        dependencyTrustSkips = $dependencyTrustSkips
        contentScansPerformed = $contentScansPerformed
        knownGoodStorageMode = if ($null -ne $knownGoodStore) { [string]$knownGoodStore.storageMode } else { 'Disabled' }
        knownGoodMatchedProfiles = if ($null -ne $knownGoodStore) { @($knownGoodStore.matchedProfiles) } else { @() }
        onlineLookupsPerformed = $onlineLookupsPerformed
        onlineMaxLookupsPerScan = $onlineMaxLookupsPerScan
    }
    } finally {
        Dispose-CstKnownGoodStore
    }
}

function New-CstArtifact {
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Source,
        [string]$Path = '',
        [string]$TargetPath = '',
        [string]$CommandLine = '',
        [string]$Name = '',
        [string]$Location = '',
        [string]$State = 'Observed',
        [string]$ObjectType = 'Persistence',
        [string]$Evidence = '',
        [string]$EntityType = '',
        [int]$Pid = 0,
        [int]$ParentPid = 0,
        [int]$SessionId = -1,
        [string]$UserSid = '',
        [string]$IntegrityLevel = '',
        [string]$SignerStatus = 'Unknown',
        [string]$Publisher = '',
        [string]$Sha256 = '',
        [string]$SourceChannel = '',
        [string]$EvidenceKind = 'Observation',
        [string[]]$RiskTags = @(),
        [string]$ParentEntityId = '',
        [string]$EdgeType = '',
        [double]$CorrelationStrength = 0.0,
        [double]$ConfidenceDelta = 0.0,
        [string]$FirstSeenUtc = '',
        [string]$LastSeenUtc = ''
    )

    $identitySeed = "{0}|{1}|{2}|{3}" -f $Kind.ToLowerInvariant(), $Source.ToLowerInvariant(), $Path.ToLowerInvariant(), $CommandLine.ToLowerInvariant()
    $artifactId = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($identitySeed)).TrimEnd('=')
    $entityTypeValue = if ([string]::IsNullOrWhiteSpace($EntityType)) { $Kind } else { $EntityType }
    $entityId = if ($Kind -eq 'Process' -and $Pid -gt 0) {
        "process:$Pid"
    }
    elseif ($Kind -eq 'ProcessModule' -and $Pid -gt 0) {
        "processmodule:{0}:{1}" -f $Pid, $artifactId
    }
    else {
        "artifact:$artifactId"
    }
    if ([string]::IsNullOrWhiteSpace($FirstSeenUtc)) {
        $FirstSeenUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    if ([string]::IsNullOrWhiteSpace($LastSeenUtc)) {
        $LastSeenUtc = $FirstSeenUtc
    }

    return [PSCustomObject]@{
        artifactId = $artifactId
        entityId = $entityId
        entityType = $entityTypeValue
        kind = $Kind
        source = $Source
        name = $Name
        path = $Path
        targetPath = $TargetPath
        commandLine = $CommandLine
        location = $Location
        state = $State
        objectType = $ObjectType
        evidence = $Evidence
        pid = if ($Pid -gt 0) { $Pid } else { $null }
        parentPid = if ($ParentPid -gt 0) { $ParentPid } else { $null }
        sessionId = if ($SessionId -ge 0) { $SessionId } else { $null }
        userSid = $UserSid
        integrityLevel = $IntegrityLevel
        signerStatus = $SignerStatus
        publisher = $Publisher
        sha256 = $Sha256
        sourceChannel = $SourceChannel
        evidenceKind = $EvidenceKind
        riskTags = @($RiskTags)
        parentEntityId = $ParentEntityId
        edgeType = $EdgeType
        correlationStrength = $CorrelationStrength
        confidenceDelta = $ConfidenceDelta
        firstSeenUtc = $FirstSeenUtc
        lastSeenUtc = $LastSeenUtc
    }
}

function Import-CstBehaviorArtifacts {
    param(
        [string[]]$InputPath = @()
    )

    $imported = New-Object System.Collections.Generic.List[object]
    $seenImportedArtifactIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in @($InputPath)) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue)) { continue }

        try {
            $extension = [IO.Path]::GetExtension($path)
            $records = @()
            if ($extension -ieq '.jsonl') {
                $records = @(Get-Content -LiteralPath $path -ErrorAction Stop | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object {
                    $_ | ConvertFrom-Json -ErrorAction Stop
                })
            }
            else {
                $parsed = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                if ($parsed -is [System.Collections.IEnumerable] -and -not ($parsed -is [string])) {
                    $records = @($parsed)
                }
                elseif ($parsed.PSObject.Properties['artifacts']) {
                    $records = @($parsed.artifacts)
                }
                else {
                    $records = @($parsed)
                }
            }

            foreach ($record in @($records)) {
                if ($null -eq $record) { continue }
                $kind = if ($record.PSObject.Properties['kind']) { [string]$record.kind } else { '' }
                if ([string]::IsNullOrWhiteSpace($kind)) { continue }

                $riskTags = @()
                if ($record.PSObject.Properties['riskTags']) {
                    $riskTags = @($record.riskTags | ForEach-Object { [string]$_ })
                }

                $artifact = (New-CstArtifact `
                    -Kind $kind `
                    -Source $(if ($record.PSObject.Properties['source']) { [string]$record.source } else { 'BehaviorImport' }) `
                    -Path $(if ($record.PSObject.Properties['path']) { [string]$record.path } else { '' }) `
                    -TargetPath $(if ($record.PSObject.Properties['targetPath']) { [string]$record.targetPath } else { '' }) `
                    -CommandLine $(if ($record.PSObject.Properties['commandLine']) { [string]$record.commandLine } else { '' }) `
                    -Name $(if ($record.PSObject.Properties['name']) { [string]$record.name } else { '' }) `
                    -Location $(if ($record.PSObject.Properties['location']) { [string]$record.location } else { [string]$path }) `
                    -State $(if ($record.PSObject.Properties['state']) { [string]$record.state } else { 'Observed' }) `
                    -ObjectType $(if ($record.PSObject.Properties['objectType']) { [string]$record.objectType } else { 'Telemetry' }) `
                    -Evidence $(if ($record.PSObject.Properties['evidence']) { [string]$record.evidence } else { 'Imported behavior artifact.' }) `
                    -EntityType $(if ($record.PSObject.Properties['entityType']) { [string]$record.entityType } else { $kind }) `
                    -Pid $(if ($record.PSObject.Properties['pid']) { [int]$record.pid } else { 0 }) `
                    -ParentPid $(if ($record.PSObject.Properties['parentPid']) { [int]$record.parentPid } else { 0 }) `
                    -SessionId $(if ($record.PSObject.Properties['sessionId']) { [int]$record.sessionId } else { -1 }) `
                    -UserSid $(if ($record.PSObject.Properties['userSid']) { [string]$record.userSid } else { '' }) `
                    -IntegrityLevel $(if ($record.PSObject.Properties['integrityLevel']) { [string]$record.integrityLevel } else { '' }) `
                    -SignerStatus $(if ($record.PSObject.Properties['signerStatus']) { [string]$record.signerStatus } else { 'Unknown' }) `
                    -Publisher $(if ($record.PSObject.Properties['publisher']) { [string]$record.publisher } else { '' }) `
                    -Sha256 $(if ($record.PSObject.Properties['sha256']) { [string]$record.sha256 } else { '' }) `
                    -SourceChannel $(if ($record.PSObject.Properties['sourceChannel']) { [string]$record.sourceChannel } else { 'ImportedBehavior' }) `
                    -EvidenceKind $(if ($record.PSObject.Properties['evidenceKind']) { [string]$record.evidenceKind } else { 'ImportedTelemetry' }) `
                    -RiskTags $riskTags `
                    -ParentEntityId $(if ($record.PSObject.Properties['parentEntityId']) { [string]$record.parentEntityId } else { '' }) `
                    -EdgeType $(if ($record.PSObject.Properties['edgeType']) { [string]$record.edgeType } else { '' }) `
                    -CorrelationStrength $(if ($record.PSObject.Properties['correlationStrength']) { [double]$record.correlationStrength } else { 0.0 }) `
                    -ConfidenceDelta $(if ($record.PSObject.Properties['confidenceDelta']) { [double]$record.confidenceDelta } else { 0.0 }) `
                    -FirstSeenUtc $(if ($record.PSObject.Properties['firstSeenUtc']) { [string]$record.firstSeenUtc } else { '' }) `
                    -LastSeenUtc $(if ($record.PSObject.Properties['lastSeenUtc']) { [string]$record.lastSeenUtc } else { '' }))

                if ($null -eq $artifact) { continue }
                $artifactId = [string]$artifact.artifactId
                if ([string]::IsNullOrWhiteSpace($artifactId)) {
                    $artifactId = (([string]$artifact.kind).ToLowerInvariant() + '|' + ([string]$artifact.source).ToLowerInvariant() + '|' + ([string]$artifact.path).ToLowerInvariant() + '|' + ([string]$artifact.commandLine).ToLowerInvariant())
                }
                if ($seenImportedArtifactIds.Add($artifactId)) {
                    $imported.Add($artifact) | Out-Null
                }
            }
        }
        catch {
            Write-Warning ("Behavior artifact import failed for {0}: {1}" -f $path, $_.Exception.Message)
        }
    }

    return [object[]]$imported.ToArray()
}

function Get-CstSafeCommandLine {
    param([Parameter(Mandatory)]$Object)

    if ($Object.PSObject.Properties['CommandLine']) {
        return [string]$Object.CommandLine
    }
    return ''
}

function Get-CstPersistenceArtifacts {
    param([Parameter(Mandatory)][ValidateSet('Windows','WinPE')][string]$EnvironmentMode)

    $artifacts = New-Object System.Collections.Generic.List[object]

    # Live process and module correlation sources
    try {
        foreach ($proc in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
            if ($null -eq $proc) { continue }
            $procId = [int]$proc.ProcessId
            $parentPid = [int]$proc.ParentProcessId
            $exePath = [string]$proc.ExecutablePath
            $cmd = Get-CstSafeCommandLine -Object $proc
            $procObj = $null
            $sessionId = -1
            try {
                $procObj = Get-Process -Id $procId -ErrorAction SilentlyContinue
                if ($null -ne $procObj -and $procObj.PSObject.Properties['SessionId']) {
                    $sessionId = [int]$procObj.SessionId
                }
            } catch {}

            $artifacts.Add((New-CstArtifact -Kind 'Process' -Source 'LiveCollector' -Path $exePath -CommandLine $cmd -Name ([string]$proc.Name) -Location 'Win32_Process' -ObjectType 'Process' -Evidence 'Live process observed.' -EntityType 'Process' -Pid $procId -ParentPid $parentPid -SessionId $sessionId -SourceChannel 'Win32_Process' -EvidenceKind 'LiveTelemetry'))

            try {
                if ($null -ne $procObj -and $procObj.PSObject.Properties['Modules']) {
                    $moduleCount = 0
                    foreach ($module in @($procObj.Modules)) {
                        if ($null -eq $module) { continue }
                        $modulePath = [string]$module.FileName
                        if ([string]::IsNullOrWhiteSpace($modulePath)) { continue }
                        $artifacts.Add((New-CstArtifact -Kind 'ProcessModule' -Source 'LiveCollector' -Path $modulePath -TargetPath $exePath -CommandLine $cmd -Name ([string]$module.ModuleName) -Location ('PID ' + $procId) -ObjectType 'Process' -Evidence 'Loaded module observed in process.' -EntityType 'Module' -Pid $procId -ParentPid $parentPid -SessionId $sessionId -ParentEntityId ("process:$procId") -EdgeType 'loaded_module' -SourceChannel 'Win32_Process' -EvidenceKind 'LiveTelemetry'))
                        $moduleCount++
                        if ($moduleCount -ge 8) { break }
                    }
                }
            } catch {}
        }
    } catch {}

    # Services
    try {
        foreach ($svc in @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue)) {
            if ($null -eq $svc) { continue }
            $path = [string]$svc.PathName
            $artifacts.Add((New-CstArtifact -Kind 'Service' -Source 'ServiceControlManager' -Path $path -CommandLine $path -Name ([string]$svc.Name) -Location 'Win32_Service' -State ([string]$svc.State) -ObjectType 'Persistence' -Evidence 'Service image path observed.' -EntityType 'Service' -SourceChannel 'Win32_Service' -EvidenceKind 'LiveTelemetry'))
        }
    } catch {}

    # Scheduled tasks
    try {
        foreach ($task in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
            if ($null -eq $task) { continue }
            $taskName = [string]$task.TaskName
            $taskPath = [string]$task.TaskPath
            try {
                $info = Get-ScheduledTaskInfo -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
                $state = if ($null -ne $info) { [string]$info.State } else { 'Unknown' }
            } catch {
                $state = 'Unknown'
            }

            $actions = @()
            if ($task.PSObject.Properties['Actions']) {
                foreach ($action in @($task.Actions)) {
                    if ($null -eq $action) { continue }
                    $execute = if ($action.PSObject.Properties['Execute']) { [string]$action.Execute } else { '' }
                    $actionArgs = if ($action.PSObject.Properties['Arguments']) { [string]$action.Arguments } else { '' }
                    $actions += ("{0} {1}" -f $execute, $actionArgs).Trim()
                }
            }
            $cmd = ($actions -join ' || ')
            $artifacts.Add((New-CstArtifact -Kind 'ScheduledTask' -Source 'TaskScheduler' -Path $cmd -CommandLine $cmd -Name $taskName -Location ($taskPath + $taskName) -State $state -ObjectType 'Persistence' -Evidence 'Scheduled task action observed.' -EntityType 'ScheduledTask' -SourceChannel 'TaskScheduler' -EvidenceKind 'LiveTelemetry'))
        }
    } catch {}

    # Run/RunOnce keys
    $runKeyPaths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    )
    foreach ($regPath in $runKeyPaths) {
        try {
            if (-not (Test-Path $regPath)) { continue }
            $item = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
            if ($null -eq $item) { continue }
            foreach ($prop in $item.PSObject.Properties) {
                if ($prop.Name -in @('PSPath','PSParentPath','PSChildName','PSDrive','PSProvider')) { continue }
                $cmd = [string]$prop.Value
                if ([string]::IsNullOrWhiteSpace($cmd)) { continue }
                $artifacts.Add((New-CstArtifact -Kind 'RunKey' -Source 'Registry' -Path $cmd -CommandLine $cmd -Name ([string]$prop.Name) -Location $regPath -ObjectType 'Persistence' -Evidence 'Run/RunOnce registry entry observed.' -EntityType 'RegistryPersistence' -SourceChannel 'Registry' -EvidenceKind 'LiveTelemetry'))
            }
        } catch {}
    }

        # WMI event subscriptions (live Windows only — not available in WinPE)
        if ($EnvironmentMode -eq 'Windows') {
            try {
                foreach ($consumer in @(Get-CimInstance -Namespace 'root\subscription' -ClassName '__EventConsumer' -ErrorAction SilentlyContinue)) {
                    if ($null -eq $consumer) { continue }
                    $consumerName = [string]$consumer.Name
                    $cmdLine = ''
                    $path = ''
                    if ($consumer.PSObject.Properties['CommandLineTemplate']) {
                        $cmdLine = [string]$consumer.CommandLineTemplate
                        $path = $cmdLine
                    } elseif ($consumer.PSObject.Properties['ScriptText']) {
                        $cmdLine = [string]$consumer.ScriptText
                        $path = '(inline script)'
                    }
                    $artifacts.Add((New-CstArtifact -Kind 'WmiSubscription' -Source 'WmiEventConsumer' -Path $path -CommandLine $cmdLine -Name $consumerName -Location 'root\subscription:__EventConsumer' -ObjectType 'Persistence' -Evidence 'WMI event consumer subscription observed.' -EntityType 'WmiConsumer' -SourceChannel 'Microsoft-Windows-WMI-Activity' -EvidenceKind 'LiveTelemetry'))
                }
            } catch {}
            try {
                $benignFilters = @('SCM Event Log Filter')
                foreach ($filter in @(Get-CimInstance -Namespace 'root\subscription' -ClassName '__EventFilter' -ErrorAction SilentlyContinue)) {
                    if ($null -eq $filter) { continue }
                    $filterName = [string]$filter.Name
                    if ($filterName -in $benignFilters) { continue }
                    $query = if ($filter.PSObject.Properties['Query']) { [string]$filter.Query } else { '' }
                    $artifacts.Add((New-CstArtifact -Kind 'WmiFilter' -Source 'WmiEventFilter' -Path '' -CommandLine $query -Name $filterName -Location 'root\subscription:__EventFilter' -ObjectType 'Persistence' -Evidence 'WMI event filter subscription observed.' -EntityType 'WmiFilter' -SourceChannel 'Microsoft-Windows-WMI-Activity' -EvidenceKind 'LiveTelemetry'))
                }
            } catch {}
        }

    # Startup folders
    $startupPaths = @(
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup')
    )
    foreach ($userProfile in @(Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue)) {
        $startupPaths += (Join-Path $userProfile.FullName 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup')
    }
    foreach ($startup in ($startupPaths | Select-Object -Unique)) {
        try {
            if (-not (Test-Path $startup)) { continue }
            foreach ($item in @(Get-ChildItem -Path $startup -File -ErrorAction SilentlyContinue)) {
                $artifacts.Add((New-CstArtifact -Kind 'StartupFolder' -Source 'StartupFolder' -Path $item.FullName -TargetPath $item.FullName -Name $item.Name -Location $startup -ObjectType 'Persistence' -Evidence 'Startup folder item observed.' -EntityType 'StartupFolderItem' -SourceChannel 'FileSystem' -EvidenceKind 'LiveTelemetry'))
            }
        } catch {}
    }

    if ($EnvironmentMode -eq 'WinPE') {
        # Offline/WinPE collector pass: load from non-X volumes where an offline Windows install is present.
        foreach ($drive in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
            $root = "{0}:\" -f $drive.Name
            if ($root -eq 'X:\') { continue }
            $offlineWindows = Join-Path $root 'Windows\System32\config'
            if (-not (Test-Path $offlineWindows)) { continue }

            $offlineStartup = Join-Path $root 'ProgramData\Microsoft\Windows\Start Menu\Programs\Startup'
            try {
                if (Test-Path $offlineStartup) {
                    foreach ($item in @(Get-ChildItem -Path $offlineStartup -File -ErrorAction SilentlyContinue)) {
                        $artifacts.Add((New-CstArtifact -Kind 'OfflineStartupFolder' -Source 'OfflineStartup' -Path $item.FullName -TargetPath $item.FullName -Name $item.Name -Location $offlineStartup -ObjectType 'Persistence' -Evidence 'Offline startup item observed.' -EntityType 'OfflineStartupFolderItem' -SourceChannel 'OfflineFileSystem' -EvidenceKind 'OfflineArtifact'))
                    }
                }
            } catch {}

            $tasksRoot = Join-Path $root 'Windows\System32\Tasks'
            try {
                if (Test-Path $tasksRoot) {
                    foreach ($task in @(Get-ChildItem -Path $tasksRoot -File -Recurse -ErrorAction SilentlyContinue)) {
                        $artifacts.Add((New-CstArtifact -Kind 'OfflineScheduledTask' -Source 'OfflineTaskXml' -Path $task.FullName -TargetPath $task.FullName -Name $task.Name -Location $tasksRoot -ObjectType 'Persistence' -Evidence 'Offline scheduled task XML observed.' -EntityType 'OfflineScheduledTask' -SourceChannel 'OfflineTaskXml' -EvidenceKind 'OfflineArtifact'))
                    }
                }
            } catch {}

            $servicesHive = Join-Path $root 'Windows\System32\config\SYSTEM'
            if (Test-Path $servicesHive -ErrorAction SilentlyContinue) {
                $artifacts.Add((New-CstArtifact -Kind 'OfflineServiceRegistry' -Source 'OfflineRegistryHive' -Path $servicesHive -TargetPath $servicesHive -Name 'SYSTEM hive' -Location $servicesHive -ObjectType 'Persistence' -Evidence 'Offline SYSTEM hive available for service correlation.' -EntityType 'OfflineRegistryHive' -SourceChannel 'OfflineRegistryHive' -EvidenceKind 'OfflineArtifact'))

                try {
                    $mountName = 'HKLM\CSTOffline_' + $drive.Name
                    & reg.exe load $mountName $servicesHive | Out-Null

                    $servicesRoot = "Registry::HKEY_LOCAL_MACHINE\CSTOffline_$($drive.Name)\ControlSet001\Services"
                    if (-not (Test-Path $servicesRoot)) {
                        $servicesRoot = "Registry::HKEY_LOCAL_MACHINE\CSTOffline_$($drive.Name)\CurrentControlSet\Services"
                    }

                    if (Test-Path $servicesRoot) {
                        $count = 0
                        foreach ($svcKey in @(Get-ChildItem -Path $servicesRoot -ErrorAction SilentlyContinue)) {
                            if ($null -eq $svcKey) { continue }
                            $svcName = [string]$svcKey.PSChildName
                            $imagePath = ''
                            try {
                                $svcProps = Get-ItemProperty -Path $svcKey.PSPath -ErrorAction SilentlyContinue
                                if ($null -ne $svcProps -and $svcProps.PSObject.Properties['ImagePath']) {
                                    $imagePath = [string]$svcProps.ImagePath
                                }
                            } catch {}
                            $artifacts.Add((New-CstArtifact -Kind 'OfflineServiceEntry' -Source 'OfflineRegistryHive' -Path $imagePath -CommandLine $imagePath -Name $svcName -Location $servicesRoot -ObjectType 'Persistence' -Evidence 'Offline service registry entry observed.' -EntityType 'OfflineServiceEntry' -SourceChannel 'OfflineRegistryHive' -EvidenceKind 'OfflineArtifact'))
                            $count++
                            if ($count -ge 200) { break }
                        }
                    }
                } catch {} finally {
                    & reg.exe unload $mountName | Out-Null
                }
            }
        }
    }

    # Normalize and deduplicate by artifact identity
    $seen = @{}
    $normalized = New-Object System.Collections.Generic.List[object]
    foreach ($artifact in $artifacts) {
        $key = "{0}|{1}|{2}|{3}" -f ([string]$artifact.kind).ToLowerInvariant(), ([string]$artifact.source).ToLowerInvariant(), ([string]$artifact.path).ToLowerInvariant(), ([string]$artifact.commandLine).ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $normalized.Add($artifact)
    }

    return [object[]]$normalized.ToArray()
}

function Invoke-CstArtifactCorrelation {
    param(
        [AllowNull()]$Findings,
        [AllowEmptyCollection()][object[]]$Artifacts = @(),
        [Parameter(Mandatory)]$Rules
    )

    $normalizedFindings = ConvertTo-CstFindingArray -InputObject @($Findings)
    $correlated = New-Object System.Collections.Generic.List[object]

    $artifactRecords = New-Object System.Collections.Generic.List[object]
    $artifactsByExactToken = @{}
    $artifactsByLeafName = @{}
    $artifactsByEntityId = @{}
    $artifactsByParentEntityId = @{}
    $tryGetLeafName = {
        param([string]$value)

        if ([string]::IsNullOrWhiteSpace($value)) { return '' }
        try {
            return [string][System.IO.Path]::GetFileName($value)
        } catch {
            return ''
        }
    }

    foreach ($artifact in @($Artifacts)) {
        if ($null -eq $artifact) { continue }

        $pathValue = [string]$artifact.path
        $targetPathValue = [string]$artifact.targetPath
        $commandLineValue = [string]$artifact.commandLine
        $nameValue = [string]$artifact.name
        $resolvedCmdPath = Get-CstPathFromCommandLine -CommandLine $commandLineValue

        $haystack = (($pathValue + ' ' + $targetPathValue + ' ' + $commandLineValue + ' ' + $nameValue)).ToLowerInvariant()
        $record = [PSCustomObject]@{
            artifact = $artifact
            haystack = $haystack
        }
        $artifactRecords.Add($record)

        $entityIdValue = [string]$artifact.entityId
        if (-not [string]::IsNullOrWhiteSpace($entityIdValue)) {
            $entityKey = $entityIdValue.ToLowerInvariant()
            if (-not $artifactsByEntityId.ContainsKey($entityKey)) {
                $artifactsByEntityId[$entityKey] = New-Object System.Collections.Generic.List[object]
            }
            $artifactsByEntityId[$entityKey].Add($record)
        }

        $parentEntityIdValue = [string]$artifact.parentEntityId
        if (-not [string]::IsNullOrWhiteSpace($parentEntityIdValue)) {
            $parentEntityKey = $parentEntityIdValue.ToLowerInvariant()
            if (-not $artifactsByParentEntityId.ContainsKey($parentEntityKey)) {
                $artifactsByParentEntityId[$parentEntityKey] = New-Object System.Collections.Generic.List[object]
            }
            $artifactsByParentEntityId[$parentEntityKey].Add($record)
        }

        foreach ($tokenCandidate in @($pathValue, $targetPathValue, $nameValue, $resolvedCmdPath)) {
            if ([string]::IsNullOrWhiteSpace($tokenCandidate)) { continue }
            $tokenKey = [string]$tokenCandidate.ToLowerInvariant()
            if (-not $artifactsByExactToken.ContainsKey($tokenKey)) {
                $artifactsByExactToken[$tokenKey] = New-Object System.Collections.Generic.List[object]
            }
            $artifactsByExactToken[$tokenKey].Add($record)

            $leafName = & $tryGetLeafName $tokenCandidate
            if (-not [string]::IsNullOrWhiteSpace($leafName)) {
                $leafKey = [string]$leafName.ToLowerInvariant()
                if (-not $artifactsByLeafName.ContainsKey($leafKey)) {
                    $artifactsByLeafName[$leafKey] = New-Object System.Collections.Generic.List[object]
                }
                $artifactsByLeafName[$leafKey].Add($record)
            }
        }
    }

    $promotionEnabled = $true
    if ($Rules.correlationRules -and $Rules.correlationRules.PSObject.Properties['enabled']) {
        $promotionEnabled = [bool]$Rules.correlationRules.enabled
    }

    $requireExactPathForPromotion = $true
    if ($Rules.correlationRules -and $Rules.correlationRules.PSObject.Properties['requireExactPathForPromotion']) {
        $requireExactPathForPromotion = [bool]$Rules.correlationRules.requireExactPathForPromotion
    }

    $promoteMinDetectorWeight = 70
    if ($Rules.correlationRules -and $Rules.correlationRules.PSObject.Properties['promoteMinDetectorWeight']) {
        $promoteMinDetectorWeight = [int]$Rules.correlationRules.promoteMinDetectorWeight
    }

    foreach ($finding in $normalizedFindings) {
        $f = $finding.PSObject.Copy()
        Ensure-CstFindingContract -Finding $f | Out-Null

        $location = [string]$f.location
        $name = [string]$f.name
        $tokens = New-Object System.Collections.Generic.List[string]
        if (-not [string]::IsNullOrWhiteSpace($location)) { $tokens.Add($location.ToLowerInvariant()) }
        if (-not [string]::IsNullOrWhiteSpace($name)) { $tokens.Add($name.ToLowerInvariant()) }

        $hits = New-Object System.Collections.Generic.List[object]
        $seenHitKeys = @{}

        $addHitRecord = {
            param($record)

            if ($null -eq $record -or $null -eq $record.artifact) { return }
            $artifactObj = $record.artifact
            $hitKey = [string]$artifactObj.artifactId
            if ([string]::IsNullOrWhiteSpace($hitKey)) {
                $hitKey = (([string]$artifactObj.kind).ToLowerInvariant() + '|' + ([string]$artifactObj.source).ToLowerInvariant() + '|' + ([string]$artifactObj.path).ToLowerInvariant() + '|' + ([string]$artifactObj.commandLine).ToLowerInvariant())
            }
            if (-not $seenHitKeys.ContainsKey($hitKey)) {
                $seenHitKeys[$hitKey] = $true
                $hits.Add($artifactObj)
            }
        }

        foreach ($token in $tokens) {
            if ([string]::IsNullOrWhiteSpace($token)) { continue }

            if ($artifactsByExactToken.ContainsKey($token)) {
                foreach ($record in $artifactsByExactToken[$token]) {
                    & $addHitRecord $record
                }
            }

            $leafToken = & $tryGetLeafName $token
            if (-not [string]::IsNullOrWhiteSpace($leafToken)) {
                $leafKey = [string]$leafToken.ToLowerInvariant()
                if ($artifactsByLeafName.ContainsKey($leafKey)) {
                    foreach ($record in $artifactsByLeafName[$leafKey]) {
                        if ($record.haystack.Contains($token)) {
                            & $addHitRecord $record
                        }
                    }
                }
            }
        }

        if ($hits.Count -eq 0 -and $tokens.Count -gt 0 -and -not $requireExactPathForPromotion) {
            foreach ($record in $artifactRecords) {
                $isMatch = $false
                foreach ($token in $tokens) {
                    if ([string]::IsNullOrWhiteSpace($token)) { continue }
                    if ($record.haystack.Contains($token)) {
                        $isMatch = $true
                        break
                    }
                }
                if ($isMatch) {
                    & $addHitRecord $record
                }
            }
        }

        if ($hits.Count -gt 0) {
            $topHits = @($hits | Select-Object -First 3)
            $corrKey = (([string]$f.location).ToLowerInvariant() + '|' + ((@($topHits | ForEach-Object { $_.artifactId }) -join ','))).Trim('|')
            $corrId = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($corrKey)).TrimEnd('=')
            $f.correlationId = $corrId
            $f | Add-Member -NotePropertyName correlatedArtifacts -NotePropertyValue @($topHits) -Force

            $kinds = (@($topHits | ForEach-Object { [string]$_.kind } | Select-Object -Unique) -join ', ')
            $telemetryChannels = @($topHits | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.sourceChannel) } | ForEach-Object { [string]$_.sourceChannel } | Select-Object -Unique)
            $riskTags = @($topHits | Where-Object { $null -ne $_.riskTags } | ForEach-Object { @($_.riskTags) } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ } | Select-Object -Unique)
            $maxCorrelationStrength = 0.0
            $maxConfidenceDelta = 0.0
            $graphArtifacts = New-Object System.Collections.Generic.List[object]
            $graphSeen = @{}
            foreach ($hit in $topHits) {
                if ($hit.PSObject.Properties['correlationStrength']) {
                    $maxCorrelationStrength = [math]::Max($maxCorrelationStrength, [double]$hit.correlationStrength)
                }
                if ($hit.PSObject.Properties['confidenceDelta']) {
                    $maxConfidenceDelta = [math]::Max($maxConfidenceDelta, [double]$hit.confidenceDelta)
                }

                $hitEntityId = [string]$hit.entityId
                if (-not [string]::IsNullOrWhiteSpace($hitEntityId)) {
                    $entityKey = $hitEntityId.ToLowerInvariant()
                    if ($artifactsByParentEntityId.ContainsKey($entityKey)) {
                        foreach ($linkedRecord in $artifactsByParentEntityId[$entityKey]) {
                            $linkedArtifact = $linkedRecord.artifact
                            $linkedKey = [string]$linkedArtifact.artifactId
                            if ([string]::IsNullOrWhiteSpace($linkedKey)) { continue }
                            if ($seenHitKeys.ContainsKey($linkedKey) -or $graphSeen.ContainsKey($linkedKey)) { continue }
                            $graphSeen[$linkedKey] = $true
                            $graphArtifacts.Add($linkedArtifact)
                        }
                    }
                }

                $hitParentEntityId = [string]$hit.parentEntityId
                if (-not [string]::IsNullOrWhiteSpace($hitParentEntityId)) {
                    $parentKey = $hitParentEntityId.ToLowerInvariant()
                    if ($artifactsByEntityId.ContainsKey($parentKey)) {
                        foreach ($linkedRecord in $artifactsByEntityId[$parentKey]) {
                            $linkedArtifact = $linkedRecord.artifact
                            $linkedKey = [string]$linkedArtifact.artifactId
                            if ([string]::IsNullOrWhiteSpace($linkedKey)) { continue }
                            if ($seenHitKeys.ContainsKey($linkedKey) -or $graphSeen.ContainsKey($linkedKey)) { continue }
                            $graphSeen[$linkedKey] = $true
                            $graphArtifacts.Add($linkedArtifact)
                        }
                    }
                }
            }

            $graphSeedArtifacts = @($topHits | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.edgeType) -or -not [string]::IsNullOrWhiteSpace([string]$_.parentEntityId) })
            $graphContextArtifacts = New-Object System.Collections.Generic.List[object]
            foreach ($graphSeed in $graphSeedArtifacts) {
                $graphContextArtifacts.Add($graphSeed) | Out-Null
            }
            foreach ($graphArtifact in $graphArtifacts) {
                $graphContextArtifacts.Add($graphArtifact) | Out-Null
            }
            $graphEdgeTypes = @($graphContextArtifacts | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.edgeType) } | ForEach-Object { [string]$_.edgeType } | Select-Object -Unique)
            $graphRiskTags = @($graphArtifacts | Where-Object { $null -ne $_.riskTags } | ForEach-Object { @($_.riskTags) } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ } | Select-Object -Unique)
            if (@($graphRiskTags).Count -gt 0) {
                $riskTags = @($riskTags + $graphRiskTags | Select-Object -Unique)
            }

            $evidenceSegments = New-Object System.Collections.Generic.List[string]
            $evidenceSegments.Add(("Correlated artifacts: {0}." -f $kinds))
            if (@($telemetryChannels).Count -gt 0) {
                $evidenceSegments.Add(("Telemetry channels: {0}." -f (@($telemetryChannels) -join ', ')))
            }
            if (@($riskTags).Count -gt 0) {
                $evidenceSegments.Add(("Risk tags: {0}." -f (@($riskTags) -join ', ')))
            }
            if (@($graphEdgeTypes).Count -gt 0) {
                $evidenceSegments.Add(("Graph edges: {0}." -f (@($graphEdgeTypes) -join ', ')))
            }
            $f.evidence = ((@([string]$f.evidence) + @($evidenceSegments.ToArray())) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' '

            $baseBoost = 0.12
            $telemetryBoost = [math]::Min(0.25, ([math]::Max(0.0, $maxConfidenceDelta) + ([math]::Max(0.0, $maxCorrelationStrength) * 0.08)))
            $graphArtifactCount = [int]$graphArtifacts.Count
            $graphRelationCount = [int]$graphContextArtifacts.Count
            $graphEdgeCount = [int]$graphEdgeTypes.Count
            $graphBoost = [math]::Min(0.08, (($graphRelationCount * 0.04) + ($graphEdgeCount * 0.02)))
            $appliedBoost = 0.0

            $detectorWeight = Get-CstDetectorWeight -Detector ([string]$f.detector) -HasCorrelation $true
            if ($promotionEnabled -and $detectorWeight -ge $promoteMinDetectorWeight) {
                $appliedBoost = [math]::Round([math]::Min(0.43, ($baseBoost + $telemetryBoost + $graphBoost)), 2)
                $f.confidence = [math]::Round([math]::Min(1.0, ([double]$f.confidence + $appliedBoost)), 2)
                if ($f.type -eq 'Suspicious') { $f.type = 'PUM' }
            }

            $f | Add-Member -NotePropertyName behaviorCorrelationSummary -NotePropertyValue ([PSCustomObject]@{
                artifactCount = @($topHits).Count
                telemetryChannels = @($telemetryChannels)
                riskTags = @($riskTags)
                maxCorrelationStrength = [math]::Round($maxCorrelationStrength, 2)
                maxConfidenceDelta = [math]::Round($maxConfidenceDelta, 2)
                baseConfidenceBoost = $baseBoost
                appliedConfidenceBoost = $appliedBoost
            }) -Force
            $f | Add-Member -NotePropertyName graphCorrelationSummary -NotePropertyValue ([PSCustomObject]@{
                relatedArtifactCount = $graphArtifactCount
                relationCount = $graphRelationCount
                edgeTypes = @($graphEdgeTypes)
                graphBoost = [math]::Round($graphBoost, 2)
            }) -Force
        }

        $correlated.Add($f)
    }

    return [object[]]$correlated.ToArray()
}

function Find-CstConfigurationFindings {
    param([Parameter(Mandatory)]$Rules)

    $findings = New-Object System.Collections.Generic.List[object]

    $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    if (Test-Path $hostsPath) {
        try {
            $custom = Get-Content $hostsPath -ErrorAction Stop | Where-Object {
                $_ -match '\S' -and $_ -notmatch '^\s*#' -and $_ -notmatch '127\.0\.0\.1\s+localhost' -and $_ -notmatch '::1\s+localhost'
            }
            foreach ($line in $custom) {
                $lineLower = $line.ToLowerInvariant()
                $hit = Test-CstPatternMatch -Value $lineLower -Patterns @($Rules.patterns.hostsSuspicious)
                if ($hit) {
                    $findings.Add((New-CstFinding -Type 'PUM' -Severity 'Medium' -Name 'Suspicious hosts entry' -Location $hostsPath -Evidence "Hosts entry matched pattern: $hit" -Detector 'HostsInspector' -Confidence 0.7 -ObjectType 'Configuration' -CanRemediate $false))
                } else {
                    $findings.Add((New-CstFinding -Type 'PUM' -Severity 'Low' -Name 'Custom hosts entry' -Location $hostsPath -Evidence "Custom hosts line: $line" -Detector 'HostsInspector' -Confidence 0.35 -ObjectType 'Configuration' -CanRemediate $false))
                }
            }
        } catch {
            $findings.Add((New-CstFinding -Type 'Suspicious' -Severity 'Low' -Name 'Hosts check failed' -Location $hostsPath -Evidence $_.Exception.Message -Detector 'HostsInspector' -Confidence 0.2 -ObjectType 'Configuration' -CanRemediate $false))
        }
    }

    return $findings
}

function Find-CstBootTargetLocations {
    param(
        [Parameter(Mandatory)]$TargetResolution,
        [Parameter(Mandatory)]$Rules
    )

    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($root in @($TargetResolution.discoveredWindowsRoots, $TargetResolution.preferredRoot, $TargetResolution.offlineRoot)) {
        $candidate = [string]$root
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $normalized = $candidate.TrimEnd('\') + '\'
        if (-not ($roots.Contains($normalized))) {
            $roots.Add($normalized)
        }
    }

    $espRoots = New-Object System.Collections.Generic.List[string]
    foreach ($root in $roots) {
        $efiPath = Join-Path $root 'EFI'
        if (Test-Path $efiPath -ErrorAction SilentlyContinue) {
            $espRoots.Add($root)
        }
    }

    $requiredPaths = @($Rules.bootFilePolicies.requiredPaths)
    if ($requiredPaths.Count -eq 0) {
        $requiredPaths = @('EFI\\Microsoft\\Boot\\bootmgfw.efi', 'EFI\\Boot\\bootx64.efi')
    }

    $bootFileCandidates = New-Object System.Collections.Generic.List[string]
    foreach ($root in $roots) {
        foreach ($rel in $requiredPaths) {
            $fullPath = Join-Path $root ([string]$rel -replace '/', '\\')
            if (-not ($bootFileCandidates.Contains($fullPath))) {
                $bootFileCandidates.Add($fullPath)
            }
        }
    }

    $bcdCandidates = New-Object System.Collections.Generic.List[string]
    foreach ($root in $roots) {
        foreach ($rel in @('EFI\\Microsoft\\Boot\\BCD', 'Boot\\BCD')) {
            $fullPath = Join-Path $root $rel
            if ((Test-Path $fullPath -ErrorAction SilentlyContinue) -and -not ($bcdCandidates.Contains($fullPath))) {
                $bcdCandidates.Add($fullPath)
            }
        }
    }

    return [PSCustomObject]@{
        windowsRoots = @($roots)
        espRoots = @($espRoots)
        bootFileCandidates = @($bootFileCandidates)
        bcdStores = @($bcdCandidates)
    }
}

function Test-CstShouldCheckRequiredEfiBootPaths {
    param(
        [Parameter(Mandatory)]$BootTargets
    )

    # Required EFI paths (bootx64.efi, bootmgfw.efi) live on a mounted ESP or boot USB
    # ({root}\EFI), not on the offline Windows volume (C:\) during WinPE client scans.
    return (@($BootTargets.espRoots).Count -gt 0)
}

function ConvertFrom-CstBcdOutput {
    param(
        [Parameter(Mandatory)][string]$Text,
        [string]$StoreLabel = 'DefaultStore'
    )

    $objects = New-Object System.Collections.Generic.List[object]
    $pendingType = ''
    $current = [ordered]@{}

    function Add-CstBcdObject {
        param($Map, [string]$TypeLabel, [string]$Store)

        if ($null -eq $Map -or $Map.Count -eq 0) { return }

        $identifier = ''
        if ($Map.Contains('identifier')) {
            $identifier = [string]$Map['identifier']
        }

        $copy = [ordered]@{}
        foreach ($k in $Map.Keys) {
            $copy[$k] = [string]$Map[$k]
        }

        $objects.Add([PSCustomObject]@{
            store = $Store
            type = $TypeLabel
            identifier = $identifier
            properties = [PSCustomObject]$copy
        }) | Out-Null
    }

    foreach ($line in @($Text -split "`r?`n")) {
        $trim = [string]$line.Trim()
        if ([string]::IsNullOrWhiteSpace($trim)) { continue }
        if ($trim -match '^[-]{3,}$') { continue }

        $kv = [regex]::Match($line, '^\s*([^\s]+)\s{2,}(.+)$')
        if ($kv.Success) {
            $key = [string]$kv.Groups[1].Value.Trim().ToLowerInvariant()
            $value = [string]$kv.Groups[2].Value.Trim()

            if ($key -eq 'identifier' -and $current.Count -gt 0) {
                Add-CstBcdObject -Map $current -TypeLabel $pendingType -Store $StoreLabel
                $current = [ordered]@{}
            }

            $current[$key] = $value
            continue
        }

        # Section heading such as "Windows Boot Loader".
        $pendingType = $trim
    }

    if ($current.Count -gt 0) {
        Add-CstBcdObject -Map $current -TypeLabel $pendingType -Store $StoreLabel
    }

    return @($objects.ToArray())
}

function Test-CstBcdEnabledValue {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $normalized = $Value.Trim().ToLowerInvariant()
    return ($normalized -in @('yes', 'on', 'true', '1'))
}

function Invoke-CstMbrGptSectorInspection {
    param(
        [Parameter(Mandatory)][byte[]]$MbrSector,
        [Parameter(Mandatory)][byte[]]$GptHeaderSector,
        [Parameter(Mandatory)]$Rules,
        [Parameter(Mandatory)][bool]$EnableBootCodeHash,
        [string]$Location = '\\.\\PhysicalDrive0'
    )

    $findings = New-Object System.Collections.Generic.List[object]
    $warnings = 0
    $scannedSectors = 0

    if ($MbrSector.Length -ge 512) {
        $scannedSectors++
        $sigValid = ($MbrSector[510] -eq 0x55 -and $MbrSector[511] -eq 0xAA)
        if ([bool]$Rules.sectorPolicies.requireMbrSignature -and -not $sigValid) {
            $findings.Add((New-CstFinding -Type 'Suspicious' -Severity 'High' -Name 'Invalid MBR signature' -Location $Location -Evidence 'MBR signature bytes do not match 0x55AA.' -Detector 'MbrVbrInspector' -Confidence 0.9 -ObjectType 'BootSector' -CanRemediate $false))
            $warnings++
        }

        if ($EnableBootCodeHash) {
            $bootCode = New-Object byte[] 440
            [Array]::Copy($MbrSector, 0, $bootCode, 0, 440)
            $algo = [System.Security.Cryptography.SHA256]::Create()
            $hashBytes = $algo.ComputeHash($bootCode)
            $bootHash = ([BitConverter]::ToString($hashBytes)).Replace('-', '')
            $knownHashes = @($Rules.sectorPolicies.knownBootCodeHashes | ForEach-Object { [string]$_ })
            if ($knownHashes.Count -gt 0 -and -not ($knownHashes -contains $bootHash)) {
                $findings.Add((New-CstFinding -Type 'Suspicious' -Severity 'Medium' -Name 'Unknown boot code hash' -Location $Location -Evidence 'Boot code hash not present in allowlist baseline.' -Detector 'MbrVbrInspector' -Confidence 0.74 -ObjectType 'BootSector' -Hash $bootHash -CanRemediate $false))
                $warnings++
            }
        }
    }

    if ($GptHeaderSector.Length -ge 512) {
        $scannedSectors++
        $protectiveMbr = ($MbrSector.Length -ge 451 -and $MbrSector[450] -eq 0xEE)
        $gptSignatureBytes = [System.Text.Encoding]::ASCII.GetBytes('EFI PART')
        $gptSignatureValid = $true
        for ($i = 0; $i -lt $gptSignatureBytes.Length; $i++) {
            if ($GptHeaderSector[$i] -ne $gptSignatureBytes[$i]) {
                $gptSignatureValid = $false
                break
            }
        }

        if ([bool]$Rules.sectorPolicies.checkGptProtectiveMbr) {
            if ($gptSignatureValid -and -not $protectiveMbr) {
                $findings.Add((New-CstFinding -Type 'Suspicious' -Severity 'High' -Name 'GPT disk missing protective MBR' -Location $Location -Evidence 'GPT header signature found at LBA1 but MBR partition type 0xEE is not present.' -Detector 'GptStructureInspector' -Confidence 0.9 -ObjectType 'PartitionTable' -CanRemediate $false))
                $warnings++
            }

            if ($protectiveMbr -and -not $gptSignatureValid) {
                $findings.Add((New-CstFinding -Type 'Suspicious' -Severity 'High' -Name 'Protective MBR without GPT header' -Location $Location -Evidence 'MBR partition type 0xEE is present but GPT header signature is missing at LBA1.' -Detector 'GptStructureInspector' -Confidence 0.88 -ObjectType 'PartitionTable' -CanRemediate $false))
                $warnings++
            }
        }

        if ($gptSignatureValid) {
            $gptHeaderSize = [BitConverter]::ToUInt32($GptHeaderSector, 12)
            $gptReserved = [BitConverter]::ToUInt32($GptHeaderSector, 20)
            $gptCurrentLba = [BitConverter]::ToUInt64($GptHeaderSector, 24)
            $gptTableStartLba = [BitConverter]::ToUInt64($GptHeaderSector, 72)
            $gptTableEntryCount = [BitConverter]::ToUInt32($GptHeaderSector, 80)
            $gptTableEntrySize = [BitConverter]::ToUInt32($GptHeaderSector, 84)

            if ($gptHeaderSize -lt 92 -or $gptHeaderSize -gt 512) {
                $findings.Add((New-CstFinding -Type 'Suspicious' -Severity 'High' -Name 'Invalid GPT header size' -Location $Location -Evidence "GPT header size out of expected range (92-512): $gptHeaderSize." -Detector 'GptStructureInspector' -Confidence 0.9 -ObjectType 'PartitionTable' -CanRemediate $false))
                $warnings++
            }

            if ($gptReserved -ne 0) {
                $findings.Add((New-CstFinding -Type 'Suspicious' -Severity 'Medium' -Name 'GPT reserved header field not zero' -Location $Location -Evidence "GPT reserved header value is non-zero: $gptReserved." -Detector 'GptStructureInspector' -Confidence 0.76 -ObjectType 'PartitionTable' -CanRemediate $false))
                $warnings++
            }

            if ($gptCurrentLba -ne 1) {
                $findings.Add((New-CstFinding -Type 'Suspicious' -Severity 'Medium' -Name 'Unexpected GPT current LBA' -Location $Location -Evidence "GPT currentLBA is $gptCurrentLba; expected 1 for primary header." -Detector 'GptStructureInspector' -Confidence 0.78 -ObjectType 'PartitionTable' -CanRemediate $false))
                $warnings++
            }

            if ($gptTableStartLba -lt 2) {
                $findings.Add((New-CstFinding -Type 'Suspicious' -Severity 'High' -Name 'Invalid GPT table start LBA' -Location $Location -Evidence "GPT partition table starts at invalid LBA: $gptTableStartLba." -Detector 'GptStructureInspector' -Confidence 0.87 -ObjectType 'PartitionTable' -CanRemediate $false))
                $warnings++
            }

            if ($gptTableEntryCount -eq 0 -or $gptTableEntryCount -gt 4096) {
                $findings.Add((New-CstFinding -Type 'Suspicious' -Severity 'High' -Name 'Invalid GPT entry count' -Location $Location -Evidence "GPT partition entry count is outside expected range: $gptTableEntryCount." -Detector 'GptStructureInspector' -Confidence 0.86 -ObjectType 'PartitionTable' -CanRemediate $false))
                $warnings++
            }

            if ($gptTableEntrySize -lt 128 -or ($gptTableEntrySize % 8) -ne 0) {
                $findings.Add((New-CstFinding -Type 'Suspicious' -Severity 'High' -Name 'Invalid GPT entry size' -Location $Location -Evidence "GPT partition entry size is invalid: $gptTableEntrySize." -Detector 'GptStructureInspector' -Confidence 0.85 -ObjectType 'PartitionTable' -CanRemediate $false))
                $warnings++
            }
        }
    }

    return [PSCustomObject]@{
        findings = @($findings.ToArray())
        warningCount = $warnings
        scannedSectors = $scannedSectors
    }
}

function Get-CstBootHashProfileContext {
    param(
        [Parameter(Mandatory)][ValidateSet('Windows','WinPE')][string]$EnvironmentMode,
        [Parameter(Mandatory)]$TargetResolution
    )

    $ctx = [PSCustomObject]@{
        buildNumber = ''
        version = ''
        productName = ''
        source = 'Unknown'
    }

    if ($EnvironmentMode -ne 'Windows') {
        return $ctx
    }

    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        if ($null -ne $os) {
            $ctx.buildNumber = [string]$os.BuildNumber
            $ctx.version = [string]$os.Version
            $ctx.productName = [string]$os.Caption
            $ctx.source = 'Win32_OperatingSystem'
        }
    } catch {}

    return $ctx
}

function Resolve-CstBootHashAllowlist {
    param(
        [Parameter(Mandatory)]$Rules,
        [Parameter(Mandatory)]$Context
    )

    $hashes = New-Object System.Collections.Generic.List[string]
    $matchedProfiles = New-Object System.Collections.Generic.List[string]

    foreach ($entry in @($Rules.bootFilePolicies.hashAllowlist)) {
        if ($entry -is [string]) {
            $h = ([string]$entry).Trim().ToUpperInvariant()
            if (-not [string]::IsNullOrWhiteSpace($h) -and -not $hashes.Contains($h)) {
                $hashes.Add($h)
            }
        } elseif ($entry.PSObject.Properties['sha256']) {
            $h = ([string]$entry.sha256).Trim().ToUpperInvariant()
            if (-not [string]::IsNullOrWhiteSpace($h) -and -not $hashes.Contains($h)) {
                $hashes.Add($h)
            }
        }
    }

    foreach ($allowProfile in @($Rules.bootFilePolicies.hashAllowlistProfiles)) {
        if ($null -eq $allowProfile) { continue }

        $profileName = if ($allowProfile.PSObject.Properties['name']) { [string]$allowProfile.name } else { 'UnnamedProfile' }
        $buildRegex = if ($allowProfile.PSObject.Properties['osBuildRegex']) { [string]$allowProfile.osBuildRegex } else { '' }
        $productRegex = if ($allowProfile.PSObject.Properties['productRegex']) { [string]$allowProfile.productRegex } else { '' }

        $buildMatch = $true
        if (-not [string]::IsNullOrWhiteSpace($buildRegex)) {
            $buildMatch = ([string]$Context.buildNumber -match $buildRegex)
        }

        $productMatch = $true
        if (-not [string]::IsNullOrWhiteSpace($productRegex)) {
            $productMatch = ([string]$Context.productName -match $productRegex)
        }

        if (-not ($buildMatch -and $productMatch)) { continue }

        foreach ($hEntry in @($allowProfile.hashes)) {
            if ($hEntry -is [string]) {
                $h = ([string]$hEntry).Trim().ToUpperInvariant()
                if (-not [string]::IsNullOrWhiteSpace($h) -and -not $hashes.Contains($h)) {
                    $hashes.Add($h)
                }
            } elseif ($hEntry.PSObject.Properties['sha256']) {
                $h = ([string]$hEntry.sha256).Trim().ToUpperInvariant()
                if (-not [string]::IsNullOrWhiteSpace($h) -and -not $hashes.Contains($h)) {
                    $hashes.Add($h)
                }
            }
        }

        if (-not $matchedProfiles.Contains($profileName)) {
            $matchedProfiles.Add($profileName)
        }
    }

    return [PSCustomObject]@{
        hashes = @($hashes.ToArray())
        matchedProfiles = @($matchedProfiles.ToArray())
        context = $Context
    }
}

function Find-CstBootChainFindings {
    param(
        [Parameter(Mandatory)][ValidateSet('ThreatScan','FullScan','CustomScan')][string]$Mode,
        [Parameter(Mandatory)][ValidateSet('Windows','WinPE')][string]$EnvironmentMode,
        [Parameter(Mandatory)]$TargetResolution,
        [Parameter(Mandatory)]$Rules
    )

    $result = [PSCustomObject]@{
        findings = @()
        itemsScanned = 0
        warnings = 0
        errors = 0
        targetsResolved = @()
        filesMonitored = @()
    }

    if (-not [bool]$Rules.bootPolicies.enabled) {
        return $result
    }

    $findings = New-Object System.Collections.Generic.List[object]
    $signatureCache = @{}
    $targets = Find-CstBootTargetLocations -TargetResolution $TargetResolution -Rules $Rules
    $result.targetsResolved = @($targets.windowsRoots)

    $strictness = [string]$Rules.bootPolicies.strictnessProfile
    $applyBalancedToCustom = [bool]$Rules.bootPolicies.applyBalancedToCustomScan
    $customGuardEnabled = [bool]$Rules.bootPolicies.customScanGuardEnabled
    $fullBalanced = ($strictness -eq 'Balanced' -or $strictness -eq 'Strict')
    $customBalanced = ($Mode -eq 'CustomScan' -and ($applyBalancedToCustom -or -not $customGuardEnabled))

    $integrityMode = [string]$Rules.bootFilePolicies.integrityMode
    $allowedSigners = @($Rules.bootFilePolicies.allowedSigners | ForEach-Object { [string]$_ })
    $hashContext = Get-CstBootHashProfileContext -EnvironmentMode $EnvironmentMode -TargetResolution $TargetResolution
    $resolvedHashPolicy = Resolve-CstBootHashAllowlist -Rules $Rules -Context $hashContext
    $hashAllowlist = @($resolvedHashPolicy.hashes)
    $enforceHashAllowlist = [bool]$Rules.bootFilePolicies.enforceHashAllowlist
    $hashPolicyRequired = ($integrityMode -eq 'HashOnly') -or $enforceHashAllowlist
    $hashPolicyUnavailable = $false

    if ($hashPolicyRequired -and $hashAllowlist.Count -eq 0) {
        $hashPolicyUnavailable = $true
        $profileInfo = if (@($resolvedHashPolicy.matchedProfiles).Count -gt 0) { (@($resolvedHashPolicy.matchedProfiles) -join ', ') } else { 'none' }
        $ctx = $resolvedHashPolicy.context
        $findings.Add((New-CstFinding -Type 'Suspicious' -Severity 'Low' -Name 'EFI hash allowlist profile unresolved' -Location 'BootHashPolicy' -Evidence "Hash enforcement is enabled but no allowlist hashes matched current OS context. build=$($ctx.buildNumber); product=$($ctx.productName); matchedProfiles=$profileInfo" -Detector 'BootFileIntegrity' -Confidence 0.42 -ObjectType 'BootConfiguration' -CanRemediate $false))
        $result.warnings++
    }

    $bootIntegrityFailure = $false
    $bcdCriticalViolation = $false

    if ([bool]$Rules.bootFilePolicies.enabled) {
        # Only check required EFI paths when a scan root exposes \EFI (mounted ESP or boot USB).
        # WinPE offline FullScan/ThreatScan of C:\ alone must not warn — ESP files are on another volume.
        $shouldCheckRequiredPaths = Test-CstShouldCheckRequiredEfiBootPaths -BootTargets $targets

        if ($shouldCheckRequiredPaths) {
            $requiredPaths = @($Rules.bootFilePolicies.requiredPaths)
            foreach ($relPath in $requiredPaths) {
                $matched = @($targets.bootFileCandidates | Where-Object {
                    $_.ToLowerInvariant().EndsWith(([string]$relPath -replace '/', '\\').ToLowerInvariant())
                })
                $existing = @($matched | Where-Object { Test-Path $_ -ErrorAction SilentlyContinue })

                if ($existing.Count -eq 0) {
                    $f = New-CstFinding -Type 'Suspicious' -Severity 'Medium' -Name 'Missing EFI boot file' -Location ([string]$relPath) -Evidence "Required EFI path not found: $relPath" -Detector 'BootFileIntegrity' -Confidence 0.72 -ObjectType 'BootFile' -SignerStatus 'NotEvaluated' -CanRemediate $false
                    $findings.Add($f)
                    continue
                }

            foreach ($path in $existing) {
                $result.itemsScanned++
                if (-not ($result.filesMonitored -contains $path)) {
                    $result.filesMonitored += $path
                }

                $signerIssue = $false
                $hashIssue = $false

                if ($integrityMode -in @('SignerOnly','SignerPlusHash')) {
                    $sigInfo = Get-CstAuthenticodeInfo -Path $path -EnvironmentMode $EnvironmentMode -Cache $signatureCache
                    if ($sigInfo.available) {
                        $publisher = [string]$sigInfo.publisher
                        $publisherOk = $true
                        if ($allowedSigners.Count -gt 0) {
                            $publisherOk = $false
                            foreach ($allowed in $allowedSigners) {
                                if (-not [string]::IsNullOrWhiteSpace($allowed) -and $publisher.ToLowerInvariant().Contains($allowed.ToLowerInvariant())) {
                                    $publisherOk = $true
                                    break
                                }
                            }
                        }

                        if ($sigInfo.signerStatus -ne 'Valid' -or -not $publisherOk) {
                            $signerIssue = $true
                            $bootIntegrityFailure = $true
                            $findings.Add((New-CstFinding -Type 'Suspicious' -Severity 'High' -Name (Split-Path $path -Leaf) -Location $path -Evidence "EFI signer policy mismatch. status=$($sigInfo.signerStatus); publisher=$publisher" -Detector 'BootFileIntegrity' -Confidence 0.86 -ObjectType 'BootFile' -SignerStatus $sigInfo.signerStatus -Publisher $publisher -CanRemediate $false))
                        }
                    } elseif ($EnvironmentMode -eq 'Windows') {
                        $result.errors++
                        $findings.Add((New-CstFinding -Type 'Suspicious' -Severity 'Low' -Name (Split-Path $path -Leaf) -Location $path -Evidence "EFI signer inspection unavailable: $($sigInfo.statusMessage)" -Detector 'BootFileIntegrity' -Confidence 0.35 -ObjectType 'BootFile' -SignerStatus $sigInfo.signerStatus -CanRemediate $false))
                    }
                }

                if ($integrityMode -in @('HashOnly','SignerPlusHash')) {
                    $fileHash = Get-CstFileHashSafe -Path $path
                    $hashKnown = $false
                    if (-not [string]::IsNullOrWhiteSpace($fileHash)) {
                        $lookup = $fileHash.ToUpperInvariant()
                        foreach ($entry in $hashAllowlist) {
                            if ($entry -is [string]) {
                                if ($lookup -eq ([string]$entry).ToUpperInvariant()) { $hashKnown = $true; break }
                            }
                        }
                    }

                    $hashRequired = ($integrityMode -eq 'HashOnly') -or $enforceHashAllowlist
                    if ($hashRequired -and -not $hashPolicyUnavailable -and -not $hashKnown) {
                        $hashIssue = $true
                        $profileInfo = if (@($resolvedHashPolicy.matchedProfiles).Count -gt 0) { (@($resolvedHashPolicy.matchedProfiles) -join ', ') } else { 'legacy-hashAllowlist-only' }
                        $findings.Add((New-CstFinding -Type 'Suspicious' -Severity 'Medium' -Name (Split-Path $path -Leaf) -Location $path -Evidence "EFI hash not found in allowlist (profiles=$profileInfo)." -Detector 'BootFileIntegrity' -Confidence 0.73 -ObjectType 'BootFile' -Hash $fileHash -CanRemediate $false))
                    }
                }

                if ($signerIssue -or $hashIssue) {
                    $result.warnings++
                }
            }
            }
        }
    }

    if ([bool]$Rules.bcdPolicies.enabled) {
        $bcdOutput = ''
        $bcdObjects = New-Object System.Collections.Generic.List[object]
        try {
            if ($targets.bcdStores.Count -gt 0) {
                foreach ($store in $targets.bcdStores) {
                    $result.itemsScanned++
                    $storeOut = & bcdedit /store $store /enum all 2>&1 | Out-String
                    if (-not [string]::IsNullOrWhiteSpace($storeOut)) {
                        $bcdOutput += "`n[STORE:$store]`n$storeOut"
                        foreach ($obj in @(ConvertFrom-CstBcdOutput -Text $storeOut -StoreLabel $store)) {
                            $bcdObjects.Add($obj) | Out-Null
                        }
                    }
                }
            } else {
                $result.itemsScanned++
                $bcdOutput = (& bcdedit /enum all 2>&1 | Out-String)
                foreach ($obj in @(ConvertFrom-CstBcdOutput -Text $bcdOutput -StoreLabel 'DefaultStore')) {
                    $bcdObjects.Add($obj) | Out-Null
                }
            }
        } catch {
            $result.errors++
            $findings.Add((New-CstFinding -Type 'Suspicious' -Severity 'Low' -Name 'BCD inspection unavailable' -Location 'BCD' -Evidence $_.Exception.Message -Detector 'BcdInspector' -Confidence 0.3 -ObjectType 'BootConfiguration' -CanRemediate $false))
            $bcdOutput = ''
        }

        if ($bcdObjects.Count -gt 0) {
            foreach ($obj in @($bcdObjects.ToArray())) {
                $props = $obj.properties.PSObject.Properties
                $identifier = [string]$obj.identifier
                $storeLabel = [string]$obj.store

                foreach ($flag in @($Rules.bcdPolicies.forbiddenFlags)) {
                    $flagName = [string]$flag
                    if ([string]::IsNullOrWhiteSpace($flagName)) { continue }

                    $prop = $props | Where-Object { $_.Name -eq $flagName.ToLowerInvariant() } | Select-Object -First 1
                    if ($null -eq $prop) { continue }

                    if (Test-CstBcdEnabledValue -Value ([string]$prop.Value)) {
                        $bcdCriticalViolation = $true
                        $findings.Add((New-CstFinding -Type 'Suspicious' -Severity 'High' -Name 'Forbidden BCD flag enabled' -Location 'BCD' -Evidence "BCD flag enabled: $flagName (identifier=$identifier, store=$storeLabel)." -Detector 'BcdInspector' -Confidence 0.89 -ObjectType 'BootConfiguration' -CanRemediate $false))
                        $result.warnings++
                    }
                }

                foreach ($pathKey in @('path', 'device', 'osdevice')) {
                    $pathProp = $props | Where-Object { $_.Name -eq $pathKey } | Select-Object -First 1
                    if ($null -eq $pathProp) { continue }

                    $pathValue = [string]$pathProp.Value
                    if ([string]::IsNullOrWhiteSpace($pathValue)) { continue }
                    $pathValueLower = $pathValue.ToLowerInvariant()

                    foreach ($rx in @($Rules.bcdPolicies.suspiciousLoaderPathRegex)) {
                        $pattern = [string]$rx
                        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }

                        $patternLower = $pattern.ToLowerInvariant()
                        if ($pathValueLower.Contains($patternLower)) {
                            $findings.Add((New-CstFinding -Type 'Suspicious' -Severity 'Medium' -Name 'Suspicious BCD loader path' -Location 'BCD' -Evidence "BCD $pathKey matched suspicious pattern: $pattern (identifier=$identifier, store=$storeLabel)." -Detector 'BcdInspector' -Confidence 0.71 -ObjectType 'BootConfiguration' -CanRemediate $false))
                            $result.warnings++
                            break
                        }
                    }
                }
            }
        } elseif (-not [string]::IsNullOrWhiteSpace($bcdOutput)) {
            # Fallback for unexpected bcdedit output formats.
            foreach ($flag in @($Rules.bcdPolicies.forbiddenFlags)) {
                $flagName = [string]$flag
                if ([string]::IsNullOrWhiteSpace($flagName)) { continue }
                if ($bcdOutput -match ("(?im)^\\s*" + [regex]::Escape($flagName) + "\\s+Yes\\b")) {
                    $bcdCriticalViolation = $true
                    $findings.Add((New-CstFinding -Type 'Suspicious' -Severity 'High' -Name 'Forbidden BCD flag enabled' -Location 'BCD' -Evidence "BCD flag enabled: $flagName" -Detector 'BcdInspector' -Confidence 0.84 -ObjectType 'BootConfiguration' -CanRemediate $false))
                    $result.warnings++
                }
            }
        }
    }

    if ([bool]$Rules.sectorPolicies.enabled -and [bool]$Rules.bootPolicies.enableMbrVbrChecks) {
        try {
            $stream = [System.IO.File]::Open('\\.\\PhysicalDrive0', [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                $buffer = New-Object byte[] 512
                $read = $stream.Read($buffer, 0, 512)
                if ($read -eq 512) {
                    $gptHeaderBuffer = New-Object byte[] 512
                    $stream.Position = 512
                    [void]$stream.Read($gptHeaderBuffer, 0, 512)

                    $inspection = Invoke-CstMbrGptSectorInspection -MbrSector $buffer -GptHeaderSector $gptHeaderBuffer -Rules $Rules -EnableBootCodeHash ([bool]$Rules.bootPolicies.enableBootCodeHash) -Location '\\.\\PhysicalDrive0'
                    $result.itemsScanned += [int]$inspection.scannedSectors
                    foreach ($sectorFinding in @($inspection.findings)) {
                        $findings.Add($sectorFinding)
                    }
                    $result.warnings += [int]$inspection.warningCount
                }
            } finally {
                $stream.Dispose()
            }
        } catch {
            $result.errors++
            $findings.Add((New-CstFinding -Type 'Suspicious' -Severity 'Low' -Name 'Raw sector read unavailable' -Location '\\.\\PhysicalDrive0' -Evidence $_.Exception.Message -Detector 'MbrVbrInspector' -Confidence 0.25 -ObjectType 'BootSector' -CanRemediate $false))
        }
    }

    $allowCriticalFail = $false
    if ($Mode -eq 'FullScan' -and $fullBalanced) {
        $allowCriticalFail = $true
    } elseif ($Mode -eq 'CustomScan' -and $customBalanced) {
        $allowCriticalFail = $true
    }

    if ($bcdCriticalViolation -and $bootIntegrityFailure) {
        if ($allowCriticalFail) {
            $findings.Add((New-CstFinding -Type 'Malware' -Severity 'High' -Name 'Boot policy and EFI trust composite violation' -Location 'BootChain' -Evidence 'Detected forbidden BCD security flags together with EFI integrity/signer failures.' -Detector 'BcdInspector' -Confidence 0.95 -ObjectType 'BootConfiguration' -CanRemediate $false))
        } else {
            $findings.Add((New-CstFinding -Type 'Suspicious' -Severity 'High' -Name 'Boot policy and EFI trust composite violation' -Location 'BootChain' -Evidence 'Composite boot-chain issue detected under CustomScan guard mode.' -Detector 'BcdInspector' -Confidence 0.89 -ObjectType 'BootConfiguration' -CanRemediate $false))
            $result.warnings++
        }
    }

    $result.findings = @($findings.ToArray())
    return $result
}

function ConvertTo-CstFindingArray {
    param($InputObject)

    $normalized = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($InputObject)) {
        if ($null -eq $item) {
            continue
        }

        if ($item.PSObject.Properties['type']) {
            $normalized.Add((Ensure-CstFindingContract -Finding $item))
            continue
        }

        if ($item -is [System.Collections.IEnumerable] -and $item -isnot [string]) {
            foreach ($nestedItem in $item) {
                if ($null -ne $nestedItem -and $nestedItem.PSObject.Properties['type']) {
                    $normalized.Add((Ensure-CstFindingContract -Finding $nestedItem))
                }
            }
        }
    }

    return [object[]]$normalized.ToArray()
}

function Get-CstDetectorWeight {
    param([string]$Detector, [bool]$HasCorrelation)

    $base = switch ($Detector) {
        'HashIOC' { 100 }
        'BootFileIntegrity' { 90 }
        'BcdInspector' { 85 }
        'YaraLike' { 85 }
        'MbrVbrInspector' { 75 }
        'GptStructureInspector' { 75 }
        'PatternEngine' { 70 }
        'HeuristicEngine' { 45 }
        'SignerTrust' { 35 }
        'PathHeuristic' { 20 }
        default { 30 }
    }

    if ($HasCorrelation) {
        # Correlated process/persistence artifacts lift priority but stay below strong content rules.
        if ($base -lt 75) {
            $base += 20
        }
    }

    return $base
}

function Invoke-CstScoreAndDeduplicateFindings {
    param([AllowNull()]$Findings)

    $normalizedFindings = ConvertTo-CstFindingArray -InputObject @($Findings)
    if ((@($normalizedFindings).Count) -eq 0) {
        return @()
    }

    $groups = @{}
    foreach ($f in $normalizedFindings) {
        $hash = [string]$f.hash
        $location = [string]$f.location
        $groupKey = if (-not [string]::IsNullOrWhiteSpace($hash)) { "hash|$($hash.ToLowerInvariant())" } elseif (-not [string]::IsNullOrWhiteSpace($location)) { "path|$($location.ToLowerInvariant())" } else { "id|$([string]$f.id)" }
        if (-not $groups.ContainsKey($groupKey)) {
            $groups[$groupKey] = New-Object System.Collections.Generic.List[object]
        }
        $groups[$groupKey].Add($f)
    }

    $finalFindings = New-Object System.Collections.Generic.List[object]

    foreach ($group in $groups.Values) {
        $best = $null
        $bestScore = -1
        $detectors = @{}

        foreach ($candidate in $group) {
            $hasCorrelation = -not [string]::IsNullOrWhiteSpace([string]$candidate.correlationId)
            $score = Get-CstDetectorWeight -Detector ([string]$candidate.detector) -HasCorrelation $hasCorrelation
            $detectors[[string]$candidate.detector] = $true
            if ($score -gt $bestScore) {
                $best = $candidate.PSObject.Copy()
                $bestScore = $score
            }
        }

        $signalCount = $detectors.Keys.Count
        $scoreConfidence = [math]::Min(1.0, [math]::Round($bestScore / 100.0, 2))
        if ([double]$best.confidence -lt $scoreConfidence) {
            $best.confidence = $scoreConfidence
        }

        $best | Add-Member -NotePropertyName combinedScore -NotePropertyValue $bestScore -Force
        $best | Add-Member -NotePropertyName signalCount -NotePropertyValue $signalCount -Force
        $best | Add-Member -NotePropertyName contributingDetectors -NotePropertyValue @($detectors.Keys | Sort-Object) -Force

        if ($signalCount -le 1 -and [string]$best.detector -in @('PathHeuristic','SignerTrust') -and [double]$best.confidence -lt 0.7) {
            $best.type = 'Suspicious'
            $best.severity = 'Low'
        }

        if ($signalCount -gt 1) {
            $best.evidence = "{0} Signals: {1}." -f $best.evidence, (($best.contributingDetectors) -join ', ')
        }

        $finalFindings.Add($best)
    }

    return [object[]]$finalFindings.ToArray()
}

function Get-CstStatus {
    param(
        $Findings,
        [int]$ScanErrors = 0
    )

    $normalizedFindings = ConvertTo-CstFindingArray -InputObject $Findings

    $mal = @($normalizedFindings | Where-Object { $_.type -eq 'Malware' }).Count
    $warnish = @($normalizedFindings | Where-Object { $_.type -in @('PUP','PUM','Suspicious') }).Count

    if ($mal -gt 0) { return 'Fail' }
    if ($warnish -gt 0) { return 'Warn' }
    if ($ScanErrors -gt 0) { return 'Warn' }
    return 'Pass'
}

function Test-CstShouldExportSuppressedAuditFinding {
    param($Finding)

    if ($null -eq $Finding) { return $false }

    $detector = if ($Finding.PSObject.Properties['detector']) { [string]$Finding.detector } else { '' }
    $confidence = if ($Finding.PSObject.Properties['confidence']) { [double]$Finding.confidence } else { 0.0 }

    if ($detector -eq 'PathHeuristic' -and $confidence -lt 0.55) {
        return $false
    }

    return $true
}

function Get-CstFilteredFindings {
    param(
        [AllowNull()]$Findings,
        [Parameter(Mandatory)][ValidateSet('All','MalwareOnly','VirusOnly')][string]$DetectionScope
    )

    $normalizedFindings = ConvertTo-CstFindingArray -InputObject $Findings

    if ($DetectionScope -eq 'All') {
        return @($normalizedFindings)
    }

    if ($DetectionScope -eq 'MalwareOnly') {
        return @($normalizedFindings | Where-Object { $_.type -eq 'Malware' })
    }

    return @($normalizedFindings | Where-Object { $_.type -eq 'Malware' -and $_.objectType -eq 'Virus' })
}

function Invoke-CstScan {
    param(
        [ValidateSet('ThreatScan','FullScan','CustomScan')][string]$Mode = 'ThreatScan',
        [string[]]$Target = @(),
        [string[]]$BehaviorArtifactsPath = @(),
        [string]$RulesPath,
        [int]$MaxMinutes = 15,
        [ValidateSet('All','MalwareOnly','VirusOnly')][string]$DetectionScope = 'All',
        [ValidateSet('ScanOnly','ScanAndRemove','ScanAndQuarantine')][string]$ActionMode = 'ScanOnly',
        [bool]$EnablePersistenceCollectors = $true,
        [switch]$OfflineOnly
    )

    $start = Get-Date
    $envMode = Get-CstEnvironmentMode

    Write-CstLiveProgress -Scanned 0 -ProgressTotal 1 -CurrentPath '' -ElapsedSec 0 -Phase 'TargetPrep' -PhasePercent 5.0 -OverallPercent 1.0 -Detail 'Initializing Core Security Tool scan...'

    if ([string]::IsNullOrWhiteSpace($RulesPath)) {
        $RulesPath = Join-Path $PSScriptRoot 'rules\rules.json'
    }

    $rules = Get-CstRuleSet -RulesPath $RulesPath
    $rulesLoadWarnings = New-Object System.Collections.Generic.List[string]
    if ($rules.PSObject.Properties['__cstFallbackReason'] -and -not [string]::IsNullOrWhiteSpace([string]$rules.__cstFallbackReason)) {
        [void]$rulesLoadWarnings.Add([string]$rules.__cstFallbackReason)
    }
    $rulesLoadWarningCount = @($rulesLoadWarnings).Count
    Write-CstLiveProgress -Scanned 0 -ProgressTotal 1 -CurrentPath '' -ElapsedSec (((Get-Date) - $start).TotalSeconds) -Phase 'TargetPrep' -PhasePercent 35.0 -OverallPercent 4.0 -Detail 'Rules loaded. Resolving scan targets...'
    $targetResolution = Resolve-CstTargets -Mode $Mode -Target $Target
    $targets = @($targetResolution.existingTargets)
    Write-CstLiveProgress -Scanned 0 -ProgressTotal 1 -CurrentPath '' -ElapsedSec (((Get-Date) - $start).TotalSeconds) -Phase 'TargetPrep' -PhasePercent 70.0 -OverallPercent 7.0 -TargetIndex @($targets).Count -TargetCount @($targets).Count -Detail ("Resolved {0} target(s). Building scan policy..." -f @($targets).Count)

    $policy = Get-CstScanPolicy -Mode $Mode -Rules $rules -EnvironmentMode $envMode
    $maxFiles = [int]$policy.maxFiles
    Write-CstLiveProgress -Scanned 0 -ProgressTotal 1 -CurrentPath '' -ElapsedSec (((Get-Date) - $start).TotalSeconds) -Phase 'TargetPrep' -PhasePercent 100.0 -OverallPercent 10.0 -TargetIndex 0 -TargetCount @($targets).Count -Detail 'Target preparation complete. Starting scan walk...'

    $effectiveMaxMinutes = if ($Mode -eq 'ThreatScan' -and $MaxMinutes -gt 0) { [int]$MaxMinutes } else { 0 }
    $scanData = $null
    if ($targets.Count -eq 0) {
        $onlinePolicy = $policy.onlineReputation
        $onlineSkippedInEnvironment = ([bool]$onlinePolicy.skipInWinPE -and $envMode -eq 'WinPE')
        $scanData = [PSCustomObject]@{
            findings = @()
            scanned = 0
            scanErrors = $rulesLoadWarningCount
            scanErrorDetails = @($rulesLoadWarnings | ForEach-Object {
                [PSCustomObject]@{
                    stage = 'RulesLoad'
                    message = [string]$_
                }
            })
            coverage = 'NoTargets'
            coverageReason = [string]$targetResolution.noTargetReason
            timeBudgetExceeded = $false
            perFileBudgetSkips = 0
            enumeratedCandidates = 0
            filteredByRiskPath = 0
            filteredByExclusion = 0
            fullScanPrioritizationApplied = $false
            fullScanFirstCandidatePath = ''
            fullScanPriorityBucketCounts = [PSCustomObject]@{ high = 0; medium = 0; low = 0 }
            skipReasonCategoryCounts = [PSCustomObject]@{}
            onlineReputation = (Get-CstOnlineReputationStatus -Enabled ([bool]$onlinePolicy.enabled) -Provider ([string]$onlinePolicy.provider) -Endpoint ([string]$onlinePolicy.endpoint) -BatchSize ([int]$onlinePolicy.batchSize) -TimeoutSeconds ([int]$onlinePolicy.timeoutSeconds) -MinTrustScore ([int]$onlinePolicy.minTrustScore) -ModeEnabled ([bool]$onlinePolicy.modeEnabled) -SkippedInEnvironment $onlineSkippedInEnvironment -OfflineOnly $OfflineOnly)
            skipLog = @()
            skipLogTruncated = $false
            noEligibleTargets = $true
        }
    } else {
        $scanData = Find-CstFileFindings -Mode $Mode -EnvironmentMode $envMode -Targets $targets -Rules $rules -RulesPath $RulesPath -MaxFiles $maxFiles -MaxMinutes $effectiveMaxMinutes -OfflineOnly $OfflineOnly -IncludesDriveRootScan ([bool]$targetResolution.includesDriveRootScan)
        if (-not $scanData.PSObject.Properties['noEligibleTargets']) {
            $scanData | Add-Member -NotePropertyName noEligibleTargets -NotePropertyValue $false -Force
        }
        if ($rulesLoadWarningCount -gt 0) {
            $existingScanErrorDetails = @()
            if ($scanData.PSObject.Properties['scanErrorDetails']) {
                $existingScanErrorDetails = @($scanData.scanErrorDetails)
            }
            $existingScanErrorDetails += @($rulesLoadWarnings | ForEach-Object {
                [PSCustomObject]@{
                    stage = 'RulesLoad'
                    message = [string]$_
                }
            })
            $scanData | Add-Member -NotePropertyName scanErrorDetails -NotePropertyValue @($existingScanErrorDetails) -Force

            $existingScanErrors = 0
            if ($scanData.PSObject.Properties['scanErrors']) {
                $existingScanErrors = [int]$scanData.scanErrors
            }
            $scanData | Add-Member -NotePropertyName scanErrors -NotePropertyValue ($existingScanErrors + $rulesLoadWarningCount) -Force
        }
    }

    $postScanScanned = [int]$scanData.scanned
    $postScanOverall = Get-CstScanOverallPercent -Scanned $postScanScanned -MaxFiles $maxFiles -MaximumPercent 95.0
    Write-CstLiveProgress -Scanned $postScanScanned -ProgressTotal $maxFiles -CurrentPath '' -ElapsedSec (((Get-Date) - $start).TotalSeconds) -Phase 'Scanning' -PhasePercent 95.0 -OverallPercent $postScanOverall -Detail 'File scan complete. Running boot and configuration checks...'

    $configFindings = Find-CstConfigurationFindings -Rules $rules
    $bootData = [PSCustomObject]@{
        findings = @()
        itemsScanned = 0
        warnings = 0
        errors = 0
        targetsResolved = @()
        filesMonitored = @()
    }
    if ($Mode -in @('FullScan', 'CustomScan')) {
        Write-CstLiveProgress -Scanned $postScanScanned -ProgressTotal $maxFiles -CurrentPath '' -ElapsedSec (((Get-Date) - $start).TotalSeconds) -Phase 'Scanning' -PhasePercent 96.0 -OverallPercent 96.0 -Detail 'Running boot chain checks...'
        $bootData = Find-CstBootChainFindings -Mode $Mode -EnvironmentMode $envMode -TargetResolution $targetResolution -Rules $rules
    }

    $findings = @(ConvertTo-CstFindingArray -InputObject @($scanData.findings, $configFindings, $bootData.findings))

    $collectPersistence = $EnablePersistenceCollectors
    if ($Mode -ne 'CustomScan') {
        $collectPersistence = $true
    }

    $artifacts = @()
    if ($collectPersistence) {
        Write-CstLiveProgress -Scanned $postScanScanned -ProgressTotal $maxFiles -CurrentPath '' -ElapsedSec (((Get-Date) - $start).TotalSeconds) -Phase 'Scanning' -PhasePercent 97.0 -OverallPercent 97.0 -Detail 'Collecting persistence artifacts...'
        $artifacts = @(Get-CstPersistenceArtifacts -EnvironmentMode $envMode)
    }
    if (@($BehaviorArtifactsPath).Count -gt 0) {
        Write-CstLiveProgress -Scanned $postScanScanned -ProgressTotal $maxFiles -CurrentPath '' -ElapsedSec (((Get-Date) - $start).TotalSeconds) -Phase 'Scanning' -PhasePercent 97.5 -OverallPercent 97.5 -Detail 'Importing behavior artifacts...'
        $artifacts += @(Import-CstBehaviorArtifacts -InputPath $BehaviorArtifactsPath)
    }
    Write-CstLiveProgress -Scanned $postScanScanned -ProgressTotal $maxFiles -CurrentPath '' -ElapsedSec (((Get-Date) - $start).TotalSeconds) -Phase 'Scanning' -PhasePercent 98.0 -OverallPercent 98.0 -Detail 'Correlating findings...'
    $findings = @(Invoke-CstArtifactCorrelation -Findings @($findings) -Artifacts $artifacts -Rules $rules)
    $findings = @(Invoke-CstScoreAndDeduplicateFindings -Findings $findings)

    $allFindings = @($findings)
    $findings = @(Get-CstFilteredFindings -Findings $allFindings -DetectionScope $DetectionScope)

    # Suppress weak, single-signal warning-class findings to reduce false-positive noise.
    $confidenceFilterMin = 0.55
    $confidenceFilteredFindings = @($findings | Where-Object {
        ($_.type -in @('PUP', 'PUM', 'Suspicious')) -and
        ([double]$_.confidence -lt $confidenceFilterMin) -and
        ([int]$_.signalCount -le 1) -and
        ([string]$_.detector -in @('PathHeuristic', 'SignerTrust', 'HeuristicEngine'))
    })
    if ($confidenceFilteredFindings.Count -gt 0) {
        $suppressedIds = @($confidenceFilteredFindings | ForEach-Object { [string]$_.id })
        $findings = @($findings | Where-Object { $suppressedIds -notcontains [string]$_.id })
    }
    $suppressedAuditFindings = @($allFindings | Where-Object {
            -not ($findings.id -contains $_.id) -and (Test-CstShouldExportSuppressedAuditFinding -Finding $_)
        })

    $selectedAction = if ($ActionMode -eq 'ScanAndRemove') { 'Remove' } elseif ($ActionMode -eq 'ScanAndQuarantine') { 'Quarantine' } else { 'ScanOnly' }
    foreach ($finding in $findings) {
        Ensure-CstFindingContract -Finding $finding -DefaultSelectedAction $selectedAction -DefaultActionState $(if ($ActionMode -eq 'ScanOnly') { 'NotRequested' } else { 'Pending' }) | Out-Null
        if ($ActionMode -ne 'ScanOnly' -and [string]::IsNullOrWhiteSpace([string]$finding.selectedAction)) {
            $finding.selectedAction = $selectedAction
        }
        if ($ActionMode -eq 'ScanOnly') {
            $finding.selectedAction = 'ScanOnly'
            $finding.actionState = 'NotRequested'
        }
    }

    $remediation = $null
    if ($ActionMode -eq 'ScanAndRemove') {
        $remediation = Invoke-CstRemediation -Findings $findings -Action 'Remove'
        $findings = @($remediation.processedFindings)
    } elseif ($ActionMode -eq 'ScanAndQuarantine') {
        $remediation = Invoke-CstRemediation -Findings $findings -Action 'Quarantine'
        $findings = @($remediation.processedFindings)
    }

    $status = Get-CstStatus -Findings $findings -ScanErrors ([int]$scanData.scanErrors)

    if ([string]$scanData.coverage -eq 'Partial' -and $status -eq 'Pass') {
        $status = 'Warn'
    }

    Write-CstLiveProgress -Scanned $postScanScanned -ProgressTotal $maxFiles -CurrentPath '' -ElapsedSec (((Get-Date) - $start).TotalSeconds) -Phase 'Completed' -PhasePercent 100.0 -OverallPercent 100.0 -Detail 'Finalizing scan report...'

    $malCount = @($findings | Where-Object { $_.type -eq 'Malware' }).Count
    $warnCount = @($findings | Where-Object { $_.type -in @('PUP','PUM','Suspicious') }).Count

    $coverageReason = $scanData.coverageReason

    if ($scanData.timeBudgetExceeded -and $status -eq 'Pass') {
        $status = 'Warn'
    }

    if ($scanData.noEligibleTargets -and $status -eq 'Pass') {
        $status = 'Warn'
    }

    $exitCode = switch ($status) {
        'Pass' { 0 }
        'Warn' { 1 }
        'Fail' { 2 }
        default { 3 }
    }

    return [PSCustomObject]@{
        status = $status
        exitCode = $exitCode
        scanMode = $Mode
        environmentMode = $envMode
        scanConfiguration = [PSCustomObject]@{
            mode = $Mode
            maxMinutes = if ($effectiveMaxMinutes -gt 0) { [int]$effectiveMaxMinutes } else { $null }
            maxFiles = $maxFiles
            detectionScope = $DetectionScope
            requestedActionMode = $ActionMode
            effectiveActionMode = if ($ActionMode -eq 'ScanAndRemove') { 'Remove' } elseif ($ActionMode -eq 'ScanAndQuarantine') { 'Quarantine' } else { 'ScanOnly' }
            persistenceCollectorsEnabled = $collectPersistence
            riskPathFilterEnabled = [bool]$policy.riskPathFilterEnabled
            riskPathRegex = [string]$policy.threatScanRiskRegex
            signerTrustEnabled = [bool]$policy.enableSignerTrust
            archiveInspectionEnabled = [bool]$policy.archiveInspectionEnabled
            archiveExtensions = @($policy.archiveExtensions)
            archiveMaxFileSizeMb = [int]$policy.archiveMaxFileSizeMb
            maxArchiveEntryCount = [int]$policy.maxArchiveEntryCount
            maxArchiveEntrySizeMb = [int]$policy.maxArchiveEntrySizeMb
            maxPerFileAnalysisMs = [int]$policy.maxPerFileAnalysisMs
            maxSignatureVerificationMs = [int]$policy.maxSignatureVerificationMs
            maxSignatureVerificationMsBase = [int]$policy.maxSignatureVerificationMsBase
            signatureTimeoutAdaptiveEnabled = [bool]$policy.signatureTimeoutAdaptiveProfile.enabled
            signatureTimeoutAdaptiveProfile = $policy.signatureTimeoutAdaptiveProfile
            hashGateMb = [int]$policy.hashGateMb
            filePatterns = @($policy.filePatterns)
            hashEligibleExtensions = @($policy.hashEligibleExtensions)
            onlineReputationEnabled = [bool]$policy.onlineReputation.enabled
            onlineReputationProvider = [string]$policy.onlineReputation.provider
            onlineReputationEndpoint = [string]$policy.onlineReputation.endpoint
            onlineReputationModeEnabled = [bool]$policy.onlineReputation.modeEnabled
            onlineReputationBatchSize = [int]$policy.onlineReputation.batchSize
            onlineReputationTimeoutSeconds = [int]$policy.onlineReputation.timeoutSeconds
            onlineReputationMinTrustScore = [int]$policy.onlineReputation.minTrustScore
            onlineReputationSkipInWinPE = [bool]$policy.onlineReputation.skipInWinPE
            confidenceFilterMin = $confidenceFilterMin
            bootChecksEnabled = [bool]$rules.bootPolicies.enabled
            bootChecksMode = [string]$rules.bootPolicies.strictnessProfile
            bootTargetsResolved = @($bootData.targetsResolved)
            bootFilesMonitored = @($bootData.filesMonitored)
            resolvedScanRoot = [string]$targetResolution.preferredRoot
            offlineRoot = [string]$targetResolution.offlineRoot
            discoveredWindowsRoots = @($targetResolution.discoveredWindowsRoots)
            targetCountBeforeExistenceFilter = @($targetResolution.rawTargets).Count
            targetCountAfterExistenceFilter = @($targets).Count
            requestedTargets = @($targetResolution.rawTargets)
            missingTargets = @($targetResolution.missingTargets)
            targets = @($targets)
            behaviorArtifactsPath = @($BehaviorArtifactsPath)
            rulesLoadWarnings = @($rulesLoadWarnings)
            helperIntegrity = [PSCustomObject]@{
                trusted = [bool]$script:CstKnownGoodHelperTrusted
                status = [string]$script:CstKnownGoodHelperStatus
                message = [string]$script:CstKnownGoodHelperMessage
            }
        }
        summary = [PSCustomObject]@{
            itemsScanned = $scanData.scanned
            threatsFound = $malCount
            warningsFound = $warnCount
            scanErrors = $scanData.scanErrors
            noEligibleTargets = [bool]$scanData.noEligibleTargets
            perFileBudgetSkips = $scanData.perFileBudgetSkips
            enumeratedCandidates = $scanData.enumeratedCandidates
            filteredByRiskPath = $scanData.filteredByRiskPath
            filteredByExclusion = $scanData.filteredByExclusion
            fullScanPrioritizationApplied = [bool]$scanData.fullScanPrioritizationApplied
            fullScanFirstCandidatePath = [string]$scanData.fullScanFirstCandidatePath
            fullScanPriorityBucketCounts = $scanData.fullScanPriorityBucketCounts
            skipReasonCategoryCounts = $scanData.skipReasonCategoryCounts
            suppressedByFilter = @($suppressedAuditFindings).Count
            onlineReputationRequestsAttempted = [int]$scanData.onlineReputation.requestsAttempted
            onlineReputationRequestsSucceeded = [int]$scanData.onlineReputation.requestsSucceeded
            onlineReputationRequestsFailed = [int]$scanData.onlineReputation.requestsFailed
            onlineReputationRequestTimeouts = [int]$scanData.onlineReputation.requestTimeouts
            onlineReputationEligibleFiles = [int]$scanData.onlineReputation.eligibleFiles
            onlineReputationKnownGoodHits = [int]$scanData.onlineReputation.knownGoodHits
            onlineReputationSuppressedFindings = [int]$scanData.onlineReputation.suppressedFindings
            knownGoodSkips = if ($scanData.PSObject.Properties['knownGoodSkips']) { [int]$scanData.knownGoodSkips } else { 0 }
            trustedSignerSkips = if ($scanData.PSObject.Properties['trustedSignerSkips']) { [int]$scanData.trustedSignerSkips } else { 0 }
            contentScansPerformed = if ($scanData.PSObject.Properties['contentScansPerformed']) { [int]$scanData.contentScansPerformed } else { [int]$scanData.scanned }
            knownGoodStorageMode = if ($scanData.PSObject.Properties['knownGoodStorageMode']) { [string]$scanData.knownGoodStorageMode } else { 'Unknown' }
            onlineLookupsPerformed = if ($scanData.PSObject.Properties['onlineLookupsPerformed']) { [int]$scanData.onlineLookupsPerformed } else { 0 }
            confidenceSuppressedFindings = @($confidenceFilteredFindings).Count
            importedBehaviorArtifacts = @($artifacts | Where-Object { $_.evidenceKind -eq 'ImportedTelemetry' }).Count
            bootItemsScanned = [int]$bootData.itemsScanned
            bootWarnings = [int]$bootData.warnings
            bootErrors = [int]$bootData.errors
            skipLogEntries = @($scanData.skipLog).Count
            skipLogTruncated = [bool]$scanData.skipLogTruncated
            rulesLoadWarnings = $rulesLoadWarningCount
        }
        onlineReputation = $scanData.onlineReputation
        scanErrorDetails = @($scanData.scanErrorDetails)
        skipLog = @($scanData.skipLog)
        skipLogTruncated = [bool]$scanData.skipLogTruncated
        coverage = $scanData.coverage
        coverageReason = $coverageReason
        findings = @($findings)
        suppressedAuditFindings = @($suppressedAuditFindings)
        artifacts = @($artifacts)
        behaviorEvidence = [PSCustomObject]@{
            entityCount = @($artifacts).Count
            entityTypes = @($artifacts | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.entityType) } | Group-Object -Property entityType | Sort-Object Name | ForEach-Object {
                [PSCustomObject]@{
                    entityType = $_.Name
                    count = $_.Count
                }
            })
            telemetrySources = @($artifacts | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.sourceChannel) } | Group-Object -Property sourceChannel | Sort-Object Name | ForEach-Object {
                [PSCustomObject]@{
                    sourceChannel = $_.Name
                    count = $_.Count
                }
            })
            evidenceKinds = @($artifacts | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.evidenceKind) } | Group-Object -Property evidenceKind | Sort-Object Name | ForEach-Object {
                [PSCustomObject]@{
                    evidenceKind = $_.Name
                    count = $_.Count
                }
            })
            correlationCoverage = [PSCustomObject]@{
                findingsWithCorrelation = @($findings | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.correlationId) }).Count
                findingsWithoutCorrelation = @($findings | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.correlationId) }).Count
            }
        }
        artifactSummary = [PSCustomObject]@{
            totalArtifacts = @($artifacts).Count
            processArtifacts = @($artifacts | Where-Object { $_.kind -eq 'Process' }).Count
            processModuleArtifacts = @($artifacts | Where-Object { $_.kind -eq 'ProcessModule' }).Count
            persistenceArtifacts = @($artifacts | Where-Object { $_.objectType -eq 'Persistence' }).Count
            offlineArtifacts = @($artifacts | Where-Object { $_.evidenceKind -eq 'OfflineArtifact' }).Count
            importedBehaviorArtifacts = @($artifacts | Where-Object { $_.evidenceKind -eq 'ImportedTelemetry' }).Count
            correlationHits = @($findings | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.correlationId) }).Count
        }
        detectorCounts = [PSCustomObject]@{
            hashIOC = @($findings | Where-Object { $_.detector -eq 'HashIOC' }).Count
            yaraLike = @($findings | Where-Object { $_.detector -eq 'YaraLike' }).Count
            signerTrust = @($findings | Where-Object { $_.detector -eq 'SignerTrust' }).Count
            heuristicEngine = @($findings | Where-Object { $_.detector -eq 'HeuristicEngine' }).Count
            archiveInspector = @($findings | Where-Object { $_.detector -eq 'ArchiveInspector' }).Count
            bootFileIntegrity = @($findings | Where-Object { $_.detector -eq 'BootFileIntegrity' }).Count
            bcdInspector = @($findings | Where-Object { $_.detector -eq 'BcdInspector' }).Count
            mbrVbrInspector = @($findings | Where-Object { $_.detector -eq 'MbrVbrInspector' }).Count
            gptStructureInspector = @($findings | Where-Object { $_.detector -eq 'GptStructureInspector' }).Count
            patternEngine = @($findings | Where-Object { $_.detector -eq 'PatternEngine' }).Count
            hostsInspector = @($findings | Where-Object { $_.detector -eq 'HostsInspector' }).Count
            pathHeuristic = @($findings | Where-Object { $_.detector -eq 'PathHeuristic' }).Count
            onlineReputation = [int]$scanData.onlineReputation.knownGoodHits
        }
        selectedFilters = [PSCustomObject]@{
            detectionScope = $DetectionScope
            requestedActionMode = $ActionMode
            persistenceCollectorsEnabled = $collectPersistence
        }
        selectedActionCounts = [PSCustomObject]@{
            scanOnly = @($findings | Where-Object { $_.selectedAction -eq 'ScanOnly' }).Count
            remove = @($findings | Where-Object { $_.selectedAction -eq 'Remove' }).Count
            quarantine = @($findings | Where-Object { $_.selectedAction -eq 'Quarantine' }).Count
            notRequested = @($findings | Where-Object { $_.actionState -eq 'NotRequested' }).Count
            pending = @($findings | Where-Object { $_.actionState -eq 'Pending' }).Count
            completed = @($findings | Where-Object { $_.actionState -eq 'Completed' }).Count
            skipped = @($findings | Where-Object { $_.actionState -eq 'Skipped' }).Count
            failed = @($findings | Where-Object { $_.actionState -eq 'Failed' }).Count
        }
        topCorrelatedFindings = @($findings | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.correlationId) } | Sort-Object -Property confidence -Descending | Select-Object -First 5 | ForEach-Object {
            [PSCustomObject]@{
                id = $_.id
                name = $_.name
                type = $_.type
                detector = $_.detector
                confidence = $_.confidence
                correlationId = $_.correlationId
                location = $_.location
            }
        })
        remediation = $remediation
        rulesVersion = [string]$rules.rulesVersion
        offlineOnly = [bool]$OfflineOnly
        actionSummary = if ($ActionMode -eq 'ScanOnly') {
            'Scan completed in detect-only mode.'
        } elseif ($null -ne $remediation) {
            "Remediation executed ($($remediation.action)): success=$($remediation.succeeded), failed=$($remediation.failed), skipped=$($remediation.skipped). Rollback manifest: $($remediation.rollbackManifestPath)"
        } else {
            "Requested $ActionMode, but remediation did not run. Findings were collected without making changes."
        }
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
    }
}

Export-ModuleMember -Function Get-CstEnvironmentMode, Invoke-CstScan, Invoke-CstRemediation, Invoke-CstRollback
