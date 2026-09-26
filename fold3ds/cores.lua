-- Cores: the emulators AeonDX downloads instead of shipping in the APK, as
-- .aeoncore files from this repository's "cores" release (built by
-- .github/workflows/cores.yml; the catalogue and format: tools/cores/README.md).
--
-- A .aeoncore is a zip:
--   aeoncore.txt          key=value lines: format, id, name, version,
--                         systems (comma separated), extensions ("nes|fds"),
--                         kind (libretro), lib (the core's path in the zip),
--                         license, source
--   lib/arm64-v8a/<core>.so, LICENSE
--
-- Installing: the catalogue (catalog.txt, one core a line: id, file, size,
-- sha256, name, systems, version) is fetched once a run; a core's file is
-- downloaded into the save folder (cores/<id>.aeoncore), its SHA-256 checked,
-- mounted with love.filesystem and unpacked into cores/<id>/.  An installed
-- core's .so is then a real path emucore dlopens (ec_open_core).
local C = {}
local bit = require("bit")

C.REPO = "https://github.com/nahalewski/AeonDX/releases/download/cores/"
local DIR = "cores/"

local function bridge(cmd, arg)
  local f = love.system and love.system.foldCamera
  if not f then return nil end
  local ok, r = pcall(f, "call", cmd, arg or "")
  return ok and r or nil
end

local function fetch(url, file)
  love.filesystem.remove(file .. ".fail")
  love.filesystem.createDirectory(file:match("^(.*)/[^/]*$") or "")
  return bridge("fetch", url .. "|" .. love.filesystem.getSaveDirectory() .. "/" .. file)
end

---------------------------------------------------------------- SHA-256
local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}
local band, bor, bxor, bnot, ror, rshift = bit.band, bit.bor, bit.bxor, bit.bnot, bit.ror, bit.rshift

