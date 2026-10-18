# Your game files

中文: [GAME_FILES.zh-CN.md](GAME_FILES.zh-CN.md)

This repository contains no game content. Everything the iPad app runs comes from **the Mac version of Disco Elysium – The Final Cut that you bought**, converted on your own Mac.

## Which copy

| Item | Requirement | How to check |
|---|---|---|
| Store | The **macOS** version. Verified with the Steam release. The GOG Mac release has not been verified (it may be the same build) | — |
| Unity version | **2020.3.12f1** (changeset `b3b2c6512326`), exactly | `/usr/libexec/PlistBuddy -c 'Print :CFBundleGetInfoString' "<app>/Contents/Info.plist"` |
| Game build | `develop \| 6f8a0e67 \| ddb 2022-05-20 12:05 \| build 1725995648 \| Platform StandaloneOSX` | `cat "<app>/Contents/Resources/Data/StreamingAssets/build_info.txt"` |
| Architecture | Universal binaries with an **arm64** slice (the Final Cut Mac build is universal) | `lipo -archs "<app>/Contents/Frameworks/GameAssembly.dylib"` |
| Size | About 9.7 GB | — |

`./setup.sh check` performs all of these checks for you.

Another build of the game, or another Unity version, will very likely need adjustments: several steps are tied to exact Unity internals and to class names in the game code. See [PORTING_NOTES.md](PORTING_NOTES.md), section "Adapting to another build".

## Where the tools look for it

By default, the Steam install location:

```
~/Library/Application Support/Steam/steamapps/common/Disco Elysium/disco.app
```

Set `GAME_APP` in `config.env` if yours is elsewhere. The game is only ever read; nothing inside the `.app` is modified.

## What is used, and what it becomes

| From your copy | Becomes | Done by |
|---|---|---|
| `Contents/Frameworks/GameAssembly.dylib` (IL2CPP game code + runtime) | `build/Frameworks/GameAssembly.framework`: the arm64 slice, platform marker changed from macOS to iOS, system library paths fixed | `make binaries` |
| `Contents/PlugIns/AmplifyTextureNative.bundle` (virtual texture decoder) | `build/Frameworks/AmplifyTextureNative.framework`, same treatment; its OpenGL imports point to an empty stub | `make binaries` |
| The *export names* of `steam_api`, `libGalaxyCSharpGlue`, `InControlNative` | Stub libraries that return "not available" (no code is copied, only the function names are read) | `make stubs` |
| `Contents/Resources/Data/**` (about 9.6 GB) | `build/GameData/Contents/Resources/Data/**`: target platform changed from StandaloneOSX (2) to iOS (9) in every serialized file, every AssetBundle rewritten with LZ4, laid out the way the iOS player expects | `make data` |
| `Contents/Resources/PlayerIcon.icns` | The app icon | `make project` |

`build/GameData` uses APFS clones for every file that is not modified, so on the same volume it takes about 4 GB of real disk space instead of 9.6 GB. The conversion is incremental: running it again only reprocesses files whose source changed.

## Where the data goes on the iPad

The app itself is an empty shell. The converted data lives in the app's sandbox, so reinstalling or re-signing the app does not require pushing it again:

```
<app sandbox>/Documents/GameData/
    de-port.json                     format marker (the app refuses to start Unity if it does not match)
    Contents/Resources/Data/         the converted Data folder (Mac .app layout, see PORTING_NOTES.md)
```

`make push-data` copies it with `xcrun devicectl` (about 20 seconds over USB-C for a first push; later pushes send only changed files). The folder is excluded from iCloud backup. It is also visible in the Files app and in Finder's device view, because the app enables file sharing; you can delete it there to free space.

Saves are written by the game to `Documents/` as well, next to `GameData`.

## Why the Mac version

- Its game code is already compiled ahead of time to **arm64** (IL2CPP), and only depends on system libraries that also exist on iOS, so it can run on the iPad unchanged.
- It already renders with **Metal**, so its shaders work with the iOS Metal backend of the same Unity version.
- The Windows version is x86-64 only and uses Direct3D shaders; it cannot be used this way.
