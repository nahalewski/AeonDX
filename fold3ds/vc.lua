-- Game Boy, Game Boy Color and Game Boy Advance games on the HOME menu as
-- the Virtual Console (SkyEmu's cores, in libemucore), and NES, Super NES,
-- Virtual Boy, Pokemon mini and Game & Watch games on cores downloaded from
-- the eShop (fold3ds/cores.lua): the provider
-- fold3ds/emus.lua picks up.  Its folder holds the Virtual Console's
-- settings pages and tools; the data side is fold3ds/emucore.lua.
local Core = require("fold3ds.emucore")
local M = {}

local N = Core.NAME
M.provider = require("fold3ds.emuprovider")({
  id = "vc",
  system = "Virtual Console",
  systems = { gb = true, gbc = true, gba = true, nes = true, snes = true, vb = true, pokemini = true, gw = true },
  folderName = "Virtual Console",
  folderSub = "Game Boy, GBC, GBA, NES, Super NES, Virtual Boy and more",
  items = {
    { id = "vc_screen", name = "Screens", sub = "Pixels and borders", url = "page?id=vc_screen" },
    { id = "vc_system", name = "Virtual Console", sub = "BIOS files, box art", url = "page?id=vc_system" },
    { id = "vc_audio", name = "Sound", sub = "Volume", url = "page?id=audio" },
    { id = "vc_controls", name = "Controls", sub = "Fast forward, the GBA's L / R", url = "page?id=controls" },
    { id = "vc_folder", name = "Games & Folders", sub = "Add games, the " .. N .. " folder", url = "page?id=folder" },
    { id = "vc_about", name = "About", sub = "The cores and where the art comes from", url = "page?id=about" },
  },
  setupTile = nil,   -- the DS folder's set-up tile covers both
  addTile = { id = "vc_add", name = "Add Virtual Console Games", sub = "Pick a game, or copy into AeonDX/vc/roms/<system>/",
    url = "act?id=add" },
})

return M
