// UI 布局诊断（调试用）：设置环境变量 DE_UI_DIAG="秒,秒,…" 时，在这些时间点通过 il2cpp 调用
// Unity 的托管接口，记录屏幕与安全区、所有相机、所有 Canvas、所有 AspectRatioFitter，
// 以及游戏 Overscan 相关类的静态字段。用于排查界面被限制在某个区域内的原因。
// UI layout diagnostics (for debugging): when the environment variable DE_UI_DIAG="sec,sec,..." is set, at those
// points in time it calls Unity's managed APIs via il2cpp and logs the screen and safe area, all cameras, all
// Canvases, all AspectRatioFitters, and the static fields of the game's Overscan-related classes.
// Used to find out why the UI is confined to a particular region.

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <string>

extern "C" {
void* il2cpp_domain_get();
void** il2cpp_domain_get_assemblies(void* domain, size_t* size);
void* il2cpp_assembly_get_image(void* assembly);
void* il2cpp_class_from_name(void* image, const char* ns, const char* name);
void* il2cpp_class_get_method_from_name(void* klass, const char* name, int argsCount);
void* il2cpp_class_get_parent(void* klass);
void* il2cpp_runtime_invoke(void* method, void* obj, void** params, void** exc);
void* il2cpp_object_unbox(void* obj);
void* il2cpp_object_get_class(void* obj);
void* il2cpp_type_get_object(void* type);
void* il2cpp_class_get_type(void* klass);
uint32_t il2cpp_array_length(void* array);
const char* il2cpp_class_get_name(void* klass);
const char* il2cpp_class_get_namespace(void* klass);
void* il2cpp_class_get_methods(void* klass, void** iter);
const char* il2cpp_method_get_name(void* method);
uint32_t il2cpp_method_get_param_count(void* method);
const uint16_t* il2cpp_string_chars(void* str);
int32_t il2cpp_string_length(void* str);
void* il2cpp_class_get_fields(void* klass, void** iter);
const char* il2cpp_field_get_name(void* field);
int il2cpp_field_get_flags(void* field);
void* il2cpp_field_get_type(void* field);
int il2cpp_type_get_type(void* type);
void il2cpp_field_static_get_value(void* field, void* value);
}

namespace
{
    struct Rect { float x, y, w, h; };
    struct Vec2 { float x, y; };

    void* FindClass(const char* ns, const char* name)
    {
        size_t count = 0;
        void** assemblies = il2cpp_domain_get_assemblies(il2cpp_domain_get(), &count);
        for (size_t i = 0; i < count; ++i)
            if (void* k = il2cpp_class_from_name(il2cpp_assembly_get_image(assemblies[i]), ns, name))
                return k;
        return nullptr;
    }

    // 沿继承链查找方法（例如 Camera 上的 Behaviour.get_enabled）
    // Look up a method along the inheritance chain (e.g. Behaviour.get_enabled on a Camera)
    void* Method(void* klass, const char* name, int argc)
    {
        for (void* k = klass; k; k = il2cpp_class_get_parent(k))
            if (void* m = il2cpp_class_get_method_from_name(k, name, argc))
                return m;
        return nullptr;
    }

    void* Call(void* obj, const char* name, void** args = nullptr, int argc = 0, void* klass = nullptr)
    {
        void* m = Method(klass ? klass : il2cpp_object_get_class(obj), name, argc);
        if (!m) return nullptr;
        void* exc = nullptr;
        void* r = il2cpp_runtime_invoke(m, klass ? nullptr : obj, args, &exc);
        return exc ? nullptr : r;
    }

    template <typename T>
    T Get(void* obj, const char* name, T fallback = T())
    {
        void* boxed = Call(obj, name);
        return boxed ? *(T*)il2cpp_object_unbox(boxed) : fallback;
    }

    std::string Str(void* s)
    {
        std::string out;
        if (!s) return "(null)";
        const uint16_t* c = il2cpp_string_chars(s);
        for (int32_t i = 0, n = il2cpp_string_length(s); i < n; ++i)
            out += c[i] < 128 ? (char)c[i] : '?';
        return out;
    }

    std::string Name(void* obj) { return obj ? Str(Call(obj, "get_name")) : "(null)"; }

