/* emucore: the HOME menu's own emulators behind one small C interface,
 * driven from Lua (fold3ds/emu.lua) through LuaJIT's FFI.
 *
 *   DS            the melonDS core (melonDS-android-lib), ds_host.cpp
 *   GB, GBC, GBA  SkyEmu's cores (its libretro build), vc_host.c
 *
 * One game at a time.  The caller runs a frame, reads the screen(s) as RGBA
 * and pulls the audio; input is a key mask and, for the DS, a touch on the
 * bottom screen.  Everything is on the caller's thread.
 *
 * The declarations below are also given to ffi.cdef (fold3ds/emu.lua):
 * keep the two in step. */
#ifndef EMUCORE_H
#define EMUCORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* the library shows only these functions (built with hidden visibility) */
#if defined(__GNUC__) || defined(__clang__)
#pragma GCC visibility push(default)
#endif

#define EC_SYS_GB  1
#define EC_SYS_GBC 2
#define EC_SYS_GBA 3
#define EC_SYS_DS  4

/* key bits (the DS's own order): pressed = 1 */
#define EC_KEY_A      (1u << 0)
#define EC_KEY_B      (1u << 1)
#define EC_KEY_SELECT (1u << 2)
#define EC_KEY_START  (1u << 3)
#define EC_KEY_RIGHT  (1u << 4)
#define EC_KEY_LEFT   (1u << 5)
#define EC_KEY_UP     (1u << 6)
#define EC_KEY_DOWN   (1u << 7)
#define EC_KEY_R      (1u << 8)
#define EC_KEY_L      (1u << 9)
#define EC_KEY_X      (1u << 10)
#define EC_KEY_Y      (1u << 11)
#define EC_KEY_LID    (1u << 12)   /* DS: the lid closed */

int ec_version(void);

/* settings, before ec_open (see fold3ds/emu.lua for the keys) */
void ec_set_option(const char* key, const char* value);

/* start a game: the ROM, its save file (read if there, written as the game
 * saves) and the system folder (BIOS / firmware, optional).  1 = running. */
int ec_open(int sys, const char* rom, const char* save, const char* sysdir);
void ec_close(void);
int ec_system(void);                  /* EC_SYS_*, 0 = none */
const char* ec_error(void);

void ec_set_keys(uint32_t pressed);
void ec_touch(int down, int x, int y); /* DS bottom screen, 256 x 192 */
void ec_run_frame(void);
double ec_fps(void);                   /* the system's frame rate */

/* the screens after the last frame: 1 (GB/GBC/GBA) or 2 (DS: 0 top,
 * 1 bottom), each RGBA8, w * h * 4 bytes, valid until the next frame */
int ec_screen_count(void);
const uint8_t* ec_screen(int idx, int* w, int* h);

/* audio: signed 16-bit stereo, interleaved; frames read (<= max_frames) */
int ec_audio_rate(void);
int ec_audio(int16_t* out, int max_frames);

/* the save memory to its file when it changed (the DS writes as it goes;
 * GB/GBC/GBA are written here) */
void ec_flush(void);
int ec_save_state(const char* path);
int ec_load_state(const char* path);
void ec_reset(void);

/* Optional GBA normal-8-bit SIO endpoint. TX events are 5-byte records:
 * transmitted byte, SIOCNT LE16, and RCNT LE16. RX bytes are consumed by
 * the next completed transfer. */
void ec_gba_sio_set_enabled(int enabled);
int ec_gba_sio_read_tx(uint8_t* out, int capacity);
int ec_gba_sio_write_rx(const uint8_t* data, int length);
uint32_t ec_gba_sio_dropped(void);

/* a ROM's header without running it: system (EC_SYS_*, 0 unknown), title,
 * game code / serial, CRC32 of the whole file, and for a DS game its
 * 32 x 32 banner icon (RGBA8, 4096 bytes) when icon_rgba is given. */
int ec_rom_info(const char* path, char* title, int title_len, char* code, int code_len,
                uint32_t* crc, uint8_t* icon_rgba);

/* the user folder: make a path (and its parents), list a folder
 * ("name\n" per entry, folders end in '/'); bytes written, -1 no folder */
int ec_mkdirs(const char* path);
int ec_list(const char* dir, char* out, int out_len);
int ec_copy(const char* from, const char* to);
int ec_remove(const char* path);

#if defined(__GNUC__) || defined(__clang__)
#pragma GCC visibility pop
#endif

#ifdef __cplusplus
}
#endif
#endif
