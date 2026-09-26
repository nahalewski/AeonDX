/* Downloaded cores: any libretro core that draws in software, loaded at run
 * time from an installed .aeoncore (fold3ds/cores.lua unpacks it into the
 * save folder: cores/<id>/<the core's .so>).  This file is the core's
 * frontend, like vc_host.c is SkyEmu's, but reaches the core through dlopen
 * instead of linking it in, so a core can be added without a new APK.
 *
 * The core's save memory is read from the save file after the game loads
 * and written back (ec_flush) when it changed; BIOS files come from the
 * system folder; core options come from ec_set_option("core.<key>", value)
 * and otherwise the core's own default (the first of its values). */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libretro.h"
#include "emucore_internal.h"

typedef struct {
  void (*init)(void);
  void (*deinit)(void);
  void (*set_environment)(retro_environment_t);
  void (*set_video_refresh)(retro_video_refresh_t);
  void (*set_audio_sample)(retro_audio_sample_t);
  void (*set_audio_sample_batch)(retro_audio_sample_batch_t);
  void (*set_input_poll)(retro_input_poll_t);
  void (*set_input_state)(retro_input_state_t);
  void (*get_system_info)(struct retro_system_info*);
  void (*get_system_av_info)(struct retro_system_av_info*);
  bool (*load_game)(const struct retro_game_info*);
  void (*unload_game)(void);
  void (*run)(void);
  void (*reset)(void);
  size_t (*serialize_size)(void);
  bool (*serialize)(void*, size_t);
  bool (*unserialize)(const void*, size_t);
  void* (*get_memory_data)(unsigned);
  size_t (*get_memory_size)(unsigned);
} core_api;

#define MAX_VARS 128

static struct {
  void* dl;
  char dl_path[1024];
  core_api api;
  int inited;
  int open;
  char sysdir[1024];
  char savedir[1024];
  char save_path[1024];
  uint8_t* saved;
  size_t saved_len;
  uint32_t keys;
  enum retro_pixel_format fmt;
  uint8_t* rgba;
  int w, h;
  double fps;
  int rate;
  int16_t ring[65536];
  uint32_t rd, wr;
  /* the core's options: key, and its default (the first value) */
  char* var_key[MAX_VARS];
  char* var_def[MAX_VARS];
  int nvars;
} cc;

#define RING_LEN (sizeof cc.ring / sizeof cc.ring[0])

static void RETRO_CALLCONV log_cb(enum retro_log_level level, const char* fmt, ...)
{
  if (level < RETRO_LOG_WARN) return;
  va_list ap;
  va_start(ap, fmt);
  ec_logv(fmt, ap);
  va_end(ap);
}

static char* dup_str(const char* s)
{
  size_t n = strlen(s) + 1;
  char* d = (char*)malloc(n);
  if (d) memcpy(d, s, n);
  return d;
}

static void clear_vars(void)
{
  for (int i = 0; i < cc.nvars; i++) { free(cc.var_key[i]); free(cc.var_def[i]); }
  cc.nvars = 0;
}

/* "Description; first|second|third" -> "first" */
static void add_var(const char* key, const char* value)
{
  if (!key || cc.nvars >= MAX_VARS) return;
  const char* v = value ? strchr(value, ';') : NULL;
  v = v ? v + 1 : "";
  while (*v == ' ') v++;
  size_t n = strcspn(v, "|");
  char* def = (char*)malloc(n + 1);
  if (!def) return;
  memcpy(def, v, n);
  def[n] = 0;
  cc.var_key[cc.nvars] = dup_str(key);
  cc.var_def[cc.nvars] = def;
  cc.nvars++;
}

static const char* get_var(const char* key)
{
  char opt[256];
  snprintf(opt, sizeof opt, "core.%s", key);
  const char* v = ec_opt(opt, NULL);
  if (v) return v;
  for (int i = 0; i < cc.nvars; i++)
    if (!strcmp(cc.var_key[i], key)) return cc.var_def[i];
  return NULL;
}