    void* FindObjects(const char* ns, const char* name)
    {
        void* klass = FindClass(ns, name);
        void* objectClass = FindClass("UnityEngine", "Object");
        if (!klass || !objectClass) return nullptr;
        void* type = il2cpp_type_get_object(il2cpp_class_get_type(klass));
        void* args[1] = { type };
        return Call(nullptr, "FindObjectsOfType", args, 1, objectClass);
    }

    template <typename F>
    void ForEach(void* array, F f)
    {
        if (!array) return;
        void** items = (void**)((char*)array + 0x20);
        for (uint32_t i = 0, n = il2cpp_array_length(array); i < n; ++i)
            if (items[i]) f(items[i]);
    }

    // 对关心的游戏脚本类，打印命名空间与全部方法（参数个数、在 GameAssembly 中的偏移）
    // For game script classes of interest, print the namespace and all methods (parameter count, offset in GameAssembly)
    void DescribeClassOnce(void* klass)
    {
        static std::string seen;
        const std::string name = il2cpp_class_get_name(klass);
        if (seen.find("|" + name + "|") != std::string::npos) return;
        seen += "|" + name + "|";
        printf("[DEPort] class %s.%s methods:\n", il2cpp_class_get_namespace(klass), name.c_str());
        void* iter = nullptr;
        while (void* m = il2cpp_class_get_methods(klass, &iter))
        {
            Dl_info info = {};
            void* code = *(void**)m;
            dladdr(code, &info);
            printf("[DEPort]   %s(%u) +0x%lx\n", il2cpp_method_get_name(m), il2cpp_method_get_param_count(m),
                   (unsigned long)((uintptr_t)code - (uintptr_t)info.dli_fbase));
        }
    }

    bool Interesting(const char* cn)
    {
        return strstr(cn, "Fitter") || strstr(cn, "Intro") || strstr(cn, "Cutscene") || strstr(cn, "Aspect") || strstr(cn, "Splash");
    }

    // 列出 RectTransform 层级：名称、是否激活、尺寸、锚点、轴心、锚定位置，以及挂载的组件
    // List the RectTransform hierarchy: name, active state, size, anchors, pivot, anchored position, and attached components
    int gTreeLines;
    void DumpTree(void* transform, int depth, int maxDepth)
    {
        if (!transform || gTreeLines > 600) return;
        void* go = Call(transform, "get_gameObject");
        Rect r = Get<Rect>(transform, "get_rect");
        Vec2 amin = Get<Vec2>(transform, "get_anchorMin"), amax = Get<Vec2>(transform, "get_anchorMax");
        Vec2 pivot = Get<Vec2>(transform, "get_pivot"), pos = Get<Vec2>(transform, "get_anchoredPosition");
        std::string comps;
        void* componentClass = FindClass("UnityEngine", "Component");
        void* typeArgs[1] = { il2cpp_type_get_object(il2cpp_class_get_type(componentClass)) };
        ForEach(go ? Call(go, "GetComponents", typeArgs, 1) : nullptr, [&](void* c) {
            const char* cn = il2cpp_class_get_name(il2cpp_object_get_class(c));
            if (strcmp(cn, "RectTransform") && strcmp(cn, "CanvasRenderer") && strcmp(cn, "Transform"))
                comps += std::string(" ") + cn;
            if (Interesting(cn)) DescribeClassOnce(il2cpp_object_get_class(c));
        });
        printf("[DEPort] tree %*s%s%s rect=%.0fx%.0f anchors=(%.2f,%.2f)-(%.2f,%.2f) pivot=(%.2f,%.2f) pos=(%.0f,%.0f) [%s ]\n",
               depth * 2, "", go && !Get<bool>(go, "get_activeSelf") ? "(off) " : "", Name(go).c_str(), r.w, r.h,
               amin.x, amin.y, amax.x, amax.y, pivot.x, pivot.y, pos.x, pos.y, comps.c_str());
        ++gTreeLines;
        if (depth >= maxDepth) return;
        const int32_t n = Get<int32_t>(transform, "get_childCount");
        if (n > 20)
        {
            printf("[DEPort] tree %*s(%d children, not expanded)\n", depth * 2 + 2, "", n);
            return;
        }
        for (int32_t i = 0; i < n; ++i)
        {
            int32_t idx = i;
            void* args[1] = { &idx };
            DumpTree(Call(transform, "GetChild", args, 1), depth + 1, maxDepth);
        }
    }

