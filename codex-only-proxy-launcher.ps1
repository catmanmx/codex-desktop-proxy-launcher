param(
    [switch]$ValidateOnly,
    [switch]$AutoStartProxy,
    [int]$AutoStartTimeoutSeconds = 90
)

#requires -version 5.1

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:AppDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:StateDir = Join-Path $env:LOCALAPPDATA "CodexProxySwitch"
$script:ConfigFile = Join-Path $script:StateDir "codex-only-launcher.json"
$script:ProxyHost = "127.0.0.1"
$script:DefaultPort = 10808
$script:NoProxy = "localhost,127.0.0.1,::1"
$script:ExitRequested = $false
$script:IconCache = @{}

function Ensure-StateDir {
    New-Item -ItemType Directory -Force -Path $script:StateDir | Out-Null
}

function Read-Config {
    Ensure-StateDir

    if (Test-Path $script:ConfigFile) {
        try {
            $config = Get-Content -Path $script:ConfigFile -Raw | ConvertFrom-Json
            if ($config.Port -as [int]) {
                $mode = if ($config.Mode -in @("proxy", "normal")) { [string]$config.Mode } else { "normal" }
                $language = if ($config.Language -in @("zh", "en")) { [string]$config.Language } else { "zh" }
                return [pscustomobject]@{
                    Port = [int]$config.Port
                    Mode = $mode
                    Language = $language
                    LaunchedAt = [string]$config.LaunchedAt
                }
            }
        } catch {
        }
    }

    [pscustomobject]@{
        Port = $script:DefaultPort
        Mode = "normal"
        Language = "zh"
        LaunchedAt = $null
    }
}

function Save-Config {
    param(
        [int]$Port,
        [ValidateSet("proxy", "normal")]
        [string]$Mode,
        [ValidateSet("zh", "en")]
        [string]$Language = $(if ($script:Language) { $script:Language } else { "zh" })
    )

    Ensure-StateDir
    [pscustomobject]@{
        Port = $Port
        Mode = $Mode
        Language = $Language
        LaunchedAt = (Get-Date).ToString("o")
    } | ConvertTo-Json | Set-Content -Path $script:ConfigFile -Encoding UTF8
}

function T {
    param(
        [string]$Key,
        [object[]]$FormatArgs = @()
    )

    $texts = @{
        zh = @{
            title = "Codex 专用代理启动器"
            lang_button = "EN"
            no_exe = "没有找到 Codex Desktop 的启动入口。请先手动打开一次 Codex，再重新使用这个启动器。"
            launch_fail = "启动 Codex 失败：{0}"
            invalid_port = "端口必须是 1 到 65535 之间的数字。"
            proxy_ok = "本地代理可以连通 OpenAI。`n端口：{0}"
            proxy_unclear = "没有确认连通。`n`n{0}"
            test_fail = "测试失败：{0}"
            port_label = "代理软件本地端口"
            host_label = "本机地址：127.0.0.1"
            normal_button = "普通模式重启 Codex"
            test_button = "测试当前端口是否可用"
            hint = "说明：红色表示关闭，绿色表示打开。这个启动器只影响被它重启的 Codex，不改系统代理。切换 VPN 节点不需要动这里，只有代理软件本地端口变了才改端口。"
            menu_open = "打开面板"
            menu_normal = "普通模式重启 Codex"
            menu_test = "测试当前端口"
            menu_exit = "退出"
            status_on = "绿色：Codex 正在通过专用代理运行，端口：{0}"
            status_off_running = "红色：Codex 正在运行，但没有通过本启动器代理"
            status_off_idle = "红色：Codex 没有使用专用代理"
            toggle_on = "关闭代理，并用普通模式重启 Codex"
            menu_toggle_on = "关闭代理并普通模式重启"
            tray_on = "Codex 专用代理：已打开"
            toggle_off = "打开代理，并重启 Codex"
            menu_toggle_off = "打开代理并重启 Codex"
            tray_off = "Codex 专用代理：已关闭"
            confirm_restart = "切换到{0}需要关闭当前 Codex 并重新启动。正在运行的任务会被中断。是否继续？"
            target_proxy = "代理模式"
            target_normal = "普通模式"
        }
        en = @{
            title = "Codex Proxy Launcher"
            lang_button = "中文"
            no_exe = "Codex Desktop launch entry was not found. Open Codex once manually, then use this launcher again."
            launch_fail = "Failed to start Codex: {0}"
            invalid_port = "Port must be a number from 1 to 65535."
            proxy_ok = "Local proxy can reach OpenAI.`nPort: {0}"
            proxy_unclear = "Connectivity was not confirmed.`n`n{0}"
            test_fail = "Test failed: {0}"
            port_label = "Proxy app local port"
            host_label = "Host: 127.0.0.1"
            normal_button = "Restart Codex normally"
            test_button = "Test current port"
            hint = "Red means off, green means on. This launcher only affects Codex restarted by it and does not change system proxy. You do not need to change this when switching VPN nodes; only update the port if your proxy app local port changes."
            menu_open = "Open panel"
            menu_normal = "Restart Codex normally"
            menu_test = "Test current port"
            menu_exit = "Exit"
            status_on = "Green: Codex is using dedicated proxy. Port: {0}"
            status_off_running = "Red: Codex is running without launcher proxy"
            status_off_idle = "Red: Codex is not using dedicated proxy"
            toggle_on = "Turn off proxy and restart Codex normally"
            menu_toggle_on = "Turn off proxy and restart"
            tray_on = "Codex proxy: ON"
            toggle_off = "Turn on proxy and restart Codex"
            menu_toggle_off = "Turn on proxy and restart Codex"
            tray_off = "Codex proxy: OFF"
            confirm_restart = "Switching to {0} must close and restart Codex. Running tasks will be interrupted. Continue?"
            target_proxy = "proxy mode"
            target_normal = "normal mode"
        }
    }

    $language = if ($script:Language -in @("zh", "en")) { $script:Language } else { "zh" }
    $template = $texts[$language][$Key]
    if ($null -eq $template) {
        $template = $Key
    }

    if ($FormatArgs.Count -gt 0) {
        return [string]::Format($template, $FormatArgs)
    }

    return $template
}

