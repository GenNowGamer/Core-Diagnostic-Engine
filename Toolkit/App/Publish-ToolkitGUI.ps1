<#
.SYNOPSIS
    Build ToolkitGUI (WPF app payload) and publish the canonical launcher to Toolkit\CDE.exe only.

.NOTES
    User-facing entry point: Toolkit\CDE.exe (single launcher exe at toolkit root).
    ToolkitGUI.exe is a runtime dependency under CDE\ToolkitGUI\bin\Release\net8.0-windows\
    and is NOT copied to any other launcher path. Do not publish a second CDE.exe under CDE\.
#>
param(
    [switch]$Clean,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$appDir = Split-Path $MyInvocation.MyCommand.Path -Parent
$toolkitRoot = [System.IO.Path]::GetFullPath((Join-Path $appDir '..'))
$version = '1.0.14'
$versionPath = Join-Path $toolkitRoot 'VERSION.json'
if (Test-Path -LiteralPath $versionPath) {
    $versionDoc = Get-Content -LiteralPath $versionPath -Raw | ConvertFrom-Json
    if (-not [string]::IsNullOrWhiteSpace([string]$versionDoc.version)) {
        $version = [string]$versionDoc.version
    }
    if (-not [string]::IsNullOrWhiteSpace($version)) {
        $globalIni = Join-Path $toolkitRoot 'Config\global.ini'
        if (Test-Path -LiteralPath $globalIni) {
            $ini = Get-Content -LiteralPath $globalIni -Raw
            $ini = $ini -replace '(?m)^Version=[^\r\n]*', "Version=$version"
            $ini = $ini -replace '(?m)^BuildDate=[^\r\n]*', "BuildDate=$(Get-Date -Format 'yyyy-MM-dd')"
            $ini = ($ini -replace "(`r?`n)+$", "`r`n")
            [System.IO.File]::WriteAllText($globalIni, $ini, (New-Object System.Text.UTF8Encoding($false)))
            Write-Host ("Synced global.ini version to {0}" -f $version) -ForegroundColor Cyan
        }

        $settingsPath = Join-Path $toolkitRoot 'Config\settings.json'
        if (Test-Path -LiteralPath $settingsPath) {
            $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
            $settings.ToolkitVersion = $version
            $settings | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $settingsPath -Encoding UTF8
        }
    }
}

$projectPath = Join-Path $PSScriptRoot 'ToolkitGUI\ToolkitGUI.csproj'
$publishDir = Join-Path $PSScriptRoot 'ToolkitGUI\bin\Release\net8.0-windows'
$expectedGuiPayload = Join-Path $publishDir 'ToolkitGUI.exe'
$launcherProjectPath = Join-Path $PSScriptRoot 'CDELauncher\CDELauncher.csproj'
$launcherPublishDir = Join-Path $PSScriptRoot 'CDELauncher\bin\Release\net8.0-windows'
$launcherBuildExe = Join-Path $launcherPublishDir 'CDE.exe'
$toolkitRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$canonicalLauncherExe = Join-Path $toolkitRoot 'CDE.exe'
$canonicalLauncherExe = [System.IO.Path]::GetFullPath($canonicalLauncherExe)
$legacyRootBat = Join-Path $toolkitRoot 'CDE_Portable.bat'
$fallbackLauncherDir = Join-Path $toolkitRoot 'Scripts\Launch'
$fallbackLauncherBat = Join-Path $fallbackLauncherDir 'CDE_Portable.bat'

if (-not (Test-Path -LiteralPath $projectPath)) {
    throw "ToolkitGUI project not found: $projectPath"
}

if (-not (Test-Path -LiteralPath $launcherProjectPath)) {
    throw "CDE launcher project not found: $launcherProjectPath"
}

if ($Clean) {
    dotnet clean $projectPath -c Release | Out-Host
    dotnet clean $launcherProjectPath -c Release | Out-Host
    foreach ($cliProj in @(
        (Join-Path $PSScriptRoot 'CdeCpuSimdCli\CdeCpuSimdCli.csproj'),
        (Join-Path $PSScriptRoot 'CdeGpuDiagCli\CdeGpuDiagCli.csproj'),
        (Join-Path $PSScriptRoot 'CdeBehaviorCollector\CdeBehaviorCollector.csproj')
    )) {
        if (Test-Path -LiteralPath $cliProj) {
            dotnet clean $cliProj -c Release | Out-Host
        }
    }
}

$beforeWrite = $null
$beforeLength = $null
if (Test-Path -LiteralPath $expectedGuiPayload) {
    $beforeExe = Get-Item -LiteralPath $expectedGuiPayload
    $beforeWrite = $beforeExe.LastWriteTimeUtc
    $beforeLength = $beforeExe.Length
}

$publishArgs = @(
    'publish',
    $projectPath,
    '-c', 'Release',
    '-r', 'win-x64',
    '--self-contained', 'true',
    '-o', $publishDir,
    "-p:Version=$version",
    '-p:AppendTargetFrameworkToOutputPath=false',
    '-p:AppendRuntimeIdentifierToOutputPath=false'
)

if ($Force) {
    $publishArgs += '--force'
}

dotnet @publishArgs | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed with exit code $LASTEXITCODE"
}

