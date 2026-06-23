# Codex Desktop Proxy Launcher 产品文档

更新时间：2026-06-23

## 产品定位

Codex Desktop Proxy Launcher 是一个非官方 Windows 小工具，用来让 Codex Desktop 通过固定的本地代理端口启动。

它解决的是“Codex 启动时没有稳定继承代理入口”的问题，而不是替代 VPN、代理软件或 Codex Desktop 本体。

## 核心目标

- 只影响通过本启动器重启的 Codex。
- 不修改 Windows 系统代理。
- 不修改 WinHTTP。
- 不影响浏览器、Git、npm 或其他软件。
- 允许用户在代理软件里切换节点，只要本地端口不变，Codex 看到的代理入口就不变。
- 用一个简洁窗口提供开关、端口、测试、连续监测、开机启动和日志健康检查。

## 当前版本状态

- `v0.1.8`：源码已推送到 GitHub `main`，提交为 `5c373c9`。
- `v0.1.8` GitHub Release 下载包：之前卡在 GitHub CLI 令牌失效，未确认完成上传。
- `v0.1.9`：本地维护版，包含文档、维护注释和小逻辑修复。
- `v0.1.10`：专用代理模式会向 Codex 进程注入代理环境变量，目标是让 app-server 子进程也继承代理。
- `v0.1.11`：direct process 被 WindowsApps 拒绝时，会在 packaged activation 前临时设置启动器进程环境变量，调用后立即恢复。
- `v0.1.12`：WindowsApps fallback 会在启动前短暂写入当前用户代理环境变量并广播环境变化，等待 Codex app-server 子进程出现后立即按备份恢复，用来让 app-server 继承 `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY`。
- `v0.1.13`：当前本地开发版。新增日志健康检查面板，启动时做只读轻量检查；Codex 版本变化或可疑时做完整检查；手动止血前必须备份，恢复只删除止血 trigger，不删除备份。

发布前必须重新运行构建，并确认 GitHub Release 中的 ZIP 与源码版本一致。

## 用户看到的界面

主窗口包含：

- 语言切换按钮：中文 / English。
- 状态灯：绿色表示本地代理端口已开启，红色表示本地代理端口未开启。
- 端口输入框：默认 `10808`，如果代理软件端口变化才需要修改。
- `使用专用代理重启 Codex`：关闭当前 Codex，用代理参数重新启动。
- `普通模式重启 Codex`：关闭当前 Codex，不带代理参数重新启动。
- `测试当前端口是否可用`：通过当前本地代理访问 `https://api.openai.com`。
- `开始连续检测节点稳定性`：持续通过当前本地代理访问 OpenAI，并显示成功、失败、成功率。
- `开机自动使用代理启动 Codex`：写入当前用户的 Windows 启动文件夹。
- 日志健康区：显示正常、可疑、TRACE 暴涨、已拦截、检查失败等状态，并显示 Codex 版本、数据库大小、WAL 大小、`MAX(id)`、10 秒增长、TRACE 占比、trigger 状态、最后检查时间和最近备份路径。
- 日志健康按钮：一键巡检、一键完整检查、一键止血、一键恢复日志、打开备份目录。

## 启动日志

启动器会写入：

```text
%LOCALAPPDATA%\CodexProxySwitch\launcher.log
```

代理模式启动时会记录：

- 当前代理端口。
- 代理 URL。
- 是否注入 `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY`。
- WindowsApps fallback 是否短暂写入并恢复当前用户代理环境变量。
- `Codex.exe` 路径。
- Codex 启动命令。
- 启动方式：direct process 或 packaged activation fallback。

日志健康检查会记录：

- 检查状态、数据库路径、数据库和 WAL 大小、`MAX(id)`、10 秒增长量、TRACE 占比、trigger 状态。
- 备份目录、止血动作、恢复动作和异常消息。
- 不记录大量 SQLite 行正文，只记录统计结果。

## 状态含义

绿色状态只表示：

```text
127.0.0.1:<端口> 有程序正在监听
```

绿色状态不表示：

