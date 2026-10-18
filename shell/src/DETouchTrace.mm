// 触摸追踪（调试用）：设置环境变量 DE_TRACE_TOUCH=1 时，记录每个触摸的开始/结束、
// 命中的视图，以及当时挂在该视图上的手势识别器状态，用于排查"点了没反应"。
// Touch tracing (for debugging): when the environment variable DE_TRACE_TOUCH=1 is set, logs the start/end of every
// touch, the view it hit, and the state of the gesture recognizers attached to that view at the time, to diagnose
// "tapped but nothing happened".
// 与 DEVirtualInput.mm 中的手势/注入日志配合，可以分辨点击丢在了哪一层。
// Combined with the gesture/injection logs in DEVirtualInput.mm, this shows at which layer a tap was lost.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>

bool DETouchTraceEnabled(void)
{
    static int enabled = -1;
    if (enabled < 0) enabled = getenv("DE_TRACE_TOUCH") ? 1 : 0;
    return enabled == 1;
}

static const char* PhaseName(UITouchPhase p)
{
    switch (p)
    {
        case UITouchPhaseBegan: return "began";
        case UITouchPhaseEnded: return "ended";
        case UITouchPhaseCancelled: return "cancelled";
        default: return "other";
    }
}

static const char* StateName(UIGestureRecognizerState s)
{
    switch (s)
    {
        case UIGestureRecognizerStatePossible: return "possible";
        case UIGestureRecognizerStateBegan: return "began";
        case UIGestureRecognizerStateChanged: return "changed";
        case UIGestureRecognizerStateEnded: return "ended";
        case UIGestureRecognizerStateCancelled: return "cancelled";
        case UIGestureRecognizerStateFailed: return "failed";
    }
    return "?";
}

static IMP gOrigSendEvent;

static void DE_sendEvent(UIWindow* self, SEL _cmd, UIEvent* event)
{
    if (event.type == UIEventTypeTouches)
    {
        for (UITouch* t in event.allTouches)
        {
            if (t.phase != UITouchPhaseBegan && t.phase != UITouchPhaseEnded && t.phase != UITouchPhaseCancelled)
                continue;
            const CGPoint p = [t locationInView: self];
            printf("[DEPort] touch %s at %.0f,%.0f type=%ld view=%s key=%d t=%.3f\n",
                   PhaseName(t.phase), p.x, p.y, (long)t.type,
                   t.view ? class_getName(t.view.class) : "nil", self.isKeyWindow, t.timestamp);
        }
    }
    ((void (*)(id, SEL, UIEvent*))gOrigSendEvent)(self, _cmd, event);

    if (event.type == UIEventTypeTouches)
    {
        UITouch* t = event.allTouches.anyObject;
        if (t.phase == UITouchPhaseEnded || t.phase == UITouchPhaseCancelled)
        {
            for (UIGestureRecognizer* g in t.view.gestureRecognizers)
                printf("[DEPort]   gesture %s %s\n", class_getName(g.class), StateName(g.state));
        }
    }
}

__attribute__((constructor)) static void InstallTouchTrace(void)
{
    if (!DETouchTraceEnabled()) return;
    Method m = class_getInstanceMethod(UIWindow.class, @selector(sendEvent:));
    gOrigSendEvent = method_setImplementation(m, (IMP)DE_sendEvent);
}
