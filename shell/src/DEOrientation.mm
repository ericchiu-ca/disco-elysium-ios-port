// 强制横屏。
// Force landscape.
//
// Mac 版 globalgamemanagers 里 iOS 相关的 PlayerSettings 都是默认值，其中默认方向是竖屏，
// Unity 会据此创建 UnityPortraitOnlyViewController，盖过 Info.plist 里的横屏声明。
// The iOS-related PlayerSettings in the Mac version's globalgamemanagers are all defaults, including a default
// orientation of portrait, so Unity creates a UnityPortraitOnlyViewController that overrides the landscape
// declaration in Info.plist.
// DEAppHooks.mm 在 -[UnityAppController createUI] 之前（引擎已初始化、根视图控制器尚未创建）
// 调用 DEForceLandscape()，通过 icall 设置与托管代码等价的：
// DEAppHooks.mm calls DEForceLandscape() before -[UnityAppController createUI] (engine initialized, root view
// controller not yet created), which uses icalls to set the equivalent of this managed code:
//   Screen.autorotateToPortrait = false; Screen.autorotateToPortraitUpsideDown = false;
//   Screen.autorotateToLandscapeLeft = true; Screen.autorotateToLandscapeRight = true;
//   Screen.orientation = ScreenOrientation.AutoRotation;

#include <stdint.h>
#include <stdio.h>

extern "C" void* il2cpp_resolve_icall(const char* name);

// UnityEngine.ScreenOrientation / UnityEngine.EnabledOrientation
enum { kScreenOrientationAutoRotation = 5 };
enum
{
    kAutorotateToPortrait = 1,
    kAutorotateToPortraitUpsideDown = 2,
    kAutorotateToLandscapeLeft = 4,
    kAutorotateToLandscapeRight = 8,
};

static void ForceLandscape(void)
{
    typedef void (*SetOrientationEnabledFn)(int32_t, bool);
    typedef void (*RequestOrientationFn)(int32_t);
    auto setEnabled = (SetOrientationEnabledFn)il2cpp_resolve_icall("UnityEngine.Screen::SetOrientationEnabled");
    auto request = (RequestOrientationFn)il2cpp_resolve_icall("UnityEngine.Screen::RequestOrientation");
    if (!setEnabled || !request)
    {
        printf("[DEPort] Screen orientation icalls not found; cannot force landscape\n");
        return;
    }
    setEnabled(kAutorotateToPortrait, false);
    setEnabled(kAutorotateToPortraitUpsideDown, false);
    setEnabled(kAutorotateToLandscapeLeft, true);
    setEnabled(kAutorotateToLandscapeRight, true);
    request(kScreenOrientationAutoRotation);
    printf("[DEPort] orientation: landscape autorotation\n");
}

extern "C" void DEForceLandscape(void)
{
    ForceLandscape();
}