- 当前 VPN 节点一定稳定。
- OpenAI 一定可访问。
- 当前 Codex 进程一定已经通过代理启动。

节点质量需要看“连续检测节点稳定性”。如果连续检测失败增加，通常是代理节点、DNS、线路或 VPN/TUN 路由问题。

## 代理边界

启动器只做两件事：

1. 重启 Codex。
2. 给新启动的 Codex 传入本地代理入口和进程级代理环境变量。
3. 在 WindowsApps fallback 启动窗口内，短暂写入当前用户代理环境变量，让 packaged activation 创建的 Codex/app-server 能继承代理；检测到 app-server 后立即恢复备份。

它不会：

- 改系统代理。
- 长期改其他软件代理；fallback 写入当前用户环境变量只发生在启动窗口内，随后恢复。
- 自动切换 VPN 节点。
- 修复代理软件本身的线路质量。
- 修复 Codex Desktop 本体的通知或 Electron 缺陷。

代理模式下，启动器会优先直接启动 `Codex.exe` 并注入进程环境变量。如果 WindowsApps 打包目录拒绝直接启动，启动器会退回 Windows packaged app activation。fallback 前会临时把代理环境变量设置到启动器进程，同时备份并短暂写入当前用户代理环境变量，广播 Windows 环境变化，等到 app-server 子进程出现或等待超时后立即恢复。这个方式不改系统代理，也不会长期保留用户代理环境变量。

## Codex 通知弹窗问题

如果看到类似：

```text
Error launching app
Unable to find Electron app at ...\type=click&tag=...
```

这是 Codex Desktop 自身的桌面通知回调问题。`type=click&tag=...` 是 Windows 通知点击参数，不是本启动器传入的启动参数。

临时处理：

1. 打开 Codex 设置。
2. 找到“通知”。
3. 将“轮次完成通知”改成“关闭”。
4. 如果仍然弹窗，再关闭权限通知和问题通知。

## 开机启动策略

当前版本使用：

```text
%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Codex Proxy Launcher.lnk
```

早期版本曾经使用过：

```text
HKCU\Software\Microsoft\Windows\CurrentVersion\Run\CodexProxyLauncherAutoStart
```

当前启动器每次打开都会清理旧注册表项，避免旧版重复启动。

如果用户移动了解压目录，启动器会检测旧快捷方式目标是否失效，并尝试自动修复为当前目录。

## 主要用户流程

### 第一次使用

1. 解压 Release ZIP。
2. 双击 `CodexProxyLauncher.exe`。
3. 填写代理软件本地端口。
4. 点击“测试当前端口是否可用”。
5. 测试可用后，点击“使用专用代理重启 Codex”。

### 更换 VPN 节点

只要代理软件本地端口不变，不需要修改启动器。

如果换节点后仍然 `Reconnecting...`，优先看连续检测是否失败增加。失败增加说明是节点或线路问题，不是启动器参数问题。

### 端口变化

如果代理软件本地端口从 `10808` 改成 `7890` 或其他值，只需要在启动器里改端口，然后重新用专用代理启动 Codex。

## 已知限制

- 启动器无法可靠读取已经运行的 Codex 进程是否真的继承了代理参数，因此“是否通过代理启动”只能根据启动器保存的最近启动模式做辅助判断。
- 连续检测使用 `curl.exe`，如果系统缺少 curl，检测会失败。
- 任务进行中重启 Codex 会中断当前任务。
- Codex Desktop 的通知弹窗问题属于 Codex 本体，不属于启动器可直接修复的范围。

## 维护原则

- 版本变化必须写入 `CHANGELOG.md`。
- 打包版本必须和 `scripts/build-release.ps1` 默认版本一致。
- 产品边界变化必须同步本文件。
- 不要在生产脚本里做逐行注释；逐行注释会增加改动成本。需要解释逻辑时，优先更新 `docs/CODE_MAP.md`。
- 修改代理启动逻辑后，必须验证普通模式和专用代理模式都能启动。
- 修改开机启动逻辑后，必须验证旧快捷方式、移动目录、取消勾选三种情况。
