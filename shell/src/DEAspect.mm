// 画面比例：游戏的 AspectUtility 只支持 16:9 / 21:9 / 16:10 / 4:3 等固定比例，
// iPad（约 1.45:1）上会被套用 16:10 并在上下加黑边。
// Aspect ratio: the game's AspectUtility only supports fixed ratios such as 16:9 / 21:9 / 16:10 / 4:3,
// so on iPad (about 1.45:1) it falls back to 16:10 and adds black bars at the top and bottom.
//
// 反汇编（GameAssembly）得到的逻辑：
// Logic recovered by disassembling GameAssembly:
//   UpdateAspectRatio(ratio, fitter)  按设置里的比例：SetAllCameras(ratio) + 设置 UI 适配器
//   UpdateAspectRatio(ratio, fitter)  applies the ratio from settings: SetAllCameras(ratio) + set up the UI fitters
//   SetAllCameras(ratio)  ratio 为 0/1/2 时把静态 wantedAspectRatio 设为 16:9/21:9/16:10，
//                         其他值不改它；然后对每个相机调用 SetCamera()
//   SetAllCameras(ratio)  for ratio 0/1/2, sets the static wantedAspectRatio to 16:9/21:9/16:10;
//                         other values leave it unchanged; then calls SetCamera() on every camera
//   SetCamera()           屏幕比例与 wantedAspectRatio 相等（两位小数）时视口取满屏，否则加黑边
//   SetCamera()           uses a full-screen viewport when the screen ratio equals wantedAspectRatio (to two decimals),
//                         otherwise letterboxes
//
//   AspectRatioFitterUtility.SetFitter  对静态 registry（List）里每个实例的 UI AspectRatioFitter
//                         设置比例：UI 根框宽度占满、高度 = 宽度 / 比例，即居中的 16:10 横条
//   AspectRatioFitterUtility.SetFitter  sets the ratio on the UI AspectRatioFitter of every instance in the static
//                         registry (List): the UI root frame fills the width, height = width / ratio, i.e. a centered 16:10 band
//
// 所以铺满的做法是：
// So the way to fill the screen is:
//   1. 相机：把 wantedAspectRatio 设为屏幕实际比例，再调用 SetAllCameras(3)（不会改写它）
//   1. Cameras: set wantedAspectRatio to the screen's actual ratio, then call SetAllCameras(3) (which does not overwrite it)
//   2. UI：把 registry 里每个 AspectRatioFitter 的 aspectRatio 设为同样的比例（不改模式），
//      否则 UI 仍在 16:10 横条里，而贴屏幕边缘的装饰在屏幕边上，两者会错开。
//      游戏算完一次布局后会把适配器禁用（例如 Global UI Canvas 上的那个），禁用状态下改比例不会重算，
//      所以对禁用的适配器临时启用一下：启用时按新比例立即重算，再禁用恢复原状
//   2. UI: set the aspectRatio of every AspectRatioFitter in the registry to the same ratio (without changing the mode);
//      otherwise the UI stays inside the 16:10 band while decorations anchored to the screen edges sit at the
//      screen edges, and the two are misaligned.
//      After computing the layout once, the game disables the fitter (e.g. the one on the Global UI Canvas), and
//      changing the ratio while disabled does not trigger a recalculation, so disabled fitters are briefly enabled:
//      enabling recalculates immediately with the new ratio, then they are disabled again to restore their state
//   3. HUD 与开局动画：Global UI Canvas 下的 "Global UI Fitter"（游戏脚本 GlobalUIFitter）由
//      RefreshAspect(比例枚举) 从固定表取尺寸（16:9 → 1920×1080 …），没有对应 1.45:1 的值。
//      右下角按钮贴着它的底边，开局动画的背景是它的子节点（上下各多出 100），所以它不满屏时
//      按钮会浮在装饰条上方、动画上下会露出主菜单。这里直接把它的 sizeDelta 设为父 Canvas 的尺寸，
//      每次检查都确认一遍（游戏改设置时会重新调用 RefreshAspect）
//   3. HUD and opening animation: the "Global UI Fitter" under the Global UI Canvas (game script GlobalUIFitter) gets
//      its size from a fixed table via RefreshAspect(ratio enum) (16:9 -> 1920x1080 ...), with no entry for 1.45:1.
//      The bottom-right buttons are anchored to its bottom edge, and the opening animation's background is its child
//      (extending 100 beyond it at the top and bottom), so when it does not fill the screen the buttons float above
//      the decoration bar and the main menu shows above and below the animation. So its sizeDelta is set directly to
//      the parent Canvas's size here, and verified again on every check (the game calls RefreshAspect again when settings change)
// 每 0.25 秒检查一次：新的 UI 适配器出现时游戏会重新套用设置里的比例，这时重新设置。
// Checked every 0.25 seconds: when a new UI fitter appears the game re-applies the ratio from settings, so set it again then.
// DE_ASPECT_LETTERBOX=1 关闭。
// DE_ASPECT_LETTERBOX=1 disables this.
// 同时记录 AspectUtility / AspectRatioFitterUtility 的静态字段与方法偏移，便于诊断。
// Also logs the static fields and method offsets of AspectUtility / AspectRatioFitterUtility, for diagnostics.

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern "C" {
void* il2cpp_domain_get();
void** il2cpp_domain_get_assemblies(void* domain, size_t* size);
void* il2cpp_assembly_get_image(void* assembly);
void* il2cpp_class_from_name(void* image, const char* ns, const char* name);
void* il2cpp_class_get_fields(void* klass, void** iter);
const char* il2cpp_field_get_name(void* field);
int il2cpp_field_get_flags(void* field);
void* il2cpp_field_get_type(void* field);
int il2cpp_type_get_type(void* type);
void il2cpp_field_static_get_value(void* field, void* value);
void il2cpp_field_static_set_value(void* field, void* value);
void* il2cpp_class_get_methods(void* klass, void** iter);
const char* il2cpp_method_get_name(void* method);
uint32_t il2cpp_method_get_param_count(void* method);
void* il2cpp_runtime_invoke(void* method, void* obj, void** params, void** exc);
void* il2cpp_resolve_icall(const char* name);
void* il2cpp_class_get_field_from_name(void* klass, const char* name);
void il2cpp_field_get_value(void* obj, void* field, void* value);
void* il2cpp_object_get_class(void* obj);
void* il2cpp_class_get_method_from_name(void* klass, const char* name, int argsCount);
void* il2cpp_class_get_parent(void* klass);
void* il2cpp_object_unbox(void* obj);
void* il2cpp_type_get_object(void* type);
void* il2cpp_class_get_type(void* klass);
uint32_t il2cpp_array_length(void* array);
}

