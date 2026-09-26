-- Mirroring the running game's top screen to a TV, a per-game setting (the
-- game's pause menu on the bottom screen: "Mirror to TV").  The TV is any
-- external display Android offers: Samsung Smart View / Miracast, HDMI or
-- USB-C, or a mirroring app's virtual display (jqssun's Mirror: AirPlay,
-- Moonlight, DisplayLink).  FoldMirror.java shows it; the pictures go to it
-- through libemucore (ec_mirror_push), read back from the top screen's image
-- at the game's own size.
--
-- The games it's on for are kept in the save folder, mirror.txt, one game
-- id a line.
local M = {}
local lg = love.graphics

local FILE = "mirror.txt"
local st = { games = nil, on = false, canvas = nil, displayAt = -1, display = "" }

local function bridge(cmd, arg)
  local f = love.system and love.system.foldCamera
  if not f then return nil end
  local ok, r = pcall(f, "call", cmd, arg or "")
  return ok and r or nil
end

local function load()
  if st.games then return st.games end
  st.games = {}
  local text = love.filesystem.read(FILE)
  for id in (text or ""):gmatch("[^\r\n]+") do st.games[id] = true end
  return st.games
end

local function save()
  local lines = {}
  for id in pairs(st.games) do lines[#lines + 1] = id end
  table.sort(lines)
  love.filesystem.write(FILE, table.concat(lines, "\n") .. "\n")
end

function M.enabled(t) return t and t.id and load()[t.id] == true or false end

function M.toggle(t)
  if not (t and t.id) then return false end
  load()
  st.games[t.id] = not st.games[t.id] or nil
  save()
  return M.enabled(t)
end

-- the TV's name, "" when none (asked at most once a second)
function M.display()
  local now = love.timer.getTime()
  if now - st.displayAt > 1 then
    st.displayAt = now
    st.display = bridge("mirror.display") or ""
  end
  return st.display
end

-- the pause menu row's label
function M.label(t)
  local tv = M.display()
  if tv == "" then return M.enabled(t) and "Mirror to TV: On (no TV)" or "Mirror to TV: Off" end
  return (M.enabled(t) and "Mirror to TV: On" or "Mirror to TV: Off")
end

-- every frame: the TV follows the running game's setting
function M.update(t)
  local want = M.enabled(t)
  if want ~= st.on then
    st.on = want
    bridge(want and "mirror.on" or "mirror.off")
  end
end

-- the top screen's picture to the TV (img: the game's screen Image)
function M.frame(t, img)
  if not st.on or not img or not M.enabled(t) then return end
  local okF, ffi = pcall(require, "ffi")
  local okE, Emu = pcall(require, "fold3ds.emucore")
  if not okF or not okE or not Emu.mirrorPush then return end
  local w, h = img:getWidth(), img:getHeight()
  if not st.canvas or st.canvas:getWidth() ~= w or st.canvas:getHeight() ~= h then
    st.canvas = lg.newCanvas(w, h)
  end
  lg.push("all")
  lg.setScissor()
  lg.setCanvas(st.canvas)
  lg.clear(0, 0, 0, 1)
  lg.setColor(1, 1, 1, 1)
  lg.draw(img, 0, 0)
  lg.setCanvas()
  lg.pop()
  local ok, data = pcall(st.canvas.newImageData, st.canvas)
  if ok and data then
    Emu.mirrorPush(data:getFFIPointer(), w, h)
    data:release()
  end
end

return M