static bool RETRO_CALLCONV environment(unsigned cmd, void* data)
{
  switch (cmd) {
    case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
      ((struct retro_log_callback*)data)->log = log_cb;
      return true;
    case RETRO_ENVIRONMENT_GET_CAN_DUPE:
      *(bool*)data = true;
      return true;
    case RETRO_ENVIRONMENT_SET_VARIABLES: {
      clear_vars();
      for (const struct retro_variable* v = (const struct retro_variable*)data; v && v->key; v++)
        add_var(v->key, v->value);
      return true;
    }
    case RETRO_ENVIRONMENT_GET_VARIABLE: {
      struct retro_variable* v = (struct retro_variable*)data;
      v->value = v->key ? get_var(v->key) : NULL;
      return v->value != NULL;
    }
    case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
      *(bool*)data = false;
      return true;
    case RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION:
      *(unsigned*)data = 0;   /* the cores fall back to SET_VARIABLES */
      return true;
    case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
      *(const char**)data = cc.sysdir[0] ? cc.sysdir : NULL;
      return cc.sysdir[0] != 0;
    case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
      *(const char**)data = cc.savedir[0] ? cc.savedir : NULL;
      return cc.savedir[0] != 0;
    case RETRO_ENVIRONMENT_GET_AUDIO_VIDEO_ENABLE:
      *(int*)data = 3;
      return true;
    case RETRO_ENVIRONMENT_GET_LANGUAGE:
      *(unsigned*)data = RETRO_LANGUAGE_ENGLISH;
      return true;
    case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT: {
      enum retro_pixel_format f = *(const enum retro_pixel_format*)data;
      if (f != RETRO_PIXEL_FORMAT_0RGB1555 && f != RETRO_PIXEL_FORMAT_XRGB8888 && f != RETRO_PIXEL_FORMAT_RGB565)
        return false;
      cc.fmt = f;
      return true;
    }
    case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO: {
      const struct retro_system_av_info* av = (const struct retro_system_av_info*)data;
      if (av->timing.fps > 1) cc.fps = av->timing.fps;
      if (av->timing.sample_rate > 1000) cc.rate = (int)av->timing.sample_rate;
      return true;
    }
    case RETRO_ENVIRONMENT_SET_GEOMETRY:
    case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
    case RETRO_ENVIRONMENT_SET_CONTROLLER_INFO:
    case RETRO_ENVIRONMENT_SET_SUBSYSTEM_INFO:
    case RETRO_ENVIRONMENT_SET_MEMORY_MAPS:
    case RETRO_ENVIRONMENT_SET_SUPPORT_ACHIEVEMENTS:
    case RETRO_ENVIRONMENT_SET_PERFORMANCE_LEVEL:
      return true;
    default:
      return false;
  }
}

static void RETRO_CALLCONV video_cb(const void* data, unsigned width, unsigned height, size_t pitch)
{
  if (!data || !width || !height) return;   /* a duped frame keeps the last picture */
  if ((int)width != cc.w || (int)height != cc.h || !cc.rgba) {
    free(cc.rgba);
    cc.rgba = (uint8_t*)malloc((size_t)width * height * 4);
    if (!cc.rgba) return;
    cc.w = (int)width;
    cc.h = (int)height;
  }
  for (unsigned y = 0; y < height; y++) {
    const uint8_t* row = (const uint8_t*)data + y * pitch;
    uint8_t* d = cc.rgba + (size_t)y * width * 4;
    for (unsigned x = 0; x < width; x++) {
      unsigned r, g, b;
      if (cc.fmt == RETRO_PIXEL_FORMAT_XRGB8888) {
        uint32_t p = ((const uint32_t*)row)[x];
        r = (p >> 16) & 0xFF; g = (p >> 8) & 0xFF; b = p & 0xFF;
      } else if (cc.fmt == RETRO_PIXEL_FORMAT_RGB565) {
        uint16_t p = ((const uint16_t*)row)[x];
        r = (p >> 11) & 0x1F; g = (p >> 5) & 0x3F; b = p & 0x1F;
        r = (r << 3) | (r >> 2); g = (g << 2) | (g >> 4); b = (b << 3) | (b >> 2);
      } else {
        uint16_t p = ((const uint16_t*)row)[x];
        r = (p >> 10) & 0x1F; g = (p >> 5) & 0x1F; b = p & 0x1F;
        r = (r << 3) | (r >> 2); g = (g << 3) | (g >> 2); b = (b << 3) | (b >> 2);
      }
      d[x * 4 + 0] = (uint8_t)r;
      d[x * 4 + 1] = (uint8_t)g;
      d[x * 4 + 2] = (uint8_t)b;
      d[x * 4 + 3] = 255;
    }
  }
}

