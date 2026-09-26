/* The Virtual Console: Game Boy, Game Boy Color and Game Boy Advance games
 * on SkyEmu's cores, through SkyEmu's libretro build (libretro.c, linked in
 * whole), with this file as its frontend.
 *
 * The save memory is read from the save file after the game loads and
 * written back (ec_flush) when it changed.  BIOS files, when the setting
 * asks for them, come from <system folder>/SkyEmu/ (gb_bios.bin,
 * gbc_bios.bin, gba_bios.bin); otherwise SkyEmu's own start-up stands in. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libretro.h"
#include "emucore_internal.h"

#define SIO_QUEUE_CAPACITY 2048
#define SIO_EVENT_SIZE 5

typedef struct {
  uint8_t bytes[SIO_QUEUE_CAPACITY];
  unsigned read_at;
  unsigned write_at;
  unsigned count;
} sio_queue_t;

static struct {
  int open;
  int sys;
  char sysdir[1024];
  char save_path[1024];
  uint8_t* saved;           /* the save memory as last written */
  size_t saved_len;
  uint32_t keys;
  uint8_t* rgba;
  int w, h;
  double fps;
  int rate;
  int16_t ring[65536];      /* stereo frames, interleaved */
  uint32_t rd, wr;          /* in samples, wrapping */
  sio_queue_t sio_tx;
  sio_queue_t sio_rx;
  uint32_t sio_dropped;
  int sio_enabled;
} vc;

#define RING_LEN (sizeof vc.ring / sizeof vc.ring[0])

static void sio_queue_clear(sio_queue_t* queue)
{
  queue->read_at = 0;
  queue->write_at = 0;
  queue->count = 0;
}

static int sio_queue_write(sio_queue_t* queue, const uint8_t* data, unsigned length)
{
  if (length > SIO_QUEUE_CAPACITY - queue->count) return 0;
  for (unsigned i = 0; i < length; i++) {
    queue->bytes[queue->write_at] = data[i];
    queue->write_at = (queue->write_at + 1) % SIO_QUEUE_CAPACITY;
  }
  queue->count += length;
  return 1;
}

static int sio_queue_read(sio_queue_t* queue, uint8_t* data, unsigned capacity)
{
  unsigned length = queue->count < capacity ? queue->count : capacity;
  for (unsigned i = 0; i < length; i++) {
    data[i] = queue->bytes[queue->read_at];
    queue->read_at = (queue->read_at + 1) % SIO_QUEUE_CAPACITY;
  }
  queue->count -= length;
  return (int)length;
}

static void sio_reset(void)
{
  sio_queue_clear(&vc.sio_tx);
  sio_queue_clear(&vc.sio_rx);
  vc.sio_dropped = 0;
}

void ec_gba_sio_set_enabled(int enabled)
{
  vc.sio_enabled = enabled != 0;
  sio_reset();
}

int ec_gba_sio_read_tx(uint8_t* out, int capacity)
{
  if (!out || capacity <= 0) return 0;
  return sio_queue_read(&vc.sio_tx, out, (unsigned)capacity);
}

int ec_gba_sio_write_rx(const uint8_t* data, int length)
{
  if (!data || length <= 0) return 0;
  if (!sio_queue_write(&vc.sio_rx, data, (unsigned)length)) {
    ++vc.sio_dropped;
    return 0;
  }
  return length;
}

uint32_t ec_gba_sio_dropped(void)
{
  return vc.sio_dropped;
}

uint8_t ec_gba_sio_transfer(uint8_t tx, uint16_t siocnt, uint16_t rcnt)
{
  if (!vc.open || vc.sys != EC_SYS_GBA || !vc.sio_enabled) return 0xff;

  const uint8_t event[SIO_EVENT_SIZE] = {
    tx,
    (uint8_t)(siocnt & 0xff), (uint8_t)(siocnt >> 8),
    (uint8_t)(rcnt & 0xff), (uint8_t)(rcnt >> 8),
  };
  if (!sio_queue_write(&vc.sio_tx, event, sizeof(event))) ++vc.sio_dropped;

  uint8_t rx = 0xff;
  (void)sio_queue_read(&vc.sio_rx, &rx, 1);
  return rx;
}