if (-not (Test-Path -LiteralPath $expectedGuiPayload)) {
    throw "Publish completed but expected GUI payload was not found at: $expectedGuiPayload"
}

$actualGuiPayload = Get-Item -LiteralPath $expectedGuiPayload
if ($null -ne $beforeWrite -and $actualGuiPayload.LastWriteTimeUtc -le $beforeWrite) {
    if ($null -ne $beforeLength -and $actualGuiPayload.Length -eq $beforeLength) {
        Write-Warning "GUI payload unchanged from previous run (timestamp not advanced): $expectedGuiPayload"
    }
    else {
        Write-Warning "GUI payload timestamp did not advance but file size changed: $expectedGuiPayload"
    }
}

# Remove confusing nested publish folder if MSBuild produced one.
$nestedPublishDir = Join-Path $publishDir 'net8.0-windows'
if (Test-Path -LiteralPath $nestedPublishDir) {
    Remove-Item -LiteralPath $nestedPublishDir -Recurse -Force
}

Write-Host 'ToolkitGUI payload build passed.' -ForegroundColor Green
Write-Host ("GUI payload: {0}" -f $expectedGuiPayload)
Write-Host ("LastWrite:   {0}" -f $actualGuiPayload.LastWriteTime)

$cdeSimdCliProject = Join-Path $PSScriptRoot 'CdeCpuSimdCli\CdeCpuSimdCli.csproj'
if (-not (Test-Path -LiteralPath $cdeSimdCliProject)) {
    throw "CdeCpuSimdCli project not found: $cdeSimdCliProject"
}

$cdeSimdCliArgs = @(
    'publish',
    $cdeSimdCliProject,
    '-c', 'Release',
    '-r', 'win-x64',
    '--self-contained', 'true',
    '-o', $publishDir,
    "-p:Version=$version",
    '-p:AppendTargetFrameworkToOutputPath=false',
    '-p:AppendRuntimeIdentifierToOutputPath=false'
)
if ($Force) {
    $cdeSimdCliArgs += '--force'
}

Write-Host "`nPublishing CdeCpuSimdCli (self-contained, colocated with GUI runtime)..." -ForegroundColor Cyan
dotnet @cdeSimdCliArgs | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "CdeCpuSimdCli publish failed with exit code $LASTEXITCODE"
}

$expectedSimdCli = Join-Path $publishDir 'CdeCpuSimdCli.exe'
if (-not (Test-Path -LiteralPath $expectedSimdCli)) {
    throw "CdeCpuSimdCli publish completed but executable was not found at: $expectedSimdCli"
}
Write-Host ("CdeCpuSimdCli: {0}" -f $expectedSimdCli) -ForegroundColor Green
Write-Host ("CdeCpuSimdCli LastWrite: {0}" -f (Get-Item -LiteralPath $expectedSimdCli).LastWriteTime)

$cdeGpuDiagCliProject = Join-Path $PSScriptRoot 'CdeGpuDiagCli\CdeGpuDiagCli.csproj'
if (-not (Test-Path -LiteralPath $cdeGpuDiagCliProject)) {
    throw "CdeGpuDiagCli project not found: $cdeGpuDiagCliProject"
}

$cdeGpuDiagCliArgs = @(
    'publish',
    $cdeGpuDiagCliProject,
    '-c', 'Release',
    '-r', 'win-x64',
    '--self-contained', 'true',
    '-o', $publishDir,
    "-p:Version=$version",
    '-p:AppendTargetFrameworkToOutputPath=false',
    '-p:AppendRuntimeIdentifierToOutputPath=false'
)
if ($Force) {
    $cdeGpuDiagCliArgs += '--force'
}