static void RETRO_CALLCONV audio_cb(int16_t left, int16_t right)
{
  cc.ring[cc.wr++ % RING_LEN] = left;
  cc.ring[cc.wr++ % RING_LEN] = right;
}

static size_t RETRO_CALLCONV audio_batch_cb(const int16_t* data, size_t frames)
{
  for (size_t i = 0; i < frames * 2; i++) cc.ring[cc.wr++ % RING_LEN] = data[i];
  if (cc.wr - cc.rd > RING_LEN) cc.rd = cc.wr - RING_LEN;
  return frames;
}

static void RETRO_CALLCONV input_poll_cb(void) {}

static int16_t RETRO_CALLCONV input_state_cb(unsigned port, unsigned device, unsigned index, unsigned id)
{
  (void)index;
  if (port != 0 || device != RETRO_DEVICE_JOYPAD) return 0;
  static const uint32_t map[] = {
    [RETRO_DEVICE_ID_JOYPAD_B] = EC_KEY_B, [RETRO_DEVICE_ID_JOYPAD_Y] = EC_KEY_Y,
    [RETRO_DEVICE_ID_JOYPAD_SELECT] = EC_KEY_SELECT, [RETRO_DEVICE_ID_JOYPAD_START] = EC_KEY_START,
    [RETRO_DEVICE_ID_JOYPAD_UP] = EC_KEY_UP, [RETRO_DEVICE_ID_JOYPAD_DOWN] = EC_KEY_DOWN,
    [RETRO_DEVICE_ID_JOYPAD_LEFT] = EC_KEY_LEFT, [RETRO_DEVICE_ID_JOYPAD_RIGHT] = EC_KEY_RIGHT,
    [RETRO_DEVICE_ID_JOYPAD_A] = EC_KEY_A, [RETRO_DEVICE_ID_JOYPAD_X] = EC_KEY_X,
    [RETRO_DEVICE_ID_JOYPAD_L] = EC_KEY_L, [RETRO_DEVICE_ID_JOYPAD_R] = EC_KEY_R,
  };
  if (id == RETRO_DEVICE_ID_JOYPAD_MASK) {
    int16_t mask = 0;
    for (unsigned i = 0; i < sizeof map / sizeof map[0]; i++)
      if (map[i] && (cc.keys & map[i])) mask |= (int16_t)(1 << i);
    return mask;
  }
  if (id >= sizeof map / sizeof map[0]) return 0;
  return (cc.keys & map[id]) ? 1 : 0;
}

static uint8_t* read_all(const char* path, size_t* len)
{
  *len = 0;
  FILE* f = fopen(path, "rb");
  if (!f) return NULL;
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  if (n <= 0) { fclose(f); return NULL; }
  uint8_t* buf = (uint8_t*)malloc((size_t)n);
  if (buf && fread(buf, 1, (size_t)n, f) != (size_t)n) { free(buf); buf = NULL; }
  fclose(f);
  if (buf) *len = (size_t)n;
  return buf;
}

