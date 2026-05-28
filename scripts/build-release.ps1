param(
    [string]$Version = "0.1.1"
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ScriptDir
$DistDir = Join-Path $Root "dist"
$ReleaseName = "codex-desktop-proxy-launcher-v$Version"
$PackageDir = Join-Path $DistDir $ReleaseName
$BuildDir = Join-Path $DistDir "build"
$ZipPath = Join-Path $DistDir "$ReleaseName.zip"
$SourcePath = Join-Path $Root "src\CodexProxyLauncherBootstrap.cs"
$ExePath = Join-Path $PackageDir "CodexProxyLauncher.exe"
$IconPath = Join-Path $BuildDir "CodexProxyLauncher.ico"

function New-LauncherIcon {
    param([string]$Path)

    Add-Type -AssemblyName System.Drawing

    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $directory | Out-Null

    $bitmap = New-Object System.Drawing.Bitmap 256, 256, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([System.Drawing.Color]::Transparent)

    $backgroundPath = New-Object System.Drawing.Drawing2D.GraphicsPath
    $radius = 48
    $backgroundPath.AddArc(18, 18, $radius, $radius, 180, 90)
    $backgroundPath.AddArc(190, 18, $radius, $radius, 270, 90)
    $backgroundPath.AddArc(190, 190, $radius, $radius, 0, 90)
    $backgroundPath.AddArc(18, 190, $radius, $radius, 90, 90)
    $backgroundPath.CloseFigure()

    $backgroundBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(18, 24, 38))
    $graphics.FillPath($backgroundBrush, $backgroundPath)

    $linePen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(245, 248, 252)), 24
    $linePen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $linePen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $graphics.DrawLine($linePen, 82, 142, 174, 114)

    $redBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(226, 57, 57))
    $greenBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(34, 184, 96))
    $whitePen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 255, 255)), 8
    $graphics.FillEllipse($redBrush, 52, 102, 74, 74)
    $graphics.DrawEllipse($whitePen, 56, 106, 66, 66)
    $graphics.FillEllipse($greenBrush, 132, 78, 82, 82)
    $graphics.DrawEllipse($whitePen, 136, 82, 74, 74)

    $boltPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(245, 248, 252)), 12
    $boltPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $boltPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $graphics.DrawLine($boltPen, 112, 200, 143, 170)
    $graphics.DrawLine($boltPen, 143, 170, 134, 196)
    $graphics.DrawLine($boltPen, 134, 196, 164, 166)

    $icon = [System.Drawing.Icon]::FromHandle($bitmap.GetHicon())
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create)
    try {
        $icon.Save($stream)
    } finally {
        $stream.Dispose()
        $icon.Dispose()
        $graphics.Dispose()
        $backgroundPath.Dispose()
        $backgroundBrush.Dispose()
        $linePen.Dispose()
        $redBrush.Dispose()
        $greenBrush.Dispose()
        $whitePen.Dispose()
        $boltPen.Dispose()
        $bitmap.Dispose()
    }
}

if (-not (Test-Path $SourcePath)) {
    throw "Missing source file: $SourcePath"
}

if (Test-Path $PackageDir) {
    Remove-Item -LiteralPath $PackageDir -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $PackageDir | Out-Null
New-LauncherIcon -Path $IconPath

$source = Get-Content -Path $SourcePath -Raw
$compilerParameters = New-Object System.CodeDom.Compiler.CompilerParameters
$compilerParameters.GenerateExecutable = $true
$compilerParameters.GenerateInMemory = $false
$compilerParameters.OutputAssembly = $ExePath
$compilerParameters.CompilerOptions = "/target:winexe /win32icon:`"$IconPath`""
[void]$compilerParameters.ReferencedAssemblies.Add("System.dll")
[void]$compilerParameters.ReferencedAssemblies.Add("System.Core.dll")
[void]$compilerParameters.ReferencedAssemblies.Add("System.Windows.Forms.dll")
[void]$compilerParameters.ReferencedAssemblies.Add("System.Drawing.dll")

Add-Type -AssemblyName Microsoft.CSharp
$provider = New-Object Microsoft.CSharp.CSharpCodeProvider
try {
    $compileResults = $provider.CompileAssemblyFromSource($compilerParameters, $source)
    if ($compileResults.Errors.HasErrors) {
        $messages = $compileResults.Errors | ForEach-Object { $_.ToString() }
        throw "C# compilation failed:`n$($messages -join [Environment]::NewLine)"
    }
} finally {
    $provider.Dispose()
}

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
Write-Host "Embedded icon:"
Write-Host $IconPath
