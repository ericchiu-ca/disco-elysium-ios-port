// 让 Unity 2020.3 iOS 播放器直接使用硬件 BC 纹理（Mac 版资源全部是 DXT/BC 格式）。
// Let the Unity 2020.3 iOS player use hardware BC textures directly (all Mac assets are in DXT/BC formats).
//
// tools/patch_player_lib.py 把 TextureFormatMetal.o 里的 5 个函数改名为 de_orig_*，
// 这里按原来的 C++ 修饰名重新定义它们：BC 格式由这里处理，其余格式原样转交原函数。
// tools/patch_player_lib.py renames 5 functions in TextureFormatMetal.o to de_orig_*;
// they are redefined here under their original C++ mangled names: BC formats are handled here, and all other
// formats are passed through unchanged to the original functions.
// 同时提供 DEMetalSupportsBC()，供打过补丁的 InitFormatUsageFlags 决定是否把 BC 标为可采样。
// Also provides DEMetalSupportsBC(), which the patched InitFormatUsageFlags uses to decide whether to mark BC as sampleable.
//
// 只有在以下条件都满足时才启用，否则完全保持 Unity 原行为（CPU 解压）：
// Enabled only when all of the following hold; otherwise Unity's original behavior (CPU decompression) is kept entirely:
//   - MTLDevice.supportsBCTextureCompression（M 系列 iPad）
//   - MTLDevice.supportsBCTextureCompression (M-series iPads)
//   - 启动自检确认 GraphicsFormat 96..109 确实是 DXT1..BC7（防止版本不符时显示错乱）
//   - A startup self-check confirms that GraphicsFormat 96..109 really are DXT1..BC7
//     (prevents garbled rendering on a version mismatch)
//   - 未设置环境变量 DE_DISABLE_BC
//   - The environment variable DE_DISABLE_BC is not set

#import <Metal/Metal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

enum GraphicsFormat : int32_t {};

// Unity 内部函数（libiPhone-lib-il2cpp.a 的 Runtime_Graphics_3.o），用于自检
// Unity internal functions (Runtime_Graphics_3.o in libiPhone-lib-il2cpp.a), used for the self-check
bool IsSRGBFormat(GraphicsFormat);
bool IsCompressedFormat(GraphicsFormat);
uint32_t GetBlockSize(GraphicsFormat);

extern "C" {
MTLPixelFormat de_orig_PixelFormat(GraphicsFormat format, GraphicsFormat* actualFormat);
int32_t de_orig_TextureFormatBlockSize(MTLPixelFormat format);
int32_t de_orig_PixelFormatElementSize(MTLPixelFormat format);
bool de_orig_IsCompressedPixelFormat(MTLPixelFormat format);
GraphicsFormat de_orig_UnityGraphicsFormat(MTLPixelFormat format);
}

namespace
{
    struct BCFormat
    {
        int32_t graphicsFormat;     // UnityEngine.Experimental.Rendering.GraphicsFormat
        MTLPixelFormat pixelFormat;
        int32_t bytesPerBlock;      // 4x4 像素块 | 4x4 pixel block
        bool srgb;
    };

    const BCFormat kBCFormats[] =
    {
        { 96,  MTLPixelFormatBC1_RGBA_sRGB,      8,  true  },  // RGBA_DXT1_SRGB
        { 97,  MTLPixelFormatBC1_RGBA,           8,  false },  // RGBA_DXT1_UNorm
        { 98,  MTLPixelFormatBC2_RGBA_sRGB,      16, true  },  // RGBA_DXT3_SRGB
        { 99,  MTLPixelFormatBC2_RGBA,           16, false },  // RGBA_DXT3_UNorm
        { 100, MTLPixelFormatBC3_RGBA_sRGB,      16, true  },  // RGBA_DXT5_SRGB
        { 101, MTLPixelFormatBC3_RGBA,           16, false },  // RGBA_DXT5_UNorm
        { 102, MTLPixelFormatBC4_RUnorm,         8,  false },  // R_BC4_UNorm
        { 103, MTLPixelFormatBC4_RSnorm,         8,  false },  // R_BC4_SNorm
        { 104, MTLPixelFormatBC5_RGUnorm,        16, false },  // RG_BC5_UNorm
        { 105, MTLPixelFormatBC5_RGSnorm,        16, false },  // RG_BC5_SNorm
        { 106, MTLPixelFormatBC6H_RGBUfloat,     16, false },  // RGB_BC6H_UFloat
        { 107, MTLPixelFormatBC6H_RGBFloat,      16, false },  // RGB_BC6H_SFloat
        { 108, MTLPixelFormatBC7_RGBAUnorm_sRGB, 16, true  },  // RGBA_BC7_SRGB
        { 109, MTLPixelFormatBC7_RGBAUnorm,      16, false },  // RGBA_BC7_UNorm
    };

