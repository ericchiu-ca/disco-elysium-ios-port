// 虚拟输入：把触屏手势（以及触控板、Apple Pencil 悬停）和屏幕按钮转换成游戏能理解的鼠标/键盘输入。
// Virtual input: turns touch gestures (plus trackpad and Apple Pencil hover) and on-screen buttons into mouse/keyboard
// input the game understands.
//
// 极乐迪斯科完全按鼠标设计：悬停高亮、悬停查看说明、单击行走/交互、双击跑步。
// Disco Elysium is designed entirely around the mouse: hover to highlight, hover to read descriptions, click to
// walk/interact, double-click to run.
// Unity 自带的"触摸模拟鼠标"只能做到按下即点击，无法单独悬停；iOS 版 Unity 注入的按键
// 在两帧之间发生时还会丢掉"本帧按下"。所以这里在 il2cpp icall 层接管 UnityEngine.Input 的
// 鼠标与按键接口，由一个逐帧推进的队列提供输入；硬件键盘仍走 Unity 原来的路径（结果取并集）。
// Unity's built-in "touch simulates mouse" can only click on touch-down and cannot hover on its own, and key presses
// injected by iOS Unity lose the "pressed this frame" state when they land between frames. So this module takes over
// UnityEngine.Input's mouse and key APIs at the il2cpp icall layer and serves input from a queue that advances one
// frame at a time; hardware keyboards still go through Unity's original path (the results are OR-ed together).
// 托管代码看到 touchCount = 0、mousePresent = true，UI 系统和游戏逻辑都走鼠标路径。
// Managed code sees touchCount = 0 and mousePresent = true, so both the UI system and the game logic take the mouse path.
//
// 手势：
// Gestures:
//   单指轻点          → 光标移到该处，下一帧按下左键，再下一帧松开（保证悬停先于点击）
//   one-finger tap                     → cursor moves there, left button down next frame, up the frame after (so hover precedes the click)
//   单指长按（并拖动） → 只移动光标（悬停），松手不点击
//   one-finger long press (and drag)   → move the cursor only (hover); no click on release
//   单指明显拖动      → 按住左键拖动（滚动条、拖放、拖动地图）
//   one-finger drag (clear movement)   → drag with the left button held (scroll bars, drag and drop, dragging the map)
//   双指轻点          → 右键
//   two-finger tap                     → right click
//   双指滑动 / 触控板滚动 → 滚轮
//   two-finger swipe / trackpad scroll → scroll wheel
//   触控板 / Pencil 悬停 → 移动光标；触控板副键点击 → 右键
//   trackpad / Pencil hover            → move the cursor; trackpad secondary click → right click
//
// 锁定键（屏幕上的"高亮"按钮）：游戏在有按键按住时会切到键盘操作模式、忽略鼠标点击，
// 所以在游戏里点击之前会先自动松开锁定键。
// Latched keys (the on-screen "highlight" button): while a key is held the game switches to keyboard mode and ignores
// mouse clicks, so latched keys are released automatically before a click in the game.
//
// 调试：DE_NATIVE_TOUCH=1 关闭本模块；DE_AUTOTAP="秒:x,y;…" 自动点按（0~1 归一化坐标）；
//       DE_AUTOKEY="秒:键码;…" 自动按键（UnityEngine.KeyCode 数值）。
// Debugging: DE_NATIVE_TOUCH=1 disables this module; DE_AUTOTAP="sec:x,y;..." taps automatically (0-1 normalized coordinates);
//            DE_AUTOKEY="sec:keycode;..." presses keys automatically (UnityEngine.KeyCode values).

#import <UIKit/UIKit.h>
#include <ctype.h>
#include <deque>
#include <set>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "DEVirtualInput.h"

extern "C" void* il2cpp_resolve_icall(const char* name);
extern "C" void il2cpp_add_internal_call(const char* name, void* method);
extern "C" const uint16_t* il2cpp_string_chars(void* str);
extern "C" int32_t il2cpp_string_length(void* str);
bool DETouchTraceEnabled(void);  // DETouchTrace.mm

#define TRACE(...) do { if (DETouchTraceEnabled()) printf(__VA_ARGS__); } while (0)

NSString* const DEVirtualKeysReleasedNotification = @"DEVirtualKeysReleased";