Write-Host "`nPublishing CdeGpuDiagCli (self-contained, colocated with GUI runtime)..." -ForegroundColor Cyan
dotnet @cdeGpuDiagCliArgs | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "CdeGpuDiagCli publish failed with exit code $LASTEXITCODE"
}

$expectedGpuCli = Join-Path $publishDir 'CdeGpuDiagCli.exe'
if (-not (Test-Path -LiteralPath $expectedGpuCli)) {
    throw "CdeGpuDiagCli publish completed but executable was not found at: $expectedGpuCli"
}
Write-Host ("CdeGpuDiagCli: {0}" -f $expectedGpuCli) -ForegroundColor Green
Write-Host ("CdeGpuDiagCli LastWrite: {0}" -f (Get-Item -LiteralPath $expectedGpuCli).LastWriteTime)

$cdeBehaviorCollectorProject = Join-Path $PSScriptRoot 'CdeBehaviorCollector\CdeBehaviorCollector.csproj'
if (-not (Test-Path -LiteralPath $cdeBehaviorCollectorProject)) {
    throw "CdeBehaviorCollector project not found: $cdeBehaviorCollectorProject"
}

$cdeBehaviorCollectorArgs = @(
    'publish',
    $cdeBehaviorCollectorProject,
    '-c', 'Release',
    '-r', 'win-x64',
    '--self-contained', 'true',
    '-o', $publishDir,
    "-p:Version=$version",
    '-p:AppendTargetFrameworkToOutputPath=false',
    '-p:AppendRuntimeIdentifierToOutputPath=false'
)
if ($Force) {
    $cdeBehaviorCollectorArgs += '--force'
}

Write-Host "`nPublishing CdeBehaviorCollector (self-contained, colocated with GUI runtime)..." -ForegroundColor Cyan
dotnet @cdeBehaviorCollectorArgs | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "CdeBehaviorCollector publish failed with exit code $LASTEXITCODE"
}

$expectedBehaviorCollector = Join-Path $publishDir 'CdeBehaviorCollector.exe'
if (-not (Test-Path -LiteralPath $expectedBehaviorCollector)) {
    throw "CdeBehaviorCollector publish completed but executable was not found at: $expectedBehaviorCollector"
}
Write-Host ("CdeBehaviorCollector: {0}" -f $expectedBehaviorCollector) -ForegroundColor Green
Write-Host ("CdeBehaviorCollector LastWrite: {0}" -f (Get-Item -LiteralPath $expectedBehaviorCollector).LastWriteTime)

$launcherArgs = @(
    'publish',
    $launcherProjectPath,
    '-c', 'Release',
    '-r', 'win-x64',
    '--self-contained', 'true',
    '-o', $launcherPublishDir,
    "-p:Version=$version",
    '-p:PublishSingleFile=true',
    '-p:EnableCompressionInSingleFile=false',
    '-p:PublishReadyToRun=true',
    '-p:DebugType=None',
    '-p:DebugSymbols=false',
    '-p:AssemblyName=CDE',
    '-p:AppendTargetFrameworkToOutputPath=false',
    '-p:AppendRuntimeIdentifierToOutputPath=false'
)

if ($Force) {
    $launcherArgs += '--force'
}

dotnet @launcherArgs | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "CDE launcher publish failed with exit code $LASTEXITCODE"
}

if (-not (Test-Path -LiteralPath $launcherBuildExe)) {
    throw "Launcher publish completed but expected executable was not found at: $launcherBuildExe"
}

Copy-Item -LiteralPath $launcherBuildExe -Destination $canonicalLauncherExe -Force

if (Test-Path -LiteralPath $legacyRootBat) {
    New-Item -ItemType Directory -Path $fallbackLauncherDir -Force | Out-Null
    Move-Item -LiteralPath $legacyRootBat -Destination $fallbackLauncherBat -Force
}

if (-not (Test-Path -LiteralPath $fallbackLauncherBat)) {
    throw "Fallback batch launcher missing at: $fallbackLauncherBat"
}

