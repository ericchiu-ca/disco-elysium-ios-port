# Game- and Unity-related material in this repository: what is here, what is not, and why

中文: [DERIVED.zh-CN.md](DERIVED.zh-CN.md)

## Not in the repository

- **No game content**: no game program, scripts, data, art, text, audio, shaders, saves or screenshots. Everything under `build/` (retagged binaries, converted data, generated project, device logs and snapshots) is produced on your machine from your copy and is ignored by git.
- **No Unity binaries or Unity source files**: the iOS player library, `baselib.a`, the Trampoline and the built-in resources are downloaded by each user from Unity's CDN into `vendor/`, which is ignored by git.
- **No copied code from the game's native plugins**: the stub libraries are generated at build time from the *export names* of your own copy.

## In the repository

Only names, numbers and short anchors needed to interoperate with your own copy and with the Unity runtime you download:

| Where | What it is | Why it has to be here |
|---|---|---|
| `tools/patch_trampoline.py` | Three short anchors from Unity's Trampoline source: the first lines of `UnityDataBundleDir()`, two `#define` lines from `Preprocessor.h`, and one `#include` line from `UnityAppController.mm` | Each patch replaces or extends exactly that text; the anchor proves the right place in the right Unity version is being patched (the tool stops if it does not match) |
| `tools/patch_player_lib.py` | The mangled names of six functions in Unity's `TextureFormatMetal.o`, one basic-block label, one `phi` pattern and one field index of `GraphicsCaps` in that object's LLVM IR | They locate the patch points for hardware BC textures; the tool stops if they do not match |
| `tools/gen_registration.py` | The naming patterns of Unity's module and icall registration functions (`RegisterModule_*`, `Register_UnityEngine_*`) | The actual list is read from the library you downloaded, at build time |
| `shell/src/DEICallOverrides.mm`, `DEVirtualInput.mm`, `DEOrientation.mm`, `DEAspect.mm` | Names of Unity's internal-call bindings, for example `UnityEngine.Application::get_platform`, `UnityEngine.Input::GetKeyInt`, `UnityEngine.Screen::RequestOrientation` | The port replaces or calls exactly these bindings |
| `shell/src/DEMetalBC.mm` | The numeric values of Unity's `GraphicsFormat` for DXT / BC formats (96–109), their Metal pixel formats, and the mangled names of three Unity helpers used by a start-up self-check | Mapping the formats is the whole point of the BC patch; the self-check refuses to enable it if the values do not match |
| `shell/src/DEAspect.mm` | Names of classes and members in the game code: `AspectUtility` (`wantedAspectRatio`, `SetAllCameras`), `AspectRatioFitterUtility` (`registry`, `fitter`), `GlobalUIFitter`, and the enum value used for `SetAllCameras` | The full-screen fix sets those fields and calls those methods through il2cpp reflection. What they do was learned by disassembling one's own copy; it is described in comments and in [PORTING_NOTES.md](PORTING_NOTES.md), with no code copied |
| `shell/src/DEVirtualInput.h` | A few `UnityEngine.KeyCode` values (Tab, Escape, I, J, C, T, M) | The on-screen highlight button and the automation hooks send these keys |
| `shell/src/DEBootstrap.mm` | The names of the game's native plugins (`steam_api`, `GalaxyCSharpGlue`, `InControlNative`, `AmplifyTextureNative`) and the Mac path of CFNetwork used by Mono | Native library lookups from the game are redirected to the frameworks inside the app |
| `shell/stubs/steam_api_overrides.c` | Four public Steamworks function names with their signatures | They must report "Steam is not available" explicitly (one of them returns 0 for success, so the generic "return 0" stub would be wrong) |
| `config.example.env`, `docs/` | The Unity version, changeset and the SHA-256 of Unity's official package; the game's build string | To download and verify the right runtime, and to tell users which copy of the game is supported |

If you add anything of this kind, list it here (in both languages) in the same change.
