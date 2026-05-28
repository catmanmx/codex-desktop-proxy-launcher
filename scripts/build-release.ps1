param(
    [string]$Version = "0.1.2"
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing

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
$IconDir = Join-Path $PackageDir "icons"
$ProxyOnIconPath = Join-Path $IconDir "proxy-on.ico"
$ProxyOffIconPath = Join-Path $IconDir "proxy-off.ico"

function Save-BitmapAsIcon {
    param(
        [System.Drawing.Bitmap]$Bitmap,
        [string]$Path
    )

    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $directory | Out-Null

    $pngStream = New-Object System.IO.MemoryStream
    try {
        $Bitmap.Save($pngStream, [System.Drawing.Imaging.ImageFormat]::Png)
        $pngBytes = $pngStream.ToArray()
    } finally {
        $pngStream.Dispose()
    }

    $fileStream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    $writer = New-Object System.IO.BinaryWriter -ArgumentList $fileStream
    try {
        $width = if ($Bitmap.Width -ge 256) { 0 } else { $Bitmap.Width }
        $height = if ($Bitmap.Height -ge 256) { 0 } else { $Bitmap.Height }

        $writer.Write([uint16]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]1)
        $writer.Write([byte]$width)
        $writer.Write([byte]$height)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]32)
        $writer.Write([uint32]$pngBytes.Length)
        $writer.Write([uint32]22)
        $writer.Write($pngBytes)
    } finally {
        $writer.Dispose()
    }
}

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

    try {
        Save-BitmapAsIcon -Bitmap $bitmap -Path $Path
    } finally {
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

function New-StateIconFile {
    param(
        [string]$Path,
        [bool]$Enabled
    )

    Add-Type -AssemblyName System.Drawing

    $bitmap = New-Object System.Drawing.Bitmap 64, 64, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([System.Drawing.Color]::Transparent)

    $color = if ($Enabled) { [System.Drawing.Color]::FromArgb(28, 172, 84) } else { [System.Drawing.Color]::FromArgb(220, 55, 55) }
    $brush = New-Object System.Drawing.SolidBrush $color
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), 6

    try {
        $graphics.FillEllipse($brush, 8, 8, 48, 48)
        $graphics.DrawEllipse($pen, 10, 10, 44, 44)
        Save-BitmapAsIcon -Bitmap $bitmap -Path $Path
    } finally {
        $graphics.Dispose()
        $brush.Dispose()
        $pen.Dispose()
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
New-StateIconFile -Path $ProxyOnIconPath -Enabled $true
New-StateIconFile -Path $ProxyOffIconPath -Enabled $false

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
Write-Host "Tray icons:"
Write-Host $ProxyOnIconPath
Write-Host $ProxyOffIconPath
