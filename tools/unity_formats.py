"""Unity 2020.3 资源文件格式的最小实现：只做本移植需要的事情——修改目标平台字段。

  - SerializedFile（level*, sharedassets*.assets, globalgamemanagers 等）：头部 metadata 里的
    m_TargetPlatform（int32）从 StandaloneOSX(2) 改为 iOS(9)，否则 iOS 播放器会拒绝加载
  - UnityFS AssetBundle：解压全部数据块，修改其中每个 SerializedFile 的平台字段，再用 LZ4 重新压缩

LZ4 使用 macOS 自带的 libcompression（COMPRESSION_LZ4_RAW 即标准 LZ4 block 格式），无第三方依赖。

A minimal implementation of the Unity 2020.3 asset file formats that does only what this port
needs: changing the target platform field.

  - SerializedFile (level*, sharedassets*.assets, globalgamemanagers, etc.): change m_TargetPlatform
    (int32) in the header metadata from StandaloneOSX(2) to iOS(9); otherwise the iOS player refuses to load it
  - UnityFS AssetBundle: decompress all data blocks, patch the platform field of every SerializedFile
    inside, then recompress with LZ4

LZ4 uses the libcompression that ships with macOS (COMPRESSION_LZ4_RAW is the standard LZ4 block
format), with no third-party dependencies.
"""
import ctypes
import lzma
import os
import struct


def m(zh, en):
    """按 DE_LANG / 系统语言选择输出语言 | Pick the output language from DE_LANG / the system language"""
    lang = os.environ.get("DE_LANG") or os.environ.get("LC_ALL") or os.environ.get("LANG") or ""
    return zh if lang.startswith("zh") else en


BUILD_TARGET_OSX = 2
BUILD_TARGET_IOS = 9

# ---------------------------------------------------------------- libcompression

_lib = ctypes.CDLL("/usr/lib/libcompression.dylib")
_COMPRESSION_LZ4_RAW = 0x101
for _fn in (_lib.compression_encode_buffer, _lib.compression_decode_buffer):
    _fn.restype = ctypes.c_size_t
    _fn.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t,
                    ctypes.c_void_p, ctypes.c_int]


def lz4_decompress(src, uncompressed_size):
    dst = ctypes.create_string_buffer(uncompressed_size)
    n = _lib.compression_decode_buffer(dst, uncompressed_size, src, len(src), None, _COMPRESSION_LZ4_RAW)
    if n != uncompressed_size:
        raise ValueError(m("LZ4 解压长度不符：%d != %d", "LZ4 decompressed length mismatch: %d != %d")
                         % (n, uncompressed_size))
    return dst.raw


def lz4_compress(src):
    cap = len(src) + len(src) // 255 + 64
    dst = ctypes.create_string_buffer(cap)
    n = _lib.compression_encode_buffer(dst, cap, src, len(src), None, _COMPRESSION_LZ4_RAW)
    if n == 0:
        raise ValueError(m("LZ4 压缩失败", "LZ4 compression failed"))
    return dst.raw[:n]


def lzma_decompress(src, uncompressed_size):
    # Unity 的 LZMA 块：5 字节属性（lc/lp/pb + 字典大小）+ 原始 LZMA 流
    # Unity's LZMA blocks: 5 bytes of properties (lc/lp/pb + dictionary size) + a raw LZMA stream
    props = src[0]
    dict_size = struct.unpack("<I", src[1:5])[0]
    lc, props = props % 9, props // 9
    lp, pb = props % 5, props // 5
    dec = lzma.LZMADecompressor(format=lzma.FORMAT_RAW, filters=[
        {"id": lzma.FILTER_LZMA1, "dict_size": dict_size, "lc": lc, "lp": lp, "pb": pb}])
    out = dec.decompress(src[5:], max_length=uncompressed_size)
    if len(out) != uncompressed_size:
        raise ValueError(m("LZMA 解压长度不符", "LZMA decompressed length mismatch"))
    return out


def decompress_block(data, uncompressed_size, flags):
    kind = flags & 0x3F
    if kind == 0:
        return bytes(data)
    if kind == 1:
        return lzma_decompress(data, uncompressed_size)
    if kind in (2, 3):
        return lz4_decompress(data, uncompressed_size)
    raise ValueError(m("未知的块压缩类型 %d", "Unknown block compression type %d") % kind)

# ---------------------------------------------------------------- SerializedFile


