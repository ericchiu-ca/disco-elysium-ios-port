#!/usr/bin/env python3
"""把 Mac 版 Data 目录转换为 iOS 播放器能读取的 GameData 目录。

输出沿用 Mac 版 .app 的目录结构 <GameData>/Contents/Resources/Data，因为游戏的托管代码看到的
平台是 Mac，会按 Application.dataPath（= Contents）拼路径（例如 AmplifyTexture）。

Data 目录内部的映射（Mac → iOS 播放器）：
  Data/StreamingAssets/**          → Data/Raw/**             （iOS 的 streamingAssetsPath）
  Data/il2cpp_data/Metadata/*      → Data/Managed/Metadata/*
  Data/il2cpp_data/Resources/*     → Data/Managed/Resources/*
  Data/il2cpp_data/etc/**          → Data/Managed/etc/**
  其余文件                          → Data/** 原样
  iOS 运行时自带的 unity default resources → Data/unity default resources

文件处理：
  UnityFS 包         解压 → 平台字段 2→9 → LZ4 重新压缩（多进程）
  SerializedFile     APFS 克隆后原地修改 4 字节平台字段
  其他（.resS/.vtc2 等原始数据）  APFS 克隆（同一卷上瞬间完成、不占额外空间）

支持增量：源文件大小与修改时间不变时跳过。
用法：convert_data.py <Mac Data 目录> <iOS unity default resources> <输出 GameData 目录> [--jobs N]

Convert the Mac version's Data directory into a GameData directory that the iOS player can read.

The output keeps the directory layout of the Mac .app, <GameData>/Contents/Resources/Data, because
the game's managed code sees Mac as its platform and builds paths from Application.dataPath
(= Contents), for example for AmplifyTexture.

Mapping inside the Data directory (Mac → iOS player):
  Data/StreamingAssets/**          → Data/Raw/**             (the iOS streamingAssetsPath)
  Data/il2cpp_data/Metadata/*      → Data/Managed/Metadata/*
  Data/il2cpp_data/Resources/*     → Data/Managed/Resources/*
  Data/il2cpp_data/etc/**          → Data/Managed/etc/**
  all other files                  → Data/** unchanged
  unity default resources shipped with the iOS runtime → Data/unity default resources

File handling:
  UnityFS bundles    decompress → platform field 2→9 → recompress with LZ4 (multiprocess)
  SerializedFile     APFS clone, then patch the 4-byte platform field in place
  everything else (raw data such as .resS/.vtc2)  APFS clone (instant on the same volume, no extra space)

Incremental: files whose source size and modification time are unchanged are skipped.
Usage: convert_data.py <Mac Data directory> <iOS unity default resources> <output GameData directory> [--jobs N]
"""
import ctypes
import json
import os
import shutil
import sys
import time
from concurrent.futures import ProcessPoolExecutor, as_completed

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import unity_formats as uf  # noqa: E402


def m(zh, en):
    """按 DE_LANG / 系统语言选择输出语言 | Pick the output language from DE_LANG / the system language"""
    lang = os.environ.get("DE_LANG") or os.environ.get("LC_ALL") or os.environ.get("LANG") or ""
    return zh if lang.startswith("zh") else en


FORMAT_VERSION = 2  # 必须与 shell/src/DEBootstrap.mm 中的 kGameDataFormatVersion 一致 | Must match kGameDataFormatVersion in shell/src/DEBootstrap.mm
# 转换逻辑本身的修订号：变化时重新处理全部文件（目录结构不变，推送时只传有变化的文件）
# Revision of the conversion logic itself: when it changes, every file is reprocessed (the directory layout stays the same, so a push only transfers changed files)
CONVERTER_REVISION = 2  # 2：块信息压缩后不变小时按未压缩存放 | 2: store the block info uncompressed when compression does not make it smaller
STATE_FILE = ".convert-state.json"

_libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
_libc.clonefile.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint32]


def clone(src, dst):
    if os.path.lexists(dst):
        os.remove(dst)
    if _libc.clonefile(os.fsencode(src), os.fsencode(dst), 0) != 0:
        shutil.copyfile(src, dst)  # 跨卷时退回普通复制 | Fall back to a regular copy across volumes


def map_path(rel):
    parts = rel.split(os.sep)
    if parts[0] == "StreamingAssets":
        return os.path.join("Raw", *parts[1:])
    if parts[0] == "il2cpp_data":
        return os.path.join("Managed", *parts[1:])
    return rel


def classify(path):
    with open(path, "rb") as f:
        head = f.read(128)
    if head.startswith(b"UnityFS\0"):
        return "bundle"
    if uf.serialized_platform_offset(head) is not None:
        return "serialized"
    return "raw"


