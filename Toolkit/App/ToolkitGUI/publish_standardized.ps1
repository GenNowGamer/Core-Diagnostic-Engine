param(
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"

$projPath = Join-Path $PSScriptRoot "ToolkitGUI.csproj"
$outDir = Join-Path $PSScriptRoot "bin\Release\net8.0-windows"

Write-Host "Publishing ToolkitGUI self-contained to standardized path..." -ForegroundColor Cyan
Write-Host "  Project: $projPath"
Write-Host "  Output : $outDir"

dotnet publish "$projPath" -c $Configuration -r win-x64 --self-contained true -o "$outDir" /p:PublishSingleFile=false /p:AppendRuntimeIdentifierToOutputPath=false
if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed."
}

$nestedRidDir = Join-Path $outDir "win-x64"
if (Test-Path $nestedRidDir) {
    Remove-Item -Recurse -Force $nestedRidDir
}

Write-Host "Publish complete." -ForegroundColor Green
