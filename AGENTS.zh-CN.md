# 给 AI 编程 agent 的说明

English: [AGENTS.md](AGENTS.md)

本仓库把用户自己的《极乐迪斯科：最终剪辑版》Mac 版，转换成能在他自己 iPad 上运行的 App。先读 [README.zh-CN.md](README.zh-CN.md)，再读 [docs/PORTING_NOTES.zh-CN.md](docs/PORTING_NOTES.zh-CN.md)（每个部分怎么工作、为什么这样做）。本文件是操作手册。

## 基本规矩

- **绝不提交、上传或粘贴游戏内容和 Unity 的二进制**（`build/`、`vendor/`、截图、含大段游戏文字的日志）。见 [docs/DERIVED.zh-CN.md](docs/DERIVED.zh-CN.md)。
- 以下操作**先问用户**：下载 530 MB 的 Unity 包（`make fetch`）、在他的开发者账号里注册 Bundle ID（第一次带签名的 `make build`）、往他的设备上安装或推送数据、以及任何对他游戏的自动点按（会作用于真实存档）。
- **向用户索取**：他的团队 ID、他自己的 Bundle ID、用哪台 iPad。不要沿用任何别人的值。
- 生成的目录都是产物：修改生成它们的东西（`scripts/`、`tools/`、`shell/`），再重新生成。改 Trampoline 走 `tools/patch_trampoline.py`；改 Unity 播放器库走 `tools/patch_player_lib.py`。`shell/src/` 里新加的文件要 `make project` 才会被纳入。
- 代码注释和文档都是中英双语（先中文后英文）；App 的日志用英文，其中一部分会被 `make smoke` 匹配。见 [CONTRIBUTING.zh-CN.md](CONTRIBUTING.zh-CN.md)。

## 复刻步骤

| 步骤 | 命令 | 门槛（满足后才能进入下一步） | 大致耗时 |
|---|---|---|---|
| 1 | `cp config.example.env config.env`，用用户给的值填上 `TEAM_ID` 和 `BUNDLE_ID` | 两项都已填写（不填第 2 步过不了） | — |
| 2 | `./setup.sh check` | 最后显示"体检通过。"：没有任何 `✗` 行。每个 `✗` 照它下面 `→` 那行去做（或者问用户）。`·` 行只是提示（例如第 3 步之前 Unity 运行时还没下载）；游戏构建那一行应当是 `✓` | 几秒 |
| 3 | `./setup.sh` | **先问用户**（它会下载 530 MB 的 Unity 包，带签名的构建会注册 Bundle ID，见基本规矩）。想在这之前、不动用户账号就检查工具链，先跑 [docs/VERIFY.zh-CN.md](docs/VERIFY.zh-CN.md) 的第二级（`build-nosign`）。最后显示"准备完成"。它执行 `make fetch binaries stubs project build data`；参考环境上 `make build` 约 10 秒，`make data` 约 10 秒 | 约 1 分钟，另加下载时间 |
| 4 | `make install push-data` | 出现 `App installed`；`push-data` 完成（约 9.6 GB，首次 USB-C 约 20 秒，之后约 1 秒）。iPad 已解锁并已配对。两者都不会动用户在 `Documents/SaveGames` 里的存档；推送时绝不要加 `--remove-existing-content`（它会清空整个 `Documents`，见移植笔记 2.6） | 1 分钟 |
| 5 | `make smoke` | 显示"冒烟测试通过"。然后打开 `build/smoke/<时间>/device/snap-000.jpg` 和 `snap-003.jpg`，确认符合 [docs/VERIFY.zh-CN.md](docs/VERIFY.zh-CN.md) 的描述 | 75 秒 |
| 6 | 交给用户 | 请他按 [docs/VERIFY.zh-CN.md](docs/VERIFY.zh-CN.md) 的人工检查清单试一遍 | — |

参考结果列在 [docs/VERIFY.zh-CN.md](docs/VERIFY.zh-CN.md) 里。

## 出问题时

1. 在 [docs/VERIFY.zh-CN.md](docs/VERIFY.zh-CN.md) 的表里找到没通过的门槛或冒烟检查项，它会指向 [docs/PORTING_NOTES.zh-CN.md](docs/PORTING_NOTES.zh-CN.md) 的对应章节。
2. 在设备上取证据，不要猜：
   - `make run` 实时输出游戏日志；`make logs` 取回 `Player.log` 和截图。
   - 崩溃：`xcrun devicectl device info files --device <id> --domain-type systemCrashLogs`，用 `xcrun devicectl device copy from` 取回最新的 `DiscoElysium-*.ips`，看触发崩溃的线程。
   - [docs/PORTING_NOTES.zh-CN.md](docs/PORTING_NOTES.zh-CN.md) 第七节的可选诊断：`DE_SNAPSHOT_EVERY`、`DE_AUTOTAP`、`DE_AUTOKEY`、`DE_TRACE_TOUCH`、`DE_UI_DIAG`，以及单独关闭某项修复的开关。
3. Unity 内部或游戏内部的行为，最好直接读出来确认：用 `DE_UI_DIAG` 列出类和方法（它会打印方法偏移），再用 `xcrun objdump -d --start-address=… --stop-address=… build/Frameworks/GameAssembly.framework/GameAssembly` 反汇编。Unity 播放器库则用 `ar -x` 取出对象文件，`segedit -extract __LLVM __bitcode`，再 `clang -S -emit-llvm`。
4. 把学到的东西记进 [docs/PORTING_NOTES.zh-CN.md](docs/PORTING_NOTES.zh-CN.md)（中英文都要）。

## 用户的副本不一样时

`./setup.sh check` 会报告 Unity 版本和游戏构建。如果与 [docs/GAME_FILES.zh-CN.md](docs/GAME_FILES.zh-CN.md) 里的不同，构建之前先照 [docs/PORTING_NOTES.zh-CN.md](docs/PORTING_NOTES.zh-CN.md) 第九节处理，并告诉用户这是未经验证的构建。

## 关键信息

| | |
|---|---|
| Unity | 2020.3.12f1（`b3b2c6512326`），IL2CPP，iOS Support 包 SHA-256 `33c739fc…fbe55` |
| 游戏构建 | `develop \| 6f8a0e67 \| ddb 2022-05-20 12:05 \| build 1725995648 \| Platform StandaloneOSX`（Steam，macOS） |
| 验证环境 | M5 Mac、macOS 27.2、Xcode 27.2（27B5019j）、XcodeGen 2.46.0、Python 3.15；iPad Pro 11 英寸（M5）、iPadOS 27.2 |
| App | 单一 target，Bundle ID 取自 `config.env`，数据在 `Documents/GameData/Contents/Resources/Data`（格式 2） |
