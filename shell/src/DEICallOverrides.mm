// 在 Unity 注册完全部 icall 之后，覆盖少数几个，让为 Mac 编译的游戏代码看到与 Mac 版一致的环境。
// After Unity has registered all icalls, override a few so the game code compiled for the Mac sees the same
// environment as on the Mac.
// 由生成的 RegisterAllStrippedInternalCalls()（tools/gen_registration.py）在末尾调用。
// Called at the end of the generated RegisterAllStrippedInternalCalls() (tools/gen_registration.py).
// il2cpp 的 icall 表按名字存放，后注册的会覆盖先注册的。
// il2cpp's icall table is keyed by name, so a later registration overrides an earlier one.

#include <stdint.h>
#include <stdio.h>

#include "DEBootstrap.h"

extern "C" void il2cpp_add_internal_call(const char* name, void* method);
extern "C" void* il2cpp_string_new(const char* str);
#include "DEVirtualInput.h"

// UnityEngine.RuntimePlatform
enum { kRuntimePlatformOSXPlayer = 1, kRuntimePlatformIPhonePlayer = 8 };

// 游戏同时支持主机平台，它的平台判断里"非桌面"分支可能走主机逻辑（存档、平台服务等），
// AssetBundle 目录名也按平台拼接。只影响托管代码看到的值，引擎原生层仍然知道自己在 iOS 上。
// The game also supports consoles, so the "non-desktop" branch of its platform checks may take console code paths
// (saves, platform services, etc.), and AssetBundle directory names are also built from the platform. This only
// affects the value seen by managed code; the engine's native layer still knows it is running on iOS.
static int32_t DE_Application_get_platform()
{
    return kRuntimePlatformOSXPlayer;
}

// Mac 版的 Application.dataPath 是 .app/Contents，游戏按它拼资源路径（例如 Resources/Data/AmplifyTexture）。
// GameData 也按 Mac 的结构存放（见 tools/convert_data.py），这里让托管代码看到同样的值。
// On the Mac, Application.dataPath is .app/Contents, and the game builds asset paths from it
// (e.g. Resources/Data/AmplifyTexture). GameData is stored in the same layout as the Mac version
// (see tools/convert_data.py), so managed code is given the same value here.
static void* DE_Application_get_dataPath()
{
    return il2cpp_string_new(DEMacStyleDataPath());
}

extern "C" void DERegisterICallOverrides()
{
    il2cpp_add_internal_call("UnityEngine.Application::get_platform", (void*)DE_Application_get_platform);
    il2cpp_add_internal_call("UnityEngine.Application::get_dataPath", (void*)DE_Application_get_dataPath);
    printf("[DEPort] icall overrides installed (platform=OSXPlayer, dataPath=%s)\n", DEMacStyleDataPath());
    DEVirtualInputRegisterICalls();
}
