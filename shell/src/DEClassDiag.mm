// 类结构诊断（调试用）：设置 DE_CLASS_DIAG="秒:名字片段,名字片段,…" 时，在启动后第几秒列出类名里含这些片段的
// 所有游戏类：字段（名称、类型、偏移，静态字段附上当前值）和方法（名称、参数个数、在 GameAssembly 里的偏移）。
// 方法偏移可以直接交给 xcrun objdump -d --start-address=… 反汇编（见 AGENTS.md "出问题时"）。
// 例：DE_CLASS_DIAG="20:Achievement,SocialPlatform"
// 成就链路测试：DE_ACH_TEST="秒:ACH_DE_名字" 在那一秒调用游戏自己的 Achievements.Set。只接受 ACH_DE_ 开头的名字：
// Steam 上没有这种成就，Mac 端会回答 unknown 并丢弃，所以整条链路（游戏 → 桩库 → 网络 → Mac 上的 Steam）都走一遍，
// 却不会解锁任何东西。
// Class structure diagnostics (for debugging): with DE_CLASS_DIAG="seconds:fragment,fragment,...", that many seconds
// after start-up it lists every game class whose name contains one of the fragments: fields (name, type, offset, and
// the current value of static fields) and methods (name, parameter count, offset inside GameAssembly).
// The method offsets can go straight to xcrun objdump -d --start-address=... (see "When something fails" in AGENTS.md).
// Example: DE_CLASS_DIAG="20:Achievement,SocialPlatform"
// Achievement path test: DE_ACH_TEST="seconds:ACH_DE_name" calls the game's own Achievements.Set at that second. Only names
// starting with ACH_DE_ are accepted: Steam has no such achievement, so the Mac answers unknown and drops it. The whole path
// (game → stub → network → Steam on the Mac) is exercised without unlocking anything.

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

extern "C" {
void* il2cpp_domain_get();
void** il2cpp_domain_get_assemblies(void* domain, size_t* size);
void* il2cpp_assembly_get_image(void* assembly);
const char* il2cpp_image_get_name(void* image);
size_t il2cpp_image_get_class_count(void* image);
void* il2cpp_image_get_class(void* image, size_t index);
const char* il2cpp_class_get_name(void* klass);
const char* il2cpp_class_get_namespace(void* klass);
void* il2cpp_class_get_parent(void* klass);
void* il2cpp_class_get_declaring_type(void* klass);
void* il2cpp_class_get_fields(void* klass, void** iter);
void* il2cpp_class_get_methods(void* klass, void** iter);
const char* il2cpp_field_get_name(void* field);
int il2cpp_field_get_flags(void* field);
void* il2cpp_field_get_type(void* field);
size_t il2cpp_field_get_offset(void* field);
void il2cpp_field_static_get_value(void* field, void* value);
char* il2cpp_type_get_name(void* type);
int il2cpp_type_get_type(void* type);
const char* il2cpp_method_get_name(void* method);
uint32_t il2cpp_method_get_param_count(void* method);
void* il2cpp_class_from_name(void* image, const char* ns, const char* name);
void* il2cpp_class_get_method_from_name(void* klass, const char* name, int argsCount);
void* il2cpp_runtime_invoke(void* method, void* obj, void** params, void** exc);
void* il2cpp_object_unbox(void* obj);
void* il2cpp_string_new(const char* str);
void il2cpp_format_exception(void* ex, char* message, int size);
void il2cpp_format_stack_trace(void* ex, char* output, int size);
}

namespace
{
    const int kFieldStatic = 0x10;  // FIELD_ATTRIBUTE_STATIC
    const int kFieldLiteral = 0x40; // FIELD_ATTRIBUTE_LITERAL（常量没有存储） | FIELD_ATTRIBUTE_LITERAL (constants have no storage)

    bool Matches(const char* name, NSArray<NSString*>* fragments)
    {
        NSString* n = [NSString stringWithUTF8String: name ?: ""];
        for (NSString* f in fragments)
            if (f.length && [n rangeOfString: f options: NSCaseInsensitiveSearch].location != NSNotFound) return true;
        return false;
    }

