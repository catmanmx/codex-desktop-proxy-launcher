param(
    [switch]$ValidateOnly,
    [switch]$AutoStartProxy,
    [int]$AutoStartTimeoutSeconds = 90,
    [switch]$StartMinimized,
    [switch]$RunLogHealthSelfTest
)

#requires -version 5.1

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Global runtime state. Keep this section small and boring: these values are
# shared by WinForms event handlers, timer callbacks, and helper functions.
$script:AppDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:StateDir = Join-Path $env:LOCALAPPDATA "CodexProxySwitch"
$script:ConfigFile = Join-Path $script:StateDir "codex-only-launcher.json"
$script:LogFile = Join-Path $script:StateDir "launcher.log"
$script:ManagedUserEnvFile = Join-Path $script:StateDir "managed-user-proxy-env.json"
$script:LogHealthModule = Join-Path $script:AppDir "codex-log-health.ps1"
$script:ProxyHost = "127.0.0.1"
$script:DefaultPort = 10808
$script:NoProxy = "localhost,127.0.0.1,::1"
$script:ExitRequested = $false
$script:IconCache = @{}
$script:SyncingStartupUi = $false
$script:MonitorEnabled = $false
$script:MonitorProcess = $null
$script:MonitorPort = 0
$script:MonitorSuccessCount = 0
$script:MonitorFailureCount = 0
$script:MonitorLastState = "idle"
$script:MonitorNextCheckAt = Get-Date

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
                    LastKnownCodexVersion = [string]$config.LastKnownCodexVersion
                    LastLogHealthMaxId = $config.LastLogHealthMaxId
                    LastLogHealthStatus = [string]$config.LastLogHealthStatus
                    LastLogHealthCheckedAt = [string]$config.LastLogHealthCheckedAt
                    LastBackupDir = [string]$config.LastBackupDir
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
        LastKnownCodexVersion = $null
        LastLogHealthMaxId = $null
        LastLogHealthStatus = $null
        LastLogHealthCheckedAt = $null
        LastBackupDir = $null
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
    $existing = Read-Config
    [pscustomobject]@{
        Port = $Port
        Mode = $Mode
        Language = $Language
        LaunchedAt = (Get-Date).ToString("o")
        LastKnownCodexVersion = $existing.LastKnownCodexVersion
        LastLogHealthMaxId = $existing.LastLogHealthMaxId
        LastLogHealthStatus = $existing.LastLogHealthStatus
        LastLogHealthCheckedAt = $existing.LastLogHealthCheckedAt
        LastBackupDir = $existing.LastBackupDir
    } | ConvertTo-Json -Depth 4 | Set-Content -Path $script:ConfigFile -Encoding UTF8
}

function Save-LogHealthConfig {
    param([object]$Result)

    if (-not $Result) { return }
    Ensure-StateDir
    $existing = Read-Config
    [pscustomobject]@{
        Port = $existing.Port
        Mode = $existing.Mode
        Language = $existing.Language
        LaunchedAt = $existing.LaunchedAt
        LastKnownCodexVersion = if ($Result.CodexVersion) { $Result.CodexVersion } else { $existing.LastKnownCodexVersion }
        LastLogHealthMaxId = if ($null -ne $Result.MaxId) { $Result.MaxId } else { $existing.LastLogHealthMaxId }
        LastLogHealthStatus = if ($Result.Status) { $Result.Status } else { $existing.LastLogHealthStatus }
        LastLogHealthCheckedAt = if ($Result.CheckedAt) { $Result.CheckedAt } else { $existing.LastLogHealthCheckedAt }
        LastBackupDir = if ($Result.BackupPath) { $Result.BackupPath } else { $existing.LastBackupDir }
    } | ConvertTo-Json -Depth 4 | Set-Content -Path $script:ConfigFile -Encoding UTF8
}

function Write-LauncherLog {
    param([string]$Message)

    try {
        Ensure-StateDir
        $line = "{0} {1}" -f (Get-Date).ToString("o"), $Message
        Add-Content -Path $script:LogFile -Encoding UTF8 -Value $line
    } catch {
    }
}