Write-Host ("Canonical launcher (only published .exe): {0}" -f $canonicalLauncherExe) -ForegroundColor Green
$launcherItem = Get-Item -LiteralPath $canonicalLauncherExe
Write-Host ("Launcher LastWrite: {0}" -f $launcherItem.LastWriteTime)
Write-Host ("Fallback launcher: {0}" -f $fallbackLauncherBat)

# Sync GUI payload (DLLs + ToolkitGUI.exe) for CDELauncher to spawn — not a second product entry point.
$cdeGuiPayloadDir = Join-Path $PSScriptRoot '..\CDE\ToolkitGUI\bin\Release\net8.0-windows'
$cdeGuiPayloadDir = [System.IO.Path]::GetFullPath($cdeGuiPayloadDir)
Write-Host "`nSyncing GUI payload to: $cdeGuiPayloadDir" -ForegroundColor Cyan
robocopy $publishDir $cdeGuiPayloadDir /MIR /IS /IT /NP | Out-Host
# Robocopy: 0-7 = success (including extra files at destination); 8+ = failure.
if ($LASTEXITCODE -ge 8) {
    throw "Robocopy GUI payload sync failed with exit code $LASTEXITCODE"
}
$guiPayloadItem = Get-Item -LiteralPath (Join-Path $cdeGuiPayloadDir 'ToolkitGUI.exe')
Write-Host ("GUI payload synced: {0}" -f $guiPayloadItem.FullName)
Write-Host ("GUI payload LastWrite: {0}" -f $guiPayloadItem.LastWriteTime)

Write-Host 'Publish complete. Launch Toolkit\CDE.exe only.' -ForegroundColor Green

