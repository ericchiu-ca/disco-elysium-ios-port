# Verifying a build

中文: [VERIFY.zh-CN.md](VERIFY.zh-CN.md)

How to tell, step by step, that a reproduction works — and where to look when it does not. The expected outputs below were recorded on the reference setup (M5 Mac, macOS 27.2, Xcode 27.2, iPad Pro 11-inch M5, iPadOS 27.2).

## Level 1: no game files needed

```
for f in setup.sh scripts/*.sh; do bash -n "$f"; done
python3 -I -m py_compile tools/*.py && rm -rf tools/__pycache__
```

Both must finish without output.

## Level 2: game files needed, no iPad

| Command | Expected |
|---|---|
| `./setup.sh check` | No `✗` line, ending with "Health check passed." `·` lines are information: before `make fetch` the Unity runtime shows as not downloaded yet. "Game build matches the verified one" should be `✓` |
| `make fetch` | Ends with "Unity iOS runtime is ready". The first time it prints "Downloading …", "Verifying SHA-256" and "Unpacking …" before that (530 MB, about 10 s at 50 MB/s; `vendor/` then takes about 2 GB) |
| `make binaries` | `GameAssembly` dependencies listed with iOS paths only (`/System/Library/Frameworks/Foundation.framework/Foundation`, no `Versions/`) |
| `make stubs` | Four frameworks: `GLStub` (13 empty stubs), `steam_api` (1049 empty stubs, 4 hand-written), `GalaxyCSharpGlue` (1231), `InControlNative` (32) |
| `make project` | Four `Patched …` lines (`Filesystem.mm`, `UnityAppController.mm`, `Preprocessor.h` twice: the three patches of PORTING_NOTES §2.4), the BC player-library patch generated, 62 modules and 8163 icalls registered, XcodeGen done. The clang warning `overriding the module target triple with arm64-apple-ios12.0.0` is expected |
| `make build-nosign` | `** BUILD SUCCEEDED **` (about 10 s on the reference Mac with an empty `build/DerivedData`) |
| `make data` | "2179 files to process (UnityFS bundles 1877, SerializedFiles 76, raw data 226)", then "Done: … (2179 files, …)". About 10 s on the same volume; only the rewritten bundles take real space (about 4.4 GB), the rest are APFS clones |

## Level 3: on the iPad

```
make build install push-data
make smoke
```

`make install` prints `App installed:`. `make push-data` takes about 20 s the first time and about 1 s when nothing changed; afterwards `Documents/` on the iPad still holds `SaveGames`, `Logs` and `Unity` next to `GameData` (`xcrun devicectl device info files --device <id> --domain-type appDataContainer --domain-identifier <bundle id> --subdirectory Documents --no-recurse`).

`make smoke` launches the installed app with no input for 75 seconds, collects the console log and a snapshot every 15 seconds into `build/smoke/<timestamp>/`, and checks:

| Check | Log marker it looks for | If it fails, see |
|---|---|---|
| Shell found the game data | `[DEPort] GameData: ` | [GAME_FILES.md](GAME_FILES.md), `make push-data` |
| icall overrides installed | `[DEPort] icall overrides installed` | PORTING_NOTES §2.3, §4 |
| Virtual input enabled | `[DEPort] virtual input enabled` | PORTING_NOTES §5 |
| Touch overlay attached | `[DEPort] touch overlay attached` | PORTING_NOTES §5 |
| Forced landscape | `[DEPort] orientation: landscape autorotation` | PORTING_NOTES §3 |
| Unity engine initialized | `Initialize engine version: ` | PORTING_NOTES §2, crash report |
| All scenes loaded | `TOTAL SCENE LOADING took` | PORTING_NOTES §2.6 |
| Reached the main menu | `Scene Loading Scenes/Lobby` | PORTING_NOTES §3, §4 |
| Camera aspect set to the screen | `[DEPort] aspect: wantedAspectRatio … -> ` | PORTING_NOTES §6 |
| HUD frame resized | `[DEPort] aspect: Global UI Fitter ` | PORTING_NOTES §6 |
| No `MissingMethodException` | (must be absent) | PORTING_NOTES §2.3 |
| No `DllNotFoundException` / `EntryPointNotFoundException` | (must be absent) | PORTING_NOTES §2.2 |
| No crash | no `App terminated due to signal N` other than 14 (14 is the end of the timed run) | Crash report (PORTING_NOTES §7) |
| BC textures in hardware | `[DEPort] BC textures: hardware`, and no `decompressing texture` | PORTING_NOTES §2.5 |

