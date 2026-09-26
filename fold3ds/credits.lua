-- Credits: the last entry of every settings menu (the emulators' pages,
-- the 3DS HOME Menu's Settings and the Switch skin's System Settings).
-- The AI Slop Productions card, then every emulator and project inside
-- AeonDX and what it brings.  On the open 3DS the card fills the top screen
-- and the list scrolls on the bottom one; the Switch skin draws both in its
-- settings pane (drawPanel).  B / Back / HOME close it.
local C = {}

local lg = love.graphics

local CARD = "fold3ds/credits/aislop.jpg"

C.ENTRIES = {
  { name = "AeonDX", by = "nahalewski  -  AI Slop Productions",
    what = "The app: the 3DS HOME menu, its shells, stickers, carts and themes, and the "
      .. "Switch skin, with every emulator below plugged into it." },
  { name = "Azahar", by = "The Azahar team, from Citra and Lime3DS  -  GPL-2.0",
    what = "Nintendo 3DS emulation: 3DS games on both screens, their settings, "
      .. "NetPlay and the 3DS system files." },
  { name = "melonDS", by = "Arisotura and the melonDS contributors  -  GPL-3.0",
    what = "Nintendo DS emulation, through rafaelvcaetano's melonDS Android library." },
  { name = "SkyEmu", by = "Skyler Saleh and the SkyEmu contributors  -  MIT",
    what = "Game Boy, Game Boy Color and Game Boy Advance: the Virtual Console." },
  { name = "Eden", by = "The Eden team, from yuzu  -  GPL-3.0",
    what = "Nintendo Switch emulation: Switch games and their settings." },
  { name = "gen1recomp", by = "bryanthaboi and the gen1recomp contributors",
    what = "Pokemon Red, Blue and Yellow recompiled to run natively, the launcher the "
      .. "HOME menu grew from, and the community mod catalog." },
  { name = "LOVE", by = "The LOVE developers  -  zlib",
    what = "The engine the HOME menu runs on (with SDL, LuaJIT and love-android)." },
  { name = "FCEUmm", by = "The FCEU / FCEUmm and libretro contributors  -  GPL-2.0",
    what = "NES and Famicom Disk System games, a core from the eShop." },
  { name = "Snes9x", by = "The Snes9x team  -  Snes9x licence (non-commercial)",
    what = "Super NES games, a core from the eShop." },
  { name = "Beetle VB", by = "Mednafen's authors and the libretro contributors  -  GPL-2.0",
    what = "Virtual Boy games, a core from the eShop." },
  { name = "PokeMini", by = "JustBurn and the libretro contributors  -  GPL-3.0",
    what = "Pokemon mini games, a core from the eShop." },
  { name = "Game & Watch", by = "Andre Leiradella and the libretro contributors  -  zlib",
    what = "Game & Watch games, a core from the eShop." },
  { name = "libretro", by = "The libretro team",
    what = "The core interface the eShop's cores speak, and the buildbot their Android builds come from." },
  { name = "PKHeX", by = "Kaphotics and the PKHeX contributors  -  GPL-3.0",
    what = "The save and Pokemon formats emuPoke Bank reads, Game Boy to Switch." },
  { name = "PokeAPI", by = "The PokeAPI contributors  -  BSD-3-Clause",
    what = "Every species' name, generation and growth rate in emuPoke Bank." },
  { name = "No-Intro", by = "The No-Intro project, through libretro-database",
    what = "Game names, serials and checksums for the game database and the tiles' names." },
  { name = "Cartridge art", by = "LaunchBox Games Database, GameTDB and Bulbagarden Archives",
    what = "The cartridge photos the labels on the 3D carts were cropped from." },
  { name = "ESP-IDF and NimBLE", by = "Espressif and the Apache Mynewt NimBLE team  -  Apache-2.0",
    what = "The ESP32-S3 board's Bluetooth link to AeonDX." },
  { name = "Mirror", by = "jqssun  -  GPL-3.0",
    what = "Screen mirroring to AirPlay, Moonlight and DisplayLink: AeonDX's Mirror to TV "
      .. "shows on the displays it makes." },
}

local ctx = { font = function(size) return lg.newFont(math.max(6, math.floor(size))) end }
local st = { open = false, scroll = 0, maxScroll = 0, t0 = 0, touch = nil, auto = true }
local card

local function image()
  if card == nil then
    local ok, img = pcall(lg.newImage, CARD)
    card = ok and img or false
    if ok then img:setFilter("linear", "linear") end
  end
  return card or nil
end

function C.init(context) for k, v in pairs(context or {}) do ctx[k] = v end end
function C.isOpen() return st.open end

function C.open()
  st.open, st.scroll, st.auto, st.t0 = true, 0, true, love.timer.getTime()
end

function C.close() st.open, st.touch = false, nil end

