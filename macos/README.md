# macOS 代理启动器

**版本：0.1.0，源码预览版。** 与 Windows v0.1.14 放在同一仓库；Windows 入口保持不变。本次仅提供源码，不提供 `.app`、DMG 或签名安装包。

## 适用范围

- 使用 macOS 自带的 `/bin/bash`，按 Bash 3.2 编写，无需 Homebrew、Python 或 Node。
- 启动已经安装的 **Electron 版 Codex 桌面应用**，同时核对应用标识 `com.openai.codex`。先在 `/Applications`，再在 `~/Applications` 查找；每个目录优先检查更名后的 `ChatGPT.app`，再检查 `Codex.app`。
- 兼容名称为 `ChatGPT.app`、标识仍为 `com.openai.codex` 的 Electron 应用。**原生、非 Electron 的 ChatGPT Mac 客户端不适用**，其他 Electron 软件也会被拒绝。
- 脚本本身不包含 CPU 架构相关二进制；能否在 Intel / Apple Silicon 上运行取决于目标应用支持的系统和架构。
- 本地代理必须提供 HTTP 或 mixed 端口；不支持仅 SOCKS 的端口、远程代理或需要账号密码的代理。

## 使用

先启动代理软件，确认本地 HTTP / mixed 端口。完成桌面应用中的任务并用 **⌘Q 完全退出**，仅关闭窗口可能还在后台运行。

在仓库根目录打开终端：

```bash
# 使用代理启动，端口按自己的代理软件设置填写
/bin/bash macos/codex-proxy-launcher.command proxy --port 7890

# 自定义应用位置；带空格的路径必须加引号
/bin/bash macos/codex-proxy-launcher.command proxy --port 7890 \
  --app "/Applications/Codex.app"

# 普通模式：不附加本启动器代理，仍遵循应用和系统自身设置
/bin/bash macos/codex-proxy-launcher.command normal

# 仅测试代理，不打开应用
/bin/bash macos/codex-proxy-launcher.command test --port 7890
```

不传参数会显示中文终端菜单。默认端口是 `10808`，也可在菜单中输入其他端口。

源码检出保留执行权限时，可以双击 `.command` 打开菜单。若下载方式没有保留执行权限，可使用上面的 `/bin/bash` 命令，或在确认文件来源后运行：

```bash
chmod +x macos/codex-proxy-launcher.command
```

启动器不会自动关闭应用，也不会强制结束进程。如果提示正在运行，请先退出后重试。不要在启动器启动的同时从 Dock 手动打开同一应用。

## 工作方式与边界

脚本从应用的 `Contents/Info.plist` 读取 `CFBundleExecutable`，直接启动 `Contents/MacOS/` 中的主程序，确保子进程获得环境变量。专用代理模式传入：

```text
--proxy-server=http://127.0.0.1:<端口>
--proxy-bypass-list=localhost;127.0.0.1;::1
```

同时设置子进程的 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY`、`NO_PROXY` 及对应小写变量，以及 `NODE_USE_ENV_PROXY=1`。普通模式在子进程中清除上述变量，不改变父终端的环境。

不修改系统代理、`launchctl` 环境、shell 配置、应用包或 TLS 校验。此版本没有 Windows 版的托盘、开机启动、连续监测和 SQLite 日志维护面板。

`NODE_USE_ENV_PROXY` 是否生效取决于应用内嵌的 Node 版本和使用的网络实现，并非所有请求都保证支持。启动提示只说明子进程没有立即退出；HTTP 测试收到 2xx–4xx 仅表示目标返回了响应，不证明账号、登录或 Dots 功能正常。

应用标准输出和错误保存在本机 `~/Library/Logs/CodexProxyLauncher/desktop.log`。日志可能含应用运行信息，不会上传；分享前应自行检查。需要时可在应用退出后清理该日志。

## 验证状态

已在 Windows 的 Bash 环境运行隔离行为测试，实际启动测试子进程检查环境和参数；macOS 的 plist 读取、进程列表及网络工具用受控测试替身验证调用逻辑。Windows 的最小 Bash 发行版缺少 `sleep` / `chmod`，本地测试补充了等待适配和权限空操作，**没有验证 macOS 执行权限或真实应用启动**。

Mac 上的验证命令：

```bash
/bin/bash -n macos/codex-proxy-launcher.command
/bin/bash scripts/test-macos-launcher.sh
```

发布为稳定版前仍需在真实 Mac 上检查：系统 Bash 3.2；真实 Info.plist 与进程枚举；已退出的 Codex 在两种模式下启动；应用内请求与子进程代理；关闭终端后应用继续运行；系统代理设置保持原状。

实现参考：[OpenAI CLI 的 Mac 应用识别](https://github.com/openai/codex/blob/main/codex-rs/cli/src/desktop_app/mac.rs)、[Apple CFBundleExecutable](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleexecutable)、[Electron 代理参数](https://www.electronjs.org/docs/latest/api/command-line-switches)、[Node 环境代理说明](https://nodejs.org/learn/http/enterprise-network-configuration)。