    void DumpClass(void* klass)
    {
        void* outer = il2cpp_class_get_declaring_type(klass);
        void* parent = il2cpp_class_get_parent(klass);
        fprintf(stderr, "[DEPort] class %s%s%s%s%s : %s\n", il2cpp_class_get_namespace(klass),
                *il2cpp_class_get_namespace(klass) ? "." : "", outer ? il2cpp_class_get_name(outer) : "", outer ? "/" : "",
                il2cpp_class_get_name(klass), parent ? il2cpp_class_get_name(parent) : "-");
        void* iter = nullptr;
        while (void* field = il2cpp_class_get_fields(klass, &iter))
        {
            const int flags = il2cpp_field_get_flags(field);
            void* type = il2cpp_field_get_type(field);
            char* typeName = il2cpp_type_get_name(type);
            if ((flags & kFieldStatic) && !(flags & kFieldLiteral))
            {
                // 只读出前 8 个字节：整数、枚举、布尔看值，引用类型看是否为空
                // Read only the first 8 bytes: the value for integers, enums and booleans; null or not for references
                uint64_t value = 0;
                il2cpp_field_static_get_value(field, &value);
                fprintf(stderr, "[DEPort]   static %s %s = 0x%llx\n", typeName, il2cpp_field_get_name(field), (unsigned long long)value);
            }
            else if (flags & kFieldLiteral)
                fprintf(stderr, "[DEPort]   const %s %s\n", typeName, il2cpp_field_get_name(field));
            else
                fprintf(stderr, "[DEPort]   field %s %s @0x%zx\n", typeName, il2cpp_field_get_name(field), il2cpp_field_get_offset(field));
        }
        iter = nullptr;
        while (void* method = il2cpp_class_get_methods(klass, &iter))
        {
            void* pointer = *(void**)method;  // MethodInfo 的第一个字段是 methodPointer | The first field of MethodInfo is methodPointer
            Dl_info info = {};
            const bool found = pointer && dladdr(pointer, &info) && info.dli_fbase;
            fprintf(stderr, "[DEPort]   method %s(%u) @%s0x%llx\n", il2cpp_method_get_name(method), il2cpp_method_get_param_count(method),
                    found ? "GameAssembly+" : "", (unsigned long long)(found ? (uintptr_t)pointer - (uintptr_t)info.dli_fbase : (uintptr_t)pointer));
        }
    }

    void Run(NSArray<NSString*>* fragments)
    {
        size_t count = 0;
        void** assemblies = il2cpp_domain_get_assemblies(il2cpp_domain_get(), &count);
        int shown = 0;
        for (size_t i = 0; i < count; ++i)
        {
            void* image = il2cpp_assembly_get_image(assemblies[i]);
            const size_t classes = il2cpp_image_get_class_count(image);
            for (size_t c = 0; c < classes && shown < 200; ++c)
            {
                void* klass = il2cpp_image_get_class(image, c);
                if (!Matches(il2cpp_class_get_name(klass), fragments)) continue;
                fprintf(stderr, "[DEPort] class diag: image %s\n", il2cpp_image_get_name(image));
                DumpClass(klass);
                ++shown;
            }
        }
        fprintf(stderr, "[DEPort] class diag: %d classes listed\n", shown);
    }

    // 调用一个全局命名空间里的静态方法并报告结果或异常 | Call a static method in the global namespace and report its result or exception
    void InvokeStatic(const char* klassName, const char* methodName, int argc, void** params)
    {
        size_t count = 0;
        void** assemblies = il2cpp_domain_get_assemblies(il2cpp_domain_get(), &count);
        for (size_t i = 0; i < count; ++i)
        {
            void* klass = il2cpp_class_from_name(il2cpp_assembly_get_image(assemblies[i]), "", klassName);
            void* method = klass ? il2cpp_class_get_method_from_name(klass, methodName, argc) : nullptr;
            if (!method) continue;
            void* exc = nullptr;
            void* ret = il2cpp_runtime_invoke(method, nullptr, params, &exc);
            char message[512] = "";
            if (exc) il2cpp_format_exception(exc, message, sizeof message);
            fprintf(stderr, "[DEPort] achievement test: %s.%s -> %s%d %s\n", klassName, methodName, ret ? "" : "(no value) ",
                    ret ? *(int32_t*)il2cpp_object_unbox(ret) : 0, message);
            return;
        }
        fprintf(stderr, "[DEPort] achievement test: %s.%s not found\n", klassName, methodName);
    }

