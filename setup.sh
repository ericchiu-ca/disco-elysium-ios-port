#!/bin/bash
# 一条命令准备好一切：体检 → 下载同版本 Unity iOS 运行时 → 改标二进制 → 桩库 → 生成工程 → 编译签名 → 转换游戏数据。
# One command to prepare everything: health check → fetch the matching Unity iOS runtime → retag binaries → stubs → generate the project → build and sign → convert the game data.
#
# 用法 / Usage:
#   ./setup.sh          体检通过后做全部准备 | run the health check, then prepare everything
#   ./setup.sh check    只体检：逐项报告状态、缺的话去哪拿、下一步命令；不改任何东西 | health check only; changes nothing
# 之后装到 iPad：make install push-data run | Then install on the iPad: make install push-data run
# 报告的语言跟系统语言走，也可用 DE_LANG=zh / en 指定。依赖说明见 docs/DEPENDENCIES.zh-CN.md。
# Reports follow the system language; set DE_LANG=zh / en to choose. Dependencies are described in docs/DEPENDENCIES.md.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/common.sh
source "$HERE/scripts/common.sh"
set +e  # 体检要把每一项都跑完，不能遇错即停 | The health check must run every item instead of stopping at the first failure

missing=0
NEXT=
ok()   { echo "  ✓ $1"; }
bad()  { echo "  ✗ $1"; echo "      → $2"; missing=$((missing + 1)); [[ -n "$NEXT" ]] || NEXT=$2; }
note() { echo "  · $1"; }
tool() {  # 命令 中文用途 英文用途 安装办法 | command, purpose (zh), purpose (en), how to install
  if command -v "$1" > /dev/null 2>&1; then ok "$1"; else bad "$(m "缺少 $1（$2）" "$1 is missing ($3)")" "$4"; fi
}

log "$(m "一、这台电脑" "1. This computer")"
OSV=$(sw_vers -productVersion 2> /dev/null)
if [[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]]; then
  ok "$(m "Apple 芯片的 Mac，macOS $OSV" "Apple silicon Mac, macOS $OSV")"
else
  bad "$(m "需要 Apple 芯片的 Mac（这台是 $(uname -s) $(uname -m)）" "An Apple silicon Mac is required (this is $(uname -s) $(uname -m))")" \
      "$(m "换一台 Apple 芯片的 Mac" "Use an Apple silicon Mac")"
fi
FREE_GB=$(df -g "$ROOT" | awk 'NR == 2 {print $4}')
if [[ "${FREE_GB:-0}" -ge 20 ]]; then ok "$(m "可用磁盘空间 ${FREE_GB} GB" "${FREE_GB} GB of free disk space")"
else bad "$(m "可用磁盘空间只有 ${FREE_GB} GB，建议至少 20 GB" "Only ${FREE_GB} GB free; at least 20 GB is recommended")" "$(m "清理磁盘空间" "Free up disk space")"; fi

log "$(m "二、工具" "2. Tools")"
if xcodebuild -version > /dev/null 2>&1; then
  ok "$(xcodebuild -version | head -1)（iOS SDK $(xcrun --sdk iphoneos --show-sdk-version 2> /dev/null)）"
else
  bad "$(m "缺少 Xcode（或 xcode-select 没有指向它）" "Xcode is missing (or xcode-select does not point to it)")" \
      "$(m "从 App Store 安装 Xcode，再运行 sudo xcode-select -s /Applications/Xcode.app" "Install Xcode from the App Store, then run sudo xcode-select -s /Applications/Xcode.app")"
fi
for t in vtool segedit; do
  if xcrun -f "$t" > /dev/null 2>&1; then ok "$t"; else bad "$(m "Xcode 工具链里没有 $t" "$t is missing from the Xcode toolchain")" "$(m "重新安装 Xcode" "Reinstall Xcode")"; fi
done
tool xcodegen "生成 Xcode 工程" "generating the Xcode project" "brew install xcodegen"
tool python3 "转换数据、打补丁" "data conversion and patching" "$(m "macOS 自带，或 brew install python" "Ships with macOS, or brew install python")"
tool curl "下载 Unity iOS 运行时" "downloading the Unity iOS runtime" "$(m "macOS 自带" "Ships with macOS")"
CERTS=$(security find-identity -v -p codesigning 2> /dev/null | grep -c "Apple Development")
if [[ "$CERTS" -gt 0 ]]; then ok "$(m "钥匙串里有 $CERTS 个 Apple Development 证书" "$CERTS Apple Development certificate(s) in the keychain")"
else bad "$(m "钥匙串里没有 Apple Development 证书" "No Apple Development certificate in the keychain")" \
         "$(m "在 Xcode → 设置 → 账户 里登录开发者账号并管理证书" "Sign in to your developer account in Xcode → Settings → Accounts and create a certificate")"; fi

