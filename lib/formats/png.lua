-- PNG decoder (all colour types, bit depths 1-16, Adam7 interlacing).
-- png.info(data) -> width, height | nil, err
-- png.decode(data, onRow, yield)  calls onRow(y, r, g, b, a) for each image
--   row (0-based y; r/g/b/a are 1-based arrays of 0..255).
local inflate = require("lib.formats.inflate")

local M = {}
local byte, floor = string.byte, math.floor

local function u32(s, i)
  local a, b, c, d = byte(s, i, i + 3)
  return ((a * 256 + b) * 256 + c) * 256 + d
end

local SIG = "\137PNG\r\n\26\n"

local function chunks(data)
  if data:sub(1, 8) ~= SIG then return nil, "not a PNG" end
  local pos, list = 9, {}
  while pos + 8 <= #data do
    local len = u32(data, pos)
    local typ = data:sub(pos + 4, pos + 7)
    list[#list + 1] = { typ, pos + 8, len }
    pos = pos + 12 + len
    if typ == "IEND" then break end
  end
  return list
end

function M.info(data)
  local list, err = chunks(data)
  if not list then return nil, err end
  local c = list[1]
  if not c or c[1] ~= "IHDR" then return nil, "PNG: missing IHDR" end
  -- colour type 3 = palette image: most likely pixel art / a logo
  return u32(data, c[2]), u32(data, c[2] + 4), { indexed = data:byte(c[2] + 9) == 3 }
end

local CHANNELS = { [0] = 1, [2] = 3, [3] = 1, [4] = 2, [6] = 4 }
-- Adam7: x0, y0, dx, dy
local ADAM7 = { {0,0,8,8}, {4,0,8,8}, {0,4,4,8}, {2,0,4,4}, {0,2,2,4}, {1,0,2,2}, {0,1,1,2} }

function M.decode(data, onRow, yield)
  local list, err = chunks(data)
  if not list then error(err) end
  local ih = list[1][2]
  local W, H = u32(data, ih), u32(data, ih + 4)
  local depth, ctype = byte(data, ih + 8), byte(data, ih + 9)
  local interlace = byte(data, ih + 12)
  local chans = CHANNELS[ctype]
  if not chans then error("PNG: bad colour type " .. tostring(ctype)) end

  local pal, palA, trns = {}, {}, nil
  local idat = {}
  for _, c in ipairs(list) do
    local typ, p, len = c[1], c[2], c[3]
    if typ == "PLTE" then
      for i = 0, len / 3 - 1 do
        local r, g, b = byte(data, p + i * 3, p + i * 3 + 2)
        pal[i] = { r, g, b }
      end
    elseif typ == "tRNS" then
      if ctype == 3 then
        for i = 0, len - 1 do palA[i] = byte(data, p + i) end
      elseif ctype == 0 then
        trns = { u32("\0\0" .. data:sub(p, p + 1), 1) }
      elseif ctype == 2 then
        trns = { u32("\0\0" .. data:sub(p, p + 1), 1), u32("\0\0" .. data:sub(p + 2, p + 3), 1),
                 u32("\0\0" .. data:sub(p + 4, p + 5), 1) }
      end
    elseif typ == "IDAT" then
      idat[#idat + 1] = data:sub(p, p + len - 1)
    end
  end
  idat = table.concat(idat)

  local bitsPP = depth * chans
  local bpp = math.max(1, floor(bitsPP / 8)) -- filter byte distance
  local maxv = 2 ^ depth - 1
  local scale = depth < 8 and 255 / maxv or 1

  -- Pass layout
  local passes = {}
  if interlace == 1 then
    for _, a in ipairs(ADAM7) do
      local pw = floor((W - a[1] + a[3] - 1) / a[3])
      local ph = floor((H - a[2] + a[4] - 1) / a[4])
      if pw > 0 and ph > 0 then passes[#passes + 1] = { a[1], a[2], a[3], a[4], pw, ph } end
    end
  else
    passes[1] = { 0, 0, 1, 1, W, H }
  end

  -- For interlaced images every pixel is buffered and emitted at the end.
  local full = interlace == 1 and {} or nil

  local R, G, B, A = {}, {}, {}, {}
  local function emitLine(line, pass, py)
    -- line[1..rowbytes] unfiltered bytes. Convert samples to RGBA.
    local pw = pass[5]
    local samples = {}
    if depth == 8 then
      samples = line
    elseif depth == 16 then
      for i = 1, pw * chans do samples[i] = line[i * 2 - 1] * 256 + line[i * 2] end
    else
      local per = 8 / depth
      local div = 2 ^ depth
      local k = 0
      for i = 1, #line do
        local v = line[i]
        for j = per - 1, 0, -1 do
          k = k + 1
          samples[k] = floor(v / 2 ^ (j * depth)) % div
        end
      end
    end
    local sh = depth == 16 and 1 / 257 or scale
    for x = 1, pw do
      local r, g, b, a
      local o = (x - 1) * chans
      if ctype == 3 then
        local idx = samples[x]
        local c = pal[idx] or { 0, 0, 0 }
        r, g, b, a = c[1], c[2], c[3], palA[idx] or 255
      elseif ctype == 0 then
        local v = samples[x]
        a = (trns and v == trns[1]) and 0 or 255
        v = floor(v * sh + 0.5); r, g, b = v, v, v
      elseif ctype == 4 then
        local v = floor(samples[o + 1] * sh + 0.5)
        r, g, b, a = v, v, v, floor(samples[o + 2] * sh + 0.5)
      elseif ctype == 2 then
        local sr, sg, sb = samples[o + 1], samples[o + 2], samples[o + 3]
        a = (trns and sr == trns[1] and sg == trns[2] and sb == trns[3]) and 0 or 255
        r, g, b = floor(sr * sh + 0.5), floor(sg * sh + 0.5), floor(sb * sh + 0.5)
      else
        r, g, b, a = floor(samples[o + 1] * sh + 0.5), floor(samples[o + 2] * sh + 0.5),
                     floor(samples[o + 3] * sh + 0.5), floor(samples[o + 4] * sh + 0.5)
      end
      if full then
        local fx, fy = pass[1] + (x - 1) * pass[3], pass[2] + py * pass[4]
        full[fy * W + fx + 1] = ((a * 256 + r) * 256 + g) * 256 + b
      else
        R[x], G[x], B[x], A[x] = r, g, b, a
      end
    end
    if not full then onRow(py, R, G, B, A) end
  end

  -- Streaming unfilter state
  local pi = 1
  local pass = passes[pi]
  local rowbytes = pass and floor((pass[5] * bitsPP + 7) / 8)
  local prev, cur = {}, {}
  for i = 1, rowbytes or 0 do prev[i] = 0 end
  local ftype, col, py = nil, 0, 0

  local function sink(buf, n)
    for i = 1, n do
      if not pass then return end
      local v = buf[i]
      if ftype == nil then
        ftype = v; col = 0
      else
        col = col + 1
        local a = col > bpp and cur[col - bpp] or 0
        if ftype == 0 then
        elseif ftype == 1 then v = (v + a) % 256
        elseif ftype == 2 then v = (v + prev[col]) % 256
        elseif ftype == 3 then v = (v + floor((a + prev[col]) / 2)) % 256
        elseif ftype == 4 then
          local b = prev[col]
          local c = col > bpp and prev[col - bpp] or 0
          local p = a + b - c
          local pa, pb, pc = math.abs(p - a), math.abs(p - b), math.abs(p - c)
          if pa <= pb and pa <= pc then v = (v + a) % 256
          elseif pb <= pc then v = (v + b) % 256
          else v = (v + c) % 256 end
        else
          error("PNG: bad filter type " .. ftype)
        end
        cur[col] = v
        if col == rowbytes then
          emitLine(cur, pass, py)
          prev, cur = cur, prev
          ftype = nil
          py = py + 1
          if py >= pass[6] then
            pi = pi + 1; pass = passes[pi]; py = 0
            if pass then
              rowbytes = floor((pass[5] * bitsPP + 7) / 8)
              prev, cur = {}, {}
              for j = 1, rowbytes do prev[j] = 0 end
            end
          end
        end
      end
    end
  end
  inflate.zlib(idat, sink, yield)

  if full then
    for y = 0, H - 1 do
      for x = 1, W do
        local v = full[y * W + x] or 0
        B[x] = v % 256; v = floor(v / 256)
        G[x] = v % 256; v = floor(v / 256)
        R[x] = v % 256; A[x] = floor(v / 256)
      end
      onRow(y, R, G, B, A)
      if yield and y % 32 == 0 then yield() end
    end
  end
  return W, H
end

return M
