param(
    [string]$Version = "0.1.0"
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ScriptDir
$DistDir = Join-Path $Root "dist"
$ReleaseName = "codex-desktop-proxy-launcher-v$Version"
$PackageDir = Join-Path $DistDir $ReleaseName
$ZipPath = Join-Path $DistDir "$ReleaseName.zip"
$SourcePath = Join-Path $Root "src\CodexProxyLauncherBootstrap.cs"
$ExePath = Join-Path $PackageDir "CodexProxyLauncher.exe"

if (-not (Test-Path $SourcePath)) {
    throw "Missing source file: $SourcePath"
}

if (Test-Path $PackageDir) {
    Remove-Item -LiteralPath $PackageDir -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $PackageDir | Out-Null

$source = Get-Content -Path $SourcePath -Raw
Add-Type `
    -TypeDefinition $source `
    -ReferencedAssemblies @("System.Windows.Forms", "System.Drawing", "System.Core") `
    -OutputAssembly $ExePath `
    -OutputType WindowsApplication

$filesToCopy = @(
    "codex-only-proxy-launcher.ps1",
    "codex-only-proxy-launcher.cmd",
    "start-codex-only-proxy-launcher.vbs",
    "README.md",
    "CHANGELOG.md",
    "LICENSE"
)

foreach ($file in $filesToCopy) {
    Copy-Item -Path (Join-Path $Root $file) -Destination $PackageDir -Force
}

if (Test-Path $ZipPath) {
    Remove-Item -LiteralPath $ZipPath -Force
}

Compress-Archive -Path (Join-Path $PackageDir "*") -DestinationPath $ZipPath -Force

Write-Host "Built package:"
Write-Host $PackageDir
Write-Host "Built zip:"
Write-Host $ZipPath
