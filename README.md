# Codex Desktop Proxy Launcher

Codex Desktop 专用代理启动器。它用于在 Windows 上让 Codex Desktop 固定通过本地代理端口启动，同时不修改系统代理、不影响其他软件。

This is an unofficial Windows launcher for Codex Desktop. It helps reduce `Reconnecting...` and stuck "thinking" issues by starting Codex through a dedicated local proxy without changing global system proxy settings.

## 解决什么问题

在部分网络环境下，Codex Desktop 可能因为直连、DNS 污染、代理未被继承或 VPN/TUN 路由不稳定，出现：

- `Reconnecting...`
- 一直显示“正在思考”
- 任务已经结束但窗口仍然像在流式输出
- 切换 VPN 节点后会话断开

这个启动器把 Codex 固定到一个本地代理入口，例如：

```text
127.0.0.1:10808
```

你可以继续在代理软件里切换节点。只要本地端口不变，Codex 看到的代理入口就不变。

## 特性

- 只影响由本启动器重启的 Codex
- 不修改 Windows 系统代理
- 不修改 WinHTTP
- 不影响浏览器、Git、npm 或其他软件
- 可填写本地代理端口
- 红色/绿色状态显示
- 中文/英文界面切换
- 可勾选开机自动打开代理并启动 Codex
- 支持测试当前端口是否可连通 OpenAI

## 使用方法

如果你下载的是 Release 压缩包，解压后优先双击：

```text
CodexProxyLauncher.exe
```

如果你是直接从源码运行，也可以双击：

```text
codex-only-proxy-launcher.cmd
```

默认端口是 `10808`。如果你的代理软件使用其他端口，例如 Clash 常见的 `7890`，在窗口里改成对应端口即可。

按钮含义：

- `打开代理，并重启 Codex`：关闭当前 Codex，用专用代理模式重新打开
- `普通模式重启 Codex`：关闭当前 Codex，不带代理重新打开
- `测试当前端口是否可用`：测试本地代理端口能否访问 OpenAI
- `开机自动打开代理并启动 Codex`：写入当前用户的 Windows 启动文件夹；下次登录后会等待本地代理端口可用，再用代理模式启动 Codex

## 注意

切换代理模式必须重启 Codex，因为 Windows 不能可靠地从外部修改一个已经运行进程的网络环境。正在运行的 Codex 任务会被中断。

本项目不是 OpenAI 官方工具。

## 下载包内容

Release 压缩包内包含：

- `CodexProxyLauncher.exe`：推荐入口，双击即可打开托盘启动器
- `codex-only-proxy-launcher.ps1`：主程序逻辑
- `codex-only-proxy-launcher.cmd`：备用启动入口
- `start-codex-only-proxy-launcher.vbs`：备用安静启动入口
- `icons/`：红色/绿色托盘状态图标
- `README.md`
- `LICENSE`

## 本地构建

在 Windows PowerShell 5.1 中运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-release.ps1
```

构建结果会生成在：

```text
dist/codex-desktop-proxy-launcher-v0.1.4.zip
```

## License

MIT License. See [LICENSE](LICENSE).

## Suggested Repository Metadata

Repository name:

```text
codex-desktop-proxy-launcher
```

Description:

```text
Unofficial Windows launcher to reduce Codex Desktop Reconnecting/Thinking issues by starting Codex through a dedicated local proxy without changing system proxy settings.
```

Topics:

```text
codex
codex-desktop
openai
proxy
proxy-launcher
windows
vpn
v2rayn
clash
```
