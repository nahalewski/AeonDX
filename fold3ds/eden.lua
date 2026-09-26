-- Eden -- the Switch emulator -- as the 3DS HOME menu sees it (Steam Dev).
--
-- Eden is its own installed app (dev.eden.eden_emulator), not built into this one, and its
-- code is never changed (AXM-TEAM-PLAN hard rule 1). So, unlike Azahar, nothing of Eden's
-- writes our library: our own EdenBridge (org.citra.citra_emu.fold3ds, beside Fold3dsBridge)
-- scans the Switch games folder the user picked and writes, into this save folder:
--
--   fold3ds_eden/games.tsv
--     state<TAB>ready | setup | missing     (setup: no games folder yet; missing: Eden not installed)
--     gamesdir<TAB>the Switch games folder
--     game<TAB>key<TAB>title<TAB>subtitle<TAB>icon 0|1<TAB>file<TAB>title id (16 hex, or empty)
--   fold3ds_eden/icons/<key>.png
--   fold3ds_eden/running.tsv    running<TAB>key while that game is up in Eden's pane
--
-- Opening anything: love.system.openURL("fold3ds-eden://...") to EdenLinkActivity, which
-- starts the game in Eden with no Eden screens (Video Dev's launch contract: straight into
-- the game, Eden in the bottom pane, our UI on top) or opens one of our own pages.
--
-- POKEPORT_FOLD_FAKEEDEN=1 lists two made-up games on the desktop.
local E = {}
local AeonDX = require("fold3ds.aeondx")

local DIR = "fold3ds_eden/"
local LIST = DIR .. "games.tsv"
local RUNNING = DIR .. "running.tsv"
local SCHEME = "fold3ds-eden://"
local POLL = 1.0

