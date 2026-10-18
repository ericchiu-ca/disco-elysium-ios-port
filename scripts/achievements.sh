#!/bin/bash
# Steam 成就（见 docs/ACHIEVEMENTS.zh-CN.md）。全部通过这台 Mac 上已登录的 Steam 客户端完成：
#   list               列出全部成就和解锁状态（只读）
#   unlock <ID>...     手动解锁在 iPad 上拿到、但没有记录下来的成就（会先确认）
#   sync               经 USB / 已配对的 Wi-Fi：取回 iPad 记下的成就，提交到 Steam，再把最新状态写回 iPad
#   pair               生成配对密钥写进 config.env（之后要重新 make stubs build install）
#   serve [--dry-run]  在前台运行实时转发服务（Ctrl-C 结束）
#   install            把实时转发服务装成登录后自动运行的后台服务
#   uninstall          卸载后台服务
#   status             查看后台服务状态和最近的日志
# Steam achievements (see docs/ACHIEVEMENTS.md). Everything goes through the Steam client logged in on this Mac:
#   list               list every achievement and whether it is unlocked (read-only)
#   unlock <id>...     unlock by hand achievements earned on the iPad that were not recorded (asks first)
#   sync               over USB / paired Wi-Fi: fetch the achievements recorded on the iPad, commit them to Steam,
#                      then write the current state back to the iPad
#   pair               generate the pairing secret into config.env (then run make stubs build install again)
#   serve [--dry-run]  run the live relay in the foreground (Ctrl-C to stop)
#   install            install the live relay as a background service that starts when you log in
#   uninstall          remove the background service
#   status             show the background service's status and its recent log
source "$(dirname "$0")/common.sh"

cmd="${1:-}"
shift || true

# macOS 自带的 Python：Apple 签名的系统软件默认被防火墙放行，不会弹出"是否接受传入连接"
# macOS's own Python: Apple-signed system software is allowed through the firewall by default, so no
# "accept incoming connections?" prompt appears
PY=/usr/bin/python3
TOOL="$ROOT/tools/steam_relay.py"
STEAM_LIB="$GAME_CONTENTS/PlugIns/steam_api.bundle/Contents/MacOS/libsteam_api.dylib"
LABEL="${BUNDLE_ID:-de-port}.steam-relay"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
# 后台服务的副本放在 ~/Library 下：launchd 启动的进程默认读不了 ~/Documents（隐私保护）
# The background service's copy lives under ~/Library: processes started by launchd cannot read ~/Documents by default (privacy protection)
SERVICE_DIR="$HOME/Library/Application Support/DEPortSteamRelay"
SERVICE_LOG="$HOME/Library/Logs/DEPortSteamRelay.log"

steam_env() {
  require_game
  [[ -f "$STEAM_LIB" ]] || die "$(m "找不到游戏的 libsteam_api.dylib：$STEAM_LIB" "The game's libsteam_api.dylib was not found: $STEAM_LIB")"
  export DE_STEAM_LIB="$STEAM_LIB" DE_STEAM_APP_ID="$STEAM_APP_ID"
  export DE_RELAY_PORT="$ACH_RELAY_PORT" DE_RELAY_SECRET="$ACH_RELAY_SECRET"
}

require_steam_running() {
  pgrep -x steam_osx > /dev/null || die "$(m "Steam 没有在运行：先打开 Steam 并登录" "Steam is not running: open Steam and log in first")"
}