    void DumpStatics(const char* ns, const char* name)
    {
        void* klass = FindClass(ns, name);
        if (!klass) { printf("[DEPort] diag: class %s not found\n", name); return; }
        printf("[DEPort] diag: %s statics\n", name);
        void* iter = nullptr;
        while (void* f = il2cpp_class_get_fields(klass, &iter))
        {
            if (!(il2cpp_field_get_flags(f) & 0x10)) continue;
            uint64_t raw = 0;
            il2cpp_field_static_get_value(f, &raw);
            const int t = il2cpp_type_get_type(il2cpp_field_get_type(f));
            float fv; memcpy(&fv, &raw, 4);
            printf("[DEPort]   %s type=0x%x raw=0x%llx f=%g\n", il2cpp_field_get_name(f), t, (unsigned long long)raw, fv);
        }
    }

    void Run(double t)
    {
        printf("[DEPort] ===== UI diag at %.0fs =====\n", t);
        void* screen = FindClass("UnityEngine", "Screen");
        if (screen)
        {
            void* m = Method(screen, "get_safeArea", 0);
            void* exc = nullptr;
            void* boxed = m ? il2cpp_runtime_invoke(m, nullptr, nullptr, &exc) : nullptr;
            if (boxed && !exc)
            {
                Rect r = *(Rect*)il2cpp_object_unbox(boxed);
                printf("[DEPort] safeArea %.0f,%.0f %.0fx%.0f\n", r.x, r.y, r.w, r.h);
            }
        }

        void* cameraClass = FindClass("UnityEngine", "Camera");
        ForEach(cameraClass ? Call(nullptr, "get_allCameras", nullptr, 0, cameraClass) : nullptr, [](void* cam) {
            Rect r = Get<Rect>(cam, "get_rect"), p = Get<Rect>(cam, "get_pixelRect");
            printf("[DEPort] camera '%s' depth=%g rect=%.3f,%.3f %.3fx%.3f pixel=%.0f,%.0f %.0fx%.0f\n",
                   Name(cam).c_str(), Get<float>(cam, "get_depth"), r.x, r.y, r.w, r.h, p.x, p.y, p.w, p.h);
        });

        ForEach(FindObjects("UnityEngine", "Canvas"), [](void* c) {
            if (!Get<bool>(c, "get_isRootCanvas")) return;
            Rect p = Get<Rect>(c, "get_pixelRect");
            printf("[DEPort] canvas '%s' mode=%d camera='%s' order=%d scale=%g pixel=%.0f,%.0f %.0fx%.0f enabled=%d\n",
                   Name(c).c_str(), Get<int32_t>(c, "get_renderMode"), Name(Call(c, "get_worldCamera")).c_str(),
                   Get<int32_t>(c, "get_sortingOrder"), Get<float>(c, "get_scaleFactor"), p.x, p.y, p.w, p.h,
                   Get<bool>(c, "get_enabled"));
        });

        // 先转储 HUD 所在的 Global UI Canvas，再转储其他根 Canvas
        // Dump the Global UI Canvas that holds the HUD first, then the other root Canvases
        gTreeLines = 0;
        for (int pass = 0; pass < 2; ++pass)
            ForEach(FindObjects("UnityEngine", "Canvas"), [pass](void* c) {
                if (!Get<bool>(c, "get_isRootCanvas")) return;
                const bool global = Name(c).find("Global") != std::string::npos;
                if (global == (pass == 0)) DumpTree(Call(c, "get_transform"), 0, 5);
            });

        ForEach(FindObjects("UnityEngine.UI", "AspectRatioFitter"), [](void* f) {
            printf("[DEPort] fitter '%s' ratio=%g mode=%d enabled=%d\n", Name(f).c_str(),
                   Get<float>(f, "get_aspectRatio"), Get<int32_t>(f, "get_aspectMode"), Get<bool>(f, "get_enabled"));
        });

        DumpStatics("", "OverscanUtils");
        DumpStatics("", "OverscanConfigurator");
        ForEach(FindObjects("", "OverscanConfigurator"), [](void* o) {
            printf("[DEPort] OverscanConfigurator instance '%s' enabled=%d\n", Name(o).c_str(), Get<bool>(o, "get_enabled"));
        });
    }
}

extern "C" void DEUIDiagSchedule(void)
{
    const char* spec = getenv("DE_UI_DIAG");
    if (!spec) return;
    for (NSString* item in [[NSString stringWithUTF8String: spec] componentsSeparatedByString: @","])
    {
        const double t = item.doubleValue;
        if (t <= 0) continue;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(t * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ Run(t); });
    }
}
