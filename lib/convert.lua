-- Converts PNG / JPEG / BMP files into adimg images: decode -> resample to
-- the 2x3 pixel grid -> (optionally) optimise a 16 colour palette ->
-- quantise with the "two colours per cell" constraint (+ optional dithering).
local adimg = require("lib.adimg")

local M = {}
local floor, byte = math.floor, string.byte

local DECODERS = {
  png = "lib.png", jpeg = "lib.jpeg", bmp = "lib.bmp",
}

-- Detects a file type from its first bytes.
function M.detect(data)
  if data:sub(1, 8) == "\137PNG\r\n\26\n" then return "png" end
  if byte(data, 1) == 0xFF and byte(data, 2) == 0xD8 then return "jpeg" end
  if data:sub(1, 2) == "BM" then return "bmp" end
  if data:sub(1, 6) == "ADIMG " then return "adimg" end
  if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then return "webp" end
  if data:sub(1, 3) == "GIF" then return "gif" end
  return nil
end

-- Returns info table {format, w, h, orientation} or nil, err.
function M.info(data)
  local fmt = M.detect(data)
  if not fmt then return nil, "unknown file format" end
  if not DECODERS[fmt] then return nil, fmt:upper() .. " files are not supported" end
  local dec = require(DECODERS[fmt])
  local w, h, extra = dec.info(data)
  if not w then return nil, h end
  local info = { format = fmt, w = w, h = h, orientation = extra and extra.orientation or 1 }
  if info.orientation >= 5 then info.dw, info.dh = h, w else info.dw, info.dh = w, h end
  return info
end

-- Suggests a cell size that fits maxW x maxH cells while keeping the aspect
-- ratio (a cell is 2x3 pixels, so pixels stay square).
function M.fitCells(info, maxW, maxH)
  local cw = maxW
  local ch = floor(cw * 2 * info.dh / info.dw / 3 + 0.5)
  if ch > maxH then
    ch = maxH
    cw = floor(ch * 3 * info.dw / info.dh / 2 + 0.5)
  end
  return math.max(1, cw), math.max(1, ch)
end

---------------------------------------------------------------------------
-- Resampling
---------------------------------------------------------------------------

local function resample(data, info, rw, rh, bg, yield)
  local dec = require(DECODERS[info.format])
  local sw, sh = info.w, info.h
  local dcOnly = false
  if info.format == "jpeg" and math.ceil(sw / 8) >= rw and math.ceil(sh / 8) >= rh then
    dcOnly = true
    sw, sh = math.ceil(sw / 8), math.ceil(sh / 8)
  end
  local bgr, bgg, bgb = adimg.rgb(bg)
  local R, G, B, N = {}, {}, {}, {}
  for i = 1, rw * rh do R[i], G[i], B[i], N[i] = 0, 0, 0, 0 end

  local onRow
  if sw >= rw and sh >= rh then
    -- box filter: every source pixel adds to exactly one target pixel
    local xmap = {}
    for x = 1, sw do xmap[x] = floor((x - 1) * rw / sw) + 1 end
    onRow = function(y, r, g, b, a)
      if y >= sh then return end
      local base = floor(y * rh / sh) * rw
      for x = 1, sw do
        local i = base + xmap[x]
        local al = a[x]
        if al == 255 then
          R[i] = R[i] + r[x]; G[i] = G[i] + g[x]; B[i] = B[i] + b[x]
        else
          local f = al / 255
          R[i] = R[i] + r[x] * f + bgr * (1 - f)
          G[i] = G[i] + g[x] * f + bgg * (1 - f)
          B[i] = B[i] + b[x] * f + bgb * (1 - f)
        end
        N[i] = N[i] + 1
      end
    end
  else
    -- nearest neighbour (upscaling in at least one direction)
    local want = {}
    for ty = 0, rh - 1 do
      local sy = floor((ty + 0.5) * sh / rh)
      want[sy] = want[sy] or {}
      table.insert(want[sy], ty)
    end
    local xmap = {}
    for tx = 1, rw do xmap[tx] = math.min(sw, floor((tx - 0.5) * sw / rw) + 1) end
    onRow = function(y, r, g, b, a)
      local list = want[y]
      if not list then return end
      for _, ty in ipairs(list) do
        for tx = 1, rw do
          local x = xmap[tx]
          local i = ty * rw + tx
          local f = a[x] / 255
          R[i] = r[x] * f + bgr * (1 - f)
          G[i] = g[x] * f + bgg * (1 - f)
          B[i] = b[x] * f + bgb * (1 - f)
          N[i] = 1
        end
      end
    end
  end
  dec.decode(data, onRow, yield, dcOnly)
  for i = 1, rw * rh do
    local n = N[i]
    if n > 0 then R[i], G[i], B[i] = R[i] / n, G[i] / n, B[i] / n
    else R[i], G[i], B[i] = bgr, bgg, bgb end
  end
  return R, G, B
