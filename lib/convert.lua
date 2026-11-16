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
  local info = { format = fmt, w = w, h = h, orientation = extra and extra.orientation or 1,
                 indexed = extra and extra.indexed or false }
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

-- hist (optional table): filled with exact source colours -> pixel counts
-- (stops counting past 4096 distinct colours: hist.overflow = true).
-- crisp: when shrinking an image with few colours, give every target pixel
-- one real source colour instead of an average (used when not dithering).
local function resample(data, info, rw, rh, bg, yield, hist, crisp)
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
  -- pixel art while shrinking: remember which exact colours fall into each
  -- target pixel, so we can pick a real colour later instead of a blend
  local areas = crisp and hist and sw >= rw and sh >= rh and {} or nil
  local axmap
  if areas then
    axmap = {}
    for x = 1, sw do axmap[x] = floor((x - 1) * rw / sw) + 1 end
  end
  if hist then
    local inner, n = onRow, 0
    onRow = function(y, r, g, b, a)
      if areas and y < sh then
        local base = floor(y * rh / sh) * rw
        for x = 1, #r do
          local al = a[x]
          local c
          if al == 255 then c = r[x] * 65536 + g[x] * 256 + b[x]
          else
            local f = al / 255
            c = floor(r[x] * f + bgr * (1 - f) + 0.5) * 65536 + floor(g[x] * f + bgg * (1 - f) + 0.5) * 256
              + floor(b[x] * f + bgb * (1 - f) + 0.5)
          end
          local i = base + axmap[x]
          local t = areas[i]
          if not t then t = {}; areas[i] = t end
          t[c] = (t[c] or 0) + 1
        end
      end
      if not hist.overflow then
        for x = 1, #r do
          local al = a[x]
          local c
          if al == 255 then c = r[x] * 65536 + g[x] * 256 + b[x]
          else
            local f = al / 255
            c = floor(r[x] * f + bgr * (1 - f) + 0.5) * 65536 + floor(g[x] * f + bgg * (1 - f) + 0.5) * 256
              + floor(b[x] * f + bgb * (1 - f) + 0.5)
          end
          local v = hist[c]
          if not v then
            n = n + 1
            if n > 4096 then hist.overflow = true; areas = nil; break end
            v = 0
          end
          hist[c] = v + 1
        end
      end
      inner(y, r, g, b, a)
    end
  end
  dec.decode(data, onRow, yield, dcOnly)
  for i = 1, rw * rh do
    local n = N[i]
    if n > 0 then R[i], G[i], B[i] = R[i] / n, G[i] / n, B[i] / n
    else R[i], G[i], B[i] = bgr, bgg, bgb end
  end
  if areas and not hist.overflow then
    -- each target pixel takes one exact source colour: of the colours
    -- covering at least a quarter of its area, the one that is rarest in
    -- the whole image (thin lines and text beat the background)
    for i = 1, rw * rh do
      local t = areas[i]
      if t then
        local total, best, bestN, top, topN = 0, nil, math.huge, nil, -1
        for _, cnt in pairs(t) do total = total + cnt end
        for c, cnt in pairs(t) do
          if cnt > topN then top, topN = c, cnt end
          if cnt * 4 >= total and hist[c] < bestN then best, bestN = c, hist[c] end
        end
        local c = best or top
        R[i], G[i], B[i] = adimg.rgb(c)
      end
    end
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

