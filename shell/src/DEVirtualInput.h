#pragma once

#ifdef __OBJC__
#import <Foundation/Foundation.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

// UnityEngine.KeyCode 中本移植用到的几个键
// The few UnityEngine.KeyCode keys used by this port
enum
{
    DEKeyTab = 9,
    DEKeyEscape = 27,
    DEKeyC = 99,
    DEKeyI = 105,
    DEKeyJ = 106,
    DEKeyM = 109,
    DEKeyT = 116,
};

// 由生成的 RegisterAllStrippedInternalCalls()（经 DEICallOverrides.mm）调用
// Called by the generated RegisterAllStrippedInternalCalls() (via DEICallOverrides.mm)
void DEVirtualInputRegisterICalls(void);

#ifdef __OBJC__
@class UIView;
void DEVirtualInputAttach(UIView* view);

// 锁定键被自动松开时发出（例如在游戏里点击时松开高亮），屏幕按钮据此更新外观
// Posted when latched keys are released automatically (e.g. the highlight is released on a click in the game);
// on-screen buttons update their appearance accordingly
extern NSString* const DEVirtualKeysReleasedNotification;
#endif

// 按键注入：都按帧排队，保证游戏能读到 GetKeyDown / GetKeyUp
// Key injection: everything is queued per frame so the game is guaranteed to see GetKeyDown / GetKeyUp
void DEVirtualKey(int keyCode, bool down);
void DEVirtualKeyTap(int keyCode);
// 标记一个已按下的键为"锁定"：在游戏里点击前会自动松开
// Mark an already-pressed key as "latched": it is released automatically before a click in the game
void DEVirtualKeyLatch(int keyCode);

#ifdef __cplusplus
}
#endif