    // 调用游戏的 Achievements.Set(string)（全局命名空间，Assembly-CSharp） | Call the game's Achievements.Set(string) (global namespace, Assembly-CSharp)
    void RunAchievementTest(NSString* name)
    {
        // 分步调用 Achievements.Set 内部用到的方法，找出是哪一步出错 | Call the steps inside Achievements.Set one by one to find the one that fails
        InvokeStatic("Achievements", "get_Platform", 0, nullptr);
        InvokeStatic("Achievements", "LogWarningIfPlatformIsNone", 0, nullptr);
        void* stepParams[1] = { il2cpp_string_new(name.UTF8String) };
        InvokeStatic("SteamAchievements", "Set", 1, stepParams);
        size_t count = 0;
        void** assemblies = il2cpp_domain_get_assemblies(il2cpp_domain_get(), &count);
        void* method = nullptr;
        for (size_t i = 0; i < count && !method; ++i)
            if (void* klass = il2cpp_class_from_name(il2cpp_assembly_get_image(assemblies[i]), "", "Achievements"))
                method = il2cpp_class_get_method_from_name(klass, "Set", 1);
        if (!method)
        {
            fprintf(stderr, "[DEPort] achievement test: Achievements.Set not found\n");
            return;
        }
        // 先看 SteamManager.Initialized：游戏的 SteamAchievements.Set 只在它为真时调用 Steam
        // Check SteamManager.Initialized first: the game's SteamAchievements.Set calls Steam only when it is true
        for (size_t i = 0; i < count; ++i)
            if (void* klass = il2cpp_class_from_name(il2cpp_assembly_get_image(assemblies[i]), "", "SteamManager"))
                if (void* getter = il2cpp_class_get_method_from_name(klass, "get_Initialized", 0))
                {
                    void* e = nullptr;
                    void* r = il2cpp_runtime_invoke(getter, nullptr, nullptr, &e);
                    fprintf(stderr, "[DEPort] achievement test: SteamManager.Initialized = %d%s\n", r ? *(bool*)il2cpp_object_unbox(r) : -1, e ? " (exception)" : "");
                    break;
                }
        void* params[1] = { il2cpp_string_new(name.UTF8String) };
        void* exc = nullptr;
        void* ret = il2cpp_runtime_invoke(method, nullptr, params, &exc);
        const bool ok = ret && *(bool*)il2cpp_object_unbox(ret);
        fprintf(stderr, "[DEPort] achievement test: Achievements.Set(%s) returned %d%s\n", name.UTF8String, ok, exc ? " (exception)" : "");
        if (exc)
        {
            char message[512] = "", trace[2048] = "";
            il2cpp_format_exception(exc, message, sizeof message);
            il2cpp_format_stack_trace(exc, trace, sizeof trace);
            fprintf(stderr, "[DEPort] achievement test: %s\n%s\n", message, trace);
        }
    }
}

static void DEAchievementTestSchedule(void)
{
    const char* spec = getenv("DE_ACH_TEST");
    if (!spec) return;
    NSArray<NSString*>* parts = [[NSString stringWithUTF8String: spec] componentsSeparatedByString: @":"];
    NSString* name = parts.lastObject;
    if (parts.count != 2 || ![name hasPrefix: @"ACH_DE_"])
    {
        fprintf(stderr, "[DEPort] achievement test: DE_ACH_TEST must look like 30:ACH_DE_TEST (names must start with ACH_DE_)\n");
        return;
    }
    const double t = parts.firstObject.doubleValue;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(t * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ RunAchievementTest(name); });
}

extern "C" void DEClassDiagSchedule(void)
{
    DEAchievementTestSchedule();
    const char* spec = getenv("DE_CLASS_DIAG");
    if (!spec) return;
    NSString* s = [NSString stringWithUTF8String: spec];
    NSRange colon = [s rangeOfString: @":"];
    const double t = colon.location == NSNotFound ? 20 : [s substringToIndex: colon.location].doubleValue;
    NSArray<NSString*>* fragments = [(colon.location == NSNotFound ? s : [s substringFromIndex: colon.location + 1]) componentsSeparatedByString: @","];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(t * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ Run(fragments); });
}
