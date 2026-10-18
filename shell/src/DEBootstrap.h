#pragma once

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// 游戏数据根目录：<Documents>/GameData，Unity 会在其下读取 Data/
// Game data root directory: <Documents>/GameData; Unity reads Data/ under it
const char* DEGameRoot(void);

// 数据是否完整可用；不可用时 reason 指向一段说明文字
// Whether the data is complete and usable; if not, reason points to an explanatory message
bool DEGameDataAvailable(const char** reason);

// 必须在 Unity 初始化之前调用：日志重定向、il2cpp 插件查找回调、iCloud 备份排除
// Must be called before Unity initializes: log redirection, il2cpp plugin lookup callback, iCloud backup exclusion
void DEBootstrapEarly(void);

// 供 Trampoline 的 UnityDataBundleDir() 调用（见 tools/patch_trampoline.py）
// Called by the Trampoline's UnityDataBundleDir() (see tools/patch_trampoline.py)
const char* DEUnityDataBundleDir(void);

// 托管代码看到的 Application.dataPath（Mac 语义：<GameData>/Contents）
// The Application.dataPath seen by managed code (Mac semantics: <GameData>/Contents)
const char* DEMacStyleDataPath(void);

#ifdef __cplusplus
}
#endif
