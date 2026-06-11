# 代码维护地图

更新时间：2026-06-05

## 为什么不在生产代码里逐行注释

逐行注释会让这个项目更难维护：

- 每改一行逻辑，就要同步改一行注释。
- 注释很容易过期，过期注释比没有注释更危险。
- PowerShell 脚本本身已经较长，逐行注释会降低定位速度。

当前做法：

- 生产代码只保留关键逻辑块注释。
- 本文件记录每个模块的职责、边界和风险点。
- 新增功能先写清楚产品边界，再改代码。

## 文件职责

| 文件 | 职责 |
| --- | --- |
| `codex-only-proxy-launcher.ps1` | 主程序，包含配置、UI、启动 Codex、代理测试、连续监测、开机启动 |
| `src/CodexProxyLauncherBootstrap.cs` | 很小的 EXE 包装器，负责静默启动 PowerShell 主脚本 |
| `scripts/build-release.ps1` | 生成图标、编译 EXE、复制发布文件、压缩 ZIP |
| `codex-only-proxy-launcher.cmd` | 备用入口，调用 VBS 静默启动 |
| `start-codex-only-proxy-launcher.vbs` | 备用静默入口，调用 PowerShell 主脚本 |
| `README.md` | 项目首页说明 |
| `CHANGELOG.md` | 版本变化记录 |
| `docs/PRODUCT.md` | 产品边界、当前状态、使用流程 |

## 主脚本结构

### 参数区

```powershell
param(...)
```

入口参数：

- `-ValidateOnly`：只做脚本解析和核心类型加载校验。
- `-AutoStartProxy`：开机启动时使用，等待代理端口后启动 Codex。
- `-AutoStartTimeoutSeconds`：开机等待代理端口的最长时间。
- `-StartMinimized`：启动后隐藏到托盘。

### 全局状态区

包含：

- 应用目录。
- 配置文件路径。
- 默认代理主机和端口。
- 托盘图标缓存。
- 开机启动 UI 同步标记。
- 连续监测状态。

这部分变量会被 WinForms 事件和计时器共享，因此不要随意改名。

### 配置读写

函数：

- `Ensure-StateDir`
- `Read-Config`
- `Save-Config`

配置文件：

```text
%LOCALAPPDATA%\CodexProxySwitch\codex-only-launcher.json
```

保存内容：

- `Port`
- `Mode`
- `Language`
- `LaunchedAt`

### 文案系统

函数：

- `T`

中文和英文文案都在 `T` 函数内部。新增按钮、菜单、状态时，必须同时加中文和英文。

### 开机启动

函数：

- `Get-StartupShortcutPath`
- `Remove-LegacyStartupEntry`
- `Get-StartupShortcutTargetPath`
- `Test-StartupEnabled`
- `Set-StartupEnabled`

当前策略：

- 使用 Startup 文件夹 `.lnk`。
- 每次打开时清理早期版本遗留的注册表 Run 项。
- 检测到旧快捷方式目标失效时尝试自动修复。

风险点：

- 用户移动了解压目录后，旧快捷方式会失效。
- Windows 启动文件夹权限异常时，勾选开机启动会失败。

### 本地端口检测

函数：

- `Test-LocalProxyPort`
- `Wait-LocalProxyPort`

作用：

- 只检测 `127.0.0.1:<端口>` 是否有程序监听。
- 不代表 OpenAI 可访问。
- 不代表节点稳定。

### Codex 进程定位和关闭

函数：

- `Find-CodexDesktopExe`
- `Get-CodexProcesses`
- `Test-CodexProxyModeRunning`
- `Test-AnyCodexRunning`
- `Stop-CodexProcesses`

注意：

- `Get-CodexProcesses` 会按进程 ID 去重。
- `Test-CodexProxyModeRunning` 是辅助判断，它依赖最近保存的启动模式，不能证明当前进程一定继承了代理。

### WindowsApps 启动路径

函数：

- `Get-CodexAppUserModelId`
- `Ensure-AppActivationType`
- `Start-PackagedCodex`

原因：

Codex Desktop 通常装在 `C:\Program Files\WindowsApps`。直接启动这个目录下的 EXE 容易遇到权限或参数问题，所以使用 Windows 的 `IApplicationActivationManager` 激活应用。

