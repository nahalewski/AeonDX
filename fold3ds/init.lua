-- fold3ds: the Android foldable layer for gen1recomp.
--
-- On a foldable held open the app becomes a 3DS: the game (or the
-- launcher) draws inside the top shell's screen, the bottom shell carries
-- drawn A / B / X / Y, D-pad, stick, START, SELECT and HOME buttons that
-- press real input, and the bottom screen shows the launcher (menus) or,
-- in game, the game's Pokemon animated.  On the cover screen (the phone
-- closed) the closed lid fills the screen.
--
-- It plugs into the engine's own seams and touches no engine file:
--   * HostDisplay backend: beginFrame / endFrame around the launcher's and
--     the game's draw, so each renders into a canvas placed in a screen
--     cutout while believing that canvas is the window (love.graphics
--     size, window mode, safe area, mouse and touch queries are answered
--     in that "virtual window" while it is active);
--   * Input:overlayPressed / overlayReleased for the game buttons;
--   * the launcher's gamepadpressed / gamepadreleased for menu buttons;
--   * Orientation.apply("landscape") so the hinge runs across the middle;
--   * LauncherView.fold (a flag the patched launcher reads) for the compact
--     bottom-screen launcher, and the mod index API to list the community
--     catalog in FIND.
--
-- In game the top screen has three shapes, cycled by a tap on the C-stick
-- above X: the Game Boy's own 10:9 screen at a whole pixel scale, wide
-- (the whole screen opening), and full (the whole top panel, over the
-- Game Boy Color frame).  START's menu and the SELECT mod manager draw on
-- the bottom screen while the world stays on top.
--
-- POKEPORT_FOLD=ds|lid|off forces a mode on the desktop for testing.
local M = {}

local lg, lw, lm, lt = love.graphics, love.window, love.mouse, love.touch
local real = {
  getDimensions = lg.getDimensions, getWidth = lg.getWidth, getHeight = lg.getHeight,
  getPixelDimensions = lg.getPixelDimensions, getPixelWidth = lg.getPixelWidth, getPixelHeight = lg.getPixelHeight,
  setCanvas = lg.setCanvas,
  getMode = lw.getMode, getSafeArea = lw.getSafeArea,
  mouseGetPosition = lm.getPosition, mouseGetX = lm.getX, mouseGetY = lm.getY,
  touchGetTouches = lt.getTouches, touchGetPosition = lt.getPosition,
}
local orig = {}   -- the engine's event handlers, wrapped by install()
local Sticker = require("fold3ds.sticker")
local Theme3DS = require("fold3ds.theme3ds")
local Home = require("fold3ds.home3ds")
local Sfx = require("fold3ds.sfx")
local Cart3D = require("fold3ds.cart3d")
local Camera = require("fold3ds.camera")
local Dlplay = require("fold3ds.dlplay")
local Eshop = require("fold3ds.eshop")
local Activity = require("fold3ds.activity")
local Notes = require("fold3ds.notes")
local Manual = require("fold3ds.manual")
local HomeNX = require("fold3ds.homenx")
local Pads = require("fold3ds.pads")
local Friends = require("fold3ds.friends")
local EmuPlay = require("fold3ds.emuplay")
local EmuPage = require("fold3ds.emupage")
local Credits = require("fold3ds.credits")
local Teardown = require("fold3ds.teardown")
local PokeBank = require("fold3ds.pokebank")
local Emus = require("fold3ds.emus")
local SkinManager = require("fold3ds.skinmanager")
-- superseded by fold3ds.skin, not drawn; optional (it may not be in the
-- repo -- a missing module here stopped the whole 3DS layer loading)
local HomeSwitch
do
  local ok, m = pcall(require, "fold3ds.homeswitch")
  HomeSwitch = ok and type(m) == "table" and m or nil
end
local Skin = require("fold3ds.skin")

local DIR = "fold3ds/"
-- shell art (full size); cut = the screen opening in the art's pixels
-- full = the dark panel around the opening (the "full screen" game shape)
local TOP = { file = "skin/top_gbc.png", cut = { 153, 92, 668, 378 }, full = { 153, 92, 668, 378 } }
local BOTTOM = { file = "skin/bottom_empty.png", cut = { 218, 102, 532, 365 } }
local BOTTOM_SHELLS = {
  default = "skin/bottom_empty.png",
  clean = "skin/bottom_aeondx_clean.png",
  distressed = "skin/bottom_aeondx_distressed.png",
}
local SHEET = "skin/buttons.png"
local LID = "skin/lid.png"
-- wallpapers: behind the open 3DS, and behind the closed lid on the cover
local WALL_OPEN = "skin/wall_open.jpg"
local WALL_LID = "skin/wall_lid.jpg"
-- the closed shell inside lid.png (x, y, w, h); the rest is transparent
local LID_BOX = { 30, 157, 1390, 757 }
-- sockets in half-size units of the bottom shell (x, y centre, r radius);
-- sprite = rect in the half-size button sheet.  Both scale by 2 for the art.
local BUTTONS = {
  { name = "stick", x = 50, y = 97.5, r = 36, sprite = { 270, 228, 181, 182 }, kind = "dpad" },
  { name = "pad", x = 48, y = 177, r = 34, sprite = { 37, 228, 184, 186 }, kind = "dpad" },
  { name = "x", x = 439, y = 91.3, r = 15, sprite = { 381, 57, 133, 134 } },
  -- the C-stick in its socket above X: cycles the top screen's shape
  { name = "cstick", x = 412, y = 67, r = 10, sprite = { 515, 256, 62, 62 } },
  { name = "y", x = 412, y = 117.5, r = 15, sprite = { 560, 58, 133, 133 } },
  { name = "a", x = 465, y = 117.5, r = 15, sprite = { 35, 58, 132, 133 } },
  { name = "b", x = 439, y = 143.7, r = 15, sprite = { 209, 58, 132, 133 } },
  { name = "start", x = 413, y = 192, r = 11, sprite = { 515, 256, 62, 62 } },
  { name = "select", x = 413, y = 223.6, r = 11, sprite = { 515, 340, 62, 63 } },
  { name = "home", x = 243, y = 258.5, r = 18, sprite = { 288, 427, 144, 86 }, wide = true },
}
-- game buttons (Input names) and launcher buttons (SDL gamepad names)
local GAME_BTN = { a = "a", b = "b", x = "r", y = "l", start = "start", select = "select",
                   up = "up", down = "down", left = "left", right = "right", l = "l", r = "r" }
local PAD_BTN = { a = "a", b = "b", x = "x", y = "y", start = "start", select = "back",
                  up = "dpup", down = "dpdown", left = "dpleft", right = "dpright",
                  l = "leftshoulder", r = "rightshoulder", zl = "triggerleft", zr = "triggerright" }
-- The Switch skin speaks actions, not buttons. Both the d-pad and the face
-- buttons are mapped because the skin is a full-screen carousel, not the
-- clamshell: there is no touch furniture to fall back on.
local SKIN_ACTION = { left = "left", right = "right", a = "confirm", b = "back", x = "filter_next" }

-- ZL / ZR in game: the controller triggers (game speed down / up)
local GAME_TRIGGER = { zl = "lefttrigger", zr = "righttrigger" }

-- The shoulder buttons: L over ZL at the middle of the left edge, R over ZR
-- at the middle of the right, straddling the hinge.  They fade away when
-- nothing touches that edge and come back at a touch; Settings can hide
-- them for good.
local SHOULDERS = {
  { name = "l", label = "L", side = -1, slot = 0 },
  { name = "zl", label = "ZL", side = -1, slot = 1 },
  { name = "r", label = "R", side = 1, slot = 0 },
  { name = "zr", label = "ZR", side = 1, slot = 1 },
}
local SHOULDER_SHOW, SHOULDER_FADE = 3.0, 0.6

local state = {
  mode = "ds",           -- ds (3DS dual-screen UI by default) | lid | off
  kind = nil,            -- last HostDisplay kind: launcher | game | editor ...
  subject = nil,
  W = 0, H = 0,          -- real window
  L = nil,               -- layout
  vwin = nil,            -- the virtual window rect (x, y, w, h) in real pixels
  frameCanvas = nil,     -- while a subject draws: its canvas
  canvases = {},
  held = {},             -- touch id -> { name=, dirs= }
  vtouch = {},           -- touch id -> { x, y } inside the virtual window
  images = {},
  idle = { manifest = nil, sheets = {} },
  oriented = false,
  time = 0,
  screenMode = nil,      -- gbc | wide | full (the game's top screen shape)
  theme = "3ds",         -- the bottom-screen launcher's look: always the 3DS HOME menu
  shoulders = true,      -- L / ZL / R / ZR shown at the sides
  sounds = true,         -- the HOME menu's sound effects in the menus
  shoulderSeen = -10,    -- when an edge was last touched (they fade after)
  toast = nil,           -- { text, at } shown over the top screen
  arrowHeld = nil,       -- { dir, id, next } an on-screen scroll arrow held
  padScroll = nil,       -- { dir, next } the d-pad held up / down in the launcher
  split = nil,           -- this frame's in-game menu split { full, top, menus }
}

local MODES = { "full", "gbc" }
local MODE_NAMES = { gbc = "NATIVE", full = "FULL SCREEN" }
local SETTINGS_FILE = "fold3ds.cfg"
-- the community mod index (the catalog at gen1recomp.com/mod), and the copy
-- of its feed shipped in the APK so the list is there before any network
local MOD_INDEX = "bryanthaboi/gen1recomp-mod-index"
local MOD_INDEX_SNAPSHOT = "modindex/index.json"

---------------------------------------------------------------- helpers

local function image(file)
  if state.images[file] == nil then
    local ok, img = pcall(lg.newImage, DIR .. file)
    state.images[file] = ok and img or false
    if ok then img:setFilter("linear", "linear") end
  end
  return state.images[file] or nil
end

local function loadSettings()
  local ok, text = pcall(love.filesystem.read, SETTINGS_FILE)
  text = ok and type(text) == "string" and text or ""
  local mode = text:match("screen=(%a+)")
  state.screenMode = mode == "gbc" and "gbc" or "full"
  -- full screen is the default now: a shape saved before that is dropped
  if not text:match("screenv=2") then state.screenMode = "full" end
  -- skin theme: 3ds is default, switch full-screen option available
  local savedTheme = text:match("theme=(%a+)")
  state.theme = (savedTheme == "switch") and "switch" or "3ds"
  SkinManager.currentSkin = state.theme
  local savedOpacity = text:match("ctrl_opacity=([%d%.]+)")
  state.controlOpacity = savedOpacity and tonumber(savedOpacity) or 0.65
  state.shoulders = text:match("shoulders=(%d)") ~= "0"
  state.sounds = text:match("sounds=(%d)") ~= "0"
  state.volume = tonumber(text:match("volume=([%d%.]+)")) or 1
  state.volKeys = text:match("volkeys=(%d)") ~= "0"
  Cart3D.region = text:match("carts=(%a+)") == "jp" and "jp" or "intl"
  state.cartSkin = text:match("cart_skin=(%w+)") or "solid3d"
  Cart3D.style = state.cartSkin
  state.bottomShell = text:match("bottom_shell=(%w+)") or "default"
  state.shakeEgg = text:match("shake_egg=(%d)") ~= "0"
  if love.audio and love.audio.setVolume then pcall(love.audio.setVolume, state.volume) end
  Sfx.enabled = state.sounds
end

local function saveSettings()
  pcall(love.filesystem.write, SETTINGS_FILE, "screen=" .. tostring(state.screenMode) .. "\nscreenv=2"
    .. "\ntheme=" .. tostring(state.theme) .. "\nshoulders=" .. (state.shoulders and "1" or "0")
    .. "\nsounds=" .. (state.sounds and "1" or "0")
    .. ("\nvolume=%.2f"):format(state.volume or 1) .. "\nvolkeys=" .. (state.volKeys and "1" or "0")
    .. "\ncarts=" .. Cart3D.region
    .. "\ncart_skin=" .. tostring(state.cartSkin or "solid3d")
    .. "\nbottom_shell=" .. tostring(state.bottomShell or "default")
    .. "\nshake_egg=" .. (state.shakeEgg == false and "0" or "1")
    .. ("\nctrl_opacity=%.2f"):format(state.controlOpacity or 0.65) .. "\n")
end

-- physical pixels per LOVE unit (Android runs high-DPI: a unit is several pixels)
local function dpi()
  local w = real.getWidth()
  local pw = real.getPixelWidth and real.getPixelWidth() or w
  if not w or w <= 0 or not pw or pw <= 0 then return 1 end
  return pw / w
end

local function detectMode()
  local force = os.getenv and os.getenv("POKEPORT_FOLD")
  if force == "off" or force == "ds" or force == "lid" then return force end
  -- On a foldable with a physical hinge sensor, detect if shut closed
  local f = love.system and love.system.foldCamera
  if f then
    local ok, angle = pcall(f, "call", "hinge.angle", "")
    local deg = ok and tonumber(angle)
    if deg and deg <= 10 then return "lid" end
  end
  -- 3DS is the default UI across all devices, screens, and aspect ratios
  return "ds"
end

-- the top shell with its whole dark panel cut out: the panel is the top
-- screen (the printed Game Boy Color frame is gone), as on a 3DS
local function topShell()
  if state.images.topShell == nil then
    state.images.topShell = false
    local ok, data = pcall(love.image.newImageData, DIR .. TOP.file)
    if ok and data then
      local x0, y0, w, h = TOP.full[1], TOP.full[2], TOP.full[3], TOP.full[4]
      local r = 14      -- the panel's rounded corners
      data:mapPixel(function(x, y, cr, cg, cb, ca)
        local dx = math.max(x0 + r - x, 0, x - (x0 + w - 1 - r))
        local dy = math.max(y0 + r - y, 0, y - (y0 + h - 1 - r))
        if dx * dx + dy * dy <= r * r then return cr, cg, cb, 0 end
        return cr, cg, cb, ca
      end, x0, y0, w, h)
      local img = lg.newImage(data)
      img:setFilter("linear", "linear")
      state.images.topShell = img
    end
  end
  return state.images.topShell or image(TOP.file)
end

local function bottomShell()
  local key = state.bottomShell or "default"
  local file = BOTTOM_SHELLS[key] or BOTTOM_SHELLS.default
  return image(file) or image(BOTTOM.file)
end

local function layout(W, H)
  local top, bottom = topShell(), bottomShell()
  if not top or not bottom then return nil end
  local topH = math.floor(H / 2)
  local botH = H - topH
  local L = { W = W, H = H, topH = topH }
  local tw, th = top:getDimensions()
  local sc = math.min(W / tw, topH / th)
  L.top = { x = math.floor((W - tw * sc) / 2), y = topH - th * sc, sc = sc, img = top }
  -- the top screen: the whole panel (it was the opening in the printed
  -- Game Boy Color frame)
  L.topCut = { x = math.floor(L.top.x + TOP.full[1] * sc), y = math.floor(L.top.y + TOP.full[2] * sc),
               w = math.floor(TOP.full[3] * sc), h = math.floor(TOP.full[4] * sc) }
  local bw, bh = bottom:getDimensions()
  local sb = math.min(W / bw, botH / bh)
  L.bottom = { x = math.floor((W - bw * sb) / 2), y = topH, sc = sb, img = bottom }
  L.botCut = { x = math.floor(L.bottom.x + BOTTOM.cut[1] * sb), y = math.floor(L.bottom.y + BOTTOM.cut[2] * sb),
               w = math.floor(BOTTOM.cut[3] * sb), h = math.floor(BOTTOM.cut[4] * sb) }
  L.topFull = { x = math.floor(L.top.x + TOP.full[1] * sc), y = math.floor(L.top.y + TOP.full[2] * sc),
                w = math.floor(TOP.full[3] * sc), h = math.floor(TOP.full[4] * sc) }
  -- the Game Boy's own screen: 10:9 at the largest whole number of physical
  -- pixels per Game Boy pixel that fits the opening, centred in it
  do
    local d = dpi()
    local k = math.floor(math.min(L.topCut.w * d / 160, L.topCut.h * d / 144))
    local gw, gh
    if k >= 1 then
      gw, gh = math.floor(160 * k / d), math.floor(144 * k / d)
    else
      gh = L.topCut.h
      gw = math.floor(gh * 160 / 144)
    end
    L.topGbc = { x = L.topCut.x + math.floor((L.topCut.w - gw) / 2),
                 y = L.topCut.y + math.floor((L.topCut.h - gh) / 2), w = gw, h = gh }
  end
  -- the launcher's window is the bottom opening less a column on its right
  -- for the up / down scroll arrows
  do
    local c = L.botCut
    local aw = math.max(18, math.floor(c.w * 0.085))
    L.botView = { x = c.x, y = c.y, w = c.w - aw, h = c.h }
    L.arrows = { x = c.x + c.w - aw, y = c.y, w = aw, h = c.h }
    L.arrowUp = { x = L.arrows.x, y = c.y, w = aw, h = math.floor(c.h / 2) }
    L.arrowDown = { x = L.arrows.x, y = c.y + math.floor(c.h / 2), w = aw, h = c.h - math.floor(c.h / 2) }
  end
  L.s2 = sb * 2          -- half-size units -> pixels
  L.topH = topH
  L.W, L.H = W, H
  return L
end

-- where the game draws on the top screen, by the chosen shape
local function gameRect(L)
  if state.screenMode == "full" then return L.topFull end
  return L.topGbc
end

-- the 3DS theme's HOME menu is up (the grid, or a tile opened from it)
local function homeActive()
  return state.mode == "ds" and state.theme == "3ds" and state.kind ~= "game"
end

local skipBoot   -- the boot screen (defined with the drawing)
local coverTouch -- a touch on the cover screen (defined with the drawing)
local onInnerEye -- the inner camera lens (defined with the drawing)

-- the Camera applet owns both screens while it is open (launcher only)
local function cameraOn()
  return state.mode == "ds" and state.kind ~= "game" and state.L ~= nil and Camera.isOpen()
end

-- a DS / Virtual Console game playing inside the shell owns both screens
local function emuOn()
  return state.mode == "ds" and state.kind ~= "game" and state.L ~= nil and EmuPlay.active() ~= nil
end

-- an emulator's settings page (from its folder) owns both screens
local function pageOn()
  -- Credits (from any settings menu) draws and takes input through EmuPage
  return state.mode == "ds" and state.kind ~= "game" and state.L ~= nil
    and (Credits.isOpen() or EmuPage.active() ~= nil)
end

-- the Activity Log owns both screens while it is open (launcher only)
local function actOn()
  return state.mode == "ds" and state.kind ~= "game" and state.L ~= nil and Activity.isOpen()
end

-- the Friend List and Game Notes, each owning both screens while open
local APPS = { friends = Friends, gamenotes = Notes, pokebank = PokeBank }
local function appOn()
  if not (state.mode == "ds" and state.kind ~= "game" and state.L ~= nil) then return nil end
  for id, m in pairs(APPS) do
    if m.isOpen() then return id, m end
  end
end
local function appExit(m, r) if r == "exit" then m.close() end end

-- the eShop owns both screens while it is open (launcher only)
local function esOn()
  return state.mode == "ds" and state.kind ~= "game" and state.L ~= nil and Eshop.isOpen()
end

-- the eShop's answers: "exit" closes it, "mods" goes on to the Mods applet
local function eshopDone(r)
  if r == "exit" then Eshop.close()
  elseif r == "mods" then Eshop.close(); Home.openApplet(state.subject, "mods")
  elseif type(r) == "string" and r:match("^app:") then
    -- one of AeonDX's own apps, downloaded from the eShop: open it
    local app = APPS[r:sub(5)]
    Eshop.close()
    if app then app.open() end
  end
end

-- Download Play owns both screens while it is open (launcher only)
local function dlOn()
  return state.mode == "ds" and state.kind ~= "game" and state.L ~= nil and Dlplay.isOpen()
end

---------------------------------------------------------------- volume slider
-- The shell's VOL slider (left edge of the top half): drag it, or press the
-- phone's volume keys (they move it instead of Android's volume, with no
-- popup, while Settings > 3DS Shell > Volume keys is on).  It sets the
-- app's own volume; full up is the top, OFF the bottom.
local VOL = { x = 3, top = 305, bottom = 405, knob = { 20, 36 } }   -- top_gbc.png pixels (the VOL slot)

local function bridge(cmd, arg)
  local f = love.system and love.system.foldCamera
  if not f then return nil end
  local ok, out = pcall(f, "call", cmd, arg or "")
  return ok and out or nil
