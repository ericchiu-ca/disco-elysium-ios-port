# Dependencies

中文: [DEPENDENCIES.zh-CN.md](DEPENDENCIES.zh-CN.md)

## What you bring yourself

| What | Used for | Notes |
|---|---|---|
| An Apple silicon Mac | Building, converting the data, installing | Tested on an M5 Mac with macOS 27.2. About 20 GB of free disk space is recommended |
| Your own Mac copy of the game | All game code and data | See [GAME_FILES.md](GAME_FILES.md). The repository contains no game files |
| An Apple developer account | Signing the app and installing it on your own iPad | **Paid account** (tested). The app requests the *Increased Memory Limit* and *Extended Virtual Addressing* entitlements, which a free personal team may not be able to sign; a free account is untested. Xcode automatic signing registers your bundle ID and creates the provisioning profile the first time `make build` runs |
| An iPad with an M-series chip | Running the game | Tested on iPad Pro 11-inch (M5), iPadOS 27.2. The game textures are BC-compressed: M-series GPUs decode them in hardware. A-series iPads would fall back to CPU decompression (much more memory; untested). In game the app uses about 5.8 GB of memory |

## Build tools

| Tool | Version tested | Used for | Where to get it |
|---|---|---|---|
| Xcode (with the iOS SDK) | 27.2 (27B5019j), iOS SDK 27.2 | Compiling, linking (the Unity player library is native code with embedded LLVM bitcode; the BC patch recompiles one object from that bitcode), signing, `devicectl`, `vtool`, `segedit`, `lipo`, `install_name_tool`, `ar`, `ranlib`, `objdump` | App Store or <https://developer.apple.com/xcode/> |
| XcodeGen | 2.46.0 | Generating the Xcode project from the `project.yml` written by `scripts/gen_project.sh` | `brew install xcodegen` · <https://github.com/yonaskolb/XcodeGen> |
| Python 3 | 3.15.0 (any recent 3.x should work) | Data conversion, patch tools, stub and registration generators. **Standard library only**; LZ4 comes from macOS's `libcompression` | Ships with macOS, or `brew install python` |
| Homebrew | — | Installing XcodeGen | <https://brew.sh> |
| macOS built-ins | — | `curl`, `pkgutil`, `sips`, `codesign`, `security`, `perl`, `PlistBuddy` | Part of macOS |

## Downloaded at build time

| What | Version | Size | Integrity | Used for |
|---|---|---|---|---|
| Unity iOS Support for Editor (`UnitySetup-iOS-Support-for-Editor-2020.3.12f1.pkg`) | 2020.3.12f1, changeset `b3b2c6512326` | 555,542,528 bytes | SHA-256 `33c739fcc638836333cfd83210b50103e206f6ff806a53f497bb33c1fecbfe55` | The iOS player static library (`libiPhone-lib-il2cpp.a`), `baselib.a`, the Trampoline (iOS app startup code) and the iOS built-in resources |

`scripts/fetch_unity_ios.sh` downloads it from Unity's official CDN:

```
https://download.unity3d.com/download_unity/b3b2c6512326/MacEditorTargetInstaller/UnitySetup-iOS-Support-for-Editor-2020.3.12f1.pkg
```

It is only unpacked (`pkgutil --expand-full`), never installed, and the Unity Editor is not needed. No Unity account is needed either. The package is subject to Unity's own terms; it is downloaded by each user and never redistributed by this repository (`vendor/` is ignored by git).

## Third-party code in this repository

None. Every source file in this repository was written for this project. The stub libraries are generated at build time from the export names of your own copy of the game.
