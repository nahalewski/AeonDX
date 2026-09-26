-- AeonDX unified directory architecture for all emulators (3DS, DS, VC, Switch).
--
-- Root folder: AeonDX
--
-- Architecture:
--   AeonDX/
--     azahar/                         -- 3DS Emulator
--       data/                         -- Generated data: config, saves, states, sdmc, nand, sysdata, dumps
--         config/
--         saves/
--         states/
--         sdmc/
--         nand/
--         sysdata/
--         dumps/
--       roms/3ds/                     -- ROMs for Nintendo 3DS (.3ds, .cia, .cxi, .cci)
--       ROM/3ds/                      -- Uppercase alias
--
--     melonds/                        -- DS Emulator
--       data/                         -- Generated data: config, saves, states, bios, dsiware
--         config/
--         saves/
--         states/
--         bios/
--         dsiware/
--       roms/ds/                      -- ROMs for Nintendo DS (.nds, .dsi)
--       ROM/ds/                       -- Uppercase alias
--
--     vc/                             -- Virtual Console (Game Boy / Color / Advance)
--       data/                         -- Generated data: config, saves, states, bios
--         config/
--         saves/
--         states/
--         bios/
--       roms/                         -- ROMs with separate console folders
--         gb/                         -- Game Boy (.gb)
--         gbc/                        -- Game Boy Color (.gbc)
--         gba/                        -- Game Boy Advance (.gba)
--       ROM/                          -- Uppercase alias
--         gb/, gbc/, gba/
--
--     eden/                           -- Switch Emulator
--       data/                         -- Generated data: config, saves, nand, keys, load, screenshots
--         config/
--         saves/
--         nand/
--         keys/
--         load/
--         screenshots/
--       roms/switch/                  -- ROMs for Nintendo Switch (.nsp, .xci, .nsz)
--       ROM/switch/                   -- Uppercase alias
--
-- Also checks shared AeonDX/roms/<console>/ and legacy AeonDX/games/ so no ROMs are missed.

local M = {}

M.NAME = "AeonDX"
local ROOT_NAME = "AeonDX"

-- Emulator definitions: id -> { name, consoles = { ... }, dataDirs = { ... } }
M.EMULATORS = {
  azahar = {
    name = "Azahar",
    emuId = "azahar",
    system = "Nintendo 3DS",
    consoles = { "3ds" },
    dataDirs = { "config", "saves", "states", "sdmc", "nand", "sysdata", "dumps" },
    exts = { ["3ds"] = "3ds", ["cia"] = "3ds", ["cxi"] = "3ds", ["cci"] = "3ds" }
  },
  melonds = {
    name = "melonDS",
    emuId = "melonds",
    system = "Nintendo DS",
    consoles = { "ds" },
    dataDirs = { "config", "saves", "states", "bios", "dsiware" },
    exts = { ["nds"] = "ds", ["dsi"] = "ds" }
  },
  vc = {
    name = "Virtual Console",
    emuId = "vc",
    system = "Virtual Console",
    -- gb / gbc / gba built in; the rest on downloaded cores (fold3ds/cores.lua)
    consoles = { "gb", "gbc", "gba", "nes", "snes", "vb", "pokemini", "gw" },
    dataDirs = { "config", "saves", "states", "bios" },
    exts = { ["gb"] = "gb", ["gbc"] = "gbc", ["cgb"] = "gbc", ["gba"] = "gba", ["agb"] = "gba",
      ["nes"] = "nes", ["fds"] = "nes", ["unf"] = "nes", ["unif"] = "nes",
      ["sfc"] = "snes", ["smc"] = "snes", ["fig"] = "snes", ["swc"] = "snes", ["bs"] = "snes",
      ["vb"] = "vb", ["vboy"] = "vb", ["min"] = "pokemini", ["mgw"] = "gw" }
  },
  eden = {
    name = "Eden",
    emuId = "eden",
    system = "Nintendo Switch",
    consoles = { "switch" },
    dataDirs = { "config", "saves", "nand", "keys", "load", "screenshots" },
    exts = { ["nsp"] = "switch", ["xci"] = "switch", ["nsz"] = "switch", ["xcz"] = "switch" }
  }
}

