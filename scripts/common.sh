# shellcheck shell=bash
# 所有脚本共用：加载配置、定义路径、日志函数。用法：source "$(dirname "$0")/common.sh"
# Shared by all scripts: loads the configuration and defines paths and logging functions. Usage: source "$(dirname "$0")/common.sh"
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 先记下调用者显式传入的环境变量，配置文件不能覆盖它们（兼容 macOS 自带的 bash 3.2）
# Remember the environment variables the caller passed explicitly, so the config files cannot override them (compatible with the bash 3.2 that ships with macOS)
_DE_VARS="GAME_APP TEAM_ID BUNDLE_ID DEVICE UNITY_VERSION UNITY_CHANGESET UNITY_IOS_PKG_SHA256 IOS_DEPLOYMENT_TARGET ACH_RELAY ACH_RELAY_HOST ACH_RELAY_PORT ACH_RELAY_SECRET STEAM_APP_ID"
for _v in $_DE_VARS; do
  if [[ -n "${!_v+x}" ]]; then printf -v "_DE_SAVED_$_v" '%s' "${!_v}"; fi
done

# shellcheck source=/dev/null
source "$ROOT/config.example.env"
if [[ -f "$ROOT/config.env" ]]; then
  # shellcheck source=/dev/null
  source "$ROOT/config.env"
fi
for _v in $_DE_VARS; do
  _s="_DE_SAVED_$_v"
  if [[ -n "${!_s+x}" ]]; then printf -v "$_v" '%s' "${!_s}"; unset "$_s"; fi
done
unset _v _s _DE_VARS

VENDOR="$ROOT/vendor"
BUILD="$ROOT/build"
IOS_SUPPORT="$VENDOR/iOSSupport"
TRAMPOLINE="$IOS_SUPPORT/Trampoline"
GAME_CONTENTS="$GAME_APP/Contents"
GAME_DATA="$GAME_CONTENTS/Resources/Data"

# 构建产物布局
# Build output layout
FW_OUT="$BUILD/Frameworks"      # 改标后的 .framework（GameAssembly、插件、桩库） | Retagged .frameworks (GameAssembly, plugins, stub libraries)
DATA_OUT="$BUILD/GameData"      # 转换后的数据，推送到 iPad 沙盒 Documents/GameData | Converted data, pushed to Documents/GameData in the iPad app sandbox
XCODE_OUT="$BUILD/xcode"        # 生成的 Xcode 工程 | Generated Xcode project
GEN_OUT="$BUILD/generated"      # 生成的注册代码等 | Generated registration code, etc.