namespace
{
    struct Vector3 { float x, y, z; };
    struct Vector2 { float x, y; };

    enum Button { kLeft = 0, kRight = 1, kMiddle = 2, kButtonCount = 3 };
    const int kKeyCount = 512;  // UnityEngine.KeyCode 中键盘部分的范围 | range of the keyboard part of UnityEngine.KeyCode

    // 每帧最多推进一步，保证"移动 → 按下 → 松开"分布在不同帧
    // Advance at most one step per frame, so "move → press → release" land on different frames
    struct Step
    {
        bool move = false;
        float x = 0, y = 0;     // UIKit 视图坐标（点） | UIKit view coordinates (points)
        int button = -1;        // 鼠标按键变化，-1 表示无 | mouse button change, -1 for none
        int key = -1;           // 键盘按键变化，-1 表示无 | keyboard key change, -1 for none
        bool press = false;
    };

    bool gEnabled = false;
    UIView* __weak gView;
    std::deque<Step> gSteps;
    float gX = 0, gY = 0;       // 当前光标，UIKit 视图坐标 | current cursor, UIKit view coordinates
    bool gHeld[kButtonCount];
    int gDownFrame[kButtonCount] = { -1, -1, -1 };
    int gUpFrame[kButtonCount] = { -1, -1, -1 };
    bool gKeyHeld[kKeyCount];
    int gKeyDownFrame[kKeyCount];
    int gKeyUpFrame[kKeyCount];
    std::set<int> gLatchedKeys;
    Vector2 gScrollPending = { 0, 0 };
    Vector2 gScrollThisFrame = { 0, 0 };
    int gLastFrame = -1;

    int32_t (*OrigFrameCount)();
    int32_t (*OrigScreenWidth)();
    int32_t (*OrigScreenHeight)();
    bool (*OrigGetKeyInt)(int32_t);
    bool (*OrigGetKeyDownInt)(int32_t);
    bool (*OrigGetKeyUpInt)(int32_t);
    bool (*OrigGetKeyString)(void*);
    bool (*OrigGetKeyDownString)(void*);
    bool (*OrigGetKeyUpString)(void*);
    bool (*OrigAnyKey)();
    bool (*OrigAnyKeyDown)();

    void Advance()
    {
        const int frame = OrigFrameCount();
        if (frame == gLastFrame) return;
        gLastFrame = frame;

        gScrollThisFrame = gScrollPending;
        gScrollPending = { 0, 0 };

        if (gSteps.empty()) return;
        Step s = gSteps.front();
        gSteps.pop_front();
        if (s.move) { gX = s.x; gY = s.y; }
        if (s.button >= 0)
        {
            gHeld[s.button] = s.press;
            (s.press ? gDownFrame : gUpFrame)[s.button] = frame;
            TRACE("[DEPort] inject %s button %d at frame %d pos %.0f,%.0f (queue %zu)\n",
                  s.press ? "down" : "up", s.button, frame, gX, gY, gSteps.size());
        }
        if (s.key >= 0)
        {
            gKeyHeld[s.key] = s.press;
            (s.press ? gKeyDownFrame : gKeyUpFrame)[s.key] = frame;
            TRACE("[DEPort] inject key %d %s at frame %d\n", s.key, s.press ? "down" : "up", frame);
        }
    }

    void Enqueue(const Step& s)
    {
        // 连续的纯移动合并为一步，避免拖动时光标滞后
        // Merge consecutive move-only steps into one so the cursor does not lag behind while dragging
        const bool moveOnly = s.move && s.button < 0 && s.key < 0;
        if (moveOnly && !gSteps.empty())
        {
            Step& last = gSteps.back();
            if (last.move && last.button < 0 && last.key < 0) { last.x = s.x; last.y = s.y; return; }
        }
        gSteps.push_back(s);
    }

    void Move(CGPoint p)                  { Step s; s.move = true; s.x = p.x; s.y = p.y; Enqueue(s); }
    void Press(int button, bool down)     { Step s; s.button = button; s.press = down; Enqueue(s); }
    void Key(int key, bool down)          { Step s; s.key = key; s.press = down; Enqueue(s); }

