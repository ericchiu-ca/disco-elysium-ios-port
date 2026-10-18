// 调试用定时截屏：设置环境变量 DE_SNAPSHOT_EVERY=<秒> 时，每隔若干秒把当前画面存为
// Documents/Logs/snap-NNN.jpg，用 `make logs` 取回。正常启动不设置该变量，不会生效。
// Periodic screenshots for debugging: when the environment variable DE_SNAPSHOT_EVERY=<seconds> is set, the current
// frame is saved every few seconds as Documents/Logs/snap-NNN.jpg; fetch them with `make logs`. A normal launch
// does not set this variable, so it has no effect.
// 通过 scripts/device.sh run 启动时可用 SNAPSHOT_EVERY=10 make run 打开。
// When launching via scripts/device.sh run, enable it with SNAPSHOT_EVERY=10 make run.

#import <UIKit/UIKit.h>
#include <mach/mach.h>
#include <os/proc.h>
#include <stdlib.h>

static UIWindow* KeyWindow(void)
{
    for (UIScene* scene in UIApplication.sharedApplication.connectedScenes)
        if ([scene isKindOfClass: UIWindowScene.class])
            for (UIWindow* w in ((UIWindowScene*)scene).windows)
                if (w.isKeyWindow) return w;
    return nil;
}

static uint64_t FootprintMB(void)
{
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return info.phys_footprint / (1024 * 1024);
}

static void TakeSnapshot(int index)
{
    printf("[DEPort] memory footprint %llu MB, available before jetsam %zu MB\n",
           FootprintMB(), os_proc_available_memory() / (1024 * 1024));

    UIWindow* window = KeyWindow();
    if (!window) return;

    UIGraphicsImageRendererFormat* fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.scale = 1.0;  // 按点而不是像素保存，文件小一些 | save in points rather than pixels for smaller files
    UIGraphicsImageRenderer* r = [[UIGraphicsImageRenderer alloc] initWithBounds: window.bounds format: fmt];
    NSData* jpg = [r JPEGDataWithCompressionQuality: 0.7 actions: ^(UIGraphicsImageRendererContext* ctx) {
        [window drawViewHierarchyInRect: window.bounds afterScreenUpdates: NO];
    }];

    NSString* docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    NSString* dir = [docs stringByAppendingPathComponent: @"Logs"];
    [NSFileManager.defaultManager createDirectoryAtPath: dir withIntermediateDirectories: YES attributes: nil error: nil];
    NSString* path = [dir stringByAppendingPathComponent: [NSString stringWithFormat: @"snap-%03d.jpg", index]];
    BOOL ok = [jpg writeToFile: path atomically: YES];
    printf("[DEPort] snapshot %s %s\n", path.lastPathComponent.UTF8String, ok ? "saved" : "FAILED");
}

extern "C" void DEScheduleDebugSnapshots(void)
{
    const char* every = getenv("DE_SNAPSHOT_EVERY");
    if (!every || atof(every) <= 0) return;
    NSTimeInterval interval = atof(every);
    __block int index = 0;
    [NSTimer scheduledTimerWithTimeInterval: interval repeats: YES block: ^(NSTimer* t) {
        TakeSnapshot(index++);
    }];
}
