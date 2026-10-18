#!/bin/bash
# 编译并签名 App（不含游戏数据）。首次运行会在你的开发者账号里注册 Bundle ID 和描述文件。
# 用法：scripts/build.sh [--no-sign]
# Build and sign the app (without the game data). The first run registers the bundle ID and a provisioning profile in your developer account.
# Usage: scripts/build.sh [--no-sign]
source "$(dirname "$0")/common.sh"
require_signing_config
[[ -d "$XCODE_OUT/DiscoElysium.xcodeproj" ]] || die "$(m "先运行 make project" "Run make project first")"

SIGN_ARGS=(-allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM_ID")
if [[ "${1:-}" == "--no-sign" ]]; then SIGN_ARGS=(CODE_SIGNING_ALLOWED=NO); fi

LOGFILE="$BUILD/xcodebuild.log"
log "$(m "xcodebuild（参考环境 M5 Mac 上约 10 秒）日志：$LOGFILE" "xcodebuild (about 10 s on the reference M5 Mac), log: $LOGFILE")"
set +e
xcodebuild -project "$XCODE_OUT/DiscoElysium.xcodeproj" -scheme DiscoElysium -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$BUILD/DerivedData" \
  "${SIGN_ARGS[@]}" build > "$LOGFILE" 2>&1
status=$?
set -e
grep -E "error:|warning: .*(provision|sign)|BUILD (SUCCEEDED|FAILED)" "$LOGFILE" | sort -u | tail -20
[[ $status -eq 0 ]] || die "$(m "构建失败，详见 $LOGFILE" "Build failed, see $LOGFILE")"
log "$(m "App：$BUILD/DerivedData/Build/Products/Release-iphoneos/DiscoElysium.app" "App: $BUILD/DerivedData/Build/Products/Release-iphoneos/DiscoElysium.app")"
