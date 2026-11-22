#!/bin/bash
# macOS source preview 0.1.0. Compatible with the system Bash 3.2.
# Only the launched process receives proxy settings. No system settings change.

fail() { printf '错误 / Error: %s\n' "$*" >&2; return 1; }

usage() {
    cat <<'HELP'
Codex macOS Proxy Launcher 0.1.0 (source preview)
Usage: bash macos/codex-proxy-launcher.command [proxy|normal|test] [options]
  proxy             使用专用代理启动 / Launch using a local HTTP proxy
  normal            普通启动 / Launch without launcher proxy overrides
  test              检测代理连通性 / Test the proxy without launching an app
  --port PORT       本地 HTTP / mixed 端口，默认 10808 (1–65535)
  --app PATH        应用路径，如 /Applications/Codex.app
  --help            显示帮助 / Show help
No arguments: show an interactive menu. Finish tasks and quit the app first.
Only Electron-based Codex/ChatGPT desktop bundles are supported.
HELP
}

valid_port() {
    case "${1-}" in ''|0*|*[!0-9]*) return 1 ;; esac
    [ "${#1}" -le 5 ] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

read_bundle_executable() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$1/Contents/Info.plist" 2>/dev/null
}

read_bundle_identifier() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null
}

resolve_bundle() {
    local bundle name identifier
    bundle=$1
    [ -d "$bundle/Contents/Frameworks/Electron Framework.framework" ] || {
        fail "不是受支持的 Electron 应用：$bundle（原生 ChatGPT.app 不适用）"; return 1;
    }
    [ -f "$bundle/Contents/Info.plist" ] || { fail "缺少 Info.plist：$bundle"; return 1; }
    bundle=$(cd "$bundle" && pwd -P) || return 1
    identifier=$(read_bundle_identifier "$bundle") || { fail '无法读取应用标识'; return 1; }
    [ "$identifier" = com.openai.codex ] || {
        fail "不是 Codex 桌面应用（应用标识：$identifier）"; return 1;
    }
    name=$(read_bundle_executable "$bundle") || { fail '无法读取应用主程序名称'; return 1; }
    case "$name" in ''|.|..|*/*|*$'\n'*|*$'\r'*) fail '应用主程序名称无效'; return 1 ;; esac
    [ -f "$bundle/Contents/MacOS/$name" ] && [ -x "$bundle/Contents/MacOS/$name" ] || {
        fail "应用主程序不存在或不可执行：$name"; return 1;
    }
    printf '%s\n' "$bundle/Contents/MacOS/$name"
}

find_app() {
    local candidate executable
    # Match the official CLI: prefer the renamed desktop app in each location.
    for candidate in /Applications/ChatGPT.app /Applications/Codex.app \
        "$HOME/Applications/ChatGPT.app" "$HOME/Applications/Codex.app"; do
        if executable=$(resolve_bundle "$candidate" 2>/dev/null); then
            printf '%s\n' "$executable"
            return 0
        fi
    done
    fail '未找到 Electron 桌面应用；请用 --app 指定完整 .app 路径。'
}

app_is_running() {
    local rows process_id executable
    # comm excludes arguments but may preserve argv[0] aliases. Match file identity too.
    rows=$(ps -ww -axo pid=,comm=) || return 2
    while read -r process_id executable; do
        [ "$executable" = "$1" ] && return 0
        case "$executable" in
            /*) [ "$executable" -ef "$1" ] && return 0 ;;
        esac
    done <<< "$rows"
    return 1
}

test_proxy() {
    local code
    # Empty --noproxy prevents an inherited NO_PROXY=* bypassing this test.
    code=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
        --connect-timeout 5 --max-time 15 --noproxy '' \
        --proxy "http://127.0.0.1:$1" https://api.openai.com/) || {
        fail '代理连接失败；请检查代理软件和 HTTP / mixed 端口。'; return 1;
    }
    case "$code" in
        [234][0-9][0-9]) printf '已收到目标 HTTP %s；仅代表连通，不代表登录或账号功能可用。\n' "$code" ;;
        *) fail "目标响应异常：HTTP $code"; return 1 ;;
    esac
}

launch_app() {
    local executable mode port log_dir log_file child_pid
    executable=$1; mode=$2; port=$3
    log_dir="$HOME/Library/Logs/CodexProxyLauncher"
    # Restrict newly-created logs to the current user. Do not print app output.
    (umask 077; mkdir -p "$log_dir") || return 1
    log_file="$log_dir/desktop.log"
    (
        umask 077
        exec >> "$log_file" 2>&1
        trap '' HUP
        unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
        unset http_proxy https_proxy all_proxy no_proxy NODE_USE_ENV_PROXY
        if [ "$mode" = proxy ]; then
            export HTTP_PROXY="http://127.0.0.1:$port" HTTPS_PROXY="http://127.0.0.1:$port"
            export ALL_PROXY="http://127.0.0.1:$port" http_proxy="http://127.0.0.1:$port"
            export https_proxy="http://127.0.0.1:$port" all_proxy="http://127.0.0.1:$port"
            export NO_PROXY='localhost,127.0.0.1,::1' no_proxy='localhost,127.0.0.1,::1'
            export NODE_USE_ENV_PROXY=1
            exec "$executable" "--proxy-server=http://127.0.0.1:$port" \
                '--proxy-bypass-list=localhost;127.0.0.1;::1'
        else
            exec "$executable"
        fi
    ) </dev/null &
    child_pid=$!
    sleep 1
    if ! kill -0 "$child_pid" 2>/dev/null; then
        wait "$child_pid" 2>/dev/null || :
        fail "应用启动后立即退出，请检查本地日志：$log_file"
        return 1
    fi
    disown "$child_pid" 2>/dev/null || :
    printf '已启动（PID %s，模式 %s）。应用内网络状态仍需实际确认。\n' "$child_pid" "$mode"
    printf '本地日志：%s\n' "$log_file"
}

main() {
    local mode port bundle executable option running_status
    mode=''; port=10808; bundle=''
    while [ "$#" -gt 0 ]; do
        option=$1
        case "$option" in
            --help|-h) usage; return 0 ;;
            proxy|normal|test)
                [ -z "$mode" ] || { fail '只能指定一种模式'; return 1; }
                mode=$option; shift ;;
            --port|--app)
                [ "$#" -ge 2 ] && [ -n "$2" ] || { fail "$option 缺少参数"; return 1; }
                if [ "$option" = --port ]; then port=$2; else bundle=$2; fi
                shift 2 ;;
            *) fail "未知参数：$option"; usage >&2; return 1 ;;
        esac
    done
    [ "$(uname -s)" = Darwin ] || { fail '此入口只适用于 macOS。Windows 请使用仓库根目录的启动器。'; return 1; }
    if [ -z "$mode" ]; then
        [ -t 0 ] || { usage >&2; fail '非交互模式请指定 proxy、normal 或 test'; return 1; }
        printf '\n1) 使用代理启动  2) 普通启动  3) 检测代理  0) 退出\n'
        read -r -p '请选择：' option || return 1
        case "$option" in 1) mode=proxy ;; 2) mode=normal ;; 3) mode=test ;; 0) return 0 ;; *) fail '无效选择'; return 1 ;; esac
        if [ "$mode" != normal ]; then
            read -r -p "本地 HTTP / mixed 代理端口 [$port]：" option || return 1
            [ -z "$option" ] || port=$option
        fi
    fi
    valid_port "$port" || { fail '端口必须是 1–65535 的十进制整数（不含前导零）'; return 1; }
    if [ "$mode" = test ]; then test_proxy "$port"; return $?; fi
    if [ -n "$bundle" ]; then
        executable=$(resolve_bundle "$bundle") || return 1
    else
        executable=$(find_app) || return 1
    fi
    if app_is_running "$executable"; then
        fail '该应用正在运行。请完成任务并用 ⌘Q 完全退出，再切换启动模式。'
        return 1
    else
        running_status=$?
        [ "$running_status" -eq 1 ] || { fail '无法检查运行进程，已取消启动。'; return 1; }
    fi
    if [ "$mode" = proxy ]; then
        nc -z -G 2 127.0.0.1 "$port" >/dev/null 2>&1 || {
            fail "本地端口 $port 未开放，请先启动代理软件。"; return 1;
        }
    fi
    launch_app "$executable" "$mode" "$port"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
    result=$?
    if [ "$#" -eq 0 ] && [ -t 0 ]; then read -r -p '按回车关闭此窗口…' _ || :; fi
    exit "$result"
fi