    // 在游戏里点击之前先松开锁定的键（例如高亮），否则游戏处于键盘模式会忽略这次点击
    // Release latched keys (e.g. highlight) before a click in the game; otherwise the game is in keyboard mode and ignores the click
    void ReleaseLatchedKeys()
    {
        if (gLatchedKeys.empty()) return;
        for (int k : gLatchedKeys) Key(k, false);
        gLatchedKeys.clear();
        [NSNotificationCenter.defaultCenter postNotificationName: DEVirtualKeysReleasedNotification object: nil];
    }

    void Click(CGPoint p, int button)
    {
        ReleaseLatchedKeys();
        Move(p);
        Press(button, true);
        Press(button, false);
    }

    bool ValidKey(int32_t k) { return k >= 0 && k < kKeyCount; }

    // 只有屏幕按钮用到的几个键需要支持字符串形式的查询
    // Only the few keys used by the on-screen buttons need to support string-based queries
    int KeyFromName(void* str)
    {
        if (!str) return -1;
        const int32_t len = il2cpp_string_length(str);
        if (len <= 0 || len > 16) return -1;
        const uint16_t* chars = il2cpp_string_chars(str);
        char name[17];
        for (int32_t i = 0; i < len; ++i) name[i] = (char)tolower(chars[i] < 128 ? chars[i] : '?');
        name[len] = 0;
        static const struct { const char* name; int code; } kNames[] = {
            { "tab", DEKeyTab }, { "escape", DEKeyEscape }, { "i", DEKeyI }, { "j", DEKeyJ },
            { "c", DEKeyC }, { "t", DEKeyT }, { "m", DEKeyM },
        };
        for (auto& n : kNames)
            if (strcmp(n.name, name) == 0) return n.code;
        return -1;
    }

    bool AnyVirtualKeyHeld()
    {
        for (int i = 0; i < kKeyCount; ++i) if (gKeyHeld[i]) return true;
        return false;
    }

    bool AnyVirtualKeyDown()
    {
        for (int i = 0; i < kKeyCount; ++i) if (gKeyDownFrame[i] == gLastFrame) return true;
        return false;
    }

    // ---- 替换的 icall ----
    // ---- Replacement icalls ----

    bool DE_GetMouseButton(int32_t b)     { Advance(); return b >= 0 && b < kButtonCount && gHeld[b]; }
    bool DE_GetMouseButtonDown(int32_t b) { Advance(); return b >= 0 && b < kButtonCount && gDownFrame[b] == gLastFrame; }
    bool DE_GetMouseButtonUp(int32_t b)   { Advance(); return b >= 0 && b < kButtonCount && gUpFrame[b] == gLastFrame; }

    void DE_get_mousePosition_Injected(Vector3* ret)
    {
        Advance();
        UIView* view = gView;
        const CGSize size = view ? view.bounds.size : CGSizeMake(1, 1);
        const float w = OrigScreenWidth(), h = OrigScreenHeight();
        // Unity 屏幕坐标：像素，原点在左下角
        // Unity screen coordinates: pixels, origin at the bottom-left
        ret->x = gX / size.width * w;
        ret->y = (1.0f - gY / size.height) * h;
        ret->z = 0;
    }

    void DE_get_mouseScrollDelta_Injected(Vector2* ret) { Advance(); *ret = gScrollThisFrame; }
    int32_t DE_get_touchCount()  { return 0; }
    bool DE_get_touchSupported() { return false; }
    bool DE_get_mousePresent()   { return true; }

    bool DE_GetKeyInt(int32_t k)     { Advance(); return OrigGetKeyInt(k) || (ValidKey(k) && gKeyHeld[k]); }
    bool DE_GetKeyDownInt(int32_t k) { Advance(); return OrigGetKeyDownInt(k) || (ValidKey(k) && gKeyDownFrame[k] == gLastFrame); }
    bool DE_GetKeyUpInt(int32_t k)   { Advance(); return OrigGetKeyUpInt(k) || (ValidKey(k) && gKeyUpFrame[k] == gLastFrame); }

    bool DE_GetKeyString(void* s)
    {
        Advance();
        const int k = KeyFromName(s);
        return OrigGetKeyString(s) || (k >= 0 && gKeyHeld[k]);
    }

    bool DE_GetKeyDownString(void* s)
    {
        Advance();
        const int k = KeyFromName(s);
        return OrigGetKeyDownString(s) || (k >= 0 && gKeyDownFrame[k] == gLastFrame);
    }