function Get-ProxyUrl {
    param([int]$Port)
    "http://$script:ProxyHost`:$Port"
}

function Wait-LocalProxyPort {
    param(
        [int]$Port,
        [int]$TimeoutSeconds = 90
    )

    $deadline = (Get-Date).AddSeconds([Math]::Max(1, $TimeoutSeconds))

    do {
        $client = $null
        $async = $null

        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $async = $client.BeginConnect($script:ProxyHost, $Port, $null, $null)

            if ($async.AsyncWaitHandle.WaitOne(1000)) {
                $client.EndConnect($async)
                return $true
            }
        } catch {
        } finally {
            if ($async -and $async.AsyncWaitHandle) {
                $async.AsyncWaitHandle.Close()
            }
            if ($client) {
                $client.Close()
            }
        }

        Start-Sleep -Milliseconds 1000
    } while ((Get-Date) -lt $deadline)

    return $false
}

function Find-CodexDesktopExe {
    $running = Get-Process -Name "Codex" -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and (Test-Path $_.Path) } |
        Sort-Object StartTime -Descending |
        Select-Object -First 1

    if ($running -and $running.Path) {
        return $running.Path
    }

    $packages = @(Get-AppxPackage -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -like "*Codex*" -or
            $_.PackageFamilyName -like "OpenAI.Codex*"
        } |
        Sort-Object Version -Descending)

    foreach ($package in $packages) {
        foreach ($relative in @("app\Codex.exe", "Codex.exe")) {
            $candidate = Join-Path $package.InstallLocation $relative
            if (Test-Path $candidate) {
                return $candidate
            }
        }
    }

    $knownRoot = Join-Path $env:ProgramFiles "WindowsApps"
    $known = Get-ChildItem -Path $knownRoot -Directory -Filter "OpenAI.Codex_*" -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending

    foreach ($dir in $known) {
        $candidate = Join-Path $dir.FullName "app\Codex.exe"
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    return $null
}

function Get-CodexProcesses {
    @("Codex", "codex") |
        ForEach-Object { Get-Process -Name $_ -ErrorAction SilentlyContinue } |
        Where-Object {
            try {
                -not [string]::IsNullOrWhiteSpace($_.Path) -and
                (
                    $_.Path -like "*\OpenAI.Codex_*" -or
                    $_.Path -like "*\AppData\Local\OpenAI\Codex\bin\*"
                )
            } catch {
                $false
            }
        }
}