end

local function setVolume(v, quiet)
  v = math.max(0, math.min(1, v))
  if math.abs(v - (state.volume or 1)) < 0.001 then return end
  state.volume = v
  if love.audio then love.audio.setVolume(v) end
  state.volSaveAt = state.time + 1
end

local function volumeKnob(L)
  local sc = L.top.sc
  local y = VOL.bottom - (VOL.bottom - VOL.top) * (state.volume or 1)
  return { x = L.top.x + VOL.x * sc, y = L.top.y + y * sc, w = VOL.knob[1] * sc, h = VOL.knob[2] * sc }
end

local function volumeZone(L, x, y)
  local sc = L.top.sc
  local zx, zy = L.top.x + (VOL.x - 14) * sc, L.top.y + (VOL.top - 20) * sc
  return x >= zx and x <= zx + (VOL.knob[1] + 34) * sc
     and y >= zy and y <= zy + (VOL.bottom - VOL.top + VOL.knob[2] + 40) * sc
end

local function volumeFromY(L, y)
  local sc = L.top.sc
  local top = L.top.y + (VOL.top + VOL.knob[2] / 2) * sc
  local bottom = L.top.y + (VOL.bottom + VOL.knob[2] / 2) * sc
  setVolume(1 - (y - top) / (bottom - top))
end

local function drawVolume(L)
  local key = "skin:vol_knob"
  if state.images[key] == nil then
    local ok, img = pcall(lg.newImage, DIR .. "skin/vol_knob.png")
    state.images[key] = ok and img or false
  end
  local img = state.images[key]
  if not img then return end
  local k = volumeKnob(L)
  lg.setColor(1, 1, 1, 1)
  lg.draw(img, k.x, k.y, 0, L.top.sc, L.top.sc)
end

local function virtualRect()
  local L = state.L
  if not L then return nil end
  if state.kind == "game" then return gameRect(L) end
  if homeActive() and Home.opened() then
    -- an opened tile: the launcher's page under the HOME menu's back bar
    local bh = Home.barHeight(L.botCut)
    return { x = L.botView.x, y = L.botView.y + bh, w = L.botView.w, h = L.botView.h - bh }
  end
  return L.botView
end

local function vactive()
  return state.mode == "ds" and state.vwin ~= nil
end

local function inside(r, x, y)
  return x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h
end

---------------------------------------------------------------- buttons

-- the shell button under a point (bottom half, outside the screen)
-- where each shoulder button sits: the margin beside the shells (or over
-- their edge on a narrow screen), centred on the hinge
local function shoulderRect(L, sb)
  local margin = math.max(L.bottom.x, L.top.x)
  local w = math.max(math.min(margin * 0.8, L.W * 0.1), L.W * 0.06)
  local h = math.min(L.H * 0.11, w * 1.1)
  local gap = h * 0.25
  local x = sb.side < 0 and math.max(4, (margin - w) / 2) or L.W - math.max(4, (margin - w) / 2) - w
  local y = L.topH - h - gap / 2 + sb.slot * (h + gap)
  return { x = x, y = y, w = w, h = h }
end

-- sockets that sit elsewhere on a bottom shell's art (its BOTTOM_SHELLS key)
local SHELL_SOCKETS = {
  clean = { start = { 413.3, 189.5 }, select = { 413.3, 220.3 } },
}
-- a button's centre on the chosen bottom shell, in pixels
local function socketAt(L, b)
  local o = SHELL_SOCKETS[state.bottomShell or "default"]
  o = o and o[b.name]
  local x, y = b.x, b.y
  if o then x, y = o[1], o[2] end
  return L.bottom.x + x * L.s2, L.bottom.y + y * L.s2
end

-- the edge strips that wake the shoulder buttons
local function shoulderZone(L, x, y)
  local margin = math.max(L.bottom.x, L.top.x, L.W * 0.06)
  return (x < margin or x > L.W - margin) and math.abs(y - L.topH) < L.H * 0.25
end

-- (defined with the skins below; buttonAt and the pad routing reach it first)
local skinActive

local function buttonAt(x, y)
  if skinActive() then return nil end
  local L = state.L
  if M.debug then print("fold3ds buttonAt L=" .. tostring(L) .. " topH=" .. tostring(L and L.topH)) end
  if L and state.shoulders then
    for _, sb in ipairs(SHOULDERS) do
      local r = shoulderRect(L, sb)
      if x >= r.x - 6 and x <= r.x + r.w + 6 and y >= r.y - 4 and y <= r.y + r.h + 4 then
        state.shoulderSeen = state.time
        return sb
      end
    end
  end
  if not L or y < L.topH then return nil end
  for _, b in ipairs(BUTTONS) do
    if M.debug then print("fold3ds  check " .. b.name) end
    local cx, cy = socketAt(L, b)
    local r = b.r * L.s2
    local dx, dy = x - cx, y - cy
    if b.kind == "dpad" then
      if math.abs(dx) <= r * 1.3 and math.abs(dy) <= r * 1.3 then return b end
    elseif b.wide then
      if math.abs(dx) <= r * 2 and math.abs(dy) <= r * 1.2 then return b end
    elseif dx * dx + dy * dy <= (r * 1.25) * (r * 1.25) then
      return b
    end
  end
  return nil
end

-- directions a d-pad / stick touch holds
local function dirsAt(b, x, y)
  local L = state.L
  local cx, cy = socketAt(L, b)
  local r = b.r * L.s2
  local dx, dy = x - cx, y - cy
  local ax, ay = math.abs(dx), math.abs(dy)
  local d = {}
  if ax > r * 0.2 or ay > r * 0.2 then
    if ax >= ay * 0.45 then d[dx < 0 and "left" or "right"] = true end
    if ay >= ax * 0.45 then d[dy < 0 and "up" or "down"] = true end
  end
  return d
end

local function gameInput()
  local ok, Input = pcall(require, "src.core.Input")
  return ok and Input or nil
end

---------------------------------------------------------------- launcher scroll
-- What an up / down arrow (or the d-pad) scrolls: the open Settings page, else
-- the open popup's list, else the tab's panel, else the whole page.
local function scrollTarget()
  local imp = state.subject
  if not imp or state.kind == "game" then return nil end
  local s = imp._settings
  if s and imp._modalKey == "_settings" and not s.confirm then
    return { get = function() return s.scroll or 0 end, max = s.maxScroll or 0,
             set = function(v) s.scroll = v end }
  end
  if imp._modalKey then
    local ms = imp._modalScroll and imp._modalScroll[imp._modalKey]
    if ms and (ms.maxScroll or 0) > 0 then
      return { get = function() return ms.scroll or 0 end, max = ms.maxScroll,
               set = function(v) ms.scroll = v end }
    end
    return nil
  end
  local tab = imp.tab or "red"
  local tmax = imp._tabScrollMax and imp._tabScrollMax[tab] or 0
  local pmax = imp._pageScrollMax or 0
  if tmax <= 0 and pmax <= 0 then return nil end
  -- the page (header) scroll first on the way down, last on the way up
  return {
    get = function() return (imp._pageScroll or 0) + ((imp._tabScroll and imp._tabScroll[tab]) or 0) end,
    max = tmax + pmax,
    set = function(v)
      local page = math.min(pmax, v)
      imp._pageScroll = page
      imp._tabScroll = imp._tabScroll or {}
      imp._tabScroll[tab] = math.max(0, math.min(tmax, v - page))
    end,
  }
end

local function canScroll(dir)
  local t = scrollTarget()
  if not t or t.max <= 0 then return false end
  local at = t.get()
  if dir < 0 then return at > 0.5 end
  return at < t.max - 0.5
end

local function scrollBy(dir, mult)
  local t = scrollTarget()
  if not t or t.max <= 0 then return false end
  local step = math.max(24, math.floor((state.vwin and state.vwin.h or 300) * 0.3)) * (mult or 1)
  t.set(math.max(0, math.min(t.max, t.get() + dir * step)))
  return true
end

-- the launcher's own text fields / file browser keep the d-pad
local function launcherOwnsPad()
  local ok, Kit = pcall(require, "src.ui.kit.Kit")
  if not ok then return false end
  return (Kit.FileBrowser and Kit.FileBrowser.active)
    or (Kit.VirtualKeyboard and Kit.VirtualKeyboard.active) or false
end

local REPEAT_FIRST, REPEAT_NEXT = 0.35, 0.09

local function toast(text)
  state.toast = { text = text, at = state.time }
end

