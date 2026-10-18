// 挂到 Unity Trampoline 生命周期上的唯一入口。
// The single entry point hooked into the Unity Trampoline lifecycle.
// -[UnityAppController createUI] 在引擎初始化之后、根视图控制器创建之前调用：
// -[UnityAppController createUI] is called after the engine is initialized and before the root view controller is created:
//   之前：强制横屏（DEOrientation.mm）
//   Before: force landscape (DEOrientation.mm)
//   之后：给 Unity 视图挂上虚拟输入手势（DEVirtualInput.mm）和屏幕按钮（DETouchOverlay.mm），
//         并开始检查画面比例（DEAspect.mm）
//   After: attach the virtual-input gestures (DEVirtualInput.mm) and on-screen buttons (DETouchOverlay.mm)
//          to the Unity view, and start checking the aspect ratio (DEAspect.mm)

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#include "UnityAppController.h"

extern "C" void DEForceLandscape(void);
#include "DEVirtualInput.h"
extern "C" void DETouchOverlayAttach(UIView* view);
extern "C" void DEAspectStart(void);
extern "C" void DEUIDiagSchedule(void);

static IMP gOrigCreateUI;

static void DE_createUI(UnityAppController* self, SEL _cmd)
{
    DEForceLandscape();
    ((void (*)(id, SEL))gOrigCreateUI)(self, _cmd);

    UIView* unityView = (UIView*)self.unityView;
    DEVirtualInputAttach(unityView);
    DETouchOverlayAttach(unityView);
    DEAspectStart();
    DEUIDiagSchedule();
}

__attribute__((constructor)) static void InstallAppHooks(void)
{
    Class cls = objc_getClass("UnityAppController");
    Method m = cls ? class_getInstanceMethod(cls, @selector(createUI)) : NULL;
    if (m) gOrigCreateUI = method_setImplementation(m, (IMP)DE_createUI);
}
