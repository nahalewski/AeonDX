-- Playing an emulator's game INSIDE the 3DS shell (3DS theme): DS games on
-- both screens, Virtual Console (GB / GBC / GBA) games on the top screen
-- with their box art and Save / Load / Reset / Close below.  The 3DS games
-- (Azahar) leave for Azahar's own screen instead and never come here.
--
-- Emulators are the fold3ds.emus providers that play in the shell, i.e.
-- have running().  While one runs this module owns both screens:
--   p.running() -> the game tile, or nil
--   p.update(dt), p.screen(i) -> Image (0 top, 1 DS bottom)
--   p.screenSize(sys) -> w, h
--   p.press(btn) / p.release(btn)   shell button names; "home" = its pause menu
--   p.touch(phase, u, v)            DS bottom screen, 0..1
--   p.menu() -> { open, rows = {{label, id}}, sel }, p.menuDo(id)
--   p.boxArt(t) -> Image, p.stop()
--   p.link(t), p.linkDo(action, arg)  optional: Game Link (fold3ds/gamelink.lua)
--                                     adds its row to the pause menu
--
-- The screens: FULL SCREEN stretches the game over the whole screen (the
-- 3DS top panel, the bottom screen); NATIVE keeps its own shape at whole
-- pixels.  The C-stick switches.
local EP = {}

local lg = love.graphics
local Emus = require("fold3ds.emus")
local Sfx = require("fold3ds.sfx")
local GameLink = require("fold3ds.gamelink")
local NintendoLink = require("fold3ds.nintendolink")

local ctx
local st = { hits = {}, touches = {}, screenRect = nil, menuExtra = 0 }

-- a system's native size and its border: frame colour, the lettering below
-- the screen, and the lettering's colour
local SYSTEMS = {
  gb = { w = 160, h = 144, frame = { 136, 138, 150 }, bezel = { 60, 62, 76 }, text = "GAME BOY",
    ink = { 38, 40, 110 }, dot = { 150, 30, 60 } },
  gbc = { w = 160, h = 144, frame = { 88, 72, 160 }, bezel = { 40, 36, 52 }, text = "GAME BOY COLOR",
    ink = { 240, 240, 250 }, dot = { 240, 70, 60 } },
  gba = { w = 240, h = 160, frame = { 64, 52, 132 }, bezel = { 28, 26, 38 }, text = "GAME BOY ADVANCE",
    ink = { 220, 220, 240 }, dot = { 110, 220, 90 } },
  nds = { w = 256, h = 192, frame = { 30, 31, 36 }, bezel = { 14, 14, 16 }, text = nil },
  switch = { w = 1280, h = 720, frame = { 30, 32, 38 }, bezel = { 18, 18, 20 }, text = "NINTENDO SWITCH",
    ink = { 240, 240, 245 }, dot = { 230, 0, 18 } },
}
EP.SYSTEMS = SYSTEMS

local function col(c, a) lg.setColor(c[1] / 255, c[2] / 255, c[3] / 255, a or 1) end

-- the running emulator and its game
function EP.active()
  for _, p in ipairs(Emus.providers()) do
    if p.running then
      local ok, t = pcall(p.running)
      if ok and t then return p, t end
    end
  end
end

local function system(p, t)
  local s = t and (t.system or t.sys)
  if SYSTEMS[s] then return s end
  if p and p.id == "eden" then return "switch" end
  if p and p.id == "melonds" then return "nds" end
  return "gbc"
end
EP.system = system

function EP.update(dt)
  local p, t = EP.active()
  if not p then return nil end
  if p.update then pcall(p.update, dt) end
  return p, t
end

local function screenImage(p, i)
  if not p.screen then return nil end
  local ok, img = pcall(p.screen, i)
  if ok and img then
    if img.setFilter then img:setFilter("nearest", "nearest") end
    return img
  end
end

-- fit w x h into a rect: whole-pixel steps when that fills most of it
local function fit(r, w, h)
  local k = math.min(r.w / w, r.h / h)
  local ik = math.floor(k)
  if ik >= 1 and ik / k > 0.85 then k = ik end
  local dw, dh = w * k, h * k
  return r.x + (r.w - dw) / 2, r.y + (r.h - dh) / 2, dw, dh, k
end

---------------------------------------------------------------- the top screen

