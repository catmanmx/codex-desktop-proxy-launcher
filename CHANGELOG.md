# Changelog

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
