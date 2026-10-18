#!/usr/bin/env python3
"""给 Unity iOS 播放器静态库打 BC 纹理补丁，输出一份修改后的副本（原文件不动）。

Unity 2020.3 的 iOS 播放器写于 iOS 支持 BC 纹理之前，TextureFormatMetal.o 里：
  - metal::PixelFormat(GraphicsFormat) 不映射 GraphicsFormat 96..109（DXT1/3/5、BC4/5/6H/7）
  - metal::InitFormatUsageFlags 不给这些格式任何能力标志 → 加载时在 CPU 上解压（4～8 倍内存）
  - TextureFormatBlockSize / PixelFormatElementSize / IsCompressedPixelFormat / UnityGraphicsFormat
    不认识 MTLPixelFormatBC*
M 系列 iPad 的 GPU 硬件支持 BC（MTLDevice.supportsBCTextureCompression）。

这个对象文件是"原生代码 + 嵌入 bitcode"，所以在 LLVM IR 层面修改再重新编译：
  1. 把上面 5 个函数改名为 de_orig_*，由 shell/src/DEMetalBC.mm 按原修饰名提供包装函数：
     BC 格式自己处理，其余格式转交原函数
  2. 在 InitFormatUsageFlags 的收尾循环之前插入：若 DEMetalSupportsBC() 为真，
     把 96..109 的能力值设为 3（与 iOS 原生支持的 ETC/ASTC 相同），收尾循环再补齐其余标志
每处修改都要求原文完全匹配，否则报错退出。

用法：patch_player_lib.py <原 libiPhone-lib-il2cpp.a> <输出 .a> <工作目录>

Apply the BC texture patch to the Unity iOS player static library, writing a modified copy (the
original file is left untouched).

The Unity 2020.3 iOS player predates BC texture support on iOS. In TextureFormatMetal.o:
  - metal::PixelFormat(GraphicsFormat) does not map GraphicsFormat 96..109 (DXT1/3/5, BC4/5/6H/7)
  - metal::InitFormatUsageFlags gives these formats no capability flags → they are decompressed
    on the CPU at load time (4-8x the memory)
  - TextureFormatBlockSize / PixelFormatElementSize / IsCompressedPixelFormat / UnityGraphicsFormat
    do not recognize MTLPixelFormatBC*
The GPUs of M-series iPads support BC in hardware (MTLDevice.supportsBCTextureCompression).

This object file is "native code + embedded bitcode", so it is modified at the LLVM IR level and
recompiled:
  1. Rename the 5 functions above to de_orig_*; shell/src/DEMetalBC.mm provides wrappers under the
     original mangled names that handle BC formats themselves and forward all other formats to the
     original functions
  2. Before the final loop of InitFormatUsageFlags, insert: if DEMetalSupportsBC() is true, set the
     capability value of 96..109 to 3 (the same as the natively supported ETC/ASTC on iOS); the
     final loop then fills in the remaining flags
Every modification requires an exact match of the original text; otherwise it exits with an error.

Usage: patch_player_lib.py <original libiPhone-lib-il2cpp.a> <output .a> <work directory>
"""
import os
import re
import shutil
import subprocess
import sys


# 名字不用 m：rename_functions() 里的局部变量 m 会遮住它
# Not named m: the local variable m in rename_functions() would shadow it
def msg(zh, en):
    """按 DE_LANG / 系统语言选择输出语言 | Pick the output language from DE_LANG / the system language"""
    lang = os.environ.get("DE_LANG") or os.environ.get("LC_ALL") or os.environ.get("LANG") or ""
    return zh if lang.startswith("zh") else en


MEMBER = "TextureFormatMetal.o"
TARGET = "arm64-apple-ios12.0"

RENAMES = {
    "_ZN5metal11PixelFormatE14GraphicsFormatPS0_": "de_orig_PixelFormat",
    "_ZN5metal22TextureFormatBlockSizeE14MTLPixelFormat": "de_orig_TextureFormatBlockSize",
    "_ZN5metal22PixelFormatElementSizeE14MTLPixelFormat": "de_orig_PixelFormatElementSize",
    "_ZN5metal23IsCompressedPixelFormatE14MTLPixelFormat": "de_orig_IsCompressedPixelFormat",
    "_ZN5metal19UnityGraphicsFormatE14MTLPixelFormat": "de_orig_UnityGraphicsFormat",
}
INIT_FLAGS = "_ZN5metal20InitFormatUsageFlagsEP12GraphicsCaps"


