# 参与贡献

English: [CONTRIBUTING.md](CONTRIBUTING.md)

## 改任何东西之前：先让检查通过

检查方法见 [docs/VERIFY.zh-CN.md](docs/VERIFY.zh-CN.md)。简单说：

| 级别 | 命令 | 需要 |
|---|---|---|
| 1 | 每个脚本跑 `bash -n`，`python3 -I -m py_compile tools/*.py` | 什么都不需要 |
| 2 | `./setup.sh check`、`make fetch binaries stubs project build-nosign data`（`make project` 需要 `binaries` 和 `stubs` 的产物） | 你的 Mac 版游戏 |
| 3 | `make build install push-data`、`make smoke`、人工检查清单 | M 系列 iPad 和开发者账号 |

跑你的改动可能影响到的那几级，并在 PR 里写明跑了哪些。

## 三条规矩

### 一、仓库里不放游戏内容，也不放 Unity 的二进制

仓库不包含、也不分发任何游戏内容或 Unity 运行时文件。游戏的代码、数据、美术、文字、音频、存档，以及由它们生成的任何东西（包括截图）都不进仓库；从 Unity 下载的东西也一样。仓库里确实带有的，是 [docs/DERIVED.zh-CN.md](docs/DERIVED.zh-CN.md) 里列出的对接信息；如果你加了更多，请在同一次改动里补进那份清单。

下面这些是生成的或本机专用的，都已写进 `.gitignore`，不要强行加入：

| 路径 | 是什么 |
|---|---|
| `vendor/` | Unity iOS Support 包及其解包内容 |
| `build/Frameworks/` | 改标后的游戏二进制和生成的桩库 |
| `build/GameData/` | 你转换后的游戏数据 |
| `build/xcode/`、`build/DerivedData/` | 生成的 Xcode 工程（含打过补丁的 Unity 文件副本）和 Xcode 的产物 |
| `build/logs/`、`build/smoke/`、`build/crashes/` | 设备日志、截图（游戏画面）和崩溃报告 |
| `config.env` | 你自己的团队 ID、Bundle ID 和设备 |

issue 和 PR 也一样：不贴游戏文件、不贴游戏截图、不传构建产物。

### 二、注释中英双语

代码里的每条注释都有中文和英文两份，意思相同：

- 文件头和成段的注释：先写中文行，紧接着写英文行。

  ```objc
  // 强制横屏：在 createUI 之前设置 Unity 的屏幕方向
  // Force landscape: set Unity's screen orientation before createUI
  ```

- 行尾注释和单行 docstring：同一行先中文后英文，用 ` | ` 隔开。

  ```bash
  FW_OUT="$BUILD/Frameworks"  # 改标后的 .framework | Retagged .frameworks
  ```

脚本里给用户看的提示一律通过 `m "中文" "English"`（shell，定义在 `scripts/common.sh`）或 `m(zh, en)`（Python）输出，按 `DE_LANG` 或系统语言选择。App 运行时的日志用英文，因为冒烟测试要按它们匹配；改动已有的日志标记时，要同时更新 `scripts/smoke_test.sh` 和 [docs/VERIFY.zh-CN.md](docs/VERIFY.zh-CN.md)。

### 三、文档双语，并记录你学到的东西

每份文档都有英文文件和内容相同的 `.zh-CN.md` 文件，两份在同一次改动里一起更新。如果一个修法依赖 Unity 内部细节或游戏代码（类名、偏移、反汇编得知的行为），把现象、原因和修法写进 [docs/PORTING_NOTES.zh-CN.md](docs/PORTING_NOTES.zh-CN.md)。下一个人、或者下一个 agent，正是靠这份文档复刻移植的。

## 提交改动

用 PR 模板：改了什么、为什么、跑了哪些检查（跑了 `make smoke` 就贴最后一行），以及用的是哪台 Mac / iPad / iPadOS 版本。

## 报告问题

用 issue 模板。最有用的附件是 `./setup.sh check` 和 `make smoke` 的输出，或者用 `make logs` 取回的 `Player.log` 的相关片段。中文或英文都可以。
