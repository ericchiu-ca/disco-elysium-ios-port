#!/bin/bash
# 设备冒烟测试：启动已安装的 App（不做任何点按），收集游戏日志与定时截图，逐项检查关键标记并给出通过/失败。
# On-device smoke test: launch the installed app (no taps at all), collect the game log and timed snapshots,
# check the key markers one by one and report pass / fail.
#
# 前提：make install push-data 已完成，iPad 已解锁并连接 | Prerequisites: make install push-data done, iPad unlocked and connected
# 用法：scripts/smoke_test.sh [运行秒数，默认 75] | Usage: scripts/smoke_test.sh [seconds to run, default 75]
# 结果保存在 build/smoke/<时间>/ | Results are saved under build/smoke/<timestamp>/
source "$(dirname "$0")/common.sh"
require_signing_config

SECONDS_TO_RUN="${1:-75}"
DEV="$(resolve_device)"
OUT="$BUILD/smoke/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT/device"
CONSOLE="$OUT/console.log"

log "$(m "在 $DEV 上运行 ${SECONDS_TO_RUN} 秒（不点按），日志：$CONSOLE" "Running for ${SECONDS_TO_RUN}s on $DEV (no taps); log: $CONSOLE")"
# perl 的 alarm 在到时后结束 devicectl，App 随之以 signal 14 结束，这是正常的
# perl's alarm ends devicectl when time is up and the app then ends with signal 14; that is expected
set +e
DEVICECTL_CHILD_DE_LOG_TO_CONSOLE=1 DEVICECTL_CHILD_DE_SNAPSHOT_EVERY=15 \
  perl -e 'alarm shift; exec @ARGV' "$SECONDS_TO_RUN" \
  xcrun devicectl device process launch --device "$DEV" --terminate-existing --console "$BUNDLE_ID" > "$CONSOLE" 2>&1
xcrun devicectl device copy from --device "$DEV" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
  --source Documents/Logs --destination "$OUT/device" > /dev/null 2>&1
# Documents/Logs 里还留着以前运行的截图（编号每次从 000 开始，旧的不会被删）。只保留这次日志里写明已保存的，
# 免得这次提前结束时，把以前的 snap-003.jpg 当成这次的结果
# Documents/Logs still holds snapshots from earlier runs (numbering restarts at 000 and old files are not deleted).
# Keep only those this run's log says were saved, so that if this run ends early an old snap-003.jpg is not taken for this run's result
SAVED=$(grep -oE '\[DEPort\] snapshot snap-[0-9]+\.jpg saved' "$CONSOLE" | awk '{print $3}' | sort -u)
for f in "$OUT/device"/snap-*.jpg; do
  [[ -e "$f" ]] || continue
  echo "$SAVED" | grep -qx "$(basename "$f")" || rm -f "$f"
done
set -e

pass=0
fail=0
check() {  # 中文名 英文名 正则 | name (zh), name (en), regex
  if grep -E -q "$3" "$CONSOLE"; then
    echo "  ✓ $(m "$1" "$2")"; pass=$((pass + 1))
  else
    echo "  ✗ $(m "$1" "$2")  ($(m "日志里没有" "not in the log"): $3)"; fail=$((fail + 1))
  fi
}
absent() {  # 中文名 英文名 正则：日志里不应出现 | name (zh), name (en), regex that must not appear in the log
  local n
  n=$(grep -E -c "$3" "$CONSOLE" || true)
  if [[ "$n" -eq 0 ]]; then
    echo "  ✓ $(m "$1" "$2")"; pass=$((pass + 1))
  else
    echo "  ✗ $(m "$1" "$2")  ($n × $3)"; fail=$((fail + 1))
  fi
}

