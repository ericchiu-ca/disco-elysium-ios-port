#!/bin/bash
# 设备操作（通过 xcrun devicectl，USB 或同一 Wi-Fi 下的已配对 iPad）
#   install     安装 App
#   push-data   把 build/GameData 推送到 App 沙盒 Documents/GameData（只传有变化的文件）
#   run         启动 App，并把游戏的 stdout 实时显示在终端（Ctrl-C 结束）
#   logs        取回 Documents/Logs（Player.log 与上一次的 Player-prev.log）到 build/logs
# Device operations (via xcrun devicectl, on a paired iPad connected over USB or on the same Wi-Fi network)
#   install     install the app
#   push-data   push build/GameData to Documents/GameData in the app sandbox (only changed files are transferred)
#   run         launch the app and stream the game's stdout to the terminal (Ctrl-C to stop)
#   logs        fetch Documents/Logs (Player.log and the previous run's Player-prev.log) into build/logs
source "$(dirname "$0")/common.sh"
require_signing_config

APP="$BUILD/DerivedData/Build/Products/Release-iphoneos/DiscoElysium.app"
DEV="$(resolve_device)"
cmd="${1:-}"

case "$cmd" in
  install)
    [[ -d "$APP" ]] || die "$(m "先运行 make build" "Run make build first")"
    log "$(m "安装到 $DEV" "Installing to $DEV")"
    xcrun devicectl device install app --device "$DEV" "$APP"
    ;;
  push-data)
    [[ -f "$DATA_OUT/de-port.json" ]] || die "$(m "先运行 make data" "Run make data first")"
    log "$(m "推送 " "Pushing ")$(du -sh "$DATA_OUT" | cut -f1)$(m " 游戏数据到 $DEV（首次较慢；之后只传变化的文件）" " of game data to $DEV (slow the first time; afterwards only changed files are transferred)")"
    # 不能加 --remove-existing-content true：它清空的是 Documents 整个目录（实测），存档 SaveGames、Logs 等会一起被删
    # Never add --remove-existing-content true: it empties the whole Documents directory (tested), deleting SaveGames, Logs and the rest
    xcrun devicectl device copy to --device "$DEV" \
      --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
      --source "$DATA_OUT" --destination Documents/GameData
    ;;
  run)
    # SNAPSHOT_EVERY=<秒>：调试用，定时把画面存到 Documents/Logs/snap-*.jpg（make logs 取回）
    # SNAPSHOT_EVERY=<seconds>: for debugging, periodically saves the screen to Documents/Logs/snap-*.jpg (fetch them with make logs)
    log "$(m "启动 $BUNDLE_ID（日志直接输出到终端）" "Launching $BUNDLE_ID (logs go straight to the terminal)")"
    DEVICECTL_CHILD_DE_LOG_TO_CONSOLE=1 DEVICECTL_CHILD_DE_SNAPSHOT_EVERY="${SNAPSHOT_EVERY:-}" \
      xcrun devicectl device process launch --device "$DEV" --terminate-existing --console "$BUNDLE_ID"
    ;;
  logs)
    mkdir -p "$BUILD/logs"
    xcrun devicectl device copy from --device "$DEV" \
      --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
      --source Documents/Logs --destination "$BUILD/logs"
    log "$(m "日志在 $BUILD/logs" "Logs are in $BUILD/logs")"
    ;;
  *)
    die "$(m "用法：scripts/device.sh install|push-data|run|logs" "Usage: scripts/device.sh install|push-data|run|logs")"
    ;;
esac