local function cycleScreen()
  local idx = 1
  for i, m in ipairs(MODES) do if m == state.screenMode then idx = i end end
  state.screenMode = MODES[idx % #MODES + 1]
  Sfx.play("screen", true)
  saveSettings()
  toast(MODE_NAMES[state.screenMode])
end

---------------------------------------------------------------- in-game menus
-- The states that draw on the bottom screen: START's menu and the mod
-- manager, and everything opened on top of them.
local MENU_BASE = { StartMenu = true, Gen2StartMenu = true, ManagerState = true }

local function menuBase(game)
  local st = game and game.stack and game.stack.states
  if type(st) ~= "table" then return nil end
  for i = 1, #st do
    local s = st[i]
    if type(s) == "table" and MENU_BASE[s.screenId] then return i end
  end
  return nil
end

-- SELECT in the overworld opens the mod manager (and closes it again)
local function selectOpensMods(game)
  if not game or not game.stack then return false end
  local top = game.stack.top and game.stack:top()
  local ok, Screens = pcall(require, "src.ui.Screens")
  if not ok then return false end
  if top and top.screenId == "ManagerState" then
    game.stack:pop()
    return true
  end
  local overworld = (top ~= nil and top == game.overworld)
    or (top == nil and game.world ~= nil and game.phase == "play")
  if not overworld then return false end
  pcall(Screens.push, game, "ManagerState")
  return true
end

local function press(btn, src)
  if skipBoot() then return end
  if emuOn() then
    -- the C-stick is the screen's shape here too (full screen / border)
    if btn == "cstick" then cycleScreen() return end
    EmuPlay.press(btn)
    return
  end
  if pageOn() then EmuPage.button(btn) return end
  if Sticker.editing() and state.kind ~= "game" then Sticker.button(btn) return end
  if cameraOn() then
    if Camera.button(btn) == "exit" then Camera.close() end
    return
  end
  if dlOn() then
    if Dlplay.button(btn) == "exit" then Dlplay.close() end
    return
  end
  if esOn() then eshopDone(Eshop.button(btn)) return end
  if actOn() then if Activity.button(btn) == "exit" then Activity.close() end return end
  do local _, m = appOn(); if m then appExit(m, m.button(btn)) return end end
  if btn == "cstick" then cycleScreen() return end
  if state.kind == "game" then
    if btn == "select" and selectOpensMods(state.subject) then return end
    if GAME_TRIGGER[btn] then
      local g = state.subject
      if g and g.gamepadpressed then pcall(g.gamepadpressed, g, nil, GAME_TRIGGER[btn]) end
      return
    end
    if btn == "home" then
      -- HOME: back to the launcher (the engine turns quit into a return)
      Sfx.play("home", true)
      love.event.quit()
      return
    end
    local Input = gameInput()
    if Input and Input.overlayPressed and GAME_BTN[btn] then Input:overlayPressed(GAME_BTN[btn]) end
  else
    if skinActive() and PokeBank.isOpen() then appExit(PokeBank, PokeBank.button(btn)) return end
    if skinActive() and Eshop.isOpen() then eshopDone(Eshop.button(btn)) return end
    if skinActive() then
      local action = SKIN_ACTION[btn]
      if action == "confirm" then
        local g = Skin.selectedGame and Skin.selectedGame()
        if g then
          Sfx.play("open")
          Emus.play(g)
          return
        end
      end
      if action and Skin.input(action) then return end
    end
    local s = state.subject
    if homeActive() then
      -- the HOME menu: HOME returns to it; on the grid the pads move and A opens
      if btn == "home" then Sfx.play("homeMenu"); Home.goHome(s, true) return end
      if Home.showing() then
        -- L or R: the Camera, as on the 3DS HOME menu
        if (btn == "l" or btn == "r") and Theme3DS.active then Camera.open() return end
        Home.button(s, btn)
        return
      end
      if btn == "b" and s and not s._modalKey and not launcherOwnsPad() then
        Sfx.play("cancel")
        Home.goHome(s, true)
        return
      end
    end
    if btn == "home" then Sfx.play("homeMenu") return end
    -- the d-pad's up / down scroll the bottom screen; the circle pad and the
    -- d-pad's left / right move the launcher's focus
    if src == "pad" and (btn == "up" or btn == "down") and not launcherOwnsPad() then
      local dir = btn == "up" and -1 or 1
      if scrollBy(dir) then
        Sfx.play("scroll")
        state.padScroll = { dir = dir, next = state.time + REPEAT_FIRST }
        return
      end
    end
    if s and s.gamepadpressed and PAD_BTN[btn] then pcall(s.gamepadpressed, s, nil, PAD_BTN[btn]) end
  end
end

local function release(btn, src)
  if emuOn() then EmuPlay.release(btn) return end
  if pageOn() then return end
  if btn == "cstick" then return end
  if Sticker.editing() and state.kind ~= "game" then return end
  if cameraOn() or dlOn() or esOn() or actOn() or appOn() then return end
  if src == "pad" and (btn == "up" or btn == "down") then state.padScroll = nil end
  if state.kind == "game" and GAME_TRIGGER[btn] then
    local g = state.subject
    if g and g.gamepadreleased then pcall(g.gamepadreleased, g, nil, GAME_TRIGGER[btn]) end
    return
  end
  if state.kind == "game" then
    local Input = gameInput()
    if Input and Input.overlayReleased and GAME_BTN[btn] then Input:overlayReleased(GAME_BTN[btn]) end
  else
    local s = state.subject
    if s and s.gamepadreleased and PAD_BTN[btn] then pcall(s.gamepadreleased, s, nil, PAD_BTN[btn]) end
  end
end

local function holdStart(id, b, x, y)
  local h = { name = b.name, kind = b.kind, dirs = {} }
  state.held[id] = h
  if b.kind == "dpad" then
    h.dirs = dirsAt(b, x, y)
    for d in pairs(h.dirs) do press(d, b.name) end
  else
    press(b.name)
  end
end

local function holdMove(id, x, y)
  local h = state.held[id]
  if not h or h.kind ~= "dpad" then return end
  local b
  for _, bb in ipairs(BUTTONS) do if bb.name == h.name then b = bb end end
  local nd = dirsAt(b, x, y)
  for d in pairs(h.dirs) do if not nd[d] then release(d, h.name) end end
  for d in pairs(nd) do if not h.dirs[d] then press(d, h.name) end end
  h.dirs = nd
end

local function holdEnd(id)
  local h = state.held[id]
  if not h then return end
  state.held[id] = nil
  if h.kind == "dpad" then
    for d in pairs(h.dirs) do release(d, h.name) end
  else
    release(h.name)
  end
end

local function releaseAll()
  for id in pairs(state.held) do holdEnd(id) end
  state.vtouch = {}
  state.arrowHeld, state.padScroll = nil, nil
end

-- The bottom screen's right-hand column: in the Classic theme, sync /
-- settings / quit at its top (the launcher's tab row gives them up so all
-- its tabs fit), then the up / down scroll arrows in what is left.
local COLUMN_BUTTONS = {
  { id = "sync", icon = "arrow-left-right" },
  { id = "gear", icon = "settings" },
  { id = "quit", icon = "x" },
}
local function clusterInColumn()
  return state.mode == "ds" and state.theme ~= "3ds" and state.kind ~= "game"
end

local function columnRects(L)
  local a = L.arrows
  local top = a.y
  local buttons = {}
  if clusterInColumn() then
    local s = a.w
    for i, b in ipairs(COLUMN_BUTTONS) do
      buttons[i] = { id = b.id, icon = b.icon, x = a.x, y = a.y + (i - 1) * s, w = a.w, h = s }
    end
    top = a.y + #COLUMN_BUTTONS * s + math.floor(s * 0.2)
  end
  local h = a.y + a.h - top
  local up = { x = a.x, y = top, w = a.w, h = math.floor(h / 2) }
  local down = { x = a.x, y = top + math.floor(h / 2), w = a.w, h = h - math.floor(h / 2) }
  return up, down, buttons
end

local function columnButtonAt(x, y)
  local L = state.L
  if not L or state.kind == "game" or not clusterInColumn() then return nil end
  local _, _, buttons = columnRects(L)
  for _, b in ipairs(buttons) do
    if inside(b, x, y) then return b end
  end
end

local function pressColumnButton(b)
  local imp = state.subject
  if not imp then return end
  Sfx.play("button")
  if b.id == "sync" and imp._openSync then imp:_openSync()
  elseif b.id == "gear" and imp._openSettings then imp:_openSettings()
  elseif b.id == "quit" and imp._quitApp then imp:_quitApp() end
end

-- the on-screen scroll arrows at the bottom screen's right edge
local function arrowAt(x, y)
  local L = state.L
  if not L or state.kind == "game" then return nil end
  local up, down = columnRects(L)
  if inside(up, x, y) then return -1 end
  if inside(down, x, y) then return 1 end
  return nil
end

local function arrowStart(id, dir)
  Sfx.play(canScroll(dir) and "scroll" or "noMove")
  scrollBy(dir)
  state.arrowHeld = { dir = dir, id = id, next = state.time + REPEAT_FIRST }
end

local function arrowEnd(id)
  if state.arrowHeld and state.arrowHeld.id == id then state.arrowHeld = nil end
end

local function buttonLit(b)
  for _, h in pairs(state.held) do
    if h.name == b.name then return true, h.dirs end
  end
  return false, nil
end

---------------------------------------------------------------- events

local topScreenTap   -- defined with the drawing (the launcher's top screen)
-- the cover sticker editor owns both screens while it is open (launcher only)
local function editingSticker()
  return state.mode == "ds" and state.kind ~= "game" and state.L ~= nil and Sticker.editing()
end

-- a touch on the 3DS HOME menu (the grid, or an opened tile's back bar)
local function homeTouch(id, x, y)
  if not homeActive() or not state.L then return false end
  if Home.showing() then
    if inside(state.L.botCut, x, y) then return Home.pressed(state.subject, id, x, y) end
    return false
  end
  return Home.tapBar(state.subject, x, y)
end
-- The Switch skin, when one is selected AND it loaded.
--
-- Two loaders existed. `homeswitch.lua` + `skinmanager.lua` parse skin.xml and
-- then never read the result - grep `config` in homeswitch.lua: zero hits - so
-- its layout is hard-coded Lua and the XML only supplies textures by literal
-- filename. `fold3ds.skin` returns an interpreted model (mode, filters,
-- carousel, statusBar, systemRow, safe area, variants) built from the file.
-- Ben's rule is that the theme is driven by the XML and never hard-coded, so
-- this is the one that is drawn. HomeSwitch stays on disk, unwired; deleting
-- it is Ben's call.
--
-- A missing or broken skin.xml leaves skinModel nil and the 3DS clamshell
-- draws instead, which is why every use goes through here rather than testing
-- state.theme directly.
skinActive = function()
  return state.theme == "switch" and state.skinModel ~= nil
end

-- Reload when the selection changes. Failure is remembered, not retried every
-- frame, and the reason is kept so Settings can say why it fell back.
local function loadSkin()
  if state.theme ~= "switch" then state.skinModel, state.skinError = nil, nil return end
  local m, err = Skin.load("switch")
  state.skinModel, state.skinError = m, (not m) and tostring(err or "skin.xml missing") or nil
  if not m then print("fold3ds: Switch skin did not load (" .. tostring(state.skinError) .. "); using the 3DS shell") end
end

-- The library, handed to the skin only when it actually changes: Skin.games()
-- resets the carousel selection, so calling it every frame would pin the
-- cursor to the first tile and look like broken input.
local function skinGames()
  local list = Emus.games()
  local sig = #list
  for i = 1, #list do sig = sig .. "|" .. tostring(list[i].id) end
  if sig ~= state.skinGamesSig then
    state.skinGamesSig = sig
    Skin.games(list)
  end
end

local function toVirtual(x, y)
  if skinActive() then return x, y, false end
  local r = state.vwin
  if not r then return x, y, false end
  return x - r.x, y - r.y, inside(r, x, y)
end

local function onTouchPressed(id, x, y, dx, dy, pr)
  if M.debug then print("fold3ds touchpressed enter mode=" .. tostring(state.mode)) end
  if state.mode ~= "ds" then
    if state.mode == "lid" then coverTouch("pressed", id, x, y) return end
    return orig.touchpressed and orig.touchpressed(id, x, y, dx, dy, pr)
  end
  if state.L and shoulderZone(state.L, x, y) then state.shoulderSeen = state.time end
  if skipBoot() then return end
  if state.L and volumeZone(state.L, x, y) then state.volDrag = id; volumeFromY(state.L, y) return end
  -- the inner camera: stickers for the shells
  if state.L and state.kind ~= "game" and not Sticker.editing() and onInnerEye(state.L, x, y) then
    Sfx.play("open")
    Sticker.open(nil, 1)
    return
  end
  local b = buttonAt(x, y)
  if M.debug then print("fold3ds buttonAt -> " .. tostring(b and b.name)) end
  if b then holdStart(id, b, x, y) return end
  if emuOn() then EmuPlay.touch("pressed", id, x, y) return end
  if skinActive() then
    local m = Skin.model and Skin.model()
    if m and m.mode == "full_screen" then
      local L = Skin.layout and Skin.layout(state.W or real.getWidth(), state.H or real.getHeight())
      local c = m.carousel
      local p = Skin.page and Skin.page(Skin.count(), Skin.selected(), m, m.baseW)
      if L and c and p and p.last >= p.first then
        local shown = p.last - p.first + 1
        local span = shown * c.tileW + (shown - 1) * c.spacing
        local startX = (m.baseW - span) / 2
        for i = p.first, p.last do
          local isSel = (i == Skin.selected())
          local scale = isSel and c.selScale or c.unselScale
          local dw, dh = c.tileW * scale, c.tileH * scale
          local dy = c.y + (c.h - dh) / 2
          local tx = startX + (c.tileW - dw) / 2
          local rx, ry = L.x(tx), L.y(dy)
          local rw, rh = L.n(dw), L.n(dh)
          if x >= rx and x <= rx + rw and y >= ry and y <= ry + rh then
            if isSel then
              local g = Skin.selectedGame and Skin.selectedGame()
              if g then
                Sfx.play("open")
                Emus.play(g)
                return
              end
            else
              Skin.selectGame(i)
              Sfx.play("select")
              return
            end
          end
          startX = startX + c.tileW + c.spacing
        end
      end
    end
    return
  end
  if pageOn() then EmuPage.pressed(id, x, y) return end
  if editingSticker() then Sticker.pressed(id, x, y, state.L.botCut, state.L.topCut) return end
  if cameraOn() then Camera.pressed(id, x, y) return end
  if dlOn() then Dlplay.pressed(id, x, y) return end
  if esOn() then Eshop.pressed(id, x, y) return end
  if actOn() then Activity.pressed(id, x, y) return end
  do local _, m = appOn(); if m then m.pressed(id, x, y) return end end
  if homeTouch(id, x, y) then return end
  local cb = columnButtonAt(x, y)
  if cb then state.columnDown = cb.id; pressColumnButton(cb) return end
  local dir = arrowAt(x, y)
  if dir then arrowStart(id, dir) return end
  if topScreenTap(x, y) then return end
  local lx, ly, ok = toVirtual(x, y)
  if M.debug then print(("fold3ds touch %d,%d -> %s %.0f,%.0f kind=%s"):format(x, y, tostring(ok), lx, ly, tostring(state.kind))) end
  if ok then
    state.vtouch[id] = { lx, ly }
    if orig.touchpressed then
      local okc, err = pcall(orig.touchpressed, id, lx, ly, dx, dy, pr)
      if M.debug then print("fold3ds forwarded ok=" .. tostring(okc)) end
      if not okc then print("fold3ds: touchpressed error: " .. tostring(err)) end
    end
  end
end

local function onTouchMoved(id, x, y, dx, dy, pr)
  if state.mode ~= "ds" then
    if state.mode == "lid" then coverTouch("moved", id, x, y) return end
    return orig.touchmoved and orig.touchmoved(id, x, y, dx, dy, pr)
  end
  if state.volDrag == id then volumeFromY(state.L, y) return end
  if state.held[id] then holdMove(id, x, y) return end
  if editingSticker() then Sticker.moved(id, x, y) return end
  if cameraOn() then Camera.moved(id, x, y) return end
  if dlOn() then Dlplay.moved(id, x, y) return end
  if esOn() then Eshop.moved(id, x, y) return end
  if actOn() then Activity.moved(id, x, y) return end
  if emuOn() then EmuPlay.touch("moved", id, x, y) return end
  if pageOn() then EmuPage.moved(id, x, y) return end
  do local _, m = appOn(); if m then m.moved(id, x, y) return end end
  if Home.moved(state.subject, id, x, y) then return end
  if state.vtouch[id] then
    local lx, ly = toVirtual(x, y)
    state.vtouch[id] = { lx, ly }
    if orig.touchmoved then return orig.touchmoved(id, lx, ly, dx, dy, pr) end
  end
end

local function onTouchReleased(id, x, y, dx, dy, pr)
  if state.mode ~= "ds" then
    if state.mode == "lid" then coverTouch("released", id, x, y) return end
    return orig.touchreleased and orig.touchreleased(id, x, y, dx, dy, pr)
  end
  if state.volDrag == id then state.volDrag = nil return end
  if state.held[id] then holdEnd(id) return end
  if editingSticker() then Sticker.released(id) return end
  if cameraOn() then if Camera.released(id, x, y) == "exit" then Camera.close() end return end
  if dlOn() then if Dlplay.released(id, x, y) == "exit" then Dlplay.close() end return end
  if esOn() then eshopDone(Eshop.released(id, x, y)) return end
  if actOn() then if Activity.released(id, x, y) == "exit" then Activity.close() end return end
  if emuOn() then EmuPlay.touch("released", id, x, y) return end
  if pageOn() then EmuPage.released(id, x, y) return end
  do local _, m = appOn(); if m then appExit(m, m.released(id, x, y)) return end end
  if Home.released(state.subject, id, x, y) then return end
  if state.arrowHeld and state.arrowHeld.id == id then arrowEnd(id) return end
  if state.vtouch[id] then
    state.vtouch[id] = nil
    local lx, ly = toVirtual(x, y)
    if orig.touchreleased then return orig.touchreleased(id, lx, ly, dx, dy, pr) end
  end
end

-- a real mouse (desktop testing) is a finger too; Android's synthesized
-- mouse twin of a touch just gets the same coordinate change
local function onMousePressed(x, y, button, istouch, presses)
  if state.mode ~= "ds" then
    if state.mode == "lid" then if not istouch then coverTouch("pressed", "mouse", x, y) end return end
    return orig.mousepressed and orig.mousepressed(x, y, button, istouch, presses)
  end
  if not istouch and button == 1 and skipBoot() then return end
  if not istouch and button == 1 and state.L and state.kind ~= "game" and not Sticker.editing()
      and onInnerEye(state.L, x, y) then
    Sfx.play("open")
    Sticker.open(nil, 1)
    return
  end
  if not istouch and button == 1 and state.L and volumeZone(state.L, x, y) then
    state.volDrag = "mouse"; volumeFromY(state.L, y) return
  end
  if not istouch and button == 1 then
    local b = buttonAt(x, y)
    if b then holdStart("mouse", b, x, y) return end
    if editingSticker() then Sticker.pressed("mouse", x, y, state.L.botCut, state.L.topCut) return end
    if cameraOn() then Camera.pressed("mouse", x, y) return end
    if dlOn() then Dlplay.pressed("mouse", x, y) return end
    if esOn() then Eshop.pressed("mouse", x, y) return end
    if actOn() then Activity.pressed("mouse", x, y) return end
    if emuOn() then EmuPlay.touch("pressed", "mouse", x, y) return end
    if skinActive() then
      local m = Skin.model and Skin.model()
      if m and m.mode == "full_screen" then
        local L = Skin.layout and Skin.layout(state.W or real.getWidth(), state.H or real.getHeight())
        local c = m.carousel
        local p = Skin.page and Skin.page(Skin.count(), Skin.selected(), m, m.baseW)
        if L and c and p and p.last >= p.first then
          local shown = p.last - p.first + 1
          local span = shown * c.tileW + (shown - 1) * c.spacing
          local startX = (m.baseW - span) / 2
          for i = p.first, p.last do
            local isSel = (i == Skin.selected())
            local scale = isSel and c.selScale or c.unselScale
            local dw, dh = c.tileW * scale, c.tileH * scale
            local dy = c.y + (c.h - dh) / 2
            local tx = startX + (c.tileW - dw) / 2
            local rx, ry = L.x(tx), L.y(dy)
            local rw, rh = L.n(dw), L.n(dh)
            if x >= rx and x <= rx + rw and y >= ry and y <= ry + rh then
              if isSel then
                local g = Skin.selectedGame and Skin.selectedGame()
                if g then
                  Sfx.play("open")
                  Emus.play(g)
                  return
                end
              else
                Skin.selectGame(i)
                Sfx.play("select")
                return
              end
            end
            startX = startX + c.tileW + c.spacing
          end
        end
      end
      return
    end
    if pageOn() then EmuPage.pressed("mouse", x, y) return end
    do local _, m = appOn(); if m then m.pressed("mouse", x, y) return end end
    if homeTouch("mouse", x, y) then return end
    local cb = columnButtonAt(x, y)
    if cb then state.columnDown = cb.id; pressColumnButton(cb) return end
    local dir = arrowAt(x, y)
    if dir then arrowStart("mouse", dir) return end
    if topScreenTap(x, y) then return end
  end
  local lx, ly, ok = toVirtual(x, y)
  if ok and orig.mousepressed then return orig.mousepressed(lx, ly, button, istouch, presses) end
end

local function onMouseMoved(x, y, dx, dy, istouch)
  if state.mode ~= "ds" then
    if state.mode == "lid" then if not istouch then coverTouch("moved", "mouse", x, y) end return end
    return orig.mousemoved and orig.mousemoved(x, y, dx, dy, istouch)
  end
  if state.volDrag == "mouse" then volumeFromY(state.L, y) return end
  if state.held.mouse then holdMove("mouse", x, y) return end
  if editingSticker() then if not istouch then Sticker.moved("mouse", x, y) end return end
  if cameraOn() then if not istouch then Camera.moved("mouse", x, y) end return end
  if dlOn() then if not istouch then Dlplay.moved("mouse", x, y) end return end
  if esOn() then if not istouch then Eshop.moved("mouse", x, y) end return end
  if actOn() then if not istouch then Activity.moved("mouse", x, y) end return end
  if emuOn() then if not istouch then EmuPlay.touch("moved", "mouse", x, y) end return end
  if pageOn() then if not istouch then EmuPage.moved("mouse", x, y) end return end
  do local _, m = appOn(); if m then if not istouch then m.moved("mouse", x, y) end return end end
  if not istouch and Home.moved(state.subject, "mouse", x, y) then return end
  local lx, ly = toVirtual(x, y)
  if orig.mousemoved then return orig.mousemoved(lx, ly, dx, dy, istouch) end
end

local function onMouseReleased(x, y, button, istouch, presses)
  if state.mode ~= "ds" then
    if state.mode == "lid" then if not istouch then coverTouch("released", "mouse", x, y) end return end
    return orig.mousereleased and orig.mousereleased(x, y, button, istouch, presses)
  end
  if state.volDrag == "mouse" and not istouch then state.volDrag = nil return end
  if state.held.mouse and not istouch then holdEnd("mouse") return end
  if editingSticker() then if not istouch then Sticker.released("mouse") end return end
  if cameraOn() then
    if not istouch and Camera.released("mouse", x, y) == "exit" then Camera.close() end
    return
  end
  if dlOn() then
    if not istouch and Dlplay.released("mouse", x, y) == "exit" then Dlplay.close() end
    return
  end
  if esOn() then
    if not istouch then eshopDone(Eshop.released("mouse", x, y)) end
    return
  end
  if actOn() then
    if not istouch and Activity.released("mouse", x, y) == "exit" then Activity.close() end
    return
  end
  if emuOn() then
    if not istouch then EmuPlay.touch("released", "mouse", x, y) end
    return
  end
  if pageOn() then
    if not istouch then EmuPage.released("mouse", x, y) end
    return
  end
  do
    local _, m = appOn()
    if m then
      if not istouch then appExit(m, m.released("mouse", x, y)) end
      return
    end
  end
  if not istouch and Home.released(state.subject, "mouse", x, y) then return end
  if not istouch and state.arrowHeld and state.arrowHeld.id == "mouse" then arrowEnd("mouse") return end
  local lx, ly = toVirtual(x, y)
  if orig.mousereleased then return orig.mousereleased(lx, ly, button, istouch, presses) end
end

---------------------------------------------------------------- drawing

local function idleAnim(version)
  local idle = state.idle
  if idle.manifest == nil then
    local ok, m = pcall(function() return love.filesystem.load(DIR .. "idle/manifest.lua")() end)
    idle.manifest = ok and type(m) == "table" and m or false
  end
  local entry = idle.manifest and idle.manifest[version]
  if not entry then return nil end
  if idle.sheets[version] == nil then
    local ok, img = pcall(lg.newImage, DIR .. "idle/" .. entry.file)
    if ok then
      img:setFilter("nearest", "nearest")
      local w, h = img:getDimensions()
      local fw = math.floor(w / entry.frames)
      local quads = {}
      for i = 0, entry.frames - 1 do quads[i + 1] = lg.newQuad(i * fw, 0, fw, h, w, h) end
      idle.sheets[version] = { img = img, quads = quads, fw = fw, fh = h, fps = entry.fps or 5, frames = entry.frames }
    else
      idle.sheets[version] = false
    end
  end
  return idle.sheets[version] or nil
end

local function currentVersion()
  local ok, GV = pcall(require, "src.core.GameVersion")
  return ok and GV.get and GV.get() or "red"
end

-- the bottom screen while playing: the game's Pokemon; Yellow's Pikachu surfs
local function drawIdle(r)
  local t = state.time
  local version = currentVersion()
  lg.setColor(0.04, 0.06, 0.16, 1)
  lg.rectangle("fill", r.x, r.y, r.w, r.h)
  local anim = idleAnim(version)
  local surf = version == "yellow"
  if surf then
    for band = 0, 2 do
      local by = r.y + r.h * (0.62 + band * 0.12)
      lg.setColor(0.16 + band * 0.06, 0.40 + band * 0.08, 0.85 - band * 0.10, 1)
      lg.rectangle("fill", r.x, by, r.w, r.h - (by - r.y))
      lg.setColor(0.85, 0.93, 1, 0.9)
      local step = r.w / 18
      for wx = r.x - step, r.x + r.w, step do
        local px = wx + (t * (30 + band * 12) * (r.w / 480)) % step
        local py = by + math.sin((px + t * 40) / 9) * 2
        if px >= r.x and px + step / 2 <= r.x + r.w then lg.rectangle("fill", px, py - 1, step / 2, r.h / 90) end
      end
    end
  end
  if not anim then return end
  local scale = math.max(1, math.floor((r.h * 0.55) / anim.fh))
  local frame = math.floor(t * anim.fps) % anim.frames + 1
  local dx = r.x + (r.w - anim.fw * scale) / 2
  local dy = r.y + (r.h - anim.fh * scale) / 2
  if surf then dy = r.y + r.h * 0.62 - anim.fh * scale + r.h * 0.08 + math.sin(t * 2.5) * r.h * 0.015 end
  lg.setColor(1, 1, 1, 1)
  lg.draw(anim.img, anim.quads[frame], math.floor(dx), math.floor(dy), 0, scale, scale)
end

-- the launcher's selected game (the GAMES tab's version, else the last panel)
local function launcherVersion()
  local imp = state.subject
  local ok, GV = pcall(require, "src.core.GameVersion")
  local v = imp and (imp.panelVersion or imp.tab)
  if ok and GV.VERSIONS and v and GV.VERSIONS[v] then return v end
  return "red"
end

local function cartImage(version)
  local key = "cart:" .. version
  if state.images[key] == nil then
    local ok, img = pcall(lg.newImage, DIR .. "carts/" .. version .. ".png")
    state.images[key] = ok and img or false
    if ok then img:setFilter("linear", "linear") end
  end
  return state.images[key] or nil
end

local fonts = {}
local function font(px)
  px = math.max(8, math.floor(px))
  if not fonts[px] then fonts[px] = lg.newFont(px) end
  return fonts[px]
end

-- the top screen behind the launcher: the selected game's cartridge, the
-- arrows that change it, the project credit
local function drawTopIdle(r)
  lg.setColor(0.02, 0.02, 0.03, 1)
  lg.rectangle("fill", r.x, r.y, r.w, r.h)
  local version = launcherVersion()
  local img = cartImage(version)
  if img then
    local iw, ih = img:getDimensions()
    local s = math.max(r.w / iw, r.h / ih)
    lg.setColor(1, 1, 1, 1)
    lg.setScissor(r.x, r.y, r.w, r.h)
    lg.draw(img, r.x + (r.w - iw * s) / 2, r.y + (r.h - ih * s) / 2, 0, s, s)
    lg.setScissor()
  end
  local f = font(r.h * 0.12)
  lg.setFont(f)
  lg.setColor(1, 1, 1, 0.85)
  lg.print("<", r.x + r.w * 0.03, r.y + r.h / 2 - f:getHeight() / 2)
  lg.print(">", r.x + r.w * 0.97 - f:getWidth(">"), r.y + r.h / 2 - f:getHeight() / 2)
  local ok, GV = pcall(require, "src.core.GameVersion")
  local info = ok and GV.info and GV.info(version)
  local imp = state.subject
  local ready = imp and imp.ready and imp.ready[version]
  local cf = font(r.h * 0.05)
  lg.setFont(cf)
  lg.setColor(0, 0, 0, 0.55)
  lg.rectangle("fill", r.x, r.y + r.h - cf:getHeight() * 3.4, r.w, cf:getHeight() * 3.4)
  lg.setColor(0.85, 0.85, 0.9, 1)
  lg.printf((info and info.displayName or version) .. (ready and "  -  tap the cart to play" or "  -  import the ROM below"),
    r.x, r.y + r.h - cf:getHeight() * 3.2, r.w, "center")
  lg.printf("Based on the Pokemon Gen 1 Recompilation Project by BOIS CLUB GAMES, LLC\ngithub.com/bryanthaboi/gen1recomp",
    r.x, r.y + r.h - cf:getHeight() * 2.1, r.w, "center")
end

-- The 3DS theme's top screen, as the 3DS draws its own: the status bar
-- (signal, Internet, the play coins, date and time, battery), the tiled
-- wallpaper with the selected game's cartridge floating over it (a 3D
-- Game Boy Color / Advance cart, fold3ds.cart3d), and the game's name.
local function col3(c, a) lg.setColor(c[1] / 255, c[2] / 255, c[3] / 255, a or 1) end

local function topPanel(r)
  local sh = math.floor(r.h * 0.13)
  local pad = math.floor(r.w * 0.02)
  local nh = math.floor(r.h * 0.12)
  return { x = r.x + pad, y = r.y + sh + pad, w = r.w - 2 * pad, h = r.h - sh - nh - 2 * pad }, sh, nh, pad
end

-- the top screen's picture of a selected tile that is not a recomp game:
-- a 3DS game card with the game's icon as its label, or the icon itself on
-- a white tile, floating over its shadow
local function drawTopTile(P, t)
  local time = state.time
  local bob = math.sin(time * 1.7) * P.h * 0.025
  local cx, cy = P.x + P.w / 2, P.y + P.h * 0.47
  if Home and Home.isWrapped and Home.isWrapped(t) then
    local gImg = image("icons3ds/gift_3ds.png", DIR .. "icons3ds/gift_3ds.png")
    if gImg then
      local iw, ih = gImg:getDimensions()
      local gs = P.h * 0.52
      local k = gs / math.max(iw, ih)
      local sway = math.sin(time * 1.4) * 0.08
      local hop = math.sin(time * 2.8) * P.h * 0.035
      -- contact shadow on stage
      lg.setColor(0.18, 0.16, 0.22, 0.2 - hop / P.h)
      lg.ellipse("fill", cx, P.y + P.h * 0.88, P.h * 0.28, P.h * 0.06)
      -- rotating gift box
      lg.setColor(1, 1, 1, 1)
      lg.draw(gImg, cx, cy + bob + hop, sway, k, k, iw / 2, ih / 2)
      -- sparkles floating around
      for sp = 1, 4 do
        local stime = (time * 1.2 + sp * 0.7) % 2.5
        if stime < 0.6 then
          local sprog = stime / 0.6
          local salpha = math.sin(sprog * math.pi)
          local sx = cx + math.cos(sp * 1.5 + time) * P.h * 0.3
          local sy = cy + bob + math.sin(sp * 2.1) * P.h * 0.25 - sprog * P.h * 0.1
          lg.setColor(1, 0.95, 0.6, salpha)
          lg.circle("fill", sx, sy, 3 + math.sin(sprog * math.pi) * 3)
        end
      end
      return
    end
  end
  if t.emuGame then
    -- every emulator's game as its own 3D cart / card, floating and
    -- spinning like the recomp carts: a DS or 3DS card, a Game Boy, Color or
    -- Advance cart, with the game's box art or icon as its label
    local skin
    local p = Emus.owner(t)
    if p and p.cartSkin then
      local ok, sk = pcall(p.cartSkin, t)
      if ok and type(sk) == "table" then skin = sk end
    end
    if not skin then
      local sys = t.system or (p and p.id == "azahar" and "3ds") or "3ds"
      local shape = ({ nds = "ds", ds = "ds", gb = "gb", gbc = "gbc", gba = "gba" })[sys] or "3ds"
      local colors = { ["3ds"] = { 214, 216, 222 }, ds = { 190, 192, 198 }, gb = { 168, 168, 176 },
        gbc = { 120, 120, 130 }, gba = { 60, 60, 70 } }
      skin = { shape = shape, color = colors[shape], labelImage = Emus.icon(t), noLabel = true }
    end
    skin.cart = true
    skin.cacheKey = skin.cacheKey or t.id
    if skin.shape == "ds" and t.system ~= "nds" and not (p and p.id == "melonds") and p and p.id == "azahar" then
      skin.shape = "3ds"
    end
    Cart3D.draw(P, t.id, time, skin)
    return
  end
  local img = t.emuGame and Emus.icon(t) or image("icons3ds/" .. t.id .. ".png")
  -- the shadow
  lg.setColor(0.2, 0.24, 0.3, 0.16 - bob / P.h)
  lg.ellipse("fill", cx, P.y + P.h * 0.9, P.h * 0.26, P.h * 0.05)
  local photo = t.emuGame and Emus.cart(t)
  if photo then
    -- the game card itself (GameTDB's photo), floating, with a slow sway
    local iw, ih = photo:getDimensions()
    local k = math.min(P.h * 0.9 / ih, P.w * 0.6 / iw)
    local sway = math.sin(time * 0.9) * 0.05
    lg.setColor(1, 1, 1, 1)
    lg.draw(photo, cx, cy + bob, sway, k, k, iw / 2, ih / 2)
    return
  end
  if t.emuGame then
    -- a 3DS game card: grey, the ridge on top, the label below it
    local w, h = P.h * 0.6, P.h * 0.68
    local x, y = cx - w / 2, cy - h / 2 + bob
    col3({ 150, 152, 158 })
    lg.rectangle("fill", x + w * 0.012, y + h * 0.02, w, h, w * 0.06, w * 0.06)
    col3({ 214, 216, 220 })
    lg.rectangle("fill", x, y, w, h, w * 0.06, w * 0.06)
    col3({ 192, 194, 199 })
    lg.rectangle("fill", x, y, w, h * 0.13, w * 0.06, w * 0.06)
    lg.rectangle("fill", x + w * 0.1, y + h * 0.13, w * 0.8, h * 0.02)
    local lx, ly, ls = x + w * 0.1, y + h * 0.2, w * 0.8
    col3({ 255, 255, 255 })
    lg.rectangle("fill", lx, ly, ls, ls * 0.95, w * 0.03, w * 0.03)
    if img then
      local iw, ih = img:getDimensions()
      local k = math.min(ls * 0.86 / iw, ls * 0.8 / ih)
      lg.setColor(1, 1, 1, 1)
      lg.draw(img, lx + (ls - iw * k) / 2, ly + (ls * 0.95 - ih * k) / 2, 0, k, k)
    else
      -- no icon: the title's first letter
      local f = font(ls * 0.5)
      lg.setFont(f)
      col3({ 206, 32, 40 })
      lg.printf(Emus.initial(t.name), lx, ly + (ls * 0.95 - f:getHeight()) / 2, ls, "center")
    end
    return
  end
  local s = P.h * 0.5
  local x, y = cx - s / 2, cy - s / 2 + bob
  lg.setColor(0.24, 0.28, 0.36, 0.18)
  lg.rectangle("fill", x + s * 0.02, y + s * 0.05, s, s, s * 0.2, s * 0.2)
  lg.setColor(1, 1, 1, 1)
  lg.rectangle("fill", x, y, s, s, s * 0.2, s * 0.2)
  if img then
    local iw, ih = img:getDimensions()
    local inset = s * 0.12
    lg.draw(img, x + inset, y + inset, 0, (s - 2 * inset) / iw, (s - 2 * inset) / ih)
  end
end

-- the L and R camera buttons in the top screen's lower corners (L or R
-- opens the Camera, as on the 3DS HOME menu)
local function drawLR(r, h, pad)
  state.lrRects = {}
  for k, name in ipairs({ "btn_l_camera", "btn_r_camera" }) do
    local key = "skin:" .. name
    if state.images[key] == nil then
      local ok, img = pcall(lg.newImage, DIR .. "skin/" .. name .. ".png")
      state.images[key] = ok and img or false
      if ok then img:setFilter("linear", "linear") end
    end
    local img = state.images[key]
    if img then
      local iw, ih = img:getDimensions()
      local s = h / ih
      local x = k == 1 and r.x + pad or r.x + r.w - pad - iw * s
      local y = r.y + r.h - h - pad * 0.4
      lg.setColor(1, 1, 1, 1)
      lg.draw(img, x, y, 0, s, s)
      state.lrRects[k] = { x = x, y = y, w = iw * s, h = h }
    end
  end
end

-- A HOME bar app's banner, as the 3DS shows it when the app is picked: its
-- icon turning in 3D (a slab, its edge a darker shade) above the app's
-- own title, English or Japanese with SKINS > CARTRIDGE ARTWORK
-- (fold3ds/icons3ds/<id>.png, fold3ds/banners/<id>_en|jp.png).
-- A 3DS game's banner on the top screen, as the HOME menu shows a game:
-- a stage in the colour of its icon, light turning slowly behind the game
-- card, and the title bubble below -- icon, title, publisher.
local function ctrColour(t)
  local key = "ctrcol:" .. (t.key or t.id or "")
  if state.images[key] == nil then
    local c
    local path = Emus.iconPath(t)
    if path then
      local ok, d = pcall(love.image.newImageData, path)
      if ok and d then
        local r, g, b, n = 0, 0, 0, 0
        local w, h = d:getDimensions()
        for y = 0, h - 1, 2 do
          for x = 0, w - 1, 2 do
            local pr, pg, pb, pa = d:getPixel(x, y)
            -- the colourful pixels count most
            local sat = math.max(pr, pg, pb) - math.min(pr, pg, pb)
            local wgt = pa * (0.15 + sat)
            r, g, b, n = r + pr * wgt, g + pg * wgt, b + pb * wgt, n + wgt
          end
        end
        if n > 0 then c = { r / n, g / n, b / n } end
      end
    end
    if not c then
      -- no icon: a colour of its own from the name
      local hsh = 0
      for i = 1, #(t.name or "") do hsh = (hsh * 31 + t.name:byte(i)) % 360 end
      local hue = hsh / 60
      local x = 1 - math.abs(hue % 2 - 1)
      local rgb = ({ { 1, x, 0 }, { x, 1, 0 }, { 0, 1, x }, { 0, x, 1 }, { x, 0, 1 }, { 1, 0, x } })[math.floor(hue) + 1]
      c = { 0.25 + rgb[1] * 0.6, 0.25 + rgb[2] * 0.6, 0.25 + rgb[3] * 0.6 }
    end
    state.images[key] = c
  end
  return state.images[key]
end

local function drawCtrBanner(r, P, t, nh, pad)
  local c = ctrColour(t)
  local time = state.time
  local bubH = nh * 1.9
  local stage = { x = r.x, y = P.y - pad * 0.5, w = r.w, h = r.y + r.h - bubH - pad * 0.6 - (P.y - pad * 0.5) }
  -- the stage: its colour fading to white at the top
  local bands = 24
  for i = 0, bands - 1 do
    local k = (i + 0.5) / bands * 0.55
    lg.setColor(1 - (1 - c[1]) * k, 1 - (1 - c[2]) * k, 1 - (1 - c[3]) * k, 1)
    local y0 = stage.y + stage.h * i / bands
    lg.rectangle("fill", stage.x, y0, stage.w, stage.h / bands + 1)
  end
  -- light turning behind the card
  local cx, cy = stage.x + stage.w / 2, stage.y + stage.h * 0.5
  local R = stage.w
  for i = 0, 11 do
    local a0 = time * 0.15 + i * math.pi / 6
    lg.setColor(1, 1, 1, 0.16)
    lg.polygon("fill", cx, cy, cx + math.cos(a0) * R, cy + math.sin(a0) * R,
      cx + math.cos(a0 + 0.2) * R, cy + math.sin(a0 + 0.2) * R)
  end
  drawTopTile({ x = P.x, y = stage.y, w = P.w, h = stage.h }, t)
  -- the title bubble
  local bx, by, bw = r.x + pad, r.y + r.h - bubH - pad * 0.4, r.w - 2 * pad
  lg.setColor(0, 0, 0, 0.12)
  lg.rectangle("fill", bx, by + bubH * 0.06, bw, bubH, bubH * 0.22, bubH * 0.22)
  lg.setColor(1, 1, 1, 1)
  lg.rectangle("fill", bx, by, bw, bubH, bubH * 0.22, bubH * 0.22)
  lg.setColor(0.82, 0.83, 0.86, 1)
  lg.setLineWidth(1)
  lg.rectangle("line", bx, by, bw, bubH, bubH * 0.22, bubH * 0.22)
  local is = bubH * 0.72
  local ix, iy = bx + bubH * 0.14, by + (bubH - is) / 2
  local icon = Emus.icon(t)
  if icon then
    local iw, ih = icon:getDimensions()
    lg.setColor(1, 1, 1, 1)
    lg.draw(icon, ix, iy, 0, is / iw, is / ih)
  else
    lg.setColor(c[1], c[2], c[3], 1)
    lg.rectangle("fill", ix, iy, is, is, is * 0.15, is * 0.15)
    local f = font(is * 0.55)
    lg.setFont(f)
    lg.setColor(1, 1, 1, 1)
    lg.printf(Emus.initial(t.name), ix, iy + (is - f:getHeight()) / 2, is, "center")
  end
  local tx, tw = ix + is + bubH * 0.2, bw - is - bubH * 0.5
  local tf = font(bubH * 0.3)
  local sf = font(bubH * 0.22)
  local total = tf:getHeight() + sf:getHeight() * 1.1
  local ty = by + (bubH - total) / 2
  lg.setFont(tf)
  lg.setColor(0.16, 0.16, 0.18, 1)
  lg.printf(t.name or "", tx, ty, tw, "left")
  lg.setFont(sf)
  lg.setColor(0.45, 0.46, 0.5, 1)
  lg.printf(t.sub or Emus.system(t) or "", tx, ty + tf:getHeight() * 1.05, tw, "left")
end

local APPLET_TITLES = { friends = "Friend List", gamenotes = "Game Notes" }
local function appletBanner(r, id, t)
  local function image(key, path)
    if state.images[key] == nil then
      local ok, im = pcall(lg.newImage, path)
      state.images[key] = ok and im or false
      if ok then im:setFilter("linear", "linear") end
    end
    return state.images[key] or nil
  end
  local icon = image("icon:" .. id, DIR .. "icons3ds/" .. id .. ".png")
  local jp = Cart3D.region == "jp"
  local title = image("banner:" .. id .. (jp and "_jp" or "_en"), DIR .. "banners/" .. id .. (jp and "_jp" or "_en") .. ".png")
  local th = r.h * 0.3
  if icon then
    local iw, ih = icon:getDimensions()
    local s = (r.h - th) * 0.82 / ih
    local cx, cy = r.x + r.w / 2, r.y + (r.h - th) * 0.5
    local cycle = (t % 5) / 5
    local turn = cycle < 0.35 and 0 or (cycle - 0.35) / 0.65
    turn = turn * turn * (3 - 2 * turn)
    local a = turn * math.pi * 2 + 0.2 * math.sin(t * 1.2)
    local ca, sa = math.cos(a), math.sin(a)
    local bob = math.sin(t * 1.5) * r.h * 0.02
    lg.setColor(0, 0, 0, 0.12)
    lg.ellipse("fill", cx, cy + ih * s * 0.55, iw * s * 0.42 * math.max(0.3, math.abs(ca)), r.h * 0.03)
    for k = 8, 1, -1 do
      local sh = 0.45 + 0.25 * k / 8
      lg.setColor(sh, sh, sh, 1)
      lg.draw(icon, cx + sa * iw * s * 0.1 * k / 8, cy + bob, 0, s * ca, s, iw / 2, ih / 2)
    end
    local lit = ca >= 0 and 1 or 0.8
    lg.setColor(lit, lit, lit, 1)
    lg.draw(icon, cx, cy + bob, 0, s * ca, s, iw / 2, ih / 2)
  end
  if title then
    local tw, tt = title:getDimensions()
    local s = math.min(r.w * 0.8 / tw, th * 0.8 / tt)
    lg.setColor(1, 1, 1, 1)
    lg.draw(title, r.x + (r.w - tw * s) / 2, r.y + r.h - th + (th - tt * s) / 2, 0, s, s)
  elseif APPLET_TITLES[id] then
    -- no title art: the name, in the banners' ink
    local f = font(th * 0.5)
    lg.setFont(f)
    lg.setColor(0.22, 0.22, 0.25, 1)
    lg.printf(APPLET_TITLES[id], r.x, r.y + r.h - th + (th - f:getHeight()) / 2, r.w, "center")
  end
end

local function drawTop3DS(r, banner)
  lg.push("all")
  lg.setScissor(r.x, r.y, r.w, r.h)
  col3({ 250, 251, 252 })
  lg.rectangle("fill", r.x, r.y, r.w, r.h)
  local P, sh, nh, pad = topPanel(r)
  local bannerH = math.floor(r.h * 0.42)
  if banner then P.h = r.h - sh - bannerH - 2 * pad end
  -- status bar
  local cy = r.y + pad * 0.6 + sh / 2
  local bh = sh * 0.7
  local x = r.x + pad
  for i = 1, 4 do
    col3({ 20, 150, 210 })
    local h = bh * (0.35 + 0.65 * i / 4)
    lg.rectangle("fill", x + (i - 1) * bh * 0.2, cy + bh / 2 - h, bh * 0.14, h)
  end
  x = x + bh * 0.95
  local iw = r.w * 0.22
  col3({ 40, 150, 230 })
  lg.rectangle("fill", x, cy - bh / 2, iw, bh, bh * 0.25, bh * 0.25)
  col3({ 120, 200, 250 }, 0.6)
  lg.rectangle("fill", x + bh * 0.1, cy - bh * 0.42, iw - bh * 0.2, bh * 0.35, bh * 0.15, bh * 0.15)
  local f = font(bh * 0.72)
  lg.setFont(f)
  lg.setColor(1, 1, 1, 1)
  lg.printf("Internet", x, cy - f:getHeight() / 2, iw, "center")
  x = x + iw + bh * 0.5
  local count = Home.coins()
  col3({ 214, 160, 10 })
  lg.circle("fill", x + bh / 2, cy, bh / 2)
  col3({ 250, 206, 40 })
  lg.circle("fill", x + bh / 2, cy, bh * 0.42)
  col3({ 70, 72, 78 })
  lg.print(tostring(count), x + bh * 1.2, cy - f:getHeight() / 2)
  -- battery, then the date and time left of it
  local batW = bh * 1.5
  local bx = r.x + r.w - pad - batW
  local pct = 1
  if love.system.getPowerInfo then
    local _, pc = love.system.getPowerInfo()
    if pc then pct = pc / 100 end
  end
  col3({ 60, 62, 68 })
  lg.rectangle("fill", bx, cy - bh * 0.38, batW, bh * 0.76, bh * 0.15, bh * 0.15)
  lg.rectangle("fill", bx - bh * 0.12, cy - bh * 0.18, bh * 0.14, bh * 0.36)
  lg.setColor(1, 1, 1, 1)
  lg.rectangle("fill", bx + bh * 0.08, cy - bh * 0.3, batW - bh * 0.16, bh * 0.6, bh * 0.1, bh * 0.1)
  col3({ 30, 150, 230 })
  local fw = (batW - bh * 0.26) * math.max(0.05, math.min(1, pct))
  lg.rectangle("fill", bx + batW - bh * 0.13 - fw, cy - bh * 0.25, fw, bh * 0.5, bh * 0.08, bh * 0.08)
  local t = os.date("*t")
  if state.steps and state.steps >= 0 then
    -- the pedometer, as the 3DS shows it: footprints, today's steps, the time
    local label = ("%d Steps"):format(state.steps)
    local clock = ("%d:%02d"):format(t.hour, t.min)
    local fw2 = bh * 1.25
    local dw = fw2 + f:getWidth(label) + bh * 0.7 + f:getWidth(clock) + bh * 0.6
    local dx = bx - bh * 0.4 - dw
    col3({ 96, 98, 104 })
    lg.rectangle("fill", dx, cy - bh / 2, dw, bh, bh * 0.4, bh * 0.4)
    col3({ 150, 152, 158 })
    lg.rectangle("line", dx, cy - bh / 2, dw, bh, bh * 0.4, bh * 0.4)
    -- two footprints
    lg.setColor(1, 1, 1, 1)
    for k = 0, 1 do
      local fx, fy = dx + bh * (0.42 + k * 0.34), cy + (k == 0 and bh * 0.05 or -bh * 0.05)
      lg.ellipse("fill", fx, fy - bh * 0.1, bh * 0.11, bh * 0.17)
      lg.ellipse("fill", fx, fy + bh * 0.2, bh * 0.08, bh * 0.07)
    end
    lg.setFont(f)
    lg.print(label, dx + fw2, cy - f:getHeight() / 2)
    lg.print(clock, dx + fw2 + f:getWidth(label) + bh * 0.7, cy - f:getHeight() / 2)
  else
    local days = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
    local stamp = ("%d/%d (%s) %d:%02d"):format(t.month, t.day, days[t.wday], t.hour, t.min)
    local dw = f:getWidth(stamp) + bh
    local dx = bx - bh * 0.4 - dw
    col3({ 244, 245, 247 })
    lg.rectangle("fill", dx, cy - bh / 2, dw, bh, bh * 0.4, bh * 0.4)
    col3({ 200, 203, 210 })
    lg.rectangle("line", dx, cy - bh / 2, dw, bh, bh * 0.4, bh * 0.4)
    col3({ 60, 62, 68 })
    lg.printf(stamp, dx, cy - f:getHeight() / 2, dw, "center")
  end
  -- the wallpaper panel: pale tiles on grey
  lg.stencil(function() lg.rectangle("fill", P.x, P.y, P.w, P.h, P.h * 0.05, P.h * 0.05) end, "replace", 1)
  lg.setStencilTest("greater", 0)
  col3({ 206, 210, 218 })
  lg.rectangle("fill", P.x, P.y, P.w, P.h)
  local ts = P.h / 3.2
  local step = ts * 1.08
  for i = -1, math.ceil(P.w / step) do
    for j = 0, 3 do
      local tx = P.x + i * step + step * 0.35
      local ty = P.y + j * step - step * 0.45
      col3({ 226, 229, 235 })
      lg.rectangle("fill", tx, ty, ts * 0.92, ts * 0.9, ts * 0.12, ts * 0.12)
      col3({ 236, 238, 243 }, 0.8)
      lg.rectangle("fill", tx + ts * 0.18, ty + ts * 0.18, ts * 0.56, ts * 0.54, ts * 0.08, ts * 0.08)
    end
  end
  lg.setStencilTest()
  if banner == "app:activity" then
    Activity.drawTop({ x = r.x, y = P.y, w = r.w, h = r.y + r.h - P.y - nh * 0.2 })
    drawLR(r, nh * 0.72, pad)
    lg.pop()
    return
  end
  if type(banner) == "string" and banner:match("^emupage:") then
    EmuPage.drawTop({ x = r.x, y = P.y, w = r.w, h = r.y + r.h - P.y - nh * 0.2 })
    lg.pop()
    return
  end
  local app = type(banner) == "string" and APPS[banner:match("^app:(.+)$") or ""]
  if app then
    app.drawTop({ x = r.x, y = P.y, w = r.w, h = r.y + r.h - P.y - nh * 0.2 })
    drawLR(r, nh * 0.72, pad)
    lg.pop()
    return
  end
  if banner == "eshop" then
    -- the eShop: its own page below the status bar
    Eshop.drawTop({ x = r.x, y = P.y, w = r.w, h = r.y + r.h - P.y - nh * 0.2 })
    drawLR(r, nh * 0.72, pad)
    lg.pop()
    return
  end
  if banner and banner ~= "dlplay" then
    -- another HOME bar app picked: its banner under the panel
    local by = P.y + P.h + pad * 0.3
    appletBanner({ x = r.x + r.w * 0.16, y = by, w = r.w * 0.68, h = r.y + r.h - by - pad * 0.2 }, banner, state.time)
    drawLR(r, bannerH * 0.26, pad)
    lg.pop()
    return
  end
  if banner == "dlplay" then
    -- Download Play: its banner turning under the panel, its news in it
    local msg = Dlplay.topMessage()
    if msg then
      local mf = font(P.h * 0.14)
      lg.setFont(mf)
      col3({ 80, 82, 90 })
      lg.printf(msg, P.x, P.y + P.h / 2 - mf:getHeight() / 2, P.w, "center")
    end
    local by = P.y + P.h + pad * 0.3
    Dlplay.drawBanner({ x = r.x + r.w * 0.16, y = by, w = r.w * 0.68, h = r.y + r.h - by - pad * 0.2 }, state.time)
    drawLR(r, bannerH * 0.26, pad)
    lg.pop()
    return
  end
  -- a 3DS game, the Azahar folder or one of its icons: that, not a cartridge
  local other = Home.showing() and Home.topTile(state.subject)
  if other and other.emuGame then
    if Home.isWrapped and Home.isWrapped(other) then
      drawTopTile(P, other)
      local nf = font(nh * 0.6)
      lg.setFont(nf)
      col3({ 70, 72, 78 })
      lg.printf("New Software", r.x, r.y + r.h - nh - pad * 0.3 + (nh - nf:getHeight()) / 2, r.w, "center")
      lg.pop()
      return
    end
    drawCtrBanner(r, P, other, nh, pad)
    lg.pop()
    return
  end
  if other then
    local isWr = Home.isWrapped and Home.isWrapped(other)
    drawTopTile(P, other)
    local nf = font(nh * 0.6)
    lg.setFont(nf)
    col3({ 70, 72, 78 })
    lg.printf(isWr and "New Software" or (other.name or ""), r.x, r.y + r.h - nh - pad * 0.3 + (nh - nf:getHeight()) / 2, r.w, "center")
    lg.pop()
    return
  end
  -- the selected game's cartridge
  local version = launcherVersion()
  local isWrGame = Home.showing() and Home.isWrapped and Home.isWrapped({ id = version, game = true })
  if isWrGame then
    drawTopTile(P, { id = version, game = true })
    local nf = font(nh * 0.6)
    lg.setFont(nf)
    col3({ 70, 72, 78 })
    lg.printf("New Software", r.x, r.y + r.h - nh - pad * 0.3 + (nh - nf:getHeight()) / 2, r.w, "center")
    drawLR(r, nh * 0.72, pad)
    lg.pop()
    return
  end
  local skin
  do
    local ok, LV = pcall(require, "src.import.LauncherView")
    if ok and type(LV) == "table" and LV.foldCartSkin and state.subject then
      local ok2, s = pcall(LV.foldCartSkin, state.subject, version)
      if ok2 then skin = s end
    end
  end
  Cart3D.draw(P, version, state.time, skin)
  -- the game's name under the panel
  local imp = state.subject
  local ok, GV = pcall(require, "src.core.GameVersion")
  local info = ok and GV.info and GV.info(version)
  local ready = imp and imp.ready and imp.ready[version]
  local nf = font(nh * 0.6)
  lg.setFont(nf)
  col3({ 70, 72, 78 })
  local name = (info and info.displayName or version) .. (ready and "" or "   -   import the ROM")
  lg.printf(name, r.x, r.y + r.h - nh - pad * 0.3 + (nh - nf:getHeight()) / 2, r.w, "center")
  drawLR(r, nh * 0.72, pad)
  lg.pop()
end
M.topPanel = topPanel

-- a tap on the top screen while the launcher shows: arrows change the
-- game, the cart plays it (the 3DS theme: the whole screen plays it)
topScreenTap = function(x, y)
  local L = state.L
  if not L or state.kind == "game" or not inside(L.topCut, x, y) then return false end
  if Theme3DS.active then
    for _, rr in pairs(state.lrRects or {}) do
      if inside(rr, x, y) then Camera.open() return true end
    end
  end
  local imp = state.subject
  if not imp then return true end
  if Theme3DS.active then
    -- a 3DS game or an Azahar icon selected: open it
    if Home.showing() and Home.topTile(imp) then Home.openSelected(imp) return true end
    local version = launcherVersion()
    if imp.ready and imp.ready[version] and imp.play then pcall(imp.play, imp, version, true) end
    return true
  end
  local rel = (x - L.topCut.x) / L.topCut.w
  local ok, GV = pcall(require, "src.core.GameVersion")
  local order = ok and GV.ORDER or { "red" }
  local version = launcherVersion()
  if rel < 0.2 or rel > 0.8 then
    local idx = 1
    for i, v in ipairs(order) do if v == version then idx = i end end
    idx = (idx - 1 + (rel < 0.2 and -1 or 1)) % #order + 1
    imp.tab = order[idx]
    imp.panelVersion = order[idx]
  elseif imp.ready and imp.ready[version] and imp.play then
    pcall(imp.play, imp, version, true)
  end
  return true
end

local function drawShoulders(L)
  if not state.shoulders then return end
  local age = state.time - state.shoulderSeen
  for _, sb in ipairs(SHOULDERS) do
    local lit = buttonLit(sb)
    if lit then state.shoulderSeen = state.time; age = 0 end
  end
  local alpha = 1 - math.max(0, math.min(1, (age - SHOULDER_SHOW) / SHOULDER_FADE))
  if alpha <= 0.01 then return end
  lg.push("all")
  for _, sb in ipairs(SHOULDERS) do
    local r = shoulderRect(L, sb)
    local lit = buttonLit(sb)
    local rad = r.h * 0.35
    lg.setColor(0, 0, 0, 0.35 * alpha)
    lg.rectangle("fill", r.x + 1, r.y + r.h * 0.08, r.w, r.h, rad, rad)
    if lit then lg.setColor(0.52, 0.53, 0.56, alpha) else lg.setColor(0.24, 0.25, 0.27, alpha) end
    lg.rectangle("fill", r.x, r.y + (lit and r.h * 0.05 or 0), r.w, r.h, rad, rad)
    lg.setColor(1, 1, 1, 0.12 * alpha)
    lg.rectangle("fill", r.x + r.w * 0.08, r.y + r.h * 0.08, r.w * 0.84, r.h * 0.3, rad * 0.6, rad * 0.6)
    lg.setColor(0.06, 0.06, 0.07, alpha)
    lg.setLineWidth(1.5)
    lg.rectangle("line", r.x, r.y + (lit and r.h * 0.05 or 0), r.w, r.h, rad, rad)
    local f = font(r.h * 0.46)
    lg.setFont(f)
    lg.setColor(0.93, 0.93, 0.95, alpha)
    lg.printf(sb.label, r.x, r.y + (lit and r.h * 0.05 or 0) + (r.h - f:getHeight()) / 2, r.w, "center")
  end
  lg.pop()
end

local function drawButtons(L)
  local sheet = image(SHEET)
  if not sheet then return end
  local sw, sh = sheet:getDimensions()
  for _, b in ipairs(BUTTONS) do
    b.quad = b.quad or lg.newQuad(b.sprite[1] * 2, b.sprite[2] * 2, b.sprite[3] * 2, b.sprite[4] * 2, sw, sh)
    local lit, dirs = buttonLit(b)
    local target = b.r * 2 * L.s2               -- socket width in pixels
    local qw, qh = b.sprite[3] * 2, b.sprite[4] * 2
    local scale = (b.wide and (target * 2 / qw)) or (target / math.max(qw, qh))
    local cx, cy = socketAt(L, b)
    local dx, dy = 0, 0
    if b.kind == "dpad" and lit and dirs then
      local lean = b.r * L.s2 * 0.12
      if dirs.left then dx = dx - lean end
      if dirs.right then dx = dx + lean end
      if dirs.up then dy = dy - lean end
      if dirs.down then dy = dy + lean end
    end
    local ps = scale * (lit and 0.93 or 1)
    if lit then lg.setColor(0.68, 0.68, 0.72, 1) else lg.setColor(1, 1, 1, 1) end
    lg.draw(sheet, b.quad, cx - qw * ps / 2 + dx, cy - qh * ps / 2 + dy + (lit and L.s2 * 1.5 or 0), 0, ps, ps)
  end
end

local function drawArrows(L)
  local a = L.arrows
  local light = Theme3DS.active
  local ink = light and Theme3DS.arrowInk or { 1, 1, 1 }
  if light then lg.setColor(Theme3DS.arrowFill) else lg.setColor(0.07, 0.08, 0.10, 1) end
  lg.rectangle("fill", a.x, a.y, a.w, a.h)
  lg.setColor(ink[1], ink[2], ink[3], 0.10)
  lg.rectangle("fill", a.x, a.y, 1, a.h)
  local function tri(r, dir)
    local on = canScroll(dir)
    local held = state.arrowHeld and state.arrowHeld.dir == dir
    local cx, cy = r.x + r.w / 2, r.y + r.h / 2
    local sz = math.min(r.w * 0.34, r.h * 0.2)
    if held then
      lg.setColor(ink[1], ink[2], ink[3], 0.12)
      lg.rectangle("fill", r.x + 2, r.y + 2, r.w - 4, r.h - 4, 4, 4)
    end
    lg.setColor(ink[1], ink[2], ink[3], on and (held and 1 or 0.85) or 0.18)
    if dir < 0 then
      lg.polygon("fill", cx - sz, cy + sz * 0.5, cx + sz, cy + sz * 0.5, cx, cy - sz * 0.7)
    else
      lg.polygon("fill", cx - sz, cy - sz * 0.5, cx + sz, cy - sz * 0.5, cx, cy + sz * 0.7)
    end
  end
  local up, down, buttons = columnRects(L)
  tri(up, -1)
  tri(down, 1)
  lg.setColor(ink[1], ink[2], ink[3], 0.10)
  lg.rectangle("fill", a.x + 4, down.y, a.w - 8, 1)
  -- sync / settings / quit, when the column carries them
  if #buttons > 0 then
    local okI, Icons = pcall(require, "src.ui.kit.Icons")
    for _, b in ipairs(buttons) do
      local s = math.floor(b.w * 0.5)
      if okI then
        Icons.draw(b.icon, b.x + (b.w - s) / 2, b.y + (b.h - s) / 2, s,
          { ink[1] * 255, ink[2] * 255, ink[3] * 255 }, 0.9)
      end
      lg.setColor(ink[1], ink[2], ink[3], 0.10)
      lg.rectangle("fill", b.x + 4, b.y + b.h - 1, b.w - 8, 1)
    end
  end
end

local function drawToast(r)
  local t = state.toast
  if not t then return end
  local age = state.time - t.at
  if age > 1.6 then state.toast = nil return end
  local alpha = age > 1.2 and (1.6 - age) / 0.4 or 1
  local f = font(r.h * 0.075)
  lg.setFont(f)
  local tw, th = f:getWidth(t.text) + f:getHeight() * 1.4, f:getHeight() * 1.6
  local x, y = r.x + (r.w - tw) / 2, r.y + r.h * 0.08
  lg.setColor(0, 0, 0, 0.72 * alpha)
  lg.rectangle("fill", x, y, tw, th, th / 3, th / 3)
  lg.setColor(1, 1, 1, alpha)
  lg.printf(t.text, x, y + (th - f:getHeight()) / 2, tw, "center")
end

-- The closed lid, as large as a rect holds (turned on its side when
-- `portrait`), with the player's sticker on it.
local function drawLidIn(x, y, W, H, portrait, cover)
  local lid = image(LID)
  if not lid then return end
  -- only the shell itself (the art's opaque box), as big as the rect holds
  -- with a thin margin
  local cw, ch = LID_BOX[3], LID_BOX[4]
  state.lidQuad = state.lidQuad or lg.newQuad(LID_BOX[1], LID_BOX[2], cw, ch, lid:getDimensions())
  local aw, ah = W, H
  if portrait then aw, ah = H, W end
  local s = math.min(aw / cw, ah / ch) * 0.98
  local ox, oy = math.floor((aw - cw * s) / 2), math.floor((ah - ch * s) / 2)
  lg.push()
  lg.translate(x, y)
  if portrait then
    lg.translate(W, 0)
    lg.rotate(math.pi / 2)
  end
  lg.setColor(1, 1, 1, 1)
  lg.draw(lid, state.lidQuad, ox, oy, 0, s, s)
  -- the sticker stays on the shell: its shape (the art's opaque pixels) is
  -- the stencil anything hanging off the edge is cut by
  state.alphaTest = state.alphaTest or lg.newShader([[
    vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
      vec4 p = Texel(tex, tc);
      if (p.a < 0.5) discard;
      return p;
    }
  ]])
  Sticker.drawOnLid(ox, oy, s, cw, ch, function()
    lg.setShader(state.alphaTest)
    lg.draw(lid, state.lidQuad, ox, oy, 0, s, s)
    lg.setShader()
  end, cover)
  lg.pop()
end

-- a wallpaper filling a w x h box, cropped rather than stretched
-- The startup, as a 3DS starts: the boot screen (the AeonDX logo animated on
-- both screens, fold3ds/boot/, the lid's click, then the HOME menu's welcome
-- jingle), then the Health & Safety warning until a touch or a button, then
-- the HOME menu coming up out of white.  A tap hurries the logo along.
local BOOT_TIME, BOOT_FADE = 4.2, 0.5
local HS_FADE, HOME_TIME = 0.35, 0.7
local function booting()
  local b = state.boot
  if not b then return false end
  local age = state.time - b.t0
  if b.phase == "logo" and age > BOOT_TIME then b.phase, b.t0 = "hs", state.time end
  if b.phase == "home" and age > HOME_TIME then state.boot = nil return false end
  return true
end

skipBoot = function()
  local b = state.boot
  if not booting() then return false end
  if b.phase == "logo" then
    -- straight to the fade
    b.t0 = math.min(b.t0, state.time - (BOOT_TIME - BOOT_FADE))
    return true
  end
  if b.phase == "hs" then
    -- not while it is still coming up (the tap that hurried the logo)
    if state.time - b.t0 < HS_FADE then return true end
    b.phase, b.t0 = "home", state.time
    Sfx.play("click")
    return true
  end
  -- the menu coming up: the touch is the menu's
  return false
end

local function bootImage(name, ext)
  local key = "boot:" .. name
  if state.images[key] == nil then
    local ok, img = pcall(lg.newImage, DIR .. "boot/" .. name .. (ext or ".jpg"))
    state.images[key] = ok and img or false
    if ok then img:setFilter("linear", "linear") end
  end
  return state.images[key] or nil
end

local function drawBootScreen(img, r, age, zoom, a)
  lg.setScissor(r.x, r.y, r.w, r.h)
  lg.setColor(0.05, 0.06, 0.09, a)
  lg.rectangle("fill", r.x, r.y, r.w, r.h)
  if img then
    local iw, ih = img:getDimensions()
    local k = math.max(r.w / iw, r.h / ih) * zoom
    lg.setColor(1, 1, 1, a)
    lg.draw(img, r.x + r.w / 2, r.y + r.h / 2, 0, k, k, iw / 2, ih / 2)
  end
  -- a light sweeping across once
  local sweep = (age - 0.5) / 1.1
  if sweep > 0 and sweep < 1 then
    local x = r.x - r.w * 0.3 + sweep * r.w * 1.6
    for i = 0, 7 do
      local o = i * r.w * 0.02
      lg.setColor(0.35, 0.85, 1.0, 0.07 * a * (1 - math.abs(i - 3.5) / 4))
      lg.polygon("fill", x + o, r.y, x + o + r.w * 0.04, r.y,
        x + o - r.w * 0.06, r.y + r.h, x + o - r.w * 0.1, r.y + r.h)
    end
  end
  -- fade in from black, as the screens light up
  if age < 0.25 then
    lg.setColor(0, 0, 0, 1 - age / 0.25)
    lg.rectangle("fill", r.x, r.y, r.w, r.h)
  end
  lg.setScissor()
end

-- The AeonDX boot, animated from its art (fold3ds/boot/aeondx_*.png, cut by
-- tools/make_boot_sprites.py).  Top: the blue and purple streaks fly in from
-- the sides, the ring opens behind, the logo drops into it with a flash and
-- then floats in the ring's pulse.  Bottom: the logo comes up, "Loading..."
-- counts its dots and the bar fills until the boot hands over.
local function aeon(name) return bootImage("aeondx_" .. name, ".png") end
local function clamp01(x) return x < 0 and 0 or (x > 1 and 1 or x) end
local function easeOut(x) x = clamp01(x) return 1 - (1 - x) ^ 3 end
local function easeBack(x)
  x = clamp01(x)
  local c = 1.7
  return 1 + (c + 1) * (x - 1) ^ 3 + c * (x - 1) ^ 2
end

-- a deep night with a few stars twinkling (fixed places, so no flicker)
local function drawBootSky(r, age, a)
  lg.setColor(0.02, 0.02, 0.06, a)
  lg.rectangle("fill", r.x, r.y, r.w, r.h)
  local n = 38
  for i = 1, n do
    local u = (i * 0.6180339) % 1
    local v = (i * 0.4142135 + 0.13) % 1
    local tw = 0.35 + 0.65 * math.abs(math.sin(age * (1.3 + (i % 5) * 0.37) + i))
    local blue = i % 3 == 0
    lg.setColor(blue and 0.55 or 0.85, blue and 0.8 or 0.6, 1, 0.55 * tw * a * clamp01(age / 0.6))
    lg.circle("fill", r.x + u * r.w, r.y + v * r.h, math.max(0.6, r.h * 0.004 * (1 + (i % 3))))
  end
end

-- draw img centred at x, y, w wide (the height follows), turned by rot
local function drawCentred(img, x, y, w, rot, alpha, add)
  if not img then return end
  local iw, ih = img:getDimensions()
  local k = w / iw
  if add then lg.setBlendMode("add") end
  lg.setColor(1, 1, 1, alpha)
  lg.draw(img, x, y, rot or 0, k, k, iw / 2, ih / 2)
  if add then lg.setBlendMode("alpha") end
end

local function drawAeonTop(r, age, a)
  local logo, ring = aeon("logo"), aeon("ring")
  if not logo then return false end
  lg.setScissor(r.x, r.y, r.w, r.h)
  drawBootSky(r, age, a)
  local cx, cy = r.x + r.w / 2, r.y + r.h * 0.5
  -- the streaks: in from each side, then drifting on, fading to a glow
  local sIn = easeOut((age - 0.05) / 0.75)
  local drift = math.max(0, age - 0.8) * r.w * 0.015
  local sA = a * clamp01((age - 0.05) / 0.25) * (1 - 0.45 * clamp01((age - 1.2) / 0.8))
  drawCentred(aeon("streak_blue"), r.x + r.w * (-0.45 + 0.7 * sIn) + drift, r.y + r.h * 0.34, r.w * 0.5, 0, sA, true)
  drawCentred(aeon("streak_purple"), r.x + r.w * (1.45 - 0.7 * sIn) - drift, r.y + r.h * 0.68, r.w * 0.5, 0, sA, true)
  -- the ring opens behind where the logo lands, turning slowly, pulsing
  local rIn = easeBack((age - 0.45) / 0.7)
  if ring and rIn > 0 then
    local pulse = 1 + 0.03 * math.sin(age * 3.1)
    drawCentred(ring, cx, cy, r.h * 1.02 * rIn * pulse, age * 0.35, a * clamp01((age - 0.45) / 0.3), true)
  end
  -- the logo drops in, lands with a flash, then floats
  local lt = (age - 0.85) / 0.5
  if lt > 0 then
    local k = 1.7 - 0.7 * easeBack(lt)
    local float = age > 1.35 and math.sin((age - 1.35) * 2.2) * r.h * 0.012 or 0
    drawCentred(logo, cx, cy + float, r.w * 0.64 * k, 0, a * clamp01(lt * 2.5))
    local flash = 1 - clamp01((age - 1.3) / 0.35)
    if age > 1.3 and flash > 0 then
      drawCentred(logo, cx, cy + float, r.w * 0.64, 0, a * flash * 0.8, true)
      lg.setColor(0.7, 0.85, 1, a * flash * 0.35)
      lg.rectangle("fill", r.x, r.y, r.w, r.h)
    end
  end
  lg.setScissor()
  return true
end

local function drawAeonBottom(r, age, a)
  local logo, text = aeon("load_logo"), aeon("load_text")
  local empty, full = aeon("bar_empty"), aeon("bar_full")
  if not (logo and empty and full) then return false end
  lg.setScissor(r.x, r.y, r.w, r.h)
  drawBootSky(r, age + 7, a)
  local cx = r.x + r.w / 2
  -- the logo comes up and settles
  local li = easeBack((age - 0.2) / 0.6)
  if li > 0 then
    drawCentred(logo, cx, r.y + r.h * (0.36 + 0.04 * (1 - li)), r.w * 0.8 * (0.9 + 0.1 * li), 0,
      a * clamp01((age - 0.2) / 0.35))
  end
  -- "Loading" and its dots, one more every third of a second
  local ta = a * clamp01((age - 0.7) / 0.3)
  if text and ta > 0 then
    local tw = r.w * 0.46
    local th = tw * text:getHeight() / text:getWidth()
    local tx, ty = cx - tw / 2, r.y + r.h * 0.64 - th / 2
    local dots = math.floor(age * 3) % 4
    local sx, sy, sw, sh = lg.getScissor()
    lg.intersectScissor(tx, ty, tw * (0.815 + 0.062 * dots), th + 1)
    lg.setColor(1, 1, 1, ta * (0.8 + 0.2 * math.sin(age * 4)))
    lg.draw(text, tx, ty, 0, tw / text:getWidth(), th / text:getHeight())
    lg.setScissor(sx, sy, sw, sh)
  end
  -- the bar: empty, filling with the boot, a bright head on the fill
  local ba = a * clamp01((age - 0.8) / 0.3)
  if ba > 0 then
    local bw = r.w * 0.72
    local k = bw / empty:getWidth()
    local bh = empty:getHeight() * k
    local bx, by = cx - bw / 2, r.y + r.h * 0.79 - bh / 2
    lg.setColor(1, 1, 1, ba)
    lg.draw(empty, bx, by, 0, k, k)
    local p = easeOut((age - 1.0) / (BOOT_TIME - BOOT_FADE - 1.1))
    if p > 0 then
      -- the fill's left cap starts past the frame's glow (5% in)
      local fw = bw * (0.05 + 0.9 * p)
      local sx, sy, sw, sh = lg.getScissor()
      lg.intersectScissor(bx, by, fw, bh)
      lg.draw(full, bx, by, 0, k, k)
      lg.setScissor(sx, sy, sw, sh)
      lg.setBlendMode("add")
      local hx = bx + fw
      for i = 3, 1, -1 do
        lg.setColor(0.9, 0.6, 1, ba * 0.18 * (4 - i))
        lg.circle("fill", hx - bh * 0.1, by + bh / 2, bh * 0.14 * i)
      end
      lg.setBlendMode("alpha")
    end
  end
  lg.setScissor()
  return true
end

local function healthImage(name)
  local key = "health:" .. name
  if state.images[key] == nil then
    local ok, img = pcall(lg.newImage, DIR .. "health/" .. name .. ".png")
    state.images[key] = ok and img or false
    if ok then img:setFilter("linear", "linear") end
  end
  return state.images[key] or nil
end

-- the Health & Safety warning: its HOME Menu title (EN or JP with the
-- artwork setting) over the note on the top screen, the prompt below
local function drawHealth(L, age, which)
  which = which or "all"
  local a = math.min(1, age / HS_FADE)
  local t, bt = L.topCut, L.botCut
  -- top: the title bar, then the note
  if which == "all" or which == "top" then
    lg.setScissor(t.x, t.y, t.w, t.h)
    lg.setColor(0.97, 0.97, 0.97, 1)
    lg.rectangle("fill", t.x, t.y, t.w, t.h)
    lg.setColor(0.86, 0.86, 0.87, 1)
    for y = t.y, t.y + t.h, math.max(2, math.floor(t.h / 60)) * 2 do
      lg.rectangle("fill", t.x, y, t.w, 1)
    end
    local barH = t.h * 0.3
    lg.setColor(1, 1, 1, 1)
    lg.rectangle("fill", t.x, t.y + t.h * 0.08, t.w, barH)
    lg.setColor(0.8, 0.8, 0.8, 1)
    lg.rectangle("fill", t.x, t.y + t.h * 0.08 + barH, t.w, 2)
    local warn = healthImage("warn")
    local title = healthImage(Cart3D.region == "jp" and "title_jp" or "title_en")
    local wx = t.x + t.w * 0.06
    if warn then
      local k = barH * 0.62 / warn:getHeight()
      lg.setColor(1, 1, 1, 1)
      lg.draw(warn, wx, t.y + t.h * 0.08 + barH / 2, 0, k, k, 0, warn:getHeight() / 2)
      wx = wx + warn:getWidth() * k + t.w * 0.05
    end
    if title then
      local k = math.min(barH * 0.7 / title:getHeight(), (t.x + t.w * 0.95 - wx) / title:getWidth())
      lg.setColor(1, 1, 1, 1)
      lg.draw(title, wx, t.y + t.h * 0.08 + barH / 2, 0, k, k, 0, title:getHeight() / 2)
    end
    local f = font(t.h * 0.066)
    lg.setFont(f)
    lg.setColor(0.2, 0.2, 0.22, 1)
    lg.printf("Before using this software, read the Health & Safety Information "
      .. "on the HOME Menu. It contains important information that will help "
      .. "you enjoy this software.", t.x + t.w * 0.08, t.y + t.h * 0.47, t.w * 0.84, "left")
    if a < 1 then
      lg.setColor(0, 0, 0, 1 - a)
      lg.rectangle("fill", t.x, t.y, t.w, t.h)
    end
    lg.setScissor()
  end
  -- bottom: the prompt, breathing
  if which == "all" or which == "bot" then
    lg.setScissor(bt.x, bt.y, bt.w, bt.h)
    lg.setColor(0.97, 0.97, 0.97, 1)
    lg.rectangle("fill", bt.x, bt.y, bt.w, bt.h)
    lg.setColor(0.86, 0.86, 0.87, 1)
    for y = bt.y, bt.y + bt.h, math.max(2, math.floor(bt.h / 60)) * 2 do
      lg.rectangle("fill", bt.x, y, bt.w, 1)
    end
    local pulse = 0.55 + 0.45 * math.abs(math.sin(state.time * 2.2))
    lg.setFont(font(bt.h * 0.07))
    lg.setColor(0.2, 0.2, 0.22, pulse)
    lg.printf("Touch the Touch Screen to continue.", bt.x, bt.y + bt.h * 0.46, bt.w, "center")
    if a < 1 then
      lg.setColor(0, 0, 0, 1 - a)
      lg.rectangle("fill", bt.x, bt.y, bt.w, bt.h)
    end
    lg.setScissor()
  end
end

local function drawBoot(L, which)
  if not booting() then return end
  which = which or "all"
  local b = state.boot
  local age = state.time - b.t0
  lg.push("all")
  if b.phase == "hs" then
    drawHealth(L, age, which)
  elseif b.phase == "home" then
    -- the HOME menu comes up out of white
    local a = 1 - math.min(1, age / HOME_TIME)
    lg.setColor(1, 1, 1, a * a)
    if which == "all" or which == "top" then lg.rectangle("fill", L.topCut.x, L.topCut.y, L.topCut.w, L.topCut.h) end
    if which == "all" or which == "bot" then lg.rectangle("fill", L.botCut.x, L.botCut.y, L.botCut.w, L.botCut.h) end
  else
    -- the jingle, a beat after the click
    if not b.jingle and age > 0.3 then b.jingle = true; Sfx.play("boot") end
    local a = 1
    if age > BOOT_TIME - BOOT_FADE then a = math.max(0, (BOOT_TIME - age) / BOOT_FADE) end
    local zoom = 1 + 0.035 * math.min(1, age / BOOT_TIME)
    if which == "all" or which == "top" then
      lg.setColor(0, 0, 0, 1)
      lg.rectangle("fill", L.topCut.x, L.topCut.y, L.topCut.w, L.topCut.h)
      if not drawAeonTop(L.topCut, age, a) then drawBootScreen(bootImage("top"), L.topCut, age, zoom, a) end
    end
    if which == "all" or which == "bot" then
      lg.setColor(0, 0, 0, 1)
      lg.rectangle("fill", L.botCut.x, L.botCut.y, L.botCut.w, L.botCut.h)
      if not drawAeonBottom(L.botCut, age, a) then drawBootScreen(bootImage("bottom"), L.botCut, age, zoom, a) end
    end
  end
  lg.pop()
end

local function drawWall(file, w, h)
  local img = image(file)
  if not img then return false end
  local iw, ih = img:getDimensions()
  local s = math.max(w / iw, h / ih)
  lg.setColor(1, 1, 1, 1)
  lg.draw(img, (w - iw * s) / 2, (h - ih * s) / 2, 0, s, s)
  return true
end

-- Stickers on the open 3DS's shells: the top half's (surface 1) and the
-- bottom half's (2), each masked by its own art so none covers a screen.
local function alphaTest()
  state.alphaTest = state.alphaTest or lg.newShader([[
    vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
      vec4 p = Texel(tex, tc);
      if (p.a < 0.5) discard;
      return p * color;
    }
  ]])
  return state.alphaTest
end

-- Surface relief creases & physical bends for stickers on the 3DS shell:
-- screen boundary tear & bezel bevel, camera bulge, speaker holes, rubber feet, sliders, and hinge
local function drawShellRelief(ox, oy, sc, bw, bh, surf)
  if surf ~= 1 then return end
  lg.push("all")

  -- 1. Screen boundary tear & bezel drop crease (TOP.full: 224, 148, 1044, 568)
  local cx = ox + TOP.full[1] * sc
  local cy = oy + TOP.full[2] * sc
  local cw = TOP.full[3] * sc
  local ch = TOP.full[4] * sc

  -- Bezel indentation shadow along screen edge (plastic dropping 2mm into screen)
  lg.setColor(0, 0, 0, 0.45)
  lg.setLineWidth(math.max(1.5, 2.5 * sc))
  lg.rectangle("line", cx, cy, cw, ch, math.max(1, 4 * sc))

  -- Highlight crease on the outer radius where plastic rounds off
  lg.setColor(1, 1, 1, 0.22)
  lg.setLineWidth(math.max(1, 1.5 * sc))
  lg.rectangle("line", cx - 2 * sc, cy - 2 * sc, cw + 4 * sc, ch + 4 * sc, math.max(1, 6 * sc))

  -- Torn paper fiber edge along the bezel rim (white fibrous paper fringe)
  lg.setColor(0.97, 0.97, 0.94, 0.75)
  lg.setLineWidth(1)
  local step = math.max(4, math.floor(8 * sc))
  for i = 0, cw, step do
    local jit = ((i * 13) % 5 - 2) * sc
    lg.line(cx + i, cy + jit, cx + math.min(cw, i + step), cy - jit)
    lg.line(cx + i, cy + ch + jit, cx + math.min(cw, i + step), cy + ch - jit)
  end
  for j = 0, ch, step do
    local jit = ((j * 17) % 5 - 2) * sc
    lg.line(cx + jit, cy + j, cx - jit, cy + math.min(ch, j + step))
    lg.line(cx + cw + jit, cy + j, cx + cw - jit, cy + math.min(ch, j + step))
  end

  -- 2. Inner camera lens bulge, in shell pixels (INNER_EYE below is in
  -- top-screen pixels and isn't declared yet here -- reading it crashed
  -- every frame)
  local eye = { 745, 68, 40 }
  local ex = ox + eye[1] * sc
  local ey = oy + eye[2] * sc
  local er = eye[3] * sc * 0.55
  lg.setColor(0, 0, 0, 0.55)
  lg.arc("line", "open", ex, ey, er, math.pi * 0.2, math.pi * 0.9)
  lg.setColor(1, 1, 1, 0.45)
  lg.arc("line", "open", ex, ey, er, -math.pi * 0.8, -math.pi * 0.1)
  lg.setColor(0.1, 0.1, 0.15, 0.6)
  lg.circle("line", ex, ey, er * 0.65)

  -- 3. Rubber bumper feet on both sides of camera
  local feet = { { 470, 60, 28, 16 }, { 1000, 60, 28, 16 } }
  for _, ft in ipairs(feet) do
    local fx, fy, fw, fh = ox + ft[1] * sc, oy + ft[2] * sc, ft[3] * sc, ft[4] * sc
    lg.setColor(1, 1, 1, 0.28)
    lg.line(fx, fy + fh, fx, fy, fx + fw, fy)
    lg.setColor(0, 0, 0, 0.48)
    lg.line(fx + fw, fy, fx + fw, fy + fh, fx, fy + fh)
  end

  -- 4. Speaker grille perforation dots
  local speakers = {
    { 235, 370 }, { 255, 370 }, { 245, 388 }, { 235, 406 }, { 255, 406 },
    { 1235, 370 }, { 1255, 370 }, { 1245, 388 }, { 1235, 406 }, { 1255, 406 }
  }
  for _, spk in ipairs(speakers) do
    local sx, sy = ox + spk[1] * sc, oy + spk[2] * sc
    local sr = 3.2 * sc
    lg.setColor(0, 0, 0, 0.55)
    lg.circle("fill", sx, sy, sr)
    lg.setColor(1, 1, 1, 0.3)
    lg.arc("line", "open", sx, sy, sr, -math.pi * 0.8, -math.pi * 0.1)
  end

  -- 5. Volume slider and 3D slider track indentations
  local sliders = { { 16, 350, 10, 110 }, { bw - 26, 350, 10, 110 } }
  for _, sl in ipairs(sliders) do
    local sx, sy, sw, sh = ox + sl[1] * sc, oy + sl[2] * sc, sl[3] * sc, sl[4] * sc
    lg.setColor(0, 0, 0, 0.5)
    lg.rectangle("fill", sx, sy, sw, sh, sw * 0.4)
    lg.setColor(1, 1, 1, 0.2)
    lg.rectangle("line", sx - 1, sy - 1, sw + 2, sh + 2, sw * 0.4)
  end

  -- 6. Bottom hinge seam
  local hy = oy + (bh - 14) * sc
  lg.setColor(0, 0, 0, 0.45)
  lg.line(ox + 40 * sc, hy, ox + (bw - 40) * sc, hy)
  lg.setColor(1, 1, 1, 0.2)
  lg.line(ox + 40 * sc, hy + 1.5 * sc, ox + (bw - 40) * sc, hy + 1.5 * sc)

  lg.pop()
end

local function shellStickers(img, ox, oy, sc, surf, cover)
  if not img then return end
  local bw, bh = img:getDimensions()
  Sticker.drawOnLid(ox, oy, sc, bw, bh, function()
    lg.setShader(alphaTest())
    lg.draw(img, ox, oy, 0, sc, sc)
    lg.setShader()
  end, cover, surf)
  drawShellRelief(ox, oy, sc, bw, bh, surf)
end

-- the shell being stickered, as the editor's preview (fitted into a rect)
local function shellPreview(surf)
  return function(x, y, W, H)
    local L = state.L
    local img = L and (surf == 1 and L.top.img or L.bottom.img)
    if not img then return end
    local iw, ih = img:getDimensions()
    local s = math.min(W / iw, H / ih)
    local ox, oy = x + (W - iw * s) / 2, y + (H - ih * s) / 2

    -- draw the live UI inside the screen opening first (shows through the shell cutout)
    if surf == 1 then
      local cut = {
        x = math.floor(ox + TOP.full[1] * s),
        y = math.floor(oy + TOP.full[2] * s),
        w = math.floor(TOP.full[3] * s),
        h = math.floor(TOP.full[4] * s),
      }
      lg.setColor(0, 0, 0, 1)
      lg.rectangle("fill", cut.x, cut.y, cut.w, cut.h)
      lg.setColor(1, 1, 1, 1)
      if Theme3DS.active then
        local focus = Home.showing() and Home.barFocus()
        local banners = { downloadplay = "dlplay", eshop = "eshop", camera = "camera", settings = "settings",
                          activity = "activity", friends = "friends", gamenotes = "gamenotes", pokebank = "pokebank" }
        drawTop3DS(cut, banners[focus or ""])
      else
        drawTopIdle(cut)
      end
    elseif surf == 2 then
      local bcut = {
        x = math.floor(ox + BOTTOM.cut[1] * s),
        y = math.floor(oy + BOTTOM.cut[2] * s),
        w = math.floor(BOTTOM.cut[3] * s),
        h = math.floor(BOTTOM.cut[4] * s),
      }
      lg.setColor(0, 0, 0, 1)
      lg.rectangle("fill", bcut.x, bcut.y, bcut.w, bcut.h)
      lg.setColor(1, 1, 1, 1)
      if homeActive() and Home.showing() then
        Home.draw(bcut, state.subject, state.time)
      else
        local canvas = state.canvases[state.kind == "game" and "game" or "launcher"]
        if canvas then
          lg.draw(canvas, bcut.x, bcut.y, 0, bcut.w / canvas:getWidth(), bcut.h / canvas:getHeight())
        end
      end
    end

    lg.setColor(1, 1, 1, 1)
    lg.draw(img, ox, oy, 0, s, s)
    shellStickers(img, ox, oy, s, surf, false)
  end
end

-- the inner camera above the top screen (top_gbc.png pixels): a tap on it
-- opens the sticker maker for the shells
local INNER_EYE = { 487, 20, 24 }
onInnerEye = function(L, x, y)
  local ex, ey = L.top.x + INNER_EYE[1] * L.top.sc, L.top.y + INNER_EYE[2] * L.top.sc
  local r = INNER_EYE[3] * L.top.sc
  return (x - ex) ^ 2 + (y - ey) ^ 2 <= r * r
end

local function innerEyeGlint(L, t)
  local k = (t % 7) / 7
  if k > 0.18 then return end
  local a = math.sin(k / 0.18 * math.pi)
  local ex, ey = L.top.x + INNER_EYE[1] * L.top.sc, L.top.y + INNER_EYE[2] * L.top.sc
  lg.setColor(1, 1, 1, 0.45 * a)
  lg.circle("line", ex, ey, INNER_EYE[3] * L.top.sc * (0.8 + k * 2))
  lg.setColor(1, 1, 1, 0.8 * a)
  lg.circle("fill", ex - INNER_EYE[3] * L.top.sc * 0.2, ey - INNER_EYE[3] * L.top.sc * 0.2, INNER_EYE[3] * L.top.sc * 0.1)
end

-- the sticker maker on the cover screen: the lid on one side, the tools on
-- the other (side by side on a wide cover, stacked on a tall one)
local function coverEditRects(W, H)
  if W >= H then
    local pw = math.floor(W * 0.4)
    return { x = 0, y = 0, w = pw, h = H }, { x = pw, y = 0, w = W - pw, h = H }
  end
  local ph = math.floor(H * 0.42)
  return { x = 0, y = 0, w = W, h = ph }, { x = 0, y = ph, w = W, h = H - ph }
end

local function drawLidWall(W, H)
  lg.push()
  if H > W * 1.1 then
    lg.translate(W, 0)
    lg.rotate(math.pi / 2)
    drawWall(WALL_LID, H, W)
  else
    drawWall(WALL_LID, W, H)
  end
  lg.pop()
end

local function drawLid(W, H)
  if Sticker.editing() then
    local prev, tools = coverEditRects(W, H)
    lg.setColor(0.08, 0.08, 0.09, 1)
    lg.rectangle("fill", 0, 0, W, H)
    Sticker.drawPreview(prev, drawLidIn)
    Sticker.drawEditor(tools)
    return
  end
  -- the teardown Easter egg: the top cover off, its parts on the screen
  if Teardown.active() and Teardown.draw(W, H) then return end
  lg.setColor(0.16, 0.16, 0.17, 1)
  lg.rectangle("fill", 0, 0, W, H)
  -- the black wallpaper behind the closed lid, turned with it
  local portrait = H > W * 1.1
  drawLidWall(W, H)
  -- shaken: the lid rattles a little more with every hard shake
  local jx, jy, jr = Teardown.wobble()
  lg.push()
  lg.translate(W / 2 + jx, H / 2 + jy)
  lg.rotate(jr)
  lg.translate(-W / 2, -H / 2)
  drawLidIn(0, 0, W, H, portrait, true)
  lg.pop()
  Sticker.eyeGlint(state.time)
end

-- a touch on the cover: the sticker maker while it is open there, else the
-- stickers themselves (the right camera lens opens the maker)
coverTouch = function(phase, id, x, y)
  if Teardown.active() then
    if phase == "pressed" then Teardown.pressed(id, x, y)
    elseif phase == "moved" then Teardown.moved(id, x, y)
    else Teardown.released(id, x, y) end
    return
  end
  if Sticker.editing() then
    local prev, tools = coverEditRects(state.W or real.getWidth(), state.H or real.getHeight())
    if phase == "pressed" then Sticker.pressed(id, x, y, tools, prev)
    elseif phase == "moved" then Sticker.moved(id, x, y)
    else Sticker.released(id) end
    return
  end
  if phase == "pressed" then
    if Sticker.coverPressed(id, x, y) == "eye" then Sfx.play("open", true) end
  elseif phase == "moved" then Sticker.coverMoved(id, x, y)
  else Sticker.coverReleased(id, x, y) end
end

local function drawFrame()
  local L = state.L
  local W, H = state.W, state.H
  real.setCanvas()
  lg.push("all")
  lg.origin()
  lg.setShader()
  lg.setScissor()
  lg.setBlendMode("alpha")
  lg.setColor(1, 1, 1, 1)
  if state.mode == "lid" then
    drawLid(W, H)
    lg.pop()
    return
  end
  if skinActive() and state.kind ~= "game" then
    local p, t = EmuPlay.active()
    if p then
      EmuPlay.drawSwitchFullScreen(W, H)
      lg.pop()
      return
    end
    skinGames()
    Skin.draw(W, H, "all")
    -- emuPoke Bank, opened from the system row, over the whole screen
    if PokeBank.isOpen() then PokeBank.drawSingle({ x = 0, y = 0, w = W, h = H })
    elseif Eshop.isOpen() then
      -- the eShop: its top screen on the left, its bottom screen on the right
      local lw = math.floor(W * 0.5)
      Eshop.drawTop({ x = 0, y = 0, w = lw, h = H })
      Eshop.drawBottom({ x = lw, y = 0, w = W - lw, h = H })
    end
    lg.pop()
    return
  end

  local openProgress = 1
  if state.openAnim then
    local age = state.time - state.openAnim.t0
    if age >= state.openAnim.dur then
      state.openAnim = nil
    else
      local p = age / state.openAnim.dur
      openProgress = 1 - (1 - p) * (1 - p) * (1 - p)
    end
  end

  lg.clear(0.05, 0.05, 0.06, 1)
  -- the white wallpaper behind the open 3DS
  drawWall(WALL_OPEN, W, H)

  local topH = L.topH or math.floor(H / 2)
  local animating = openProgress < 1
  local canvas = state.canvases[state.kind == "game" and "game" or "launcher"]
  local gr = gameRect(L)

  -- ==================== TOP HALF (CLAMSHELL LID) ====================
  if animating then
    lg.push()
    local scaleY = 0.15 + 0.85 * openProgress
    lg.translate(0, topH)
    lg.scale(1, scaleY)
    lg.translate(0, -topH)
  end

  if state.kind == "game" then
    lg.setColor(0, 0, 0, 1)
    lg.rectangle("fill", L.topCut.x, L.topCut.y, L.topCut.w, L.topCut.h)
    lg.setColor(1, 1, 1, 1)
    if canvas and state.screenMode ~= "full" then lg.draw(canvas, gr.x, gr.y) end
  elseif emuOn() then
    EmuPlay.drawTop(L.topCut, state.screenMode ~= "gbc")
  elseif pageOn() then
    local P = select(1, EmuPage.active())
    if Credits.isOpen() or not P then Credits.drawTop(L.topCut)
    else drawTop3DS(L.topCut, "emupage:" .. P.id) end
  elseif cameraOn() then
    Camera.drawTop(L.topCut)
  elseif Sticker.editing() then
    local surf = Sticker.surface()
    Sticker.drawPreview(L.topCut, surf == 0 and drawLidIn or shellPreview(surf))
  elseif dlOn() then
    drawTop3DS(L.topCut, "dlplay")
  elseif esOn() then
    drawTop3DS(L.topCut, "eshop")
  elseif actOn() then
    drawTop3DS(L.topCut, "app:activity")
  elseif appOn() then
    local id, m = appOn()
    drawTop3DS(L.topCut, "app:" .. id)
  elseif homeActive() and Home.showing() then
    local focus = Home.barFocus()
    local banners = { downloadplay = "dlplay", eshop = "eshop", camera = "camera", settings = "settings",
                      activity = "activity", friends = "friends", gamenotes = "gamenotes", pokebank = "pokebank" }
    if Theme3DS.active then drawTop3DS(L.topCut, banners[focus or ""])
    else drawTopIdle(L.topCut) end
  else
    if Theme3DS.active then drawTop3DS(L.topCut) else drawTopIdle(L.topCut) end
  end

  drawBoot(L, "top")
  lg.setColor(1, 1, 1, 1)
  lg.draw(L.top.img, L.top.x, L.top.y, 0, L.top.sc, L.top.sc)
  shellStickers(L.top.img, L.top.x, L.top.y, L.top.sc, 1, "shell")
  drawVolume(L)
  if state.kind ~= "game" and not Sticker.editing() then innerEyeGlint(L, state.time) end
  -- FULL: the game covers the whole top panel, Game Boy Color frame included
  if state.kind == "game" and state.screenMode == "full" and canvas then
    lg.setColor(0, 0, 0, 1)
    lg.rectangle("fill", gr.x, gr.y, gr.w, gr.h)
    lg.setColor(1, 1, 1, 1)
    lg.draw(canvas, gr.x, gr.y)
  end

  if animating then
    lg.pop()
  end

  -- ==================== BOTTOM HALF ====================
  if state.kind == "game" then
    local menus = state.canvases.menus
    if state.menusShown and menus then
      lg.setColor(0, 0, 0, 1)
      lg.rectangle("fill", L.botCut.x, L.botCut.y, L.botCut.w, L.botCut.h)
      lg.setColor(1, 1, 1, 1)
      lg.draw(menus, L.botCut.x, L.botCut.y)
    else
      drawIdle(L.botCut)
    end
  elseif emuOn() then
    EmuPlay.drawBottom(L.botCut, state.screenMode ~= "gbc")
  elseif pageOn() then
    EmuPage.drawBottom(L.botCut)
  elseif cameraOn() then
    Camera.drawBottom(L.botCut)
  elseif Sticker.editing() then
    Sticker.drawEditor(L.botCut)
  elseif dlOn() then
    Dlplay.drawBottom(L.botCut)
  elseif esOn() then
    Eshop.drawBottom(L.botCut)
  elseif actOn() then
    Activity.drawBottom(L.botCut)
  elseif appOn() then
    local id, m = appOn()
    m.drawBottom(L.botCut)
  elseif homeActive() and Home.showing() then
    Home.draw(L.botCut, state.subject, state.time)
  else
    lg.setColor(1, 1, 1, 1)
    local vr = state.vwin or L.botView
    if canvas then lg.draw(canvas, vr.x, vr.y) end
    if homeActive() then Home.drawBar(L.botView) end
    drawArrows(L)
  end

  drawBoot(L, "bot")
  lg.setColor(1, 1, 1, 1)
  lg.draw(L.bottom.img, L.bottom.x, L.bottom.y, 0, L.bottom.sc, L.bottom.sc)
  shellStickers(L.bottom.img, L.bottom.x, L.bottom.y, L.bottom.sc, 2, "shell")
  drawButtons(L)
  drawShoulders(L)
  drawToast(state.kind == "game" and gr or L.topCut)

  if animating then
    -- Hinge shadow crease
    lg.setColor(0, 0, 0, 0.45 * (1 - openProgress))
    lg.rectangle("fill", 0, topH - 8, W, 16)
    -- Screen power-up bloom
    lg.setColor(0.35, 0.85, 1.0, 0.22 * (1 - openProgress))
    lg.rectangle("fill", L.topCut.x, L.topCut.y, L.topCut.w, L.topCut.h)
    lg.rectangle("fill", L.botCut.x, L.botCut.y, L.botCut.w, L.botCut.h)
  end

  lg.pop()
end

---------------------------------------------------------------- backend

local backend = {}

local dbgFrames = 0
function backend:update(dt)
  state.time = state.time + (dt or 0)
  -- fold3ds.skin has no per-frame update; its carousel is laid out on draw.
  Home.tick(dt)   -- the play meter runs whenever the app does
  Sticker.tick(dt) -- and wears the re-stuck stickers
  Camera.update(dt, cameraOn())
  Dlplay.update(dt)
  Eshop.update(dt)
  do
    local okL, Lid = pcall(require, "fold3ds.lid")
    if okL and Lid and Lid.update then
      if not state._lidHooked then
        state._lidHooked = true
        Lid.hooks({
          onClick = function(action)
            if action == "open" then
              Sfx.play("hinge", true)
              state.openAnim = { t0 = state.time, dur = 0.55 }
            elseif action == "close" then
              Sfx.play("hingeClose", true)
            end
          end,
        })
      end
      Lid.update()
    end
  end
  -- the Activity Log: the running gen1recomp game's time
  if state.kind == "game" then
    local ok, GV = pcall(require, "src.core.GameVersion")
    local v = ok and GV.get and GV.get() or nil
    local info = v and GV.info and GV.info(v)
    Activity.playing(v, info and info.displayName or v, dt)
  else
    local _, et = EmuPlay.update(dt)
    -- a word from an emulator (a game added, a state saved, ...)
    for _, ep in ipairs(Emus.providers()) do
      local okm, msg = pcall(function() return ep.message and ep.message() end)
      if okm and msg then toast(msg) end
      if et and ep.toast then
        local okt, text, at = pcall(ep.toast)
        if okt and text and at ~= state.emuToastAt then state.emuToastAt = at; toast(text) end
      end
    end
    if et then Activity.playing(et.id, et.name, dt) else Activity.playing(nil) end
  end
  Activity.tick(dt, state.time)
  -- the volume keys move the slider (and are kept from Android's volume)
  if state.volKeysSent ~= state.volKeys then
    state.volKeysSent = state.volKeys
    bridge("vol.capture", state.volKeys and "1" or "0")
  end
  if state.volKeys then
    local n = tonumber(bridge("vol.take") or "0") or 0
    if n ~= 0 then setVolume((state.volume or 1) + n / 10) end
  end
  if state.volSaveAt and state.time >= state.volSaveAt then state.volSaveAt = nil; saveSettings() end
  -- the top screen's cartridge feels the phone: a quick spin when it is
  -- moved (the gyroscope), a lean with its tilt (the accelerometer)
  if Theme3DS.active and state.mode == "ds" and state.kind ~= "game" then
    if state.sensors == nil then
      local ok, S = pcall(require, "src.core.Sensors")
      state.sensors = ok and S or false
    end
    local S = state.sensors
    if S then
      local ok, gx, gy, gz = pcall(S.read, "gyroscope")
      if ok and gx and math.sqrt(gx * gx + gy * gy + (gz or 0) ^ 2) > 2.4 then Cart3D.kick(state.time) end
      local ok2, ax, ay = pcall(S.read, "accelerometer")
      if ok2 and ax then Cart3D.setTilt(-ax / 9.8, ay / 9.8 - 0.5) end
    end
  end
  -- the shut phone shaken hard, again and again: the teardown Easter egg
  if state.mode == "lid" and state.shakeEgg ~= false and not Teardown.active() then
    if state.sensors == nil then
      local ok, S = pcall(require, "src.core.Sensors")
      state.sensors = ok and S or false
    end
    if state.sensors then
      local ok, ax, ay, az = pcall(state.sensors.read, "accelerometer")
      if ok and ax then Teardown.feed(ax, ay, az) end
    end
    if os.getenv("POKEPORT_FOLD_TEARDOWN") and not state.teardownTested then
      state.teardownTested = true
      Teardown.start()
      if os.getenv("POKEPORT_FOLD_TEARDOWN") == "solve" then Teardown.autoSolve(2.5) end
      if os.getenv("POKEPORT_FOLD_TEARDOWN") == "lcd" then Teardown.debugFace("lcd") end
    end
  end
  -- today's steps for the top screen (every few seconds, 3DS theme only)
  if Theme3DS.active and state.time >= (state.stepsAt or 0) then
    state.stepsAt = state.time + 3
    local fake = os.getenv("POKEPORT_FOLD_FAKESTEPS")
    local n = fake and tonumber(fake) or tonumber(bridge("steps") or "")
    state.steps = n
    Activity.steps(n)
  end
  if M.debug and dbgFrames < 3 then dbgFrames = dbgFrames + 1 io.stdout:setvbuf("no") print("fold3ds update mode=" .. tostring(state.mode) .. " kind=" .. tostring(state.kind)) end
  if M.driverTick then M.driverTick() end
  local mode = detectMode()
  local W, H = real.getDimensions()
  if mode ~= state.mode then
    releaseAll()
    -- opening the phone: mechanical hinge noise and unfolding animation
    if mode == "ds" and (state.mode == "lid" or state.mode == "off") then
      Sfx.play("hinge", true)
      state.openAnim = { t0 = state.time, dur = 0.55 }
    elseif mode == "lid" and state.mode == "ds" then
      Sfx.play("hingeClose", true)
    end
    state.mode = mode
  end
  if not state._openedOnce and mode == "ds" then
    state._openedOnce = true
    state.openAnim = { t0 = state.time, dur = 0.55 }
    Sfx.play("hinge", true)
  end
  if mode == "ds" and (W ~= state.W or H ~= state.H or not state.L) then
    state.W, state.H = W, H
    state.L = layout(W, H)
    if not state.L then state.mode = "off" end
  end
  state.W, state.H = W, H
  state.vwin = state.mode == "ds" and virtualRect() or nil
  -- the launcher's compact bottom-screen layout
  do
    local ok, LV = pcall(require, "src.import.LauncherView")
    if ok and type(LV) == "table" then
      LV.fold = state.mode == "ds" or nil
      LV.foldNoHeader = homeActive() or nil
      LV.foldClusterOut = (state.mode == "ds" and state.theme ~= "3ds") or nil
      LV.foldSticker = {
        has = Sticker.has, open = Sticker.open, remove = Sticker.remove,
        count = Sticker.count, putBack = Sticker.putBack,
        addDefault = Sticker.addDefault,
        getFavorites = Sticker.getFavorites,
        applyFavorite = Sticker.applyFavorite,
      }
      LV.foldBottomShell = {
        get = function() return state.bottomShell or "default" end,
        set = function(v)
          state.bottomShell = (v == "clean" or v == "distressed") and v or "default"
          saveSettings()
          if state.mode == "ds" then
            state.L = layout(state.W, state.H)
          end
        end,
      }
      -- theme selection in SKINS: 3DS (Dual-screen Fold) or Switch (Full-screen)
      LV.foldTheme = LV.foldTheme or {
        get = function() return state.theme end,
        set = function(v)
          state.theme = (v == "switch") and "switch" or "3ds"
          SkinManager.setSkin(state.theme)
          loadSkin()
          saveSettings()
        end,
        choices = { { "3ds", "Nintendo 3DS (Fold)" }, { "switch", "Nintendo Switch (Full Screen)" } }
      }
      -- the top screen cartridges: EN or JP artwork
      LV.foldArtwork = LV.foldArtwork or {
        get = function() return Cart3D.region end,
        set = function(v)
          Cart3D.region = v == "jp" and "jp" or "intl"
          Sfx.play("button")
          saveSettings()
        end,
      }
    end
  end
  -- the 3DS look dresses the launcher on the fold's bottom screen
  Theme3DS.set(state.mode == "ds" and state.theme == "3ds")
  Sticker.update()
  if homeActive() then Home.update(state.subject) end
  -- held scroll arrow / d-pad: repeat
  local now = state.time
  for i = 1, 2 do
    local r = i == 1 and state.arrowHeld or state.padScroll
    if r and now >= r.next then
      -- held: speeds up to four steps a repeat over two seconds
      r.count = (r.count or 0) + 1
      if state.kind == "game" or not scrollBy(r.dir, 1 + math.min(3, r.count / 7)) then
        if r == state.padScroll then state.padScroll = nil end
      end
      r.next = now + REPEAT_NEXT
    end
  end
  if not state.oriented and love.system.getOS() == "Android" then
    state.oriented = true
    pcall(function() require("src.core.Orientation").apply("landscape") end)
  end
end

local function canvasFor(key, r)
  local c = state.canvases[key]
  if not c or c:getWidth() ~= r.w or c:getHeight() ~= r.h then
    if c and c.release then c:release() end
    c = lg.newCanvas(r.w, r.h)
    state.canvases[key] = c
  end
  return c
end

-- put a split frame's stack back (also run defensively before each frame,
-- should a draw have thrown between the two halves)
local function unsplit()
  local sp = state.split
  if sp and sp.stack and sp.stack.states ~= sp.full then sp.stack.states = sp.full end
  state.split = nil
end

function backend:beginFrame(kind, subject)
  unsplit()
  state.menusShown = false
  local changed = kind ~= state.kind
  state.kind, state.subject = kind, subject
  if changed then releaseAll() end
  -- back from a game: the HOME menu's grid, as on a 3DS
  if changed and kind == "launcher" then Home.goHome(nil, true) end
  -- the menu's chime the first time it comes up
  -- the first time the menu comes up on the open 3DS: the boot screen
  if kind == "launcher" and not state.chimed and state.mode == "ds" then
    state.chimed = true
    state.boot = { t0 = state.time, jingle = false, phase = "logo" }
    Sfx.play("click")
  end
  Sfx.inGame = kind == "game"
  if state.mode ~= "ds" or not state.L then return end
  state.vwin = virtualRect()
  local r = state.vwin
  local c = canvasFor(kind == "game" and "game" or "launcher", r)
  if kind == "game" then
    -- the shell's buttons replace the engine's touch overlay
    local ok, TC = pcall(require, "src.core.TouchControls")
    if ok and TC then TC.enabled = false end
    -- START's menu / the mod manager open: the top screen draws the stack
    -- below them, the bottom screen draws them (endFrame)
    local base = menuBase(subject)
    if base then
      local full = subject.stack.states
      local top = {}
      for i = 1, base - 1 do top[i] = full[i] end
      local menus = {}
      for i = base, #full do menus[#menus + 1] = full[i] end
      state.split = { stack = subject.stack, full = full, top = top, menus = menus }
      subject.stack.states = top
    end
  end
  -- the 3DS theme draws its own 3D cart on the top screen (fold3ds.cart3d)
  do
    local ok, LV = pcall(require, "src.import.LauncherView")
    if ok and type(LV) == "table" then LV.foldTopCart = nil end
  end
  state.frameCanvas = c
  real.setCanvas(c)
  lg.clear(0, 0, 0, 1)
end

-- the menus of a split frame, drawn by the game itself into the bottom screen
local function drawMenus(subject)
  local sp = state.split
  local L = state.L
  local r = L.botCut
  local c = canvasFor("menus", r)
  sp.stack.states = sp.menus
  state.vwin = r
  state.frameCanvas = c
  real.setCanvas(c)
  lg.clear(0, 0, 0, 1)
  lg.push("all")
  local ok, err = pcall(subject.draw, subject)
  lg.pop()
  if not ok then print("fold3ds: bottom menu draw: " .. tostring(err)) end
  sp.stack.states = sp.full
  state.frameCanvas = nil
  state.vwin = virtualRect()
  state.menusShown = true
end

function backend:endFrame(kind, subject)
  state.frameCanvas = nil
  if state.split then state.split.stack.states = state.split.full end
  if state.mode ~= "off" and kind == "game" and state.split and state.L then drawMenus(subject) end
  state.split = nil
  if state.mode == "off" then return end
  drawFrame()
end

---------------------------------------------------------------- install

-- The community mod catalog in FIND: the index is added once (a player who
-- removes it keeps it removed), and the feed shipped in the APK stands in
-- until the first live fetch replaces it.
local function seedModIndex()
  local ok, err = pcall(function()
    local ModIndex = require("src.mods.ModIndex")
    local SaveData = require("src.core.SaveData")
    local opts = SaveData.loadOptions()
    if type(opts) ~= "table" then return end
    local source = ModIndex.resolveSource(MOD_INDEX)
    if not source then return end
    if not opts.fold3dsModIndex then
      ModIndex.addSource(MOD_INDEX)
      opts = SaveData.loadOptions()
      opts.fold3dsModIndex = true
      SaveData.saveOptions(opts)
    end
    local listed = false
    for _, row in ipairs(opts.modIndexes or {}) do
      if row.feed == source.feed then listed = true end
    end
    if not listed or ModIndex.readCache(source.feed) then return end
    local text = love.filesystem.read(DIR .. MOD_INDEX_SNAPSHOT)
    if not text then return end
    local index = ModIndex.parse(text)
    if not index then return end
    ModIndex.writeCache(source.feed, index)
    -- stale on purpose: the next visit to FIND fetches the live feed
    opts = SaveData.loadOptions()
    local entry = opts.modIndexCache and opts.modIndexCache[source.feed]
    if entry then
      entry.checkedAt = 0
      SaveData.saveOptions(opts)
    end
  end)
  if not ok then print("fold3ds: mod index: " .. tostring(err)) end
end

-- Settings gets what the fold launcher's footer used to carry: the app
-- updater, the patch notes and the BOIS CLUB GAMES mark.
local invertShader
local function aboutSection(imp)
  local okLV, LV = pcall(require, "src.import.LauncherView")
  local okS, Strings = pcall(require, "src.core.Strings")
  local S = okS and Strings or function(x) return x end
  local rows = {}
  if okLV and LV._updateControl and imp.Check then
    rows[#rows + 1] = {
      label = S("App updates"),
      actionLabel = function()
        local _, label = LV._updateControl(imp)
        return label or S("Check for updates")
      end,
      action = function()
        local _, _, act = LV._updateControl(imp)
        if act then pcall(act) end
        return false
      end,
    }
  end
  rows[#rows + 1] = {
    label = S("Patch notes"),
    actionLabel = S("Open"),
    action = function()
      if imp._closeSettings then imp:_closeSettings() end
      imp._appPatchNotes = true
      return false
    end,
  }
  if imp._openBugPanel then
    rows[#rows + 1] = {
      label = S("Troubleshooting"),
      actionLabel = S("Open"),
      action = function() imp:_openBugPanel() return false end,
    }
  end
  if imp.bcg then
    rows[#rows + 1] = { label = "", custom = {
      height = function(m) return math.floor(76 * m.s) end,
      draw = function(_, m, x, y, w, h)
        local Kit = require("src.ui.kit.Kit")
        local Theme = require("src.ui.kit.Theme")
        invertShader = invertShader or lg.newShader([[
          vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
            vec4 p = Texel(tex, tc);
            return vec4((vec3(1.0) - p.rgb) * color.rgb, p.a * color.a);
          }
        ]])
        local bw, bh = imp.bcg:getDimensions()
        local sc = math.min((160 * m.s) / bw, (28 * m.s) / bh)
        local dw, dh = bw * sc, bh * sc
        local bx, by = x + (w - dw) / 2, y + math.floor(10 * m.s)
        lg.setShader(invertShader)
        lg.setColor(1, 1, 1, Kit.hover(bx, by, dw, dh) and 1 or 0.85)
        lg.draw(imp.bcg, Theme.snap(bx), Theme.snap(by), 0, sc, sc)
        lg.setShader()
        lg.setColor(1, 1, 1, 1)
        local line = "BOIS CLUB GAMES  -  bois.icu"
        local lw = Kit.textWidth("micro", line)
        Kit.text("micro", line, x + (w - lw) / 2, by + dh + math.floor(8 * m.s), Theme.PAL.muted)
        if Kit.press(x, y, w, h) then pcall(love.system.openURL, "https://bois.icu") end
      end,
    } }
  end
  return { title = S("About"), rows = rows }
