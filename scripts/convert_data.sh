#!/bin/bash
# 把你本机 Mac 版的游戏数据转换为 iOS 布局，输出到 build/GameData（约 10 GB，同卷上为 APFS 克隆）
# Convert the game data of your local Mac version to the iOS layout, output to build/GameData (about 10 GB; APFS clones on the same volume)
source "$(dirname "$0")/common.sh"
require_game
require_ios_support

log "$(m "转换游戏数据：$GAME_DATA → $DATA_OUT" "Converting game data: $GAME_DATA → $DATA_OUT")"
python3 -I "$ROOT/tools/convert_data.py" "$GAME_DATA" "$TRAMPOLINE/Data/unity default resources" "$DATA_OUT"
