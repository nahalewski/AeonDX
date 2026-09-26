# Cores: the plan

The user's ask: every emulator is a core, downloaded from the eShop as a
`.aeoncore`, and its games show on the 3DS HOME menu and in the Switch skin.
GameCube, Wii and Wii U are their own console folders, not Virtual Console.
Eden is a core, not a separate app.

## Phase 1: software cores (done)

- `emu/native/core_host.c`: a libretro frontend in libemucore that
  dlopens a downloaded core (`ec_open_core`). It handles every libretro pixel
  format, core options, save memory and save states. Tested on the desktop
  with FCEUmm and the nes-test-roms suite.
- `.aeoncore` (`tools/cores/README.md`), `tools/cores/make_aeoncore.py`,
  `tools/cores/cores.tsv` and `.github/workflows/cores.yml` publish to the
  `cores` release.
- `fold3ds/cores.lua` holds the catalogue, download, SHA-256 check, unpacking
  and installed cores.
- The eShop gets a Cores shelf, and the Virtual Console folder gets NES,
  Super NES, Virtual Boy, Pokemon mini and Game & Watch
  (`AeonDX/vc/roms/<system>/`).

## Phase 2: GPU cores (GameCube, Wii, Wii U, Switch)

Dolphin (GameCube and Wii), Cemu (Wii U) and Eden (Switch) render with the
GPU (OpenGL ES or Vulkan), run many threads, and on Android come with their
own Java/Kotlin layer (JNI entry points, a Surface to draw into, settings).
None of that fits libemucore's "give me the frame's pixels" host. The way
Azahar already works in this app is the model:

- The core's native libraries (`libmain.so` / `libyuzu-android.so` / Cemu's)
  go into its `.aeoncore` as `lib/arm64-v8a/*.so`, plus a `classes.dex`
  holding its JNI classes (NativeLibrary etc.) under their own package.
- An `AeonCoreHost` in the app loads the dex with a DexClassLoader whose
  library path is the unpacked core's `lib/` folder. It hands the core a
  Surface: the top screen's `SurfaceView`, as Azahar's in-shell play already
  does (Fold3dsShell.kt). It also drives start / pause / stop / input through
  the core's own NativeLibrary calls. Activities can't be declared from a
  downloaded dex, so all UI stays ours. Their settings pages are drawn from
  their settings files, like the Azahar folder's.
- Eden: its `src/android` (the `eden-src` branch) builds `libyuzu-android.so`
  and the `org.yuzu.yuzu_emu` JNI classes. A CI job builds those (NDK,
  Vulkan, CMake; about an hour) and packs them as `eden.aeoncore`. Then the
  Switch folder asks for the core, not the Eden app. EdenBridge's
  installed-app check becomes "is the core installed".
- Dolphin: `Source/Android` has the same shape (`libmain.so` +
  `org.dolphinemu.dolphinemu.NativeLibrary`) and becomes `dolphin.aeoncore`,
  serving the `gc` and `wii` folders.
- Cemu: its Android port (`src/android`) becomes `cemu.aeoncore` for the
  `wiiu` folder.

Each is its own CI build, publishing to the same `cores` release, with its
licence (Eden and Dolphin GPL-2.0+, Cemu MPL-2.0) inside the `.aeoncore`.