def serialized_platform_offset(head):
    """返回 SerializedFile 中 m_TargetPlatform 的偏移和字节序；不是 SerializedFile 时返回 None。 | Return the offset and byte order of m_TargetPlatform in a SerializedFile; None if it is not a SerializedFile."""
    if len(head) < 64:
        return None
    version = struct.unpack(">I", head[8:12])[0]
    if not 9 <= version <= 30:
        return None
    if version >= 22:
        endian, meta = head[16], 48
    else:
        endian, meta = head[16], 20
    try:
        end = head.index(b"\0", meta, min(len(head), meta + 32))
    except ValueError:
        return None
    unity_version = head[meta:end]
    if not (unity_version[:2].isdigit() and b"." in unity_version):
        return None
    return end + 1, ("<" if endian == 0 else ">")


def patch_platform(buf, offset_in_buf, target, expect=BUILD_TARGET_OSX):
    """在 bytearray/mmap 中修改平台字段。返回 True 表示改了，False 表示本来就是目标平台。 | Patch the platform field in a bytearray/mmap. Returns True if it was changed, False if it already was the target platform."""
    head = bytes(buf[offset_in_buf:offset_in_buf + 128])
    found = serialized_platform_offset(head)
    if found is None:
        raise ValueError(m("不是 SerializedFile", "Not a SerializedFile"))
    off, endian = found
    cur = struct.unpack(endian + "i", head[off:off + 4])[0]
    if cur == target:
        return False
    if cur != expect:
        raise ValueError(m("意外的平台值 %d", "Unexpected platform value %d") % cur)
    buf[offset_in_buf + off:offset_in_buf + off + 4] = struct.pack(endian + "i", target)
    return True


def is_serialized_file(path):
    with open(path, "rb") as f:
        return serialized_platform_offset(f.read(128)) is not None


def patch_serialized_file_inplace(path, target=BUILD_TARGET_IOS):
    with open(path, "r+b") as f:
        head = bytearray(f.read(128))
        changed = patch_platform(head, 0, target)
        if changed:
            f.seek(0)
            f.write(head)
    return changed

# ---------------------------------------------------------------- UnityFS


def _read_cstr(b, o):
    e = b.index(b"\0", o)
    return b[o:e], e + 1


def _align(n, a=16):
    return (n + a - 1) // a * a


BLOCK_SIZE = 0x20000  # Unity 默认的 LZ4 分块大小（128 KiB） | Unity's default LZ4 chunk size (128 KiB)


