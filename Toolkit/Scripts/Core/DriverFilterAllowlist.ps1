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
