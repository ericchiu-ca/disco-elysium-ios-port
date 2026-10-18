#!/bin/bash
# 构建 iOS 上替代 Mac 专有原生库的桩 framework，输出到 build/Frameworks：
#   GLStub              AmplifyTextureNative 引用的 13 个 OpenGL 函数（Metal 下不会走到）
#   steam_api           Steamworks，全部报告"Steam 不可用"
#   GalaxyCSharpGlue    GOG Galaxy SWIG 胶水层
#   InControlNative     InControl 的 HID 原生层（触屏版暂不需要手柄）
# Build the stub frameworks that replace Mac-only native libraries on iOS, output to build/Frameworks:
#   GLStub              the 13 OpenGL functions referenced by AmplifyTextureNative (never reached under Metal)
#   steam_api           Steamworks; everything reports "Steam unavailable"
#   GalaxyCSharpGlue    the GOG Galaxy SWIG glue layer
#   InControlNative     InControl's native HID layer (the touch version does not need a gamepad for now)
source "$(dirname "$0")/common.sh"
require_game
require_signing_config

WORK="$BUILD/tmp/stubs"
rm -rf "$WORK"; mkdir -p "$WORK" "$FW_OUT"
GEN="$ROOT/tools/gen_stub.py"
STUBS_SRC="$ROOT/shell/stubs"

compile_framework() { # <名称> <源文件.c> | <name> <source.c>
  local name="$1" src="$2" fw="$FW_OUT/$1.framework"
  rm -rf "$fw"; mkdir -p "$fw"
  xcrun --sdk iphoneos clang -target "arm64-apple-ios$IOS_DEPLOYMENT_TARGET" \
    -dynamiclib -O1 -fvisibility=hidden -Wno-incompatible-library-redeclaration \
    -install_name "@rpath/$name.framework/$name" -o "$fw/$name" "$src"
  write_framework_plist "$fw" "$name"
}

AMPLIFY_MAC="$GAME_CONTENTS/PlugIns/AmplifyTextureNative.bundle/Contents/MacOS/AmplifyTextureNative"
python3 -I "$GEN" undefined "$AMPLIFY_MAC" gl GLStub "$WORK/GLStub.c"
compile_framework GLStub "$WORK/GLStub.c"

python3 -I "$GEN" exports "$GAME_CONTENTS/PlugIns/steam_api.bundle/Contents/MacOS/libsteam_api.dylib" \
  steam_api "$WORK/steam_api.c" --overrides "$STUBS_SRC/steam_api_overrides.c"
compile_framework steam_api "$WORK/steam_api.c"

python3 -I "$GEN" exports "$GAME_CONTENTS/PlugIns/libGalaxyCSharpGlue.dylib" GalaxyCSharpGlue "$WORK/GalaxyCSharpGlue.c"
compile_framework GalaxyCSharpGlue "$WORK/GalaxyCSharpGlue.c"

python3 -I "$GEN" exports "$GAME_CONTENTS/PlugIns/InControlNative.bundle/Contents/MacOS/InControlNative" \
  InControlNative "$WORK/InControlNative.c"
compile_framework InControlNative "$WORK/InControlNative.c"

rm -rf "$WORK"
log "$(m "桩库已生成：" "Stub libraries generated: ")$(cd "$FW_OUT" && ls -d GLStub.framework steam_api.framework GalaxyCSharpGlue.framework InControlNative.framework | tr '\n' ' ')"