def rewrite_bundle(src_path, dst_path, target=BUILD_TARGET_IOS):
    """读取 UnityFS 包，修改内部所有 SerializedFile 的平台字段，以 LZ4 分块重写到 dst_path。
    返回被修改的 SerializedFile 数量。

    Read a UnityFS bundle, patch the platform field of every SerializedFile inside, and rewrite it
    to dst_path in LZ4 chunks. Returns the number of SerializedFiles that were patched."""
    with open(src_path, "rb") as f:
        raw = f.read()
    if not raw.startswith(b"UnityFS\0"):
        raise ValueError(m("不是 UnityFS 包", "Not a UnityFS bundle"))
    o = 8
    version = struct.unpack(">I", raw[o:o + 4])[0]; o += 4
    ver_str, o = _read_cstr(raw, o)
    rev_str, o = _read_cstr(raw, o)
    _size, cbi_size, ubi_size, flags = struct.unpack(">qIII", raw[o:o + 20]); o += 20
    if version >= 7:
        o = _align(o)
    if flags & 0x80:  # 块信息在文件末尾 | The block info is at the end of the file
        bi_start = len(raw) - cbi_size
        data_start = o
    else:
        bi_start = o
        data_start = o + cbi_size
    if flags & 0x200:
        data_start = _align(data_start)

    info = decompress_block(raw[bi_start:bi_start + cbi_size], ubi_size, flags)
    p = 0
    data_hash = info[p:p + 16]; p += 16
    (block_count,) = struct.unpack(">i", info[p:p + 4]); p += 4
    blocks = []
    for _ in range(block_count):
        usz, csz, bfl = struct.unpack(">IIH", info[p:p + 10]); p += 10
        blocks.append((usz, csz, bfl))
    (node_count,) = struct.unpack(">i", info[p:p + 4]); p += 4
    nodes = []
    for _ in range(node_count):
        noff, nsz, nfl = struct.unpack(">qqI", info[p:p + 20]); p += 20
        name, p = _read_cstr(info, p)
        nodes.append((noff, nsz, nfl, name))

    # 解压全部数据
    # Decompress all of the data
    data = bytearray()
    q = data_start
    for usz, csz, bfl in blocks:
        data += decompress_block(raw[q:q + csz], usz, bfl)
        q += csz

    patched = 0
    for noff, nsz, nfl, name in nodes:
        if nfl & 0x4 and serialized_platform_offset(bytes(data[noff:noff + 128])):
            if patch_platform(data, noff, target):
                patched += 1

    # 以 LZ4 分块重新压缩；压缩无收益的块按原样存储
    # Recompress in LZ4 chunks; chunks that do not get smaller are stored as is
    new_blocks, chunks = [], []
    for i in range(0, len(data), BLOCK_SIZE):
        piece = bytes(data[i:i + BLOCK_SIZE])
        comp = lz4_compress(piece)
        if len(comp) < len(piece):
            new_blocks.append((len(piece), len(comp), 0x2))
            chunks.append(comp)
        else:
            new_blocks.append((len(piece), len(piece), 0x0))
            chunks.append(piece)

    info_out = bytearray(data_hash)
    info_out += struct.pack(">i", len(new_blocks))
    for usz, csz, bfl in new_blocks:
        info_out += struct.pack(">IIH", usz, csz, bfl)
    info_out += struct.pack(">i", len(nodes))
    for noff, nsz, nfl, name in nodes:
        info_out += struct.pack(">qqI", noff, nsz, nfl) + name + b"\0"
    # 块信息很小时 LZ4 会让它变大；Unity 读不了"压缩后更大"的块信息，这种情况按未压缩存放
    # When the block info is small, LZ4 makes it larger; Unity cannot read block info that is "larger after compression", so store it uncompressed in that case
    info_comp = lz4_compress(bytes(info_out))
    info_kind = 0x2
    if len(info_comp) >= len(info_out):
        info_comp, info_kind = bytes(info_out), 0x0

    out_flags = 0x40 | info_kind  # 块信息与目录合并存放、紧跟头部 | Block info and directory stored together, right after the header
    header = bytearray(b"UnityFS\0")
    header += struct.pack(">I", version) + ver_str + b"\0" + rev_str + b"\0"
    size_pos = len(header)
    header += struct.pack(">qIII", 0, len(info_comp), len(info_out), out_flags)
    if version >= 7:
        header += b"\0" * (_align(len(header)) - len(header))
    total = len(header) + len(info_comp) + sum(len(c) for c in chunks)
    header[size_pos:size_pos + 8] = struct.pack(">q", total)

    tmp = dst_path + ".part"
    with open(tmp, "wb") as f:
        f.write(header)
        f.write(info_comp)
        for c in chunks:
            f.write(c)
    os.replace(tmp, dst_path)
    return patched


def bundle_platforms(path):
    """调试用：返回包内每个 SerializedFile 的 (名字, 平台)。 | For debugging: return (name, platform) for each SerializedFile in the bundle."""
    with open(path, "rb") as f:
        raw = f.read()
    o = 8
    version = struct.unpack(">I", raw[o:o + 4])[0]; o += 4
    _, o = _read_cstr(raw, o)
    _, o = _read_cstr(raw, o)
    _size, cbi_size, ubi_size, flags = struct.unpack(">qIII", raw[o:o + 20]); o += 20
    if version >= 7:
        o = _align(o)
    bi_start, data_start = (len(raw) - cbi_size, o) if flags & 0x80 else (o, o + cbi_size)
    if flags & 0x200:
        data_start = _align(data_start)
    info = decompress_block(raw[bi_start:bi_start + cbi_size], ubi_size, flags)
    p = 16
    (bc,) = struct.unpack(">i", info[p:p + 4]); p += 4
    blocks = [struct.unpack(">IIH", info[p + 10 * i:p + 10 * i + 10]) for i in range(bc)]
    p += 10 * bc
    (nc,) = struct.unpack(">i", info[p:p + 4]); p += 4
    nodes = []
    for _ in range(nc):
        noff, nsz, nfl = struct.unpack(">qqI", info[p:p + 20]); p += 20
        name, p = _read_cstr(info, p)
        nodes.append((noff, nsz, nfl, name))
    data = bytearray()
    q = data_start
    for usz, csz, bfl in blocks:
        data += decompress_block(raw[q:q + csz], usz, bfl)
        q += csz
    result = []
    for noff, nsz, nfl, name in nodes:
        found = serialized_platform_offset(bytes(data[noff:noff + 128])) if nfl & 4 else None
        if found:
            off, e = found
            result.append((name.decode(), struct.unpack(e + "i", bytes(data[noff + off:noff + off + 4]))[0]))
        else:
            result.append((name.decode(), None))
    return result
