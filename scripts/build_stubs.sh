#!/bin/bash
# 构建 iOS 上替代 Mac 专有原生库的桩 framework，输出到 build/Frameworks：
#   GLStub              AmplifyTextureNative 引用的 13 个 OpenGL 函数（Metal 下不会走到）
#   steam_api           Steamworks，全部报告"Steam 不可用"；ACH_RELAY=1 时换成成就模式（shell/stubs/steam_relay.c）
#   GalaxyCSharpGlue    GOG Galaxy SWIG 胶水层
#   InControlNative     InControl 的 HID 原生层（触屏版暂不需要手柄）
# Build the stub frameworks that replace Mac-only native libraries on iOS, output to build/Frameworks:
#   GLStub              the 13 OpenGL functions referenced by AmplifyTextureNative (never reached under Metal)
#   steam_api           Steamworks; everything reports "Steam unavailable"; with ACH_RELAY=1, achievement mode instead (shell/stubs/steam_relay.c)
#   GalaxyCSharpGlue    the GOG Galaxy SWIG glue layer
#   InControlNative     InControl's native HID layer (the touch version does not need a gamepad for now)
source "$(dirname "$0")/common.sh"
require_game
require_signing_config

WORK="$BUILD/tmp/stubs"
rm -rf "$WORK"; mkdir -p "$WORK" "$FW_OUT"
GEN="$ROOT/tools/gen_stub.py"
STUBS_SRC="$ROOT/shell/stubs"

compile_framework() { # <名称> <源文件.c> [额外的编译参数...] | <name> <source.c> [extra compiler arguments...]
  local name="$1" src="$2" fw="$FW_OUT/$1.framework"
  shift 2
  rm -rf "$fw"; mkdir -p "$fw"
  xcrun --sdk iphoneos clang -target "arm64-apple-ios$IOS_DEPLOYMENT_TARGET" \
    -dynamiclib -O1 -fvisibility=hidden -Wno-incompatible-library-redeclaration \
    -install_name "@rpath/$name.framework/$name" -o "$fw/$name" "$src" "$@"
  write_framework_plist "$fw" "$name"
}

AMPLIFY_MAC="$GAME_CONTENTS/PlugIns/AmplifyTextureNative.bundle/Contents/MacOS/AmplifyTextureNative"
python3 -I "$GEN" undefined "$AMPLIFY_MAC" gl GLStub "$WORK/GLStub.c"
compile_framework GLStub "$WORK/GLStub.c"

# 成就模式：把 Mac 的地址、端口、配对密钥编进桩库（只在你自己的构建里，config.env 不进 git）
# Achievement mode: the Mac's address, port and pairing secret are compiled into the stub (only in your own build; config.env is not in git)
STEAM_OVERRIDES="$STUBS_SRC/steam_api_overrides.c"
STEAM_FLAGS=()
if [[ "$ACH_RELAY" == 1 ]]; then
  require_relay_config
  STEAM_OVERRIDES="$STUBS_SRC/steam_relay.c"
  STEAM_FLAGS=(-DDE_STEAM_APP_ID="${STEAM_APP_ID}u" -DDE_RELAY_HOST="\"$(relay_host)\"" -DDE_RELAY_PORT="\"$ACH_RELAY_PORT\""
               -DDE_RELAY_SECRET="\"$ACH_RELAY_SECRET\"" -framework CoreFoundation)
  log "$(m "Steam 桩库：成就模式，转发到 $(relay_host):$ACH_RELAY_PORT" "Steam stub: achievement mode, relaying to $(relay_host):$ACH_RELAY_PORT")"
fi
python3 -I "$GEN" exports "$GAME_CONTENTS/PlugIns/steam_api.bundle/Contents/MacOS/libsteam_api.dylib" \
  steam_api "$WORK/steam_api.c" --overrides "$STEAM_OVERRIDES"
compile_framework steam_api "$WORK/steam_api.c" ${STEAM_FLAGS[@]+"${STEAM_FLAGS[@]}"}

# 成就模式下 GalaxyInstance.User() 要返回非空对象，否则游戏的 Achievements.Set 会在调用 Steam 之前抛出异常
# In achievement mode GalaxyInstance.User() must return a non-null object, otherwise the game's Achievements.Set throws before it calls Steam
GALAXY_OVERRIDES=()
[[ "$ACH_RELAY" == 1 ]] && GALAXY_OVERRIDES=(--overrides "$STUBS_SRC/galaxy_relay.c")
python3 -I "$GEN" exports "$GAME_CONTENTS/PlugIns/libGalaxyCSharpGlue.dylib" GalaxyCSharpGlue "$WORK/GalaxyCSharpGlue.c" \
  ${GALAXY_OVERRIDES[@]+"${GALAXY_OVERRIDES[@]}"}
compile_framework GalaxyCSharpGlue "$WORK/GalaxyCSharpGlue.c"

python3 -I "$GEN" exports "$GAME_CONTENTS/PlugIns/InControlNative.bundle/Contents/MacOS/InControlNative" \
  InControlNative "$WORK/InControlNative.c"
compile_framework InControlNative "$WORK/InControlNative.c"

rm -rf "$WORK"
log "$(m "桩库已生成：" "Stub libraries generated: ")$(cd "$FW_OUT" && ls -d GLStub.framework steam_api.framework GalaxyCSharpGlue.framework InControlNative.framework | tr '\n' ' ')"
