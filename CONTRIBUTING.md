# Contributing

中文: [CONTRIBUTING.zh-CN.md](CONTRIBUTING.zh-CN.md)

## Before you change anything: get the checks passing

The checks are described in [docs/VERIFY.md](docs/VERIFY.md). In short:

| Level | Commands | Needs |
|---|---|---|
| 1 | `bash -n` on every script, `python3 -I -m py_compile tools/*.py` | Nothing |
| 2 | `./setup.sh check`, `make fetch binaries stubs project build-nosign data` (`make project` needs the output of `binaries` and `stubs`) | Your Mac copy of the game |
| 3 | `make build install push-data`, `make smoke`, the manual checklist | An M-series iPad and a developer account |

Run the levels your change can affect, and say in the pull request which ones you ran.

## Three rules

### 1. No game content and no Unity binaries in the repository

The repository contains and distributes no game content and no Unity runtime files. The game's code, data, art, text, audio and saves — and anything generated from them, including screenshots — stay out. So does everything downloaded from Unity. What the repository does carry is the interoperability information listed in [docs/DERIVED.md](docs/DERIVED.md); add to that list in the same change if you add more.

These are generated or local and are ignored by `.gitignore`. Do not force-add them:

| Path | What it is |
|---|---|
| `vendor/` | The Unity iOS Support package and its unpacked contents |
| `build/Frameworks/` | Retagged game binaries and generated stub libraries |
| `build/GameData/` | Your converted game data |
| `build/xcode/`, `build/DerivedData/` | The generated Xcode project (including patched copies of Unity files) and Xcode output |
| `build/logs/`, `build/smoke/`, `build/crashes/` | Device logs, snapshots (game screenshots) and crash reports |
| `config.env` | Your own Team ID, bundle ID and device |

The same applies to issues and pull requests: no game files, no game screenshots, no builds.

### 2. Comments are bilingual

Every comment in the code exists in both Chinese and English, saying the same thing:

- File headers and block comments: the Chinese lines first, immediately followed by the English lines.

  ```objc
  // 强制横屏：在 createUI 之前设置 Unity 的屏幕方向
  // Force landscape: set Unity's screen orientation before createUI
  ```

- Trailing comments and one-line docstrings: Chinese first, then English, on the same line, separated by ` | `.

  ```bash
  FW_OUT="$BUILD/Frameworks"  # 改标后的 .framework | Retagged .frameworks
  ```

User-facing messages in scripts go through `m "中文" "English"` (shell, from `scripts/common.sh`) or `m(zh, en)` (Python), which pick the language from `DE_LANG` or the system language. Runtime log lines in the app are English, because the smoke test greps them; do not change existing log markers without updating `scripts/smoke_test.sh` and [docs/VERIFY.md](docs/VERIFY.md).

### 3. Documentation is bilingual and records what you learned

Every document has an English file and a `.zh-CN.md` file with the same content; update both in the same change. When a fix depends on Unity internals or on the game's code (a class name, an offset, a behaviour learned by disassembly), record the symptom, the cause and the fix in [docs/PORTING_NOTES.md](docs/PORTING_NOTES.md). That document is what lets the next person, or the next agent, reproduce the port.

## Submitting a change

Use the pull request template: what changed, why, which checks you ran (paste the last line of `make smoke` if you ran it), and on which Mac / iPad / iPadOS.

## Reporting a problem

Use the issue template. The most useful attachments are the output of `./setup.sh check` and of `make smoke`, or the relevant part of `Player.log` fetched with `make logs`. Chinese or English are both fine.
