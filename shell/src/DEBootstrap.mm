#import <Foundation/Foundation.h>
#include <os/log.h>
#include <stdio.h>
#include <string.h>

#include "DEBootstrap.h"

// GameData 目录格式版本，必须与 tools/convert_data.py 中的 FORMAT_VERSION 一致
// GameData directory format version; must match FORMAT_VERSION in tools/convert_data.py
static const int kGameDataFormatVersion = 2;

static os_log_t DELog(void)
{
    static os_log_t log;
    if (!log) log = os_log_create("DEPort", "boot");
    return log;
}

static NSString* GameRootPath(void)
{
    NSString* docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    return [docs stringByAppendingPathComponent: @"GameData"];
}

const char* DEGameRoot(void)
{
    static const char* root;
    if (!root) root = strdup(GameRootPath().fileSystemRepresentation);
    return root;
}

// 与 Mac 版 .app 相同的结构：<GameData>/Contents/Resources/Data
// Same layout as the Mac .app: <GameData>/Contents/Resources/Data
static NSString* ContentsPath(void)
{
    return [GameRootPath() stringByAppendingPathComponent: @"Contents"];
}

static NSString* DataPath(void)
{
    return [ContentsPath() stringByAppendingPathComponent: @"Resources/Data"];
}

// Unity 在这个目录下读取 Data/
// Unity reads Data/ under this directory
const char* DEUnityDataBundleDir(void)
{
    static const char* dir;
    if (!dir) dir = strdup([ContentsPath() stringByAppendingPathComponent: @"Resources"].fileSystemRepresentation);
    return dir;
}

// 托管代码看到的 Application.dataPath，与 Mac 版一致（= .app/Contents）
// The Application.dataPath seen by managed code, same as the Mac version (= .app/Contents)
const char* DEMacStyleDataPath(void)
{
    static const char* dir;
    if (!dir) dir = strdup(ContentsPath().fileSystemRepresentation);
    return dir;
}

bool DEGameDataAvailable(const char** reason)
{
    NSFileManager* fm = NSFileManager.defaultManager;
    NSString* root = GameRootPath();
    NSString* data = DataPath();

    NSArray<NSString*>* required = @[
        @"globalgamemanagers",
        @"unity default resources",
        @"Managed/Metadata/global-metadata.dat",
    ];
    for (NSString* rel in required)
    {
        if (![fm fileExistsAtPath: [data stringByAppendingPathComponent: rel]])
        {
            if (reason) *reason = strdup([NSString stringWithFormat: @"缺少文件 Contents/Resources/Data/%1$@ / Missing file Contents/Resources/Data/%1$@", rel].UTF8String);
            return false;
        }
    }

    NSString* marker = [root stringByAppendingPathComponent: @"de-port.json"];
    NSData* json = [NSData dataWithContentsOfFile: marker];
    NSDictionary* info = json ? [NSJSONSerialization JSONObjectWithData: json options: 0 error: nil] : nil;
    if (![info isKindOfClass: NSDictionary.class] || [info[@"format"] intValue] != kGameDataFormatVersion)
    {
        if (reason) *reason = strdup("GameData 的格式版本与 App 不一致，请在 Mac 上重新转换并推送数据 / The GameData format version does not match the app; please convert and push the data again on the Mac");
        return false;
    }
    return true;
}

// ---- 日志：把 Unity 的 stdout/stderr 写进 Documents/Logs，便于不连调试器时排查 ----
// ---- Logs: write Unity's stdout/stderr to Documents/Logs for troubleshooting without a debugger attached ----

static void RedirectLogs(void)
{
    // 连着 Xcode 调试器，或用 scripts/run.sh（devicectl --console）启动时保留控制台输出
    // Keep console output when attached to the Xcode debugger or launched via scripts/run.sh (devicectl --console)
    if (isatty(STDERR_FILENO) || getenv("DE_LOG_TO_CONSOLE")) return;

    NSString* docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    NSString* dir = [docs stringByAppendingPathComponent: @"Logs"];
    [NSFileManager.defaultManager createDirectoryAtPath: dir withIntermediateDirectories: YES attributes: nil error: nil];
    NSString* cur = [dir stringByAppendingPathComponent: @"Player.log"];
    NSString* prev = [dir stringByAppendingPathComponent: @"Player-prev.log"];
    [NSFileManager.defaultManager removeItemAtPath: prev error: nil];
    [NSFileManager.defaultManager moveItemAtPath: cur toPath: prev error: nil];

    if (freopen(cur.fileSystemRepresentation, "w", stdout))
    {
        dup2(fileno(stdout), STDERR_FILENO);
        setvbuf(stdout, NULL, _IOLBF, 0);
        setvbuf(stderr, NULL, _IONBF, 0);
    }
}

