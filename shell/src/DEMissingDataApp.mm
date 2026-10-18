// 沙盒里没有可用的游戏数据时显示的说明页，避免 Unity 在缺文件时直接崩溃。
// Help screen shown when there is no usable game data in the sandbox, so Unity does not simply crash on missing files.

#import <UIKit/UIKit.h>
#include "DEBootstrap.h"

static NSString* gReason;

@interface DEMissingDataDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow* window;
@end

@implementation DEMissingDataDelegate

- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)launchOptions
{
    UIViewController* vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.blackColor;

    UILabel* label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.numberOfLines = 0;
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont monospacedSystemFontOfSize: 17 weight: UIFontWeightRegular];
    label.text = [NSString stringWithFormat:
        @"未找到可用的游戏数据\n\n"
        @"原因：%1$@\n\n"
        @"本 App 不包含任何游戏内容。请在 Mac 上用你自己的游戏副本转换并推送数据：\n\n"
        @"    make data push-data\n\n"
        @"数据位置：%2$s\n"
        @"\n"
        @"No usable game data found\n\n"
        @"Reason: %1$@\n\n"
        @"This app does not contain any game content. On your Mac, convert and push the data from your own copy of the game:\n\n"
        @"    make data push-data\n\n"
        @"Data location: %2$s\n",
        gReason ?: @"未知 / Unknown", DEGameRoot()];
    [vc.view addSubview: label];
    [NSLayoutConstraint activateConstraints: @[
        [label.leadingAnchor constraintEqualToAnchor: vc.view.layoutMarginsGuide.leadingAnchor],
        [label.trailingAnchor constraintEqualToAnchor: vc.view.layoutMarginsGuide.trailingAnchor],
        [label.centerYAnchor constraintEqualToAnchor: vc.view.centerYAnchor],
    ]];

    self.window = [[UIWindow alloc] initWithFrame: UIScreen.mainScreen.bounds];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int DERunMissingDataApp(int argc, char* argv[], const char* reason)
{
    gReason = reason ? [NSString stringWithUTF8String: reason] : nil;
    NSLog(@"[DEPort] Game data unavailable: %@", gReason);
    return UIApplicationMain(argc, argv, nil, NSStringFromClass(DEMissingDataDelegate.class));
}
