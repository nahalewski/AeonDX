// emucore: one game at a time on the DS host or the Virtual Console host,
// settings, the ROM header reader and the user folder's file helpers.
#include <cerrno>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <vector>
#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>
#ifdef __ANDROID__
#include <android/log.h>
#endif

#include "emucore_internal.h"

namespace {
std::map<std::string, std::string> options;
std::string lastError;
int current = 0;   // EC_SYS_* running, 0 none
}

extern "C" {

// ---------------------------------------------------------------- common

int ec_version(void) { return 1; }

void ec_set_option(const char* key, const char* value)
{
    if (!key) return;
    if (!value) options.erase(key);
    else options[key] = value;
}

const char* ec_opt(const char* key, const char* def)
{
    auto it = options.find(key);
    return it == options.end() ? def : it->second.c_str();
}

int ec_opt_bool(const char* key, int def)
{
    auto it = options.find(key);
    if (it == options.end()) return def;
    const std::string& v = it->second;
    return v == "1" || v == "true" || v == "on" || v == "yes";
}

void ec_set_error(const char* msg) { lastError = msg ? msg : ""; }
const char* ec_error(void) { return lastError.c_str(); }

void ec_logv(const char* fmt, va_list ap)
{
#ifdef __ANDROID__
    __android_log_vprint(ANDROID_LOG_INFO, "emucore", fmt, ap);
#else
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
#endif
}

void ec_log(const char* fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    ec_logv(fmt, ap);
    va_end(ap);
}

// ---------------------------------------------------------------- the game

int ec_open(int sys, const char* rom, const char* save, const char* sysdir)
{
    ec_close();
    lastError.clear();
    if (!rom) { ec_set_error("no game"); return 0; }
    if (sysdir) options["sysdir"] = sysdir;
    int ok = 0;
    if (sys == EC_SYS_DS) ok = ds_open(rom, save, sysdir);
    else if (sys == EC_SYS_GB || sys == EC_SYS_GBC || sys == EC_SYS_GBA) ok = vc_open(sys, rom, save, sysdir);
    else ec_set_error("unknown system");
    current = ok ? sys : 0;
    return ok;
}

int ec_open_core(const char* core_so, const char* rom, const char* save, const char* sysdir)
{
    ec_close();
    lastError.clear();
    if (!core_so || !rom) { ec_set_error("no core or no game"); return 0; }
    if (sysdir) options["sysdir"] = sysdir;
    int ok = core_open(core_so, rom, save, sysdir);
    current = ok ? EC_SYS_CORE : 0;
    return ok;
}

void ec_close(void)
{
    if (current == EC_SYS_DS) ds_close();
    else if (current == EC_SYS_CORE) core_close();
    else if (current) vc_close();
    current = 0;
}

int ec_system(void) { return current; }

void ec_set_keys(uint32_t pressed)
{
    if (current == EC_SYS_DS) ds_set_keys(pressed);
    else if (current == EC_SYS_CORE) core_set_keys(pressed);
    else if (current) vc_set_keys(pressed);
}

void ec_touch(int down, int x, int y)
{
    if (current == EC_SYS_DS) ds_touch(down, x, y);
}

void ec_run_frame(void)
{
    if (current == EC_SYS_DS) ds_run_frame();
    else if (current == EC_SYS_CORE) core_run_frame();
    else if (current) vc_run_frame();
}

double ec_fps(void)
{
    if (current == EC_SYS_DS) return 59.8261;
    if (current == EC_SYS_CORE) return core_fps();
    if (current) return vc_fps();
    return 60.0;
}

int ec_screen_count(void) { return current == EC_SYS_DS ? 2 : current ? 1 : 0; }

const uint8_t* ec_screen(int idx, int* w, int* h)
{
    if (current == EC_SYS_DS) return ds_screen(idx, w, h);
    if (current == EC_SYS_CORE && idx == 0) return core_screen(w, h);
    if (current && idx == 0) return vc_screen(w, h);
    return nullptr;
}

int ec_audio_rate(void)
{
    if (current == EC_SYS_DS) return 48000;
    if (current == EC_SYS_CORE) return core_audio_rate();
    if (current) return vc_audio_rate();
    return 48000;
}

int ec_audio(int16_t* out, int max_frames)
{
    if (!out || max_frames <= 0) return 0;
    if (current == EC_SYS_DS) return ds_audio(out, max_frames);
    if (current == EC_SYS_CORE) return core_audio(out, max_frames);
    if (current) return vc_audio(out, max_frames);
    return 0;
}

void ec_flush(void)
{
    if (current == EC_SYS_DS) ds_flush(true);
    else if (current == EC_SYS_CORE) core_flush();
    else if (current) vc_flush();
}

int ec_save_state(const char* path)
{
    if (!path) return 0;
    if (current == EC_SYS_DS) return ds_save_state(path);
    if (current == EC_SYS_CORE) return core_save_state(path);
    if (current) return vc_save_state(path);
    return 0;
}

int ec_load_state(const char* path)
{
    if (!path) return 0;
    if (current == EC_SYS_DS) return ds_load_state(path);
    if (current == EC_SYS_CORE) return core_load_state(path);
    if (current) return vc_load_state(path);
    return 0;
}

void ec_reset(void)
{
    if (current == EC_SYS_DS) ds_reset();
    else if (current == EC_SYS_CORE) core_reset();
    else if (current) vc_reset();
}

} // extern "C"