case "$cmd" in
  list)
    steam_env; require_steam_running
    "$PY" -I "$TOOL" list
    ;;
  unlock)
    steam_env; require_steam_running
    [[ $# -gt 0 ]] || die "$(m "用法：make achievements-unlock NAMES=\"ACH_KIM ACH_CUNO\"" "Usage: make achievements-unlock NAMES=\"ACH_KIM ACH_CUNO\"")"
    "$PY" -I "$TOOL" unlock "$@"
    ;;
  sync)
    steam_env; require_steam_running; require_signing_config
    DEV="$(resolve_device)"
    OUT="$BUILD/achievements"
    mkdir -p "$OUT"
    rm -f "$OUT/pending.txt" "$OUT/state.txt"
    log "$(m "从 iPad 取回记下的成就" "Fetching the recorded achievements from the iPad")"
    if ! xcrun devicectl device copy from --device "$DEV" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
         --source Documents/Achievements/pending.txt --destination "$OUT/pending.txt" > /dev/null 2>&1; then
      log "$(m "iPad 上没有待同步的成就" "No achievements waiting on the iPad")"
      : > "$OUT/pending.txt"
    fi
    "$PY" -I "$TOOL" sync "$OUT/pending.txt" "$OUT/state.txt"
    log "$(m "把 Steam 上的最新状态写回 iPad（App 下次启动时读取，已提交的记录随之清除）" "Writing Steam's current state back to the iPad (the app reads it at its next start and clears the committed entries)")"
    xcrun devicectl device copy to --device "$DEV" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
      --source "$OUT/state.txt" --destination Documents/Achievements/state.txt > /dev/null
    log "$(m "同步完成" "Sync complete")"
    ;;
  pair)
    [[ -f "$ROOT/config.env" ]] || die "$(m "先创建 config.env（cp config.example.env config.env）" "Create config.env first (cp config.example.env config.env)")"
    SECRET="$(openssl rand -hex 16)"
    # 只改 config.env 里的 ACH_RELAY_SECRET 一行，没有就追加 | Change only the ACH_RELAY_SECRET line in config.env, appending it if missing
    if grep -q '^ACH_RELAY_SECRET=' "$ROOT/config.env"; then
      sed -i '' "s/^ACH_RELAY_SECRET=.*/ACH_RELAY_SECRET=\"$SECRET\"/" "$ROOT/config.env"
    else
      printf 'ACH_RELAY_SECRET="%s"\n' "$SECRET" >> "$ROOT/config.env"
    fi
    log "$(m "已生成新的配对密钥。接下来：make stubs build install（iPad 上的 App 要带上新密钥），后台服务装过的话再 make relay-install" "A new pairing secret was generated. Next: make stubs build install (the app on the iPad needs the new secret), and make relay-install again if the background service is installed")"
    ;;
  serve)
    steam_env
    [[ -n "$ACH_RELAY_SECRET" ]] || die "$(m "还没有配对密钥：先 make relay-pair" "No pairing secret yet: run make relay-pair first")"
    exec "$PY" -I "$TOOL" serve "$@"
    ;;
  install)
    steam_env
    [[ -n "$ACH_RELAY_SECRET" ]] || die "$(m "还没有配对密钥：先 make relay-pair" "No pairing secret yet: run make relay-pair first")"
    mkdir -p "$SERVICE_DIR" "$(dirname "$AGENT")" "$(dirname "$SERVICE_LOG")"
    cp "$TOOL" "$SERVICE_DIR/steam_relay.py"
    # 配置（含配对密钥）写进 plist 的环境变量，文件只有自己可读
    # The configuration (pairing secret included) goes into the plist's environment variables; only you can read the file
    umask 077
    cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PY</string><string>-I</string><string>$SERVICE_DIR/steam_relay.py</string><string>serve</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>DE_STEAM_LIB</key><string>$STEAM_LIB</string>
    <key>DE_STEAM_APP_ID</key><string>$STEAM_APP_ID</string>
    <key>DE_RELAY_PORT</key><string>$ACH_RELAY_PORT</string>
    <key>DE_RELAY_SECRET</key><string>$ACH_RELAY_SECRET</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$SERVICE_LOG</string>
  <key>StandardErrorPath</key><string>$SERVICE_LOG</string>
</dict>
</plist>
EOF
    launchctl bootout "gui/$(id -u)/$LABEL" 2> /dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$AGENT"
    log "$(m "后台服务已安装并启动（$LABEL），日志：$SERVICE_LOG" "Background service installed and started ($LABEL), log: $SERVICE_LOG")"
    ;;
  uninstall)
    launchctl bootout "gui/$(id -u)/$LABEL" 2> /dev/null || true
    rm -f "$AGENT"
    rm -rf "$SERVICE_DIR"
    log "$(m "后台服务已卸载" "Background service removed")"
    ;;
  status)
    if launchctl print "gui/$(id -u)/$LABEL" > /dev/null 2>&1; then
      log "$(m "后台服务已安装：" "Background service installed: ")$(launchctl print "gui/$(id -u)/$LABEL" | awk '/state =/ {print $3; exit}')"
    else
      log "$(m "后台服务没有安装（make relay-install）" "Background service not installed (make relay-install)")"
    fi
    pgrep -x steam_osx > /dev/null && echo "  Steam: $(m "运行中" "running")" || echo "  Steam: $(m "没有运行" "not running")"
    [[ -f "$SERVICE_LOG" ]] && tail -n 15 "$SERVICE_LOG"
    ;;
  *)
    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
