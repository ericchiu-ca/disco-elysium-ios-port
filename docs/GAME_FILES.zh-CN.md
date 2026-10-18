# 你的游戏文件

English: [GAME_FILES.md](GAME_FILES.md)

本仓库不含任何游戏内容。iPad 上运行的一切都来自**你自己购买的《极乐迪斯科：最终剪辑版》Mac 版**，在你自己的 Mac 上转换而来。

## 需要哪一份

| 项目 | 要求 | 怎么查 |
|---|---|---|
| 商店 | **macOS** 版。已用 Steam 版验证；GOG 的 Mac 版未验证（可能是同一个构建） | — |
| Unity 版本 | 必须正好是 **2020.3.12f1**（changeset `b3b2c6512326`） | `/usr/libexec/PlistBuddy -c 'Print :CFBundleGetInfoString' "<app>/Contents/Info.plist"` |
| 游戏构建 | `develop \| 6f8a0e67 \| ddb 2022-05-20 12:05 \| build 1725995648 \| Platform StandaloneOSX` | `cat "<app>/Contents/Resources/Data/StreamingAssets/build_info.txt"` |
| 架构 | 含 **arm64** 的通用二进制（最终剪辑版的 Mac 版就是通用二进制） | `lipo -archs "<app>/Contents/Frameworks/GameAssembly.dylib"` |
| 大小 | 约 9.7 GB | — |

`./setup.sh check` 会替你把这几项都查一遍。

换一个游戏构建、或者换一个 Unity 版本，大概率需要调整：好几个步骤绑定了 Unity 内部的确切细节和游戏代码里的类名。见 [PORTING_NOTES.zh-CN.md](PORTING_NOTES.zh-CN.md) 的"适配其他构建"一节。

## 工具去哪里找它

默认是 Steam 的安装位置：

```
~/Library/Application Support/Steam/steamapps/common/Disco Elysium/disco.app
```

装在别处就在 `config.env` 里设置 `GAME_APP`。工具只读取游戏，从不修改 `.app` 里的任何东西。

## 用到了哪些部分，变成了什么

| 你的副本里的 | 变成 | 由谁完成 |
|---|---|---|
| `Contents/Frameworks/GameAssembly.dylib`（IL2CPP 游戏代码 + 运行时） | `build/Frameworks/GameAssembly.framework`：取 arm64 部分，平台标记从 macOS 改为 iOS，修正系统库路径 | `make binaries` |
| `Contents/PlugIns/AmplifyTextureNative.bundle`（虚拟纹理解码） | `build/Frameworks/AmplifyTextureNative.framework`，同样处理；它引用的 OpenGL 函数指向一个空桩库 | `make binaries` |
| `steam_api`、`libGalaxyCSharpGlue`、`InControlNative` 的**导出函数名** | 一律返回"不可用"的桩库（不复制任何代码，只读取函数名） | `make stubs` |
| `Contents/Resources/Data/**`（约 9.6 GB） | `build/GameData/Contents/Resources/Data/**`：每个序列化文件的目标平台从 StandaloneOSX(2) 改为 iOS(9)，每个 AssetBundle 用 LZ4 重写，目录按 iOS 播放器的要求排布 | `make data` |
| `Contents/Resources/PlayerIcon.icns` | App 图标 | `make project` |

`build/GameData` 里没有改动的文件都是 APFS 克隆，同一个卷上实际只占约 4 GB，而不是 9.6 GB。转换是增量的：再跑一次只会重新处理源文件有变化的部分。

## 数据放在 iPad 的哪里

App 本身只是一个空壳。转换后的数据放在 App 的沙盒里，所以重装或重新签名 App 都不需要再推送一次数据：

```
<App 沙盒>/Documents/GameData/
    de-port.json                     格式标记（与 App 不一致时不会启动 Unity）
    Contents/Resources/Data/         转换后的 Data 目录（Mac .app 的目录结构，原因见 PORTING_NOTES.zh-CN.md）
```

`make push-data` 用 `xcrun devicectl` 推送（首次通过 USB-C 约 20 秒，之后只传有变化的文件，约 1 秒）。它只写 `Documents/GameData`，不动 `Documents/` 里的其他内容。这个目录已设置为不参与 iCloud 备份。由于 App 开启了文件共享，它在"文件"App 和 Finder 的设备页面里也能看到，需要释放空间时可以在那里删除。

游戏存档写在 `Documents/SaveGames` 里，和 `GameData` 并列。重装 App 不会丢存档（实测）。存档只在 iPad 上，想备份的话用"文件"App 或 Finder 把这个目录拷出来。

## 为什么用 Mac 版

- 它的游戏代码已经提前编译成 **arm64**（IL2CPP），而且只依赖 iOS 上同样存在的系统库，可以原样在 iPad 上运行。
- 它本来就用 **Metal** 渲染，着色器可以直接配合同版本 Unity 的 iOS Metal 后端使用。
- Windows 版只有 x86-64，着色器是 Direct3D 的，没法这样用。