log "$(m "三、游戏文件" "3. Game files")"
if [[ -d "$GAME_CONTENTS" ]]; then
  ok "$(m "找到游戏：" "Found the game: ")$GAME_APP"
  VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleGetInfoString' "$GAME_CONTENTS/Info.plist" 2> /dev/null)
  if [[ "$VER" == *"$UNITY_VERSION"* ]]; then ok "$(m "Unity 版本 $UNITY_VERSION" "Unity version $UNITY_VERSION")"
  else bad "$(m "Unity 版本不符：$VER（需要 $UNITY_VERSION）" "Unity version mismatch: $VER (need $UNITY_VERSION)")" \
           "$(m "本项目只验证过 Unity $UNITY_VERSION 的版本，见 docs/GAME_FILES.zh-CN.md" "Only the Unity $UNITY_VERSION build is supported; see docs/GAME_FILES.md")"; fi
  if lipo -archs "$GAME_CONTENTS/Frameworks/GameAssembly.dylib" 2> /dev/null | grep -q arm64; then ok "$(m "GameAssembly 含 arm64" "GameAssembly contains arm64")"
  else bad "$(m "GameAssembly.dylib 缺失或不含 arm64" "GameAssembly.dylib is missing or has no arm64 slice")" "$(m "见 docs/GAME_FILES.zh-CN.md" "See docs/GAME_FILES.md")"; fi
  BUILD_INFO="$GAME_DATA/StreamingAssets/build_info.txt"
  [[ -f "$BUILD_INFO" ]] && note "build_info: $(cat "$BUILD_INFO")"
else
  bad "$(m "找不到游戏：$GAME_APP" "Game not found: $GAME_APP")" \
      "$(m "在 Steam 里安装 Mac 版，或在 config.env 里设置 GAME_APP，见 docs/GAME_FILES.zh-CN.md" "Install the Mac version from Steam, or set GAME_APP in config.env; see docs/GAME_FILES.md")"
fi

log "$(m "四、Unity iOS 运行时" "4. Unity iOS runtime")"
if [[ -f "$TRAMPOLINE/Libraries/libiPhone-lib-il2cpp.a" ]]; then ok "$(m "已解包：" "Unpacked: ")$IOS_SUPPORT"
else note "$(m "尚未下载（约 530 MB，下一步会自动下载并校验）" "Not downloaded yet (about 530 MB; the next step downloads and verifies it)")"; fi

log "$(m "五、签名配置" "5. Signing configuration")"
if [[ -f "$ROOT/config.env" ]]; then ok "config.env"
else bad "$(m "缺少 config.env" "config.env is missing")" "cp config.example.env config.env"; fi
if [[ -n "$TEAM_ID" ]]; then
  if security find-certificate -a -c "Apple Development" -p 2> /dev/null | openssl x509 -noout -subject 2> /dev/null | grep -q "OU=$TEAM_ID"; then
    ok "TEAM_ID=$TEAM_ID"
  else
    note "$(m "TEAM_ID=$TEAM_ID（钥匙串里第一张证书的团队不是它，请确认）" "TEAM_ID=$TEAM_ID (the first certificate in the keychain belongs to another team; please double-check)")"
  fi
else
  bad "$(m "config.env 里没有设置 TEAM_ID" "TEAM_ID is not set in config.env")" \
      "$(m "填你的 10 位团队 ID（开发证书的 OU 字段）" "Fill in your 10-character Team ID (the OU field of your development certificate)")"
fi
if [[ -n "$BUNDLE_ID" ]]; then ok "BUNDLE_ID=$BUNDLE_ID"
else bad "$(m "config.env 里没有设置 BUNDLE_ID" "BUNDLE_ID is not set in config.env")" "$(m "填一个你自己的 Bundle ID，例如 com.你的名字.discoelysium" "Choose your own bundle ID, e.g. com.yourname.discoelysium")"; fi

log "$(m "六、设备（构建不需要；安装时需要）" "6. Device (not needed to build; needed to install)")"
DEV=$(resolve_device 2> /dev/null)
if [[ -n "$DEV" ]]; then ok "$(m "已配对的 iPad：" "Paired iPad: ")$DEV"
else note "$(m "没有找到已配对的实体 iPad；安装前用线连接并在 Xcode 的设备窗口里配对" "No paired physical iPad found; before installing, connect it by cable and pair it in Xcode's Devices window")"; fi

echo
if [[ $missing -gt 0 ]]; then
  echo "$(m "还缺 $missing 项。下一步：" "$missing item(s) missing. Next step:") $NEXT"
  exit 1
fi
echo "$(m "体检通过。" "Health check passed.")"
[[ "${1:-}" == check ]] && exit 0

set -e
log "$(m "开始准备（每一步做过的会跳过或增量处理）" "Preparing (steps that are already done are skipped or done incrementally)")"
make -C "$ROOT" all
echo
log "$(m "准备完成。下一步把 App 和数据装到 iPad：make install push-data run" "All set. Next, install the app and data on the iPad: make install push-data run")"
