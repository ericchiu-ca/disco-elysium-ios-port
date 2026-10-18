#!/bin/bash
# 从 Unity 官方 CDN 下载与游戏同版本的 iOS Support 包，只解包、不安装。
# 产物：vendor/iOSSupport/（Trampoline 模板、libiPhone-lib-il2cpp.a、baselib.a 等）
# Download the iOS Support package for the game's Unity version from Unity's official CDN; it is only unpacked, not installed.
# Output: vendor/iOSSupport/ (the Trampoline template, libiPhone-lib-il2cpp.a, baselib.a, etc.)
source "$(dirname "$0")/common.sh"

PKG_NAME="UnitySetup-iOS-Support-for-Editor-$UNITY_VERSION.pkg"
PKG_URL="https://download.unity3d.com/download_unity/$UNITY_CHANGESET/MacEditorTargetInstaller/$PKG_NAME"
PKG="$VENDOR/downloads/$PKG_NAME"

if [[ -f "$TRAMPOLINE/Libraries/libiPhone-lib-il2cpp.a" ]]; then
  log "$(m "Unity iOS 运行时已就绪：$IOS_SUPPORT" "Unity iOS runtime is ready: $IOS_SUPPORT")"
  exit 0
fi

mkdir -p "$VENDOR/downloads"
if [[ ! -f "$PKG" ]]; then
  log "$(m "下载 $PKG_URL" "Downloading $PKG_URL")"
  curl -fL --retry 3 -o "$PKG.part" "$PKG_URL"
  mv "$PKG.part" "$PKG"
fi

log "$(m "校验 SHA-256" "Verifying SHA-256")"
actual="$(shasum -a 256 "$PKG" | awk '{print $1}')"
[[ "$actual" == "$UNITY_IOS_PKG_SHA256" ]] || die "$(m "校验失败：$actual" "Checksum mismatch: $actual")"

log "$(m "解包到 $IOS_SUPPORT" "Unpacking to $IOS_SUPPORT")"
tmp="$VENDOR/.pkg-expand"
rm -rf "$tmp"
pkgutil --expand-full "$PKG" "$tmp"
rm -rf "$IOS_SUPPORT"
mv "$tmp/TargetSupport.pkg.tmp/Payload/iOSSupport" "$IOS_SUPPORT"
rm -rf "$tmp"

require_ios_support
log "$(m "完成" "Done")"