    bool DE_GetKeyUpString(void* s)
    {
        Advance();
        const int k = KeyFromName(s);
        return OrigGetKeyUpString(s) || (k >= 0 && gKeyUpFrame[k] == gLastFrame);
    }

    bool DE_get_anyKey()     { Advance(); return OrigAnyKey() || AnyVirtualKeyHeld() || gHeld[kLeft] || gHeld[kRight]; }
    bool DE_get_anyKeyDown() { Advance(); return OrigAnyKeyDown() || AnyVirtualKeyDown(); }

    template <typename T>
    bool Resolve(T& fn, const char* name)
    {
        fn = (T)il2cpp_resolve_icall(name);
        if (!fn) printf("[DEPort] Virtual input: icall %s not found\n", name);
        return fn != nullptr;
    }
}

extern "C" void DEVirtualKey(int keyCode, bool down)
{
    if (!gEnabled || !ValidKey(keyCode)) return;
    if (!down) gLatchedKeys.erase(keyCode);
    Key(keyCode, down);
}

extern "C" void DEVirtualKeyTap(int keyCode)
{
    if (!gEnabled || !ValidKey(keyCode)) return;
    Key(keyCode, true);
    Key(keyCode, false);
}

extern "C" void DEVirtualKeyLatch(int keyCode)
{
    if (!gEnabled || !ValidKey(keyCode)) return;
    gLatchedKeys.insert(keyCode);
}

extern "C" void DEVirtualInputRegisterICalls()
{
    if (getenv("DE_NATIVE_TOUCH")) return;
    for (int i = 0; i < kKeyCount; ++i) gKeyDownFrame[i] = gKeyUpFrame[i] = -1;

    bool ok = true;
    ok &= Resolve(OrigFrameCount, "UnityEngine.Time::get_frameCount");
    ok &= Resolve(OrigScreenWidth, "UnityEngine.Screen::get_width");
    ok &= Resolve(OrigScreenHeight, "UnityEngine.Screen::get_height");
    ok &= Resolve(OrigGetKeyInt, "UnityEngine.Input::GetKeyInt");
    ok &= Resolve(OrigGetKeyDownInt, "UnityEngine.Input::GetKeyDownInt");
    ok &= Resolve(OrigGetKeyUpInt, "UnityEngine.Input::GetKeyUpInt");
    ok &= Resolve(OrigGetKeyString, "UnityEngine.Input::GetKeyString");
    ok &= Resolve(OrigGetKeyDownString, "UnityEngine.Input::GetKeyDownString");
    ok &= Resolve(OrigGetKeyUpString, "UnityEngine.Input::GetKeyUpString");
    ok &= Resolve(OrigAnyKey, "UnityEngine.Input::get_anyKey");
    ok &= Resolve(OrigAnyKeyDown, "UnityEngine.Input::get_anyKeyDown");
    if (!ok)
    {
        printf("[DEPort] Virtual input: required icalls missing, falling back to Unity default touch\n");
        return;
    }

    static const struct { const char* name; void* fn; } kOverrides[] = {
        { "UnityEngine.Input::GetMouseButton", (void*)DE_GetMouseButton },
        { "UnityEngine.Input::GetMouseButtonDown", (void*)DE_GetMouseButtonDown },
        { "UnityEngine.Input::GetMouseButtonUp", (void*)DE_GetMouseButtonUp },
        { "UnityEngine.Input::get_mousePosition_Injected", (void*)DE_get_mousePosition_Injected },
        { "UnityEngine.Input::get_mouseScrollDelta_Injected", (void*)DE_get_mouseScrollDelta_Injected },
        { "UnityEngine.Input::get_touchCount", (void*)DE_get_touchCount },
        { "UnityEngine.Input::get_touchSupported", (void*)DE_get_touchSupported },
        { "UnityEngine.Input::get_mousePresent", (void*)DE_get_mousePresent },
        { "UnityEngine.Input::GetKeyInt", (void*)DE_GetKeyInt },
        { "UnityEngine.Input::GetKeyDownInt", (void*)DE_GetKeyDownInt },
        { "UnityEngine.Input::GetKeyUpInt", (void*)DE_GetKeyUpInt },
        { "UnityEngine.Input::GetKeyString", (void*)DE_GetKeyString },
        { "UnityEngine.Input::GetKeyDownString", (void*)DE_GetKeyDownString },
        { "UnityEngine.Input::GetKeyUpString", (void*)DE_GetKeyUpString },
        { "UnityEngine.Input::get_anyKey", (void*)DE_get_anyKey },
        { "UnityEngine.Input::get_anyKeyDown", (void*)DE_get_anyKeyDown },
    };
    for (auto& o : kOverrides) il2cpp_add_internal_call(o.name, o.fn);
    gEnabled = true;
    printf("[DEPort] virtual input enabled (mouse + keys)\n");
}

