# Cores (.aeoncore)

The emulators AeonDX downloads from the eShop's Cores shelf instead of
shipping in the APK. `cores.tsv` lists them. `.github/workflows/cores.yml`
fetches each one's Android arm64 build from the libretro buildbot, packs it
with `make_aeoncore.py`, and publishes it with `catalog.txt` to this
repository's `cores` release. On the phone, `fold3ds/cores.lua` reads the
catalogue, downloads a core, checks its SHA-256, and unpacks it into the save
folder. `libemucore`'s `core_host.c` then loads it (`ec_open_core`).

## The .aeoncore format (version 1)

A zip holding:

- `aeoncore.txt`: `key=value` lines
  - `format`: 1
  - `id`: the core's id (the catalogue's, and its folder under `cores/`)
  - `name`, `version`: shown in the eShop
  - `kind`: `libretro` (a libretro core drawing in software)
  - `systems`: comma-separated system ids (`nes`, `snes`, `vb`, `pokemini`, `gw`)
  - `extensions`: the file extensions it plays, `|` separated
  - `ext_<ext>=<system>`: which system an extension is, when a core has several
  - `lib`: the core's path in the zip, `lib/arm64-v8a/<name>.so`
  - `license`, `source`: the core's licence and where its source is
- `lib/arm64-v8a/<name>.so`: the core
- `LICENSE`: the core's licence text

`catalog.txt` has one core a line, tab separated: id, file, size, sha256,
name, systems, version, subtitle.

## Not yet

GameCube, Wii and Wii U (Dolphin, Cemu) and the Switch (Eden) need a
graphics-card renderer and their own Android code, so they can't run through
this host, which only takes software-drawn frames. They're the next kind of
core (see `notes/cores-plan.md`).
