param(
    [string]$LauncherScript = (Join-Path (Split-Path -Parent $PSScriptRoot) "codex-only-proxy-launcher.ps1")
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $LauncherScript)) {
    throw "Launcher script not found: $LauncherScript"
}

$process = New-Object System.Diagnostics.Process
$process.StartInfo.FileName = "powershell.exe"
$process.StartInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $LauncherScript.Replace('"', '\"') + '" -RunLogHealthSelfTest'
$process.StartInfo.UseShellExecute = $false
$process.StartInfo.CreateNoWindow = $true
$process.StartInfo.RedirectStandardOutput = $true
$process.StartInfo.RedirectStandardError = $true

try {
    [void]$process.Start()

    if (-not $process.WaitForExit(20000)) {
        try {
            $process.Kill()
        } catch {
        }
        throw "Log health self-test did not exit within 20 seconds."
    }

    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()

    if ($process.ExitCode -ne 0) {
        throw "Log health self-test failed with exit code $($process.ExitCode).`n$stdout`n$stderr"
    }

    if ($stdout -notmatch "Log health self-test passed") {
        throw "Log health self-test did not report success.`n$stdout`n$stderr"
    }
} finally {
    $process.Dispose()
}