def run(*cmd, cwd=None):
    subprocess.run(cmd, cwd=cwd, check=True)


def rename_functions(ir):
    declares = []
    for old, new in RENAMES.items():
        pat = re.compile(r"^define ([^@\n]*)@%s\(([^)]*)\)" % re.escape(old), re.M)
        m = pat.search(ir)
        if not m or len(pat.findall(ir)) != 1:
            sys.exit(msg("补丁不匹配：找不到唯一的 define @%s",
                         "Patch mismatch: no unique define @%s found") % old)
        ret = m.group(1).replace("local_unnamed_addr", "").strip()
        params = ", ".join(p.strip().rsplit(" ", 1)[0] for p in m.group(2).split(",") if p.strip())
        declares.append("declare %s @%s(%s)" % (ret, old, params))
        ir = ir[:m.start()] + "define %s@%s(%s)" % (m.group(1), new, m.group(2)) + ir[m.end():]
    return ir, declares


def patch_init_flags(ir):
    start = ir.index("define hidden void @%s(" % INIT_FLAGS)
    end = ir.index("\n}\n", start)
    body = ir[start:end]

    br = re.findall(r"\n  br label %120(, !dbg !\d+)\n", body)
    phi = re.findall(r"phi i64 \[ 0, %114 \], \[ %154, %153 \]", body)
    store95 = re.findall(r"getelementptr inbounds %struct.GraphicsCaps, ptr %0, i64 0, i32 52, i64 95", body)
    if len(br) != 1 or len(phi) != 1 or len(store95) != 1:
        sys.exit(msg("补丁不匹配：InitFormatUsageFlags 的结构与 Unity 2020.3.12f1 不同",
                     "Patch mismatch: the structure of InitFormatUsageFlags differs from Unity 2020.3.12f1"))
    dbg = br[0]

    body = body.replace(
        "\n  br label %%120%s\n" % dbg,
        "\n  %%de.bc = tail call zeroext i1 @DEMetalSupportsBC()%s\n"
        "  br i1 %%de.bc, label %%de.setbc, label %%120%s\n\n"
        "de.setbc:\n"
        "  %%de.p = getelementptr inbounds %%struct.GraphicsCaps, ptr %%0, i64 0, i32 52, i64 96\n"
        "  call void @memset_pattern16(ptr %%de.p, ptr @.memset_pattern.3, i64 56)%s\n"
        "  br label %%120%s\n" % (dbg, dbg, dbg, dbg))
    body = body.replace("phi i64 [ 0, %114 ], [ %154, %153 ]",
                        "phi i64 [ 0, %114 ], [ 0, %de.setbc ], [ %154, %153 ]")
    return ir[:start] + body + ir[end:]


def main():
    src_lib, dst_lib, work = sys.argv[1:4]
    os.makedirs(work, exist_ok=True)
    run("xcrun", "ar", "-x", os.path.abspath(src_lib), MEMBER, cwd=work)
    obj = os.path.join(work, MEMBER)
    bc = os.path.join(work, "TextureFormatMetal.bc")
    ll = os.path.join(work, "TextureFormatMetal.ll")
    run("segedit", obj, "-extract", "__LLVM", "__bitcode", bc)
    run("xcrun", "--sdk", "iphoneos", "clang", "-target", TARGET, "-S", "-emit-llvm", "-x", "ir", bc, "-o", ll)

    with open(ll) as f:
        ir = f.read()
    ir, declares = rename_functions(ir)
    ir = patch_init_flags(ir)
    ir += "\n; ---- DEPort BC 纹理补丁 ----\n; ---- DEPort BC texture patch ----\n" + "\n".join(declares)
    ir += "\ndeclare zeroext i1 @DEMetalSupportsBC() local_unnamed_addr\n"
    patched = os.path.join(work, "TextureFormatMetal.patched.ll")
    with open(patched, "w") as f:
        f.write(ir)

    os.remove(obj)
    run("xcrun", "--sdk", "iphoneos", "clang", "-target", TARGET, "-O2", "-w", "-c", "-x", "ir", patched, "-o", obj)

    shutil.copyfile(src_lib, dst_lib)
    run("xcrun", "ar", "-r", os.path.abspath(dst_lib), MEMBER, cwd=work)
    run("xcrun", "ranlib", os.path.abspath(dst_lib))
    print(msg("已生成打过 BC 补丁的播放器库：%s", "Generated the BC-patched player library: %s") % dst_lib)


if __name__ == "__main__":
    main()