static void RETRO_CALLCONV log_cb(enum retro_log_level level, const char* fmt, ...)
{
  if (level < RETRO_LOG_WARN) return;
  va_list ap;
  va_start(ap, fmt);
  ec_logv(fmt, ap);
  va_end(ap);
}

/* SkyEmu's options: the core follows the file's system; BIOS files only when
 * asked for (Settings > Virtual Console > BIOS) */
static const char* variable(const char* key)
{
  if (!strcmp(key, "system_core_override")) {
    if (vc.sys == EC_SYS_GBA) return "Game Boy Advance";
    if (vc.sys == EC_SYS_GB || vc.sys == EC_SYS_GBC) return "Game Boy";
    return "Automatic";
  }
  if (!strcmp(key, "system_gb_bios_enable") || !strcmp(key, "system_gba_bios_enable") ||
      !strcmp(key, "system_nds_bios_enable"))
    return ec_opt_bool("vc.bios", 0) ? "ON" : "OFF";
  return "";
}

static bool RETRO_CALLCONV environment(unsigned cmd, void* data)
{
  switch (cmd) {
    case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
      ((struct retro_log_callback*)data)->log = log_cb;
      return true;
    case RETRO_ENVIRONMENT_GET_VARIABLE: {
      struct retro_variable* v = (struct retro_variable*)data;
      v->value = variable(v->key ? v->key : "");
      return true;
    }
    case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
      *(const char**)data = vc.sysdir[0] ? vc.sysdir : NULL;
      return vc.sysdir[0] != 0;
    case RETRO_ENVIRONMENT_GET_AUDIO_VIDEO_ENABLE:
      *(int*)data = 3;
      return true;
    case RETRO_ENVIRONMENT_GET_LANGUAGE:
      *(unsigned*)data = RETRO_LANGUAGE_ENGLISH;
      return true;
    case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
      return *(const enum retro_pixel_format*)data == RETRO_PIXEL_FORMAT_XRGB8888;
    default:
      return false;
  }
}

static void RETRO_CALLCONV video_cb(const void* data, unsigned width, unsigned height, size_t pitch)
{
  if (!data || !width || !height) return;
  if ((int)width != vc.w || (int)height != vc.h || !vc.rgba) {
    free(vc.rgba);
    vc.rgba = (uint8_t*)malloc((size_t)width * height * 4);
    if (!vc.rgba) return;
    vc.w = (int)width;
    vc.h = (int)height;
  }
  for (unsigned y = 0; y < height; y++) {
    const uint32_t* src = (const uint32_t*)((const uint8_t*)data + y * pitch);
    uint8_t* d = vc.rgba + (size_t)y * width * 4;
    for (unsigned x = 0; x < width; x++) {
      uint32_t p = src[x];                 /* 0x00RRGGBB */
      d[x * 4 + 0] = (uint8_t)(p >> 16);
      d[x * 4 + 1] = (uint8_t)(p >> 8);
      d[x * 4 + 2] = (uint8_t)p;
      d[x * 4 + 3] = 255;
    }
  }
}

static void RETRO_CALLCONV audio_cb(int16_t left, int16_t right)
{
  vc.ring[vc.wr++ % RING_LEN] = left;
  vc.ring[vc.wr++ % RING_LEN] = right;
}