log "$(m "检查" "Checks")"
check "外壳启动并找到游戏数据" "Shell started and found the game data" '\[DEPort\] GameData: '
check "il2cpp icall 覆盖已安装" "il2cpp icall overrides installed" '\[DEPort\] icall overrides installed'
check "虚拟输入已启用" "Virtual input enabled" '\[DEPort\] virtual input enabled'
check "屏幕按钮已挂载" "Touch overlay attached" '\[DEPort\] touch overlay attached'
check "强制横屏" "Forced landscape" '\[DEPort\] orientation: landscape autorotation'
check "Unity 引擎初始化" "Unity engine initialized" 'Initialize engine version: '
check "全部场景加载完成" "All scenes loaded" 'TOTAL SCENE LOADING took'
check "进入主菜单" "Reached the main menu" 'Scene Loading Scenes/Lobby'
check "相机比例铺满屏幕" "Camera aspect set to the screen" '\[DEPort\] aspect: wantedAspectRatio .* -> '
check "HUD 框铺满屏幕" "HUD frame resized to the screen" '\[DEPort\] aspect: Global UI Fitter '
absent "没有缺失的引擎方法" "No missing engine methods" 'MissingMethodException'
absent "没有找不到的原生库" "No missing native libraries" 'DllNotFoundException|EntryPointNotFoundException'
absent "没有崩溃" "No crash" 'App terminated due to signal ([0-9]|1[0-35-9]|[2-9][0-9])([^0-9]|$)'

if grep -q '\[DEPort\] BC textures: hardware' "$CONSOLE"; then
  absent "BC 纹理走硬件，没有 CPU 解压" "BC textures in hardware, none decompressed on the CPU" 'decompressing texture'
else
  warn "$(m "这台设备没有启用硬件 BC 纹理（会在 CPU 上解压，内存占用更高）：" "Hardware BC textures are not enabled on this device (they are decompressed on the CPU, using more memory):") $(grep '\[DEPort\] BC textures' "$CONSOLE" | head -1)"
fi

# 成就模式（ACH_RELAY=1）：桩库已启用，游戏也选用了 Steam 成就后端（没有成就模式时它打印 NONE）
# Achievement mode (ACH_RELAY=1): the stub is active and the game picked its Steam achievement backend (it prints NONE without achievement mode)
if [[ "$ACH_RELAY" == 1 ]]; then
  check "Steam 成就模式已启用" "Steam achievement mode on" '\[DEPort\] steam relay: mode on'
  check "游戏初始化了成就后端" "The game initialized an achievement backend" 'INITIALIZE ACHIEVEMENTS: '
  absent "游戏没有退回到无成就模式" "The game did not fall back to no achievements" 'INITIALIZE ACHIEVEMENTS: +NONE'
  RELAY_LINE=$(grep -E '\[DEPort\] steam relay: (connected|cannot|the Mac)' "$CONSOLE" | head -1 | sed 's/.*steam relay: //' || true)
  [[ -n "$RELAY_LINE" ]] && log "$(m "转发：" "Relay: ")$RELAY_LINE"
fi

MEM=$(grep '\[DEPort\] memory footprint' "$CONSOLE" | tail -1 | sed 's/.*memory footprint //' || true)
[[ -n "$MEM" ]] && log "$(m "内存：" "Memory: ")$MEM"
log "$(m "截图（每 15 秒一张）：" "Snapshots (one every 15 s): ")$OUT/device"
echo "    $(m "这次运行保存的（以前的已去掉）：" "Saved in this run (earlier ones removed): ")$(echo ${SAVED:-$(m "无" "none")})"
echo "    $(m "snap-000 ≈ 15 秒：启动画面（版权声明或 ZA/UM 动画）应铺满全屏，上下不露出主菜单" "snap-000 ≈ 15 s: the start-up screen (legal notice or ZA/UM animation) should fill the screen with no main menu showing at the top or bottom")"
echo "    $(m "snap-003 ≈ 60 秒：主菜单应铺满全屏、横屏、无黑边" "snap-003 ≈ 60 s: the main menu should fill the screen, landscape, without black bars")"

echo
if [[ $fail -gt 0 ]]; then
  echo "$(m "冒烟测试未通过：$pass 项通过，$fail 项失败。排查方法见 docs/VERIFY.zh-CN.md" "Smoke test FAILED: $pass passed, $fail failed. See docs/VERIFY.md for troubleshooting")"
  exit 1
fi
echo "$(m "冒烟测试通过（$pass 项）。截图请再人工或用图像模型核对一遍。" "Smoke test PASSED ($pass checks). Please also review the snapshots by eye or with an image-capable model.")"