end

-- the last section of Settings: Credits (fold3ds/credits.lua)
local function creditsSection(imp)
  return { title = "Credits", rows = {
    { label = "AI Slop Productions and every emulator in AeonDX", actionLabel = "Open",
      action = function()
        if imp._closeSettings then imp:_closeSettings() end
        Credits.open()
        Sfx.play("open")
        return false
      end },
  } }
end

-- the 3DS shell & Switch options
local function controlsSection()
  local okS, Strings = pcall(require, "src.core.Strings")
  local S = okS and Strings or function(x) return x end
  return { title = S("Shell & Controls"), rows = {
    { label = S("Cartridge 3D Model"),
      choices = { { value = "solid3d", label = S("3D Solid (Chunky)") }, { value = "flat", label = S("Flat Card") } },
      selected = function() return state.cartSkin or "solid3d" end,
      select = function(v)
        state.cartSkin = v
        Cart3D.style = v
        saveSettings()
      end },
    { label = S("Switch Touch Controls"),
      choices = { { value = "off", label = S("Off") }, { value = "low", label = S("25%") }, { value = "mid", label = S("50%") }, { value = "high", label = S("75%") }, { value = "solid", label = S("100%") } },
      selected = function()
        local op = state.controlOpacity or 0.65
        if op <= 0.05 then return "off"
        elseif op <= 0.35 then return "low"
        elseif op <= 0.60 then return "mid"
        elseif op <= 0.85 then return "high"
        else return "solid" end
      end,
      select = function(v)
        local map = { off = 0.0, low = 0.25, mid = 0.5, high = 0.75, solid = 1.0 }
        state.controlOpacity = map[v] or 0.65
        saveSettings()
      end },
    { label = S("Shake the closed phone to open its top cover"),
      choices = { { value = "on", label = S("On") }, { value = "off", label = S("Off") } },
      selected = function() return state.shakeEgg == false and "off" or "on" end,
      select = function(v)
        state.shakeEgg = v == "on"
        saveSettings()
      end },
    { label = S("L / ZL / R / ZR buttons"),
      choices = { { value = "on", label = S("On") }, { value = "off", label = S("Off") } },
      selected = function() return state.shoulders and "on" or "off" end,
      select = function(v)
        state.shoulders = v == "on"
        state.shoulderSeen = state.time
        saveSettings()
      end },
    { label = S("Volume keys move the 3DS slider"),
      choices = { { value = "on", label = S("On") }, { value = "off", label = S("Off") } },
      selected = function() return state.volKeys and "on" or "off" end,
      select = function(v)
        state.volKeys = v == "on"
        saveSettings()
      end },
    { label = S("Menu sounds"),
      choices = { { value = "on", label = S("On") }, { value = "off", label = S("Off") } },
      selected = function() return state.sounds and "on" or "off" end,
      select = function(v)
        state.sounds = v == "on"
        Sfx.enabled = state.sounds
        Sfx.play(state.sounds and "on" or "off")
        saveSettings()
      end },
  } }