// ---- il2cpp 原生插件查找：把 DllImport 名映射到 App 内的 framework ----
// ---- il2cpp native plugin lookup: map DllImport names to frameworks inside the app ----

typedef const char* (*Il2CppFindPluginCallback)(const char*);
extern "C" void il2cpp_set_find_plugin_callback(Il2CppFindPluginCallback method);

static NSString* NormalizeLibraryName(NSString* name)
{
    NSString* base = name.lastPathComponent;
    for (NSString* ext in @[@"dll", @"dylib", @"bundle", @"so"])
        if ([base.pathExtension.lowercaseString isEqualToString: ext])
            base = base.stringByDeletingPathExtension;
    if ([base.lowercaseString hasPrefix: @"lib"] && base.length > 3)
        base = [base substringFromIndex: 3];
    return base.lowercaseString;
}

static const char* FindPlugin(const char* requested)
{
    static NSMutableDictionary<NSString*, NSValue*>* cache;
    static NSDictionary<NSString*, NSString*>* frameworks;
    static NSDictionary<NSString*, NSString*>* systemPaths;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSMutableDictionary dictionary];
        frameworks = @{
            @"steam_api": @"steam_api",
            @"galaxycsharpglue": @"GalaxyCSharpGlue",
            @"incontrolnative": @"InControlNative",
            @"amplifytexturenative": @"AmplifyTextureNative",
        };
        // Mono 的 System.dll 在 Mac 上用 CoreServices 内的 CFNetwork 路径，iOS 上路径不同
        // Mono's System.dll uses the CFNetwork path inside CoreServices on the Mac; the path differs on iOS
        systemPaths = @{
            @"/System/Library/Frameworks/CoreServices.framework/Frameworks/CFNetwork.framework/CFNetwork":
                @"/System/Library/Frameworks/CFNetwork.framework/CFNetwork",
        };
    });
    if (!requested) return requested;

    NSString* name = [NSString stringWithUTF8String: requested];
    @synchronized(cache)
    {
        NSValue* hit = cache[name];
        if (hit) return (const char*)hit.pointerValue;

        NSString* resolved = systemPaths[name];
        NSString* fw = frameworks[NormalizeLibraryName(name)];
        if (fw)
            resolved = [NSString stringWithFormat: @"%@/%@.framework/%@", NSBundle.mainBundle.privateFrameworksPath, fw, fw];

        const char* result = resolved ? strdup(resolved.fileSystemRepresentation) : requested;
        os_log(DELog(), "DllImport \"%{public}s\" -> %{public}s", requested, result);
        printf("[DEPort] DllImport \"%s\" -> %s\n", requested, result);
        // 未映射时返回原指针：il2cpp 会按原名 dlopen（例如 libc）
        // When unmapped, return the original pointer: il2cpp will dlopen it by its original name (e.g. libc)
        if (resolved) cache[name] = [NSValue valueWithPointer: result];
        return result;
    }
}

// iOS 播放器的 streamingAssetsPath 是 Data/Raw；Mac 版是 Data/StreamingAssets。
// 补一个符号链接，兼容按 Mac 规则手工拼出的路径。
// The iOS player's streamingAssetsPath is Data/Raw; the Mac version uses Data/StreamingAssets.
// Add a symlink so paths built by hand following the Mac convention still work.
static void LinkMacStreamingAssets(void)
{
    NSString* link = [DataPath() stringByAppendingPathComponent: @"StreamingAssets"];
    NSFileManager* fm = NSFileManager.defaultManager;
    if ([fm destinationOfSymbolicLinkAtPath: link error: nil] != nil) return;
    if (![fm fileExistsAtPath: [DataPath() stringByAppendingPathComponent: @"Raw"]]) return;
    NSError* err = nil;
    if (![fm createSymbolicLinkAtPath: link withDestinationPath: @"Raw" error: &err])
        os_log_error(DELog(), "Failed to create the StreamingAssets link: %{public}@", err);
}

static void ExcludeGameDataFromBackup(void)
{
    NSURL* url = [NSURL fileURLWithPath: GameRootPath() isDirectory: YES];
    if (![NSFileManager.defaultManager fileExistsAtPath: url.path]) return;
    NSError* err = nil;
    if (![url setResourceValue: @YES forKey: NSURLIsExcludedFromBackupKey error: &err])
        os_log_error(DELog(), "Failed to exclude from iCloud backup: %{public}@", err);
}

extern "C" void DEInstallMetalCapsProbe(void);
extern "C" void DEScheduleDebugSnapshots(void);

void DEBootstrapEarly(void)
{
    RedirectLogs();
    printf("[DEPort] GameData: %s\n", DEGameRoot());
    il2cpp_set_find_plugin_callback(FindPlugin);
    ExcludeGameDataFromBackup();
    LinkMacStreamingAssets();
    DEInstallMetalCapsProbe();
    DEScheduleDebugSnapshots();
}
