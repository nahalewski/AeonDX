# Cores (.aeoncore)

The emulators AeonDX downloads from the eShop's Cores shelf instead of
shipping in the APK. `cores.tsv` lists them, each with its repository and a
pinned commit. `.github/workflows/cores.yml` clones each one at that commit,
applies our patches (`patches/<id>/*.patch`, in order, `git apply --3way`),
and builds it: libretro cores with `ndk-build`, Android cores (Dolphin, Cemu,
Eden) with their own Gradle build, R8 shrinking off so the host can reach
their classes by name. Then it packs the result with `make_aeoncore.py` and
publishes it with `catalog.txt` to this repository's `cores` release. Nothing
prebuilt from outside goes in. A core that fails keeps its last good build in
the release.

To update a core, change its commit in `cores.tsv` (and its patches if they
no longer apply) and push. On the phone, `fold3ds/cores.lua` reads the
catalogue, downloads a core, checks its SHA-256, and unpacks it into the save
folder. `libemucore`'s `core_host.c` then loads it (`ec_open_core`).

## The .aeoncore format (version 1)

A zip holding:

- `aeoncore.txt`: `key=value` lines
  - `format`: 1
  - `id`: the core's id (the catalogue's, and its folder under `cores/`)
  - `name`, `version`: shown in the eShop
  - `kind`: `libretro` (a libretro core drawing in software, hosted by
    libemucore's core_host.c) or `android` (an Android emulator's native
    libraries and classes, hosted in-process by AeonCoreHost.kt)
  - `dex`, `libdir`: an android core's classes (comma-separated .dex files)
    and its libraries' folder
  - `systems`: comma-separated system ids (`nes`, `snes`, `vb`, `pokemini`, `gw`)
  - `extensions`: the file extensions it plays, `|` separated
  - `ext_<ext>=<system>`: which system an extension is, when a core has several
  - `lib`: the core's path in the zip, `lib/arm64-v8a/<name>.so`
  - `license`, `source`: the core's licence and where its source is
- `lib/arm64-v8a/<name>.so`: the core
- `LICENSE`: the core's licence text

`catalog.txt` has one core a line, tab separated: id, file, size, sha256,
name, systems, version, subtitle.

## Android cores

Dolphin (GameCube, Wii), Cemu (Wii U) and Eden (Switch) are built from their
own Android projects. Their `classes*.dex` and `lib/arm64-v8a/*.so` go into
the `.aeoncore`, and AeonCoreHost.kt loads them into the app with a
child-first class loader. Each one draws into an ImageReader the shell reads,
the way Azahar's in-shell play works. See `notes/cores-plan.md`.