// ---------------------------------------------------------------- ROM headers

namespace {

uint32_t crcTable[256];

void crcInit()
{
    static bool done = false;
    if (done) return;
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
        crcTable[i] = c;
    }
    done = true;
}

uint32_t crcFile(FILE* f)
{
    crcInit();
    uint32_t c = 0xFFFFFFFFu;
    std::vector<unsigned char> buf(1 << 16);
    fseek(f, 0, SEEK_SET);
    size_t n;
    while ((n = fread(buf.data(), 1, buf.size(), f)) > 0)
        for (size_t i = 0; i < n; i++) c = crcTable[(c ^ buf[i]) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFFu;
}

uint32_t le32(const unsigned char* p) { return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24); }
uint16_t le16(const unsigned char* p) { return (uint16_t)(p[0] | (p[1] << 8)); }

// printable ASCII only, trimmed
void copyText(char* out, int outLen, const unsigned char* src, int n)
{
    if (!out || outLen <= 0) return;
    int k = 0;
    for (int i = 0; i < n && k < outLen - 1; i++) {
        unsigned char c = src[i];
        if (c == 0) break;
        out[k++] = (c >= 0x20 && c < 0x7F) ? (char)c : ' ';
    }
    while (k > 0 && out[k - 1] == ' ') k--;
    out[k] = 0;
}

// a DS banner title (UTF-16, lines split by '\n'): its first line as UTF-8
void bannerTitle(char* out, int outLen, const unsigned char* t)
{
    if (!out || outLen <= 0) return;
    int k = 0;
    for (int i = 0; i < 128; i++) {
        uint32_t c = le16(t + i * 2);
        if (c == 0 || c == '\n') break;
        if (c >= 0xD800 && c < 0xE000) continue;
        char tmp[4];
        int n;
        if (c < 0x80) { tmp[0] = (char)c; n = 1; }
        else if (c < 0x800) { tmp[0] = (char)(0xC0 | (c >> 6)); tmp[1] = (char)(0x80 | (c & 0x3F)); n = 2; }
        else { tmp[0] = (char)(0xE0 | (c >> 12)); tmp[1] = (char)(0x80 | ((c >> 6) & 0x3F)); tmp[2] = (char)(0x80 | (c & 0x3F)); n = 3; }
        if (k + n >= outLen) break;
        memcpy(out + k, tmp, n);
        k += n;
    }
    out[k] = 0;
}

// the banner's 32 x 32 icon: 4 x 4 tiles of 8 x 8, 4 bits a pixel, a
// 16-colour BGR555 palette whose first colour is see-through
void bannerIcon(uint8_t* rgba, const unsigned char* bmp, const unsigned char* pal)
{
    for (int ty = 0; ty < 4; ty++)
        for (int tx = 0; tx < 4; tx++)
            for (int y = 0; y < 8; y++)
                for (int x = 0; x < 8; x++) {
                    int byte = bmp[(ty * 4 + tx) * 32 + y * 4 + x / 2];
                    int idx = (x & 1) ? (byte >> 4) : (byte & 0xF);
                    uint16_t c = le16(pal + idx * 2);
                    uint8_t* d = rgba + ((ty * 8 + y) * 32 + tx * 8 + x) * 4;
                    d[0] = (uint8_t)(((c & 0x1F) * 255) / 31);
                    d[1] = (uint8_t)((((c >> 5) & 0x1F) * 255) / 31);
                    d[2] = (uint8_t)((((c >> 10) & 0x1F) * 255) / 31);
                    d[3] = idx == 0 ? 0 : 255;
                }
}

const unsigned char GB_LOGO[4] = { 0xCE, 0xED, 0x66, 0x66 };
const unsigned char GBA_LOGO[4] = { 0x24, 0xFF, 0xAE, 0x51 };

} // namespace

