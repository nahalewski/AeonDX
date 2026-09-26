/* emucore's pieces talking to each other (not for Lua) */
#ifndef EMUCORE_INTERNAL_H
#define EMUCORE_INTERNAL_H

#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include "emucore.h"

#ifdef __cplusplus
extern "C" {
#endif

/* settings given with ec_set_option; def when unset */
const char* ec_opt(const char* key, const char* def);
int ec_opt_bool(const char* key, int def);
void ec_set_error(const char* msg);
void ec_logv(const char* fmt, va_list ap);
void ec_log(const char* fmt, ...);

/* the DS (ds_host.cpp) */
int ds_open(const char* rom, const char* save, const char* sysdir);
void ds_close(void);
void ds_set_keys(uint32_t pressed);
void ds_touch(int down, int x, int y);
void ds_run_frame(void);
const uint8_t* ds_screen(int idx, int* w, int* h);
int ds_audio(int16_t* out, int max_frames);
void ds_flush(bool now);
int ds_save_state(const char* path);
int ds_load_state(const char* path);
void ds_reset(void);

/* GB / GBC / GBA (vc_host.c) */
int vc_open(int sys, const char* rom, const char* save, const char* sysdir);
void vc_close(void);
void vc_set_keys(uint32_t pressed);
void vc_run_frame(void);
const uint8_t* vc_screen(int* w, int* h);
int vc_audio(int16_t* out, int max_frames);
int vc_audio_rate(void);
double vc_fps(void);
void vc_flush(void);
int vc_save_state(const char* path);
int vc_load_state(const char* path);
void vc_reset(void);

/* a downloaded libretro core (core_host.c) */
int core_open(const char* so, const char* rom, const char* save, const char* sysdir);
void core_close(void);
void core_set_keys(uint32_t pressed);
void core_run_frame(void);
const uint8_t* core_screen(int* w, int* h);
int core_audio(int16_t* out, int max_frames);
int core_audio_rate(void);
double core_fps(void);
void core_flush(void);
int core_save_state(const char* path);
int core_load_state(const char* path);
void core_reset(void);

#ifdef __cplusplus
}
#endif
#endif
