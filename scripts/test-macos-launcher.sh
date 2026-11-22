#!/bin/bash
# Run with macOS /bin/bash (3.2+) or Bash on Linux/Windows. No desktop is opened.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LAUNCHER="$ROOT/macos/codex-proxy-launcher.command"
if [ ! -f "$LAUNCHER" ]; then
    echo 'FAIL: macOS launcher is missing' >&2
    exit 1
fi
. "$LAUNCHER"
TEST_ROOT=$(mktemp -d)
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="$TEST_ROOT/home"
mkdir -p "$HOME"
passed=0
check() { if "$@"; then passed=$((passed + 1)); else echo "FAIL: $*" >&2; exit 1; fi; }
reject() { if "$@" >/dev/null 2>&1; then return 1; fi; }

# Bounds and decimal parsing: reject shell input, octal ambiguity, and overflow.
check valid_port 1
check valid_port 65535
for port in 0 65536 -1 01 1.5 '80;echo bad' 999999999999999999999999 '' ' 80'; do
    check reject valid_port "$port"
done

APP="$TEST_ROOT/My Codex.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks/Electron Framework.framework"
write_plist() {
    cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$1</string>
<key>CFBundleIdentifier</key><string>$2</string>
</dict></plist>
PLIST
}
write_plist 'Codex Desktop' com.openai.codex
export CAPTURE="$TEST_ROOT/capture"
cat > "$APP/Contents/MacOS/Codex Desktop" <<'CHILD'
#!/bin/sh
printf '%s\n' "${HTTP_PROXY-unset}" "${HTTPS_PROXY-unset}" "${ALL_PROXY-unset}" \
    "${http_proxy-unset}" "${https_proxy-unset}" "${all_proxy-unset}" \
    "${NO_PROXY-unset}" "${no_proxy-unset}" "${NODE_USE_ENV_PROXY-unset}" > "$CAPTURE"
printf '<%s>\n' "$@" >> "$CAPTURE"
sleep 3
CHILD
chmod +x "$APP/Contents/MacOS/Codex Desktop"

# Use real PlistBuddy on macOS; only substitute unavailable OS readers elsewhere.
if [ "$(uname -s)" != Darwin ]; then
    read_bundle_executable() { sed -n 's|.*<key>CFBundleExecutable</key><string>\(.*\)</string>.*|\1|p' "$1/Contents/Info.plist"; }
    read_bundle_identifier() { sed -n 's|.*<key>CFBundleIdentifier</key><string>\(.*\)</string>.*|\1|p' "$1/Contents/Info.plist"; }
fi
check test "$(resolve_bundle "$APP")" = "$APP/Contents/MacOS/Codex Desktop"
write_plist 'Codex Desktop' com.example.unrelated
check reject resolve_bundle "$APP"
write_plist 'Codex Desktop' com.openai.codex
check reject resolve_bundle "$TEST_ROOT/missing.app"
mkdir -p "$TEST_ROOT/Native ChatGPT.app/Contents/MacOS"
check reject resolve_bundle "$TEST_ROOT/Native ChatGPT.app"
write_plist '../outside' com.openai.codex
check reject resolve_bundle "$APP"
write_plist 'missing' com.openai.codex
check reject resolve_bundle "$APP"
write_plist 'Codex Desktop' com.openai.codex

# ps is an OS boundary. Check literal full paths, not application-name matches.
ps() { printf '%s\n' "  42 $APP/Contents/MacOS/Codex Desktop" '  43 /usr/local/bin/codex'; }
check app_is_running "$APP/Contents/MacOS/Codex Desktop"
check reject app_is_running "$TEST_ROOT/Elsewhere.app/Contents/MacOS/Codex Desktop"
ps() { printf '%s\n' "  42 $APP/Contents/MacOS/../MacOS/Codex Desktop"; }
check app_is_running "$APP/Contents/MacOS/Codex Desktop"
ps() { printf '%s\n' "  42 $APP/Contents/Frameworks/Helper.app/Contents/MacOS/Helper" '  43 /usr/local/bin/codex'; }
check reject app_is_running "$APP/Contents/MacOS/Codex Desktop"
ps() { return 1; }
status=0
app_is_running "$APP/Contents/MacOS/Codex Desktop" || status=$?
check test "$status" = 2

# curl's exit status and final status code both matter, including NO_PROXY=*.
curl() { printf '%s\n' "$*" > "$TEST_ROOT/curl-args"; printf '401'; }
export NO_PROXY='*'
check test_proxy 7890
check grep -q -- '--noproxy ' "$TEST_ROOT/curl-args"
curl() { printf '200'; return 7; }
check reject test_proxy 7890
curl() { printf '000'; }
check reject test_proxy 7890
curl() { printf '502'; }
check reject test_proxy 7890

# Exercise the actual spawned child's environment and argument boundaries.
export HTTP_PROXY='http://parent.invalid:1111' HTTPS_PROXY='http://parent.invalid:1111'
export ALL_PROXY='http://parent.invalid:1111' http_proxy='http://parent.invalid:1111'
export https_proxy='http://parent.invalid:1111' all_proxy='http://parent.invalid:1111'
export no_proxy='*' NODE_USE_ENV_PROXY=1
check launch_app "$APP/Contents/MacOS/Codex Desktop" proxy 7890
check test "$(sed -n '1p' "$CAPTURE")" = 'http://127.0.0.1:7890'
check test "$(sed -n '6p' "$CAPTURE")" = 'http://127.0.0.1:7890'
check test "$(sed -n '7p' "$CAPTURE")" = 'localhost,127.0.0.1,::1'
check test "$(sed -n '9p' "$CAPTURE")" = '1'
check grep -Fxq -- '<--proxy-server=http://127.0.0.1:7890>' "$CAPTURE"
check grep -Fxq -- '<--proxy-bypass-list=localhost;127.0.0.1;::1>' "$CAPTURE"
check test "$HTTP_PROXY" = 'http://parent.invalid:1111'
check launch_app "$APP/Contents/MacOS/Codex Desktop" normal 7890
check test "$(grep -c '^unset$' "$CAPTURE")" = 9
check reject grep -q -- '--proxy-server' "$CAPTURE"
check test "$NO_PROXY" = '*'
cat > "$APP/Contents/MacOS/Crashing Desktop" <<'CHILD'
#!/bin/sh
exit 1
CHILD
chmod +x "$APP/Contents/MacOS/Crashing Desktop"
check reject launch_app "$APP/Contents/MacOS/Crashing Desktop" normal 7890

# Main command validation must reject input before any desktop launch.
# Child launches above used the real function. Here a marker detects any attempt
# to reach the spawn boundary after an input/OS precondition fails.
launch_app() { printf 'spawn\n' >> "$TEST_ROOT/spawn-attempts"; return 1; }
uname() { printf 'Darwin\n'; }
check reject main proxy --port 0 --app "$APP"
check reject main proxy --port
check reject main proxy --unknown
check reject main unexpected
ps() { return 1; }
check reject main normal --app "$APP"
ps() { printf '%s\n' "  42 $APP/Contents/MacOS/Codex Desktop"; }
check reject main normal --app "$APP"
ps() { return 0; }
nc() { return 1; }
check reject main proxy --app "$APP" --port 7890
uname() { printf 'Linux\n'; }
check reject main normal --app "$APP"
check main --help
check test ! -e "$TEST_ROOT/spawn-attempts"
printf 'PASS: %s macOS launcher checks\n' "$passed"
