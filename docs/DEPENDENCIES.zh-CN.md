# 依赖

English: [DEPENDENCIES.md](DEPENDENCIES.md)

## 你自己准备的

| 什么 | 用途 | 说明 |
|---|---|---|
| Apple 芯片的 Mac | 构建、转换数据、安装 | 在 M5 Mac、macOS 27.2 上测试。建议至少有 20 GB 可用磁盘空间 |
| 你自己的 Mac 版游戏 | 全部游戏代码与数据 | 见 [GAME_FILES.zh-CN.md](GAME_FILES.zh-CN.md)。仓库里没有任何游戏文件 |
| Apple 开发者账号 | 签名并安装到你自己的 iPad | **付费账号**（已测试）。App 申请了"提高内存上限"和"扩展虚拟寻址"两项权限，免费的个人团队可能无法签这两项；免费账号未测试。第一次运行 `make build` 时，Xcode 自动签名会注册你的 Bundle ID 并生成描述文件 |
| Mac 版 Steam（只有可选的成就同步需要） | 提交你的成就 | 登录拥有这款游戏的账号。见 [ACHIEVEMENTS.zh-CN.md](ACHIEVEMENTS.zh-CN.md) |
| M 系列芯片的 iPad | 运行游戏 | 在 iPad Pro 11 英寸（M5）、iPadOS 27.2 上测试。游戏纹理是 BC 压缩格式，M 系列 GPU 能硬件解码；A 系列 iPad 会退回 CPU 解压（内存占用高得多，未测试）。游戏中内存占用约 5.8 GB |

## 构建工具

| 工具 | 测试版本 | 用途 | 获取方式 |
|---|---|---|---|
| Xcode（含 iOS SDK） | 27.2（27B5019j），iOS SDK 27.2 | 编译、链接（Unity 播放器库是带嵌入 LLVM bitcode 的原生代码；BC 补丁从这份 bitcode 重新编译其中一个对象文件）、签名，以及 `devicectl`、`vtool`、`segedit`、`lipo`、`install_name_tool`、`ar`、`ranlib`、`objdump` | App Store 或 <https://developer.apple.com/xcode/> |
| XcodeGen | 2.46.0 | 根据 `scripts/gen_project.sh` 写出的 `project.yml` 生成 Xcode 工程 | `brew install xcodegen` · <https://github.com/yonaskolb/XcodeGen> |
| Python 3 | 3.15.0（较新的 3.x 应该都可以） | 数据转换、补丁工具、桩库与注册代码生成。**只用标准库**；LZ4 来自 macOS 自带的 `libcompression` | macOS 自带，或 `brew install python` |
| Apple 自带的 Python（`/usr/bin/python3`） | 3.9.6 | Steam 成就转发服务（`tools/steam_relay.py`）。它有 Apple 签名，macOS 防火墙会直接允许它接受 iPad 的连接，不弹提示 | 随 Xcode / Command Line Tools 提供 |
| Homebrew | — | 安装 XcodeGen | <https://brew.sh> |
| macOS 自带工具 | — | `curl`、`pkgutil`、`sips`、`codesign`、`security`、`perl`、`PlistBuddy` | macOS 自带 |

## 构建时下载的

| 什么 | 版本 | 大小 | 校验 | 用途 |
|---|---|---|---|---|
| Unity iOS Support for Editor（`UnitySetup-iOS-Support-for-Editor-2020.3.12f1.pkg`） | 2020.3.12f1，changeset `b3b2c6512326` | 555,542,528 字节 | SHA-256 `33c739fcc638836333cfd83210b50103e206f6ff806a53f497bb33c1fecbfe55` | iOS 播放器静态库（`libiPhone-lib-il2cpp.a`）、`baselib.a`、Trampoline（iOS App 启动代码）和 iOS 内置资源 |

`scripts/fetch_unity_ios.sh` 从 Unity 官方 CDN 下载：

```
https://download.unity3d.com/download_unity/b3b2c6512326/MacEditorTargetInstaller/UnitySetup-iOS-Support-for-Editor-2020.3.12f1.pkg
```

只解包（`pkgutil --expand-full`），不安装，也不需要 Unity 编辑器和 Unity 账号。这个包受 Unity 自己的条款约束；它由每个用户自己下载，本仓库从不分发（`vendor/` 已被 git 忽略）。

## 仓库里的第三方代码

没有。仓库里的每个源文件都是为本项目编写的。桩库在构建时根据你自己游戏副本的导出函数名生成。