-- draw a screen image into r: stretched over all of it (fullScreen, the
-- whole wide screen), or native (its own shape, whole pixels when that
-- fills most of it, black around)
local function drawScreen(img, r, fullScreen)
  lg.setColor(0, 0, 0, 1)
  lg.rectangle("fill", r.x, r.y, r.w, r.h)
  if not img then return r end
  local x, y, w, h
  if fullScreen then
    x, y, w, h = r.x, r.y, r.w, r.h
  else
    x, y, w, h = fit(r, img:getWidth(), img:getHeight())
  end
  lg.setColor(1, 1, 1, 1)
  lg.draw(img, x, y, 0, w / img:getWidth(), h / img:getHeight())
  return { x = x, y = y, w = w, h = h }
end

-- the top screen: the whole top panel
function EP.drawTop(r, fullScreen)
  local p = EP.active()
  if not p then return end
  lg.push("all")
  lg.setScissor(r.x, r.y, r.w, r.h)
  drawScreen(screenImage(p, 0), r, fullScreen)
  lg.pop()
end

---------------------------------------------------------------- the bottom screen

local function hit(id, x, y, w, h) st.hits[#st.hits + 1] = { id = id, x = x, y = y, w = w, h = h } end

local function pill(id, x, y, w, h, label, on)
  if on then lg.setColor(0.2, 0.55, 0.95, 1) else lg.setColor(1, 1, 1, 1) end
  lg.rectangle("fill", x, y, w, h, h * 0.3, h * 0.3)
  lg.setColor(0.78, 0.8, 0.84, 1)
  lg.setLineWidth(1)
  lg.rectangle("line", x, y, w, h, h * 0.3, h * 0.3)
  local f = ctx.font(h * 0.42)
  lg.setFont(f)
  if on then lg.setColor(1, 1, 1, 1) else lg.setColor(0.25, 0.26, 0.3, 1) end
  lg.printf(label, x, y + (h - f:getHeight()) / 2, w, "center")
  hit(id, x, y, w, h)
end

-- the emulator's pause menu (HOME), 3DS style, over the bottom screen
-- the pause menu's rows, with Game Link after Resume when the game links
local function menuRows(p, t, m)
  local rows = m.rows or {}
  local extras = {}
  if GameLink.linkable(p, t) then extras[#extras + 1] = { label = "Game Link", id = "gamelink" } end
  if NintendoLink.supported(p, t) then extras[#extras + 1] = { label = "Nintendo Link", id = "nintendolink" } end
  if #extras == 0 then return rows end
  local out = {}
  for i, row in ipairs(rows) do
    out[#out + 1] = row
    if i == 1 then
      for _, extra in ipairs(extras) do out[#out + 1] = extra end
    end
  end
  return out
end

local function drawMenu(r, m, p, t)
  lg.setColor(0, 0, 0, 0.55)
  lg.rectangle("fill", r.x, r.y, r.w, r.h)
  local rows = menuRows(p, t, m)
  local sel = m.sel
  local extraCount = #rows - #(m.rows or {})
  if extraCount > 0 then
    sel = st.menuExtra > 0 and (1 + st.menuExtra) or ((m.sel or 1) > 1 and m.sel + extraCount or m.sel)
  end
  local rh = math.min(r.h * 0.13, (r.h * 0.8) / math.max(1, #rows))
  local w = r.w * 0.6
  local x = r.x + (r.w - w) / 2
  local y = r.y + (r.h - rh * #rows * 1.15) / 2
  for i, row in ipairs(rows) do
    pill("menu:" .. tostring(row.id or row[2]), x, y, w, rh, tostring(row.label or row[1]), sel == i)
    y = y + rh * 1.15
  end
end

function EP.drawBottom(r, fullScreen)
  local p, t = EP.active()
  st.hits = {}
  st.screenRect = nil
  if not p then return end
  local sys = system(p, t)
  lg.push("all")
  lg.setScissor(r.x, r.y, r.w, r.h)
  if sys == "nds" then
    -- the DS touch screen, as large as fits
    local img = screenImage(p, 1)
    if img then
      st.screenRect = drawScreen(img, r, fullScreen)
    else
      local S = SYSTEMS.nds
      lg.setColor(0, 0, 0, 1)
      lg.rectangle("fill", r.x, r.y, r.w, r.h)
      local x, y, w, h = fit(r, S.w, S.h)
      st.screenRect = { x = x, y = y, w = w, h = h }
    end
  elseif sys == "switch" then
    -- Nintendo Switch companion panel on bottom screen
    for yy = 0, r.h, 2 do
      local k = yy / r.h
      lg.setColor(0.14 - 0.03 * k, 0.15 - 0.03 * k, 0.18 - 0.03 * k, 1)
      lg.rectangle("fill", r.x, r.y + yy, r.w, 2)
    end
    -- Joy-Con neon red (left) & neon blue (right) edge accents
    lg.setColor(0.95, 0.18, 0.15, 0.85)
    lg.rectangle("fill", r.x, r.y, 4, r.h)
    lg.setColor(0.12, 0.65, 0.95, 0.85)
    lg.rectangle("fill", r.x + r.w - 4, r.y, 4, r.h)

    local pad = r.w * 0.04
    local artR = { x = r.x + pad + 4, y = r.y + pad, w = r.w * 0.5 - pad * 1.5, h = r.h - pad * 2 }
    local art = p.boxArt and select(2, pcall(p.boxArt, t))
    if type(art) == "userdata" then
      local x, y, w, h = fit(artR, art:getWidth(), art:getHeight())
      lg.setColor(0, 0, 0, 0.35)
      lg.rectangle("fill", x + 3, y + 4, w, h)
      lg.setColor(1, 1, 1, 1)
      lg.draw(art, x, y, 0, w / art:getWidth(), h / art:getHeight())
    else
      lg.setColor(0.22, 0.23, 0.28, 1)
      lg.rectangle("fill", artR.x, artR.y, artR.w, artR.h, 8, 8)
      col(SYSTEMS.switch.dot)
      local f = ctx and ctx.font and ctx.font(artR.h * 0.1)
      if f then
        lg.setFont(f)
        lg.printf(t and t.name or "Nintendo Switch", artR.x + 6, artR.y + artR.h * 0.4, artR.w - 12, "center")
      end
    end
    local bx = r.x + r.w * 0.5 + pad * 0.5
    local bw = r.w * 0.5 - pad * 1.5 - 4
    local tf = ctx and ctx.font and ctx.font(r.h * 0.065)
    if tf then
      lg.setFont(tf)
      lg.setColor(0.95, 0.95, 0.98, 1)
      lg.printf(t and t.name or "Nintendo Switch Game", bx, r.y + pad, bw, "left")
    end
    local sf = ctx and ctx.font and ctx.font(r.h * 0.045)
    if sf then
      lg.setFont(sf)
      lg.setColor(0.65, 0.68, 0.76, 1)
      lg.printf("Nintendo Switch  -  Eden", bx, r.y + pad + (tf and tf:getHeight() * 1.6 or 24), bw, "left")
    end
    local bh = r.h * 0.14
    local y = r.y + r.h - pad - bh * 2 - pad * 0.5
    pill("vc:pause", bx, y, bw, bh, "Pause / Menu", false)
    y = y + bh + pad * 0.5
    pill("vc:close", bx, y, bw, bh, "Close Game", false)
  else
    -- Virtual Console: the box art, the title, and the game's buttons
    for yy = 0, r.h, 2 do
      local k = yy / r.h
      lg.setColor(0.96 - 0.06 * k, 0.97 - 0.05 * k, 0.99, 1)
      lg.rectangle("fill", r.x, r.y + yy, r.w, 2)
    end
    local pad = r.w * 0.04
    local artR = { x = r.x + pad, y = r.y + pad, w = r.w * 0.5 - pad * 1.5, h = r.h - pad * 2 }
    local art = p.boxArt and select(2, pcall(p.boxArt, t))
    if type(art) == "userdata" then
      local x, y, w, h = fit(artR, art:getWidth(), art:getHeight())
      lg.setColor(0, 0, 0, 0.18)
      lg.rectangle("fill", x + 3, y + 4, w, h)
      lg.setColor(1, 1, 1, 1)
      lg.draw(art, x, y, 0, w / art:getWidth(), h / art:getHeight())
    else
      lg.setColor(1, 1, 1, 1)
      lg.rectangle("fill", artR.x, artR.y, artR.w, artR.h, 8, 8)
      col(SYSTEMS[sys].frame)
      local f = ctx.font(artR.h * 0.1)
      lg.setFont(f)
      lg.printf(t.name or "", artR.x + 6, artR.y + artR.h * 0.4, artR.w - 12, "center")
    end
    local bx = r.x + r.w * 0.5 + pad * 0.5
    local bw = r.w * 0.5 - pad * 1.5
    local tf = ctx.font(r.h * 0.06)
    lg.setFont(tf)
    lg.setColor(0.2, 0.2, 0.24, 1)
    lg.printf(t.name or "", bx, r.y + pad, bw, "left")
    local sf = ctx.font(r.h * 0.045)
    lg.setFont(sf)
    lg.setColor(0.45, 0.46, 0.5, 1)
    lg.printf(({ gb = "Game Boy", gbc = "Game Boy Color", gba = "Game Boy Advance" })[sys] .. "  -  Virtual Console",
      bx, r.y + pad + tf:getHeight() * 2.3, bw, "left")
    local bh = r.h * 0.12
    local y = r.y + r.h - pad - bh * 4 - pad * 1.5
    for _, b in ipairs({ { "save", "Save" }, { "load", "Load" }, { "reset", "Reset" }, { "close", "Close" } }) do
      pill("vc:" .. b[1], bx, y, bw, bh, b[2], false)
      y = y + bh + pad * 0.5
    end
  end
  local m = p.menu and select(2, pcall(p.menu))
  if type(m) == "table" and m.open then drawMenu(r, m, p, t) end
  if GameLink.isOpen() then GameLink.draw(r) end
  lg.pop()
end

local switchBorderImg = nil
local function getSwitchBorder()
  if switchBorderImg ~= nil then return switchBorderImg or nil end
  local candidates = {
    "fold3ds/SKINS/switch/textures/switch border.png",
    "SKINS/switch/textures/switch border.png",
    "switch/textures/switch border.png",
  }
  for _, path in ipairs(candidates) do
    local ok, img = pcall(lg.newImage, path)
    if ok and img then
      img:setFilter("linear", "linear")
      switchBorderImg = img
      return img
    end
  end
  switchBorderImg = false
  return nil
end

local OVERLAY_BUTTONS = {
  { id = "l_stick", btn = "pad",    x = 96,   y = 81,  w = 256, h = 255 },
  { id = "d_up",    btn = "up",     x = 197,  y = 367, w = 135, h = 131 },
  { id = "d_left",  btn = "left",   x = 92,   y = 463, w = 136, h = 135 },
  { id = "d_right", btn = "right",  x = 301,  y = 467, w = 133, h = 131 },
  { id = "d_down",  btn = "down",   x = 197,  y = 559, w = 132, h = 130 },
  { id = "capture", btn = "select", x = 325,  y = 666, w = 123, h = 123 },
  { id = "minus",   btn = "select", x = 399,  y = 106, w = 102, h = 88  },
  { id = "zl",      btn = "zl",     x = 562,  y = 16,  w = 273, h = 153 },
  { id = "l",       btn = "l",      x = 551,  y = 189, w = 286, h = 96  },
  { id = "zr",      btn = "zr",     x = 1081, y = 14,  w = 273, h = 154 },
  { id = "r",       btn = "r",      x = 1080, y = 190, w = 286, h = 95  },
  { id = "plus",    btn = "start",  x = 1416, y = 95,  w = 103, h = 102 },
  { id = "x",       btn = "x",      x = 1607, y = 94,  w = 137, h = 135 },
  { id = "y",       btn = "y",      x = 1492, y = 199, w = 135, h = 134 },
  { id = "a",       btn = "a",      x = 1718, y = 200, w = 187, h = 134 },
  { id = "b",       btn = "b",      x = 1607, y = 300, w = 136, h = 134 },
  { id = "r_stick", btn = "cstick", x = 1543, y = 444, w = 262, h = 261 },
  { id = "home",    btn = "home",   x = 1448, y = 667, w = 127, h = 125 },
}

local switchOverlayImg = nil
local function getSwitchOverlay()
  if switchOverlayImg ~= nil then return switchOverlayImg or nil end
  local candidates = {
    "fold3ds/SKINS/switch/textures/overlay controls test 1.png",
    "SKINS/switch/textures/overlay controls test 1.png",
    "switch/textures/overlay controls test 1.png",
    "fold3ds/SKINS/switch/textures/overlay controls test 2.png",
    "SKINS/switch/textures/overlay controls test 2.png",
    "fold3ds/SKINS/switch/textures/overlay controls test.png",
  }
  for _, path in ipairs(candidates) do
    local ok, img = pcall(lg.newImage, path)
    if ok and img then
      img:setFilter("linear", "linear")
      switchOverlayImg = img
      return img
    end
  end
  switchOverlayImg = false
  return nil
end

local function handleStick(p, stickId, ox, oy, osc, x, y, tt)
  local cx = (stickId == "l_stick") and 224 or 1674
  local cy = (stickId == "l_stick") and 208.5 or 574.5
  local dx = (x - (ox + cx * osc)) / osc
  local dy = (y - (oy + cy * osc)) / osc
  local dir = nil
  local thresh = 25
  if dx * dx + dy * dy >= thresh * thresh then
    if math.abs(dx) > math.abs(dy) * 1.3 then
      dir = dx > 0 and "right" or "left"
    elseif math.abs(dy) > math.abs(dx) * 1.3 then
      dir = dy > 0 and "down" or "up"
    else
      dir = math.abs(dx) > math.abs(dy) and (dx > 0 and "right" or "left") or (dy > 0 and "down" or "up")
    end
  end
  if tt.lastDir ~= dir then
    if tt.lastDir and p.release then pcall(p.release, tt.lastDir) end
    tt.lastDir = dir
    if dir and p.press then pcall(p.press, dir) end
  end
end

function EP.drawSwitchFullScreen(W, H)
  local p, t = EP.active()
  st.hits = {}
  st.screenRect = nil
  if not p then return end

  lg.setColor(0.04, 0.04, 0.05, 1)
  lg.rectangle("fill", 0, 0, W, H)

  local img = screenImage(p, 0)
  local border = getSwitchBorder()

  if border then
    local bw, bh = border:getWidth(), border:getHeight() -- 1916 x 821
    local sc = math.min(W / bw, H / bh)
    local bx = (W - bw * sc) / 2
    local by = (H - bh * sc) / 2

    -- Transparent screen cutout inside switch border:
    local gx, gy, gw, gh
    if bw == 1672 and bh == 941 then
      gx = bx + 362 * sc
      gy = by + 235 * sc
      gw = 943 * sc
      gh = 503 * sc
    else
      -- Default / 1916 x 821 space
      gx = bx + 412 * sc
      gy = by + 114 * sc
      gw = 1096 * sc
      gh = 586 * sc
    end

    st.screenRect = { x = gx, y = gy, w = gw, h = gh }

    -- Draw game screen behind the border frame
    if img then
      lg.setColor(1, 1, 1, 1)
      local iw, ih = img:getWidth(), img:getHeight()
      local k = math.min(gw / iw, gh / ih)
      local sw, sh = iw * k, ih * k
      local sx = gx + (gw - sw) / 2
      local sy = gy + (gh - sh) / 2
      lg.draw(img, sx, sy, 0, sw / iw, sh / ih)
    else
      lg.setColor(0.08, 0.09, 0.11, 1)
      lg.rectangle("fill", gx, gy, gw, gh)
      local f = ctx and ctx.font and ctx.font(gh * 0.08)
      if f then
        lg.setFont(f)
        lg.setColor(1, 1, 1, 0.8)
        lg.printf(t and t.name or "Nintendo Switch", gx, gy + gh * 0.45, gw, "center")
      end
    end

    -- Draw the Switch console border over the screen
    lg.setColor(1, 1, 1, 1)
    lg.draw(border, bx, by, 0, sc, sc)

    -- Register HOME button hit area on the right Joy-Con (approx X=1605, Y=620)
    hit("switch:home", bx + 1580 * sc, by + 595 * sc, 50 * sc, 50 * sc)
  else
    -- Fallback if texture missing: centered 16:9 full screen
    local iw, ih = (img and img:getWidth()) or 1280, (img and img:getHeight()) or 720
    local k = math.min(W / iw, H / ih)
    local sw, sh = iw * k, ih * k
    local sx = (W - sw) / 2
    local sy = (H - sh) / 2
    st.screenRect = { x = sx, y = sy, w = sw, h = sh }
    if img then
      lg.setColor(1, 1, 1, 1)
      lg.draw(img, sx, sy, 0, sw / iw, sh / ih)
    end
  end

  -- On-screen transparent touch controller overlay (customizable opacity from Settings)
  local overlay = getSwitchOverlay()
  local opacity = (ctx and ctx.controlOpacity)
  if opacity == nil and ctx and ctx.getControlOpacity then
    opacity = ctx.getControlOpacity()
  end
  if opacity == nil and _G.state and _G.state.controlOpacity then
    opacity = _G.state.controlOpacity
  end
  opacity = opacity ~= nil and opacity or 0.65

  if overlay and opacity > 0.01 then
    local ow, oh = overlay:getWidth(), overlay:getHeight()
    local osc = math.min(W / ow, H / oh)
    local ox = (W - ow * osc) / 2
    local oy = (H - oh * osc) / 2
    st.overlayParams = { ox = ox, oy = oy, osc = osc }

    lg.setColor(1, 1, 1, opacity)
    lg.draw(overlay, ox, oy, 0, osc, osc)

    for _, b in ipairs(OVERLAY_BUTTONS) do
      hit("ctrl:" .. b.id, ox + b.x * osc, oy + b.y * osc, b.w * osc, b.h * osc)
    end
  else
    st.overlayParams = nil
  end

  local m = p.menu and select(2, pcall(p.menu))
  if type(m) == "table" and m.open then
    local r = st.screenRect or { x = 0, y = 0, w = W, h = H }
    drawMenu(r, m, p, select(2, EP.active()))
  end
  if GameLink.isOpen() then
    -- the Switch skin: the panel in the middle of the screen
    local w = math.min(W * 0.9, H * 1.35)
    local h = w * 0.75
    GameLink.draw({ x = (W - w) / 2, y = (H - h) / 2, w = w, h = h })
  end
  if NintendoLink.isOpen() then
    local w = math.min(W * 0.9, H * 1.35)
    local h = w * 0.75
    NintendoLink.draw({ x = (W - w) / 2, y = (H - h) / 2, w = w, h = h })
  end
end

---------------------------------------------------------------- input

local function hitAt(x, y)
  for k = #st.hits, 1, -1 do
    local h = st.hits[k]
    if x >= h.x and y >= h.y and x <= h.x + h.w and y <= h.y + h.h then return h end
  end
end

function EP.press(btn)
  local p = EP.active()
  if not p then return false end
  if GameLink.isOpen() then GameLink.button(btn) return true end
  if NintendoLink.isOpen() then NintendoLink.button(btn) return true end
  -- the pause menu with a Game Link row the provider doesn't know about:
  -- it sits under the first row
  local t = select(2, EP.active())
  local m = p.menu and select(2, pcall(p.menu))
  if type(m) == "table" and m.open then
    local rows = menuRows(p, t, m)
    local extraCount = #rows - #(m.rows or {})
    if st.menuExtra > 0 and extraCount > 0 then
      if btn == "a" then
        local row = rows[1 + st.menuExtra]
        st.menuExtra = 0
        if p.menuDo then pcall(p.menuDo, "resume") end
        if row and row.id == "gamelink" then GameLink.open(p, t)
        elseif row and row.id == "nintendolink" then NintendoLink.open(t) end
        Sfx.play("open")
        return true
      elseif btn == "up" then
        st.menuExtra = st.menuExtra - 1
        Sfx.play("over")
        return true
      elseif btn == "down" then
        if st.menuExtra < extraCount then
          st.menuExtra = st.menuExtra + 1
        else
          st.menuExtra = 0
          if p.press then pcall(p.press, "down") end
        end
        Sfx.play("over")
        return true
      elseif btn == "b" or btn == "home" then
        st.menuExtra = 0
        if p.press then pcall(p.press, btn) end
        return true
      else
        return true
      end
    elseif btn == "down" and (m.sel or 1) == 1 and extraCount > 0 then
      st.menuExtra = 1
      Sfx.play("over")
      return true
    else
      st.menuExtra = 0
    end
  else
    st.menuExtra = 0
  end
  if p.press then pcall(p.press, btn) end
  return true
end

function EP.release(btn)
  local p = EP.active()
  if not p then return false end
  if GameLink.isOpen() or NintendoLink.isOpen() then return true end
  if p.release then pcall(p.release, btn) end
  return true
end

local function toScreen(x, y)
  local r = st.screenRect
  if not r then return nil end
  local u, v = (x - r.x) / r.w, (y - r.y) / r.h
  return math.max(0, math.min(1, u)), math.max(0, math.min(1, v)),
    u >= 0 and u <= 1 and v >= 0 and v <= 1
end

local function activate(p, id)
  if id == "menu:gamelink" then
    -- close the pause menu, open the panel
    if p.menuDo then pcall(p.menuDo, "resume") end
    GameLink.open(p, select(2, EP.active()))
    Sfx.play("open")
  elseif id == "menu:nintendolink" then
    if p.menuDo then pcall(p.menuDo, "resume") end
    NintendoLink.open(select(2, EP.active()))
    Sfx.play("open")
  elseif id:match("^menu:") then
    if p.menuDo then pcall(p.menuDo, id:sub(6)) end
    Sfx.play("select")
  elseif id == "vc:close" or id == "switch:close" then
    Sfx.play("back")
    if p.stop then pcall(p.stop) end
  elseif id:match("^vc:") or id == "switch:home" then
    Sfx.play("select")
    if id == "switch:home" or id == "vc:pause" then
      if p.press then pcall(p.press, "home") end
    elseif p.menuDo then
      pcall(p.menuDo, id:sub(4))
    end
  end
end

function EP.touch(phase, id, x, y)
  local p = EP.active()
  if not p then return false end
  if GameLink.isOpen() then GameLink.touch(phase, id, x, y) return true end
  if NintendoLink.isOpen() then NintendoLink.touch(phase, id, x, y) return true end
  local m = p.menu and select(2, pcall(p.menu))
  local menuOpen = type(m) == "table" and m.open
  if phase == "pressed" then
    local h = hitAt(x, y)
    local u, v, inside = toScreen(x, y)
    if h and h.id and h.id:match("^ctrl:") then
      local btnId = h.id:sub(6)
      local bDef = nil
      for _, ob in ipairs(OVERLAY_BUTTONS) do
        if ob.id == btnId then bDef = ob; break end
      end
      st.touches[id] = { ctrl = btnId, bDef = bDef }
      if btnId == "home" then
        if p.press then pcall(p.press, "home") end
      elseif btnId == "l_stick" or btnId == "r_stick" then
        if st.overlayParams then
          handleStick(p, btnId, st.overlayParams.ox, st.overlayParams.oy, st.overlayParams.osc, x, y, st.touches[id])
        end
      else
        local btn = bDef and bDef.btn or btnId
        if p.press then pcall(p.press, btn) end
      end
    elseif not menuOpen and inside and p.touch then
      st.touches[id] = { game = true }
      pcall(p.touch, "pressed", u, v)
    else
      st.touches[id] = { hit = h and h.id }
    end
  elseif phase == "moved" then
    local tt = st.touches[id]
    if tt and tt.ctrl and (tt.ctrl == "l_stick" or tt.ctrl == "r_stick") and st.overlayParams then
      handleStick(p, tt.ctrl, st.overlayParams.ox, st.overlayParams.oy, st.overlayParams.osc, x, y, tt)
    elseif tt and tt.game and p.touch then
      local u, v = toScreen(x, y)
      if u then pcall(p.touch, "moved", u, v) end
    end
  else
    local tt = st.touches[id]
    st.touches[id] = nil
    if not tt then return true end
    if tt.ctrl then
      if tt.lastDir and p.release then pcall(p.release, tt.lastDir) end
      local bDef = tt.bDef
      local btn = bDef and bDef.btn or tt.ctrl
      if btn ~= "home" and btn ~= "pad" and btn ~= "cstick" and p.release then
        pcall(p.release, btn)
      end
    elseif tt.game then
      if p.touch then
        local u, v = toScreen(x, y)
        pcall(p.touch, "released", u or 0, v or 0)
      end
    else
      local h = hitAt(x, y)
      if h and h.id == tt.hit then activate(p, h.id) end
    end
  end
  return true
end

function EP.init(context)
  ctx = context
  GameLink.init({ font = context.font, sfx = function(n) Sfx.play(n) end })
  NintendoLink.init({ font = context.font, sfx = function(n) Sfx.play(n) end })
end

return EP
