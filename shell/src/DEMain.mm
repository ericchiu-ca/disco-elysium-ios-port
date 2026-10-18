// App 入口，替换 Trampoline 的 MainApp/main.mm。
// App entry point; replaces the Trampoline's MainApp/main.mm.
// 与 Unity 默认的"主程序 + UnityFramework.framework"不同，这里整个播放器静态链接进主程序，
// 游戏逻辑在单独的 GameAssembly.framework（由 Mac 版改标而来）。
// Unlike Unity's default "main executable + UnityFramework.framework", the whole player is statically linked into
// the main executable here, and the game logic lives in a separate GameAssembly.framework (the Mac version's binary
// retagged for the iOS platform).

#include "UnityFramework.h"
#include "DEBootstrap.h"

int DERunMissingDataApp(int argc, char* argv[], const char* reason);

int main(int argc, char* argv[])
{
    @autoreleasepool
    {
        DEBootstrapEarly();

        const char* reason = NULL;
        if (!DEGameDataAvailable(&reason))
            return DERunMissingDataApp(argc, argv, reason);

        UnityFramework* ufw = [UnityFramework getInstance];
        [ufw setExecuteHeader: &_mh_execute_header];
        [ufw runUIApplicationMainWithArgc: argc argv: argv];
        return 0;
    }
}