// ---------------------------------------------------------------- 手势
// ---------------------------------------------------------------- Gestures

@interface DEMouseGestures : NSObject <UIGestureRecognizerDelegate>
@end

@implementation DEMouseGestures

- (void)tap:(UITapGestureRecognizer*)g
{
    const CGPoint p = [g locationInView: g.view];
    TRACE("[DEPort] gesture tap at %.0f,%.0f\n", p.x, p.y);
    Click(p, kLeft);
}

- (void)secondaryTap:(UITapGestureRecognizer*)g
{
    const CGPoint p = [g locationInView: g.view];
    TRACE("[DEPort] gesture secondary tap at %.0f,%.0f\n", p.x, p.y);
    Click(p, kRight);
}

- (void)longPress:(UILongPressGestureRecognizer*)g
{
    if (g.state == UIGestureRecognizerStateBegan)
        TRACE("[DEPort] gesture long-press began\n");
    if (g.state == UIGestureRecognizerStateBegan || g.state == UIGestureRecognizerStateChanged)
        Move([g locationInView: g.view]);
}

- (void)drag:(UIPanGestureRecognizer*)g
{
    const CGPoint p = [g locationInView: g.view];
    if (g.state == UIGestureRecognizerStateBegan || g.state == UIGestureRecognizerStateEnded)
        TRACE("[DEPort] gesture drag %s at %.0f,%.0f\n", g.state == UIGestureRecognizerStateBegan ? "began" : "ended", p.x, p.y);
    switch (g.state)
    {
        case UIGestureRecognizerStateBegan:
        {
            // 从手指按下的位置开始拖动，而不是识别出拖动时的位置
            // Start the drag from where the finger went down, not where the drag was recognized
            const CGPoint t = [g translationInView: g.view];
            ReleaseLatchedKeys();
            Move(CGPointMake(p.x - t.x, p.y - t.y));
            Press(kLeft, true);
            Move(p);
            break;
        }
        case UIGestureRecognizerStateChanged:
            Move(p);
            break;
        default:
            Move(p);
            Press(kLeft, false);
            break;
    }
}

- (void)scroll:(UIPanGestureRecognizer*)g
{
    const CGPoint t = [g translationInView: g.view];
    [g setTranslation: CGPointZero inView: g.view];
    const float kPointsPerNotch = 24.0f;
    gScrollPending.x += -t.x / kPointsPerNotch;
    gScrollPending.y += t.y / kPointsPerNotch;   // 手指下滑 = 内容上移 = 滚轮向上 | finger moves down = content moves up = wheel scrolls up
}

- (void)hover:(UIHoverGestureRecognizer*)g
{
    if (g.state == UIGestureRecognizerStateBegan || g.state == UIGestureRecognizerStateChanged)
        Move([g locationInView: g.view]);
}

// 落在屏幕按钮（DETouchOverlay.mm）上的触摸不转换成鼠标
// Touches that land on on-screen buttons (DETouchOverlay.mm) are not converted to mouse input
- (BOOL)gestureRecognizer:(UIGestureRecognizer*)g shouldReceiveTouch:(UITouch*)touch
{
    return ![touch.view isKindOfClass: UIControl.class];
}

// 悬停与其他手势互不干扰
// Hover and the other gestures do not interfere with each other
- (BOOL)gestureRecognizer:(UIGestureRecognizer*)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer*)b
{
    return [a isKindOfClass: UIHoverGestureRecognizer.class] || [b isKindOfClass: UIHoverGestureRecognizer.class];
}

@end

static DEMouseGestures* gGestures;

