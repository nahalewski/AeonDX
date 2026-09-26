-- Nintendo eShop (3DS theme, the shopping-bag icon on the HOME menu's applet
-- bar): the community mod catalog (gen1recomp.com/mod) as a 3DS store.
--
-- Everything underneath is the launcher's own FIND machinery on the
-- RomImporter: the catalog (imp.findIndex, loaded by _ensureFind), the
-- thumbnails (_startFindThumb / _findThumb), what is installed
-- (_findInstalledMap) and the download-and-install job (_findInstall ->
-- _beginModInstall), so a mod got here is installed exactly as FIND would.
--
-- Bottom screen: the orange eShop bar, the shelves (New, Popular, Updated,
-- Installed, Cores -- the emulator cores, fold3ds/cores.lua) and a page of titles with their Download / Open buttons; a
-- title's page with its big Download button.  Top screen: the shopping bag
-- turning in 3D over the eShop logo, or the chosen title's art and blurb.
-- Sounds: connecting on the way in, the wait loop while the catalog loads,
-- the gift unwrapping when a download is done, the error chime if not.
-- Art: fold3ds/eshop/*.png, cut from the supplied eShop sprite sheet.
local E = {}

local lg = love.graphics
local Sfx = require("fold3ds.sfx")
local Apps = require("fold3ds.apps")
local Cores = require("fold3ds.cores")

local ctx
local st = {
  open = false,
  view = "shelf",            -- shelf / title
  shelf = "new",             -- new / popular / updated / installed
  page = 1, sel = 1,
  title = nil,               -- the entry shown on its own page
  hits = {}, down = nil, touches = {},
  t = 0,
  job = nil,                 -- { entry, started, done, ok, text }
  images = {},
  wasLoading = false,
}

local SHELVES = {
  { id = "new", name = "New" }, { id = "popular", name = "Popular" },
  { id = "updated", name = "Updated" }, { id = "installed", name = "Installed" },
  { id = "cores", name = "Cores" },
}

-- the Cores shelf: every core in the catalogue, as eShop titles
local SYS_NAMES = { nes = "NES", snes = "Super NES", vb = "Virtual Boy", pokemini = "Pokemon mini",
  gw = "Game & Watch", gc = "GameCube", wii = "Wii", wiiu = "Wii U", switch = "Switch", n64 = "Nintendo 64" }
local function coreRows()
  local _, order, why = Cores.catalog()
  local rows = {}
  for _, c in ipairs(order or {}) do
    local names = {}
    for _, sys in ipairs(c.systems) do names[#names + 1] = SYS_NAMES[sys] or sys end
    rows[#rows + 1] = { id = "core:" .. c.id, core = c.id, title = c.name,
      author = table.concat(names, ", ") .. "  -  core " .. c.version, blurb = c.sub }
  end
  return rows, why
end
local PER_PAGE = 4

local function col(c, a) lg.setColor(c[1] / 255, c[2] / 255, c[3] / 255, a or 1) end
local function rrect(mode, x, y, w, h, r) lg.rectangle(mode, x, y, w, h, r, r, 10) end

local function img(name)
  if st.images[name] == nil then
    local ok, i = pcall(lg.newImage, "fold3ds/eshop/" .. name .. ".png")
    st.images[name] = ok and i or false
    if ok then i:setFilter("linear", "linear") end
  end
  return st.images[name] or nil
end

-- draw an image fitted into a box (keeping its shape), centred
local function fit(i, x, y, w, h, a)
  if not i then return end
  local iw, ih = i:getDimensions()
  local s = math.min(w / iw, h / ih)
  lg.setColor(1, 1, 1, a or 1)
  lg.draw(i, x + (w - iw * s) / 2, y + (h - ih * s) / 2, 0, s, s)
  return iw * s, ih * s
end

---------------------------------------------------------------- the catalog

local function imp() return ctx.subject and ctx.subject() or nil end

local function loading(i)
  return i and not i.findLoaded
end

local function installedMap(i)
  if not i or not i._findInstalledMap then return {} end
  local ok, m = pcall(i._findInstalledMap, i)
  return ok and m or {}
end

local function day(s) return type(s) == "string" and s:match("^(%d%d%d%d%-%d%d%-%d%d)") or "" end

local function shelfRows(i)
  if st.shelf == "cores" then return (coreRows()) end
  local all = i and i.findIndex and i.findIndex.mods or {}
  local ModIndex = require("src.mods.ModIndex")
  local cache = st.cache
  local installed = installedMap(i)
  if cache and cache.src == all and cache.shelf == st.shelf and cache.inst == installed then return cache.rows end
  local rows = {}
  for _, e in ipairs(all) do
    if st.shelf ~= "installed" or installed[e.id] then rows[#rows + 1] = e end
  end
  local function dates(e) return ModIndex.releaseDates(e) or {} end
  if st.shelf == "new" then
    table.sort(rows, function(a, b)
      local da, db = day(dates(a).first or dates(a).latest), day(dates(b).first or dates(b).latest)
      if da ~= db then return da > db end
      return (a.title or a.id) < (b.title or b.id)
    end)
  elseif st.shelf == "updated" then
    table.sort(rows, function(a, b)
      local da, db = day(dates(a).latest), day(dates(b).latest)
      if da ~= db then return da > db end
      return (a.title or a.id) < (b.title or b.id)
    end)
  elseif st.shelf == "popular" then
    table.sort(rows, function(a, b)
      local sa, sb = ModIndex.downloadStats(a), ModIndex.downloadStats(b)
      local na, nb = sa and sa.total or 0, sb and sb.total or 0
      if na ~= nb then return na > nb end
      return (a.title or a.id) < (b.title or b.id)
    end)
  else
    table.sort(rows, function(a, b) return (a.title or a.id) < (b.title or b.id) end)
  end
  -- AeonDX's own apps first (fold3ds/apps.lua)
  for k = #Apps.LIST, 1, -1 do
    local e = Apps.LIST[k]
    if st.shelf ~= "installed" or Apps.installed(e.app) then table.insert(rows, 1, e) end
  end
  st.cache = { src = all, shelf = st.shelf, inst = installed, rows = rows }
  return rows
end

local function isNew(e)
  if e.core then return false end
  if e.app then return not Apps.installed(e.app) end
  local ModIndex = require("src.mods.ModIndex")
  local d = ModIndex.releaseDates(e)
  local first = d and (d.first or d.latest)
  if not first then return false end
  local y, m, dd = first:match("(%d+)%-(%d+)%-(%d+)")
  if not y then return false end
  local t = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(dd), hour = 12 })
  return os.time() - t < 45 * 86400
end

local function thumb(i, e)
  if e and e.core then return nil end
  if e and e.app then
    local key = "app:" .. e.app
    if st.images[key] == nil then
      local ok, t = pcall(lg.newImage, e.icon)
      st.images[key] = ok and t or false
    end
    return st.images[key] or nil
  end
  if not i or not e then return nil end
  if i._startFindThumb then pcall(i._startFindThumb, i, e) end
  local ok, t = pcall(i._findThumb, i, e)
  if ok and type(t) == "userdata" then return t end
  return nil
end

-- what the title's button says: Download, Update or Open
local function status(i, e)
  if e.core then
    local s = Cores.state(e.core)
    return s == "installed" and "open" or s == "update" and "update" or s == "downloading" and "busy" or "download"
  end
  if e.app then return Apps.installed(e.app) and "open" or "download" end
  local installed = installedMap(i)[e.id]
  if not installed then return "download" end
  local ModIndex = require("src.mods.ModIndex")
  local v = ModIndex.displayVersion and ModIndex.displayVersion(e)
  if type(installed) == "string" and v and tostring(v):gsub("^v", "") ~= installed:gsub("^v", "") then
    return "update"
  end
  return "open"
end

local function download(e)
  local i = imp()
  if e.core then
    if Cores.state(e.core) == "downloading" then Sfx.play("noMove") return end
    Cores.install(e.core)
    st.job = { entry = e, started = st.t, core = true }
    Sfx.play("button")
    return
  end
  if e.app then
    -- an app: onto the HOME menu (the job's finish plays the gift)
    Apps.install(e.app)
    if i then i.findNotice = nil end
    st.job = { entry = e, started = st.t }
    st.cache = nil
    Sfx.play("button")
    return
  end
  if not i or not i._findInstall then return end
  if i._modInstall or i._cartInstall then Sfx.play("noMove") return end
  i.findNotice = nil
  pcall(i._findInstall, i, e)
  st.job = { entry = e, started = st.t }
  Sfx.play("button")
end

---------------------------------------------------------------- drawing

local ORANGE = { 246, 120, 20 }
local INK = { 60, 62, 68 }

local function hit(id, x, y, w, h, extra)
  local e = extra or {}
  e.id, e.x, e.y, e.w, e.h = id, x, y, w, h
  st.hits[#st.hits + 1] = e
end

local function spinner(cx, cy, r)
  for k = 0, 7 do
    local a = k / 8 * math.pi * 2 + st.t * 4
    local fade = ((k - st.t * 8) % 8) / 8
    lg.setColor(0.96, 0.5, 0.1, 0.25 + 0.75 * fade)
    lg.circle("fill", cx + math.cos(a) * r, cy + math.sin(a) * r, r * 0.22)
  end
end

local function button(id, x, y, w, h, label, kind)
  local down = st.down == id
  local oy = down and h * 0.05 or 0
  local base = kind == "white" and img("btn_open_white") or img("btn_open")
  if base then
    local iw, ih = base:getDimensions()
    lg.setColor(1, 1, 1, 1)
    lg.draw(base, x, y + oy, 0, w / iw, h / ih)
    -- the sprite's own word is covered by ours
    if kind == "white" then col({ 238, 238, 240 }) else col({ 250, 124, 26 }) end
    rrect("fill", x + w * 0.12, y + oy + h * 0.22, w * 0.76, h * 0.5, h * 0.2)
  else
    col(kind == "white" and { 236, 236, 238 } or ORANGE)
    rrect("fill", x, y + oy, w, h, h * 0.3)
  end
  local f = ctx.font(h * 0.42)
  lg.setFont(f)
  if kind == "white" then col(INK) else lg.setColor(1, 1, 1, 1) end
  lg.printf(label, x, y + oy + (h - f:getHeight()) / 2, w, "center")
  hit(id, x, y, w, h)
end

local function header(r, h)
  -- the orange eShop bar
  for i = 0, h do
    local k = i / h
    lg.setColor(1, 0.62 - 0.12 * k, 0.16 - 0.1 * k, 1)
    lg.rectangle("fill", r.x, r.y + i, r.w, 1)
  end
  lg.setColor(1, 1, 1, 0.3)
  lg.rectangle("fill", r.x, r.y, r.w, h * 0.35)
  local bag = img("bag")
  local s = h * 0.72
  fit(bag, r.x + h * 0.3, r.y + (h - s) / 2, s, s)
  local f = ctx.font(h * 0.46)
  lg.setFont(f)
  lg.setColor(1, 1, 1, 1)
  lg.printf("Nintendo eShop", r.x, r.y + (h - f:getHeight()) / 2, r.w, "center")
  fit(img("coin"), r.x + r.w - h * 1.0, r.y + h * 0.15, h * 0.7, h * 0.7)
end

local function shelfTabs(x, y, w, h)
  local tw = w / #SHELVES
  for k, s in ipairs(SHELVES) do
    local tx = x + (k - 1) * tw
    local on = st.shelf == s.id
    col(on and { 255, 255, 255 } or { 222, 224, 228 })
    rrect("fill", tx + 1, y, tw - 2, h + (on and 4 or 0), h * 0.25)
    if on then col(ORANGE) lg.rectangle("fill", tx + tw * 0.2, y + h - 3, tw * 0.6, 3) end
    local f = ctx.font(h * 0.42)
    lg.setFont(f)
    col(on and { 230, 100, 10 } or { 110, 112, 118 })
    lg.printf(s.name, tx, y + (h - f:getHeight()) / 2, tw, "center")
    hit("shelf:" .. s.id, tx, y, tw, h)
  end
end

local function drawShelf(r, y0, pad)
  local i = imp()
  local rowsH = r.y + r.h - y0 - pad
  local footH = rowsH * 0.17
  local listH = rowsH - footH - pad * 0.5
  local coreWhy
  if st.shelf == "cores" then _, coreWhy = coreRows() end
  if (st.shelf ~= "cores" and (loading(i) or not (i and i.findIndex))) or coreWhy == "loading" then
    -- connecting: the eShop's own loading wheel, turning
    local wheel = img("wheel")
    if wheel then
      local ws = listH * 0.32
      local iw, ih = wheel:getDimensions()
      lg.setColor(1, 1, 1, 1)
      lg.draw(wheel, r.x + r.w / 2, y0 + listH * 0.38, math.floor(st.t * 8) * math.pi / 4, ws / iw, ws / ih, iw / 2, ih / 2)
    end
    fit(img("checking"), r.x + r.w * 0.2, y0 + listH * 0.66, r.w * 0.6, listH * 0.22)
    return
  end
  local rows = shelfRows(i)
  local pages = math.max(1, math.ceil(#rows / PER_PAGE))
  st.page = math.max(1, math.min(pages, st.page))
  if #rows == 0 then
    local f = ctx.font(listH * 0.07)
    lg.setFont(f)
    col(INK, 0.7)
    lg.printf(st.shelf == "installed" and "Nothing installed from the eShop yet."
      or st.shelf == "cores" and (coreWhy == "offline" and "The cores can't be reached. Check the connection."
        or "No cores yet.") or "The catalog is empty.",
      r.x, y0 + listH / 2 - f:getHeight(), r.w, "center")
  end
  local rh = listH / PER_PAGE
  local installed = installedMap(i)
  for k = 1, PER_PAGE do
    local idx = (st.page - 1) * PER_PAGE + k
    local e = rows[idx]
    if not e then break end
    local ry = y0 + (k - 1) * rh
    local chosen = idx == st.sel
    col(chosen and { 255, 246, 232 } or { 255, 255, 255 })
    rrect("fill", r.x + pad, ry + 2, r.w - pad * 2, rh - 4, rh * 0.12)
    col(chosen and ORANGE or { 214, 216, 222 })
    rrect("line", r.x + pad, ry + 2, r.w - pad * 2, rh - 4, rh * 0.12)
    -- the art
    local ts = rh - 12
    local tx, ty = r.x + pad + 6, ry + 6
    col({ 200, 204, 212 })
    rrect("fill", tx, ty, ts, ts, 6)
    local t = thumb(i, e)
    if t then
      lg.stencil(function() rrect("fill", tx, ty, ts, ts, 6) end, "replace", 1)
      lg.setStencilTest("greater", 0)
      local iw, ih = t:getDimensions()
      local s = math.max(ts / iw, ts / ih)
      lg.setColor(1, 1, 1, 1)
      lg.draw(t, tx + (ts - iw * s) / 2, ty + (ts - ih * s) / 2, 0, s, s)
      lg.setStencilTest()
    else
      fit(img("bag"), tx + ts * 0.2, ty + ts * 0.2, ts * 0.6, ts * 0.6, 0.5)
    end
    -- the words
    local bw = (r.w - pad * 2) * 0.27
    local wx = tx + ts + 8
    local ww = r.x + r.w - pad - bw - 10 - wx
    local f = ctx.font(rh * 0.24)
    lg.setFont(f)
    col(INK)
    lg.print(e.title or e.id, wx, ry + rh * 0.1)
    local f2 = ctx.font(rh * 0.17)
    lg.setFont(f2)
    col({ 120, 122, 128 })
    lg.print(e.author or "", wx, ry + rh * 0.1 + f:getHeight())
    col(INK, 0.9)
    lg.print("Free", wx, ry + rh * 0.1 + f:getHeight() + f2:getHeight() * 1.1)
    local tag = isNew(e) and img("tag_new") or (installed[e.id] and status(i, e) == "update" and img("tag_sale"))
    if tag then fit(tag, wx + f2:getWidth("Free") + 8, ry + rh * 0.1 + f:getHeight() + f2:getHeight() * 0.95, rh * 0.9, f2:getHeight() * 1.35) end
    -- the button
    local s = status(i, e)
    local label = s == "open" and (e.core and "Installed" or "Open") or s == "update" and "Update"
      or s == "busy" and "Getting..." or "Download"
    button("row:" .. idx, r.x + r.w - pad - bw - 6, ry + (rh - rh * 0.42) / 2, bw, rh * 0.42, label,
      s == "open" and "white" or nil)
    hit("sel:" .. idx, r.x + pad, ry, r.w - pad * 2 - bw - 12, rh)
  end
  -- the footer: back, page dots, the arrows
  local fy = y0 + listH + pad * 0.5
  fit(img("back"), r.x + pad, fy, footH * 1.2, footH)
  hit("back", r.x + pad, fy, footH * 1.2, footH)
  local n = pages
  for p = 1, math.min(n, 8) do
    local px = r.x + r.w / 2 + (p - (math.min(n, 8) + 1) / 2) * footH * 0.5
    if p == st.page then col(ORANGE) else lg.setColor(0.78, 0.79, 0.82, 1) end
    lg.circle("fill", px, fy + footH / 2, footH * 0.15)
  end
  fit(img("arrow_left"), r.x + r.w - pad - footH * 2.2, fy, footH, footH, st.page > 1 and 1 or 0.35)
  fit(img("arrow_right"), r.x + r.w - pad - footH, fy, footH, footH, st.page < n and 1 or 0.35)
  hit("prev", r.x + r.w - pad - footH * 2.2, fy, footH, footH)
  hit("next", r.x + r.w - pad - footH, fy, footH, footH)
end

local function drawTitle(r, y0, pad)
  local i = imp()
  local e = st.title
  if not e then st.view = "shelf" return end
  local h0 = r.y + r.h - y0 - pad
  local f = ctx.font(h0 * 0.075)
  lg.setFont(f)
  col(INK)
  lg.printf(e.title or e.id, r.x + pad, y0, r.w - pad * 2, "center")
  local f2 = ctx.font(h0 * 0.05)
  lg.setFont(f2)
  col({ 120, 122, 128 })
  local ModIndex = require("src.mods.ModIndex")
  local plain = e.app or e.core
  local v = (not plain and ModIndex.displayVersion and ModIndex.displayVersion(e)) or e.version or ""
  local stats = not plain and ModIndex.downloadStats(e) or nil
  local line = (e.author or "") .. (v ~= "" and ("   v" .. tostring(v):gsub("^v", "")) or "")
    .. (stats and stats.total and ("   " .. stats.total .. " downloads") or "")
  lg.printf(line, r.x + pad, y0 + f:getHeight() * 1.1, r.w - pad * 2, "center")
  local job = st.job
  local by = y0 + h0 * 0.42
  if job and job.entry == e and not job.done then
    -- downloading: the bar fills and the dots turn
    local bar = img("progress")
    local bw, bh = r.w * 0.7, h0 * 0.08
    col({ 110, 112, 118 })
    rrect("fill", r.x + (r.w - bw) / 2, by, bw, bh, bh / 2)
    col(ORANGE)
    local frac = math.min(0.95, (st.t - job.started) / 6)
    rrect("fill", r.x + (r.w - bw) / 2, by, math.max(bh, bw * frac), bh, bh / 2)
    lg.setFont(f2)
    col(INK)
    lg.printf("Downloading...", r.x, by + bh * 1.6, r.w, "center")
    spinner(r.x + r.w / 2, by + bh * 4, h0 * 0.05)
  elseif job and job.entry == e and job.done then
    if job.ok then
      -- the gift cube pops in, then the thank-you card
      local age = st.t - (job.doneAt or st.t)
      local pop = math.min(1, age / 0.35)
      local g = img("gift")
      if g then
        local iw, ih = g:getDimensions()
        local gs = h0 * 0.22 * (0.6 + 0.4 * pop)
        local hop = math.abs(math.sin(math.min(age, 1.2) * math.pi * 2.5)) * h0 * 0.03
        local wiggle = (age < 0.8) and (math.sin(age * math.pi * 8) * 0.1 * (1 - age / 0.8)) or 0
        local gcx, gcy = r.x + r.w / 2, by - h0 * 0.26 - hop
        -- contact drop shadow
        lg.setColor(0.2, 0.15, 0.25, 0.18 * pop)
        lg.ellipse("fill", gcx, by - h0 * 0.16, gs * 0.4, gs * 0.12)
        -- gift box
        lg.push()
        lg.translate(gcx, gcy)
        lg.rotate(wiggle)
        lg.setColor(1, 1, 1, pop)
        lg.draw(g, 0, 0, 0, gs / iw, gs / ih, iw / 2, ih / 2)
        lg.pop()
        -- Sparkles
        local sc = (st.t * 2) % 2.5
        if sc < 0.5 then
          local sprog = sc / 0.5
          local sSize = math.sin(sprog * math.pi) * (gs * 0.2)
          local sx, sy = gcx + gs * 0.18, gcy - gs * 0.22
          lg.setColor(1, 0.95, 0.6, math.sin(sprog * math.pi))
          lg.circle("fill", sx, sy, sSize * 0.4)
        end
      end
      fit(img("thanks"), r.x + r.w * 0.1, by, r.w * 0.8, h0 * 0.2)
      lg.setFont(f2)
      col(INK, 0.8)
      lg.printf(e.core and "Its games play in the Virtual Console folder." or e.app and "It's on your HOME Menu now." or "Turn it on in MODS.", r.x, by + h0 * 0.2, r.w, "center")
    else
      lg.setFont(f2)
      col({ 210, 60, 50 })
      lg.printf("Couldn't download: " .. tostring(job.text or "error"), r.x + pad, by, r.w - pad * 2, "center")
    end
  else
    local s = status(i, e)
    button("get", r.x + r.w * 0.15, by, r.w * 0.7, h0 * 0.16,
      s == "open" and "Installed - open MODS" or s == "update" and "Update (Free)" or "Download (Free)",
      s == "open" and "white" or nil)
  end
  local fy = r.y + r.h - pad - h0 * 0.17
  fit(img("back"), r.x + pad, fy, h0 * 0.2, h0 * 0.17)
  hit("back", r.x + pad, fy, h0 * 0.2, h0 * 0.17)
end

function E.drawBottom(r)
  st.hits = {}
  lg.push("all")
  lg.setScissor(r.x, r.y, r.w, r.h)
  -- the eShop's warm paper
  for i = 0, r.h, 2 do
    local k = i / r.h
    lg.setColor(0.99 - 0.02 * k, 0.96 - 0.03 * k, 0.9 - 0.04 * k, 1)
    lg.rectangle("fill", r.x, r.y + i, r.w, 2)
  end
  local pad = math.floor(r.w * 0.02)
  local hh = math.floor(r.h * 0.12)
  header(r, hh)
  local y = r.y + hh + pad * 0.5
  if st.view == "shelf" then
    local th = math.floor(r.h * 0.09)
    shelfTabs(r.x + pad, y, r.w - pad * 2, th)
    drawShelf(r, y + th + pad, pad)
  else
    drawTitle(r, y + pad, pad)
  end
  lg.pop()
end

-- the top screen (inside the 3DS top screen's frame): the turning bag over
-- the logo, or the chosen title's art and blurb
local function bag3d(cx, cy, s, t)
  local bag = img("bag")
  if not bag then return end
  local iw, ih = bag:getDimensions()
  local cycle = (t % 5) / 5
  local turn = cycle < 0.35 and 0 or (cycle - 0.35) / 0.65
  turn = turn * turn * (3 - 2 * turn)
  local a = turn * math.pi * 2 + 0.2 * math.sin(t * 1.2)
  local ca, sa = math.cos(a), math.sin(a)
  local bob = math.sin(t * 1.5) * s * 0.03
  lg.setColor(0, 0, 0, 0.12)
  lg.ellipse("fill", cx, cy + ih * s * 0.52, iw * s * 0.4 * math.max(0.3, math.abs(ca)), s * 8)
  for k = 10, 1, -1 do
    local sh = 0.55 + 0.25 * k / 10
    lg.setColor(0.8 * sh, 0.32 * sh, 0.02 * sh, 1)
    lg.draw(bag, cx + sa * iw * s * 0.14 * k / 10, cy + bob, 0, s * ca, s, iw / 2, ih / 2)
  end
  local lit = ca >= 0 and 1 or 0.8
  lg.setColor(lit, lit, lit, 1)
  lg.draw(bag, cx, cy + bob, 0, s * ca, s, iw / 2, ih / 2)
end

function E.drawTop(r)
  lg.push("all")
  lg.setScissor(r.x, r.y, r.w, r.h)
  local i = imp()
  local e = st.view == "title" and st.title
    or (st.view == "shelf" and i and i.findLoaded and shelfRows(i)[st.sel]) or nil
  -- a soft orange-white wash
  for y = 0, r.h, 2 do
    local k = y / r.h
    lg.setColor(1, 0.97 - 0.05 * k, 0.92 - 0.1 * k, 1)
    lg.rectangle("fill", r.x, r.y + y, r.w, 2)
  end
  if e and st.view == "title" then
    local ts = r.h * 0.62
    local t = thumb(i, e)
    local tx, ty = r.x + r.w * 0.05, r.y + (r.h - ts) / 2
    col({ 220, 222, 228 })
    rrect("fill", tx, ty, ts, ts, 10)
    if t then
      lg.stencil(function() rrect("fill", tx, ty, ts, ts, 10) end, "replace", 1)
      lg.setStencilTest("greater", 0)
      local iw, ih = t:getDimensions()
      local s = math.max(ts / iw, ts / ih)
      lg.setColor(1, 1, 1, 1)
      lg.draw(t, tx + (ts - iw * s) / 2, ty + (ts - ih * s) / 2, 0, s, s)
      lg.setStencilTest()
    else
      bag3d(tx + ts / 2, ty + ts / 2, ts / 260, st.t)
    end
    local wx = tx + ts + r.w * 0.04
    local ww = r.x + r.w - wx - r.w * 0.04
    local f = ctx.font(r.h * 0.08)
    lg.setFont(f)
    col({ 50, 52, 58 })
    lg.printf(e.title or e.id, wx, ty, ww, "left")
    local f2 = ctx.font(r.h * 0.05)
    lg.setFont(f2)
    col({ 90, 92, 98 })
    local _, lines = f:getWrap(e.title or e.id, ww)
    lg.printf(e.summary or "", wx, ty + #lines * f:getHeight() + f2:getHeight() * 0.5, ww, "left")
  else
    bag3d(r.x + r.w / 2, r.y + r.h * 0.38, r.h * 0.0026, st.t)
    local jp = ctx.region and ctx.region() == "jp"
    fit(img(jp and "logo_jp" or "logo"), r.x + r.w * 0.15, r.y + r.h * 0.64, r.w * 0.7, r.h * (jp and 0.24 or 0.2))
    -- the eShop guy hops across the bottom
    local guy = img("guy")
    if guy then
      local gh = r.h * 0.16
      local iw, ih = guy:getDimensions()
      local span = r.w + gh * 2
      local gx = r.x - gh + (st.t * r.w * 0.12) % span
      local hop = math.abs(math.sin(st.t * 6)) * gh * 0.25
      lg.setColor(1, 1, 1, 1)
      lg.draw(guy, gx, r.y + r.h - gh - hop - r.h * 0.02, 0, gh / ih, gh / ih)
    end
    if e then
      local f = ctx.font(r.h * 0.055)
      lg.setFont(f)
      col({ 90, 92, 98 })
      lg.printf(e.title or e.id, r.x, r.y + r.h * 0.88, r.w, "center")
    end
  end
  lg.pop()
end

---------------------------------------------------------------- input

local function rowsNow()
  local i = imp()
  if st.shelf == "cores" then return shelfRows(i) end
  return (i and i.findLoaded) and shelfRows(i) or {}
end

local function showTitle(e)
  st.title = e
  st.view = "title"
  Sfx.play("open")
end

local function activate(id)
  local rows = rowsNow()
  if id == "back" then
    if st.view == "title" then st.view = "shelf"; Sfx.play("back") return end
    return "exit"
  elseif id:match("^shelf:") then
    local s = id:sub(7)
    if s ~= st.shelf then st.shelf, st.page, st.sel = s, 1, 1; Sfx.play("select") end
  elseif id:match("^sel:") then
    local idx = tonumber(id:sub(5))
    if idx == st.sel and rows[idx] then showTitle(rows[idx])
    else st.sel = idx; Sfx.play("over") end
  elseif id:match("^row:") then
    local e = rows[tonumber(id:sub(5))]
    if not e then return end
    st.sel = tonumber(id:sub(5))
    local s = status(imp(), e)
    if e.core and (s == "open" or s == "busy") then Sfx.play("noMove") return end
    if s == "open" then
      Sfx.play("open")
      return e.app and ("app:" .. e.app) or "mods"
    end
    showTitle(e)
    download(e)
  elseif id == "get" then
    local e = st.title
    if not e then return end
    local s = status(imp(), e)
    if e.core and (s == "open" or s == "busy") then Sfx.play("noMove") return end
    if s == "open" then Sfx.play("open") return e.app and ("app:" .. e.app) or "mods" end
    download(e)
  elseif id == "prev" or id == "next" then
    local n = math.max(1, math.ceil(#rows / PER_PAGE))
    local p = math.max(1, math.min(n, st.page + (id == "next" and 1 or -1)))
    Sfx.play(p == st.page and "edge" or "strip")
    st.page = p
    st.sel = (p - 1) * PER_PAGE + 1
  end
end

local function hitAt(x, y)
  for k = #st.hits, 1, -1 do
    local h = st.hits[k]
    if x >= h.x and y >= h.y and x <= h.x + h.w and y <= h.y + h.h then return h end
  end
end

function E.pressed(id, x, y)
  local h = hitAt(x, y)
  st.touches[id] = { hit = h and h.id, x0 = x, y0 = y }
  st.down = h and h.id or nil
end

function E.moved(id, x, y)
  local t = st.touches[id]
  if not t then return end
  local h = hitAt(x, y)
  st.down = (h and h.id == t.hit) and t.hit or nil
end

function E.released(id, x, y)
  local t = st.touches[id]
  st.touches[id] = nil
  st.down = nil
  if not t then return end
  if st.view == "shelf" and math.abs(x - t.x0) > 60 and math.abs(x - t.x0) > math.abs(y - t.y0) then
    return activate(x < t.x0 and "next" or "prev")
  end
  local h = hitAt(x, y)
  if h and h.id == t.hit then return activate(h.id) end
end

function E.button(name)
  if name == "home" then return "exit" end
  if name == "b" then return activate("back") end
  local rows = rowsNow()
  if st.view == "shelf" then
    if name == "up" then st.sel = math.max(1, st.sel - 1); Sfx.play("over")
    elseif name == "down" then st.sel = math.min(math.max(1, #rows), st.sel + 1); Sfx.play("over")
    elseif name == "left" then return activate("prev")
    elseif name == "right" then return activate("next")
    elseif name == "a" and rows[st.sel] then showTitle(rows[st.sel])
    elseif name == "l" or name == "r" then
      local k = 1
      for i, s in ipairs(SHELVES) do if s.id == st.shelf then k = i end end
      k = (k + (name == "r" and 1 or -1) - 1) % #SHELVES + 1
      return activate("shelf:" .. SHELVES[k].id)
    end
    st.page = math.floor((st.sel - 1) / PER_PAGE) + 1
  elseif name == "a" then
    return activate("get")
  end
end

---------------------------------------------------------------- life

local waitSource
local function waitLoop(on)
  if on then
    if not Sfx.enabled then return end
    if not waitSource then
      local ok, s = pcall(love.audio.newSource, "fold3ds/sounds/common_wait.wav", "static")
      waitSource = ok and s or false
      if waitSource then waitSource:setLooping(true); waitSource:setVolume(0.5) end
    end
    if waitSource and not waitSource:isPlaying() then waitSource:play() end
  elseif waitSource then
    waitSource:stop()
  end
end

function E.init(context) ctx = context end
function E.isOpen() return st.open end

function E.open()
  st.open = true
  st.view = "shelf"
  st.cache = nil
  local i = imp()
  if i and i._ensureFind then pcall(i._ensureFind, i) end
  st.wasLoading = loading(i)
  Sfx.play("connect")
end

function E.close()
  if not st.open then return end
  st.open = false
  waitLoop(false)
  Sfx.play("back")
end

function E.update(dt)
  st.t = st.t + (dt or 0)
  if not st.open then return end
  local i = imp()
  local now = loading(i)
  waitLoop(now and st.t > 0.8)
  if st.wasLoading and not now then Sfx.play("waitEnd") end
  st.wasLoading = now
  -- a download finishing
  local job = st.job
  if job and job.core and not job.done then
    local s, why = Cores.state(job.entry.core)
    if s ~= "downloading" then
      job.done, job.doneAt = true, st.t
      job.ok = s == "installed"
      job.text = job.ok and (job.entry.title .. " is installed") or ("Couldn't install " .. job.entry.title ..
        (why and (": " .. why) or ""))
      st.cache = nil
      if job.ok then
        local okE, Emu = pcall(require, "fold3ds.emucore")
        if okE and Emu.rescan then Emu.rescan() end
      end
      Sfx.play(job.ok and "gift" or "error")
    end
    return
  end
  if job and not job.done and (job.entry.app or (i and not i._modInstall)) and st.t - job.started > 0.3 then
    job.done = true
    local n = i and i.findNotice
    job.ok = not (n and n.ok == false)
    job.text = n and n.text
    job.doneAt = st.t
    st.cache = nil
    if job.ok and job.entry then
      local okH, Home = pcall(require, "fold3ds.home3ds")
      if okH and Home and Home.wrapTile then Home.wrapTile(job.entry.id) end
    end
    Sfx.play(job.ok and "gift" or "error")
  end
end

return E
