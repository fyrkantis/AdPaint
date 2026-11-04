-- JPEG decoder: baseline + progressive Huffman JPEGs, any chroma
-- subsampling, greyscale/YCbCr/RGB/CMYK, restart markers, EXIF orientation.
--
-- jpeg.info(data) -> width, height, {orientation=1..8, progressive=bool}
-- jpeg.decode(data, onRow, yield, dcOnly)
--   Calls onRow(y, r, g, b, a) per output row. With dcOnly = true only the DC
--   coefficient of every 8x8 block is used, giving a 1/8 scale image
--   (ceil(w/8) x ceil(h/8)) far faster and with far less memory - ideal when
--   the result gets shrunk onto a monitor anyway.
local M = {}
local byte, floor, cos, sqrt, pi = string.byte, math.floor, math.cos, math.sqrt, math.pi

local function u16(s, i) local a, b = byte(s, i, i + 1); return a * 256 + b end

local ZZ = {
  0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
  12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
  35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
  58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
}
-- ZZ1[k] = natural 1-based index of zigzag position k (0-based)
local ZZ1 = {}
for k = 0, 63 do ZZ1[k] = ZZ[k + 1] + 1 end

local POW = {}
for i = 0, 32 do POW[i] = 2 ^ i end

-- IDCT basis: CB[u * 8 + x + 1] = c(u)/2 * cos((2x+1) u pi / 16)
local CB = {}
for u = 0, 7 do
  for x = 0, 7 do
    CB[u * 8 + x + 1] = (u == 0 and 1 / sqrt(2) or 1) / 2 * cos((2 * x + 1) * u * pi / 16)
  end
end

-- EXIF orientation from an APP1 segment
local function exifOrientation(data, p, len)
  if data:sub(p, p + 5) ~= "Exif\0\0" then return nil end
  local t = p + 6
  local le = data:sub(t, t + 1) == "II"
  local function r16(i) local a, b = byte(data, i, i + 1); if not b then return 0 end; return le and a + b * 256 or a * 256 + b end
  local function r32(i) return le and r16(i) + r16(i + 2) * 65536 or r16(i) * 65536 + r16(i + 2) end
  local ifd = t + r32(t + 4)
  local n = r16(ifd)
  for i = 0, n - 1 do
    local e = ifd + 2 + i * 12
    if e + 12 > p + len then break end
    if r16(e) == 0x0112 then return r16(e + 8) end
  end
end

local function parseHeaders(data)
  if byte(data, 1) ~= 0xFF or byte(data, 2) ~= 0xD8 then return nil, "not a JPEG" end
  local p, info = 3, { orientation = 1 }
  while p < #data do
    if byte(data, p) ~= 0xFF then p = p + 1
    else
      local m = byte(data, p + 1)
      if m == 0xFF then p = p + 1
      elseif m == 0xD8 or m == 0x01 or (m >= 0xD0 and m <= 0xD7) then p = p + 2
      elseif m == 0xD9 then break
      else
        local len = u16(data, p + 2)
        if m == 0xE1 then info.orientation = exifOrientation(data, p + 4, len - 2) or info.orientation end
        if m >= 0xC0 and m <= 0xCF and m ~= 0xC4 and m ~= 0xC8 and m ~= 0xCC then
          info.sof = m
          info.h, info.w = u16(data, p + 5), u16(data, p + 7)
          info.progressive = m == 0xC2
          return info
        end
        p = p + 2 + len
      end
    end
  end
  return nil, "JPEG: no frame header"
end

function M.info(data)
  local info, err = parseHeaders(data)
  if not info then return nil, err end
  return info.w, info.h, info
end

local function buildHuff(counts, syms)
  local t = { look = {}, maxcode = {}, mincode = {}, valptr = {}, vals = syms }
  local code, k = 0, 1
  for l = 1, 16 do
    t.valptr[l] = k; t.mincode[l] = code
    for _ = 1, counts[l] do
      if l <= 9 then
        local v = syms[k] * 16 + l
        local lo = code * POW[9 - l]
        for j = lo, lo + POW[9 - l] - 1 do t.look[j] = v end
      end
      code = code + 1; k = k + 1
    end
    t.maxcode[l] = counts[l] > 0 and code - 1 or -1
    code = code * 2
  end
  return t