// DE_AUTOTAP="秒:x,y;…" / DE_AUTOKEY="秒:键码;…"，仅用于在没人操作设备时做自动化验证
// DE_AUTOTAP="sec:x,y;..." / DE_AUTOKEY="sec:keycode;...", only for automated verification when nobody is operating the device
static void ScheduleAutomation(void)
{
    const char* taps = getenv("DE_AUTOTAP");
    const char* keys = getenv("DE_AUTOKEY");
    for (int pass = 0; pass < 2; ++pass)
    {
        const char* spec = pass == 0 ? taps : keys;
        if (!spec) continue;
        for (NSString* item in [[NSString stringWithUTF8String: spec] componentsSeparatedByString: @";"])
        {
            NSArray<NSString*>* parts = [item componentsSeparatedByCharactersInSet: [NSCharacterSet characterSetWithCharactersInString: @":,"]];
            if (parts.count != (pass == 0 ? 3u : 2u)) continue;
            const double t = parts[0].doubleValue;
            const double a = parts[1].doubleValue, b = pass == 0 ? parts[2].doubleValue : 0;
            const bool isTap = pass == 0;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(t * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                UIView* v = gView;
                if (!v) return;
                if (isTap)
                {
                    printf("[DEPort] autotap at %.2f,%.2f\n", a, b);
                    Click(CGPointMake(a * v.bounds.size.width, b * v.bounds.size.height), kLeft);
                }
                else
                {
                    printf("[DEPort] autokey %d\n", (int)a);
                    DEVirtualKeyTap((int)a);
                }
            });
        }
    }
}

extern "C" void DEVirtualInputAttach(UIView* view)
{
    if (!gEnabled || !view) return;
    gView = view;
    gX = view.bounds.size.width / 2;
    gY = view.bounds.size.height / 2;
    gGestures = [DEMouseGestures new];

    UILongPressGestureRecognizer* longPress = [[UILongPressGestureRecognizer alloc] initWithTarget: gGestures action: @selector(longPress:)];
    longPress.minimumPressDuration = 0.35;
    longPress.allowableMovement = 12;

    UITapGestureRecognizer* tap = [[UITapGestureRecognizer alloc] initWithTarget: gGestures action: @selector(tap:)];

    // 轻点时手指难免有一点位移：只有轻点和长按都失败（明显移动）后才算拖动
    // A finger inevitably moves a little during a tap: only count it as a drag after both tap and long press have failed
    // (clear movement)
    UIPanGestureRecognizer* drag = [[UIPanGestureRecognizer alloc] initWithTarget: gGestures action: @selector(drag:)];
    drag.maximumNumberOfTouches = 1;
    [drag requireGestureRecognizerToFail: longPress];
    [drag requireGestureRecognizerToFail: tap];

    UITapGestureRecognizer* twoFingerTap = [[UITapGestureRecognizer alloc] initWithTarget: gGestures action: @selector(secondaryTap:)];
    twoFingerTap.numberOfTouchesRequired = 2;

    // 触控板 / 鼠标的副键点击。buttonMaskRequired 对手指触摸不起作用，必须限定为间接指针，
    // 否则每次手指轻点都会被它抢先识别成右键
    // Trackpad / mouse secondary click. buttonMaskRequired has no effect on finger touches, so this must be restricted
    // to indirect pointers; otherwise every finger tap would be grabbed first and recognized as a right click
    UITapGestureRecognizer* secondaryClick = [[UITapGestureRecognizer alloc] initWithTarget: gGestures action: @selector(secondaryTap:)];
    secondaryClick.buttonMaskRequired = UIEventButtonMaskSecondary;
    secondaryClick.allowedTouchTypes = @[ @(UITouchTypeIndirectPointer) ];

    UIPanGestureRecognizer* scroll = [[UIPanGestureRecognizer alloc] initWithTarget: gGestures action: @selector(scroll:)];
    scroll.minimumNumberOfTouches = 2;
    scroll.allowedScrollTypesMask = UIScrollTypeMaskAll;

    UIHoverGestureRecognizer* hover = [[UIHoverGestureRecognizer alloc] initWithTarget: gGestures action: @selector(hover:)];

    for (UIGestureRecognizer* g in @[longPress, drag, tap, twoFingerTap, secondaryClick, scroll, hover])
    {
        g.cancelsTouchesInView = NO;
        g.delegate = gGestures;
        [view addGestureRecognizer: g];
    }
    ScheduleAutomation();
    printf("[DEPort] virtual input gestures attached\n");
}