extern "C" int ec_rom_info(const char* path, char* title, int title_len, char* code, int code_len,
                           uint32_t* crc, uint8_t* icon_rgba)
{
    if (title && title_len > 0) title[0] = 0;
    if (code && code_len > 0) code[0] = 0;
    if (crc) *crc = 0;
    FILE* f = fopen(path, "rb");
    if (!f) return 0;
    unsigned char h[0x200];
    size_t n = fread(h, 1, sizeof h, f);
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    int sys = 0;
    if (n >= 0x180 && memcmp(h + 0x104, GB_LOGO, 4) == 0) {
        sys = (h[0x143] & 0x80) ? EC_SYS_GBC : EC_SYS_GB;
        // the newer carts end the title early for a maker code
        int tl = (h[0x143] & 0x80) ? 11 : 16;
        copyText(title, title_len, h + 0x134, tl);
        if (sys == EC_SYS_GBC && h[0x13F] >= 'A' && h[0x13F] <= 'Z') copyText(code, code_len, h + 0x13F, 4);
    } else if (n >= 0xC0 && memcmp(h + 0x04, GBA_LOGO, 4) == 0 && h[0xB2] == 0x96) {
        sys = EC_SYS_GBA;
        copyText(title, title_len, h + 0xA0, 12);
        copyText(code, code_len, h + 0xAC, 4);
    } else if (n >= 0x170 && size >= 0x4000 && le16(h + 0x15C) == 0xCF56) {
        // a DS game: the header's copy of the logo checksums to 0xCF56
        sys = EC_SYS_DS;
        copyText(title, title_len, h, 12);
        copyText(code, code_len, h + 0x0C, 4);
        uint32_t banner = le32(h + 0x68);
        if (banner && banner + 0x440 <= (uint32_t)size) {
            unsigned char b[0x440];
            fseek(f, (long)banner, SEEK_SET);
            if (fread(b, 1, sizeof b, f) == sizeof b) {
                char name[256];
                bannerTitle(name, sizeof name, b + 0x340);          // English
                if (!name[0]) bannerTitle(name, sizeof name, b + 0x240);  // Japanese
                if (name[0] && title && title_len > 0) {
                    strncpy(title, name, title_len - 1);
                    title[title_len - 1] = 0;
                }
                if (icon_rgba) bannerIcon(icon_rgba, b + 0x20, b + 0x220);
            }
        }
    }
    // the whole file's CRC32 names a GB / GBC / GBA dump in No-Intro's list
    // (a DS game is named by its game code instead)
    if (crc && sys && sys != EC_SYS_DS) *crc = crcFile(f);
    fclose(f);
    return sys;
}

// ---------------------------------------------------------------- the user folder

extern "C" int ec_mkdirs(const char* path)
{
    if (!path || !path[0]) return 0;
    std::string p = path;
    for (size_t i = 1; i <= p.size(); i++) {
        if (i == p.size() || p[i] == '/') {
            std::string part = p.substr(0, i);
            if (mkdir(part.c_str(), 0775) != 0 && errno != EEXIST) return 0;
        }
    }
    return 1;
}

extern "C" int ec_list(const char* dir, char* out, int out_len)
{
    DIR* d = opendir(dir);
    if (!d) return -1;
    int k = 0;
    struct dirent* e;
    while ((e = readdir(d)) != nullptr) {
        if (e->d_name[0] == '.') continue;
        std::string full = std::string(dir) + "/" + e->d_name;
        struct stat st;
        bool isDir = stat(full.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
        size_t len = strlen(e->d_name);
        if (k + (int)len + 3 > out_len) break;
        memcpy(out + k, e->d_name, len);
        k += (int)len;
        if (isDir) out[k++] = '/';
        out[k++] = '\n';
    }
    closedir(d);
    if (k < out_len) out[k] = 0;
    return k;
}

extern "C" int ec_copy(const char* from, const char* to)
{
    FILE* in = fopen(from, "rb");
    if (!in) return 0;
    std::string tmp = std::string(to) + ".part";
    FILE* out = fopen(tmp.c_str(), "wb");
    if (!out) { fclose(in); return 0; }
    std::vector<char> buf(1 << 16);
    size_t n;
    bool ok = true;
    while ((n = fread(buf.data(), 1, buf.size(), in)) > 0)
        if (fwrite(buf.data(), 1, n, out) != n) { ok = false; break; }
    fclose(in);
    ok = fclose(out) == 0 && ok;
    if (!ok || rename(tmp.c_str(), to) != 0) { unlink(tmp.c_str()); return 0; }
    return 1;
}

extern "C" int ec_remove(const char* path) { return path && unlink(path) == 0; }