namespace
{
    const int kFieldStatic = 0x0010;
    enum { kTypeBool = 0x02, kTypeI4 = 0x08, kTypeR4 = 0x0c, kTypeValueType = 0x11 };

    void* gClass;
    void* gWantedField;
    void* gSetAllCameras;
    void* gFitterUtilClass;
    void* gRegistryField;   // static List<AspectRatioFitterUtility>
    void* gFitterField;     // UnityEngine.UI.AspectRatioFitter fitter
    bool gDumped;
    int32_t (*ScreenWidth)();
    int32_t (*ScreenHeight)();

    void* FindClass(const char* ns, const char* name)
    {
        size_t count = 0;
        void** assemblies = il2cpp_domain_get_assemblies(il2cpp_domain_get(), &count);
        for (size_t i = 0; i < count; ++i)
            if (void* k = il2cpp_class_from_name(il2cpp_assembly_get_image(assemblies[i]), ns, name))
                return k;
        return nullptr;
    }

    void Dump(void* klass, const char* className)
    {
        if (!klass) return;
        printf("[DEPort] %s static fields (screen %dx%d):\n", className, ScreenWidth(), ScreenHeight());
        void* iter = nullptr;
        while (void* f = il2cpp_class_get_fields(klass, &iter))
        {
            if (!(il2cpp_field_get_flags(f) & kFieldStatic)) continue;
            const char* name = il2cpp_field_get_name(f);
            const int type = il2cpp_type_get_type(il2cpp_field_get_type(f));
            uint64_t raw = 0;
            il2cpp_field_static_get_value(f, &raw);
            if (type == kTypeR4)
            {
                float v; memcpy(&v, &raw, 4);
                printf("[DEPort]   %s : float = %f\n", name, v);
            }
            else if (type == kTypeI4 || type == kTypeValueType || type == kTypeBool)
                printf("[DEPort]   %s : type 0x%x = %d\n", name, type, (int32_t)raw);
            else
                printf("[DEPort]   %s : type 0x%x = %p\n", name, type, (void*)raw);
        }
        iter = nullptr;
        while (void* m = il2cpp_class_get_methods(klass, &iter))
        {
            void* code = *(void**)m;  // MethodInfo::methodPointer
            Dl_info info = {};
            dladdr(code, &info);
            printf("[DEPort]   method %s(%u) at GameAssembly+0x%lx\n", il2cpp_method_get_name(m),
                   il2cpp_method_get_param_count(m), (unsigned long)((uintptr_t)code - (uintptr_t)info.dli_fbase));
        }
    }