function T {
    param(
        [string]$Key,
        [object[]]$FormatArgs = @()
    )

    # UI strings live in one table so Chinese and English stay in sync.
    $texts = @{
        zh = @{
            port_status_on = "绿色：本地代理端口已开启，端口：{0}"
            port_status_off = "红色：本地代理端口未开启，端口：{0}"
            toggle_proxy_restart = "使用专用代理重启 Codex"
            menu_toggle_proxy_restart = "使用专用代理重启 Codex"
            tray_port_on = "Codex 代理端口：已开启"
            tray_port_off = "Codex 代理端口：未开启"
            startup_checkbox_v2 = "开机自动使用代理启动 Codex"
            monitor_start = "开始连续检测节点稳定性"
            monitor_stop = "停止连续检测节点稳定性"
            monitor_idle = "节点稳定性监测：未开启"
            monitor_waiting = "节点稳定性监测：运行中，等待首次检测..."
            monitor_invalid_port = "节点稳定性监测：端口无效，请先填写正确端口"
            monitor_summary = "节点稳定性监测：运行中，成功 {0} / 失败 {1}，成功率 {2}%，最近：{3}"
            monitor_ok = "通过"
            monitor_fail = "失败"
            menu_monitor_start = "开始连续检测节点稳定性"
            menu_monitor_stop = "停止连续检测节点稳定性"
            log_health_title = "日志健康"
            log_health_idle = "日志健康：尚未检查"
            log_health_status = "日志健康：{0}"
            log_health_details = "Codex：{0} | DB：{1} | WAL：{2} | MAX(id)：{3}`n10 秒增长：{4} | TRACE 占比：{5} | trigger：{6}`n最后检查：{7} | 备份：{8}"
            log_health_light_button = "一键巡检"
            log_health_full_button = "一键完整检查"
            log_health_block_button = "一键止血"
            log_health_restore_button = "一键恢复日志"
            log_health_open_backup_button = "打开备份目录"
            log_health_running = "检查中..."
            log_health_yes = "是"
            log_health_no = "否"
            log_health_missing = "无"
            log_health_confirm_block = "一键止血会先备份日志库，然后创建 SQLite trigger 阻止新日志写入 logs 表。继续？"
            log_health_confirm_restore = "恢复日志会删除 logs_block_all_inserts trigger，并重新评估日志健康状态。继续？"
            log_health_backup_missing = "还没有可打开的备份目录。"
            hint_v2 = "说明：顶部红绿状态只表示本地代理端口是否开启，不代表节点稳定。专用代理启动会短暂写入当前用户代理环境变量，启动后自动恢复，用来让 app-server 继承代理；不改系统代理。切换 VPN 节点不需要动这里，只有代理软件本地端口变了才改端口。"
            title = "Codex 专用代理启动器"
            lang_button = "EN"
            no_exe = "没有找到 Codex Desktop 的启动入口。请先手动打开一次 Codex，再重新使用这个启动器。"
            launch_fail = "启动 Codex 失败：{0}"
            invalid_port = "端口必须是 1 到 65535 之间的数字。"
            proxy_ok = "本地代理可以连通 OpenAI。`n端口：{0}"
            proxy_unclear = "没有确认连通。`n`n{0}"
            test_fail = "测试失败：{0}"
            startup_fail = "更新开机启动失败：{0}"
            unexpected_error = "操作失败：{0}"
            port_label = "代理软件本地端口"
            host_label = "本机地址：127.0.0.1"
            normal_button = "普通模式重启 Codex"
            test_button = "测试当前端口是否可用"
            startup_checkbox = "开机自动打开代理并启动 Codex"
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
            port_status_on = "Green: local proxy port is open. Port: {0}"
            port_status_off = "Red: local proxy port is closed. Port: {0}"
            toggle_proxy_restart = "Restart Codex using dedicated proxy"
            menu_toggle_proxy_restart = "Restart Codex using dedicated proxy"
            tray_port_on = "Codex proxy port: open"
            tray_port_off = "Codex proxy port: closed"
            startup_checkbox_v2 = "Start Codex in proxy mode with Windows"
            monitor_start = "Start continuous node stability check"
            monitor_stop = "Stop continuous node stability check"
            monitor_idle = "Node stability monitor: off"
            monitor_waiting = "Node stability monitor: running, waiting for first check..."
            monitor_invalid_port = "Node stability monitor: invalid port"
            monitor_summary = "Node stability monitor: running, passed {0} / failed {1}, success rate {2}%, latest: {3}"
            monitor_ok = "passed"
            monitor_fail = "failed"
            menu_monitor_start = "Start continuous node stability check"
            menu_monitor_stop = "Stop continuous node stability check"
            log_health_title = "Log health"
            log_health_idle = "Log health: not checked"
            log_health_status = "Log health: {0}"
            log_health_details = "Codex: {0} | DB: {1} | WAL: {2} | MAX(id): {3}`n10s delta: {4} | TRACE ratio: {5} | trigger: {6}`nLast check: {7} | Backup: {8}"
            log_health_light_button = "Quick check"
            log_health_full_button = "Full check"
            log_health_block_button = "Block writes"
            log_health_restore_button = "Restore logs"
            log_health_open_backup_button = "Open backups"
            log_health_running = "checking..."
            log_health_yes = "yes"
            log_health_no = "no"
            log_health_missing = "none"
            log_health_confirm_block = "Blocking writes will first back up the log database, then create a SQLite trigger that prevents new rows in logs. Continue?"
            log_health_confirm_restore = "Restoring logs will delete the logs_block_all_inserts trigger and re-check log health. Continue?"
            log_health_backup_missing = "No backup folder is available yet."
            hint_v2 = "The red/green indicator only shows whether the local proxy port is open; it does not prove node stability. Proxy launch briefly writes current-user proxy environment variables, then restores them after startup, so app-server can inherit the proxy. It does not change system proxy. Only update the port if your proxy app local port changes."
            title = "Codex Proxy Launcher"
            lang_button = "中文"
            no_exe = "Codex Desktop launch entry was not found. Open Codex once manually, then use this launcher again."
            launch_fail = "Failed to start Codex: {0}"
            invalid_port = "Port must be a number from 1 to 65535."
            proxy_ok = "Local proxy can reach OpenAI.`nPort: {0}"
            proxy_unclear = "Connectivity was not confirmed.`n`n{0}"
            test_fail = "Test failed: {0}"
            startup_fail = "Failed to update startup setting: {0}"
            unexpected_error = "Operation failed: {0}"
            port_label = "Proxy app local port"
            host_label = "Host: 127.0.0.1"
            normal_button = "Restart Codex normally"
            test_button = "Test current port"
            startup_checkbox = "Start proxy mode with Windows"
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

function Get-ProxyEnvironment {
    param([int]$Port)

    $proxyUrl = Get-ProxyUrl $Port
    @(
        [pscustomobject]@{ Name = "HTTP_PROXY"; Value = $proxyUrl },
        [pscustomobject]@{ Name = "HTTPS_PROXY"; Value = $proxyUrl },
        [pscustomobject]@{ Name = "ALL_PROXY"; Value = $proxyUrl },
        [pscustomobject]@{ Name = "http_proxy"; Value = $proxyUrl },
        [pscustomobject]@{ Name = "https_proxy"; Value = $proxyUrl },
        [pscustomobject]@{ Name = "all_proxy"; Value = $proxyUrl },
        [pscustomobject]@{ Name = "NO_PROXY"; Value = $script:NoProxy },
        [pscustomobject]@{ Name = "no_proxy"; Value = $script:NoProxy }
    )
}

function Set-ProxyEnvironment {
    param(
        [System.Diagnostics.ProcessStartInfo]$StartInfo,
        [int]$Port
    )

    foreach ($entry in (Get-ProxyEnvironment -Port $Port)) {
        $StartInfo.EnvironmentVariables[$entry.Name] = [string]$entry.Value
    }

    $StartInfo.EnvironmentVariables["CODEX_PROXY_SWITCH_MODE"] = "proxy"
    $StartInfo.EnvironmentVariables["CODEX_PROXY_SWITCH_PORT"] = [string]$Port
}

function Push-CurrentProcessProxyEnvironment {
    param([int]$Port)

    $previous = @{}
    $entries = @(Get-ProxyEnvironment -Port $Port)
    $entries += [pscustomobject]@{ Name = "CODEX_PROXY_SWITCH_MODE"; Value = "proxy" }
    $entries += [pscustomobject]@{ Name = "CODEX_PROXY_SWITCH_PORT"; Value = [string]$Port }

    foreach ($entry in $entries) {
        if (-not $previous.ContainsKey($entry.Name)) {
            $oldValue = [Environment]::GetEnvironmentVariable($entry.Name, "Process")
            $previous[$entry.Name] = [pscustomobject]@{
                Name = $entry.Name
                Value = $oldValue
                Existed = $null -ne $oldValue
            }
        }

        [Environment]::SetEnvironmentVariable($entry.Name, [string]$entry.Value, "Process")
    }

    return @($previous.Values)
}

function Pop-CurrentProcessProxyEnvironment {
    param([object[]]$Previous)

    foreach ($entry in $Previous) {
        $value = if ($entry.Existed) { [string]$entry.Value } else { $null }
        [Environment]::SetEnvironmentVariable($entry.Name, $value, "Process")
    }
}

function Publish-EnvironmentChange {
    try {
        if (-not ("CodexProxyEnvironmentChange" -as [type])) {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class CodexProxyEnvironmentChange {
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd,
        int msg,
        IntPtr wParam,
        string lParam,
        int flags,
        int timeout,
        out IntPtr result);
}
"@
        }

        $result = [IntPtr]::Zero
        [void][CodexProxyEnvironmentChange]::SendMessageTimeout([IntPtr]0xffff, 0x1a, [IntPtr]::Zero, "Environment", 0x2, 1000, [ref]$result)
    } catch {
        Write-LauncherLog ("Environment change broadcast failed: {0}" -f $_.Exception.Message)
    }
}

function Read-ManagedUserProxyEnvironmentState {
    if (-not (Test-Path -LiteralPath $script:ManagedUserEnvFile)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $script:ManagedUserEnvFile -Raw | ConvertFrom-Json
    } catch {
        Write-LauncherLog ("Failed to read managed user proxy environment state: {0}" -f $_.Exception.Message)
        return $null
    }
}

function New-UserProxyEnvironmentBackup {
    $names = Get-ProxyEnvironment -Port $script:DefaultPort | Select-Object -ExpandProperty Name
    foreach ($name in $names) {
        $oldValue = [Environment]::GetEnvironmentVariable($name, "User")
        [pscustomobject]@{
            Name = $name
            Value = $oldValue
            Existed = $null -ne $oldValue
        }
    }
}

function Enable-ManagedUserProxyEnvironment {
    param([int]$Port)

    Ensure-StateDir
    $existingState = Read-ManagedUserProxyEnvironmentState
    if ($existingState -and $existingState.Active -eq $true -and $existingState.Entries) {
        $backupEntries = @($existingState.Entries)
        $backupCreated = $false
    } else {
        $backupEntries = @(New-UserProxyEnvironmentBackup)
        $backupCreated = $true
    }

    $state = [pscustomobject]@{
        Version = 1
        Active = $true
        Port = $Port
        AppliedAt = (Get-Date).ToString("o")
        Entries = $backupEntries
    }
    $state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:ManagedUserEnvFile -Encoding UTF8

    foreach ($entry in (Get-ProxyEnvironment -Port $Port)) {
        [Environment]::SetEnvironmentVariable($entry.Name, [string]$entry.Value, "User")
    }

    Publish-EnvironmentChange

    $proxyUrl = Get-ProxyUrl $Port
    $httpSet = [Environment]::GetEnvironmentVariable("HTTP_PROXY", "User") -eq $proxyUrl
    $httpsSet = [Environment]::GetEnvironmentVariable("HTTPS_PROXY", "User") -eq $proxyUrl
    $allSet = [Environment]::GetEnvironmentVariable("ALL_PROXY", "User") -eq $proxyUrl
    Write-LauncherLog ("Managed user proxy environment enabled: Port={0}; HTTP_PROXY={1}; HTTPS_PROXY={2}; ALL_PROXY={3}; BackupCreated={4}" -f $Port, $httpSet, $httpsSet, $allSet, $backupCreated)
}

function Disable-ManagedUserProxyEnvironment {
    param([string]$Reason = "restore")

    $state = Read-ManagedUserProxyEnvironmentState
    if (-not $state -or $state.Active -ne $true -or -not $state.Entries) {
        return $false
    }

    $entries = @($state.Entries)
    foreach ($entry in $entries) {
        $value = if ($entry.Existed) { [string]$entry.Value } else { $null }
        [Environment]::SetEnvironmentVariable([string]$entry.Name, $value, "User")
    }

    Remove-Item -LiteralPath $script:ManagedUserEnvFile -Force -ErrorAction SilentlyContinue
    Publish-EnvironmentChange
    Write-LauncherLog ("Managed user proxy environment restored: Reason={0}; EntryCount={1}" -f $Reason, $entries.Count)
    return $true
}

function Format-CodexCommandForLog {
    param(
        [string]$ExePath,
        [string]$Arguments
    )

    $command = Quote-CommandArgument $ExePath
    if (-not [string]::IsNullOrWhiteSpace($Arguments)) {
        $command += " $Arguments"
    }

    return $command
}

function Show-AppError {
    param([string]$Message)

    try {
        $body = T "unexpected_error" $Message
        $caption = T "title"
    } catch {
        $body = "操作失败：$Message"
        $caption = "Codex 专用代理启动器"
    }

    [System.Windows.Forms.MessageBox]::Show($body, $caption, "OK", "Error") | Out-Null
}

function Invoke-Safely {
    param(
        [scriptblock]$Action,
        [switch]$Silent
    )

    try {
        & $Action
    } catch {
        if (-not $Silent) {
            Show-AppError $_.Exception.Message
        }
    }
}

function Quote-CommandArgument {
    param([string]$Value)
    '"' + $Value.Replace('"', '\"') + '"'
}

function Get-PowerShellPath {
    $candidate = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) "WindowsPowerShell\v1.0\powershell.exe"
    if (Test-Path -LiteralPath $candidate) {
        return $candidate
    }

    return "powershell.exe"
}

function Get-StartupShortcutPath {
    $startupDir = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
    Join-Path $startupDir "Codex Proxy Launcher.lnk"
}

# Early versions wrote an HKCU Run entry. Current versions use a Startup-folder
# shortcut only, so remove the old key whenever the launcher has a chance.
function Remove-LegacyStartupEntry {
    $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    Remove-ItemProperty -LiteralPath $runKey -Name "CodexProxyLauncherAutoStart" -Force -ErrorAction SilentlyContinue
}

function Get-StartupShortcutTargetPath {
    param([string]$ShortcutPath = $(Get-StartupShortcutPath))

    if (-not (Test-Path -LiteralPath $ShortcutPath)) {
        return $null
    }

    $shell = $null
    $shortcut = $null

    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($ShortcutPath)
        return [string]$shortcut.TargetPath
    } finally {
        if ($shortcut) {
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut)
        }
        if ($shell) {
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
        }
    }
}