-- Console to emulator mapping
M.CONSOLE_EMU = {
  ["3ds"] = "azahar",
  ["ds"] = "melonds",
  ["nds"] = "melonds",
  ["gb"] = "vc",
  ["gbc"] = "vc",
  ["gba"] = "vc",
  ["nes"] = "vc",
  ["snes"] = "vc",
  ["vb"] = "vc",
  ["pokemini"] = "vc",
  ["gw"] = "vc",
  ["switch"] = "eden",
  ["nx"] = "eden"
}

local currentRoot = nil

local function android()
  return love and love.system and love.system.getOS and love.system.getOS() == "Android"
end

local function bridge(cmd, arg)
  local f = love and love.system and love.system.foldCamera
  if not f then return nil end
  local ok, r = pcall(f, "call", cmd, arg or "")
  return ok and r or nil
end

local function normalizePath(p)
  if not p or p == "" then return "" end
  local clean = p:gsub("\\", "/"):gsub("/+", "/")
  if clean:sub(-1) == "/" and #clean > 1 then
    clean = clean:sub(1, -2)
  end
  return clean
end

local function ensureDir(p)
  if not p or p == "" then return false end
  -- Try love.filesystem first if available and relative
  if love and love.filesystem and love.filesystem.createDirectory then
    pcall(love.filesystem.createDirectory, p)
  end
  -- Try C ec_mkdirs if FFI / emucore available
  local ok, ffi = pcall(require, "ffi")
  if ok and ffi then
    local okCore, emucore = pcall(require, "fold3ds.emucore")
    -- Or native mkdir via os.execute or Windows mkdir
    if os.getenv and os.getenv("OS") and os.getenv("OS"):match("Windows") then
      local winPath = p:gsub("/", "\\")
      pcall(os.execute, 'mkdir "' .. winPath .. '" >nul 2>nul')
    else
      pcall(os.execute, 'mkdir -p "' .. p .. '" 2>/dev/null')
    end
  end
  return true
end

-- Resolve root directory
function M.pickRoot(customDir)
  if customDir and customDir ~= "" then
    local clean = normalizePath(customDir)
    if clean:match("[^/]+$"):lower() == ROOT_NAME:lower() then
      currentRoot = clean
    else
      currentRoot = clean .. "/" .. ROOT_NAME
    end
  elseif currentRoot then
    return currentRoot
  else
    local shared = android() and bridge("files.ok") == "1" and bridge("external")
    if shared and shared ~= "" and not shared:match("^error") then
      currentRoot = normalizePath(shared) .. "/" .. ROOT_NAME
    elseif love and love.filesystem and love.filesystem.getSaveDirectory then
      currentRoot = normalizePath(love.filesystem.getSaveDirectory()) .. "/" .. ROOT_NAME
    else
      currentRoot = ROOT_NAME
    end
  end

  M.ensureAllDirectories(currentRoot)
  return currentRoot
end

function M.getRoot()
  if not currentRoot then return M.pickRoot() end
  return currentRoot
end

function M.setRoot(dir)
  return M.pickRoot(dir)
end

-- Create the full AeonDX folder hierarchy for all emulators
function M.ensureAllDirectories(root)
  local r = root or M.getRoot()
  ensureDir(r)

  for emuId, spec in pairs(M.EMULATORS) do
    local emuBase = r .. "/" .. emuId
    ensureDir(emuBase)

    -- Data directory and subdirectories
    local dataDir = emuBase .. "/data"
    ensureDir(dataDir)
    for _, sub in ipairs(spec.dataDirs) do
      ensureDir(dataDir .. "/" .. sub)
      -- Also alias at emuBase/<subDir> for convenience
      ensureDir(emuBase .. "/" .. sub)
    end

    -- ROMs directories per console
    for _, console in ipairs(spec.consoles) do
      ensureDir(emuBase .. "/roms/" .. console)
      ensureDir(emuBase .. "/ROM/" .. console)
      -- Shared root roms/<console>
      ensureDir(r .. "/roms/" .. console)
      ensureDir(r .. "/ROM/" .. console)
    end
  end

  -- Legacy games folder
  ensureDir(r .. "/games")
  return true