end

local function wrapSettings()
  local ok, RomImporter = pcall(require, "src.import.RomImporter")
  if not ok or type(RomImporter) ~= "table" or not RomImporter._openSettings then return end
  -- every launcher control a finger or A activates, and a game starting
  if RomImporter.runActions then
    local run = RomImporter.runActions
    RomImporter.runActions = function(self, queue, ...)
      if state.mode == "ds" and type(queue) == "table" and #queue > 0 then Sfx.play("button") end
      return run(self, queue, ...)
    end
  end
  if RomImporter.play then
    local play = RomImporter.play
    RomImporter.play = function(self, ...)
      if state.mode == "ds" then Sfx.play("launch") end
      return play(self, ...)
    end
  end
  local open = RomImporter._openSettings
  RomImporter._openSettings = function(self, ...)
    local r = open(self, ...)
    local model = self._settings
    if state.mode == "ds" and model and type(model.sections) == "table" then
      pcall(function()
        model.sections[#model.sections + 1] = controlsSection()
        model.sections[#model.sections + 1] = aboutSection(self)
        model.sections[#model.sections + 1] = creditsSection(self)
      end)
    end
    return r
  end
end

function M.install()
  if M.installed then return end
  M.installed = true
  loadSettings()
  loadSkin()   -- the theme is known now; a failure here falls back to the 3DS shell
  Sticker.init({ setCanvas = real.setCanvas, font = font })
  Camera.init({ font = font })
  Credits.init({ font = font })
  PokeBank.init({ font = font, sfx = function(name) Sfx.play(name) end })
  -- the Switch skin's buttons for eShop apps stay off until downloaded
  Skin.hide = function(id)
    local okA, Apps = pcall(require, "fold3ds.apps")
    return id == "pokebank" and not (okA and Apps.installed("pokebank"))
  end
  Teardown.init({
    font = font,
    sfx = function(name) Sfx.play(name, true) end,
    bootTop = function(r, t) drawAeonTop(r, t, 1) end,
    setCanvas = real.setCanvas,
    lidImage = function() return image(LID) end,
    lidBox = LID_BOX,
    drawWall = drawLidWall,
    volume = function() return state.volume or 1 end,
    -- back to the app's own lock (update() sets landscape once at start)
    unlock = function() pcall(function() require("src.core.Orientation").apply("landscape") end) end,
  })
  Dlplay.init({ font = font, subject = function() return state.subject end })
  Activity.init({ font = font, drawIcon = function(id, x, y, s)
    if not Home.drawIconFor(state.subject, id, x, y, s) then
      lg.setColor(0.85, 0.9, 0.9, 1)
      lg.rectangle("fill", x, y, s, s, s * 0.15, s * 0.15)
    end
  end })
  -- an emulator's game opened from the HOME menu: the Activity Log times it
  -- until the menu is back in focus
  do
    -- every emulator's games, not only Azahar's
    local play = Emus.play
    Emus.play = function(t)
      -- games that leave for their emulator's own screen (Azahar) are timed
      -- until the menu comes back; those playing in the shell, frame by frame
      local p = Emus.owner(t)
      if not (p and p.running) then Activity.launched(t) end
      return play(t)
    end
    local focus = love.focus
    love.focus = function(f)
      Activity.focus(f)
      if focus then return focus(f) end
    end
  end
  Eshop.init({ font = font, subject = function() return state.subject end,
    region = function() return Cart3D.region end })
  Home.init({ font = font, openCamera = Camera.open, drawCameraIcon = Camera.drawIcon, openDlplay = Dlplay.open, openEshop = Eshop.open,
    openActivity = Activity.open, openApp = function(id) if APPS[id] then APPS[id].open() end end })
  if HomeSwitch then HomeSwitch.init({
    font = font,
    openSettings = function() if state.subject and state.subject._openSettings then state.subject:_openSettings() end end,
    launchGame = function(t) if state.subject and state.subject._switchTab then state.subject:_switchTab(t.id) end end,
  }) end
  Notes.init({ font = font, setCanvas = real.setCanvas })
  EmuPlay.init({
    font = font,
    getControlOpacity = function() return state.controlOpacity end,
  })
  EmuPage.init({ font = font, icon = function(id) return image("icons3ds/" .. id .. ".png") end })
  do
    local open = Emus.open
    Emus.open = function(t) EmuPage.opened(t and t.emu) return open(t) end
  end
  Friends.init({ font = font, favourite = Activity.favourite })
  seedModIndex()
  wrapSettings()
  -- the virtual window: size, mode, safe area, pointer queries
  lg.getDimensions = function() if vactive() then return state.vwin.w, state.vwin.h end return real.getDimensions() end
  lg.getWidth = function() if vactive() then return state.vwin.w end return real.getWidth() end
  lg.getHeight = function() if vactive() then return state.vwin.h end return real.getHeight() end
  if real.getPixelDimensions then
    -- physical pixels, not units: the engine picks its whole-pixel Game Boy
    -- scale from these, and on a high-DPI phone units are several pixels
    local function px(v) return math.floor(v * dpi() + 0.5) end
    lg.getPixelDimensions = function() if vactive() then return px(state.vwin.w), px(state.vwin.h) end return real.getPixelDimensions() end
    lg.getPixelWidth = function() if vactive() then return px(state.vwin.w) end return real.getPixelWidth() end
    lg.getPixelHeight = function() if vactive() then return px(state.vwin.h) end return real.getPixelHeight() end
  end
  -- "the screen" (no target, or a nil target) is the subject's canvas while
  -- it draws; the engine's GameViewport passes nil when it has no viewport
  lg.setCanvas = function(...)
    if state.frameCanvas and (select("#", ...) == 0 or select(1, ...) == nil) then
      return real.setCanvas(state.frameCanvas)
    end
    return real.setCanvas(...)
  end
  lw.getMode = function()
    local w, h, flags = real.getMode()
    if vactive() then return state.vwin.w, state.vwin.h, flags end
    return w, h, flags
  end
  if real.getSafeArea then
    lw.getSafeArea = function()
      if vactive() then return 0, 0, state.vwin.w, state.vwin.h end
      return real.getSafeArea()
    end
  end
  lm.getPosition = function()
    local x, y = real.mouseGetPosition()
    if vactive() then return x - state.vwin.x, y - state.vwin.y end
    return x, y
  end
  lm.getX = function() local x = lm.getPosition() return x end
  lm.getY = function() local _, y = lm.getPosition() return y end
  lt.getTouches = function()
    if not vactive() then return real.touchGetTouches() end
    local ids = {}
    for id in pairs(state.vtouch) do ids[#ids + 1] = id end
    return ids
  end
  lt.getPosition = function(id)
    if vactive() and state.vtouch[id] then return state.vtouch[id][1], state.vtouch[id][2] end
    return real.touchGetPosition(id)
  end
  -- events
  orig.touchpressed, orig.touchmoved, orig.touchreleased = love.touchpressed, love.touchmoved, love.touchreleased
  orig.mousepressed, orig.mousemoved, orig.mousereleased = love.mousepressed, love.mousemoved, love.mousereleased
  -- the Switch skin: emuPoke Bank takes the touches while it is open, and
  -- the system row's buttons open what they name (app:pokebank)
  local function skinApp(phase, id, x, y)
    if not (skinActive() and state.kind ~= "game" and not emuOn()) then return false end
    if PokeBank.isOpen() then
      if phase == "pressed" then PokeBank.pressed(id, x, y)
      elseif phase == "released" then appExit(PokeBank, PokeBank.released(id, x, y)) end
      return true
    end
    if Eshop.isOpen() then
      if phase == "pressed" then Eshop.pressed(id, x, y)
      elseif phase == "moved" then Eshop.moved(id, x, y)
      else eshopDone(Eshop.released(id, x, y)) end
      return true
    end
    if phase == "pressed" then
      local L = Skin.layout and Skin.layout(state.W or real.getWidth(), state.H or real.getHeight())
      local b = Skin.systemButtonAt and L and Skin.systemButtonAt(x, y, L)
      if b and b.action == "pokebank" then PokeBank.open() return true end
      if b and b.action == "eshop" then Eshop.open() return true end
    end
    return false
  end
  love.touchpressed = function(id, x, y, ...) if skinApp("pressed", id, x, y) then return end return onTouchPressed(id, x, y, ...) end
  love.touchmoved = function(id, x, y, ...) if skinApp("moved", id, x, y) then return end return onTouchMoved(id, x, y, ...) end
  love.touchreleased = function(id, x, y, ...) if skinApp("released", id, x, y) then return end return onTouchReleased(id, x, y, ...) end
  love.mousepressed = function(x, y, b, istouch, ...)
    if not istouch and skinApp("pressed", "mouse", x, y) then return end
    return onMousePressed(x, y, b, istouch, ...)
  end
  love.mousemoved = function(x, y, dx, dy, istouch, ...)
    if not istouch and PokeBank.isOpen() and skinActive() then return end
    return onMouseMoved(x, y, dx, dy, istouch, ...)
  end
  love.mousereleased = function(x, y, b, istouch, ...)
    if not istouch and skinApp("released", "mouse", x, y) then return end
    return onMouseReleased(x, y, b, istouch, ...)
  end
  -- typing a name or a comment in the Friend List
  local textinput, keypressed = love.textinput, love.keypressed
  love.textinput = function(t, ...)
    if Friends.textinput(t) or EmuPage.textinput(t) then return end
    if textinput then return textinput(t, ...) end
  end
  -- the Switch HOME menu and a game's manual take the keyboard as the
  -- shell's buttons (they have none on screen to press)
  local KEY_BTN = { up = "up", down = "down", left = "left", right = "right",
    w = "up", s = "down", a = "left", d = "right",
    z = "a", ["return"] = "a", space = "a", x = "b", backspace = "b",
    c = "x", v = "y", escape = "start", tab = "select", q = "l", e = "r", h = "home" }
  local function shellKeys()
    if HomeNX.active() then return true end
    local id = appOn()
    return id == "manual"
  end
  love.keypressed = function(k, ...)
    if k == "f6" then
      state.theme = (state.theme == "3ds") and "switch" or "3ds"
      SkinManager.setSkin(state.theme)
      loadSkin()
      saveSettings()
      Sfx.play("button")
      return
    end
    if k == "w" and Home and Home.showing and Home.showing() and not state.openApp then
      if Home.toggleWrapSelected then Home.toggleWrapSelected() return end
    end
    if shellKeys() and KEY_BTN[k] then press(KEY_BTN[k]) return end
    if Friends.keypressed(k) or EmuPage.keypressed(k) then return end
    if keypressed then return keypressed(k, ...) end
  end
  -- controllers (fold3ds.pads): recognised and mapped by their labels as
  -- they connect.  In a recomp game they go to the game as ever (HOME
  -- aside); everywhere else -- both HOME menus, the apps, the emulators in
  -- the shell -- they are the shell's buttons, the left stick its + Pad
  local padOrig = { pressed = love.gamepadpressed, released = love.gamepadreleased,
    axis = love.gamepadaxis, added = love.joystickadded, removed = love.joystickremoved }
  local function inGame() return state.mode ~= "ds" or state.kind == "game" end
  love.gamepadpressed = function(j, b, ...)
    local btn = Pads.shell(j, b)
    if inGame() then
      if btn == "home" and state.mode == "ds" then press("home", "pad") return end
      if padOrig.pressed then return padOrig.pressed(j, Pads.sdl(j, b), ...) end
      return
    end
    if btn then press(btn, "pad") end
  end
  love.gamepadreleased = function(j, b, ...)
    if inGame() then
      if padOrig.released then return padOrig.released(j, Pads.sdl(j, b), ...) end
      return
    end
    local btn = Pads.shell(j, b)
    if btn then release(btn, "pad") end
  end
  love.gamepadaxis = function(j, axis, v, ...)
    if inGame() then
      if padOrig.axis then return padOrig.axis(j, axis, v, ...) end
      return
    end
    for _, e in ipairs(Pads.axis(j, axis, v)) do
      if e[1] == "press" then press(e[2], "pad") else release(e[2], "pad") end
    end
  end
  love.joystickadded = function(j, ...)
    local ok, name = pcall(Pads.added, j)
    if ok and name and (j:isGamepad() or name ~= "Controller") then toast(name .. " connected") end
    if padOrig.added then return padOrig.added(j, ...) end
  end
  love.joystickremoved = function(j, ...)
    local ok, ev = pcall(Pads.removed, j)
    for _, e in ipairs(ok and ev or {}) do release(e[2], "pad") end
    if padOrig.removed then return padOrig.removed(j, ...) end
  end
  -- the frame
  local ok, HostDisplay = pcall(require, "src.core.HostDisplay")
  if ok and HostDisplay and HostDisplay.setBackend then HostDisplay.setBackend(backend) end
  -- desktop testing: a window the size of a foldable's screen, and a script
  local size = os.getenv and os.getenv("POKEPORT_FOLD_SIZE")
  if size then
    local w, h = size:match("^(%d+)x(%d+)$")
    if w then
      pcall(lw.setMode, tonumber(w), tonumber(h), { resizable = true })
      -- the launcher's desktop window manager would resize it back
      lw.setMode = function() return true end
    end
  end
  -- keep the play meter's last seconds when the app closes
  local quit = love.quit
  love.quit = function(...)
    pcall(Home.saveCoins)
    pcall(Activity.flush)
    pcall(Notes.flush)
    if quit then return quit(...) end
  end
  local script = os.getenv and os.getenv("POKEPORT_FOLD_TEST")
  if script then
    M.debug = true
    local okd, driver = pcall(function() return love.filesystem.load(DIR .. "dev/driver.lua")() end)
    if okd and driver then driver.start(script, M) end
  end
  backend:update(0)
end
M.backend = backend

M.state = state
return M