function Test-StartupEnabled {
    $shortcutPath = Get-StartupShortcutPath
    $targetPath = Get-StartupShortcutTargetPath
    if (-not [string]::IsNullOrWhiteSpace($targetPath) -and (Test-Path -LiteralPath $targetPath)) {
        return $true
    }

    if (-not (Test-Path -LiteralPath $shortcutPath)) {
        return $false
    }

    # A stale shortcut means the user moved to a newer unpacked release. Repair
    # it in place so the checkbox reflects the current package rather than an
    # old broken target.
    try {
        Set-StartupEnabled -Enabled $true
        $targetPath = Get-StartupShortcutTargetPath
        return (-not [string]::IsNullOrWhiteSpace($targetPath) -and (Test-Path -LiteralPath $targetPath))
    } catch {
        return $false
    }
}

function Set-StartupEnabled {
    param([bool]$Enabled)

    Remove-LegacyStartupEntry
    $shortcutPath = Get-StartupShortcutPath

    if (-not $Enabled) {
        Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction SilentlyContinue
        return
    }

    $shell = $null
    $shortcut = $null

    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $appDir = (Resolve-Path -LiteralPath $script:AppDir -ErrorAction Stop).Path

        $exePath = Join-Path $appDir "CodexProxyLauncher.exe"
        if (Test-Path -LiteralPath $exePath) {
            $exePath = (Resolve-Path -LiteralPath $exePath -ErrorAction Stop).Path
            $shortcut.TargetPath = $exePath
            $shortcut.Arguments = "-AutoStartProxy -StartMinimized"
            $shortcut.IconLocation = "$exePath,0"
        } else {
            $scriptPath = (Resolve-Path -LiteralPath (Join-Path $appDir "codex-only-proxy-launcher.ps1") -ErrorAction Stop).Path
            $powerShellPath = Get-PowerShellPath
            $shortcut.TargetPath = $powerShellPath
            $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $(Quote-CommandArgument $scriptPath) -AutoStartProxy -StartMinimized"
            $shortcut.IconLocation = "$powerShellPath,0"
        }

        $shortcut.WorkingDirectory = $appDir
        $shortcut.Description = "Start Codex through the dedicated local proxy at Windows sign-in."
        $shortcut.Save()

        $savedTargetPath = Get-StartupShortcutTargetPath -ShortcutPath $shortcutPath
        if ([string]::IsNullOrWhiteSpace($savedTargetPath) -or -not (Test-Path -LiteralPath $savedTargetPath)) {
            throw "The startup shortcut target is invalid: $savedTargetPath"
        }
    } finally {
        if ($shortcut) {
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut)
        }
        if ($shell) {
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
        }
    }
}