function C.sha256(msg)
  local h = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
  for i = 1, 8 do h[i] = bit.tobit(h[i]) end
  local len = #msg
  local extra = 64 - ((len + 9) % 64)
  if extra == 64 then extra = 0 end
  local bits = len * 8
  local tail = { "\128", ("\0"):rep(extra) }
  for i = 7, 0, -1 do tail[#tail + 1] = string.char(math.floor(bits / 2 ^ (i * 8)) % 256) end
  local function block(s, o)
    local w = {}
    for i = 0, 15 do
      local a, b, c, d = s:byte(o + i * 4, o + i * 4 + 3)
      w[i] = bor(bit.lshift(a, 24), bit.lshift(b, 16), bit.lshift(c, 8), d)
    end
    for i = 16, 63 do
      local s0 = bxor(ror(w[i - 15], 7), ror(w[i - 15], 18), rshift(w[i - 15], 3))
      local s1 = bxor(ror(w[i - 2], 17), ror(w[i - 2], 19), rshift(w[i - 2], 10))
      w[i] = bit.tobit(w[i - 16] + s0 + w[i - 7] + s1)
    end
    local a, b, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
    for i = 0, 63 do
      local S1 = bxor(ror(e, 6), ror(e, 11), ror(e, 25))
      local ch = bxor(band(e, f), band(bnot(e), g))
      local t1 = bit.tobit(hh + S1 + ch + K[i + 1] + w[i])
      local S0 = bxor(ror(a, 2), ror(a, 13), ror(a, 22))
      local maj = bxor(band(a, b), band(a, c), band(b, c))
      local t2 = bit.tobit(S0 + maj)
      hh, g, f, e, d, c, b, a = g, f, e, bit.tobit(d + t1), c, b, a, bit.tobit(t1 + t2)
    end
    h[1] = bit.tobit(h[1] + a); h[2] = bit.tobit(h[2] + b); h[3] = bit.tobit(h[3] + c); h[4] = bit.tobit(h[4] + d)
    h[5] = bit.tobit(h[5] + e); h[6] = bit.tobit(h[6] + f); h[7] = bit.tobit(h[7] + g); h[8] = bit.tobit(h[8] + hh)
  end
  local whole = len - len % 64
  for o = 1, whole, 64 do block(msg, o) end
  local last = msg:sub(whole + 1) .. table.concat(tail)
  for o = 1, #last, 64 do block(last, o) end
  local out = {}
  for i = 1, 8 do out[i] = bit.tohex(h[i], 8) end
  return table.concat(out)
end

---------------------------------------------------------------- manifests
local function parseKV(text)
  local t = {}
  for line in (text or ""):gmatch("[^\r\n]+") do
    local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
    if k then t[k] = v end
  end
  return t
end
C.parseKV = parseKV

local function split(s, sep)
  local out = {}
  for part in (s or ""):gmatch("[^" .. sep .. "]+") do out[#out + 1] = part end
  return out
end

-- the catalogue: id -> { id, file, size, sha256, name, systems = {...}, version }
local st = { catalog = nil, asked = false, installed = nil, jobs = {} }

local CATALOG = DIR .. "catalog.txt"

function C.parseCatalog(text)
  local out, order = {}, {}
  for line in (text or ""):gmatch("[^\r\n]+") do
    if not line:match("^%s*#") then
      local f = split(line, "\t")
      if #f >= 7 then
        local c = { id = f[1], file = f[2], size = tonumber(f[3]), sha256 = f[4]:lower(), name = f[5],
          systems = split(f[6], ","), version = f[7], sub = f[8] }
        out[c.id] = c
        order[#order + 1] = c
      end
    end
  end
  return out, order
end

-- ask for the catalogue (once a run); C.catalog() reads it when it's there
function C.refresh()
  love.filesystem.remove(CATALOG)
  fetch(C.REPO .. "catalog.txt", CATALOG)
  st.asked, st.catalog = true, nil
end

function C.catalog()
  if not st.asked then C.refresh() end
  if st.catalog then return st.catalog, st.order end
  local text = love.filesystem.read(CATALOG)
  if not text then return {}, {}, love.filesystem.getInfo(CATALOG .. ".fail") and "offline" or "loading" end
  st.catalog, st.order = C.parseCatalog(text)
  return st.catalog, st.order
end

---------------------------------------------------------------- installed cores
local function readManifest(id)
  local text = love.filesystem.read(DIR .. id .. "/aeoncore.txt")
  if not text then return nil end
  local m = parseKV(text)
  if m.id ~= id or not m.lib then return nil end
  m.systems = split(m.systems, ",")
  m.path = love.filesystem.getSaveDirectory() .. "/" .. DIR .. id .. "/" .. m.lib
  return m
end

-- id -> manifest, for every core unpacked in cores/
function C.installed()
  if st.installed then return st.installed end
  local out = {}
  for _, name in ipairs(love.filesystem.getDirectoryItems(DIR)) do
    local info = love.filesystem.getInfo(DIR .. name)
    if info and info.type == "directory" then
      local m = readManifest(name)
      if m then out[name] = m end
    end
  end
  st.installed = out
  return out
end

-- the installed core that plays a system ("nes"), or nil
function C.forSystem(sys)
  for _, m in pairs(C.installed()) do
    for _, s in ipairs(m.systems) do if s == sys then return m end end
  end
  return nil
end

-- every file extension an installed core plays -> its system
function C.extensions()
  local out = {}
  for _, m in pairs(C.installed()) do
    local exts = split(m.extensions, "|")
    for _, e in ipairs(exts) do
      local ext = e:lower()
      -- a core serving several systems names each extension's system (nes:fds)
      local sys = m["ext_" .. ext] or m.systems[1]
      out[ext] = sys
    end
  end
  return out
end

-- unpack a downloaded .aeoncore (already checked) into cores/<id>/
local function unpack(id, file)
  local mount = "aeoncore_" .. id
  if not love.filesystem.mount(file, mount) then return false, "not a .aeoncore" end
  local ok, why = pcall(function()
    local m = parseKV(love.filesystem.read(mount .. "/aeoncore.txt"))
    assert(m.id == id, "the core inside is " .. tostring(m.id))
    assert(m.lib and not m.lib:find("%.%."), "no library in it")
    local function copy(from, to)
      for _, name in ipairs(love.filesystem.getDirectoryItems(from)) do
        local src, dst = from .. "/" .. name, to .. "/" .. name
        if love.filesystem.getInfo(src, "directory") then
          love.filesystem.createDirectory(dst)
          copy(src, dst)
        else
          assert(love.filesystem.write(dst, love.filesystem.read(src)), "could not write " .. dst)
        end
      end
    end
    local dest = DIR .. id
    love.filesystem.createDirectory(dest)
    copy(mount, dest)
  end)
  love.filesystem.unmount(file)
  return ok, why
end

-- start installing a core from the catalogue; C.state(id) follows it
function C.install(id)
  local cat = C.catalog()
  local c = cat[id]
  if not c then return false, "not in the catalogue" end
  local file = DIR .. c.file
  love.filesystem.remove(file)
  fetch(C.REPO .. c.file, file)
  st.jobs[id] = { file = file, entry = c, phase = "downloading" }
  return true
end

-- a core's state: "installed" | "downloading" | "failed" (with why) | "available"
function C.state(id)
  local job = st.jobs[id]
  if job and job.phase == "downloading" then
    if love.filesystem.getInfo(job.file .. ".fail") then
      job.phase, job.why = "failed", "the download failed"
    elseif love.filesystem.getInfo(job.file) then
      local data = love.filesystem.read(job.file)
      if job.entry.sha256 ~= "" and C.sha256(data or "") ~= job.entry.sha256 then
        job.phase, job.why = "failed", "the download was damaged"
      else
        local ok, why = unpack(job.entry.id, job.file)
        job.phase, job.why = ok and "done" or "failed", why
        st.installed = nil
      end
      love.filesystem.remove(job.file)
    end
  end
  if job and job.phase == "failed" then return "failed", job.why end
  if C.installed()[id] then
    local cat = C.catalog()
    if cat[id] and cat[id].version ~= C.installed()[id].version then return "update" end
    return "installed"
  end
  if job and job.phase == "downloading" then return "downloading" end
  return "available"
end

-- remove an installed core
function C.remove(id)
  local function rm(p)
    for _, name in ipairs(love.filesystem.getDirectoryItems(p)) do
      local q = p .. "/" .. name
      if love.filesystem.getInfo(q, "directory") then rm(q) end
      love.filesystem.remove(q)
    end
  end
  rm(DIR .. id)
  love.filesystem.remove(DIR .. id)
  st.installed, st.jobs[id] = nil, nil
end

return C
