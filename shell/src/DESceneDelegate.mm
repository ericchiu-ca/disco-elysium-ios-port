// UIScene 生命周期适配。
// UIScene lifecycle adaptation.
//
// iPadOS 27 起，用新 SDK 构建的 App 必须采用 UIScene 生命周期，否则启动即被 UIKit 断言终止。
// Starting with iPadOS 27, apps built with the new SDK must adopt the UIScene lifecycle, or UIKit terminates them
// with an assertion at launch.
// Unity 2020.3 的 Trampoline 仍是基于 UIApplicationDelegate 的窗口模型：在 didFinishLaunching 里
// 创建 UIWindow，并依赖 applicationDidBecomeActive 等回调启动/暂停播放器。
// Unity 2020.3's Trampoline still uses the UIApplicationDelegate-based window model: it creates the UIWindow in
// didFinishLaunching and relies on callbacks such as applicationDidBecomeActive to start/pause the player.
// 采用场景生命周期后 UIKit 不再调用这些 AppDelegate 回调，所以这里：
// With the scene lifecycle, UIKit no longer calls these AppDelegate callbacks, so this file:
//   1. 场景连接时，把 AppDelegate 已创建的窗口挂到该场景上
//   1. When a scene connects, attaches the window already created by the AppDelegate to that scene
//   2. 把场景的前后台事件转发给 AppDelegate 对应的 application* 方法
//   2. Forwards the scene's foreground/background events to the corresponding application* methods of the AppDelegate
// Unity 与缺数据提示页（DEMissingDataDelegate）共用这一个场景代理。
// Unity and the missing-data screen (DEMissingDataDelegate) share this one scene delegate.

#import <UIKit/UIKit.h>

@interface DESceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (strong, nonatomic) UIWindow* window;
@end

@implementation DESceneDelegate

static void Forward(SEL sel)
{
    UIApplication* app = UIApplication.sharedApplication;
    id<UIApplicationDelegate> delegate = app.delegate;
    if ([delegate respondsToSelector: sel])
        ((void (*)(id, SEL, UIApplication*))[(NSObject*)delegate methodForSelector: sel])(delegate, sel, app);
}

- (void)scene:(UIScene*)scene willConnectToSession:(UISceneSession*)session options:(UISceneConnectionOptions*)connectionOptions
{
    if (![scene isKindOfClass: UIWindowScene.class])
        return;

    id<UIApplicationDelegate> delegate = UIApplication.sharedApplication.delegate;
    UIWindow* window = [delegate respondsToSelector: @selector(window)] ? delegate.window : nil;
    if (window == nil)
    {
        NSLog(@"[DEPort] AppDelegate has not created a window yet when the scene connected");
        return;
    }
    window.windowScene = (UIWindowScene*)scene;
    window.frame = ((UIWindowScene*)scene).coordinateSpace.bounds;
    self.window = window;
    [window makeKeyAndVisible];
}

- (void)sceneWillEnterForeground:(UIScene*)scene
{
    Forward(@selector(applicationWillEnterForeground:));
}

- (void)sceneDidBecomeActive:(UIScene*)scene
{
    Forward(@selector(applicationDidBecomeActive:));
}

- (void)sceneWillResignActive:(UIScene*)scene
{
    Forward(@selector(applicationWillResignActive:));
}

- (void)sceneDidEnterBackground:(UIScene*)scene
{
    Forward(@selector(applicationDidEnterBackground:));
}

@end