static size_t RETRO_CALLCONV audio_batch_cb(const int16_t* data, size_t frames)
{
  for (size_t i = 0; i < frames * 2; i++) vc.ring[vc.wr++ % RING_LEN] = data[i];
  /* more than the ring holds: the oldest goes */
  if (vc.wr - vc.rd > RING_LEN) vc.rd = vc.wr - RING_LEN;
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
  if (id >= sizeof map / sizeof map[0]) return 0;
  return (vc.keys & map[id]) ? 1 : 0;
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

static int registered;

int vc_open(int sys, const char* rom, const char* save, const char* sysdir)
{
  vc_close();
  sio_reset();
  vc.sio_enabled = 0;
  if (!registered) {
    retro_set_environment(environment);
    retro_set_video_refresh(video_cb);
    retro_set_audio_sample(audio_cb);
    retro_set_audio_sample_batch(audio_batch_cb);
    retro_set_input_poll(input_poll_cb);
    retro_set_input_state(input_state_cb);
    retro_init();
    registered = 1;
  }
  vc.sys = sys;
  snprintf(vc.sysdir, sizeof vc.sysdir, "%s", sysdir ? sysdir : "");
  snprintf(vc.save_path, sizeof vc.save_path, "%s", save ? save : "");
  size_t len = 0;
  uint8_t* data = read_all(rom, &len);
  if (!data) { ec_set_error("could not read the game"); return 0; }
  /* the core picks its system by the extension, in lower case */
  const char* fake = sys == EC_SYS_GBA ? "game.gba" : sys == EC_SYS_GBC ? "game.gbc" : "game.gb";
  struct retro_game_info info = { fake, data, len, "" };
  vc.rd = vc.wr = 0;
  bool ok = retro_load_game(&info);
  free(data);
  if (!ok) { ec_set_error("not a game this can play"); return 0; }
  vc.open = 1;
  struct retro_system_av_info av;
  memset(&av, 0, sizeof av);
  retro_get_system_av_info(&av);
  vc.fps = av.timing.fps > 1 ? av.timing.fps : 59.7275;
  vc.rate = av.timing.sample_rate > 1000 ? (int)av.timing.sample_rate : 48000;
  /* the save file into the cart's memory */
  uint8_t* mem = (uint8_t*)retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
  size_t memlen = retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);
  if (mem && memlen && vc.save_path[0]) {
    size_t slen = 0;
    uint8_t* s = read_all(vc.save_path, &slen);
    if (s) {
      memcpy(mem, s, slen < memlen ? slen : memlen);
      free(s);
    }
    vc.saved = (uint8_t*)malloc(memlen);
    if (vc.saved) { memcpy(vc.saved, mem, memlen); vc.saved_len = memlen; }
  }
  vc.keys = 0;
  return 1;
}

void vc_close(void)
{
  vc.sio_enabled = 0;
  sio_reset();
  if (!vc.open) return;
  vc_flush();
  retro_unload_game();
  vc.open = 0;
  free(vc.saved);
  vc.saved = NULL;
  vc.saved_len = 0;
}

void vc_set_keys(uint32_t pressed) { vc.keys = pressed; }

void vc_run_frame(void)
{
  if (vc.open) retro_run();
}

const uint8_t* vc_screen(int* w, int* h)
{
  if (!vc.rgba) return NULL;
  *w = vc.w;
  *h = vc.h;
  return vc.rgba;
}

int vc_audio(int16_t* out, int max_frames)
{
  uint32_t avail = (vc.wr - vc.rd) / 2;
  uint32_t n = avail < (uint32_t)max_frames ? avail : (uint32_t)max_frames;
  for (uint32_t i = 0; i < n * 2; i++) out[i] = vc.ring[vc.rd++ % RING_LEN];
  return (int)n;
}

int vc_audio_rate(void) { return vc.rate ? vc.rate : 48000; }
double vc_fps(void) { return vc.fps ? vc.fps : 59.7275; }

/* the cart's save memory to its file when it differs from the last write */
void vc_flush(void)
{
  if (!vc.open || !vc.saved || !vc.save_path[0]) return;
  const uint8_t* mem = (const uint8_t*)retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
  if (!mem || memcmp(mem, vc.saved, vc.saved_len) == 0) return;
  if (write_all(vc.save_path, mem, vc.saved_len)) memcpy(vc.saved, mem, vc.saved_len);
}

int vc_save_state(const char* path)
{
  if (!vc.open) return 0;
  size_t n = retro_serialize_size();
  if (!n) return 0;
  void* buf = malloc(n);
  if (!buf) return 0;
  int ok = retro_serialize(buf, n) && write_all(path, buf, n);
  free(buf);
  return ok;
}

int vc_load_state(const char* path)
{
  if (!vc.open) return 0;
  size_t n = 0;
  uint8_t* buf = read_all(path, &n);
  if (!buf) return 0;
  int ok = retro_unserialize(buf, n);
  free(buf);
  return ok;
}

void vc_reset(void)
{
  if (vc.open) retro_reset();
  sio_reset();
}