def process(task):
    kind, src, dst = task
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if kind == "bundle":
        uf.rewrite_bundle(src, dst)
    elif kind == "serialized":
        clone(src, dst)
        uf.patch_serialized_file_inplace(dst)
    else:
        clone(src, dst)
    return task


def main():
    args = sys.argv[1:]
    jobs = os.cpu_count() or 4
    if "--jobs" in args:
        i = args.index("--jobs")
        jobs = int(args[i + 1])
        del args[i:i + 2]
    src_data, ios_default_res, out_root = args
    out_data = os.path.join(out_root, "Contents", "Resources", "Data")

    state_path = os.path.join(out_root, STATE_FILE)
    try:
        with open(state_path) as f:
            state = json.load(f)
    except (OSError, ValueError):
        state = {}
    if state.get("__format__") != FORMAT_VERSION:
        # 目录结构变了：整个重建（同卷上是 APFS 克隆，代价很小）
        # The directory layout changed: rebuild everything (cheap, since these are APFS clones on the same volume)
        if os.path.isdir(out_root):
            shutil.rmtree(out_root)
        state = {"__format__": FORMAT_VERSION}
    if state.get("__revision__") != CONVERTER_REVISION:
        state = {"__format__": FORMAT_VERSION, "__revision__": CONVERTER_REVISION}
    os.makedirs(out_data, exist_ok=True)

    tasks, wanted, skipped = [], set(), 0
    for dirpath, dirnames, filenames in os.walk(src_data):
        dirnames.sort()
        for name in sorted(filenames):
            if name == ".DS_Store":
                continue
            src = os.path.join(dirpath, name)
            rel = os.path.relpath(src, src_data)
            dst_rel = map_path(rel)
            dst = os.path.join(out_data, dst_rel)
            wanted.add(dst_rel)
            st = os.stat(src)
            sig = [st.st_size, st.st_mtime_ns]
            if state.get(dst_rel, {}).get("sig") == sig and os.path.exists(dst):
                skipped += 1
                continue
            tasks.append((classify(src), src, dst, dst_rel, sig))

    # iOS 运行时自带的内置资源（Mac 版这个文件不在 Data 里）
    # Built-in resources shipped with the iOS runtime (in the Mac version this file is not in Data)
    tasks.append(("raw", ios_default_res, os.path.join(out_data, "unity default resources"),
                  "unity default resources", [os.path.getsize(ios_default_res), 0]))
    wanted.add("unity default resources")

    # 删除源里已不存在的旧文件
    # Delete old files that no longer exist in the source
    for dst_rel in [k for k in state if not k.startswith("__") and k not in wanted]:
        p = os.path.join(out_data, dst_rel)
        if os.path.exists(p):
            os.remove(p)
        del state[dst_rel]

    counts = {"bundle": 0, "serialized": 0, "raw": 0}
    for t in tasks:
        counts[t[0]] += 1
    print(m("待处理 %d 个文件（UnityFS 包 %d、SerializedFile %d、原始数据 %d），跳过未变化的 %d 个",
            "%d files to process (UnityFS bundles %d, SerializedFiles %d, raw data %d), %d unchanged files skipped")
          % (len(tasks), counts["bundle"], counts["serialized"], counts["raw"], skipped))

    start = time.time()
    done = 0
    with ProcessPoolExecutor(max_workers=jobs) as pool:
        futures = {pool.submit(process, t[:3]): t for t in tasks}
        for fut in as_completed(futures):
            t = futures[fut]
            fut.result()  # 出错时直接抛出，带上文件名 | Re-raises on error, with the file name
            state[t[3]] = {"sig": t[4], "kind": t[0]}
            done += 1
            if done % 200 == 0 or done == len(tasks):
                print("  %d/%d  %.0fs" % (done, len(tasks), time.time() - start), flush=True)
                with open(state_path, "w") as f:
                    json.dump(state, f)

    with open(state_path, "w") as f:
        json.dump(state, f)

    build_info = os.path.join(src_data, "StreamingAssets", "build_info.txt")
    marker = {
        "format": FORMAT_VERSION,
        "source_build": open(build_info).read().strip() if os.path.exists(build_info) else None,
        "files": len(wanted),
        "converted_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
    }
    with open(os.path.join(out_root, "de-port.json"), "w") as f:
        json.dump(marker, f, ensure_ascii=False, indent=2)
    print(m("完成：%s（%d 个文件，用时 %.0fs）", "Done: %s (%d files, %.0fs)")
          % (out_root, len(wanted), time.time() - start))


if __name__ == "__main__":
    main()