end

-- Applies an EXIF orientation while copying the (rw x rh) grid to (tw x th).
local function orient(R, G, B, rw, rh, o, tw, th)
  if o == 1 then return R, G, B end
  local R2, G2, B2 = {}, {}, {}
  for Y = 0, th - 1 do
    for X = 0, tw - 1 do
      local x, y
      if o == 2 then x, y = rw - 1 - X, Y
      elseif o == 3 then x, y = rw - 1 - X, rh - 1 - Y
      elseif o == 4 then x, y = X, rh - 1 - Y
      elseif o == 5 then x, y = Y, X
      elseif o == 6 then x, y = Y, rh - 1 - X
      elseif o == 7 then x, y = rw - 1 - Y, rh - 1 - X
      else x, y = rw - 1 - Y, X end
      local s, d = y * rw + x + 1, Y * tw + X + 1
      R2[d], G2[d], B2[d] = R[s], G[s], B[s]
    end
  end
  return R2, G2, B2
end

---------------------------------------------------------------------------
-- Palette optimisation (median cut + k-means refinement)
---------------------------------------------------------------------------

local function optimisePalette(R, G, B, n, yield)
  local step = math.max(1, floor(n / 12000))
  local pts = {}
  for i = 1, n, step do pts[#pts + 1] = { R[i], G[i], B[i] } end
  local boxes = { { 1, #pts } }
  while #boxes < 16 do
    -- pick the box with the largest channel range
    local best, bestRange, bestCh = nil, -1, 1
    for bi, bx in ipairs(boxes) do
      if bx[2] > bx[1] then
        for ch = 1, 3 do
          local lo, hi = 256, -1
          for i = bx[1], bx[2] do
            local v = pts[i][ch]
            if v < lo then lo = v end
            if v > hi then hi = v end
          end
          local w = (hi - lo) * (ch == 2 and 1.2 or 1)
          if w > bestRange then best, bestRange, bestCh = bi, w, ch end
        end
      end
    end
    if not best or bestRange <= 0 then break end
    local bx = boxes[best]
    local tmp = {}
    for i = bx[1], bx[2] do tmp[#tmp + 1] = pts[i] end
    table.sort(tmp, function(a, b) return a[bestCh] < b[bestCh] end)
    for i = 1, #tmp do pts[bx[1] + i - 1] = tmp[i] end
    local mid = bx[1] + floor(#tmp / 2) - 1
    boxes[best] = { bx[1], mid }
    boxes[#boxes + 1] = { mid + 1, bx[2] }
    if yield then yield() end
  end
  local cen = {}
  for _, bx in ipairs(boxes) do
    local r, g, b = 0, 0, 0
    for i = bx[1], bx[2] do r = r + pts[i][1]; g = g + pts[i][2]; b = b + pts[i][3] end
    local c = bx[2] - bx[1] + 1
    cen[#cen + 1] = { r / c, g / c, b / c }
  end
  -- k-means refinement
  for _ = 1, 4 do
    local sum = {}
    for k = 1, #cen do sum[k] = { 0, 0, 0, 0 } end
    for i = 1, #pts do
      local p = pts[i]
      local bk, bd = 1, math.huge
      for k = 1, #cen do
        local c = cen[k]
        local dr, dg, db = p[1] - c[1], p[2] - c[2], p[3] - c[3]
        local d = 2 * dr * dr + 4 * dg * dg + 3 * db * db
        if d < bd then bk, bd = k, d end
      end
      local s = sum[bk]
      s[1], s[2], s[3], s[4] = s[1] + p[1], s[2] + p[2], s[3] + p[3], s[4] + 1
      if i % 2000 == 0 and yield then yield() end
    end
    for k = 1, #cen do
      local s = sum[k]
      if s[4] > 0 then cen[k] = { s[1] / s[4], s[2] / s[4], s[3] / s[4] } end
    end
  end
  -- fill unused slots, order bright -> dark (like the default palette)
  local defaults = { { 240, 240, 240 }, { 17, 17, 17 }, { 153, 153, 153 }, { 76, 76, 76 } }
  local di = 1
  while #cen < 16 do cen[#cen + 1] = defaults[di] or { 0, 0, 0 }; di = di + 1 end
  table.sort(cen, function(a, b)
    return a[1] * 0.3 + a[2] * 0.59 + a[3] * 0.11 > b[1] * 0.3 + b[2] * 0.59 + b[3] * 0.11
  end)
  local pal = {}
  for k = 1, 16 do
    local c = cen[k]
    pal[k - 1] = floor(c[1] + 0.5) * 65536 + floor(c[2] + 0.5) * 256 + floor(c[3] + 0.5)
  end
  return pal
end

---------------------------------------------------------------------------
-- Quantisation with the 2-colours-per-cell constraint
---------------------------------------------------------------------------

local function quantise(R, G, B, cw, ch, palette, dither, yield)
  local pw = cw * 2
  local PR, PG, PB = {}, {}, {}
  for i = 0, 15 do PR[i], PG[i], PB[i] = adimg.rgb(palette[i]) end
  local px = {}
  -- copies so error diffusion can modify values
  local r, g, b = {}, {}, {}
  for i = 1, #R do r[i], g[i], b[i] = R[i], G[i], B[i] end
  local offs = { 0, 1, pw, pw + 1, 2 * pw, 2 * pw + 1 }
  local function clamp(v) return v < 0 and 0 or v > 255 and 255 or v end
  local d = {} -- d[p*16 + c]
  for cy = 0, ch - 1 do
    for cx = 0, cw - 1 do
      local base = cy * 3 * pw + cx * 2 + 1
      -- distances of the 6 pixels to every palette colour
      local cand, ncand = {}, 0
      local isCand = {}
      for p = 1, 6 do
        local i = base + offs[p]
        local vr, vg, vb = clamp(r[i]), clamp(g[i]), clamp(b[i])
        local b1, b2, d1, d2 = 0, 0, math.huge, math.huge
        for c = 0, 15 do
          local dr, dg, db = vr - PR[c], vg - PG[c], vb - PB[c]
          local dd = 2 * dr * dr + 4 * dg * dg + 3 * db * db
          d[p * 16 + c] = dd
          if dd < d1 then b2, d2 = b1, d1; b1, d1 = c, dd
          elseif dd < d2 then b2, d2 = c, dd end
        end
        if not isCand[b1] then isCand[b1] = true; ncand = ncand + 1; cand[ncand] = b1 end
        if not isCand[b2] then isCand[b2] = true; ncand = ncand + 1; cand[ncand] = b2 end
      end
      -- best pair among candidates
      local ba, bb, bcost = cand[1], cand[1], math.huge
      for i = 1, ncand do
        local ca = cand[i]
        for j = i, ncand do
          local cb = cand[j]
          local cost = 0
          for p = 1, 6 do
            local da, db = d[p * 16 + ca], d[p * 16 + cb]
            cost = cost + (da < db and da or db)
          end
          if cost < bcost then ba, bb, bcost = ca, cb, cost end
        end
      end
      -- assign pixels (with optional Floyd-Steinberg diffusion)
      for p = 1, 6 do
        local i = base + offs[p]
        local vr, vg, vb = clamp(r[i]), clamp(g[i]), clamp(b[i])
        local c
        if dither then
          local dr, dg, db = vr - PR[ba], vg - PG[ba], vb - PB[ba]
          local da = 2 * dr * dr + 4 * dg * dg + 3 * db * db
          dr, dg, db = vr - PR[bb], vg - PG[bb], vb - PB[bb]
          c = (2 * dr * dr + 4 * dg * dg + 3 * db * db) < da and bb or ba
          -- diffuse 85% of the error: full FS gets noisy with only 2 colours/cell
          local er, eg, eb = (vr - PR[c]) * 0.85, (vg - PG[c]) * 0.85, (vb - PB[c]) * 0.85
          local x = cx * 2 + (p - 1) % 2
          local y = cy * 3 + floor((p - 1) / 2)
          local lx = (p - 1) % 2      -- column inside the cell
          local ly = floor((p - 1) / 2)
          -- right neighbour (always unprocessed)
          if x + 1 < pw then
            local j = i + 1
            r[j], g[j], b[j] = r[j] + er * 7 / 16, g[j] + eg * 7 / 16, b[j] + eb * 7 / 16
          end
          if y + 1 < ch * 3 then
            local j = i + pw
            r[j], g[j], b[j] = r[j] + er * 5 / 16, g[j] + eg * 5 / 16, b[j] + eb * 5 / 16
            -- below-left belongs to an already processed cell when it is in
            -- the same cell row and we are in the cell's left column
            if x > 0 and not (lx == 0 and ly < 2) then
              j = i + pw - 1
              r[j], g[j], b[j] = r[j] + er * 3 / 16, g[j] + eg * 3 / 16, b[j] + eb * 3 / 16
            end
            if x + 1 < pw then
              j = i + pw + 1
              r[j], g[j], b[j] = r[j] + er / 16, g[j] + eg / 16, b[j] + eb / 16
            end
          end
        else
          c = d[p * 16 + ba] <= d[p * 16 + bb] and ba or bb
        end
        px[i] = c
      end
    end
    if yield then yield() end
  end
  return px
end

-- Imports an encoded image file (string) into a new adimg image.
-- opts: w, h (cells), dither (bool), optimise (bool: custom palette),
--       background (0xRRGGBB used behind transparent pixels), yield, status(msg)
function M.import(data, opts)
  local info, err = M.info(data)
  if not info then return nil, err end
  local cw, ch = opts.w, opts.h
  if cw and not ch then ch = select(2, M.fitCells(info, cw, math.huge)) end
  if not cw or not ch then cw, ch = M.fitCells(info, opts.maxW or 51, opts.maxH or 19) end
  local tw, th = cw * 2, ch * 3
  local rw, rh = tw, th
  if info.orientation >= 5 then rw, rh = th, tw end
  local status = opts.status or function() end
  status("Decoding " .. info.format:upper() .. " " .. info.w .. "x" .. info.h .. "...")
  local ok, R, G, B = pcall(resample, data, info, rw, rh, opts.background or 0xFFFFFF, opts.yield)
  if not ok then return nil, tostring(R) end
  R, G, B = orient(R, G, B, rw, rh, info.orientation, tw, th)
  local palette = adimg.DEFAULT_PALETTE
  local custom = nil
  if opts.optimise then
    status("Optimising palette...")
    custom = optimisePalette(R, G, B, tw * th, opts.yield)
    palette = custom
  end
  status("Quantising...")
  local img = adimg.new(cw, ch, 15)
  img.px = quantise(R, G, B, cw, ch, palette, opts.dither, opts.yield)
  img.palette = custom
  return img
end

return M