    const BCFormat* FindByGraphicsFormat(int32_t f)
    {
        for (const BCFormat& e : kBCFormats)
            if (e.graphicsFormat == f) return &e;
        return nullptr;
    }

    const BCFormat* FindByPixelFormat(MTLPixelFormat f)
    {
        for (const BCFormat& e : kBCFormats)
            if (e.pixelFormat == f) return &e;
        return nullptr;
    }

    bool SelfCheck()
    {
        for (const BCFormat& e : kBCFormats)
        {
            GraphicsFormat f = (GraphicsFormat)e.graphicsFormat;
            if (!IsCompressedFormat(f) || IsSRGBFormat(f) != e.srgb || GetBlockSize(f) != (uint32_t)e.bytesPerBlock)
            {
                printf("[DEPort] BC self-check failed: GraphicsFormat %d compressed=%d srgb=%d block=%u\n",
                       e.graphicsFormat, IsCompressedFormat(f), IsSRGBFormat(f), GetBlockSize(f));
                return false;
            }
        }
        return true;
    }

    // 原函数在不使用 sRGB 采样时会把 sRGB 格式换成线性格式；用 ASTC 4x4 sRGB 探测同样的策略
    // When sRGB sampling is not in use, the original function swaps sRGB formats for linear ones;
    // probe that policy with ASTC 4x4 sRGB
    bool KeepsSRGB()
    {
        static int keeps = -1;
        if (keeps < 0)
        {
            const GraphicsFormat astcSRGB = (GraphicsFormat)129;  // RGBA_ASTC4X4_SRGB
            GraphicsFormat actual = astcSRGB;
            if (IsSRGBFormat(astcSRGB))
                de_orig_PixelFormat(astcSRGB, &actual);
            keeps = (actual == astcSRGB) ? 1 : 0;
        }
        return keeps == 1;
    }
}

extern "C" bool DEMetalSupportsBC()
{
    static int supported = -1;
    if (supported < 0)
    {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        const bool hw = device.supportsBCTextureCompression;
        const bool disabled = getenv("DE_DISABLE_BC") != nullptr;
        const bool ok = SelfCheck();
        supported = (hw && !disabled && ok) ? 1 : 0;
        printf("[DEPort] BC textures: %s (hardware=%d, disabled=%d, selfcheck=%d)\n",
               supported ? "hardware" : "CPU decompression", hw, disabled, ok);
    }
    return supported == 1;
}

namespace metal
{
    MTLPixelFormat PixelFormat(GraphicsFormat format, GraphicsFormat* actualFormat)
    {
        const BCFormat* e = FindByGraphicsFormat(format);
        if (!e || !DEMetalSupportsBC())
            return de_orig_PixelFormat(format, actualFormat);

        if (e->srgb && !KeepsSRGB())
            e = FindByGraphicsFormat(format + 1);  // 每个 sRGB 格式的下一个就是对应的 UNorm | the format right after each sRGB one is its UNorm counterpart
        if (actualFormat) *actualFormat = (GraphicsFormat)e->graphicsFormat;
        return e->pixelFormat;
    }

    int32_t TextureFormatBlockSize(MTLPixelFormat format)
    {
        return FindByPixelFormat(format) ? 4 : de_orig_TextureFormatBlockSize(format);
    }

    int32_t PixelFormatElementSize(MTLPixelFormat format)
    {
        const BCFormat* e = FindByPixelFormat(format);
        return e ? e->bytesPerBlock : de_orig_PixelFormatElementSize(format);
    }

    bool IsCompressedPixelFormat(MTLPixelFormat format)
    {
        return FindByPixelFormat(format) ? true : de_orig_IsCompressedPixelFormat(format);
    }

    GraphicsFormat UnityGraphicsFormat(MTLPixelFormat format)
    {
        const BCFormat* e = FindByPixelFormat(format);
        return e ? (GraphicsFormat)e->graphicsFormat : de_orig_UnityGraphicsFormat(format);
    }
}
