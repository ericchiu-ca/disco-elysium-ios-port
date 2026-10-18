// 屏幕按钮：游戏界面里已有菜单、背包、日志等按钮，触屏上唯一缺少的是"按住 Tab 高亮可交互物"，
// 所以左侧只放一个高亮按钮（对话面板在右侧，避免遮挡）。
// On-screen buttons: the game UI already has buttons for the menu, inventory, journal, etc.; the only thing missing on
// a touch screen is "hold Tab to highlight interactables", so there is just one highlight button on the left
// (the dialogue panel is on the right, so it stays out of the way).
// 按键通过 DEVirtualInput 的逐帧队列送进游戏（GetKey / GetKeyDown / GetKeyUp 都能读到），
// 不走 Unity 的原生按键注入：后者在两帧之间按下时会丢掉"本帧按下"。
// Keys are fed to the game through DEVirtualInput's per-frame queue (visible to GetKey / GetKeyDown / GetKeyUp),
// not through Unity's native key injection, which drops the "pressed this frame" state when a press lands between frames.
//
//   眼睛  Tab   点一下锁定高亮（在游戏里点击时自动松开）；按住不放则松手即结束
//   eye   Tab   tap to latch the highlight (released automatically when you click in the game); if held down, it ends on release
//
// 需要更多按键时在 kButtons 里添加（holdable = false 表示点一下 = 按下并松开）。
// To add more keys, append them to kButtons (holdable = false means a tap = press and release).

#import <UIKit/UIKit.h>
#include <stdio.h>

#include "DEVirtualInput.h"

namespace
{
    struct ButtonDef
    {
        const char* symbol;   // SF Symbol
        int key;              // UnityEngine.KeyCode
        bool holdable;        // 可锁定 / 按住的键（高亮）；其余为点一下 = 按下并松开 | latchable / holdable key (highlight); others are tap = press and release
    };

    const ButtonDef kButtons[] =
    {
        { "eye", DEKeyTab, true },
    };

    // 按住超过这个时长再松手，视为"按住即时"而不是"点一下锁定"
    // Releasing after holding longer than this counts as a "momentary hold" rather than a "tap to latch"
    const double kHoldThresholdSeconds = 0.4;
}

// 只让按钮接收触摸，按钮之间的空白处把触摸交还给游戏
// Only the buttons receive touches; empty space between buttons passes touches back to the game
@interface DEOverlayContainer : UIView
@end

@implementation DEOverlayContainer
- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event
{
    UIView* hit = [super hitTest: point withEvent: event];
    return hit == self ? nil : hit;
}
@end

@interface DEKeyButton : UIButton
@property (nonatomic) int keyCode;
@property (nonatomic) bool holdable;
@property (nonatomic) bool held;            // 当前是否按着（含锁定） | whether currently pressed (including latched)
@property (nonatomic) bool releasingTouch;  // 这次触摸是用来松开锁定的 | this touch is releasing the latch
@property (nonatomic) CFTimeInterval pressedAt;
@end

@implementation DEKeyButton

@synthesize held = _held;

- (void)setHeld:(bool)held
{
    _held = held;
    self.backgroundColor = [UIColor colorWithWhite: held ? 0.85 : 0.0 alpha: held ? 0.75 : 0.35];
    self.tintColor = held ? UIColor.blackColor : UIColor.whiteColor;
}

- (void)down
{
    if (!self.holdable)
    {
        self.backgroundColor = [UIColor colorWithWhite: 0.85 alpha: 0.75];
        return;
    }
    if (self.held)
    {
        // 已锁定：这次触摸用来松开
        // Already latched: this touch releases it
        self.releasingTouch = true;
        DEVirtualKey(self.keyCode, false);
        self.held = false;
        return;
    }
    self.releasingTouch = false;
    self.pressedAt = CACurrentMediaTime();
    DEVirtualKey(self.keyCode, true);
    self.held = true;
}

- (void)up
{
    if (!self.holdable)
    {
        self.backgroundColor = [UIColor colorWithWhite: 0 alpha: 0.35];
        DEVirtualKeyTap(self.keyCode);
        return;
    }
    if (self.releasingTouch) return;
    if (CACurrentMediaTime() - self.pressedAt > kHoldThresholdSeconds)
    {
        DEVirtualKey(self.keyCode, false);  // 按住即时：松手结束 | momentary hold: ends on release
        self.held = false;
    }
    else
    {
        DEVirtualKeyLatch(self.keyCode);    // 点一下：锁定，直到再点一次或在游戏里点击 | tap: latch until tapped again or a click in the game
    }
}

- (void)cancel
{
    if (!self.holdable)
    {
        self.backgroundColor = [UIColor colorWithWhite: 0 alpha: 0.35];
        return;
    }
    if (!self.releasingTouch && self.held)
    {
        DEVirtualKey(self.keyCode, false);
        self.held = false;
    }
}

- (void)keysReleased:(NSNotification*)note
{
    if (self.holdable && self.held) self.held = false;
}

@end

static UIButton* MakeRoundButton(NSString* symbol, Class cls)
{
    UIButton* b = [cls buttonWithType: UIButtonTypeSystem];
    UIImageSymbolConfiguration* cfg = [UIImageSymbolConfiguration configurationWithPointSize: 20 weight: UIImageSymbolWeightMedium];
    [b setImage: [UIImage systemImageNamed: symbol withConfiguration: cfg] forState: UIControlStateNormal];
    b.tintColor = UIColor.whiteColor;
    b.backgroundColor = [UIColor colorWithWhite: 0 alpha: 0.35];
    b.layer.cornerRadius = 24;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b.widthAnchor constraintEqualToConstant: 48].active = YES;
    [b.heightAnchor constraintEqualToConstant: 48].active = YES;
    return b;
}

extern "C" void DETouchOverlayAttach(UIView* view)
{
    if (!view || getenv("DE_NO_OVERLAY")) return;

    DEOverlayContainer* container = [DEOverlayContainer new];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    [view addSubview: container];

    UIStackView* stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview: stack];

    for (const ButtonDef& def : kButtons)
    {
        DEKeyButton* b = (DEKeyButton*)MakeRoundButton([NSString stringWithUTF8String: def.symbol], DEKeyButton.class);
        b.keyCode = def.key;
        b.holdable = def.holdable;
        [b addTarget: b action: @selector(down) forControlEvents: UIControlEventTouchDown];
        [b addTarget: b action: @selector(up) forControlEvents: UIControlEventTouchUpInside];
        [b addTarget: b action: @selector(cancel) forControlEvents: UIControlEventTouchUpOutside | UIControlEventTouchCancel];
        [NSNotificationCenter.defaultCenter addObserver: b selector: @selector(keysReleased:)
                                                   name: DEVirtualKeysReleasedNotification object: nil];
        [stack addArrangedSubview: b];
    }

    [NSLayoutConstraint activateConstraints: @[
        [container.leadingAnchor constraintEqualToAnchor: view.safeAreaLayoutGuide.leadingAnchor constant: 10],
        [container.centerYAnchor constraintEqualToAnchor: view.centerYAnchor],
        [stack.topAnchor constraintEqualToAnchor: container.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor: container.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor: container.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor: container.trailingAnchor],
    ]];
    printf("[DEPort] touch overlay attached (%zu keys)\n", sizeof(kButtons) / sizeof(kButtons[0]));
}