Then look at the snapshots (by eye, or with an image-capable model). `build/smoke/<timestamp>/device` keeps only the snapshots that this run's log says it saved: the iPad's `Documents/Logs` still holds older ones (numbering restarts at 000 on every launch), and the smoke test drops those. If `snap-003.jpg` is missing, the run ended before 60 s.

| Snapshot | Expected |
|---|---|
| `snap-000.jpg` (≈15 s) | A start-up screen (the legal notice on black, or the ZA/UM animation on dark grey, depending on timing) covering the whole screen; nothing of the main menu shows at the top or bottom |
| `snap-003.jpg` (≈60 s) | Main menu in landscape, the painted background filling the screen, no black bars |

Reference values: memory footprint about 4.9 GB at the main menu and about 5.8 GB in game, with about 6.5 GB of headroom before the system would end the app (iPad Pro 11-inch M5).

## Achievement mode (optional)

Only with `ACH_RELAY=1`; see [ACHIEVEMENTS.md](ACHIEVEMENTS.md).

| Step | Expected |
|---|---|
| `./setup.sh check` | Section 7 has no `✗` |
| `make achievements` (Steam open and logged in; read-only) | One line per achievement (`✓` or `·`), ending with "Unlocked N of 45" |
| `make relay DRY_RUN=1` in one terminal, then start the game on the iPad | The relay prints `iPad connected` and `Steam session started`; `Player.log` has `[DEPort] steam relay: connected to the Mac: …` |
| `make smoke` | Three more checks: "Steam achievement mode on", "The game initialized an achievement backend", and no `INITIALIZE ACHIEVEMENTS: NONE` |
| Unlock an achievement in the game (with `make relay` running without `DRY_RUN`) | `Player.log`: `achievement … recorded`, then `… committed to Steam`; it shows on your Steam profile |

## Manual checklist

| Action | Expected |
|---|---|
| Tap menu items | They activate on the first tap |
| Long-press over a menu item or an object, then slide | Hover highlight follows the finger; nothing is clicked when you lift it |
| Tap twice quickly on the ground in game | The character runs |
| Tap the eye button on the left, then tap a dialogue option | Interactables highlight; the tap releases the highlight and selects the option |
| Look at the bottom-right HUD buttons in game | They sit on their dark decorative strip at the bottom edge |
| Open inventory / journal / character sheet with the game's own HUD buttons | They open and close normally |
| Save and load | The save appears in the load list and loads |

## Navigating automatically

Without touching the device, `DE_AUTOTAP` clicks at given times (normalized coordinates, origin top-left) and `DE_SNAPSHOT_EVERY` shows the result:

```
DEVICECTL_CHILD_DE_LOG_TO_CONSOLE=1 DEVICECTL_CHILD_DE_SNAPSHOT_EVERY=20 \
DEVICECTL_CHILD_DE_AUTOTAP="45:0.219,0.279" \
  perl -e 'alarm 90; exec @ARGV' xcrun devicectl device process launch --device <id> --terminate-existing --console <bundle id>
make logs     # snapshots and Player.log land in build/logs
```

`make logs` also brings back snapshots left by earlier runs. Use the `[DEPort] snapshot snap-NNN.jpg saved` lines of this run's console output (or the file times) to tell which ones are new.

Menu positions depend on the state: with a save present the first item is "Continue" (about `0.219,0.279` in the full-screen layout); without one, "New Game" is first. Take a snapshot first, then compute the coordinates from it. Automated taps act on the real game and its saves.