-- start the list over without taking the screens (the Switch skin's pane)
function C.restart() st.scroll, st.auto, st.t0 = 0, true, love.timer.getTime() end

-- the card, as big as fits r, with a slow glow breathing behind it
local function drawCard(x, y, w, h)
  lg.setColor(0, 0, 0, 1)
  lg.rectangle("fill", x, y, w, h)
  local img = image()
  if not img then return end
  local iw, ih = img:getDimensions()
  local k = math.min(w / iw, h / ih)
  local t = love.timer.getTime() - st.t0
  local breathe = 1 + 0.012 * math.sin(t * 1.6)
  local zoom = 0.94 + 0.06 * math.min(1, t / 0.5)
  lg.setColor(1, 1, 1, math.min(1, t / 0.35))
  lg.draw(img, x + w / 2, y + h / 2, 0, k * zoom * breathe, k * zoom * breathe, iw / 2, ih / 2)
end

-- the list, scrolling in x, y, w, h (drifts on its own until touched)
local function drawList(x, y, w, h, noBack)
  lg.setColor(0.04, 0.03, 0.07, 1)
  lg.rectangle("fill", x, y, w, h)
  local pad = w * 0.06
  local tf = ctx.font(h * 0.085)
  local nf = ctx.font(h * 0.066)
  local bf = ctx.font(h * 0.043)
  local wf = ctx.font(h * 0.05)
  local sx, sy, sw, sh = lg.getScissor()
  lg.intersectScissor(x, y, w, h)
  local cy = y + pad - st.scroll
  lg.setFont(tf)
  lg.setColor(0.45, 1, 0.3, 1)
  lg.printf("Credits", x, cy, w, "center")
  cy = cy + tf:getHeight() * 1.5
  for _, e in ipairs(C.ENTRIES) do
    lg.setFont(nf)
    lg.setColor(0.72, 0.55, 1, 1)
    lg.printf(e.name, x + pad, cy, w - pad * 2, "left")
    cy = cy + nf:getHeight() * 1.05
    lg.setFont(bf)
    lg.setColor(0.55, 0.8, 1, 1)
    local _, lines = bf:getWrap(e.by, w - pad * 2)
    lg.printf(e.by, x + pad, cy, w - pad * 2, "left")
    cy = cy + #lines * bf:getHeight() + 2
    lg.setFont(wf)
    lg.setColor(0.9, 0.9, 0.95, 1)
    _, lines = wf:getWrap(e.what, w - pad * 2)
    lg.printf(e.what, x + pad, cy, w - pad * 2, "left")
    cy = cy + #lines * wf:getHeight() + nf:getHeight() * 0.9
  end
  lg.setFont(bf)
  lg.setColor(0.5, 0.5, 0.58, 1)
  lg.printf("Nintendo, Game Boy, Nintendo DS, Nintendo 3DS, Nintendo Switch and Pokemon are "
    .. "trademarks of their owners.  AeonDX is not affiliated with them.", x + pad, cy, w - pad * 2, "center")
  cy = cy + bf:getHeight() * 4
  st.maxScroll = math.max(0, cy + st.scroll - (y + h))
  lg.setScissor(sx, sy, sw, sh)
  -- the drift: from a second in, slowly, then a pause at the end and round again
  local t = love.timer.getTime() - st.t0
  if st.auto and t > 1.2 and st.maxScroll > 0 then
    st.scroll = st.scroll + h * 0.05 * love.timer.getDelta()
    if st.scroll > st.maxScroll + h * 0.4 then st.scroll, st.t0 = 0, love.timer.getTime() - 0.4 end
  end
  -- Back (the Switch skin's pane has B instead)
  st.back = nil
  if noBack then return end
  local bh = h * 0.1
  local bw = w * 0.22
  st.back = { x = x + 6, y = y + h - bh - 6, w = bw, h = bh }
  lg.setColor(0.2, 0.55, 0.95, 0.92)
  lg.rectangle("fill", st.back.x, st.back.y, bw, bh, bh * 0.25, bh * 0.25)
  local f = ctx.font(bh * 0.45)
  lg.setFont(f)
  lg.setColor(1, 1, 1, 1)
  lg.printf("Back", st.back.x, st.back.y + (bh - f:getHeight()) / 2, bw, "center")
end

function C.drawTop(r)
  lg.push("all")
  lg.setScissor(r.x, r.y, r.w, r.h)
  drawCard(r.x, r.y, r.w, r.h)
  lg.pop()
end

function C.drawBottom(r)
  lg.push("all")
  lg.setScissor(r.x, r.y, r.w, r.h)
  drawList(r.x, r.y, r.w, r.h)
  lg.pop()
end

-- one pane (the Switch skin): the card on top, the list under it
function C.drawPanel(x, y, w, h)
  lg.push("all")
  lg.setScissor(x, y, w, h)
  local ch = math.min(h * 0.42, w * 720 / 1280)
  drawCard(x, y, w, ch)
  drawList(x, y + ch, w, h - ch, true)
  lg.pop()
end

local function inBack(x, y)
  local b = st.back
  return b and x >= b.x and y >= b.y and x <= b.x + b.w and y <= b.y + b.h
end

-- touch: drag to scroll, tap Back to close; returns "exit" when closed
function C.pressed(id, x, y)
  st.touch = { id = id, y0 = y, scroll = st.scroll, moved = false, back = inBack(x, y) }
end

function C.moved(id, x, y)
  local t = st.touch
  if not t or t.id ~= id then return end
  if math.abs(y - t.y0) > 8 then t.moved = true end
  if t.moved then
    st.auto = false
    st.scroll = math.max(0, math.min(st.maxScroll, t.scroll - (y - t.y0)))
  end
end

function C.released(id, x, y)
  local t = st.touch
  st.touch = nil
  if t and not t.moved and t.back and inBack(x, y) then C.close() return "exit" end
end

function C.wheel(dy)
  st.auto = false
  st.scroll = math.max(0, math.min(st.maxScroll, st.scroll - dy * 30))
end

function C.button(btn)
  if btn == "b" or btn == "home" then C.close() return "exit" end
  if btn == "up" or btn == "down" then
    st.auto = false
    st.scroll = math.max(0, math.min(st.maxScroll, st.scroll + (btn == "down" and 40 or -40)))
  end
end

return C