function Test-LocalProxyPort {
    param(
        [int]$Port,
        [int]$TimeoutMilliseconds = 250
    )

    $client = $null
    $async = $null

    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $async = $client.BeginConnect($script:ProxyHost, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMilliseconds)) {
            return $false
        }

        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        if ($async -and $async.AsyncWaitHandle) {
            $async.AsyncWaitHandle.Close()
        }
        if ($client) {
            $client.Close()
        }
    }
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
                if ($_.ProcessName -eq "Codex") {
                    return $true
                }

                -not [string]::IsNullOrWhiteSpace($_.Path) -and
                (
                    $_.Path -like "*\OpenAI.Codex_*" -or
                    $_.Path -like "*\AppData\Local\OpenAI\Codex\bin\*"
                )
            } catch {
                $_.ProcessName -eq "Codex"
            }
        } |
        Sort-Object Id -Unique
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
    for ($attempt = 0; $attempt -lt 6; $attempt++) {
        $processes = @(Get-CodexProcesses)
        if ($processes.Count -eq 0) {
            return
        }

        foreach ($process in $processes) {
            try {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            } catch {
            }
        }

        Start-Sleep -Milliseconds 700
    }
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

    # Codex Desktop is usually installed as a packaged Windows app. Starting it
    # by raw WindowsApps path is unreliable, so use the official app activation
    # COM API and pass Electron launch arguments through that activation path.
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
    return [int][AppActivation.ApplicationActivator]::Activate($appId, $Arguments)
}

