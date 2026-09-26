-- The HOME menu's own emulators, the data side: DS games on the melonDS
-- core and Game Boy / Game Boy Color / Game Boy Advance games on SkyEmu's
-- cores (the Virtual Console).  The cores are libemucore.so (emu/native),
-- reached through LuaJIT's FFI.  fold3ds/melonds.lua and fold3ds/vc.lua are
-- their providers for fold3ds/emus.lua; the 3DS UI session draws all of it
-- from the functions under "for the UI".
--
--   * the user folder, as Azahar keeps its own: <shared storage>/<NAME>/
--       config/settings.ini   every setting (the folders' pages)
--       games/                the games: .nds, .gb, .gbc, .gba (sub-folders too)
--       saves/                each game's save, <game>.sav
--       states/               save states, <game>.state
--       bios/                 optional: bios7.bin, bios9.bin, firmware.bin
--                             (DS), SkyEmu/gb_bios.bin, gbc_bios.bin,
--                             gba_bios.bin (Virtual Console)
--     Without the all-files permission it is the app's own folder instead.
--   * the library: every game in games/ is a tile, named from its header
--     and fold3ds/emudb (No-Intro's names, tools/make_emudb.py); a DS game
--     has its own banner icon, a Virtual Console game its box art;
--   * art, fetched once on the phone into the save folder (emu_cache/):
--     box art from libretro-thumbnails, DS cards / covers from GameTDB;
--     a game's border (The Bezel Project) only when it starts;
--   * playing: update(dt) runs the frames due, screen(i) is the picture,
--     press / release / touch the input, HOME the pause menu (save / load
--     state, reset, screen shape, close).
--
-- E.NAME is the root folder name: AeonDX
local E = {}

E.NAME = "AeonDX"
local AeonDX = require("fold3ds.aeondx")
local Cores = require("fold3ds.cores")

local lg = love.graphics
local ffi
do
  local ok, f = pcall(require, "ffi")
  if ok then ffi = f end
end

local SYS = { gb = 1, gbc = 2, gba = 3, ds = 4 }
local SYS_NAME = { [1] = "gb", [2] = "gbc", [3] = "gba", [4] = "ds" }
local SYS_LABEL = {
  gb = "Virtual Console  -  Game Boy", gbc = "Virtual Console  -  Game Boy Color",
  gba = "Virtual Console  -  Game Boy Advance", ds = "Nintendo DS",
  nes = "Virtual Console  -  NES", snes = "Virtual Console  -  Super NES",
  vb = "Virtual Console  -  Virtual Boy", pokemini = "Virtual Console  -  Pokemon mini",
  gw = "Virtual Console  -  Game & Watch",
}
-- the systems played on a downloaded core (fold3ds/cores.lua): their games are
-- found by the installed cores' extensions and started with ec_open_core
local CORE_SYS = { nes = true, snes = true, vb = true, pokemini = true, gw = true }
local EXT = { nds = "ds", dsi = "ds", gb = "gb", gbc = "gbc", cgb = "gbc", gba = "gba", agb = "gba" }
-- libretro-thumbnails' folders, and the name index per system
local THUMBS = {
  gb = "Nintendo_-_Game_Boy", gbc = "Nintendo_-_Game_Boy_Color",
  gba = "Nintendo_-_Game_Boy_Advance", ds = "Nintendo_-_Nintendo_DS",
  nes = "Nintendo_-_Nintendo_Entertainment_System", snes = "Nintendo_-_Super_Nintendo_Entertainment_System",
  vb = "Nintendo_-_Virtual_Boy", pokemini = "Nintendo_-_Pokemon_Mini", gw = "Handheld_Electronic_Game",
}
local DB = { gb = "gb", gbc = "gbc", gba = "gba", ds = "nds" }
-- the real shells' colours (a game's own colour is mixed in from its art)
local SHELL = { gb = { 150, 152, 160 }, gbc = { 60, 60, 66 }, gba = { 110, 90, 200 }, ds = { 70, 72, 78 },
  nes = { 180, 180, 176 }, snes = { 160, 160, 170 }, vb = { 150, 30, 30 }, pokemini = { 60, 110, 200 },
  gw = { 170, 150, 110 } }

local KEY = { a = 1, b = 2, select = 4, start = 8, right = 16, left = 32, up = 64, down = 128,
              r = 256, l = 512, x = 1024, y = 2048 }

local CACHE = "emu_cache/"

-- POKEPORT_FOLD_FAKEEMU=1: no core needed -- a few made-up DS, GB, GBC and
-- GBA games whose screens are test patterns (for building the UI on a PC)
local FAKE = os.getenv and os.getenv("POKEPORT_FOLD_FAKEEMU") == "1"

---------------------------------------------------------------- the core

local C, loadError
local CDEF = [[
int ec_version(void);
void ec_set_option(const char* key, const char* value);
int ec_open(int sys, const char* rom, const char* save, const char* sysdir);
int ec_open_core(const char* core_so, const char* rom, const char* save, const char* sysdir);
int ec_core_info(const char* core_so, char* name, int name_len, char* exts, int exts_len);
void ec_close(void);
int ec_system(void);
const char* ec_error(void);
void ec_set_keys(uint32_t pressed);
void ec_touch(int down, int x, int y);
void ec_run_frame(void);
double ec_fps(void);
int ec_screen_count(void);
const uint8_t* ec_screen(int idx, int* w, int* h);
int ec_audio_rate(void);
int ec_audio(int16_t* out, int max_frames);
void ec_flush(void);
int ec_save_state(const char* path);
int ec_load_state(const char* path);
void ec_reset(void);
void ec_gba_sio_set_enabled(int enabled);
int ec_gba_sio_read_tx(uint8_t* out, int capacity);
int ec_gba_sio_write_rx(const uint8_t* data, int length);
uint32_t ec_gba_sio_dropped(void);
int ec_rom_info(const char* path, char* title, int title_len, char* code, int code_len, uint32_t* crc, uint8_t* icon_rgba);
int ec_mkdirs(const char* path);
int ec_list(const char* dir, char* out, int out_len);
int ec_copy(const char* from, const char* to);
int ec_remove(const char* path);
]]

local function core()
  if C ~= nil then return C or nil end
  C = false
  if not ffi then loadError = "no FFI" return nil end
  pcall(ffi.cdef, CDEF)
  local tries = { "emucore", "libemucore.so" }
  local env = os.getenv and os.getenv("EMUCORE_LIB")
  if env then table.insert(tries, 1, env) end
  -- next to liblove.so (the app's own library folder)
  local maps = io.open("/proc/self/maps", "r")
  if maps then
    for line in maps:lines() do
      local dir = line:match("(/%S+)/liblove%.so$")
      if dir then tries[#tries + 1] = dir .. "/libemucore.so" break end
    end
    maps:close()
  end
  for _, name in ipairs(tries) do
    local ok, lib = pcall(ffi.load, name)
    if ok and lib then
      local okv, v = pcall(function() return lib.ec_version() end)
      if okv and v >= 1 then C = lib return C end
    end
    loadError = tostring(lib)
  end
  return nil
end

function E.available() return FAKE or core() ~= nil end
function E.fake() return FAKE end

---------------------------------------------------------------- the bridge (Java)

local function bridge(cmd, arg)
  local f = love.system and love.system.foldCamera
  if not f then return nil end
  local ok, r = pcall(f, "call", cmd, arg or "")
  return ok and r or nil
end

local function android() return love.system.getOS() == "Android" end

-- download url into the save folder's file (in the background, once)
function E.fetch(url, file)
  if love.filesystem.getInfo(file) or love.filesystem.getInfo(file .. ".fail") then return end
  local dir = file:match("^(.*)/[^/]*$")
  if dir then love.filesystem.createDirectory(dir) end
  bridge("fetch", url .. "|" .. love.filesystem.getSaveDirectory() .. "/" .. file)
end

local function urlencode(s)
  return (s:gsub("[^%w%-%._~]", function(c) return ("%%%02X"):format(c:byte()) end))
end

---------------------------------------------------------------- the user folder

local st = {
  root = nil,            -- the user folder (a path)
  settings = {},
  games = {},            -- the library's tiles, sorted by name
  byKey = {},
  scanned = false,
  scanAt = -1,
  images = {},
  names = {},            -- system -> { crc / code -> No-Intro name }
  running = nil,         -- the playing game's tile
}

-- the settings: key -> default (every page's rows are these)
E.DEFAULTS = {
  ["screen.smooth"] = "0",           -- 1: smoothed pixels
  ["screen.swap"] = "0",             -- DS: the touch screen on top
  ["border.style"] = "game",         -- game | system
  ["audio.volume"] = "100",
  ["audio.mute"] = "0",
  ["speed.fast"] = "3",              -- ZR held: this many times as fast
  ["controls.gba_xy"] = "1",         -- GBA: X / Y are R / L too
  ["ds.nickname"] = "Player",
  ["ds.message"] = "",
  ["ds.language"] = "1",
  ["ds.color"] = "0",
  ["ds.birth_month"] = "1",
  ["ds.birth_day"] = "1",
  ["ds.real_bios"] = "1",
  ["ds.boot_menu"] = "0",
  ["ds.jit"] = "1",
  ["ds.jit_block"] = "32",
  ["ds.threaded_3d"] = "1",
  ["ds.audio_interp"] = "1",
  ["vc.bios"] = "0",
  ["art.download"] = "1",
}

function E.get(key)
  local v = st.settings[key]
  if v == nil then v = E.DEFAULTS[key] end
  return v
end
function E.getNum(key) return tonumber(E.get(key)) or 0 end
function E.getBool(key) return E.get(key) == "1" end

local function path(...)
  return table.concat({ st.root, ... }, "/")
end

local function readText(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function writeText(p, s)
  local f = io.open(p .. ".part", "wb")
  if not f then return false end
  f:write(s)
  f:close()
  return os.rename(p .. ".part", p)
end

local function saveSettings()
  if not st.root then return end
  local keys = {}
  for k in pairs(st.settings) do keys[#keys + 1] = k end
  table.sort(keys)
  local out = { "; " .. E.NAME .. " settings (the HOME menu's " .. E.NAME .. " folder writes this)" }
  for _, k in ipairs(keys) do out[#out + 1] = k .. "=" .. tostring(st.settings[k]) end
  writeText(path("config", "settings.ini"), table.concat(out, "\n") .. "\n")
end

function E.set(key, value)
  st.settings[key] = tostring(value)
  saveSettings()
end

local function loadSettings()
  st.settings = {}
  local text = st.root and readText(path("config", "settings.ini")) or nil
  for line in (text or ""):gmatch("[^\r\n]+") do
    local k, v = line:match("^%s*([%w%._]+)%s*=%s*(.-)%s*$")
    if k then st.settings[k] = v end
  end
end

-- where the user folder is: shared storage when the app may use it, else
-- the app's own folder (no permission needed, but harder to reach)
local function pickRoot()
  local custom = st.settings and st.settings["root.dir"]
  local root = AeonDX.pickRoot(custom)
  local lib = core()
  if lib then
    for _, dir in ipairs(AeonDX.getAllScanDirs()) do
      lib.ec_mkdirs(dir)
    end
    for _, emu in ipairs({ "azahar", "melonds", "vc", "eden" }) do
      lib.ec_mkdirs(root .. "/" .. emu .. "/data/config")
      lib.ec_mkdirs(root .. "/" .. emu .. "/data/saves")
      lib.ec_mkdirs(root .. "/" .. emu .. "/data/states")
      lib.ec_mkdirs(root .. "/" .. emu .. "/data/bios")
    end
  end
  if st.root ~= root then
    st.root = root
    loadSettings()
    st.scanned = false
  end
end

function E.root() pickRoot() return st.root end
function E.setRoot(dir)
  if dir and dir ~= "" then
    E.set("root.dir", dir)
    st.root = nil
    pickRoot()
  end
end
function E.sharedOk() return FAKE or not android() or bridge("files.ok") == "1" end
function E.askShared() return bridge("files.ask") end

---------------------------------------------------------------- the library

local function list(dir)
  local lib = core()
  if not lib then return {} end
  local buf = ffi.new("char[?]", 65536)
  local n = lib.ec_list(dir, buf, 65536)
  if n < 0 then return {} end
  local out = {}
  for name in ffi.string(buf, n):gmatch("[^\n]+") do out[#out + 1] = name end
  return out
end

-- the No-Intro names for a system (fold3ds/emudb/<db>.tsv)
local function nameFor(sys, key)
  local db = DB[sys]
  if not db or not key or key == "" then return nil end
  if not st.names[db] then
    local t = {}
    local ok, text = pcall(love.filesystem.read, "fold3ds/emudb/" .. db .. ".tsv")
    if ok and text then
      for k, v in text:gmatch("([^\t\n]+)\t([^\n]+)") do t[k] = v end
    end
    st.names[db] = t
  end
  return st.names[db][key]
end

local function fnv(s)
  local h = 2166136261
  for i = 1, #s do
    h = bit.bxor(h, s:byte(i))
    h = (h * 16777619) % 4294967296
  end
  return ("%08x"):format(h)
end

-- the game's name without No-Intro's tags: "Pokemon - Emerald Version"
local function shortName(n)
  return (n:gsub("%s*%b()", ""):gsub("%s+$", ""))
end

-- a library entry from a file; its header read once (emu_cache/library.tsv)
local cacheLines
local function cached(file)
  if not cacheLines then
    cacheLines = {}
    local ok, text = pcall(love.filesystem.read, CACHE .. "library.tsv")
    for line in (ok and text or ""):gmatch("[^\n]+") do
      local f = {}
      for field in (line .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = field end
      if f[1] then cacheLines[f[1]] = f end
    end
  end
  return cacheLines[file]
end

local function saveCache()
  local out = {}
  for _, f in pairs(cacheLines or {}) do out[#out + 1] = table.concat(f, "\t") end
  love.filesystem.createDirectory(CACHE)
  pcall(love.filesystem.write, CACHE .. "library.tsv", table.concat(out, "\n") .. "\n")
end

local function readHeader(file, ext)
  local lib = core()
  local f = cached(file)
  if f then return f end
  local title = ffi.new("char[256]")
  local code = ffi.new("char[16]")
  local crc = ffi.new("uint32_t[1]")
  local icon = ffi.new("uint8_t[4096]")
  local sysn = lib.ec_rom_info(file, title, 256, code, 16, crc, icon)
  local sys = SYS_NAME[sysn] or EXT[ext] or Cores.extensions()[ext]
  local key = fnv(file)
  local hasIcon = "0"
  if sys == "ds" and sysn == SYS.ds then
    -- the banner's icon, kept as a PNG for the tiles
    local ok = pcall(function()
      local d = love.image.newImageData(32, 32, "rgba8")
      ffi.copy(d:getFFIPointer(), icon, 4096)
      love.filesystem.createDirectory(CACHE .. "icons")
      d:encode("png", CACHE .. "icons/" .. key .. ".png")
    end)
    if ok then hasIcon = "1" end
  end
  f = { file, sys or "", ffi.string(title), ffi.string(code), ("%08X"):format(crc[0]), hasIcon, key }
  cacheLines[file] = f
  return f
end

local function scan()
  local lib = core()
  if not lib then st.games, st.byKey = {}, {} return end
  pickRoot()
  local games, byKey = {}, {}
  local changed = false
  local coreExt = Cores.extensions()
  local function walk(dir, depth)
    for _, name in ipairs(list(dir)) do
      if name:sub(-1) == "/" then
        if depth < 2 then walk(dir .. "/" .. name:sub(1, -2), depth + 1) end
      else
        local ext = (name:match("%.(%w+)$") or ""):lower()
        if EXT[ext] or coreExt[ext] then
          local file = dir .. "/" .. name
          local had = cached(file) ~= nil
          local h = readHeader(file, ext)
          if not had then changed = true end
          local sys = h[2]
          if sys ~= "" then
            local nointro = nameFor(sys, sys == "ds" and h[4] or h[5])
            local base = name:gsub("%.%w+$", "")
            local t = {
              id = (sys == "ds" and "nds_" or "vc_") .. h[7], key = h[7], core = true, sys = sys,
              system = sys == "ds" and "nds" or sys, file = file, base = base,
              code = h[4], crc = h[5], hasIcon = h[6] == "1", nointro = nointro,
              name = nointro and shortName(nointro) or (h[3] ~= "" and h[3]) or base,
              sub = SYS_LABEL[sys],
            }
            games[#games + 1] = t
            byKey[t.key] = t
          end
        end
      end
    end
  end
  local seenFiles = {}
  for _, scanDir in ipairs(AeonDX.getAllScanDirs()) do
    walk(scanDir, 0)
  end
  table.sort(games, function(a, b) return a.name:lower() < b.name:lower() end)
  st.games, st.byKey = games, byKey
  st.scanned = true
  if changed then saveCache() end
end

local FAKE_GAMES = {
  { sys = "ds", name = "Pokemon - Platinum Version", code = "CPUE" },
  { sys = "ds", name = "New Super Mario Bros.", code = "A2DE" },
  { sys = "gb", name = "Tetris", crc = "46DF91AD" },
  { sys = "gbc", name = "Pokemon - Crystal Version", crc = "3358E30A" },
  { sys = "gba", name = "Pokemon - Emerald Version", crc = "1F1C08FB" },
}

function E.games()
  if FAKE then
    if not st.fakeGames then
      st.fakeGames = {}
      for i, g in ipairs(FAKE_GAMES) do
        local key = ("fake%d"):format(i)
        st.fakeGames[i] = { id = (g.sys == "ds" and "nds_" or "vc_") .. key, key = key, core = true, fake = true,
          sys = g.sys, system = g.sys == "ds" and "nds" or g.sys, name = g.name, code = g.code, crc = g.crc,
          nointro = nil, base = key, sub = SYS_LABEL[g.sys] }
      end
    end
    return st.fakeGames
  end
  if not st.scanned then scan() end
  return st.games
end

function E.rescan() st.scanned = false; st.images = {} end

-- a look at the games folder now and then (a game copied in joins the grid)
function E.poll(time)
  if FAKE or time < st.scanAt then return end
  st.scanAt = time + 5
  if core() then
    local before = #st.games
    scan()
    if #st.games ~= before then st.images = {} end
  end
end

---------------------------------------------------------------- art

-- the box art's file, and asking for it (libretro-thumbnails, by name)
local function boxFile(t) return CACHE .. "box/" .. t.sys .. "/" .. t.key .. ".png" end

local function thumbName(n) return (n:gsub("[&%*/:`<>%?\\|\"]", "_")) end

local function wantArt(t)
  if not E.getBool("art.download") or not android() then return end
  if t.nointro and THUMBS[t.sys] then
    E.fetch(("https://raw.githubusercontent.com/libretro-thumbnails/%s/master/Named_Boxarts/%s.png")
      :format(THUMBS[t.sys], urlencode(thumbName(t.nointro))), boxFile(t))
  elseif t.sys == "ds" and t.code and #t.code == 4 then
    -- no No-Intro name: GameTDB's cover by the game code
    local region = ({ E = "US", P = "EN", J = "JA", K = "KO", D = "DE", F = "FR", S = "ES", I = "IT" })[t.code:sub(4)] or "EN"
    E.fetch(("https://art.gametdb.com/ds/coverS/%s/%s.png"):format(region, t.code), boxFile(t))
  end
  -- a DS game's card, photographed (GameTDB), for its top screen
  if t.sys == "ds" and t.code and #t.code == 4 then
    local region = ({ E = "US", P = "EN", J = "JA", K = "KO" })[t.code:sub(4)] or "EN"
    E.fetch(("https://art.gametdb.com/ds/cart/%s/%s.png"):format(region, t.code), CACHE .. "cart/" .. t.key .. ".png")
  end
end

local function img(file)
  if st.images[file] == nil then
    st.images[file] = false
    if love.filesystem.getInfo(file) then
      local ok, i = pcall(lg.newImage, file)
      if ok and i then
        i:setFilter("linear", "linear")
        st.images[file] = i
      end
    end
  end
  return st.images[file] or nil
end

-- the tile's icon: a DS game's own banner icon, else its box art
function E.icon(t)
  if not t or not t.core or t.fake then return nil end
  if t.hasIcon then
    local i = img(CACHE .. "icons/" .. t.key .. ".png")
    if i then i:setFilter("nearest", "nearest") return i end
  end
  local b = img(boxFile(t))
  if not b then
    wantArt(t)
    -- look again in a while (the download may finish)
    if st.images[boxFile(t)] == false and love.filesystem.getInfo(boxFile(t)) then st.images[boxFile(t)] = nil end
  end
  return b
end

-- the icon's file in the save folder (the UI reads its colours)
function E.iconPath(t)
  if not t or not t.core then return nil end
  if t.hasIcon then return CACHE .. "icons/" .. t.key .. ".png" end
  if love.filesystem.getInfo(boxFile(t)) then return boxFile(t) end
  return nil
end

function E.boxArt(t)
  if t and t.fake then return nil end
  local b = img(boxFile(t))
  if not b then
    wantArt(t)
    if st.images[boxFile(t)] == false and love.filesystem.getInfo(boxFile(t)) then st.images[boxFile(t)] = nil end
  end
  return b
end

-- a DS game card's photo (GameTDB), when there is one
function E.cartPhoto(t)
  if not t or t.sys ~= "ds" then return nil end
  local f = CACHE .. "cart/" .. t.key .. ".png"
  local p = img(f)
  if not p and st.images[f] == false and love.filesystem.getInfo(f) then st.images[f] = nil end
  return p
end

-- the colour a game's cart is shown in: its system's shell with the art's
-- own colour mixed in
local colours = {}
function E.colour(t)
  if colours[t.key] then return colours[t.key] end
  local base = SHELL[t.sys] or { 150, 150, 160 }
  local file = t.hasIcon and (CACHE .. "icons/" .. t.key .. ".png") or boxFile(t)
  if not love.filesystem.getInfo(file) then return base end
  local c = base
  local ok, d = pcall(love.image.newImageData, file)
  if ok and d then
    local r, g, b, n = 0, 0, 0, 0
    local w, h = d:getDimensions()
    local step = math.max(1, math.floor(math.max(w, h) / 48))
    for y = 0, h - 1, step do
      for x = 0, w - 1, step do
        local pr, pg, pb, pa = d:getPixel(x, y)
        local sat = math.max(pr, pg, pb) - math.min(pr, pg, pb)
        local wgt = pa * sat * sat
        r, g, b, n = r + pr * wgt, g + pg * wgt, b + pb * wgt, n + wgt
      end
    end
    if n > 0 then
      local k = 0.7
      c = { base[1] * (1 - k) + r / n * 255 * k, base[2] * (1 - k) + g / n * 255 * k, base[3] * (1 - k) + b / n * 255 * k }
    end
  end
  colours[t.key] = c
  return c
end

-- the top screen's 3D cart for a game (fold3ds.cart3d's skin)
function E.cartSkin(t)
  local shape = t.sys == "ds" and "ds" or t.sys == "gba" and "gba" or "gb"
  return { shape = shape, cart = true, color = E.colour(t), labelImage = E.boxArt(t),
    noLabel = true, cacheKey = t.key }
end

---------------------------------------------------------------- playing

local run = {
  t = nil,               -- the game's tile
  acc = 0,
  keys = 0,              -- held, from the shell
  touch = nil,           -- { x, y } on the DS's touch screen
  data = {},             -- screen idx -> ImageData
  images = {},           -- screen idx -> Image
  source = nil,          -- QueueableSource
  sounds = {},           -- SoundData pool
  soundIdx = 1,
  abuf = nil, afill = 0, arate = 48000,
  fast = false, slow = false,
  menu = false,          -- HOME's menu open (paused)
  menuSel = 1,
  flushAt = 0,
  toast = nil,
}
local CHUNK = 1024        -- audio frames per queued buffer

local function applyOptions(lib)
  for k in pairs(E.DEFAULTS) do lib.ec_set_option(k, E.get(k)) end
end

local function saveFile(t) return AeonDX.getSavePath(t.sys, t.base) end
local function stateFile(t) return AeonDX.getStatePath(t.sys, t.base) end
local function biosDir(t) return AeonDX.getBiosDir(t.sys) end

-- a fake game's screen: colour bars, a moving stripe, the frame count
local function fakeFrame(i, w, h, n)
  local d = run.data[i]
  if not d then
    d = love.image.newImageData(w, h, "rgba8")
    run.data[i] = d
  end
  local p = ffi.cast("uint8_t*", d:getFFIPointer())
  local bars = { { 255, 255, 255 }, { 255, 255, 0 }, { 0, 255, 255 }, { 0, 255, 0 },
                 { 255, 0, 255 }, { 255, 0, 0 }, { 0, 0, 255 }, { 20, 20, 20 } }
  local stripe = n % w
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local c = bars[math.floor(x * 8 / w) + 1]
      local k = (y * w + x) * 4
      local lit = (x == stripe or y == n % h) and 0 or 1
      local shade = i == 1 and 0.6 or 1
      p[k] = c[1] * lit * shade; p[k + 1] = c[2] * lit * shade; p[k + 2] = c[3] * lit * shade; p[k + 3] = 255
    end
  end
  -- the DS touch point: a white dot
  if i == 1 and run.touch then
    for dy = -3, 3 do
      for dx = -3, 3 do
        local x, y = run.touch[1] + dx, run.touch[2] + dy
        if x >= 0 and y >= 0 and x < w and y < h then
          local k = (y * w + x) * 4
          p[k], p[k + 1], p[k + 2] = 255, 255, 255
        end
      end
    end
  end
  if run.images[i] then run.images[i]:replacePixels(d) else run.images[i] = lg.newImage(d) end
  run.images[i]:setFilter("nearest", "nearest")
end

function E.play(t)
  if FAKE then
    run.t = t
    run.acc, run.keys, run.touch, run.frame = 0, 0, nil, 0
    run.menu, run.fast, run.slow = false, false, false
    run.data, run.images = {}, {}
    return true
  end
  local lib = core()
  if not lib then
    E.message = E.NAME .. " is not in this build of the app"
    return false
  end
  pickRoot()
  applyOptions(lib)
  local bDir = biosDir(t)
  local opened
  if CORE_SYS[t.sys] then
    local m = Cores.forSystem(t.sys)
    if not m then
      E.message = "Get the " .. (SYS_LABEL[t.sys] or t.sys):gsub("^Virtual Console  %-  ", "") ..
        " core in the eShop's Cores section first"
      return false
    end
    opened = lib.ec_open_core(m.path, t.file, saveFile(t), bDir)
  else
    opened = lib.ec_open(SYS[t.sys], t.file, saveFile(t), bDir)
  end
  if opened ~= 1 then
    E.message = "Could not start " .. (t.name or "the game") .. ": " .. ffi.string(lib.ec_error())
    return false
  end
  run.t = t
  run.acc, run.keys, run.touch = 0, 0, nil
  run.menu, run.fast, run.slow = false, false, false
  run.data, run.images = {}, {}
  run.flushAt = love.timer.getTime() + 2
  run.arate = lib.ec_audio_rate()
  run.abuf = ffi.new("int16_t[?]", CHUNK * 2 * 4)
  run.afill = 0
  run.sounds = {}
  for i = 1, 8 do run.sounds[i] = love.sound.newSoundData(CHUNK, run.arate, 16, 2) end
  run.source = love.audio.newQueueableSource(run.arate, 16, 2, 8)
  -- the game's own border (fetched the first time, into borders.lua's cache)
  local okB, Borders = pcall(require, "fold3ds.borders")
  if okB then
    Borders.style = E.get("border.style") == "system" and "system" or "game"
    Borders.setGame(t.sys, t.nointro)
  end
  return true
end

function E.running() return run.t ~= nil end
function E.current() return run.t end
function E.system() return run.t and run.t.sys end

function E.stop()
  if FAKE then run.t = nil; run.data, run.images = {}, {} return end
  local lib = core()
  if not run.t or not lib then return end
  lib.ec_flush()
  lib.ec_close()
  if run.source then run.source:stop() end
  run.source = nil
  run.t = nil
  run.data, run.images = {}, {}
end

local function toast(text) run.toast = { text = text, at = love.timer.getTime() } end

function E.saveState()
  if FAKE then toast("State saved") return end
  local lib = core()
  if not run.t or not lib then return end
  toast(lib.ec_save_state(stateFile(run.t)) == 1 and "State saved" or "Could not save the state")
end

function E.loadState()
  if FAKE then toast("State loaded") return end
  local lib = core()
  if not run.t or not lib then return end
  toast(lib.ec_load_state(stateFile(run.t)) == 1 and "State loaded" or "No saved state")
end

function E.reset()
  if FAKE then toast("Reset") return end
  local lib = core()
  if run.t and lib then lib.ec_reset(); toast("Reset") end
end

function E.gbaSioEnable(enabled)
  if FAKE then return false end
  local lib = core()
  if not lib then return false end
  lib.ec_gba_sio_set_enabled(enabled and 1 or 0)
  return true
end

function E.gbaSioRead(capacity)
  if FAKE then return "" end
  local lib = core()
  if not lib then return "" end
  capacity = math.max(1, math.min(4096, math.floor(capacity or 1024)))
  local out = ffi.new("uint8_t[?]", capacity)
  local length = lib.ec_gba_sio_read_tx(out, capacity)
  return length > 0 and ffi.string(out, length) or ""
end

function E.gbaSioWrite(data)
  if FAKE or type(data) ~= "string" or #data == 0 then return 0 end
  local lib = core()
  if not lib then return 0 end
  local input = ffi.new("uint8_t[?]", #data)
  ffi.copy(input, data, #data)
  return lib.ec_gba_sio_write_rx(input, #data)
end

function E.gbaSioDropped()
  local lib = core()
  return lib and tonumber(lib.ec_gba_sio_dropped()) or 0
end

local function pushAudio(lib)
  if not run.source then return end
  local vol = E.getBool("audio.mute") and 0 or E.getNum("audio.volume") / 100
  run.source:setVolume(math.max(0, math.min(1, vol)))
  while true do
    local want = CHUNK - run.afill
    local n = lib.ec_audio(run.abuf + run.afill * 2, want)
    if n <= 0 then break end
    run.afill = run.afill + n
    if run.afill >= CHUNK then
      if run.source:getFreeBufferCount() > 0 then
        local sd = run.sounds[run.soundIdx]
        run.soundIdx = run.soundIdx % #run.sounds + 1
        ffi.copy(sd:getFFIPointer(), run.abuf, CHUNK * 4)
        run.source:queue(sd)
        if not run.source:isPlaying() then run.source:play() end
      end
      run.afill = 0
    end
  end
end

local function pullScreens(lib)
  local w, h = ffi.new("int[1]"), ffi.new("int[1]")
  for i = 0, lib.ec_screen_count() - 1 do
    local p = lib.ec_screen(i, w, h)
    if p ~= nil then
      local d = run.data[i]
      if not d or d:getWidth() ~= w[0] or d:getHeight() ~= h[0] then
        d = love.image.newImageData(w[0], h[0], "rgba8")
        run.data[i] = d
        run.images[i] = nil
      end
      ffi.copy(d:getFFIPointer(), p, w[0] * h[0] * 4)
      if run.images[i] then
        run.images[i]:replacePixels(d)
      else
        run.images[i] = lg.newImage(d)
      end
      local f = E.getBool("screen.smooth") and "linear" or "nearest"
      run.images[i]:setFilter(f, f)
    end
  end
end

-- every frame the app runs: the game's frames due since the last one
function E.update(dt)
  if FAKE and run.t then
    if run.menu then return end
    run.frame = (run.frame or 0) + 1
    local w, h = E.screenSize(run.t.sys)
    fakeFrame(0, w, h, run.frame)
    if run.t.sys == "ds" then fakeFrame(1, w, h, run.frame) end
    return
  end
  local lib = core()
  if not run.t or not lib then return end
  local now = love.timer.getTime()
  if now >= run.flushAt then lib.ec_flush(); run.flushAt = now + 2 end
  if run.menu then return end
  local fps = lib.ec_fps()
  local speed = run.fast and math.max(1, E.getNum("speed.fast")) or run.slow and 0.5 or 1
  run.acc = math.min(run.acc + (dt or 0) * speed, 8 / fps)
  local n = 0
  while run.acc >= 1 / fps and n < 8 do
    lib.ec_set_keys(run.keys)
    if run.touch then lib.ec_touch(1, run.touch[1], run.touch[2]) else lib.ec_touch(0, 0, 0) end
    lib.ec_run_frame()
    run.acc = run.acc - 1 / fps
    n = n + 1
    -- fast forward: only a frame's worth of sound
    if n == 1 or not run.fast then pushAudio(lib) else lib.ec_audio(run.abuf, CHUNK * 4) end
  end
  if n > 0 then pullScreens(lib) end
end

---------------------------------------------------------------- input

-- the in-game menu (HOME): its rows (the screen's shape is the UI's own,
-- on the C-stick)
local MENU = {
  { id = "resume", label = "Resume" },
  { id = "save", label = "Save State" },
  { id = "load", label = "Load State" },
  { id = "reset", label = "Reset" },
  { id = "close", label = "Close Game" },
}

local function menuDo(id, ctx)
  if not run.t then return end
  if id == "resume" then run.menu = false
  elseif id == "save" then E.saveState(); run.menu = false
  elseif id == "load" then E.loadState(); run.menu = false
  elseif id == "reset" then E.reset(); run.menu = false
  elseif id == "screen" then if ctx and ctx.cycleScreen then ctx.cycleScreen() end
  elseif id == "close" then E.stop(); return "closed" end
end

-- a shell button pressed / released while a game runs; "closed" when the
-- game was closed from its menu
function E.press(btn, ctx)
  if not run.t then return end
  if btn == "home" then
    run.menu = not run.menu
    run.menuSel = 1
    return
  end
  if run.menu then
    if btn == "up" then run.menuSel = (run.menuSel - 2) % #MENU + 1
    elseif btn == "down" then run.menuSel = run.menuSel % #MENU + 1
    elseif btn == "a" then return menuDo(MENU[run.menuSel].id, ctx)
    elseif btn == "b" then run.menu = false end
    return
  end
  if btn == "zr" then run.fast = true return end
  if btn == "zl" then run.slow = true return end
  if btn == "cstick" then if ctx and ctx.cycleScreen then ctx.cycleScreen() end return end
  local k = KEY[btn]
  if run.t.sys == "gba" and E.getBool("controls.gba_xy") then
    if btn == "x" then k = KEY.r elseif btn == "y" then k = KEY.l end
  end
  if k then run.keys = bit.bor(run.keys, k) end
end

function E.release(btn)
  if not run.t then return end
  if btn == "zr" then run.fast = false return end
  if btn == "zl" then run.slow = false return end
  local k = KEY[btn]
  if run.t.sys == "gba" and E.getBool("controls.gba_xy") then
    if btn == "x" then k = KEY.r elseif btn == "y" then k = KEY.l end
  end
  if k then run.keys = bit.band(run.keys, bit.bnot(k)) end
  if btn == "a" or btn == "b" or btn == "x" or btn == "y" then
    -- a button still held by another finger stays held (the shell sends
    -- one release per finger)
  end
end

function E.releaseAll()
  run.keys, run.touch, run.fast, run.slow = 0, nil, false, false
end

-- a touch on the DS's touch screen at (u, v), 0..1 across and down; the
-- UI maps the finger into the picture it drew.  phase: pressed | moved |
-- released
function E.touch(phase, u, v)
  if not run.t or run.t.sys ~= "ds" or run.menu then return end
  if phase == "released" or not u or not v then run.touch = nil return end
  local tx, ty = math.floor(u * 256), math.floor(v * 192)
  if tx >= 0 and ty >= 0 and tx < 256 and ty < 192 then run.touch = { tx, ty }
  elseif phase == "pressed" then run.touch = nil end
end

---------------------------------------------------------------- for the UI
-- (the 3DS UI session draws everything; these are what it reads)

-- the core's picture: 0 the top (the only one on GB / GBC / GBA), 1 the
-- DS's touch screen; screen.swap puts the touch screen on top
function E.screen(i)
  if not run.t then return nil end
  if run.t.sys == "ds" and E.getBool("screen.swap") then i = 1 - i end
  return run.images[i]
end

-- the systems' screens, in pixels
local SIZES = { gb = { 160, 144 }, gbc = { 160, 144 }, gba = { 240, 160 }, ds = { 256, 192 },
  nes = { 256, 240 }, snes = { 256, 224 }, vb = { 384, 224 }, pokemini = { 96, 64 }, gw = { 256, 256 } }
function E.screenSize(sys) local s = SIZES[sys or ""] return s and s[1], s and s[2] end

-- the in-game menu (HOME): open, its rows, the selected one
function E.menu()
  return { open = run.menu, rows = MENU, sel = run.menuSel }
end
function E.menuDo(id, ctx) return menuDo(id, ctx) end
function E.vcButtons() return { "save", "load", "reset", "close" } end

-- a message for the player (a toast), and its time; nil when none
function E.toast()
  return run.toast and run.toast.text, run.toast and run.toast.at
end

---------------------------------------------------------------- adding games

-- the Android file picker: the chosen file lands in the save folder as
-- emu_picked.bin, and is moved into games/ under its header's name
local PICKED = "emu_picked.bin"
local picking = false

function E.pick()
  if not (love.system.pickFile and android()) then
    E.message = "Copy your games into " .. (AeonDX.getRomDir("ds") or path("melonds", "roms", "ds"))
    return false
  end
  pcall(love.filesystem.remove, PICKED)
  picking = love.system.pickFile("required_import", PICKED) and true or false
  return picking
end

-- a picked file arrived: into the emulator's console ROM folder
function E.takePicked()
  if not picking or not love.filesystem.getInfo(PICKED) then return end
  picking = false
  local lib = core()
  if not lib then return end
  pickRoot()
  local src = love.filesystem.getSaveDirectory() .. "/" .. PICKED
  local title = ffi.new("char[256]")
  local code = ffi.new("char[16]")
  local sysn = lib.ec_rom_info(src, title, 256, code, 16, nil, nil)
  local sys = SYS_NAME[sysn]
  if not sys then E.message = "That is not a DS, Game Boy or Game Boy Advance game" return end
  local ext = ({ ds = "nds", gb = "gb", gbc = "gbc", gba = "gba" })[sys]
  local base = ffi.string(title):gsub("[^%w%-_ ]", ""):gsub("^%s+", ""):gsub("%s+$", "")
  if base == "" then base = "Game" end
  local romDir = AeonDX.getRomDir(sys)
  lib.ec_mkdirs(romDir)
  local dest = romDir .. "/" .. base .. "." .. ext
  local n = 1
  while io.open(dest, "rb") do n = n + 1; dest = romDir .. ("/%s (%d).%s"):format(base, n, ext) end
  if lib.ec_copy(src, dest) == 1 then
    pcall(love.filesystem.remove, PICKED)
    E.rescan()
    E.message = "Added " .. base .. " to " .. sys:upper()
  end
end

---------------------------------------------------------------- settings pages
-- Each folder icon's page, as data: rows of { key, label, choices } (a
-- choice is { value, label }) or { action, label, sub }.  The UI draws a
-- page (E.page()) and calls E.set(key, value) or E.act(action).

local YESNO = { { "1", "On" }, { "0", "Off" } }
local function range(a, b, fmt)
  local out = {}
  for i = a, b do out[#out + 1] = { tostring(i), fmt and fmt:format(i) or tostring(i) } end
  return out
end

E.PAGES = {
  ds_screen = { title = "Screens", rows = {
    { key = "screen.swap", label = "Touch screen on top", choices = YESNO },
    { key = "screen.smooth", label = "Smooth pixels", choices = YESNO },
    { key = "border.style", label = "Border", choices = { { "game", "The game's own" }, { "system", "The system's" } } },
  } },
  ds_profile = { title = "DS Profile", rows = {
    { key = "ds.nickname", label = "Nickname", text = 10 },
    { key = "ds.message", label = "Message", text = 26 },
    { key = "ds.language", label = "Language", choices = { { "0", "Japanese" }, { "1", "English" },
      { "2", "French" }, { "3", "German" }, { "4", "Italian" }, { "5", "Spanish" } } },
    { key = "ds.color", label = "Favourite colour", choices = range(0, 15) },
    { key = "ds.birth_month", label = "Birthday month", choices = range(1, 12) },
    { key = "ds.birth_day", label = "Birthday day", choices = range(1, 31) },
  } },
  ds_system = { title = "DS System", rows = {
    { key = "ds.real_bios", label = "Use BIOS files (bios/)", choices = YESNO },
    { key = "ds.boot_menu", label = "Start at the DS menu (needs BIOS + firmware)", choices = YESNO },
    { key = "ds.jit", label = "Fast CPU (JIT)", choices = YESNO },
    { key = "ds.jit_block", label = "JIT block size", choices = range(1, 32) },
    { key = "ds.threaded_3d", label = "3D on its own thread", choices = YESNO },
  } },
  audio = { title = "Sound", rows = {
    { key = "audio.volume", label = "Volume", choices = { { "0", "0%" }, { "25", "25%" }, { "50", "50%" }, { "75", "75%" }, { "100", "100%" } } },
    { key = "audio.mute", label = "Mute", choices = YESNO },
    { key = "ds.audio_interp", label = "DS sound filter", choices = { { "0", "None" }, { "1", "Linear" },
      { "2", "Cosine" }, { "3", "Cubic" }, { "4", "Gaussian" } } },
  } },
  controls = { title = "Controls", rows = {
    { key = "speed.fast", label = "ZR fast-forward speed", choices = { { "2", "2x" }, { "3", "3x" }, { "4", "4x" }, { "6", "6x" } } },
    { key = "controls.gba_xy", label = "GBA: X / Y are R / L too", choices = YESNO },
  } },
  vc_screen = { title = "Screens", rows = {
    { key = "screen.smooth", label = "Smooth pixels", choices = YESNO },
    { key = "border.style", label = "Border", choices = { { "game", "The game's own" }, { "system", "The system's" } } },
  } },
  vc_system = { title = "Virtual Console", rows = {
    { key = "vc.bios", label = "Use BIOS files (bios/SkyEmu/)", choices = YESNO },
    { key = "art.download", label = "Download box art", choices = YESNO },
  } },
  folder = { title = "Games & Folders", rows = {
    { action = "add", label = "Add a game", sub = "Pick a .nds, .gb, .gbc or .gba file" },
    { action = "rescan", label = "Look for new games" },
    { action = "storage", label = "Use shared storage", sub = "So the folder is easy to reach from a PC or file manager" },
    { action = "info_root", label = "User folder" },
  } },
  about = { title = "About", rows = {
    { info = true, label = "DS: the melonDS core (melonDS-android-lib), GPLv3" },
    { info = true, label = "Game Boy / Color / Advance: SkyEmu's cores, MIT" },
    { info = true, label = "Borders: libretro common-overlays (CC-BY 4.0), The Bezel Project" },
    { info = true, label = "Box art: libretro-thumbnails; DS covers: GameTDB" },
    { info = true, label = "Names: No-Intro, via libretro-database" },
  } },
}

local page = nil
-- open(url) of a folder icon: "page?id=X" shows a page; the rest act now
function E.open(url)
  local what, arg = url:match("^(%w+)%??(.*)$")
  local id = arg and arg:match("id=([%w_]+)")
  if what == "page" and id and E.PAGES[id] then page = id return true end
  if what == "act" and id then return E.act(id) end
  return false
end

-- the page the UI should show (nil: none), and closing it
function E.page()
  local p = page and E.PAGES[page]
  if not p then return nil end
  local out = { id = page, title = p.title, rows = {} }
  for i, r in ipairs(p.rows) do
    local row = { key = r.key, label = r.label, sub = r.sub, choices = r.choices, text = r.text,
      action = r.action, info = r.info }
    if r.key then row.value = E.get(r.key) end
    if r.action == "info_root" then row.sub = E.root() end
    out.rows[i] = row
  end
  return out
end
function E.closePage() page = nil end

function E.act(id)
  if id == "add" then return E.pick() end
  if id == "rescan" then E.rescan(); return true end
  if id == "storage" then
    local r = E.askShared()
    st.root = nil
    return r
  end
  return false
end

-- a finished text entry or a picked choice from a page
function E.setSetting(key, value)
  if E.DEFAULTS[key] == nil then return end
  E.set(key, value)
end

-- the No-Intro name a game's border and box art are filed under
function E.borderName(t) return t and t.nointro end

---------------------------------------------------------------- setup

function E.init()
  if core() then pickRoot() end
end

function E.loadError() return loadError end
function E.path(...) pickRoot() return path(...) end

return E
