-- BMP decoder: 1/4/8/16/24/32 bpp, BI_RGB and BI_BITFIELDS, top-down or
-- bottom-up. (RLE-compressed BMPs are not supported.)
local M = {}
local byte, floor = string.byte, math.floor

local function u16(s, i) local a, b = byte(s, i, i + 1); return a + b * 256 end
local function u32(s, i) local a, b, c, d = byte(s, i, i + 3); return a + b * 256 + c * 65536 + d * 16777216 end
local function s32(s, i) local v = u32(s, i); if v >= 2 ^ 31 then v = v - 2 ^ 32 end; return v end

local function header(data)
  if data:sub(1, 2) ~= "BM" then return nil, "not a BMP" end
  local h = { offset = u32(data, 11), hsize = u32(data, 15) }
  if h.hsize == 12 then
    h.w, h.h, h.bpp, h.comp = u16(data, 19), u16(data, 21), u16(data, 25), 0
  else
    h.w, h.h, h.bpp, h.comp = s32(data, 19), s32(data, 23), u16(data, 29), u32(data, 31)
    h.ncolors = u32(data, 47)
  end
  h.topdown = h.h < 0
  h.h = math.abs(h.h)
  return h
end

function M.info(data)
  local h, err = header(data)
  if not h then return nil, err end
  return h.w, h.h
end

local function maskInfo(m)
  if m == 0 then return 1, 0 end
  local shift = 0
  while m % 2 == 0 do m = m / 2; shift = shift + 1 end
  return 2 ^ shift, m -- divisor, max value
end

function M.decode(data, onRow, yield)
  local h, err = header(data)
  if not h then error(err) end
  local W, H, bpp = h.w, h.h, h.bpp
  if h.comp ~= 0 and h.comp ~= 3 and h.comp ~= 6 then
    error("BMP: compressed BMPs (RLE) are not supported")
  end
  -- palette
  local pal = {}
  if bpp <= 8 then
    local entry = h.hsize == 12 and 3 or 4
    local n = (h.ncolors and h.ncolors > 0) and h.ncolors or 2 ^ bpp
    local p = 15 + h.hsize
    for i = 0, n - 1 do
      local b, g, r = byte(data, p + i * entry, p + i * entry + 2)
      pal[i] = { r or 0, g or 0, b or 0 }
    end
  end
  -- channel masks for 16/32 bpp
  local masks
  if bpp == 16 or bpp == 32 then
    local rm, gm, bm, am
    if h.comp == 3 or h.comp == 6 then
      local mp = h.hsize >= 52 and 55 or 15 + h.hsize -- masks inside header (v2+) or after it
      rm, gm, bm = u32(data, mp), u32(data, mp + 4), u32(data, mp + 8)
      am = (h.hsize >= 56) and u32(data, mp + 12) or 0
    elseif bpp == 16 then
      rm, gm, bm, am = 0x7C00, 0x03E0, 0x001F, 0
    else
      rm, gm, bm, am = 0xFF0000, 0xFF00, 0xFF, 0
    end
    masks = {}
    for i, m in ipairs({ rm, gm, bm, am }) do
      local div, max = maskInfo(m)
      masks[i] = { m, div, max }
    end
  end
  local function chan(v, mk)
    if mk[1] == 0 then return nil end
    -- (v & mask) >> shift without bit ops: v is < 2^32
    local x = floor(v / mk[2]) % (mk[3] + 1)
    return floor(x * 255 / mk[3] + 0.5)
  end

  local stride = floor((W * bpp + 31) / 32) * 4
  local R, G, B, A = {}, {}, {}, {}
  for row = 0, H - 1 do
    local y = h.topdown and row or (H - 1 - row)
    local p = h.offset + row * stride + 1
    for x = 1, W do
      local r, g, b, a = 0, 0, 0, 255
      if bpp == 24 then
        local q = p + (x - 1) * 3
        b, g, r = byte(data, q, q + 2)
      elseif bpp == 32 or bpp == 16 then
        local v
        if bpp == 32 then v = u32(data, p + (x - 1) * 4) else v = u16(data, p + (x - 1) * 2) end
        r, g, b = chan(v, masks[1]), chan(v, masks[2]), chan(v, masks[3])
        a = chan(v, masks[4]) or 255
      else
        local bit = (x - 1) * bpp
        local v = byte(data, p + floor(bit / 8)) or 0
        local idx = floor(v / 2 ^ (8 - bpp - bit % 8)) % 2 ^ bpp
        local c = pal[idx] or { 0, 0, 0 }
        r, g, b = c[1], c[2], c[3]
      end
      R[x], G[x], B[x], A[x] = r or 0, g or 0, b or 0, a
    end
    onRow(y, R, G, B, A)
    if yield and row % 16 == 0 then yield() end
  end
  return W, H
end

return M
