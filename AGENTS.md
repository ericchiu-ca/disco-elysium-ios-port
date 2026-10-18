# Instructions for AI coding agents

中文: [AGENTS.zh-CN.md](AGENTS.zh-CN.md)

This repository turns a user's own Mac copy of Disco Elysium – The Final Cut into an app for their own iPad. Read [README.md](README.md) first, then [docs/PORTING_NOTES.md](docs/PORTING_NOTES.md) (how and why every part works). This file is the runbook.

## Ground rules

- **Never commit, upload or paste game content or Unity binaries** (`build/`, `vendor/`, screenshots, logs with large game text). See [docs/DERIVED.md](docs/DERIVED.md).
- **Ask the user** before: downloading the 530 MB Unity package (`make fetch`), registering a bundle ID in their developer account (the first signed `make build`), installing to or pushing data onto their device, and any automated taps on their game (they act on real saves).
- **Ask the user** before anything that writes to their Steam account: `make achievements-unlock`, `make achievements-sync`, `make relay` without `DRY_RUN=1`, and `make relay-install`. `make achievements` only reads. Use `make relay DRY_RUN=1` for tests. Never print, paste or commit `ACH_RELAY_SECRET`. See [docs/ACHIEVEMENTS.md](docs/ACHIEVEMENTS.md).
- **Ask the user for** their Team ID, a bundle ID of their own, and which iPad to use. Do not reuse anyone else's values.
- Generated directories are outputs: change the generators (`scripts/`, `tools/`, `shell/`), then regenerate. Trampoline changes go through `tools/patch_trampoline.py`; Unity player-library changes go through `tools/patch_player_lib.py`. New files in `shell/src/` need `make project` to be picked up.
- Code comments and docs are bilingual (Chinese, then English); app log lines are English and some are matched by `make smoke`. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Reproduction runbook

| Step | Command | Gate (must hold before moving on) | Typical time |
|---|---|---|---|
| 1 | `cp config.example.env config.env`, fill `TEAM_ID` and `BUNDLE_ID` with the user's values | Both are set (without them step 2 cannot pass) | — |
| 2 | `./setup.sh check` | Ends with "Health check passed.": no `✗` line. For each `✗`, do what its `→` line says (or ask the user). `·` lines are information only (for example, the Unity runtime is not downloaded before step 3); the game build line should be `✓` | seconds |
| 3 | `./setup.sh` | **Ask the user first** (it downloads the 530 MB Unity package and the signed build registers the bundle ID, see the ground rules). To check the toolchain before that without touching their account, run level 2 of [docs/VERIFY.md](docs/VERIFY.md) (`build-nosign`). Ends with "All set". This runs `make fetch binaries stubs project build data`; on the reference Mac `make build` takes about 10 s and `make data` about 10 s | about 1 min plus the download |
| 4 | `make install push-data` | `App installed`; `push-data` completes (about 9.6 GB, ~20 s over USB-C the first time, about 1 s afterwards). iPad unlocked and paired. Both keep the user's saves in `Documents/SaveGames`; never add `--remove-existing-content` to the push (it empties all of `Documents`, see PORTING_NOTES §2.6) | 1 min |
| 5 | `make smoke` | "Smoke test PASSED". Then open `build/smoke/<time>/device/snap-000.jpg` and `snap-003.jpg` and confirm what [docs/VERIFY.md](docs/VERIFY.md) describes | 75 s |
| 6 | Hand over to the user | Ask them to run the manual checklist in [docs/VERIFY.md](docs/VERIFY.md) | — |
| 7 (optional) | Steam achievements: [docs/ACHIEVEMENTS.md](docs/ACHIEVEMENTS.md). `make relay-pair`, `ACH_RELAY="1"`, `make stubs build install`, then `make relay-install` (ask first) | `./setup.sh check` section 7 has no `✗`; `make smoke` shows "Steam achievement mode on" and "The game uses Steam for achievements"; `make relay-status` shows `Steam session started` | 2 min |

Expected reference results are listed in [docs/VERIFY.md](docs/VERIFY.md).

## When something fails

1. Find the failing gate or smoke check in the table in [docs/VERIFY.md](docs/VERIFY.md); it points to the matching section of [docs/PORTING_NOTES.md](docs/PORTING_NOTES.md).
2. Get evidence on the device instead of guessing:
   - `make run` streams the game log; `make logs` fetches `Player.log` and snapshots.
   - Crash: `xcrun devicectl device info files --device <id> --domain-type systemCrashLogs`, copy the newest `DiscoElysium-*.ips` with `xcrun devicectl device copy from`, read the triggered thread.
   - The opt-in diagnostics in [docs/PORTING_NOTES.md](docs/PORTING_NOTES.md) section 7: `DE_SNAPSHOT_EVERY`, `DE_AUTOTAP`, `DE_AUTOKEY`, `DE_TRACE_TOUCH`, `DE_UI_DIAG`, `DE_CLASS_DIAG`, `DE_ACH_TEST`, and the switches that turn single fixes off.
3. Unity-internal or game-internal behaviour is best confirmed by reading it: list classes and methods through `DE_CLASS_DIAG` (or `DE_UI_DIAG`; both print method offsets), then `xcrun objdump -d --start-address=… --stop-address=… build/Frameworks/GameAssembly.framework/GameAssembly`. For Unity's player library, `ar -x` the object, `segedit -extract __LLVM __bitcode`, `clang -S -emit-llvm`.
4. Record what you learned in [docs/PORTING_NOTES.md](docs/PORTING_NOTES.md) (both languages).

## If the user's copy differs

`./setup.sh check` reports the Unity version and the game build. If they differ from those in [docs/GAME_FILES.md](docs/GAME_FILES.md), follow [docs/PORTING_NOTES.md](docs/PORTING_NOTES.md) section 9 before building, and tell the user it is an unverified build.

## Key facts

| | |
|---|---|
| Unity | 2020.3.12f1 (`b3b2c6512326`), IL2CPP, iOS Support package SHA-256 `33c739fc…fbe55` |
| Game build | `develop \| 6f8a0e67 \| ddb 2022-05-20 12:05 \| build 1725995648 \| Platform StandaloneOSX` (Steam, macOS) |
| Verified on | M5 Mac, macOS 27.2, Xcode 27.2 (27B5019j), XcodeGen 2.46.0, Python 3.15; iPad Pro 11-inch (M5), iPadOS 27.2 |
| App | Single target, bundle ID from `config.env`, data in `Documents/GameData/Contents/Resources/Data` (format 2) |
| Steam (optional achievement sync) | App ID `632470`; achievement mode replaces `shell/stubs/steam_api_overrides.c` with `shell/stubs/steam_relay.c`; relay on the Mac runs with `/usr/bin/python3` (Python 3.9); see PORTING_NOTES section 10 |