static int write_all(const char* path, const void* data, size_t len)
{
  char tmp[1100];
  snprintf(tmp, sizeof tmp, "%s.part", path);
  FILE* f = fopen(tmp, "wb");
  if (!f) return 0;
  int ok = fwrite(data, 1, len, f) == len;
  ok = (fclose(f) == 0) && ok;
  return ok && rename(tmp, path) == 0;
}

#define SYM(name) (*(void**)&cc.api.name = dlsym(cc.dl, "retro_" #name))

/* the core's library, loaded once per path */
static int load_core(const char* so)
{
  if (cc.dl && !strcmp(cc.dl_path, so)) return 1;
  if (cc.dl) {
    if (cc.inited && cc.api.deinit) cc.api.deinit();
    dlclose(cc.dl);
    cc.dl = NULL;
    cc.inited = 0;
  }
  memset(&cc.api, 0, sizeof cc.api);
  cc.dl = dlopen(so, RTLD_NOW | RTLD_LOCAL);
  if (!cc.dl) {
    const char* e = dlerror();
    ec_set_error(e ? e : "could not load the core");
    return 0;
  }
  snprintf(cc.dl_path, sizeof cc.dl_path, "%s", so);
  SYM(init); SYM(deinit); SYM(set_environment); SYM(set_video_refresh); SYM(set_audio_sample);
  SYM(set_audio_sample_batch); SYM(set_input_poll); SYM(set_input_state); SYM(get_system_info);
  SYM(get_system_av_info); SYM(load_game); SYM(unload_game); SYM(run); SYM(reset);
  SYM(serialize_size); SYM(serialize); SYM(unserialize); SYM(get_memory_data); SYM(get_memory_size);
  if (!cc.api.init || !cc.api.run || !cc.api.load_game || !cc.api.set_environment || !cc.api.get_system_info) {
    ec_set_error("not a libretro core");
    dlclose(cc.dl);
    cc.dl = NULL;
    return 0;
  }
  cc.api.set_environment(environment);
  cc.api.set_video_refresh(video_cb);
  if (cc.api.set_audio_sample) cc.api.set_audio_sample(audio_cb);
  if (cc.api.set_audio_sample_batch) cc.api.set_audio_sample_batch(audio_batch_cb);
  if (cc.api.set_input_poll) cc.api.set_input_poll(input_poll_cb);
  if (cc.api.set_input_state) cc.api.set_input_state(input_state_cb);
  cc.api.init();
  cc.inited = 1;
  return 1;
}

int ec_core_info(const char* so, char* name, int name_len, char* exts, int exts_len)
{
  if (!so || !load_core(so)) return 0;
  struct retro_system_info info;
  memset(&info, 0, sizeof info);
  cc.api.get_system_info(&info);
  if (name && name_len > 0)
    snprintf(name, (size_t)name_len, "%s %s", info.library_name ? info.library_name : "",
             info.library_version ? info.library_version : "");
  if (exts && exts_len > 0) snprintf(exts, (size_t)exts_len, "%s", info.valid_extensions ? info.valid_extensions : "");
  return 1;
}