function Wait-CodexAppServerProcess {
    param(
        [int]$ParentProcessId,
        [int]$TimeoutSeconds = 8
    )

    if ($ParentProcessId -le 0) {
        return $false
    }

    $deadline = (Get-Date).AddSeconds([Math]::Max(1, $TimeoutSeconds))
    do {
        $server = Get-CimInstance Win32_Process -Filter "ParentProcessId=$ParentProcessId" -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -ieq "codex.exe" -and
                $_.CommandLine -match "\\resources\\codex\.exe.*app-server"
            } |
            Select-Object -First 1

        if ($server) {
            Write-LauncherLog ("App-server process detected: ParentPid={0}; AppServerPid={1}" -f $ParentProcessId, $server.ProcessId)
            return $true
        }

        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)

    Write-LauncherLog ("App-server process was not detected before restore: ParentPid={0}; TimeoutSeconds={1}" -f $ParentProcessId, $TimeoutSeconds)
    return $false
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
    $proxyUrl = $null

    if ($ProxyMode) {
        $proxyUrl = Get-ProxyUrl $Port
        $arguments = "--proxy-server=$proxyUrl --proxy-bypass-list=localhost;127.0.0.1;::1"
    } else {
        [void](Disable-ManagedUserProxyEnvironment -Reason "normal-mode launch")
    }

    Write-LauncherLog ("Start-Codex requested. Mode={0}; Port={1}; ProxyUrl={2}; Exe={3}" -f $(if ($ProxyMode) { "proxy" } else { "normal" }), $Port, $(if ($proxyUrl) { $proxyUrl } else { "" }), $exe)
    Write-LauncherLog ("Codex command: {0}" -f (Format-CodexCommandForLog -ExePath $exe -Arguments $arguments))

    try {
        if ($exe -like "*\WindowsApps\*" -and -not $ProxyMode) {
            Write-LauncherLog "Launch method: packaged activation; proxy environment injected: false"
            [void](Start-PackagedCodex -Arguments $arguments)
        } else {
            try {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = $exe
                $psi.WorkingDirectory = Split-Path $exe -Parent
                $psi.UseShellExecute = $false
                $psi.Arguments = $arguments

                if ($ProxyMode) {
                    Set-ProxyEnvironment -StartInfo $psi -Port $Port
                    Write-LauncherLog ("Proxy environment injected: HTTP_PROXY=true; HTTPS_PROXY=true; ALL_PROXY=true; NO_PROXY={0}" -f $script:NoProxy)
                } else {
                    Write-LauncherLog "Proxy environment injected: false"
                }

                [System.Diagnostics.Process]::Start($psi) | Out-Null
                Write-LauncherLog "Launch method: direct process"
            } catch {
                if ($exe -like "*\WindowsApps\*" -and $ProxyMode) {
                    Write-LauncherLog ("Direct process launch failed: {0}" -f $_.Exception.Message)
                    $previousEnvironment = $null
                    $managedUserEnvironmentEnabled = $false
                    try {
                        $previousEnvironment = Push-CurrentProcessProxyEnvironment -Port $Port
                        $managedUserEnvironmentEnabled = $true
                        Enable-ManagedUserProxyEnvironment -Port $Port
                        Write-LauncherLog "Fallback process environment prepared: HTTP_PROXY=true; HTTPS_PROXY=true; ALL_PROXY=true"
                        Write-LauncherLog "Fallback user environment prepared: HTTP_PROXY=true; HTTPS_PROXY=true; ALL_PROXY=true"
                        Write-LauncherLog "Launch method: packaged activation fallback; process and current-user environment temporarily set; --proxy-server arguments preserved"
                        $activatedProcessId = Start-PackagedCodex -Arguments $arguments
                        Write-LauncherLog ("Packaged activation returned process id: {0}" -f $activatedProcessId)
                        [void](Wait-CodexAppServerProcess -ParentProcessId $activatedProcessId -TimeoutSeconds 8)
                    } finally {
                        if ($previousEnvironment) {
                            Pop-CurrentProcessProxyEnvironment -Previous $previousEnvironment
                            Write-LauncherLog "Fallback process environment restored"
                        }
                        if ($managedUserEnvironmentEnabled) {
                            [void](Disable-ManagedUserProxyEnvironment -Reason "post-launch restore")
                        }
                    }
                } else {
                    throw
                }
            }
        }
    } catch {
        Write-LauncherLog ("Launch failed: {0}" -f $_.Exception.Message)
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
            -ArgumentList @(
                "--ssl-no-revoke",
                "-sS",
                "-o", "NUL",
                "-w", "HTTP_CODE:%{http_code}`nEXIT_CODE:%{exitcode}`nERROR:%{errormsg}`n",
                "--max-time", "15",
                "--proxy", (Get-ProxyUrl $Port),
                "https://api.openai.com"
            ) `
            -WindowStyle Hidden `
            -RedirectStandardOutput $tempOut `
            -RedirectStandardError $tempErr `
            -Wait `
            -PassThru

        $output = ""
        if (Test-Path $tempOut) { $output += Get-Content $tempOut -Raw }
        if (Test-Path $tempErr) { $output += Get-Content $tempErr -Raw }

        $httpCode = if ($output -match "HTTP_CODE:(\d{3})") { [int]$Matches[1] } else { 0 }

        if ($process.ExitCode -eq 0 -and $httpCode -ge 200 -and $httpCode -lt 500) {
            [System.Windows.Forms.MessageBox]::Show((T "proxy_ok" $Port), (T "title"), "OK", "Information") | Out-Null
        } else {
            [System.Windows.Forms.MessageBox]::Show((T "proxy_unclear" $output), (T "title"), "OK", "Warning") | Out-Null
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show((T "test_fail" $_.Exception.Message), (T "title"), "OK", "Error") | Out-Null
    } finally {
        Remove-Item $tempOut, $tempErr -ErrorAction SilentlyContinue
    }
}

function Reset-StabilityMonitorStats {
    param([int]$Port = 0)

    $script:MonitorPort = $Port
    $script:MonitorSuccessCount = 0
    $script:MonitorFailureCount = 0
    $script:MonitorLastState = "idle"
    $script:MonitorNextCheckAt = Get-Date
}

function Stop-StabilityProbe {
    if (-not $script:MonitorProcess) {
        return
    }

    try {
        if (-not $script:MonitorProcess.HasExited) {
            $script:MonitorProcess.Kill()
        }
    } catch {
    } finally {
        try {
            $script:MonitorProcess.Dispose()
        } catch {
        }
        $script:MonitorProcess = $null
    }
}

function Start-StabilityProbe {
    param([int]$Port)

    if ($script:MonitorProcess) {
        return
    }

    # A probe is intentionally just curl through the configured local port. It
    # does not start Codex, change system proxy, or touch VPN settings.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "curl.exe"
    $psi.Arguments = '--ssl-no-revoke -sS -o NUL -w "HTTP_CODE:%{http_code}" --max-time 12 --proxy "' + (Get-ProxyUrl $Port) + '" "https://api.openai.com"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $script:MonitorProcess = [System.Diagnostics.Process]::Start($psi)
}

function Complete-StabilityProbe {
    if (-not $script:MonitorProcess) {
        return
    }

    try {
        if (-not $script:MonitorProcess.HasExited) {
            return
        }

        $output = $script:MonitorProcess.StandardOutput.ReadToEnd()
        $output += $script:MonitorProcess.StandardError.ReadToEnd()
        $httpCode = if ($output -match "HTTP_CODE:(\d{3})") { [int]$Matches[1] } else { 0 }

        if ($script:MonitorProcess.ExitCode -eq 0 -and $httpCode -ge 200 -and $httpCode -lt 500) {
            $script:MonitorSuccessCount++
            $script:MonitorLastState = "ok"
        } else {
            $script:MonitorFailureCount++
            $script:MonitorLastState = "fail"
        }
    } catch {
        $script:MonitorFailureCount++
        $script:MonitorLastState = "fail"
    } finally {
        try {
            $script:MonitorProcess.Dispose()
        } catch {
        }
        $script:MonitorProcess = $null
        $script:MonitorNextCheckAt = (Get-Date).AddSeconds(5)
    }
}

function Update-StabilityMonitorUi {
    $monitorButton.Text = if ($script:MonitorEnabled) { T "monitor_stop" } else { T "monitor_start" }
    $menuMonitor.Text = if ($script:MonitorEnabled) { T "menu_monitor_stop" } else { T "menu_monitor_start" }

    if (-not $script:MonitorEnabled) {
        $monitorLabel.Text = T "monitor_idle"
        $monitorLabel.ForeColor = [System.Drawing.SystemColors]::ControlText
        return
    }

    $total = $script:MonitorSuccessCount + $script:MonitorFailureCount
    if ($total -eq 0) {
        $monitorLabel.Text = T "monitor_waiting"
        $monitorLabel.ForeColor = [System.Drawing.SystemColors]::ControlText
        return
    }

    $successRate = [Math]::Round(($script:MonitorSuccessCount * 100.0) / $total)
    $lastState = if ($script:MonitorLastState -eq "ok") { T "monitor_ok" } else { T "monitor_fail" }
    $monitorLabel.Text = T "monitor_summary" @($script:MonitorSuccessCount, $script:MonitorFailureCount, $successRate, $lastState)
    $monitorLabel.ForeColor = if ($script:MonitorLastState -eq "ok") {
        [System.Drawing.Color]::FromArgb(28, 140, 74)
    } else {
        [System.Drawing.Color]::FromArgb(200, 45, 45)
    }
}

function Stop-StabilityMonitor {
    Stop-StabilityProbe
    $script:MonitorEnabled = $false
    Reset-StabilityMonitorStats
    Update-StabilityMonitorUi
}

function Start-StabilityMonitor {
    $port = Parse-PortFromTextBox $portBox
    if ($null -eq $port) {
        return
    }

    Stop-StabilityProbe
    Reset-StabilityMonitorStats -Port $port
    $script:MonitorEnabled = $true
    Start-StabilityProbe -Port $port
    Update-StabilityMonitorUi
}

function Invoke-StabilityMonitorTick {
    Complete-StabilityProbe

    if (-not $script:MonitorEnabled) {
        return
    }

    $port = 0
    if (-not [int]::TryParse($portBox.Text.Trim(), [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        Stop-StabilityProbe
        Reset-StabilityMonitorStats
        $monitorLabel.Text = T "monitor_invalid_port"
        $monitorLabel.ForeColor = [System.Drawing.Color]::FromArgb(200, 45, 45)
        return
    }

    if ($port -ne $script:MonitorPort) {
        Stop-StabilityProbe
        Reset-StabilityMonitorStats -Port $port
    }

    if (-not $script:MonitorProcess -and (Get-Date) -ge $script:MonitorNextCheckAt) {
        Start-StabilityProbe -Port $port
    }

    Update-StabilityMonitorUi
}

function Toggle-StabilityMonitor {
    if ($script:MonitorEnabled) {
        Stop-StabilityMonitor
    } else {
        Start-StabilityMonitor
    }
}

if (Test-Path -LiteralPath $script:LogHealthModule) {
    . $script:LogHealthModule
}

if ($RunLogHealthSelfTest) {
    Invoke-LogHealthSelfTest
    exit 0
}

if ($ValidateOnly) {
    Ensure-AppActivationType
    Write-Host "Codex-only launcher script parsed successfully."
    exit 0
}

[System.Windows.Forms.Application]::EnableVisualStyles()

# Clean legacy startup state before reading config or drawing the checkbox.
Remove-LegacyStartupEntry
$config = Read-Config
$script:Language = $config.Language
[void](Disable-ManagedUserProxyEnvironment -Reason "startup cleanup")

if ($AutoStartProxy) {
    $autoPort = if ($config.Port -as [int]) { [int]$config.Port } else { $script:DefaultPort }
    if (Wait-LocalProxyPort -Port $autoPort -TimeoutSeconds $AutoStartTimeoutSeconds) {
        Stop-CodexProcesses
        [void](Start-Codex -Port $autoPort -ProxyMode)
        $config = Read-Config
    }
}

# Build the compact WinForms UI directly in this script. The layout is fixed so
# the launcher stays dependency-free and easy to package as a single EXE wrapper.
$form = New-Object System.Windows.Forms.Form
$form.Text = T "title"
$form.Size = New-Object System.Drawing.Size(620, 650)
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

$monitorButton = New-Object System.Windows.Forms.Button
$monitorButton.Text = T "monitor_start"
$monitorButton.Location = New-Object System.Drawing.Point(22, 190)
$monitorButton.Size = New-Object System.Drawing.Size(560, 34)
$monitorButton.FlatStyle = "System"

$monitorLabel = New-Object System.Windows.Forms.Label
$monitorLabel.Text = T "monitor_idle"
$monitorLabel.Location = New-Object System.Drawing.Point(22, 232)
$monitorLabel.Size = New-Object System.Drawing.Size(560, 24)

$startupCheckBox = New-Object System.Windows.Forms.CheckBox
$startupCheckBox.Text = T "startup_checkbox_v2"
$startupCheckBox.Location = New-Object System.Drawing.Point(22, 262)
$startupCheckBox.Size = New-Object System.Drawing.Size(560, 24)
$startupCheckBox.Checked = Test-StartupEnabled

$logHealthGroup = New-Object System.Windows.Forms.GroupBox
$logHealthGroup.Text = T "log_health_title"
$logHealthGroup.Location = New-Object System.Drawing.Point(22, 296)
$logHealthGroup.Size = New-Object System.Drawing.Size(560, 190)

$logHealthStatusLabel = New-Object System.Windows.Forms.Label
$logHealthStatusLabel.Text = T "log_health_idle"
$logHealthStatusLabel.Location = New-Object System.Drawing.Point(12, 24)
$logHealthStatusLabel.Size = New-Object System.Drawing.Size(536, 22)

$logHealthDetailsLabel = New-Object System.Windows.Forms.Label
$logHealthDetailsLabel.Location = New-Object System.Drawing.Point(12, 50)
$logHealthDetailsLabel.Size = New-Object System.Drawing.Size(536, 58)

$logHealthLightButton = New-Object System.Windows.Forms.Button
$logHealthLightButton.Location = New-Object System.Drawing.Point(12, 116)
$logHealthLightButton.Size = New-Object System.Drawing.Size(102, 28)
$logHealthLightButton.FlatStyle = "System"

$logHealthFullButton = New-Object System.Windows.Forms.Button
$logHealthFullButton.Location = New-Object System.Drawing.Point(120, 116)
$logHealthFullButton.Size = New-Object System.Drawing.Size(112, 28)
$logHealthFullButton.FlatStyle = "System"

$logHealthBlockButton = New-Object System.Windows.Forms.Button
$logHealthBlockButton.Location = New-Object System.Drawing.Point(238, 116)
$logHealthBlockButton.Size = New-Object System.Drawing.Size(96, 28)
$logHealthBlockButton.FlatStyle = "System"

$logHealthRestoreButton = New-Object System.Windows.Forms.Button
$logHealthRestoreButton.Location = New-Object System.Drawing.Point(340, 116)
$logHealthRestoreButton.Size = New-Object System.Drawing.Size(108, 28)
$logHealthRestoreButton.FlatStyle = "System"

$logHealthBackupButton = New-Object System.Windows.Forms.Button
$logHealthBackupButton.Location = New-Object System.Drawing.Point(454, 116)
$logHealthBackupButton.Size = New-Object System.Drawing.Size(94, 28)
$logHealthBackupButton.FlatStyle = "System"

$logHealthGroup.Controls.AddRange(@($logHealthStatusLabel, $logHealthDetailsLabel, $logHealthLightButton, $logHealthFullButton, $logHealthBlockButton, $logHealthRestoreButton, $logHealthBackupButton))
$script:LogHealthUiReady = $true

$hintLabel = New-Object System.Windows.Forms.Label
$hintLabel.Text = T "hint_v2"
$hintLabel.Location = New-Object System.Drawing.Point(22, 500)
$hintLabel.Size = New-Object System.Drawing.Size(560, 88)

$form.Controls.AddRange(@($languageButton, $statusDot, $statusLabel, $portLabel, $portBox, $hostLabel, $toggleButton, $normalButton, $testButton, $monitorButton, $monitorLabel, $startupCheckBox, $logHealthGroup, $hintLabel))

$contextMenu = New-Object System.Windows.Forms.ContextMenuStrip
$menuOpen = New-Object System.Windows.Forms.ToolStripMenuItem (T "menu_open")
$menuToggle = New-Object System.Windows.Forms.ToolStripMenuItem
$menuNormal = New-Object System.Windows.Forms.ToolStripMenuItem (T "menu_normal")
$menuTest = New-Object System.Windows.Forms.ToolStripMenuItem (T "menu_test")
$menuMonitor = New-Object System.Windows.Forms.ToolStripMenuItem (T "menu_monitor_start")
$menuExit = New-Object System.Windows.Forms.ToolStripMenuItem (T "menu_exit")
[void]$contextMenu.Items.Add($menuOpen)
[void]$contextMenu.Items.Add($menuToggle)
[void]$contextMenu.Items.Add($menuNormal)
[void]$contextMenu.Items.Add($menuTest)
[void]$contextMenu.Items.Add($menuMonitor)
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
    $monitorButton.Text = if ($script:MonitorEnabled) { T "monitor_stop" } else { T "monitor_start" }
    $startupCheckBox.Text = T "startup_checkbox_v2"
    $logHealthGroup.Text = T "log_health_title"
    $logHealthLightButton.Text = T "log_health_light_button"
    $logHealthFullButton.Text = T "log_health_full_button"
    $logHealthBlockButton.Text = T "log_health_block_button"
    $logHealthRestoreButton.Text = T "log_health_restore_button"
    $logHealthBackupButton.Text = T "log_health_open_backup_button"
    $hintLabel.Text = T "hint_v2"
    $menuOpen.Text = T "menu_open"
    $menuNormal.Text = T "menu_normal"
    $menuTest.Text = T "menu_test"
    $menuMonitor.Text = if ($script:MonitorEnabled) { T "menu_monitor_stop" } else { T "menu_monitor_start" }
    $menuExit.Text = T "menu_exit"
    Update-Ui
    Update-StabilityMonitorUi
    Update-LogHealthUi
}

function Update-Ui {
    $port = 0
    [void][int]::TryParse($portBox.Text.Trim(), [ref]$port)
    # The green/red indicator answers only one question: is the local proxy
    # port open? Node quality is handled separately by the stability monitor.
    $isProxyRunning = if ($port -gt 0) { Test-CodexProxyModeRunning $port } else { $false }
    $isPortOpen = if ($port -gt 0) { Test-LocalProxyPort -Port $port } else { $false }

    if ($isPortOpen) {
        $statusDot.BackColor = [System.Drawing.Color]::FromArgb(28, 172, 84)
        $statusLabel.Text = T "port_status_on" $port
        $notifyIcon.Icon = New-StateIcon $true
        $notifyIcon.Text = T "tray_port_on"
    } else {
        $statusDot.BackColor = [System.Drawing.Color]::FromArgb(220, 55, 55)
        $statusLabel.Text = T "port_status_off" $port
        $notifyIcon.Icon = New-StateIcon $false
        $notifyIcon.Text = T "tray_port_off"
    }

    if ($isProxyRunning) {
        $toggleButton.Text = T "toggle_on"
        $menuToggle.Text = T "menu_toggle_on"
    } else {
        $toggleButton.Text = T "toggle_proxy_restart"
        $menuToggle.Text = T "menu_toggle_proxy_restart"
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

$languageButton.Add_Click({ Invoke-Safely {
    $script:Language = if ($script:Language -eq "zh") { "en" } else { "zh" }
    Save-LanguagePreference
    Update-LanguageUi
} })
$toggleButton.Add_Click({ Invoke-Safely { Invoke-Toggle } })
$normalButton.Add_Click({ Invoke-Safely { Start-NormalMode } })
$testButton.Add_Click({ Invoke-Safely {
    $port = Parse-PortFromTextBox $portBox
    if ($null -ne $port) { Test-OpenAIProxy $port }
} })
$monitorButton.Add_Click({ Invoke-Safely { Toggle-StabilityMonitor } })
$logHealthLightButton.Add_Click({ Invoke-Safely { Start-LogHealthLightCheck -AllowFullCheck } })
$logHealthFullButton.Add_Click({ Invoke-Safely { Start-LogHealthFullCheck } })
$logHealthBlockButton.Add_Click({ Invoke-Safely { Invoke-LogHealthBlockWrites } })
$logHealthRestoreButton.Add_Click({ Invoke-Safely { Invoke-LogHealthRestoreWrites } })
$logHealthBackupButton.Add_Click({ Invoke-Safely { Open-LogHealthBackupDirectory } })
$startupCheckBox.Add_CheckedChanged({ Invoke-Safely {
    if ($script:SyncingStartupUi) {
        return
    }

    try {
        Set-StartupEnabled -Enabled $startupCheckBox.Checked
    } catch {
        [System.Windows.Forms.MessageBox]::Show((T "startup_fail" $_.Exception.Message), (T "title"), "OK", "Error") | Out-Null
        $script:SyncingStartupUi = $true
        $startupCheckBox.Checked = Test-StartupEnabled
        $script:SyncingStartupUi = $false
    }
} })
$menuToggle.Add_Click({ Invoke-Safely { Invoke-Toggle } })
$menuNormal.Add_Click({ Invoke-Safely { Start-NormalMode } })
$menuTest.Add_Click({ Invoke-Safely {
    $port = Parse-PortFromTextBox $portBox
    if ($null -ne $port) { Test-OpenAIProxy $port }
} })
$menuMonitor.Add_Click({ Invoke-Safely { Toggle-StabilityMonitor } })
$menuOpen.Add_Click({ Invoke-Safely {
    $form.Show()
    $form.WindowState = "Normal"
    $form.Activate()
} })
$notifyIcon.Add_DoubleClick({ Invoke-Safely {
    $form.Show()
    $form.WindowState = "Normal"
    $form.Activate()
} })
$menuExit.Add_Click({ Invoke-Safely {
    $script:ExitRequested = $true
    Stop-StabilityMonitor
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    Dispose-StateIcons
    $form.Close()
} })
$form.Add_FormClosing({
    if (-not $script:ExitRequested -and $_.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
        $_.Cancel = $true
        $form.Hide()
    }
})
$portBox.Add_TextChanged({ Invoke-Safely { Update-Ui } -Silent })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2500
$timer.Add_Tick({ Invoke-Safely {
    Update-Ui
    Invoke-StabilityMonitorTick
    Invoke-LogHealthTick
} -Silent })
$timer.Start()

Invoke-Safely { Update-LanguageUi } -Silent
Invoke-Safely { Start-LogHealthLightCheck -AllowFullCheck } -Silent
if ($StartMinimized) {
    $form.Add_Shown({ Invoke-Safely { $form.Hide() } -Silent })
}
[System.Windows.Forms.Application]::Run($form)

