-- Setup page for the ESP32-backed Nintendo Switch LDN trade path.
-- The USB/RFU host bridge is not implemented in AeonDX yet, so this page
-- explains the supported workflow without offering a nonfunctional connect.
local NL = {}

local lg = love.graphics
local ctx = { font = function(s) return lg.newFont(math.max(6, math.floor(s))) end }
local st = { open = false, page = 1, hits = {}, touches = {} }

local function supportedTitle(t)
  local name = ((t and (t.nointro or t.name)) or ""):lower():gsub("[^%w]", "")
  if name:find("pokemonfireredversion", 1, true)
    or name:find("pokemonleafgreenversion", 1, true)
    or name:find("pokemonemeraldversion", 1, true) then
    return true
  end

  local code = ((t and t.code) or ""):upper()
  return code:match("^BPR") ~= nil or code:match("^BPG") ~= nil or code:match("^BPE") ~= nil
end

function NL.supported(p, t)
  return p and p.id == "vc" and t and t.sys == "gba" and supportedTitle(t)
end

function NL.open(t)
  st.open, st.page = true, 1
  st.title = t and t.name or "Game Boy Advance"
end

function NL.close()
  st.open, st.title = false, nil
end

function NL.isOpen()
  return st.open
end

local function hit(id, x, y, w, h)
  st.hits[#st.hits + 1] = { id = id, x = x, y = y, w = w, h = h }
end

local function button(id, label, x, y, w, h, primary)
  if primary then lg.setColor(0.16, 0.48, 0.82, 1) else lg.setColor(1, 1, 1, 1) end
  lg.rectangle("fill", x, y, w, h, h * 0.2, h * 0.2)
  lg.setColor(0.16, 0.48, 0.82, 1)
  lg.rectangle("line", x, y, w, h, h * 0.2, h * 0.2)
  local f = ctx.font(h * 0.38)
  lg.setFont(f)
  if primary then lg.setColor(1, 1, 1, 1) else lg.setColor(0.2, 0.22, 0.28, 1) end
  lg.printf(label, x + 3, y + (h - f:getHeight()) / 2, w - 6, "center")
  hit(id, x, y, w, h)
end

local function paragraph(text, x, y, w, size, color)
  local f = ctx.font(size)
  lg.setFont(f)
  lg.setColor(color[1], color[2], color[3], 1)
  local _, lines = f:getWrap(text, w)
  lg.printf(text, x, y, w, "left")
  return y + #lines * f:getHeight()
end

function NL.draw(r)
  if not st.open then return end
  st.hits = {}
  lg.push("all")
  lg.setScissor(r.x, r.y, r.w, r.h)
  lg.setColor(0.95, 0.96, 0.98, 1)
  lg.rectangle("fill", r.x, r.y, r.w, r.h)

  local pad = math.max(6, r.w * 0.035)
  local barH = r.h * 0.14
  lg.setColor(0.86, 0.89, 0.94, 1)
  lg.rectangle("fill", r.x, r.y, r.w, barH)
  button("back", "Back", r.x + pad, r.y + barH * 0.16, r.w * 0.19, barH * 0.68, true)

  local titleFont = ctx.font(barH * 0.34)
  lg.setFont(titleFont)
  lg.setColor(0.12, 0.16, 0.23, 1)
  lg.printf("Nintendo Link", r.x + r.w * 0.22, r.y + (barH - titleFont:getHeight()) / 2,
    r.w * 0.75, "center")

  local cardX, cardW = r.x + pad, r.w - pad * 2
  local contentY = r.y + barH + pad
  local statusH = r.h * 0.17
  lg.setColor(1, 0.91, 0.75, 1)
  lg.rectangle("fill", cardX, contentY, cardW, statusH, 6, 6)
  local statusFont = ctx.font(statusH * 0.24)
  lg.setFont(statusFont)
  lg.setColor(0.68, 0.34, 0.06, 1)
  lg.printf("SETUP GUIDE  |  NOT CONNECTED", cardX + pad, contentY + statusH * 0.1,
    cardW - pad * 2, "left")
  paragraph("AeonDX cannot yet send GBA wireless-adapter frames to the ESP32. This page is instructions only; it cannot start a trade yet.",
    cardX + pad, contentY + statusH * 0.42, cardW - pad * 2, statusH * 0.16, { 0.35, 0.23, 0.1 })

  local bodyY = contentY + statusH + pad
  local bodyH = r.y + r.h - bodyY - r.h * 0.14 - pad
  lg.setColor(1, 1, 1, 1)
  lg.rectangle("fill", cardX, bodyY, cardW, bodyH, 6, 6)
  local headingText = st.page == 1 and "Supported games and setup"
    or st.page == 2 and "Transport and storage" or "Keys and current status"
  local heading = ctx.font(bodyH * 0.105)
  lg.setFont(heading)
  lg.setColor(0.15, 0.19, 0.27, 1)
  lg.printf(headingText, cardX + pad, bodyY + pad * 0.7, cardW - pad * 2, "left")

  local text
  if st.page == 1 then
    text = "Switch: Pokemon FireRed or LeafGreen, hosting a Trade Center room.\n\n"
      .. "AeonDX: GBA FireRed, LeafGreen or Emerald.\n\n"
      .. "The ESP32-S3 joins the Switch over local wireless. Scarlet / Union Circle is not supported by this bridge."
  elseif st.page == 2 then
    text = "USB-OTG is the current GB-Link transport. BLE is possible, but needs a new GATT transport in the ESP32 firmware and Android app; Wi-Fi and BLE share the radio, so coexistence needs testing.\n\n"
      .. "The board microSD could store party PK3 files and artwork. The bridge does not use it yet, and its default adapter UART uses GPIO1/2, which overlap the SD bus; those pins must be remapped."
  else
    text = "Keys: your own Switch prod.keys are required by the LDN host. Keep them private; never send them in chat. The upstream bridge stores the needed LDN keys in NVS, not on the SD card.\n\n"
      .. "AeonDX still needs Android USB/BLE transport, a SkyEmu GBA RFU endpoint, and the LDN trade-session host before this page can start a trade."
  end
  paragraph(text, cardX + pad, bodyY + pad * 2 + heading:getHeight(), cardW - pad * 2,
    bodyH * 0.075, { 0.2, 0.23, 0.3 })

  local navY, navH = r.y + r.h - r.h * 0.12 - pad * 0.45, r.h * 0.1
  if st.page > 1 then button("prev", "Previous", cardX, navY, cardW * 0.44, navH, false) end
  if st.page < 3 then button("next", "Next", cardX + cardW * 0.56, navY, cardW * 0.44, navH, true) end
  lg.pop()
end

local function press(id)
  if id == "back" then NL.close()
  elseif id == "next" then st.page = math.min(3, st.page + 1)
  elseif id == "prev" then st.page = math.max(1, st.page - 1) end
  if ctx.sfx then ctx.sfx("select") end
end

function NL.button(btn)
  if btn == "b" or btn == "home" then NL.close()
  elseif btn == "right" or btn == "a" then st.page = math.min(3, st.page + 1)
  elseif btn == "left" then st.page = math.max(1, st.page - 1) end
end

function NL.touch(phase, id, x, y)
  if phase == "pressed" then
    local found
    for i = #st.hits, 1, -1 do
      local h = st.hits[i]
      if x >= h.x and y >= h.y and x <= h.x + h.w and y <= h.y + h.h then
        found = h.id
        break
      end
    end
    st.touches[id] = found
  elseif phase == "released" then
    local expected = st.touches[id]
    st.touches[id] = nil
    if expected then
      for i = #st.hits, 1, -1 do
        local h = st.hits[i]
        if h.id == expected and x >= h.x and y >= h.y and x <= h.x + h.w and y <= h.y + h.h then
          press(expected)
          break
        end
      end
    end
  end
end

function NL.init(context)
  for k, v in pairs(context or {}) do ctx[k] = v end
end

return NL