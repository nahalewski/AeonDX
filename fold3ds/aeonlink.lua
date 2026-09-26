-- AeonDX Link: a byte stream to an ESP32-S3 board over USB-OTG or Bluetooth
-- LE (android/FoldLink.java; the board's side is
-- tools/nintendo_link/esp32_s3_ble_link).  The same bytes either way, so a
-- serial protocol (GB-Link-Switch-LDN's) runs over whichever is there.
--
--   L.scan()            look for boards over BLE (15 s)
--   L.found()           { { addr, name, rssi } ... }
--   L.usbDevices()      { { id = "vid:pid", name } ... }
--   L.open("usb") / L.open("ble", addr) -> true | nil, why
--   L.state()           "closed" | "opening" | "usb" | "ble" | "error:..."
--   L.write(bytes)      -> how many went
--   L.read()            -> the bytes that arrived since the last read
--   L.close()
local L = {}

local function bridge(cmd, arg)
  local f = love.system and love.system.foldCamera
  if not f then return nil end
  local ok, r = pcall(f, "call", cmd, arg or "")
  return ok and r or nil
end

local function tohex(s) return (s:gsub(".", function(c) return ("%02x"):format(c:byte()) end)) end
local function fromhex(h) return ((h or ""):gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end)) end
L.tohex, L.fromhex = tohex, fromhex

local function lines(text, fields)
  local out = {}
  for line in (text or ""):gmatch("[^\n]+") do
    local f = {}
    for part in (line .. "|"):gmatch("([^|]*)|") do f[#f + 1] = part end
    out[#out + 1] = fields(f)
  end
  return out
end

function L.scan() return bridge("link.scan") == "ok" end

function L.found()
  return lines(bridge("link.found"), function(f) return { addr = f[1], name = f[2], rssi = tonumber(f[3]) } end)
end

function L.usbDevices()
  return lines(bridge("link.usb"), function(f) return { id = f[1], name = f[2] } end)
end

function L.open(kind, addr)
  local r = bridge("link.open", kind == "ble" and ("ble|" .. tostring(addr)) or "usb")
  if r == "ok" then return true end
  return nil, r and r:gsub("^error:", "") or "no bridge"
end

function L.state() return bridge("link.state") or "closed" end
function L.write(bytes) return tonumber(bridge("link.write", tohex(bytes or ""))) or 0 end
function L.read() return fromhex(bridge("link.read")) end
function L.close() bridge("link.close") end

return L
