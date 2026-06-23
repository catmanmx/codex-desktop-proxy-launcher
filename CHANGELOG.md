# Changelog

## v0.1.13

- Add a Log Health panel that checks Codex `logs_2.sqlite` status, WAL size, current `MAX(id)`, TRACE ratio, Codex version changes, and existing block triggers.
- Add manual full checks, backup, block-writes, restore, and open-backup actions. Blocking writes is never automatic and creates a SQLite backup first.
- Package `codex-log-health.ps1` and add a deterministic self-test covering missing database, blocked trigger, TRACE storm detection, backup, block, and restore flows.

## v0.1.12

- In WindowsApps fallback mode, temporarily write proxy variables to the current user's environment before packaged activation so Codex app-server can inherit them.
- Back up and restore existing user-level proxy variables immediately after startup to reduce impact on other newly launched software.
- Broadcast the Windows environment change and log whether `HTTP_PROXY`, `HTTPS_PROXY`, and `ALL_PROXY` were written.

## v0.1.11

- When WindowsApps refuses direct `Codex.exe` startup, temporarily set proxy environment variables on the launcher process before packaged app activation.
- Restore the launcher process environment immediately after activation so other software is not affected.
- Improve fallback logs to show whether the packaged activation path had proxy environment prepared.

## v0.1.10

- In proxy mode, inject `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, and `NO_PROXY` into the Codex process environment so child processes such as app-server can inherit the proxy.
- Try direct `Codex.exe` startup for WindowsApps installs in proxy mode, then fall back to packaged app activation if Windows refuses direct startup.
- Keep existing `--proxy-server` and `--proxy-bypass-list` launch arguments.
- Add launcher logs under `%LOCALAPPDATA%\CodexProxySwitch\launcher.log` with port, proxy injection, command, and launch method details.

## v0.1.9

- Add product and maintenance documentation so future changes have a clear source of truth.
- Add targeted maintenance comments to the launcher and build scripts without turning the production script into a line-by-line comment dump.
- Deduplicate Codex process discovery before stopping processes.
- Clean proxy-test temporary files after each test.
- Stop an in-flight stability probe when the monitor port becomes invalid.
- Allow Windows shutdown and logoff to close the launcher instead of hiding the window.

## v0.1.8

- Validate the saved Windows startup shortcut target and automatically repair stale shortcuts when the launcher opens.
- Remove the legacy registry startup entry left by early launcher versions when the launcher opens.
- Show whether the local proxy port is open without implying that the selected VPN node is stable.
- Add an optional continuous node stability monitor with passed, failed, and success-rate counters.

## v0.1.7

- Make Codex restart stricter by also stopping path-protected `Codex.exe` processes whose executable path cannot be read.
- Repeat shutdown checks before relaunching so proxy startup arguments are less likely to be ignored by an already-running Codex instance.

## v0.1.6

- Fix proxy test false positives caused by counting the local proxy `200 Connection established` handshake as OpenAI connectivity.
- Proxy test now requires a final HTTP response from `https://api.openai.com`.

## v0.1.5

- Prevent raw Microsoft .NET Framework exception dialogs from launcher button, menu, and timer events.
- Show launcher-controlled error messages instead of unhandled PowerShell WinForms exceptions.

## v0.1.4

- Add a per-user Windows startup checkbox.
- Startup mode waits for the configured local proxy port, then starts Codex through the dedicated proxy.
- Startup mode opens minimized to the tray.

## v0.1.3

- Fix Chinese/English message placeholders like `端口：{0}` not being replaced with the actual port.

## v0.1.2

- Fix a runtime tray icon crash caused by GDI+ `GetHicon()`.
- Load packaged red/green tray icons from disk instead of drawing them while the launcher is running.

## v0.1.1

- Add a custom embedded icon for `CodexProxyLauncher.exe`.
- Keep icon generation inside the build script so release packages are reproducible.

## v0.1.0

Initial public release.

- Dedicated Codex Desktop proxy launcher for Windows.
- Does not change system proxy, WinHTTP, or global user environment variables.
- Supports local proxy port configuration.
- Chinese/English UI switch.
- Red/green proxy status indicator.
- OpenAI connectivity test for the selected local proxy port.
- Packaged Windows `.exe` bootstrapper plus fallback `.cmd` and `.vbs` launchers.
