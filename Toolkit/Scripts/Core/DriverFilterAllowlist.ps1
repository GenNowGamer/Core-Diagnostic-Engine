#Requires -Version 5.1
<#
.SYNOPSIS
  Shared driver/minifilter allowlist for System Health Driver Signature Audit.
  Prefer CST rules.json driverFilterPolicies.allowlistedFilterNames (single source of truth).
#>

function Get-CdeToolkitRootForFilters {
    if (-not [string]::IsNullOrWhiteSpace($env:TOOLKIT_ROOT) -and (Test-Path -LiteralPath $env:TOOLKIT_ROOT)) {
        return $env:TOOLKIT_ROOT.TrimEnd('\', '/')
    }
    if ($PSScriptRoot) {
        return (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
    }
    return $null
}

function Get-CdeDefaultDriverFilterAllowlistNames {
    <#
    .SYNOPSIS
      Fallback stock Windows + Malwarebytes filter names (matches CST driverFilterPolicies).
    #>
    return @(
        'WdFilter', 'luafv', 'npsvctrig', 'FileInfo', 'Wof', 'storqosflt', 'wcifs',
        'FileCrypt', 'bindflt', 'CldFlt', 'PrjFlt', 'bfs', 'gameflt', 'UCPD',
        'UnionFS', 'EhStorClass', 'fvevol', 'partmgr', 'volsnap', 'iorate', 'rdyboost',
        'applockerfltr', 'mbamchameleon', 'MBAMFarflt', 'MBAMProtection'
    )
}

function Get-CdeDriverFilterAllowlistNames {
    <#
    .SYNOPSIS
      Load allowlisted filter names from CST rules.json when present; else defaults.
    #>
    param(
        [string]$RulesPath
    )

    $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($n in @(Get-CdeDefaultDriverFilterAllowlistNames)) {
        if (-not [string]::IsNullOrWhiteSpace($n)) { [void]$names.Add($n.Trim()) }
    }

    if ([string]::IsNullOrWhiteSpace($RulesPath)) {
        $root = Get-CdeToolkitRootForFilters
        if ($root) {
            $RulesPath = Join-Path $root 'Security\CST\rules\rules.json'
        }
    }

    if ($RulesPath -and (Test-Path -LiteralPath $RulesPath)) {
        try {
            $json = Get-Content -LiteralPath $RulesPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $fromRules = @($json.driverFilterPolicies.allowlistedFilterNames)
            foreach ($n in $fromRules) {
                if (-not [string]::IsNullOrWhiteSpace([string]$n)) { [void]$names.Add(([string]$n).Trim()) }
            }
        } catch {
            # Keep defaults if rules.json cannot be parsed.
        }
    }

    return @($names | Sort-Object)
}

function Test-CdeDriverFilterAllowlisted {
    param(
        [Parameter(Mandatory)][string]$FilterName,
        [string[]]$Allowlist
    )
    if (-not $Allowlist) { $Allowlist = @(Get-CdeDriverFilterAllowlistNames) }
    foreach ($a in $Allowlist) {
        if ($FilterName -ieq $a) { return $true }
    }
    return $false
}

function Resolve-CdeDriverFilterBinaryPath {
    <#
    .SYNOPSIS
      Resolve a driver/minifilter service name to its normalized on-disk .sys path via Services\ImagePath.
    #>
    param(
        [Parameter(Mandatory)][string]$FilterName
    )

    $result = [PSCustomObject]@{
        FilterName   = $FilterName
        RawImagePath = ''
        ResolvedPath = ''
        Exists       = $false
    }

    $svcKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$FilterName"
    if (-not (Test-Path -LiteralPath $svcKey -ErrorAction SilentlyContinue)) {
        return $result
    }

    try {
        $props = Get-ItemProperty -LiteralPath $svcKey -ErrorAction Stop
        $raw = [string]$props.ImagePath
    } catch {
        return $result
    }

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $result
    }

    $result.RawImagePath = $raw
    $p = $raw.Trim().Trim('"')
    $p = $p -replace '^\\\?\?\\', ''
    $p = $p -replace '^\\SystemRoot\\', "$env:SystemRoot\"
    $p = [Environment]::ExpandEnvironmentVariables($p)
    if ($p -match '^(?i)system32\\') {
        $p = Join-Path $env:SystemRoot $p
    }

    $result.ResolvedPath = $p
    if (Test-Path -LiteralPath $p -PathType Leaf -ErrorAction SilentlyContinue) {
        try {
            $result.ResolvedPath = (Get-Item -LiteralPath $p -ErrorAction Stop).FullName
        } catch { }
        $result.Exists = $true
    }

    return $result
}

function Test-CdeDriverFilterMicrosoftSigned {
    <#
    .SYNOPSIS
      Return $true if a driver/minifilter resolves on disk and carries a valid Microsoft Authenticode signature.
    #>
    param(
        [Parameter(Mandatory)][string]$FilterName,
        [string]$ResolvedPath,
        [bool]$TargetExists,
        [bool]$IsValidSignature,
        [string]$SignerSubject
    )

    $useInjected = $PSBoundParameters.ContainsKey('ResolvedPath') `
        -or $PSBoundParameters.ContainsKey('TargetExists') `
        -or $PSBoundParameters.ContainsKey('IsValidSignature') `
        -or $PSBoundParameters.ContainsKey('SignerSubject')

    $path = ''
    $exists = $false
    $valid = $false
    $subject = ''

    if ($useInjected) {
        $path = if ($PSBoundParameters.ContainsKey('ResolvedPath')) { [string]$ResolvedPath } else { '' }
        $exists = if ($PSBoundParameters.ContainsKey('TargetExists')) { $TargetExists } else { $false }
        $valid = if ($PSBoundParameters.ContainsKey('IsValidSignature')) { $IsValidSignature } else { $false }
        $subject = if ($PSBoundParameters.ContainsKey('SignerSubject')) { [string]$SignerSubject } else { '' }
    } else {
        $resolved = Resolve-CdeDriverFilterBinaryPath -FilterName $FilterName
        $path = $resolved.ResolvedPath
        $exists = $resolved.Exists
        if ($exists -and -not [string]::IsNullOrWhiteSpace($path)) {
            if (Get-Command -Name Get-FileSignatureInfo -ErrorAction SilentlyContinue) {
                try {
                    $sigInfo = Get-FileSignatureInfo -FilePath $path
                    $valid = [bool]$sigInfo.IsSigned
                    $subject = if (-not [string]::IsNullOrWhiteSpace([string]$sigInfo.SignedBy)) {
                        [string]$sigInfo.SignedBy
                    } else {
                        [string]$sigInfo.SignedDisplay
                    }
                } catch { }
            }
            if (-not $valid) {
                try {
                    $sig = Get-AuthenticodeSignature -LiteralPath $path -ErrorAction Stop
                    $valid = ($sig.Status -eq 'Valid')
                    if ($sig.SignerCertificate) {
                        $subject = [string]$sig.SignerCertificate.Subject
                    }
                } catch { }
            }
        }
    }

    $isMicrosoft = $exists -and $valid -and ($subject -match '(?i)(O=Microsoft Corporation|CN=Microsoft Windows|CN=Microsoft Corporation)')
    return [PSCustomObject]@{
        IsMicrosoftSigned = [bool]$isMicrosoft
        ResolvedPath      = $path
        Exists            = [bool]$exists
        IsValidSignature  = [bool]$valid
        SignerSubject     = $subject
    }
}