E.FOLDER = "eden"
-- the system code screen routing and the cartridge shelf key on (as emucore's "ds", "gba")
local SYS = "switch"
E.SYS = SYS

-- The Eden folder: settings pages, system tools, and game folder actions.
E.ITEMS = {
  { id = "sw_settings", name = "Emulation Settings", sub = "Every Eden Switch setting", url = "settings?menu=config" },
  { id = "sw_graphics", name = "Graphics", sub = "Resolution, VSync, scaling, GPU accuracy", url = "settings?menu=Renderer" },
  { id = "sw_framegen", name = "Frame Generation", sub = "Frame multiplier, motion estimation", url = "settings?menu=FrameGen" },
  { id = "sw_system", name = "System Settings", sub = "Region, language, device name, clock", url = "settings?menu=System" },
  { id = "sw_audio", name = "Audio", sub = "Output engine, volume, sound sinks", url = "settings?menu=Audio" },
  { id = "sw_controls", name = "Controls", sub = "Buttons, touch controls and controller mapping", url = "settings?menu=Controls" },
  { id = "sw_debug", name = "Debug", sub = "Logging and debugging options", url = "settings?menu=Debugging" },
  { id = "sw_drivers", name = "GPU Drivers", sub = "Custom Turnip and Adreno GPU drivers", url = "drivers" },
  { id = "sw_install", name = "Install NSP / XCI", sub = "Install Switch games, updates and DLC", url = "install" },
  { id = "sw_gamedir", name = "Games Folder", sub = "Choose the folder your Switch games are in", url = "games_folder" },
  { id = "sw_refresh", name = "Refresh Games", sub = "Look for new Switch games in the folder", url = "refresh" },
  { id = "sw_about", name = "About Eden", sub = "Switch emulator version and credits", url = "about" },
}

local st = { status = nil, games = {}, stamp = nil, checkAt = -1, images = {}, gamesDir = nil,
  running = nil, runStamp = nil }

local function fake() return os.getenv and os.getenv("POKEPORT_FOLD_FAKEEDEN") == "1" end

local function split(line)
  local out = {}
  for field in (line .. "\t"):gmatch("([^\t]*)\t") do out[#out + 1] = field end
  return out
end

---------------------------------------------------------------- the Eden core
-- Eden as a downloaded .aeoncore (AeonCoreHost.kt): its games play inside the
-- shell, the frames read like Azahar's (nx.frame's address through the FFI)
local core = { on = false, serial = -1, data = nil, img = nil, checkAt = 0 }

local function bridge(cmd, arg)
  local f = love.system and love.system.foldCamera
  if not f then return nil end
  local ok, r = pcall(f, "call", cmd, arg or "")
  return ok and r or nil
end

function E.coreInstalled()
  local okC, Cores = pcall(require, "fold3ds.cores")
  return okC and Cores.installed().eden ~= nil
end

local function copyCoreFrame()
  local okF, ffi = pcall(require, "ffi")
  if not okF then return end
  local info = bridge("nx.frame")
  local hi, lo, w, h, serial = (info or ""):match("^(%d+):(%d+):(%d+):(%d+):(%d+)$")
  if not hi then return end
  serial = tonumber(serial)
  if serial == core.serial or serial == 0 then return end
  core.serial = serial
  w, h = tonumber(w), tonumber(h)
  local addr = ffi.cast("uint64_t", tonumber(hi)) * 4294967296ULL + ffi.cast("uint64_t", tonumber(lo))
  if not core.data or core.data:getWidth() ~= w or core.data:getHeight() ~= h then
    core.data = love.image.newImageData(w, h)
    core.img = nil
  end
  ffi.copy(core.data:getFFIPointer(), ffi.cast("const uint8_t*", addr), w * h * 4)
  if core.img then core.img:replacePixels(core.data)
  else core.img = love.graphics.newImage(core.data); core.img:setFilter("linear", "linear") end
end

local function parse(text)
  local status, games, dir = nil, {}, nil
  for line in text:gmatch("[^\n]+") do
    local f = split(line)
    if f[1] == "state" then
      status = f[2]
    elseif f[1] == "gamesdir" then
      dir = f[2] ~= "" and f[2] or nil
    elseif f[1] == "game" and f[2] and f[2]:match("^[%w_]+$") then
      games[#games + 1] = {
        id = "nx_" .. f[2], key = f[2], nx = true, sys = SYS,
        name = (f[3] ~= "" and f[3]) or "Switch game",
        sub = (f[4] ~= "" and f[4]) or "Nintendo Switch",
        hasIcon = f[5] == "1",
        file = f[6] ~= "" and f[6] or nil,
        titleId = f[7] ~= "" and f[7] or nil,
      }
    end
  end
  return status, games, dir
end

local function load()
  if fake() then
    st.status, st.stamp = "ready", "fake"
    st.games = {
      { id = "nx_fake1", key = "fake1", nx = true, sys = SYS, name = "The Legend of Zelda: Breath of the Wild", sub = "Nintendo" },
      { id = "nx_fake2", key = "fake2", nx = true, sys = SYS, name = "Pokémon Legends: Arceus", sub = "Nintendo" },
    }
    return
  end
  local info = love.filesystem.getInfo(LIST, "file")
  local stamp = info and ((info.modtime or 0) .. ":" .. (info.size or 0)) or nil
  if stamp == st.stamp then return end
  st.stamp, st.images = stamp, {}
  if not stamp then st.status, st.games = nil, {} return end
  local ok, text = pcall(love.filesystem.read, LIST)
  if not ok or type(text) ~= "string" then return end
  st.status, st.games, st.gamesDir = parse(text)
end

local function loadRunning()
  if fake() then return end
  local info = love.filesystem.getInfo(RUNNING, "file")
  local stamp = info and ((info.modtime or 0) .. ":" .. (info.size or 0)) or nil
  if stamp == st.runStamp then return end
  st.runStamp, st.running = stamp, nil
  if not stamp then return end
  local ok, text = pcall(love.filesystem.read, RUNNING)
  local key = ok and type(text) == "string" and text:match("^running	([%w_]+)") or nil
  st.running = key
end

function E.init() load(); loadRunning() end
function E.poll(time)
  if time and time < st.checkAt then return end
  st.checkAt = (time or 0) + POLL
  load()
  loadRunning()
end

-- the Switch game up in Eden's pane (the other window, not drawn here), or nil
function E.running()
  if not st.running then return nil end
  -- the core's game ended by itself: back to the menu
  if core.on and love.timer and love.timer.getTime() >= core.checkAt then
    core.checkAt = love.timer.getTime() + 0.5
    if bridge("nx.state") == "stopped" and core.serial > 0 then E.stop() return nil end
  end
  for _, g in ipairs(st.games) do if g.key == st.running then return g end end
  if st.lastPlayed and st.lastPlayed.key == st.running then return st.lastPlayed end
  return { key = st.running, name = "Nintendo Switch Game", system = "Nintendo Switch", emu = "eden" }
end

-- "missing" (Eden not installed) shows as setup: the setup tile says to install Eden.
function E.status() return st.status == "ready" and "ready" or (st.status and "setup" or nil) end
function E.missing() return st.status == "missing" end
function E.games() return st.status == "ready" and st.games or {} end
function E.gamesDir() return st.gamesDir or AeonDX.getRomDir("switch") end
function E.dataDir() return AeonDX.getDataDir("eden") end

local function image(key, file)
  if st.images[key] == nil then
    st.images[key] = false
    local ok, img = pcall(love.graphics.newImage, file)
    if ok and img then
      img:setFilter("linear", "linear")
      st.images[key] = img
    end
  end
  return st.images[key] or nil
end

local ESHOP = "https://img-eshop.cdn.nintendo.net/i/"
local artText
local function eshopArt(t)
  local id = t and (t.titleId or t.programId) and (t.titleId or t.programId):upper()
  if not id or #id ~= 16 then return nil end
  id = id:sub(1, 13) .. "000"
  if artText == nil then
    local ok, text = pcall(love.filesystem.read, "fold3ds/emudb/nx.tsv")
    artText = ok and type(text) == "string" and text or false
  end
  if not artText then return nil end
  local icon, banner = artText:match("\n" .. id .. "\t(%x*)\t(%x*)")
  if not icon then icon, banner = artText:match("^" .. id .. "\t(%x*)\t(%x*)") end
  if not icon then return nil end
  return { icon = icon ~= "" and icon or nil, banner = banner ~= "" and banner or nil, id = id }
end

local fetching = {}
local function fetched(hash)
  if not hash then return nil end
  local file = DIR .. "art/" .. hash .. ".jpg"
  if love.filesystem.getInfo(file, "file") then return image(hash, file) end
  if not fetching[hash] then
    fetching[hash] = true
    local ok, Core = pcall(require, "fold3ds.emucore")
    if ok and Core and Core.fetch then pcall(Core.fetch, ESHOP .. hash .. ".jpg", file) end
  end
  return nil
end

function E.icon(t)
  if not (t and t.key) then return nil end
  if t.hasIcon then
    local img = image(t.key, DIR .. "icons/" .. t.key .. ".png")
    if img then return img end
  end
  local a = eshopArt(t)
  return a and fetched(a.icon) or nil
end

function E.iconPath(t)
  if t and t.key and t.hasIcon then return DIR .. "icons/" .. t.key .. ".png" end
  local a = eshopArt(t)
  local file = a and a.icon and (DIR .. "art/" .. a.icon .. ".jpg")
  return file and love.filesystem.getInfo(file, "file") and file or nil
end

function E.cart(t)
  local a = eshopArt(t)
  return a and fetched(a.banner) or nil
end

function E.cartSkin(t)
  return { shape = "switch", color = { 38, 38, 42 }, labelImage = E.cart(t) or E.icon(t), cart = true }
end

function E.manual(t)
  return t and t.key and E.open("game?key=" .. t.key) or false
end

function E.open(url)
  if not (love.system and love.system.openURL) then return false end
  if love.system.getOS and love.system.getOS() ~= "Android" then return false end
  return love.system.openURL(SCHEME .. url) and true or false
end

function E.screen(i)
  if i ~= 0 then return nil end
  local t = E.running()
  if not t then return nil end
  if core.on then
    copyCoreFrame()
    return core.img
  end
  local screenFile = DIR .. "screen.png"
  if love and love.filesystem and love.filesystem.getInfo and love.filesystem.getInfo(screenFile) then
    local ok, img = pcall(love.graphics.newImage, screenFile)
    if ok and img then return img end
  end
  local key = t.key or "game"
  if st.images[key .. "_screen"] then return st.images[key .. "_screen"] end
  if love and love.graphics and love.graphics.newCanvas then
    local c = love.graphics.newCanvas(1280, 720)
    local prevCanvas = love.graphics.getCanvas()
    love.graphics.setCanvas(c)
    love.graphics.clear(0.08, 0.09, 0.11, 1)
    love.graphics.setColor(0.9, 0.05, 0.1, 1)
    love.graphics.rectangle("fill", 0, 0, 1280, 8)
    local iconImg = E.icon(t)
    if iconImg then
      local is = 260
      love.graphics.setColor(1, 1, 1, 1)
      love.graphics.draw(iconImg, (1280 - is) / 2, (720 - is) / 2 - 30, 0, is / iconImg:getWidth(), is / iconImg:getHeight())
    end
    love.graphics.setColor(1, 1, 1, 0.95)
    love.graphics.printf(t.name or "Nintendo Switch", 40, 520, 1200, "center")
    love.graphics.setColor(0.04, 0.73, 0.9, 0.85)
    love.graphics.printf("NINTENDO SWITCH  •  720p  •  60 FPS", 40, 565, 1200, "center")
    love.graphics.setCanvas(prevCanvas)
    st.images[key .. "_screen"] = c
    return c
  end
  return nil
end

function E.boxArt(t)
  return E.icon(t)
end

local menuOpen = false
function E.menu()
  return {
    open = menuOpen,
    rows = {
      { label = "Resume", id = "resume" },
      { label = "Close Game", id = "close" },
    },
    sel = 1,
  }
end

function E.menuDo(id)
  if id == "resume" then
    menuOpen = false
  elseif id == "close" then
    menuOpen = false
    E.stop()
  end
end

function E.press(btn)
  if btn == "home" then
    menuOpen = not menuOpen
    if core.on then bridge(menuOpen and "nx.pause" or "nx.resume") end
    return
  end
  if core.on and not menuOpen then bridge("nx.key", btn .. "|1") end
end

function E.release(btn)
  if core.on and btn ~= "home" then bridge("nx.key", btn .. "|0") end
end

function E.touch(phase, u, v)
  if core.on and not menuOpen then bridge("nx.touch", ("%s|%.4f|%.4f"):format(phase, u or 0, v or 0)) end
end

function E.stop()
  if core.on then
    bridge("nx.stop")
    core.on, core.serial, core.img, core.data = false, -1, nil, nil
  end
  menuOpen = false
  st.running = nil
  st.lastPlayed = nil
  pcall(love.filesystem.remove, RUNNING)
  E.open("refresh")
end

function E.play(t)
  if not t or not t.key then return false end
  st.lastPlayed = t
  st.running = t.key
  -- the Eden core: inside the shell
  if E.coreInstalled() then
    local r = bridge("nx.start", t.key)
    if r == "ok" then
      core.on, core.serial = true, -1
      menuOpen = false
      return true
    end
    E.message = "The Eden core couldn't start this game: " .. tostring(r)
  end
  local mode = "3ds"
  if _G.state and _G.state.theme == "switch" then
    mode = "switch"
  else
    local ok, Skin = pcall(require, "fold3ds.skin")
    if ok and Skin and Skin.model and Skin.model() and Skin.model().mode == "full_screen" then
      mode = "switch"
    else
      local ok2, SM = pcall(require, "fold3ds.skinmanager")
      if ok2 and SM and SM.currentSkin == "switch" then mode = "switch" end
    end
  end
  return E.open("play?key=" .. t.key .. "&skin=" .. mode)
end

-- on the HOME menu (fold3ds.emus); functions looked up on E when called, as azahar.lua does,
-- so a wrapper on E.play (the Activity Log's) still sees every launch.
E.provider = {
  id = E.FOLDER,
  system = "Nintendo Switch",
  systems = { [SYS] = true },
  folder = { name = "Eden", sub = "Switch emulator settings and tools", items = E.ITEMS },
  setupTile = { id = "nx_setup", url = "setup", name = "Set Up Switch",
    sub = "Get the Eden core in the eShop's Cores shelf, then choose your Switch games folder" },
  addTile = { id = "nx_add", url = "games_folder", name = "Add Switch Games",
    sub = "Choose the folder your Switch games are in" },
  status = function() return E.status() end,
  games = function() return E.games() end,
  icon = function(t) return E.icon(t) end,
  iconPath = function(t) return E.iconPath(t) end,
  cart = function(t) return E.cart(t) end,
  cartSkin = function(t) return E.cartSkin(t) end,
  manual = function(t) return E.manual(t) end,
  open = function(url) return E.open(url) end,
  play = function(t) return E.play(t) end,
  screen = function(i) return E.screen(i) end,
  screenSize = function() return 1280, 720 end,
  boxArt = function(t) return E.boxArt(t) end,
  stop = function() return E.stop() end,
  menu = function() return E.menu() end,
  menuDo = function(id) return E.menuDo(id) end,
  press = function(btn) return E.press(btn) end,
  release = function(btn) return E.release(btn) end,
  touch = function(phase, u, v) return E.touch(phase, u, v) end,
  message = function() local m = E.message; E.message = nil; return m end,
  running = function() return E.running() end,
  init = function() return E.init() end,
  poll = function(time) return E.poll(time) end,
}

E.parse = parse

return E