# 输出语言：DE_LANG=zh / en，未设置时跟随系统语言；用法：log "$(m "中文" "English")"
# Output language: DE_LANG=zh / en, defaulting to the system language; usage: log "$(m "中文" "English")"
case "${DE_LANG:-${LC_ALL:-${LANG:-}}}" in zh*) DE_ZH=1;; *) DE_ZH=0;; esac
m() { if [ "$DE_ZH" = 1 ]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m%s\033[0m %s\n' "$(m "警告:" "Warning:")" "$*" >&2; }
die()  { printf '\033[1;31m%s\033[0m %s\n' "$(m "错误:" "Error:")" "$*" >&2; exit 1; }

require_game() {
  [[ -d "$GAME_CONTENTS" ]] || die "$(m "找不到游戏：$GAME_APP（在 config.env 里设置 GAME_APP）" "Game not found: $GAME_APP (set GAME_APP in config.env)")"
  local v
  v="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleGetInfoString' "$GAME_CONTENTS/Info.plist" 2>/dev/null || true)"
  [[ "$v" == *"$UNITY_VERSION"* ]] || die "$(m "游戏的 Unity 版本与配置不一致：$v（期望 $UNITY_VERSION）" "The game's Unity version does not match the configuration: $v (expected $UNITY_VERSION)")"
}

# 为 iOS 动态 framework 写最小 Info.plist：write_framework_plist <framework 目录> <名称>
# Write a minimal Info.plist for an iOS dynamic framework: write_framework_plist <framework directory> <name>
write_framework_plist() {
  cat > "$1/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$2</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID.fw.$(echo "$2" | tr '_' '-')</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$2</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
  <key>MinimumOSVersion</key><string>$IOS_DEPLOYMENT_TARGET</string>
</dict>
</plist>
EOF
}

# 签名相关配置必须由用户填写（config.env），不能用示例里的空值
# Signing-related settings must be filled in by the user (config.env); the empty example values are not usable
require_signing_config() {
  [[ -n "$TEAM_ID" ]] || die "$(m "config.env 里没有设置 TEAM_ID（见 config.example.env）" "TEAM_ID is not set in config.env (see config.example.env)")"
  [[ -n "$BUNDLE_ID" ]] || die "$(m "config.env 里没有设置 BUNDLE_ID（见 config.example.env）" "BUNDLE_ID is not set in config.env (see config.example.env)")"
}

# 成就模式的配置：密钥、端口和主机名都要能安全地写进 C 字符串
# Achievement-mode settings: the secret, port and host name must all be safe to put into a C string
relay_host() {
  if [[ -n "$ACH_RELAY_HOST" ]]; then echo "$ACH_RELAY_HOST"; else echo "$(scutil --get LocalHostName).local"; fi
}

require_relay_config() {
  [[ "$ACH_RELAY_SECRET" =~ ^[0-9a-f]{32,64}$ ]] || die "$(m "成就模式需要配对密钥：先运行 make relay-pair" "Achievement mode needs a pairing secret: run make relay-pair first")"
  [[ "$ACH_RELAY_PORT" =~ ^[0-9]{2,5}$ ]] || die "$(m "ACH_RELAY_PORT 不是有效端口：$ACH_RELAY_PORT" "ACH_RELAY_PORT is not a valid port: $ACH_RELAY_PORT")"
  [[ "$(relay_host)" =~ ^[A-Za-z0-9.-]+$ ]] || die "$(m "ACH_RELAY_HOST 只能包含字母、数字、点和减号：$(relay_host)" "ACH_RELAY_HOST may contain only letters, digits, dots and hyphens: $(relay_host)")"
  [[ "$STEAM_APP_ID" =~ ^[0-9]+$ ]] || die "$(m "STEAM_APP_ID 不是数字：$STEAM_APP_ID" "STEAM_APP_ID is not a number: $STEAM_APP_ID")"
}

require_ios_support() {
  [[ -f "$TRAMPOLINE/Libraries/libiPhone-lib-il2cpp.a" ]] || die "$(m "缺少 Unity iOS 运行时，先运行 scripts/fetch_unity_ios.sh" "The Unity iOS runtime is missing; run scripts/fetch_unity_ios.sh first")"
}

# 自动选择设备：配置优先，否则取第一台已配对的实体 iPad
# Pick the device automatically: the configured one takes precedence, otherwise the first paired physical iPad
resolve_device() {
  if [[ -n "$DEVICE" ]]; then echo "$DEVICE"; return; fi
  local tmp; tmp="$(mktemp)"
  xcrun devicectl list devices --json-output "$tmp" >/dev/null 2>&1 || die "$(m "devicectl 无法列出设备" "devicectl could not list the devices")"
  # 第二个参数是找不到 iPad 时的报错信息（按输出语言选好）
  # The second argument is the error message used when no iPad is found (already in the output language)
  python3 -I - "$tmp" "$(m "没有找到已配对的实体 iPad" "No paired physical iPad found")" <<'EOF'
import json, sys
devs = json.load(open(sys.argv[1]))["result"]["devices"]
for d in devs:
    hw = d.get("hardwareProperties", {})
    if hw.get("reality") == "physical" and hw.get("deviceType") == "iPad" \
       and d.get("connectionProperties", {}).get("pairingState") == "paired":
        print(hw["udid"]); break
else:
    sys.exit(sys.argv[2])
EOF
  # 保留 Python 的退出码：找不到 iPad 时调用方应当停下，而不是带着空设备 ID 继续
  # Keep Python's exit status: when no iPad is found the caller must stop instead of carrying on with an empty device ID
  local status=$?
  rm -f "$tmp"
  return $status
}
