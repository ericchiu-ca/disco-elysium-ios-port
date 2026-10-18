// Steam 桩库的手写部分。iPad 上没有 Steam 客户端，所有入口都报告"Steam 不可用"，
// 游戏按无平台服务模式运行（没有成就、云存档，存档只保存在本机）。
// Hand-written part of the Steam stub library. There is no Steam client on iPad, so every entry point reports
// "Steam unavailable" and the game runs without platform services (no achievements or cloud saves; saves are
// stored on the device only).

#include <stdbool.h>

// override: SteamAPI_RestartAppIfNecessary
__attribute__((visibility("default"))) bool SteamAPI_RestartAppIfNecessary(uint32_t appId)
{
    os_log(de_stub_log(), "steam_api stub: RestartAppIfNecessary(%u) -> false", appId);
    return false;
}

// override: SteamAPI_Init
__attribute__((visibility("default"))) bool SteamAPI_Init(void)
{
    os_log(de_stub_log(), "steam_api stub: SteamAPI_Init -> false");
    return false;
}

// override: SteamAPI_IsSteamRunning
__attribute__((visibility("default"))) bool SteamAPI_IsSteamRunning(void)
{
    return false;
}

// 新版 SDK 的初始化入口返回 ESteamAPIInitResult，0 表示成功，所以不能用默认的"返回 0"
// The newer SDK's init entry point returns ESteamAPIInitResult, where 0 means success, so the default "return 0" cannot be used
// override: SteamInternal_SteamAPI_Init
__attribute__((visibility("default"))) int SteamInternal_SteamAPI_Init(const char* versions, char* errMsg)
{
    (void)versions;
    if (errMsg) errMsg[0] = 0;
    os_log(de_stub_log(), "steam_api stub: SteamInternal_SteamAPI_Init -> FailedGeneric");
    return 1;  // k_ESteamAPIInitResult_FailedGeneric
}