    // 沿继承链查找并调用实例方法（例如 Behaviour.set_enabled），异常时返回 false
    // Look up an instance method along the inheritance chain and invoke it (e.g. Behaviour.set_enabled); returns false on an exception
    bool Invoke(void* obj, const char* name, void** args, int argc, void** result = nullptr)
    {
        for (void* k = il2cpp_object_get_class(obj); k; k = il2cpp_class_get_parent(k))
        {
            if (void* m = il2cpp_class_get_method_from_name(k, name, argc))
            {
                void* exc = nullptr;
                void* r = il2cpp_runtime_invoke(m, obj, args, &exc);
                if (result) *result = r;
                return exc == nullptr;
            }
        }
        return false;
    }

    // List<T> 的内部字段；Il2CppArray 的元素从偏移 0x20 开始（64 位）
    // Internal fields of List<T>; Il2CppArray elements start at offset 0x20 (64-bit)
    void FillUIFitters(float aspect)
    {
        if (!gRegistryField || !gFitterField) return;
        void* list = nullptr;
        il2cpp_field_static_get_value(gRegistryField, &list);
        if (!list) return;
        void* listClass = il2cpp_object_get_class(list);
        void* itemsField = il2cpp_class_get_field_from_name(listClass, "_items");
        void* sizeField = il2cpp_class_get_field_from_name(listClass, "_size");
        if (!itemsField || !sizeField) return;
        void* items = nullptr;
        int32_t size = 0;
        il2cpp_field_get_value(list, itemsField, &items);
        il2cpp_field_get_value(list, sizeField, &size);
        if (!items) return;

        void** elements = (void**)((char*)items + 0x20);
        int updated = 0;
        for (int32_t i = 0; i < size; ++i)
        {
            void* util = elements[i];
            if (!util) continue;
            void* fitter = nullptr;
            il2cpp_field_get_value(util, gFitterField, &fitter);
            if (!fitter) continue;
            // 已销毁的组件会抛异常，跳过即可
            // Destroyed components throw an exception; just skip them
            float value = aspect;
            void* ratioArgs[1] = { &value };
            if (!Invoke(fitter, "set_aspectRatio", ratioArgs, 1)) continue;

            void* boxed = nullptr;
            const bool enabled = Invoke(fitter, "get_enabled", nullptr, 0, &boxed) && boxed && *(bool*)il2cpp_object_unbox(boxed);
            if (!enabled)
            {
                bool on = true, off = false;
                void* onArgs[1] = { &on };
                void* offArgs[1] = { &off };
                Invoke(fitter, "set_enabled", onArgs, 1);   // OnEnable 会按新比例立即重算布局 | OnEnable immediately recalculates the layout with the new ratio
                Invoke(fitter, "set_enabled", offArgs, 1);  // 恢复游戏原来的状态 | restore the game's original state
            }
            ++updated;
        }
        printf("[DEPort] aspect: %d UI fitters -> %f\n", updated, aspect);
    }

    struct Rect { float x, y, w, h; };

    struct Vec2 { float x, y; };

    bool GetRect(void* transform, Rect* out)
    {
        void* boxed = nullptr;
        if (!transform || !Invoke(transform, "get_rect", nullptr, 0, &boxed) || !boxed) return false;
        *out = *(Rect*)il2cpp_object_unbox(boxed);
        return true;
    }

    // GlobalUIFitter 的单例存放在它自己的静态字段里
    // The GlobalUIFitter singleton is stored in one of its own static fields
    void* GlobalUIFitterInstance()
    {
        static void* klass = FindClass("", "GlobalUIFitter");
        if (!klass) return nullptr;
        void* iter = nullptr;
        while (void* f = il2cpp_class_get_fields(klass, &iter))
        {
            if (!(il2cpp_field_get_flags(f) & kFieldStatic)) continue;
            void* value = nullptr;
            il2cpp_field_static_get_value(f, &value);
            if (value && il2cpp_object_get_class(value) == klass) return value;
        }
        return nullptr;
    }

