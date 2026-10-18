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
| `./setup.sh check` | Every line `✓`, ending with "Health check passed." |
| `make fetch` | "Unity iOS runtime is ready" (after a one-time 530 MB download whose SHA-256 is verified) |
| `make binaries` | `GameAssembly` dependencies listed with iOS paths only (`/System/Library/Frameworks/Foundation.framework/Foundation`, no `Versions/`) |
| `make stubs` | Four frameworks: `GLStub`, `steam_api`, `GalaxyCSharpGlue`, `InControlNative` |
| `make project` | Three Trampoline patches applied, the BC player-library patch generated, 62 modules and 8163 icalls registered, XcodeGen done |
| `make build-nosign` | `** BUILD SUCCEEDED **` (the LTO link of the player library takes a few minutes) |
| `make data` | About 2179 files: 1877 UnityFS bundles, 76 serialized files, the rest raw data. Finishes in seconds on the same volume (APFS clones) |

## Level 3: on the iPad

```
make build install push-data
make smoke
```

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

Then look at the snapshots (by eye, or with an image-capable model):

| Snapshot | Expected |
|---|---|
| `snap-000.jpg` (≈15 s) | A start-up screen (the legal notice on black, or the ZA/UM animation on dark grey, depending on timing) covering the whole screen; nothing of the main menu shows at the top or bottom |
| `snap-003.jpg` (≈60 s) | Main menu in landscape, the painted background filling the screen, no black bars |

Reference values: memory footprint about 4.9 GB at the main menu and about 5.8 GB in game, with about 6.5 GB of headroom before the system would end the app (iPad Pro 11-inch M5).

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

Menu positions depend on the state: with a save present the first item is "Continue" (about `0.219,0.279` in the full-screen layout); without one, "New Game" is first. Take a snapshot first, then compute the coordinates from it. Automated taps act on the real game and its saves.