# Sync CST source to Toolkit runtime (prevents stale copy issues)
$cstSourceCandidates = @(
    [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\Core Security Tool\CST')),
    [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\Core Security Tool\CST'))
)

$cstSourceDir = $null
foreach ($candidate in $cstSourceCandidates) {
    if (Test-Path -LiteralPath $candidate) {
        $cstSourceDir = $candidate
        break
    }
}

if ($null -eq $cstSourceDir) {
    $cstSourceDir = $cstSourceCandidates[0]
}

$cstRuntimeDir = Join-Path $toolkitRoot 'Security\CST'
Write-Host "`nSyncing CST runtime files from source..." -ForegroundColor Cyan
Write-Host ("  Source: {0}" -f $cstSourceDir)

# Guard against silently overwriting newer edits made directly inside Toolkit\Security\CST\
$cstRelativePaths = [System.Collections.Generic.List[string]]::new()
foreach ($cstFile in @('CoreSecurityTool.ps1', 'CoreSecurityTool.psm1', 'Cst.KnownGood.ps1', 'Cst.StartupEntryScan.ps1', 'rules\rules.json')) {
    $cstRelativePaths.Add($cstFile)
}
foreach ($subDir in @('rules\baselines', 'lib')) {
    $srcSubDir = Join-Path $cstSourceDir $subDir
    if (Test-Path -LiteralPath $srcSubDir) {
        foreach ($item in (Get-ChildItem -LiteralPath $srcSubDir -Recurse -File -ErrorAction SilentlyContinue)) {
            $rel = $item.FullName.Substring($cstSourceDir.Length).TrimStart('\')
            $cstRelativePaths.Add($rel)
        }
    }
}

$newerRuntimeFiles = @()
foreach ($relPath in $cstRelativePaths) {
    $srcPath = Join-Path $cstSourceDir $relPath
    $dstPath = Join-Path $cstRuntimeDir $relPath
    if ((Test-Path -LiteralPath $srcPath) -and (Test-Path -LiteralPath $dstPath)) {
        $srcItem = Get-Item -LiteralPath $srcPath
        $dstItem = Get-Item -LiteralPath $dstPath
        if ($dstItem.LastWriteTimeUtc -gt $srcItem.LastWriteTimeUtc.AddSeconds(2)) {
            $newerRuntimeFiles += ("  - {0} (Toolkit: {1:yyyy-MM-dd HH:mm:ss} UTC > Source: {2:yyyy-MM-dd HH:mm:ss} UTC)" -f $relPath, $dstItem.LastWriteTimeUtc, $srcItem.LastWriteTimeUtc)
        }
    }
}

if ($newerRuntimeFiles.Count -gt 0 -and -not $Force) {
    $details = $newerRuntimeFiles -join "`n"
    throw "Aborted CST sync: destination files in '$cstRuntimeDir' are newer than '$cstSourceDir':`n$details`nPort these changes back to '$cstSourceDir' first, or re-run Publish-ToolkitGUI.ps1 -Force to overwrite."
}

foreach ($cstFile in @('CoreSecurityTool.ps1', 'CoreSecurityTool.psm1', 'Cst.KnownGood.ps1', 'Cst.StartupEntryScan.ps1')) {
    $src = Join-Path $cstSourceDir $cstFile
    $dst = Join-Path $cstRuntimeDir $cstFile
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination $dst -Force
        Write-Host ("  Synced: {0}" -f $cstFile)
    } else {
        Write-Warning ("  CST source file not found, skipping: {0}" -f $src)
    }
}
$cstRulesDir = Join-Path $cstRuntimeDir 'rules'
New-Item -ItemType Directory -Path $cstRulesDir -Force | Out-Null
$srcRules = Join-Path $cstSourceDir 'rules\rules.json'
$dstRules = Join-Path $cstRulesDir 'rules.json'
if (Test-Path -LiteralPath $srcRules) {
    Copy-Item -LiteralPath $srcRules -Destination $dstRules -Force
    Write-Host '  Synced: rules\rules.json'
} else {
    Write-Warning ("  CST rules file not found, skipping: {0}" -f $srcRules)
}
$srcBaselines = Join-Path $cstSourceDir 'rules\baselines'
$dstBaselines = Join-Path $cstRulesDir 'baselines'
if (Test-Path -LiteralPath $srcBaselines) {
    New-Item -ItemType Directory -Path $dstBaselines -Force | Out-Null
    $staleNestedBaselines = Join-Path $dstBaselines 'baselines'
    if (Test-Path -LiteralPath $staleNestedBaselines) {
        Remove-Item -LiteralPath $staleNestedBaselines -Recurse -Force -ErrorAction SilentlyContinue
    }
    Copy-Item -Path (Join-Path $srcBaselines '*') -Destination $dstBaselines -Recurse -Force
    Write-Host '  Synced: rules\baselines\**'
}
# NSRL goodware.db is dev-only (Core Security Tool\CST\rules\). Not shipped to Toolkit/USB (FAT32 4GB limit, long publish).
$dstGoodwareDb = Join-Path $cstRulesDir 'goodware.db'
foreach ($staleNsrl in @($dstGoodwareDb, "$dstGoodwareDb-wal", "$dstGoodwareDb-shm")) {
    if (Test-Path -LiteralPath $staleNsrl) {
        Remove-Item -LiteralPath $staleNsrl -Force -ErrorAction SilentlyContinue
        Write-Host ("  Removed stale toolkit NSRL artifact: {0}" -f (Split-Path -Leaf $staleNsrl))
    }
}
# Clean up any stale backup or temp files in toolkit rules directory
foreach ($staleRuleBak in @(Get-ChildItem -LiteralPath $cstRulesDir -Filter '*.bak*' -File -ErrorAction SilentlyContinue)) {
    Remove-Item -LiteralPath $staleRuleBak.FullName -Force -ErrorAction SilentlyContinue
    Write-Host ("  Removed stale rules backup: {0}" -f $staleRuleBak.Name)
}
foreach ($staleRuleTmp in @(Get-ChildItem -LiteralPath $cstRulesDir -Filter '*.tmp*' -File -ErrorAction SilentlyContinue)) {
    Remove-Item -LiteralPath $staleRuleTmp.FullName -Force -ErrorAction SilentlyContinue
    Write-Host ("  Removed stale rules temp: {0}" -f $staleRuleTmp.Name)
}
$srcCstLib = Join-Path $cstSourceDir 'lib'
$dstCstLib = Join-Path $cstRuntimeDir 'lib'
if (Test-Path -LiteralPath $srcCstLib) {
    New-Item -ItemType Directory -Path $dstCstLib -Force | Out-Null
    $staleNestedLib = Join-Path $dstCstLib 'lib'
    if (Test-Path -LiteralPath $staleNestedLib) {
        Remove-Item -LiteralPath $staleNestedLib -Recurse -Force -ErrorAction SilentlyContinue
    }
    Copy-Item -Path (Join-Path $srcCstLib '*') -Destination $dstCstLib -Recurse -Force
    Write-Host '  Synced: lib\**'
}
Write-Host 'CST runtime sync complete.' -ForegroundColor Green

# Sync hardware test catalog from CHU (Core_Hardware_Utility.json)
$syncCatalogScript = Join-Path $PSScriptRoot '..\Scripts\Core\Sync-HardwareTestCatalog.ps1'
if (-not (Test-Path -LiteralPath $syncCatalogScript)) {
    throw "Hardware catalog sync script not found: $syncCatalogScript"
}
& $syncCatalogScript
if ($LASTEXITCODE -ne 0) {
    throw "Sync-HardwareTestCatalog.ps1 failed with exit code $LASTEXITCODE"
}
Write-Host 'Hardware test catalog sync complete.' -ForegroundColor Green

# Generate User Guide PDF into HALP
$userGuideProject = Join-Path $PSScriptRoot 'UserGuideGenerator\UserGuideGenerator.csproj'
$userGuideSource = Join-Path $toolkitRoot 'Docs\UserGuide'
$halpDir = Join-Path $toolkitRoot 'HALP'
$userGuidePdf = Join-Path $halpDir 'CDE_User_Guide.pdf'

if (-not (Test-Path -LiteralPath $userGuideProject)) {
    throw "User guide generator project not found: $userGuideProject"
}
if (-not (Test-Path -LiteralPath $userGuideSource)) {
    throw "User guide source not found: $userGuideSource"
}

Write-Host "`nGenerating User Guide PDF..." -ForegroundColor Cyan
New-Item -ItemType Directory -Path $halpDir -Force | Out-Null
dotnet publish $userGuideProject -c Release -r win-x64 --self-contained true -o $publishDir "-p:Version=$version" -p:AppendTargetFrameworkToOutputPath=false -p:AppendRuntimeIdentifierToOutputPath=false | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "UserGuideGenerator publish failed with exit code $LASTEXITCODE"
}
$userGuideExe = Join-Path $publishDir 'UserGuideGenerator.exe'
foreach ($ugFile in @('UserGuideGenerator.exe', 'UserGuideGenerator.dll', 'UserGuideGenerator.deps.json', 'UserGuideGenerator.runtimeconfig.json', 'Markdig.dll')) {
    $srcUg = Join-Path $publishDir $ugFile
    if (Test-Path -LiteralPath $srcUg) {
        Copy-Item -LiteralPath $srcUg -Destination (Join-Path $cdeGuiPayloadDir $ugFile) -Force
    }
}
& $userGuideExe $toolkitRoot $userGuideSource $userGuidePdf | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "User guide PDF generation failed with exit code $LASTEXITCODE"
}
if (-not (Test-Path -LiteralPath $userGuidePdf)) {
    throw "User guide generation completed but PDF was not found at: $userGuidePdf"
}
$rootUserGuide = Join-Path $toolkitRoot 'CDE_User_Guide.pdf'
Copy-Item -LiteralPath $userGuidePdf -Destination $rootUserGuide -Force
$userGuideItem = Get-Item -LiteralPath $userGuidePdf
Write-Host ("User guide: {0}" -f $userGuideItem.FullName) -ForegroundColor Green
Write-Host ("User guide size: {0:N0} bytes" -f $userGuideItem.Length)
Write-Host ("User guide mtime: {0}" -f $userGuideItem.LastWriteTime)

if (-not (Test-Path -LiteralPath $canonicalLauncherExe)) {
    throw "Canonical launcher missing after publish: $canonicalLauncherExe"
}

Write-Host "`nCanonical publish verified." -ForegroundColor Green
Write-Host ("  Launcher:     {0}" -f $canonicalLauncherExe)
Write-Host ("  Launcher mtime: {0}" -f (Get-Item -LiteralPath $canonicalLauncherExe).LastWriteTime)
Write-Host ("  GUI payload:  {0}" -f $guiPayloadItem.FullName)
Write-Host ("  GUI mtime:    {0}" -f $guiPayloadItem.LastWriteTime)
if (Test-Path -LiteralPath $userGuidePdf) {
    Write-Host ("  User guide:   {0}" -f $userGuideItem.FullName)
    Write-Host ("  Guide mtime:  {0}" -f $userGuideItem.LastWriteTime)
}

Write-Host "`nPublish step complete. Verification is now a separate step." -ForegroundColor Yellow
Write-Host "Run App\Publish-ToolkitGUI-FullVerify.ps1 when full validation is required." -ForegroundColor Yellow