end

-- Data directory for an emulator
function M.getDataDir(emuId)
  local r = M.getRoot()
  local id = emuId or "melonds"
  return r .. "/" .. id .. "/data"
end

-- Save file path for a game
function M.getSavePath(sys, gameBase)
  local emuId = M.CONSOLE_EMU[sys] or "vc"
  local r = M.getRoot()
  local primary = r .. "/" .. emuId .. "/data/saves/" .. gameBase .. ".sav"
  
  -- Check if already exists in primary, fallback, or legacy location
  local fallbacks = {
    primary,
    r .. "/" .. emuId .. "/saves/" .. gameBase .. ".sav",
    r .. "/saves/" .. gameBase .. ".sav"
  }
  for _, p in ipairs(fallbacks) do
    local f = io.open(p, "rb")
    if f then f:close(); return p end
  end
  return primary
end

-- Save state file path for a game
function M.getStatePath(sys, gameBase)
  local emuId = M.CONSOLE_EMU[sys] or "vc"
  local r = M.getRoot()
  local primary = r .. "/" .. emuId .. "/data/states/" .. gameBase .. ".state"
  
  local fallbacks = {
    primary,
    r .. "/" .. emuId .. "/states/" .. gameBase .. ".state",
    r .. "/states/" .. gameBase .. ".state"
  }
  for _, p in ipairs(fallbacks) do
    local f = io.open(p, "rb")
    if f then f:close(); return p end
  end
  return primary
end

-- Bios directory for an emulator
function M.getBiosDir(sys)
  local emuId = M.CONSOLE_EMU[sys] or "vc"
  local r = M.getRoot()
  return r .. "/" .. emuId .. "/data/bios"
end

-- Primary ROM directory to place new ROMs for a console
function M.getRomDir(sys)
  local emuId = M.CONSOLE_EMU[sys] or "vc"
  local r = M.getRoot()
  return r .. "/" .. emuId .. "/roms/" .. sys
end

-- All ROM search paths for a console
function M.getConsoleRomDirs(sys)
  local emuId = M.CONSOLE_EMU[sys] or "vc"
  local r = M.getRoot()
  local dirs = {
    r .. "/" .. emuId .. "/roms/" .. sys,
    r .. "/" .. emuId .. "/ROM/" .. sys,
    r .. "/roms/" .. sys,
    r .. "/ROM/" .. sys,
  }
  if sys == "ds" then
    dirs[#dirs + 1] = r .. "/" .. emuId .. "/roms/nds"
    dirs[#dirs + 1] = r .. "/" .. emuId .. "/ROM/nds"
    dirs[#dirs + 1] = r .. "/roms/nds"
  end
  dirs[#dirs + 1] = r .. "/games"
  return dirs
end

-- All directories to scan across all emulators
function M.getAllScanDirs()
  local r = M.getRoot()
  local seen = {}
  local out = {}
  
  local function add(d)
    if d and not seen[d] then
      seen[d] = true
      out[#out + 1] = d
    end
  end

  for emuId, spec in pairs(M.EMULATORS) do
    local emuBase = r .. "/" .. emuId
    for _, console in ipairs(spec.consoles) do
      add(emuBase .. "/roms/" .. console)
      add(emuBase .. "/ROM/" .. console)
      add(r .. "/roms/" .. console)
      add(r .. "/ROM/" .. console)
    end
    add(emuBase .. "/games")
  end
  add(r .. "/games")
  return out
end

return M
