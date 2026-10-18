// Metal 能力诊断：Mac 版的纹理是 BC（DXT/BC7）压缩格式。M 系列 iPad 的 GPU 硬件支持 BC，
// 但 Unity 2020.3 的 iOS 播放器写于 iOS 支持 BC 之前，会认为不支持并在 CPU 上解压（占用 4～8 倍内存）。
// 这里先记录 Unity 查询了哪些 GPU 家族 / 特性集，以确定怎样让它启用硬件 BC。
// Metal capability diagnostics: the Mac version's textures use BC (DXT/BC7) compressed formats. The GPUs in
// M-series iPads support BC in hardware, but Unity 2020.3's iOS player predates BC support on iOS, so it assumes
// BC is unsupported and decompresses on the CPU (using 4-8x the memory).
// As a first step, log which GPU families / feature sets Unity queries, to work out how to make it enable hardware BC.

#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <stdio.h>

static IMP gOrigSupportsFamily;
static IMP gOrigSupportsFeatureSet;

// Unity 每帧都会查询，只记录每个值的第一次
// Unity queries these every frame; log only the first query for each value
static bool FirstQuery(NSUInteger kind, NSUInteger value)
{
    static NSMutableSet<NSNumber*>* seen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
    NSNumber* key = @((kind << 32) | value);
    @synchronized(seen)
    {
        if ([seen containsObject: key]) return false;
        [seen addObject: key];
        return true;
    }
}

static BOOL DE_supportsFamily(id self, SEL _cmd, MTLGPUFamily family)
{
    BOOL r = ((BOOL (*)(id, SEL, MTLGPUFamily))gOrigSupportsFamily)(self, _cmd, family);
    if (FirstQuery(1, family)) printf("[DEPort] MTLDevice supportsFamily:%ld -> %d\n", (long)family, r);
    return r;
}

static BOOL DE_supportsFeatureSet(id self, SEL _cmd, NSUInteger featureSet)
{
    BOOL r = ((BOOL (*)(id, SEL, NSUInteger))gOrigSupportsFeatureSet)(self, _cmd, featureSet);
    if (FirstQuery(2, featureSet)) printf("[DEPort] MTLDevice supportsFeatureSet:%lu -> %d\n", (unsigned long)featureSet, r);
    return r;
}

extern "C" void DEInstallMetalCapsProbe(void)
{
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) return;
    printf("[DEPort] GPU %s, supportsBCTextureCompression=%d, recommendedMaxWorkingSetSize=%llu MB\n",
           device.name.UTF8String, (int)device.supportsBCTextureCompression,
           device.recommendedMaxWorkingSetSize / (1024 * 1024));

    Class cls = object_getClass(device);
    Method m1 = class_getInstanceMethod(cls, @selector(supportsFamily:));
    Method m2 = class_getInstanceMethod(cls, @selector(supportsFeatureSet:));
    if (m1) gOrigSupportsFamily = method_setImplementation(m1, (IMP)DE_supportsFamily);
    if (m2) gOrigSupportsFeatureSet = method_setImplementation(m2, (IMP)DE_supportsFeatureSet);
}
