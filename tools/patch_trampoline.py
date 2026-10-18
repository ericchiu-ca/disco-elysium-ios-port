#!/usr/bin/env python3
"""对复制出来的 Unity Trampoline 源码做少量、精确的修改。

每条补丁都要求原文完全匹配；Unity 版本不同导致不匹配时直接报错，而不是悄悄跳过。
用法：patch_trampoline.py <复制后的 Trampoline 根目录>

Make a few precise modifications to the copied Unity Trampoline sources.

Every patch requires an exact match of the original text; if it does not match (because of a
different Unity version), the script fails with an error instead of silently skipping it.
Usage: patch_trampoline.py <root of the copied Trampoline>
"""
import os
import sys


def m(zh, en):
    """按 DE_LANG / 系统语言选择输出语言 | Pick the output language from DE_LANG / the system language"""
    lang = os.environ.get("DE_LANG") or os.environ.get("LC_ALL") or os.environ.get("LANG") or ""
    return zh if lang.startswith("zh") else en


PATCHES = [
    # 1. Unity 从 UnityDataBundleDir()/Data 读取全部资源；改为指向沙盒 Documents/GameData
    #    Unity reads all resources from UnityDataBundleDir()/Data; point it at Documents/GameData in the sandbox instead
    (
        "Classes/Unity/Filesystem.mm",
        """extern "C" const char* UnityDataBundleDir()
{
    static const char* dir = NULL;""",
        """extern "C" const char* DEUnityDataBundleDir();
extern "C" const char* UnityDataBundleDir()
{
    return DEUnityDataBundleDir();
}

extern "C" const char* UnityDataBundleDirOriginal()
{
    static const char* dir = NULL;""",
    ),
    # 2. Mac 版托管程序集里没有 AudioSettings.Mobile；播放器在 UnityUpdateMuteState 里回调它，
    #    找不到方法时会调用空方法指针崩溃。静音状态对本游戏没有用处，直接去掉这三处调用。
    #    The Mac version's managed assemblies have no AudioSettings.Mobile; the player calls back into it from
    #    UnityUpdateMuteState and, when the method is missing, crashes calling a null method pointer. The mute
    #    state is of no use to this game, so these three calls are simply removed.
    (
        "Classes/UnityAppController.mm",
        "#include <sys/sysctl.h>\n",
        "#include <sys/sysctl.h>\n\n"
        "// DEPort: 见 tools/patch_trampoline.py\n"
        "// DEPort: see tools/patch_trampoline.py\n"
        "#define UnityUpdateMuteState(muted) ((void)(muted))\n",
    ),
    # 3. 关闭编辑器默认打开、但本移植用不到且需要额外权限的功能
    #    Turn off features the editor enables by default that this port does not use and that need extra permissions
    (
        "Classes/Preprocessor.h",
        "#define UNITY_USES_REMOTE_NOTIFICATIONS 1",
        "#define UNITY_USES_REMOTE_NOTIFICATIONS 0",
    ),
    (
        "Classes/Preprocessor.h",
        "#define UNITY_USES_IAD 1",
        "#define UNITY_USES_IAD 0",
    ),
]


def main():
    root = sys.argv[1]
    for rel, old, new in PATCHES:
        path = os.path.join(root, rel)
        with open(path, encoding="utf-8") as f:
            src = f.read()
        if src.count(old) != 1:
            sys.exit(m("补丁不匹配：%s\n期望原文：\n%s", "Patch mismatch: %s\nExpected original text:\n%s") % (rel, old))
        with open(path, "w", encoding="utf-8") as f:
            f.write(src.replace(old, new))
        print(m("已修改 %s", "Patched %s") % rel)


if __name__ == "__main__":
    main()