function Test-CodexProxyModeRunning {
    param([int]$Port)

    $config = Read-Config
    return ($config.Mode -eq "proxy" -and [int]$config.Port -eq $Port -and (Test-AnyCodexRunning))
}

function Test-AnyCodexRunning {
    @(Get-CodexProcesses).Count -gt 0
}

function Stop-CodexProcesses {
    $processes = @(Get-CodexProcesses)
    foreach ($process in $processes) {
        try {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        } catch {
        }
    }

    Start-Sleep -Milliseconds 900
}

function Get-CodexAppUserModelId {
    $exe = Find-CodexDesktopExe
    if ($exe -and $exe -match "OpenAI\.Codex_[^\\]+__([^\\]+)") {
        return "OpenAI.Codex_$($Matches[1])!App"
    }

    return "OpenAI.Codex_2p2nqsd0c76g0!App"
}

function Ensure-AppActivationType {
    if ("AppActivation.ApplicationActivator" -as [type]) {
        return
    }

    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace AppActivation {
    [Flags]
    public enum ActivateOptions {
        None = 0x00000000,
        DesignMode = 0x00000001,
        NoErrorUI = 0x00000002,
        NoSplashScreen = 0x00000004
    }

    [ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IApplicationActivationManager {
        [PreserveSig]
        int ActivateApplication(
            [In, MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
            [In, MarshalAs(UnmanagedType.LPWStr)] string arguments,
            [In] ActivateOptions options,
            out uint processId);
    }

    [ComImport, Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")]
    public class ApplicationActivationManager {}

    public static class ApplicationActivator {
        public static uint Activate(string appUserModelId, string arguments) {
            Guid clsid = new Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C");
            Type type = Type.GetTypeFromCLSID(clsid);
            object comObject = Activator.CreateInstance(type);
            IntPtr unknownPtr = IntPtr.Zero;
            IntPtr interfacePtr = IntPtr.Zero;

            try {
                unknownPtr = Marshal.GetIUnknownForObject(comObject);
                Guid iid = typeof(IApplicationActivationManager).GUID;
                int queryResult = Marshal.QueryInterface(unknownPtr, ref iid, out interfacePtr);
                if (queryResult != 0) {
                    Marshal.ThrowExceptionForHR(queryResult);
                }

                IApplicationActivationManager manager =
                    (IApplicationActivationManager)Marshal.GetTypedObjectForIUnknown(interfacePtr, typeof(IApplicationActivationManager));

                uint processId;
                int result = manager.ActivateApplication(appUserModelId, arguments ?? "", ActivateOptions.None, out processId);
                if (result != 0) {
                    Marshal.ThrowExceptionForHR(result);
                }

                return processId;
            } finally {
                if (interfacePtr != IntPtr.Zero) {
                    Marshal.Release(interfacePtr);
                }
                if (unknownPtr != IntPtr.Zero) {
                    Marshal.Release(unknownPtr);
                }
                if (comObject != null) {
                    Marshal.ReleaseComObject(comObject);
                }
            }
        }
    }
}
"@
}

function Start-PackagedCodex {
    param([string]$Arguments)

    Ensure-AppActivationType
    $appId = Get-CodexAppUserModelId
    [AppActivation.ApplicationActivator]::Activate($appId, $Arguments) | Out-Null
}

function Start-Codex {
    param(
        [int]$Port,
        [switch]$ProxyMode
    )

    $exe = Find-CodexDesktopExe
    if (-not $exe) {
        [System.Windows.Forms.MessageBox]::Show((T "no_exe"), (T "title"), "OK", "Error") | Out-Null
        return $false
    }

    $arguments = ""

    if ($ProxyMode) {
        $proxyUrl = Get-ProxyUrl $Port
        $arguments = "--proxy-server=$proxyUrl --proxy-bypass-list=localhost;127.0.0.1;::1"
    }

    try {
        if ($exe -like "*\WindowsApps\*") {
            Start-PackagedCodex -Arguments $arguments
        } else {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $exe
            $psi.WorkingDirectory = Split-Path $exe -Parent
            $psi.UseShellExecute = $false
            $psi.Arguments = $arguments

            if ($ProxyMode) {
                $proxyUrl = Get-ProxyUrl $Port
                $psi.EnvironmentVariables["HTTP_PROXY"] = $proxyUrl
                $psi.EnvironmentVariables["HTTPS_PROXY"] = $proxyUrl
                $psi.EnvironmentVariables["ALL_PROXY"] = $proxyUrl
                $psi.EnvironmentVariables["NO_PROXY"] = $script:NoProxy
                $psi.EnvironmentVariables["http_proxy"] = $proxyUrl
                $psi.EnvironmentVariables["https_proxy"] = $proxyUrl
                $psi.EnvironmentVariables["all_proxy"] = $proxyUrl
                $psi.EnvironmentVariables["no_proxy"] = $script:NoProxy
                $psi.EnvironmentVariables["CODEX_PROXY_SWITCH_MODE"] = "proxy"
                $psi.EnvironmentVariables["CODEX_PROXY_SWITCH_PORT"] = [string]$Port
            }

            [System.Diagnostics.Process]::Start($psi) | Out-Null
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show((T "launch_fail" $_.Exception.Message), (T "title"), "OK", "Error") | Out-Null
        return $false
    }

    Save-Config -Port $Port -Mode $(if ($ProxyMode) { "proxy" } else { "normal" })
    return $true
}

function Parse-PortFromTextBox {
    param([System.Windows.Forms.TextBox]$TextBox)

    $raw = $TextBox.Text.Trim()
    $port = 0
    if (-not [int]::TryParse($raw, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        [System.Windows.Forms.MessageBox]::Show((T "invalid_port"), (T "title"), "OK", "Warning") | Out-Null
        return $null
    }

    return $port
}

function New-StateIcon {
    param([bool]$Enabled)

    $key = if ($Enabled) { "on" } else { "off" }
    if ($script:IconCache.ContainsKey($key)) {
        return $script:IconCache[$key]
    }

    $fileName = if ($Enabled) { "proxy-on.ico" } else { "proxy-off.ico" }
    $iconPath = Join-Path (Join-Path $script:AppDir "icons") $fileName

    try {
        if (Test-Path -LiteralPath $iconPath) {
            $script:IconCache[$key] = New-Object System.Drawing.Icon -ArgumentList $iconPath
        } else {
            $script:IconCache[$key] = [System.Drawing.SystemIcons]::Application.Clone()
        }
    } catch {
        $script:IconCache[$key] = [System.Drawing.SystemIcons]::Application.Clone()
    }

    return $script:IconCache[$key]
}

function Dispose-StateIcons {
    foreach ($icon in $script:IconCache.Values) {
        try {
            if ($icon) { $icon.Dispose() }
        } catch {
        }
    }
    $script:IconCache.Clear()
}

function Test-OpenAIProxy {
    param([int]$Port)

    $tempOut = Join-Path $env:TEMP "codex-only-proxy-test.out"
    $tempErr = Join-Path $env:TEMP "codex-only-proxy-test.err"
    Remove-Item $tempOut, $tempErr -ErrorAction SilentlyContinue

    try {
        $process = Start-Process -FilePath "curl.exe" `
            -ArgumentList @("--ssl-no-revoke", "-I", "--max-time", "12", "--proxy", (Get-ProxyUrl $Port), "https://api.openai.com") `
            -WindowStyle Hidden `
            -RedirectStandardOutput $tempOut `
            -RedirectStandardError $tempErr `
            -Wait `
            -PassThru

        $output = ""
        if (Test-Path $tempOut) { $output += Get-Content $tempOut -Raw }
        if (Test-Path $tempErr) { $output += Get-Content $tempErr -Raw }

        if ($output -match "HTTP/\d(\.\d)?\s+(200|401|403|404|421)") {
            [System.Windows.Forms.MessageBox]::Show((T "proxy_ok" $Port), (T "title"), "OK", "Information") | Out-Null
        } else {
            [System.Windows.Forms.MessageBox]::Show((T "proxy_unclear" $output), (T "title"), "OK", "Warning") | Out-Null
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show((T "test_fail" $_.Exception.Message), (T "title"), "OK", "Error") | Out-Null
    }
}

if ($ValidateOnly) {
    Ensure-AppActivationType
    Write-Host "Codex-only launcher script parsed successfully."
    exit 0
}

[System.Windows.Forms.Application]::EnableVisualStyles()

$config = Read-Config
$script:Language = $config.Language

if ($AutoStartProxy) {
    $autoPort = if ($config.Port -as [int]) { [int]$config.Port } else { $script:DefaultPort }
    [void](Wait-LocalProxyPort -Port $autoPort -TimeoutSeconds $AutoStartTimeoutSeconds)
    Stop-CodexProcesses
    [void](Start-Codex -Port $autoPort -ProxyMode)
    $config = Read-Config
}

$form = New-Object System.Windows.Forms.Form
$form.Text = T "title"
$form.Size = New-Object System.Drawing.Size(620, 330)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.MinimizeBox = $true
$form.ShowInTaskbar = $true
$form.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)

$languageButton = New-Object System.Windows.Forms.Button
$languageButton.Location = New-Object System.Drawing.Point(22, 17)
$languageButton.Size = New-Object System.Drawing.Size(64, 28)
$languageButton.FlatStyle = "System"

$statusDot = New-Object System.Windows.Forms.Panel
$statusDot.Location = New-Object System.Drawing.Point(102, 22)
$statusDot.Size = New-Object System.Drawing.Size(18, 18)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Location = New-Object System.Drawing.Point(130, 19)
$statusLabel.Size = New-Object System.Drawing.Size(455, 24)

$portLabel = New-Object System.Windows.Forms.Label
$portLabel.Text = T "port_label"
$portLabel.Location = New-Object System.Drawing.Point(22, 62)
$portLabel.Size = New-Object System.Drawing.Size(140, 24)

$portBox = New-Object System.Windows.Forms.TextBox
$portBox.Location = New-Object System.Drawing.Point(170, 58)
$portBox.Size = New-Object System.Drawing.Size(90, 24)
$portBox.Text = [string]$config.Port

$hostLabel = New-Object System.Windows.Forms.Label
$hostLabel.Text = T "host_label"
$hostLabel.Location = New-Object System.Drawing.Point(275, 62)
$hostLabel.Size = New-Object System.Drawing.Size(180, 24)

$toggleButton = New-Object System.Windows.Forms.Button
$toggleButton.Location = New-Object System.Drawing.Point(22, 102)
$toggleButton.Size = New-Object System.Drawing.Size(560, 40)
$toggleButton.FlatStyle = "System"

$normalButton = New-Object System.Windows.Forms.Button
$normalButton.Text = T "normal_button"
$normalButton.Location = New-Object System.Drawing.Point(22, 148)
$normalButton.Size = New-Object System.Drawing.Size(275, 34)
$normalButton.FlatStyle = "System"

$testButton = New-Object System.Windows.Forms.Button
$testButton.Text = T "test_button"
$testButton.Location = New-Object System.Drawing.Point(307, 148)
$testButton.Size = New-Object System.Drawing.Size(275, 34)
$testButton.FlatStyle = "System"

$hintLabel = New-Object System.Windows.Forms.Label
$hintLabel.Text = T "hint"
$hintLabel.Location = New-Object System.Drawing.Point(22, 196)
$hintLabel.Size = New-Object System.Drawing.Size(560, 70)

$form.Controls.AddRange(@($languageButton, $statusDot, $statusLabel, $portLabel, $portBox, $hostLabel, $toggleButton, $normalButton, $testButton, $hintLabel))

$contextMenu = New-Object System.Windows.Forms.ContextMenuStrip
$menuOpen = New-Object System.Windows.Forms.ToolStripMenuItem (T "menu_open")
$menuToggle = New-Object System.Windows.Forms.ToolStripMenuItem
$menuNormal = New-Object System.Windows.Forms.ToolStripMenuItem (T "menu_normal")
$menuTest = New-Object System.Windows.Forms.ToolStripMenuItem (T "menu_test")
$menuExit = New-Object System.Windows.Forms.ToolStripMenuItem (T "menu_exit")
[void]$contextMenu.Items.Add($menuOpen)
[void]$contextMenu.Items.Add($menuToggle)
[void]$contextMenu.Items.Add($menuNormal)
[void]$contextMenu.Items.Add($menuTest)
[void]$contextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$contextMenu.Items.Add($menuExit)

$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.ContextMenuStrip = $contextMenu
$notifyIcon.Visible = $true

function Save-LanguagePreference {
    $currentConfig = Read-Config
    $port = [int]$currentConfig.Port
    $parsedPort = 0
    if ([int]::TryParse($portBox.Text.Trim(), [ref]$parsedPort)) {
        $port = $parsedPort
    }

    Save-Config -Port $port -Mode $currentConfig.Mode -Language $script:Language
}

function Update-LanguageUi {
    $form.Text = T "title"
    $languageButton.Text = T "lang_button"
    $portLabel.Text = T "port_label"
    $hostLabel.Text = T "host_label"
    $normalButton.Text = T "normal_button"
    $testButton.Text = T "test_button"
    $hintLabel.Text = T "hint"
    $menuOpen.Text = T "menu_open"
    $menuNormal.Text = T "menu_normal"
    $menuTest.Text = T "menu_test"
    $menuExit.Text = T "menu_exit"
    Update-Ui
}

function Update-Ui {
    $port = 0
    [void][int]::TryParse($portBox.Text.Trim(), [ref]$port)
    $isProxyRunning = if ($port -gt 0) { Test-CodexProxyModeRunning $port } else { $false }
    $anyCodex = Test-AnyCodexRunning

    if ($isProxyRunning) {
        $statusDot.BackColor = [System.Drawing.Color]::FromArgb(28, 172, 84)
        $statusLabel.Text = T "status_on" $port
        $toggleButton.Text = T "toggle_on"
        $menuToggle.Text = T "menu_toggle_on"
        $notifyIcon.Icon = New-StateIcon $true
        $notifyIcon.Text = T "tray_on"
    } else {
        $statusDot.BackColor = [System.Drawing.Color]::FromArgb(220, 55, 55)
        $statusLabel.Text = if ($anyCodex) { T "status_off_running" } else { T "status_off_idle" }
        $toggleButton.Text = T "toggle_off"
        $menuToggle.Text = T "menu_toggle_off"
        $notifyIcon.Icon = New-StateIcon $false
        $notifyIcon.Text = T "tray_off"
    }
}

function Confirm-Restart {
    param([string]$TargetMode)

    if (-not (Test-AnyCodexRunning)) {
        return $true
    }

    $targetMode = T $TargetMode
    $message = T "confirm_restart" $targetMode
    $result = [System.Windows.Forms.MessageBox]::Show($message, (T "title"), "YesNo", "Warning")
    return $result -eq [System.Windows.Forms.DialogResult]::Yes
}

function Start-ProxyMode {
    $port = Parse-PortFromTextBox $portBox
    if ($null -eq $port) {
        return
    }

    if (-not (Confirm-Restart "target_proxy")) {
        return
    }

    Stop-CodexProcesses
    if (Start-Codex -Port $port -ProxyMode) {
        Update-Ui
    }
}

function Start-NormalMode {
    $port = Parse-PortFromTextBox $portBox
    if ($null -eq $port) {
        return
    }

    if (-not (Confirm-Restart "target_normal")) {
        return
    }

    Stop-CodexProcesses
    if (Start-Codex -Port $port) {
        Update-Ui
    }
}

function Invoke-Toggle {
    $port = Parse-PortFromTextBox $portBox
    if ($null -eq $port) {
        return
    }

    if (Test-CodexProxyModeRunning $port) {
        Start-NormalMode
    } else {
        Start-ProxyMode
    }
}

$languageButton.Add_Click({
    $script:Language = if ($script:Language -eq "zh") { "en" } else { "zh" }
    Save-LanguagePreference
    Update-LanguageUi
})
$toggleButton.Add_Click({ Invoke-Toggle })
$normalButton.Add_Click({ Start-NormalMode })
$testButton.Add_Click({
    $port = Parse-PortFromTextBox $portBox
    if ($null -ne $port) { Test-OpenAIProxy $port }
})
$menuToggle.Add_Click({ Invoke-Toggle })
$menuNormal.Add_Click({ Start-NormalMode })
$menuTest.Add_Click({
    $port = Parse-PortFromTextBox $portBox
    if ($null -ne $port) { Test-OpenAIProxy $port }
})
$menuOpen.Add_Click({
    $form.Show()
    $form.WindowState = "Normal"
    $form.Activate()
})
$notifyIcon.Add_DoubleClick({
    $form.Show()
    $form.WindowState = "Normal"
    $form.Activate()
})
$menuExit.Add_Click({
    $script:ExitRequested = $true
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    Dispose-StateIcons
    $form.Close()
})
$form.Add_FormClosing({
    if (-not $script:ExitRequested) {
        $_.Cancel = $true
        $form.Hide()
    }
})
$portBox.Add_TextChanged({ Update-Ui })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2500
$timer.Add_Tick({ Update-Ui })
$timer.Start()

Update-LanguageUi
[System.Windows.Forms.Application]::Run($form)