local function samplePoints(R, G, B, n, limit)
  local step = math.max(1, floor(n / limit))
  local pts = {}
  for i = 1, n, step do pts[#pts + 1] = { R[i], G[i], B[i] } end
  return pts
end

local function pdist(r1, g1, b1, r2, g2, b2)
  local dr, dg, db = r1 - r2, g1 - g2, b1 - b2
  return 2 * dr * dr + 4 * dg * dg + 3 * db * db
end

local function luma(c) local r, g, b = adimg.rgb(c); return r * 0.3 + g * 0.59 + b * 0.11 end

-- Picks the k colours of the default palette that represent the image best
-- (greedy: repeatedly add the colour that lowers the total error most).
local function defaultSubset(R, G, B, n, k, yield)
  local pts = samplePoints(R, G, B, n, 3000)
  local DP = adimg.DEFAULT_PALETTE
  local PR, PG, PB = {}, {}, {}
  for c = 0, 15 do PR[c], PG[c], PB[c] = adimg.rgb(DP[c]) end
  local best = {} -- current error per point
  for i = 1, #pts do best[i] = math.huge end
  local chosen, used = {}, {}
  for _ = 1, k do
    local bc, berr = nil, math.huge
    for c = 0, 15 do
      if not used[c] then
        local err = 0
        for i = 1, #pts do
          local p = pts[i]
          local d = pdist(p[1], p[2], p[3], PR[c], PG[c], PB[c])
          err = err + (d < best[i] and d or best[i])
        end
        if err < berr then bc, berr = c, err end
      end
    end
    used[bc] = true
    chosen[#chosen + 1] = bc
    for i = 1, #pts do
      local p = pts[i]
      local d = pdist(p[1], p[2], p[3], PR[bc], PG[bc], PB[bc])
      if d < best[i] then best[i] = d end
    end
    if yield then yield() end
  end
  table.sort(chosen)
  return chosen
end

-- Turns a list of chosen 0xRRGGBB colours into a 16 slot palette: the
-- colours (bright -> dark) in slots 0..n-1, spare slots filled with default
-- colours that differ most from them (so there is something left to draw
-- with). Returns palette, allowed (the slots the image may use).
local function finishPalette(cols)
  local seen, uniq = {}, {}
  for _, c in ipairs(cols) do if not seen[c] then seen[c] = true; uniq[#uniq + 1] = c end end
  cols = uniq
  table.sort(cols, function(a, b) return luma(a) > luma(b) end)
  local used = #cols
  local spare, taken = {}, {}
  while #cols + #spare < 16 do
    local bc, bd = nil, -1
    for c = 0, 15 do
      if not taken[c] then
        local dc = adimg.DEFAULT_PALETTE[c]
        local md = math.huge
        for _, x in ipairs(cols) do md = math.min(md, adimg.dist(dc, x)) end
        for _, x in ipairs(spare) do md = math.min(md, adimg.dist(dc, x)) end
        if md > bd then bc, bd = c, md end
      end
    end
    taken[bc] = true
    spare[#spare + 1] = adimg.DEFAULT_PALETTE[bc]
  end
  table.sort(spare, function(a, b) return luma(a) > luma(b) end)
  local pal, allowed = {}, {}
  for i = 1, 16 do
    pal[i - 1] = cols[i] or spare[i - #cols]
    if i <= used then allowed[i] = i - 1 end
  end
  return pal, allowed
end

-- Builds a custom palette with k colours fitted to the image: median cut
-- that always splits the box with the largest total squared error (so a
-- big flat background doesn't eat all the colours), then weighted k-means.
local function optimisePalette(R, G, B, n, yield, k)
  k = k or 16
  local pts = samplePoints(R, G, B, n, 12000)
  local function boxStats(b)
    local sr, sg, sb, c = 0, 0, 0, b[2] - b[1] + 1
    for i = b[1], b[2] do local p = pts[i]; sr, sg, sb = sr + p[1], sg + p[2], sb + p[3] end
    local mr, mg, mb = sr / c, sg / c, sb / c
    local vr, vg, vb = 0, 0, 0
    for i = b[1], b[2] do
      local p = pts[i]
      vr, vg, vb = vr + (p[1] - mr) ^ 2, vg + (p[2] - mg) ^ 2, vb + (p[3] - mb) ^ 2
    end
    vr, vg, vb = vr * 2, vg * 4, vb * 3 -- same weights as the colour distance
    b.err = vr + vg + vb
    b.ch = (vr >= vg and vr >= vb) and 1 or (vg >= vb and 2 or 3)
    b.mean = { mr, mg, mb }
  end
  local boxes = { { 1, #pts } }
  boxStats(boxes[1])
  while #boxes < k do
    local best
    for bi, bx in ipairs(boxes) do
      if bx[2] > bx[1] and bx.err > 0 and (not best or bx.err > boxes[best].err) then best = bi end
    end
    if not best then break end
    local bx = boxes[best]
    local ch = bx.ch
    local tmp = {}
    for i = bx[1], bx[2] do tmp[#tmp + 1] = pts[i] end
    table.sort(tmp, function(a, b) return a[ch] < b[ch] end)
    for i = 1, #tmp do pts[bx[1] + i - 1] = tmp[i] end
    -- split at the mean (not the median), so a small distinct group gets
    -- its own box instead of being cut in half
    local mean, cut = bx.mean[ch], bx[1]
    while cut < bx[2] - 1 and pts[cut + 1][ch] <= mean do cut = cut + 1 end
    if cut >= bx[2] then cut = bx[2] - 1 end
    local a, b = { bx[1], cut }, { cut + 1, bx[2] }
    boxStats(a); boxStats(b)
    boxes[best] = a
    boxes[#boxes + 1] = b
    if yield then yield() end
  end
  local cen = {}
  for _, bx in ipairs(boxes) do cen[#cen + 1] = { bx.mean[1], bx.mean[2], bx.mean[3] } end
  -- k-means refinement; a centre that loses all its points jumps to the
  -- point that is currently worst represented
  for _ = 1, 4 do
    local sum, worst, worstD = {}, nil, -1
    for c = 1, #cen do sum[c] = { 0, 0, 0, 0 } end
    for i = 1, #pts do
      local p = pts[i]
      local bk, bd = 1, math.huge
      for c = 1, #cen do
        local q = cen[c]
        local d = pdist(p[1], p[2], p[3], q[1], q[2], q[3])
        if d < bd then bk, bd = c, d end
      end
      if bd > worstD then worst, worstD = p, bd end
      local s4 = sum[bk]
      s4[1], s4[2], s4[3], s4[4] = s4[1] + p[1], s4[2] + p[2], s4[3] + p[3], s4[4] + 1
      if i % 2000 == 0 and yield then yield() end
    end
    for c = 1, #cen do
      local s4 = sum[c]
      if s4[4] > 0 then cen[c] = { s4[1] / s4[4], s4[2] / s4[4], s4[3] / s4[4] }
      elseif worst then cen[c] = { worst[1], worst[2], worst[3] }; worst = nil end
    end
  end
  local cols = {}
  for i, c in ipairs(cen) do
    cols[i] = floor(c[1] + 0.5) * 65536 + floor(c[2] + 0.5) * 256 + floor(c[3] + 0.5)
  end
  return finishPalette(cols)
end

-- Pixel art / logos: use the source's exact colours. If there are more
-- than k, pick them weighted farthest-first: start with the most common
-- colour, then repeatedly add the colour with the largest
-- (pixel count x distance to everything chosen so far).
local function pixelArtPalette(hist, k)
  local list = {}
  for c, n in pairs(hist) do if type(c) == "number" then list[#list + 1] = { c, n } end end
  table.sort(list, function(a, b) return a[2] > b[2] end)
  local cols = {}
  if #list <= k then
    for i, e in ipairs(list) do cols[i] = e[1] end
  else
    local minD = {}
    for i = 1, #list do minD[i] = math.huge end
    local pickI = 1
    while #cols < k do
      cols[#cols + 1] = list[pickI][1]
      local bestI, bestS = nil, -1
      for i, e in ipairs(list) do
        local d = adimg.dist(e[1], list[pickI][1])
        if d < minD[i] then minD[i] = d end
        local sc = e[2] * math.sqrt(minD[i])
        if sc > bestS then bestI, bestS = i, sc end
      end
      if not bestI or bestS <= 0 then break end
      pickI = bestI
    end
  end
  return finishPalette(cols)
end

---------------------------------------------------------------------------
-- Quantisation with the 2-colours-per-cell constraint
---------------------------------------------------------------------------

local function quantise(R, G, B, cw, ch, palette, dither, yield, allowed)
  local nal = #allowed
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
        local b1, b2, d1, d2 = allowed[1], allowed[1], math.huge, math.huge
        for ai = 1, nal do
          local c = allowed[ai]
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
--       colours (2..16, how many palette colours the image may use),
--       mode ("stretch" (default), "fit" or "fill") with anchor ax, ay,
--       background (0xRRGGBB used behind transparent pixels), yield, status(msg)
function M.import(data, opts)
  local info, err = M.info(data)
  if not info then return nil, err end
  local cw, ch = opts.w, opts.h
  if cw and not ch then ch = select(2, M.fitCells(info, cw, math.huge)) end
  if not cw or not ch then cw, ch = M.fitCells(info, opts.maxW or 51, opts.maxH or 19) end
  local tw, th = cw * 2, ch * 3
  -- the picture's size/offset inside the target (fit/fill/stretch)
  local dw, dh, ox, oy = adimg.fitRect(info.dw, info.dh, tw, th, opts.mode or "stretch", opts.ax, opts.ay)
  local rw, rh = dw, dh
  if info.orientation >= 5 then rw, rh = dh, dw end
  local status = opts.status or function() end
  status("Decoding " .. info.format:upper() .. " " .. info.w .. "x" .. info.h .. "...")
  -- Images with few colours (logos, pixel art, maps) keep their exact
  -- colours; photos (more than 4096 colours) get a fitted palette instead.
  local hist = {}
  local ok, R, G, B = pcall(resample, data, info, rw, rh, opts.background or 0xFFFFFF, opts.yield, hist,
                            not opts.dither)
  if not ok then return nil, tostring(R) end
  R, G, B = orient(R, G, B, rw, rh, info.orientation, dw, dh)
  if dw ~= tw or dh ~= th or ox ~= 0 or oy ~= 0 then
    -- place the picture: bars (fit) get the background colour, overflow
    -- (fill) is cropped
    local br, bg, bb = adimg.rgb(opts.background or 0xFFFFFF)
    local R2, G2, B2 = {}, {}, {}
    for y = 0, th - 1 do
      local sy = y - oy
      for x = 0, tw - 1 do
        local sx = x - ox
        local d = y * tw + x + 1
        if sx >= 0 and sy >= 0 and sx < dw and sy < dh then
          local s = sy * dw + sx + 1
          R2[d], G2[d], B2[d] = R[s], G[s], B[s]
        else
          R2[d], G2[d], B2[d] = br, bg, bb
        end
      end
    end
    R, G, B = R2, G2, B2
  end
  local palette = adimg.DEFAULT_PALETTE
  local custom, allowed = nil, nil
  local k = math.max(2, math.min(16, opts.colours or 16))
  if opts.optimise then
    status("Optimising palette...")
    if not hist.overflow then
      custom, allowed = pixelArtPalette(hist, k)
    else
      custom, allowed = optimisePalette(R, G, B, tw * th, opts.yield, k)
    end
    palette = custom
  elseif k < 16 then
    status("Choosing colours...")
    allowed = defaultSubset(R, G, B, tw * th, k, opts.yield)
  else
    allowed = {}
    for c = 0, 15 do allowed[c + 1] = c end
  end
  status("Quantising...")
  local img = adimg.new(cw, ch, 15)
  img.px = quantise(R, G, B, cw, ch, palette, opts.dither, opts.yield, allowed)
  img.palette = custom
  return img
end

return M
