# 仓库里与游戏、Unity 相关的内容：有什么、没有什么、为什么

English: [DERIVED.md](DERIVED.md)

## 仓库里没有的

- **没有任何游戏内容**：没有游戏程序、脚本、数据、美术、文字、音频、着色器、存档或截图。`build/` 下的一切（改标后的二进制、转换后的数据、生成的工程、设备日志与截图）都由你自己的副本在你的电脑上生成，并且被 git 忽略。
- **没有 Unity 的二进制或源码文件**：iOS 播放器库、`baselib.a`、Trampoline 和内置资源由每个用户自己从 Unity 的 CDN 下载到 `vendor/`，该目录被 git 忽略。
- **没有从游戏原生插件复制的代码**：桩库在构建时根据你自己副本的*导出函数名*生成。

## 仓库里有的

只有与你自己的副本、以及你下载的 Unity 运行时对接所必需的名称、数值和简短锚点：

| 位置 | 是什么 | 为什么必须在这里 |
|---|---|---|
| `tools/patch_trampoline.py` | Unity Trampoline 源码中的三处简短锚点：`UnityDataBundleDir()` 的开头几行、`Preprocessor.h` 里的两行 `#define`、`UnityAppController.mm` 里的一行 `#include` | 每个补丁都只替换或扩展这段文字；锚点用来证明改的是正确 Unity 版本里的正确位置（对不上时工具直接停下） |
| `tools/patch_player_lib.py` | Unity `TextureFormatMetal.o` 中六个函数的修饰名，以及该对象 LLVM IR 里的一个基本块标签、一个 `phi` 模式和 `GraphicsCaps` 的一个字段编号 | 用来定位硬件 BC 纹理补丁的修改点；对不上时工具直接停下 |
| `tools/gen_registration.py` | Unity 模块与 icall 注册函数的命名规律（`RegisterModule_*`、`Register_UnityEngine_*`） | 具体的清单在构建时从你下载的库里读取 |
| `shell/src/DEICallOverrides.mm`、`DEVirtualInput.mm`、`DEOrientation.mm`、`DEAspect.mm` | Unity 内部调用（icall）绑定的名称，例如 `UnityEngine.Application::get_platform`、`UnityEngine.Input::GetKeyInt`、`UnityEngine.Screen::RequestOrientation` | 移植替换或调用的正是这些绑定 |
| `shell/src/DEMetalBC.mm` | Unity `GraphicsFormat` 中 DXT / BC 格式的数值（96–109）、对应的 Metal 像素格式，以及启动自检用到的三个 Unity 辅助函数的修饰名 | 映射这些格式就是 BC 补丁的全部意义；数值对不上时自检会拒绝启用 |
| `shell/src/DEAspect.mm` | 游戏代码里的类和成员名：`AspectUtility`（`wantedAspectRatio`、`SetAllCameras`）、`AspectRatioFitterUtility`（`registry`、`fitter`）、`GlobalUIFitter`，以及调用 `SetAllCameras` 时用的枚举值 | 铺满屏幕的修复通过 il2cpp 反射设置这些字段、调用这些方法。它们的行为是反汇编自己的副本得知的，只在注释和 [PORTING_NOTES.zh-CN.md](PORTING_NOTES.zh-CN.md) 里用文字描述，没有复制任何代码 |
| `shell/src/DEVirtualInput.h` | 几个 `UnityEngine.KeyCode` 数值（Tab、Escape、I、J、C、T、M） | 屏幕上的高亮按钮和自动化接口发送的就是这些键 |
| `shell/src/DEBootstrap.mm` | 游戏原生插件的名称（`steam_api`、`GalaxyCSharpGlue`、`InControlNative`、`AmplifyTextureNative`）和 Mono 使用的 Mac 版 CFNetwork 路径 | 游戏查找原生库时，要把它们重定向到 App 内的 framework |
| `shell/stubs/steam_api_overrides.c` | 四个公开的 Steamworks 函数名及其签名 | 它们必须明确报告"Steam 不可用"（其中一个用 0 表示成功，通用的"返回 0"桩会出错） |
| `config.example.env`、`docs/` | Unity 版本、changeset 和 Unity 官方包的 SHA-256；游戏的构建字符串 | 用来下载并校验正确的运行时，并告诉用户支持哪一份游戏 |

如果你加入了这类内容，请在同一次改动里把它列到这里（中英文都要）。