    void FixGlobalUIFitter()
    {
        void* fitter = GlobalUIFitterInstance();
        void* transform = nullptr;
        void* parent = nullptr;
        if (!fitter || !Invoke(fitter, "get_transform", nullptr, 0, &transform) || !transform) return;
        if (!Invoke(transform, "get_parent", nullptr, 0, &parent) || !parent) return;
        Rect mine, canvas;
        if (!GetRect(transform, &mine) || !GetRect(parent, &canvas)) return;
        if (fabsf(mine.w - canvas.w) < 1 && fabsf(mine.h - canvas.h) < 1) return;
        Vec2 size = { canvas.w, canvas.h };
        void* args[1] = { &size };
        if (Invoke(transform, "set_sizeDelta", args, 1))
            printf("[DEPort] aspect: Global UI Fitter %.0fx%.0f -> %.0fx%.0f\n", mine.w, mine.h, size.x, size.y);
    }

    void Tick()
    {
        if (!gClass)
        {
            gClass = FindClass("", "AspectUtility");
            if (!gClass) return;
            void* iter = nullptr;
            while (void* f = il2cpp_class_get_fields(gClass, &iter))
                if (strcmp(il2cpp_field_get_name(f), "wantedAspectRatio") == 0 && (il2cpp_field_get_flags(f) & kFieldStatic)
                    && il2cpp_type_get_type(il2cpp_field_get_type(f)) == kTypeR4)
                    gWantedField = f;
            iter = nullptr;
            while (void* m = il2cpp_class_get_methods(gClass, &iter))
                if (strcmp(il2cpp_method_get_name(m), "SetAllCameras") == 0 && il2cpp_method_get_param_count(m) == 1)
                    gSetAllCameras = m;
            gFitterUtilClass = FindClass("", "AspectRatioFitterUtility");
            if (gFitterUtilClass)
            {
                gRegistryField = il2cpp_class_get_field_from_name(gFitterUtilClass, "registry");
                gFitterField = il2cpp_class_get_field_from_name(gFitterUtilClass, "fitter");
            }
            printf("[DEPort] AspectUtility found (static wantedAspectRatio=%d, SetAllCameras(int)=%d, UI registry=%d, fitter=%d)\n",
                   gWantedField != nullptr, gSetAllCameras != nullptr, gRegistryField != nullptr, gFitterField != nullptr);
        }

        float wanted = 0;
        if (gWantedField) il2cpp_field_static_get_value(gWantedField, &wanted);
        if (!gDumped && wanted > 0)
        {
            gDumped = true;
            Dump(gClass, "AspectUtility");
            Dump(FindClass("", "AspectRatioFitterUtility"), "AspectRatioFitterUtility");
        }

        if (getenv("DE_ASPECT_LETTERBOX") || !gWantedField || !gSetAllCameras || wanted <= 0) return;
        FixGlobalUIFitter();
        const float screen = (float)ScreenWidth() / (float)ScreenHeight();
        if (fabsf(wanted - screen) < 0.001f) return;
        il2cpp_field_static_set_value(gWantedField, (void*)&screen);
        int32_t keepWanted = 3;  // Ratio_4x3：SetAllCameras 不会改写 wantedAspectRatio | Ratio_4x3: SetAllCameras does not overwrite wantedAspectRatio
        void* args[1] = { &keepWanted };
        void* exc = nullptr;
        il2cpp_runtime_invoke(gSetAllCameras, nullptr, args, &exc);
        printf("[DEPort] aspect: wantedAspectRatio %f -> %f%s\n", wanted, screen, exc ? " (SetAllCameras threw)" : "");
        FillUIFitters(screen);
    }
}

extern "C" void DEAspectStart(void)
{
    ScreenWidth = (int32_t (*)())il2cpp_resolve_icall("UnityEngine.Screen::get_width");
    ScreenHeight = (int32_t (*)())il2cpp_resolve_icall("UnityEngine.Screen::get_height");
    if (!ScreenWidth || !ScreenHeight) return;
    // 等游戏完成初始化后再开始检查，之后每 0.25 秒一次（只读一个静态 float，开销很小）
    // Start checking only after the game has finished initializing, then every 0.25 seconds
    // (it only reads a static float, so the cost is tiny)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval: 0.25 repeats: YES block: ^(NSTimer* t) { Tick(); }];
    });
}
