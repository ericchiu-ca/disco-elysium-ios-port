#!/bin/bash
# 把 Mac 版里与平台无关的 arm64 原生代码改标为 iOS 平台，封装成 .framework。
#   GameAssembly.dylib        → GameAssembly.framework（IL2CPP 游戏逻辑 + libil2cpp 运行时）
#   AmplifyTextureNative      → AmplifyTextureNative.framework（虚拟纹理解码；OpenGL 依赖换成 GLStub）
# 只在本机处理你自己的副本，产物位于 build/Frameworks，不进 git。
# Retag the platform-independent arm64 native code from the Mac version as iOS and wrap it into .frameworks.
#   GameAssembly.dylib        → GameAssembly.framework (IL2CPP game logic + the libil2cpp runtime)
#   AmplifyTextureNative      → AmplifyTextureNative.framework (virtual texture decoding; the OpenGL dependency is replaced with GLStub)
# Only your own copy is processed, locally; the output goes to build/Frameworks and is not committed to git.
source "$(dirname "$0")/common.sh"
require_game
require_signing_config

mkdir -p "$FW_OUT"
WORK="$BUILD/tmp/binaries"
rm -rf "$WORK"; mkdir -p "$WORK"

# Mac 系统库路径 → iOS 系统库路径
# Mac system library paths → iOS system library paths
SYS_CHANGES=(
  -change /System/Library/Frameworks/Foundation.framework/Versions/C/Foundation /System/Library/Frameworks/Foundation.framework/Foundation
  -change /System/Library/Frameworks/Security.framework/Versions/A/Security /System/Library/Frameworks/Security.framework/Security
  -change /System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation /System/Library/Frameworks/CoreFoundation.framework/CoreFoundation
  -change /System/Library/Frameworks/OpenGL.framework/Versions/A/OpenGL @rpath/GLStub.framework/GLStub
)

# retag <源 Mach-O（通用包）> <framework 名>
# retag <source Mach-O (universal binary)> <framework name>
retag() {
  local src="$1" name="$2"
  local thin="$WORK/$name.arm64" out="$WORK/$name.ios"
  local fw="$FW_OUT/$name.framework"
  log "$(m "改标 $name" "Retagging $name")"
  lipo -thin arm64 "$src" -output "$thin"
  codesign --remove-signature "$thin"
  # LC_BUILD_VERSION：平台从 macOS(1) 改为 iOS(2)
  # LC_BUILD_VERSION: platform macOS(1) → iOS(2)
  xcrun vtool -arch arm64 -set-build-version ios "$IOS_DEPLOYMENT_TARGET" "$(xcrun --sdk iphoneos --show-sdk-version)" \
    -replace -output "$out" "$thin"
  # 只对实际存在的依赖做替换，install_name_tool 遇到不存在的旧路径会静默忽略
  # Only dependencies that are actually present get replaced; install_name_tool silently ignores old paths that do not exist
  install_name_tool -id "@rpath/$name.framework/$name" "${SYS_CHANGES[@]}" "$out" 2>&1 \
    | grep -v "invalidate the code signature" || true

  rm -rf "$fw"; mkdir -p "$fw"
  mv "$out" "$fw/$name"
  write_framework_plist "$fw" "$name"
  verify_ios_macho "$fw/$name"
}

# 确认改标结果：平台是 iOS，且不再依赖任何 Mac 专有路径
# Verify the retagged result: the platform is iOS, and nothing depends on Mac-only paths any more
verify_ios_macho() {
  local f="$1"
  local plat
  plat="$(otool -l "$f" | awk '/cmd LC_BUILD_VERSION/{p=1} p&&/platform/{print $2; exit}')"
  [[ "$plat" == "2" ]] || die "$(m "$f 的平台标记不是 iOS（$plat）" "The platform tag of $f is not iOS ($plat)")"
  if otool -L "$f" | tail -n +2 | grep -E "Versions/|AppKit|Carbon|Cocoa|OpenGL.framework|IOKit" ; then
    die "$(m "$f 仍依赖 Mac 专有库（见上）" "$f still depends on Mac-only libraries (see above)")"
  fi
}

retag "$GAME_CONTENTS/Frameworks/GameAssembly.dylib" GameAssembly
retag "$GAME_CONTENTS/PlugIns/AmplifyTextureNative.bundle/Contents/MacOS/AmplifyTextureNative" AmplifyTextureNative

log "$(m "GameAssembly 依赖：" "GameAssembly dependencies:")"
otool -L "$FW_OUT/GameAssembly.framework/GameAssembly" | tail -n +2
log "$(m "AmplifyTextureNative 依赖：" "AmplifyTextureNative dependencies:")"
otool -L "$FW_OUT/AmplifyTextureNative.framework/AmplifyTextureNative" | tail -n +2

rm -rf "$WORK"
log "$(m "完成：$FW_OUT" "Done: $FW_OUT")"
