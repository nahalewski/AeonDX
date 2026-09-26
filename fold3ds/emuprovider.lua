-- One provider for fold3ds/emus.lua over fold3ds/emucore.lua: the games of
-- some of its systems, a folder of its settings pages and tools, and what
-- the 3DS UI reads to show a running game (running, update, screen, ...).
-- fold3ds/melonds.lua (DS) and fold3ds/vc.lua (Virtual Console) are two.
local Core = require("fold3ds.emucore")

return function(spec)
  if not Core.available() then return nil end
  local p = {
    id = spec.id,
    system = spec.system,
    folder = { name = spec.folderName, sub = spec.folderSub, items = spec.items },
    setupTile = spec.setupTile,
    addTile = spec.addTile,
  }
  local function mine(t) return t and spec.systems[t.sys] end
  -- "setup" until the user folder can be on shared storage
  function p.status() return Core.sharedOk() and "ready" or "setup" end
  function p.games()
    local out = {}
    for _, t in ipairs(Core.games()) do if mine(t) then out[#out + 1] = t end end
    return out
  end
  function p.icon(t) return Core.icon(t) end
  function p.iconPath(t) return Core.iconPath(t) end
  function p.cart(t) return Core.cartPhoto(t) end
  function p.open(url) return Core.open(url) end
  function p.play(t) return Core.play(t) end
  function p.init() Core.init() end
  function p.transferEntries(t) return Core.transferEntries(t) end
  function p.poll(time) Core.poll(time); Core.takePicked() end
  -- for the UI: the running game and its screens, input, menu and pages
  function p.running() local t = Core.current() return mine(t) and t or nil end
  p.update = Core.update
  p.screen = Core.screen
  p.screenSize = Core.screenSize
  p.press = Core.press
  p.release = Core.release
  p.releaseAll = Core.releaseAll
  p.touch = Core.touch
  p.menu = Core.menu
  p.menuDo = Core.menuDo
  p.toast = Core.toast
  p.stop = Core.stop
  p.boxArt = Core.boxArt
  p.cartSkin = Core.cartSkin
  p.borderName = Core.borderName
  p.page = Core.page
  p.closePage = Core.closePage
  p.setSetting = Core.setSetting
  p.act = Core.act
  p.gbaSioEnable = Core.gbaSioEnable
  p.gbaSioRead = Core.gbaSioRead
  p.gbaSioWrite = Core.gbaSioWrite
  p.gbaSioDropped = Core.gbaSioDropped
  p.message = function() local m = Core.message; Core.message = nil; return m end
  return p
end