end

function M.decode(data, onRow, yield, dcOnly)
  local qt, dcT, acT = {}, {}, {}
  local frame, ri, adobe = nil, 0, nil
  local p = 3
  local outW, outH, S
  local comps, byId
  local nextOut = 0
  local work = 0

  local function maybeYield()
    work = work + 1
    if work >= 512 then work = 0; if yield then yield() end end
  end

  local function newBlock()
    if dcOnly then return { 0 } end
    local b = {}
    for i = 1, 64 do b[i] = 0 end
    return b
  end

  local function getBlock(c, row, col)
    local idx = row * c.bpl + col + 1
    local b = c.blocks[idx]
    if not b then b = newBlock(); c.blocks[idx] = b end
    return b
  end

  -- Converts one MCU row of blocks into output pixel rows.
  local planes = {}
  local function outputMcuRow(my)
    if my >= frame.mcusY then return end
    for ci, c in ipairs(comps) do
      local plane = planes[ci] or {}
      planes[ci] = plane
      local q = qt[c.tq] or {}
      local pw = c.bpl * S
      for vb = 0, c.v - 1 do
        local row = my * c.v + vb
        for col = 0, c.bpl - 1 do
          local idx = row * c.bpl + col + 1
          local blk = c.blocks[idx]
          c.blocks[idx] = nil
          if dcOnly then
            local v = blk and blk[1] * (q[1] or 1) / 8 + 128 or 128
            plane[vb * pw + col + 1] = v
          elseif not blk then
            for y = 0, 7 do
              local o = (vb * 8 + y) * pw + col * 8
              for x = 1, 8 do plane[o + x] = 128 end
            end
          else
            -- dequantise + separable IDCT
            local tmp = {}
            for v = 0, 7 do
              local base = v * 8
              local f0 = blk[base + 1] * q[base + 1]
              local any = false
              for u = 2, 8 do if blk[base + u] ~= 0 then any = true; break end end
              if not any then
                local val = f0 * CB[1]
                for x = 1, 8 do tmp[base + x] = val end
              else
                local F = {}
                for u = 1, 8 do F[u] = blk[base + u] * q[base + u] end
                for x = 1, 8 do
                  local s = 0
                  for u = 0, 7 do
                    local f = F[u + 1]
                    if f ~= 0 then s = s + f * CB[u * 8 + x] end
                  end
                  tmp[base + x] = s
                end
              end
            end
            for y = 0, 7 do
              local o = (vb * 8 + y) * pw + col * 8
              for x = 1, 8 do
                local s = 0
                for v = 0, 7 do s = s + tmp[v * 8 + x] * CB[v * 8 + y + 1] end
                plane[o + x] = s + 128
              end
            end
          end
        end
        maybeYield()
      end
    end
    -- colour convert and emit
    local R, G, B, A = {}, {}, {}, {}
    local y0 = my * frame.vmax * S
    local nc = #comps
    local hmax, vmax = frame.hmax, frame.vmax
    local transform = adobe
    if transform == nil then
      -- no Adobe marker: component ids "R","G","B" mean plain RGB
      local rgbIds = nc == 3 and comps[1].id == 82 and comps[2].id == 71 and comps[3].id == 66
      transform = (nc == 3 and not rgbIds) and 1 or 0
    end
    for ly = 0, frame.vmax * S - 1 do
      local y = y0 + ly
      if y >= outH then break end
      local rows, xs = {}, {}
      for ci, c in ipairs(comps) do
        rows[ci] = floor(ly * c.v / vmax) * c.bpl * S
        xs[ci] = c.h / hmax
      end
      for x = 0, outW - 1 do
        local s1 = planes[1][rows[1] + floor(x * xs[1]) + 1]
        local r, g, b
        if nc == 1 then
          r, g, b = s1, s1, s1
        else
          local s2 = planes[2][rows[2] + floor(x * xs[2]) + 1]
          local s3 = planes[3][rows[3] + floor(x * xs[3]) + 1]
          if transform ~= 0 then
            local cb, cr = s2 - 128, s3 - 128
            r = s1 + 1.402 * cr
            g = s1 - 0.344136 * cb - 0.714136 * cr
            b = s1 + 1.772 * cb
          else
            r, g, b = s1, s2, s3
          end
          if nc == 4 then
            local k = planes[4][rows[4] + floor(x * xs[4]) + 1] / 255
            r, g, b = r * k, g * k, b * k
          end
        end
        r = floor(r + 0.5); g = floor(g + 0.5); b = floor(b + 0.5)
        R[x + 1] = r < 0 and 0 or r > 255 and 255 or r
        G[x + 1] = g < 0 and 0 or g > 255 and 255 or g
        B[x + 1] = b < 0 and 0 or b > 255 and 255 or b
        A[x + 1] = 255
      end
      onRow(y, R, G, B, A)
    end
    if yield then yield() end
  end

  local function flushRows(upto)
    while nextOut < upto do outputMcuRow(nextOut); nextOut = nextOut + 1 end
  end

  -- Skips entropy-coded data until the next non-RST marker.
  local function skipScan(q)
    while q < #data do
      if byte(data, q) == 0xFF then
        local m = byte(data, q + 1)
        if m ~= 0 and not (m >= 0xD0 and m <= 0xD7) then return q end
        q = q + 2
      else q = q + 1 end
    end
    return q
  end

  local function decodeScan(q, scomps, Ss, Se, Ah, Al)
    local acc, nbits, marker = 0, 0, false
    local function fill()
      while nbits <= 16 do
        local b = 0
        if not marker then
          b = byte(data, q)
          if not b then marker = true; b = 0
          elseif b == 0xFF then
            local b2 = byte(data, q + 1)
            if b2 == 0 then q = q + 2
            elseif b2 == 0xFF then q = q + 1; b = nil
            else marker = true; b = 0 end
          else q = q + 1 end
        end
        if b then acc = acc * 256 + b; nbits = nbits + 8 end
      end
    end
    local function bits(n)
      if nbits < n then fill() end
      nbits = nbits - n
      local p2 = POW[nbits]
      local v = floor(acc / p2)
      acc = acc - v * p2
      return v
    end
    local function ext(s)
      if s == 0 then return 0 end
      local v = bits(s)
      if v < POW[s - 1] then v = v - POW[s] + 1 end
      return v
    end
    local function huff(t)
      if nbits < 16 then fill() end
      local peek = floor(acc / POW[nbits - 16])
      local e = t.look[floor(peek / 128)]
      if e then
        local l = e % 16
        nbits = nbits - l
        acc = acc % POW[nbits]
        return (e - l) / 16
      end
      for l = 10, 16 do
        local code = floor(peek / POW[16 - l])
        if code <= t.maxcode[l] then
          nbits = nbits - l
          acc = acc % POW[nbits]
          return t.vals[t.valptr[l] + code - t.mincode[l]]
        end
      end
      error("JPEG: bad huffman code")
    end
    local function restart()
      acc, nbits = 0, 0
      if not marker then
        -- find the RST marker
        while q < #data and not (byte(data, q) == 0xFF and byte(data, q + 1) ~= 0) do q = q + 1 end
      end
      local m = byte(data, q + 1)
      if byte(data, q) == 0xFF and m and m >= 0xD0 and m <= 0xD7 then q = q + 2 end
      marker = false
      for _, c in ipairs(scomps) do c.pred = 0 end
    end

    local eobrun = 0
    local progressive = frame.progressive
    local decodeBlock
    if not progressive then
      decodeBlock = function(c, blk)
        local t = huff(c.dct)
        c.pred = c.pred + ext(t)
        blk[1] = c.pred
        local ac = c.act
        local k = 1
        while k < 64 do
          local rs = huff(ac)
          local s, r = rs % 16, floor(rs / 16)
          if s == 0 then
            if r < 15 then break end
            k = k + 16
          else
            k = k + r
            local v = ext(s)
            if not dcOnly and k < 64 then blk[ZZ1[k]] = v end
            k = k + 1
          end
        end
      end
    elseif Ss == 0 then
      if Ah == 0 then
        decodeBlock = function(c, blk)
          c.pred = c.pred + ext(huff(c.dct))
          blk[1] = c.pred * POW[Al]
        end
      else
        decodeBlock = function(c, blk)
          if bits(1) == 1 then blk[1] = blk[1] + POW[Al] end
        end
      end
    elseif Ah == 0 then
      decodeBlock = function(c, blk)
        if eobrun > 0 then eobrun = eobrun - 1; return end
        local ac = c.act
        local k = Ss
        while k <= Se do
          local rs = huff(ac)
          local s, r = rs % 16, floor(rs / 16)
          if s == 0 then
            if r < 15 then
              eobrun = POW[r] - 1
              if r > 0 then eobrun = eobrun + bits(r) end
              break
            end
            k = k + 16
          else
            k = k + r
            if k <= 63 then blk[ZZ1[k]] = ext(s) * POW[Al] else ext(s) end
            k = k + 1
          end
        end
      end
    else
      local bit = POW[Al]
      local function refine(blk, z)
        local v = blk[z]
        if bits(1) == 1 and floor(math.abs(v) / bit) % 2 == 0 then
          blk[z] = v >= 0 and v + bit or v - bit
        end
      end
      decodeBlock = function(c, blk)
        local k = Ss
        if eobrun > 0 then
          eobrun = eobrun - 1
          for kk = Ss, Se do
            local z = ZZ1[kk]
            if blk[z] ~= 0 then refine(blk, z) end
          end
          return
        end
        local ac = c.act
        while k <= Se do
          local rs = huff(ac)
          local s, r = rs % 16, floor(rs / 16)
          if s == 0 then
            if r < 15 then
              eobrun = POW[r] - 1
              if r > 0 then eobrun = eobrun + bits(r) end
              r = 64
            end
          else
            s = bits(1) == 1 and bit or -bit
          end
          while k <= Se do
            local z = ZZ1[k]
            k = k + 1
            if blk[z] ~= 0 then
              refine(blk, z)
            else
              if r == 0 then
                if s ~= 0 then blk[z] = s end
                break
              end
              r = r - 1
            end
          end
        end
      end
    end

    local mcu = 0
    local streaming = not progressive and #scomps == #comps
    if #scomps == 1 then
      local c = scomps[1]
      for row = 0, c.bh - 1 do
        for col = 0, c.bw - 1 do
          if ri > 0 and mcu > 0 and mcu % ri == 0 then restart(); eobrun = 0 end
          decodeBlock(c, getBlock(c, row, col))
          mcu = mcu + 1
        end
        maybeYield()
        if streaming and (row + 1) % c.v == 0 then flushRows((row + 1) / c.v) end
      end
    else
      for my = 0, frame.mcusY - 1 do
        for mx = 0, frame.mcusX - 1 do
          if ri > 0 and mcu > 0 and mcu % ri == 0 then restart(); eobrun = 0 end
          for _, c in ipairs(scomps) do
            for v = 0, c.v - 1 do
              for h = 0, c.h - 1 do
                decodeBlock(c, getBlock(c, my * c.v + v, mx * c.h + h))
              end
            end
          end
          mcu = mcu + 1
        end
        maybeYield()
        if streaming then flushRows(my + 1) end
      end
    end
    return skipScan(q)
  end

  while p < #data do
    if byte(data, p) ~= 0xFF then p = p + 1
    else
      local m = byte(data, p + 1)
      if m == 0xFF then p = p + 1
      elseif m == 0xD8 or m == 0x01 or (m >= 0xD0 and m <= 0xD7) then p = p + 2
      elseif m == 0xD9 then break
      else
        local len = u16(data, p + 2)
        local s = p + 4 -- segment payload start
        local e = p + 2 + len
        if m == 0xDB then
          while s < e do
            local pq, tq = floor(byte(data, s) / 16), byte(data, s) % 16
            s = s + 1
            local t = {}
            for k = 0, 63 do
              local v
              if pq == 0 then v = byte(data, s); s = s + 1 else v = u16(data, s); s = s + 2 end
              t[ZZ1[k]] = v
            end
            qt[tq] = t
          end
        elseif m == 0xC4 then
          while s < e do
            local tc, th = floor(byte(data, s) / 16), byte(data, s) % 16
            local counts, total = {}, 0
            for l = 1, 16 do counts[l] = byte(data, s + l); total = total + counts[l] end
            local syms = {}
            for i = 1, total do syms[i] = byte(data, s + 16 + i) end
            s = s + 17 + total
            if tc == 0 then dcT[th] = buildHuff(counts, syms) else acT[th] = buildHuff(counts, syms) end
          end
        elseif m == 0xDD then
          ri = u16(data, s)
        elseif m == 0xEE and data:sub(s, s + 4) == "Adobe" then
          adobe = byte(data, s + 11)
        elseif m == 0xC0 or m == 0xC1 or m == 0xC2 then
          if byte(data, s) ~= 8 then error("JPEG: only 8-bit precision supported") end
          frame = { progressive = m == 0xC2, h = u16(data, s + 1), w = u16(data, s + 3) }
          if frame.h == 0 then error("JPEG: DNL height not supported") end
          comps, byId = {}, {}
          local nc = byte(data, s + 5)
          frame.hmax, frame.vmax = 1, 1
          for i = 0, nc - 1 do
            local o = s + 6 + i * 3
            local hv = byte(data, o + 1)
            local c = { id = byte(data, o), h = floor(hv / 16), v = hv % 16, tq = byte(data, o + 2),
                        blocks = {}, pred = 0 }
            comps[#comps + 1] = c
            byId[c.id] = c
            frame.hmax = math.max(frame.hmax, c.h)
            frame.vmax = math.max(frame.vmax, c.v)
          end
          if nc ~= 1 and nc ~= 3 and nc ~= 4 then error("JPEG: unsupported component count") end
          frame.mcusX = math.ceil(frame.w / (8 * frame.hmax))
          frame.mcusY = math.ceil(frame.h / (8 * frame.vmax))
          for _, c in ipairs(comps) do
            c.bpl = frame.mcusX * c.h
            c.bw = math.ceil(math.ceil(frame.w * c.h / frame.hmax) / 8)
            c.bh = math.ceil(math.ceil(frame.h * c.v / frame.vmax) / 8)
          end
          if nc == 1 then
            -- a single component scan is never interleaved: one block per MCU
            local c = comps[1]
            c.h, c.v, frame.hmax, frame.vmax = 1, 1, 1, 1
            frame.mcusX, frame.mcusY = c.bw, c.bh
            c.bpl = c.bw
          end
          S = dcOnly and 1 or 8
          if dcOnly then
            outW, outH = math.ceil(frame.w / 8), math.ceil(frame.h / 8)
          else
            outW, outH = frame.w, frame.h
          end
        elseif m >= 0xC3 and m <= 0xCF and m ~= 0xC4 and m ~= 0xC8 and m ~= 0xCC then
          error("JPEG: unsupported type (lossless/arithmetic coded)")
        elseif m == 0xDA then
          if not frame then error("JPEG: scan before frame") end
          local ns = byte(data, s)
          local scomps = {}
          for i = 0, ns - 1 do
            local c = byId[byte(data, s + 1 + i * 2)]
            local t = byte(data, s + 2 + i * 2)
            if not c then error("JPEG: bad scan component") end
            c.dct, c.act = dcT[floor(t / 16)], acT[t % 16]
            c.pred = 0
            scomps[#scomps + 1] = c
          end
          local o = s + 1 + ns * 2
          local Ss, Se, A = byte(data, o), byte(data, o + 1), byte(data, o + 2)
          if dcOnly and frame.progressive and Ss > 0 then
            p = skipScan(e)
          else
            p = decodeScan(e, scomps, Ss, Se, floor(A / 16), A % 16)
          end
          e = nil
        end
        if e then p = e end
      end
    end
  end
  if not frame then error("JPEG: no image data") end
  flushRows(frame.mcusY)
  return outW, outH
end

return M