### Codex 启动

函数：

- `Start-Codex`
- `Publish-EnvironmentChange`
- `Enable-ManagedUserProxyEnvironment`
- `Disable-ManagedUserProxyEnvironment`
- `Wait-CodexAppServerProcess`

专用代理模式会传入：

```text
--proxy-server=http://127.0.0.1:<端口>
--proxy-bypass-list=localhost;127.0.0.1;::1
```

代理模式还会向新启动的 Codex 进程环境注入：

```text
HTTP_PROXY
HTTPS_PROXY
ALL_PROXY
NO_PROXY
http_proxy
https_proxy
all_proxy
no_proxy
```

WindowsApps 打包版在代理模式下会优先走 direct process 启动，以便注入这些环境变量。若 Windows 拒绝直接启动，则退回 `IApplicationActivationManager`。fallback 前会临时设置当前启动器进程环境变量，激活完成后恢复；这不写入全局用户环境，但能否被 packaged app 继承取决于 Windows 激活行为。

v0.1.12 后，fallback 还会短暂托管当前用户代理环境变量：

- 备份当前用户级 `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY` / 大小写变体 / `NO_PROXY`。
- 写入当前端口对应的代理值。
- 广播 Windows `Environment` 变化。
- 调用 packaged activation 启动 Codex。
- 等到 `resources\codex.exe app-server` 子进程出现，或等待超时。
- 启动窗口结束后立即恢复备份并删除临时状态文件。

这一步用于解决 WindowsApps packaged activation 不继承启动器进程环境变量的问题，让 Codex app-server 有机会继承代理。

启动日志写入：

```text
%LOCALAPPDATA%\CodexProxySwitch\launcher.log
```

### 代理连通测试

函数：

- `Test-OpenAIProxy`

测试方式：

```text
curl.exe --proxy http://127.0.0.1:<端口> https://api.openai.com
```

判断逻辑：

- `curl` 退出码为 0。
- 最终 HTTP 状态码在 `200` 到 `499` 之间。

为什么 `421` 也算可用：

它说明请求已经通过代理到达 OpenAI 侧，只是 OpenAI 对未带完整 API 请求的访问返回了非业务状态。

### 连续稳定性监测

函数：

- `Reset-StabilityMonitorStats`
- `Stop-StabilityProbe`
- `Start-StabilityProbe`
- `Complete-StabilityProbe`
- `Update-StabilityMonitorUi`
- `Stop-StabilityMonitor`
- `Start-StabilityMonitor`
- `Invoke-StabilityMonitorTick`
- `Toggle-StabilityMonitor`

机制：

- WinForms timer 每 2.5 秒检查一次。
- 每轮探测最多 12 秒。
- 探测结束后等待 5 秒再发下一轮。
- 只调用 `curl.exe`，不会启动 Codex，也不会修改系统代理。

### UI 和托盘

主要对象：

- `$form`
- `$notifyIcon`
- `$contextMenu`
- `$timer`

关闭行为：

- 用户点窗口右上角关闭：隐藏到托盘。
- 菜单点退出：真正退出。
- Windows 关机或注销：允许关闭，不再强行隐藏窗口。

## 本轮代码审查结论

已修复：

- 关闭窗口逻辑只拦截用户手动关闭，不拦截 Windows 关机和注销。
- 连续监测中端口变成非法值时，会停止正在运行的探测并重置统计。
- 手动代理测试结束后会删除临时输出文件。
- Codex 进程列表按进程 ID 去重，避免重复停止同一个进程。

仍需注意：

- Codex Desktop 通知弹窗是 Codex 本体问题，不是启动器逻辑问题。
- 绿色状态不是节点稳定性的证明。
- GitHub Release 上传需要有效的 GitHub CLI 令牌。

## 发布检查清单

发布前按顺序做：

1. 运行主脚本校验。
2. 运行构建脚本。
3. 运行发布包内脚本校验。
4. 检查 ZIP 内容。
5. 检查 `CHANGELOG.md` 版本。
6. 检查 `README.md` 下载路径版本。
7. 提交源码。
8. 推送 GitHub。
9. 创建 GitHub Release。
10. 上传 ZIP。