int core_open(const char* so, const char* rom, const char* save, const char* sysdir)
{
  core_close();
  if (!load_core(so)) return 0;
  cc.fmt = RETRO_PIXEL_FORMAT_0RGB1555;
  snprintf(cc.sysdir, sizeof cc.sysdir, "%s", sysdir ? sysdir : "");
  snprintf(cc.save_path, sizeof cc.save_path, "%s", save ? save : "");
  /* the save folder, for cores that keep their own files there */
  snprintf(cc.savedir, sizeof cc.savedir, "%s", cc.save_path);
  char* slash = strrchr(cc.savedir, '/');
  if (slash) *slash = 0; else cc.savedir[0] = 0;
  struct retro_system_info info;
  memset(&info, 0, sizeof info);
  cc.api.get_system_info(&info);
  struct retro_game_info gi;
  memset(&gi, 0, sizeof gi);
  gi.path = rom;
  uint8_t* data = NULL;
  if (!info.need_fullpath) {
    size_t len = 0;
    data = read_all(rom, &len);
    if (!data) { ec_set_error("could not read the game"); return 0; }
    gi.data = data;
    gi.size = len;
  }
  cc.rd = cc.wr = 0;
  bool ok = cc.api.load_game(&gi);
  free(data);
  if (!ok) { ec_set_error("the core could not start this game"); return 0; }
  cc.open = 1;
  struct retro_system_av_info av;
  memset(&av, 0, sizeof av);
  if (cc.api.get_system_av_info) cc.api.get_system_av_info(&av);
  cc.fps = av.timing.fps > 1 ? av.timing.fps : 60.0;
  cc.rate = av.timing.sample_rate > 1000 ? (int)av.timing.sample_rate : 48000;
  uint8_t* mem = cc.api.get_memory_data ? (uint8_t*)cc.api.get_memory_data(RETRO_MEMORY_SAVE_RAM) : NULL;
  size_t memlen = cc.api.get_memory_size ? cc.api.get_memory_size(RETRO_MEMORY_SAVE_RAM) : 0;
  if (mem && memlen && cc.save_path[0]) {
    size_t slen = 0;
    uint8_t* s = read_all(cc.save_path, &slen);
    if (s) {
      memcpy(mem, s, slen < memlen ? slen : memlen);
      free(s);
    }
    cc.saved = (uint8_t*)malloc(memlen);
    if (cc.saved) { memcpy(cc.saved, mem, memlen); cc.saved_len = memlen; }
  }
  cc.keys = 0;
  return 1;
}

void core_close(void)
{
  if (!cc.open) return;
  core_flush();
  if (cc.api.unload_game) cc.api.unload_game();
  cc.open = 0;
  free(cc.saved);
  cc.saved = NULL;
  cc.saved_len = 0;
}

void core_set_keys(uint32_t pressed) { cc.keys = pressed; }
void core_run_frame(void) { if (cc.open) cc.api.run(); }

const uint8_t* core_screen(int* w, int* h)
{
  if (!cc.rgba) return NULL;
  *w = cc.w;
  *h = cc.h;
  return cc.rgba;
}

int core_audio(int16_t* out, int max_frames)
{
  uint32_t avail = (cc.wr - cc.rd) / 2;
  uint32_t n = avail < (uint32_t)max_frames ? avail : (uint32_t)max_frames;
  for (uint32_t i = 0; i < n * 2; i++) out[i] = cc.ring[cc.rd++ % RING_LEN];
  return (int)n;
}

int core_audio_rate(void) { return cc.rate ? cc.rate : 48000; }
double core_fps(void) { return cc.fps ? cc.fps : 60.0; }

void core_flush(void)
{
  if (!cc.open || !cc.saved || !cc.save_path[0] || !cc.api.get_memory_data) return;
  const uint8_t* mem = (const uint8_t*)cc.api.get_memory_data(RETRO_MEMORY_SAVE_RAM);
  if (!mem || memcmp(mem, cc.saved, cc.saved_len) == 0) return;
  if (write_all(cc.save_path, mem, cc.saved_len)) memcpy(cc.saved, mem, cc.saved_len);
}

int core_save_state(const char* path)
{
  if (!cc.open || !cc.api.serialize_size || !cc.api.serialize) return 0;
  size_t n = cc.api.serialize_size();
  if (!n) return 0;
  void* buf = malloc(n);
  if (!buf) return 0;
  int ok = cc.api.serialize(buf, n) && write_all(path, buf, n);
  free(buf);
  return ok;
}

int core_load_state(const char* path)
{
  if (!cc.open || !cc.api.unserialize) return 0;
  size_t n = 0;
  uint8_t* buf = read_all(path, &n);
  if (!buf) return 0;
  int ok = cc.api.unserialize(buf, n);
  free(buf);
  return ok;
}

void core_reset(void) { if (cc.open && cc.api.reset) cc.api.reset(); }
