-- paint: editing operations on adimg images (see lib/formats/adimg.lua), with no
-- user interface or editor state, so other programs can draw on images too.
--
-- Functions that change pixels take an optional `set(img, i, c)` used for
-- every write (i = index into img.px); the editor passes one that records
-- undo information. Without it pixels are written directly.
local adimg = require("lib.formats.adimg")

local M = {}
local floor, max, min = math.floor, math.max, math.min

local function directSet(img, i, c) img.px[i] = c end

-- 4x4 ordered dither matrix (values 0..15).
M.BAYER = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 }
local BAYER = M.BAYER

-- Whether pixel (x, y) is painted at `level` coverage out of 16.
function M.ditherOn(x, y, level)
  return BAYER[(y % 4) * 4 + x % 4 + 1] < level
end
local ditherOn = M.ditherOn

-- Restores the "max 2 colours per cell" rule after painting `keep`: the cell
-- keeps `keep` (or, if absent, its most common colour) plus its most common
-- other colour; other pixels snap to whichever of the two is nearer.
function M.fixCell(img, cx, cy, keep, set)
  if cx < 0 or cy < 0 or cx >= img.w or cy >= img.h then return end
  set = set or directSet
  local pw, px = img.pw, img.px
  local b = cy * 3 * pw + cx * 2 + 1
  local idx = { b, b + 1, b + pw, b + pw + 1, b + 2 * pw, b + 2 * pw + 1 }
  local cnt, n = {}, 0
  for k = 1, 6 do
    local c = px[idx[k]]
    if not cnt[c] then cnt[c] = 0; n = n + 1 end
    cnt[c] = cnt[c] + 1
  end
  if n <= 2 then return end
  if not cnt[keep] then
    local bc = -1
    for c, v in pairs(cnt) do if v > bc then keep, bc = c, v end end
  end
  local second, sc = nil, -1
  for c = 0, 15 do
    local v = cnt[c]
    if v and c ~= keep and v > sc then second, sc = c, v end
  end
  local pal = img.palette or adimg.DEFAULT_PALETTE
  for k = 1, 6 do
    local c = px[idx[k]]
    if c ~= keep and c ~= second then
      local nc = adimg.dist(pal[c], pal[keep]) <= adimg.dist(pal[c], pal[second]) and keep or second
      set(img, idx[k], nc)
    end
  end
end
local fixCell = M.fixCell

local function fixTouched(img, touched, color, set)
  for k in pairs(touched) do fixCell(img, k % img.w, floor(k / img.w), color, set) end
end

-- Paints one round brush stamp of `size` with `color` at (ux, uy).
-- native = true: ux/uy and the brush are in cells (whole cells are painted);
-- otherwise they are in pixels. dither 1..8 (8 = solid); with dithering and
-- a brush bigger than 2 the brush is soft (coverage fades towards the rim).
function M.stamp(img, ux, uy, color, native, size, dither, set)
  set = set or directSet
  local s = size
  local lo, hi = -floor((s - 1) / 2), floor(s / 2)
  local c = (s % 2 == 0) and 0.5 or 0
  local r2 = (s / 2) ^ 2
  local soft = dither < 8 and s > 2
  local full = dither * 2
  local bcx, bcy = ux + 0.5 + c, uy + 0.5 + c -- brush centre (brush units)
  local rim2 = (s / 2 + 0.5) ^ 2
  local function level(x, y) -- x, y: continuous position in brush units
    if not soft then return full end
    local d2 = (x - bcx) ^ 2 + (y - bcy) ^ 2
    return full * max(0, 1 - d2 / rim2)
  end
  local touched = {}
  for dy = lo, hi do
    for dx = lo, hi do
      local ex, ey = dx - c, dy - c
      if s <= 2 or ex * ex + ey * ey <= r2 then
        if native then
          local cx, cy = ux + dx, uy + dy
          if cx >= 0 and cy >= 0 and cx < img.w and cy < img.h then
            for py = cy * 3, cy * 3 + 2 do
              for pxx = cx * 2, cx * 2 + 1 do
                if ditherOn(pxx, py, level((pxx + 0.5) / 2, (py + 0.5) / 3)) then
                  set(img, py * img.pw + pxx + 1, color)
                end
              end
            end
            touched[cy * img.w + cx] = true
          end
        else
          local x, y = ux + dx, uy + dy
          if x >= 0 and y >= 0 and x < img.pw and y < img.ph and ditherOn(x, y, level(x + 0.5, y + 0.5)) then
            set(img, y * img.pw + x + 1, color)
            touched[floor(y / 3) * img.w + floor(x / 2)] = true
          end
        end
      end
    end
  end
  fixTouched(img, touched, color, set)
end

-- Calls fn(x, y) for every point of a line (Bresenham), both ends included.
function M.line(x0, y0, x1, y1, fn)
  local dx, dy = math.abs(x1 - x0), -math.abs(y1 - y0)
  local sx, sy = x0 < x1 and 1 or -1, y0 < y1 and 1 or -1
  local err = dx + dy
  while true do
    fn(x0, y0)
    if x0 == x1 and y0 == y1 then break end
    local e2 = 2 * err
    if e2 >= dy then err = err + dy; x0 = x0 + sx end
    if e2 <= dx then err = err + dx; y0 = y0 + sy end
  end
end

-- Fills the 4-connected area of pixel (x, y)'s colour with `color`.
function M.floodFill(img, x, y, color, set)
  set = set or directSet
  local pw, ph, px = img.pw, img.ph, img.px
  local start = y * pw + x
  local target = px[start + 1]
  if target == color then return end
  local seen, stack, region = { [start] = true }, { start }, {}
  while #stack > 0 do
    local p = stack[#stack]; stack[#stack] = nil
    region[#region + 1] = p
    local qx = p % pw
    local function try(q)
      if not seen[q] and px[q + 1] == target then seen[q] = true; stack[#stack + 1] = q end
    end
    if qx > 0 then try(p - 1) end
    if qx < pw - 1 then try(p + 1) end
    if p >= pw then try(p - pw) end
    if p < pw * (ph - 1) then try(p + pw) end
  end
  local touched = {}
  for _, p in ipairs(region) do
    local qx, qy = p % pw, floor(p / pw)
    set(img, p + 1, color)
    touched[floor(qy / 3) * img.w + floor(qx / 2)] = true
  end
  fixTouched(img, touched, color, set)
end

-- The colour covering most of a cell, and the pixel position (x, y) of
-- one pixel with that colour.
function M.cellMajority(img, cx, cy)
  local b = cy * 3 * img.pw + cx * 2
  local cnt, best, bc, bp = {}, nil, -1, nil
  for _, o in ipairs({ 0, 1, img.pw, img.pw + 1, 2 * img.pw, 2 * img.pw + 1 }) do
    local c = img.px[b + o + 1]
    cnt[c] = (cnt[c] or 0) + 1
    if cnt[c] > bc then best, bc, bp = c, cnt[c], b + o end
  end
  return best, bp % img.pw, floor(bp / img.pw)
end

---------------------------------------------------------------------------
-- Canvas size / scaling
---------------------------------------------------------------------------

-- Copies src's pixels into a new w x h image filled with `fill`, with the
-- source's top-left at cell offset (ox, oy). Returns the new image.
function M.placePixels(src, w, h, ox, oy, fill)
  local new = adimg.new(w, h, fill)
  for y = 0, new.ph - 1 do
    local sy = y - oy * 3
    if sy >= 0 and sy < src.ph then
      for x = 0, new.pw - 1 do
        local sx = x - ox * 2
        if sx >= 0 and sx < src.pw then new.px[y * new.pw + x + 1] = src.px[sy * src.pw + sx + 1] end
      end
    end
  end
  return new
end

-- Offset that puts a `size` wide thing at anchor `a` (0/0.5/1) in `space`.
function M.anchorOffset(space, size, a)
  return floor((space - size) * a + 0.5)
end

-- Moves text boxes by (dx, dy) cells, keeping them inside a w x h image.
function M.moveText(text, dx, dy, w, h)
  for _, b in ipairs(text) do
    b.x = max(1, min(w, b.x + dx))
    b.y = max(1, min(h, b.y + dy))
  end
end

-- Canvas resize (crop / extend) to nw x nh cells with the old image at
-- anchor (ax, ay); new area filled with `fill`. Returns the new pixel image
-- and a moved copy of the text layer (img itself is not changed).
function M.resizeCanvas(img, nw, nh, ax, ay, fill)
  local ox, oy = M.anchorOffset(nw, img.w, ax), M.anchorOffset(nh, img.h, ay)
  local new = M.placePixels(img, nw, nh, ox, oy, fill)
  local text = adimg.copyText(img.text)
  M.moveText(text, ox, oy, nw, nh)
  return new, text
end

-- Scales the image to exactly nw x nh cells (nearest neighbour), then makes
-- every cell 2-colour again. mode "fit" (bars in `fill`), "fill" (crop) or
-- "stretch" decides what happens when the aspect ratio changes; (ax, ay) is
-- the anchor. Returns the new pixel image and a moved copy of the text
-- layer (img itself is not changed).
function M.scale(img, nw, nh, mode, ax, ay, fill)
  local tw, th = nw * 2, nh * 3
  local dw, dh, ox, oy = adimg.fitRect(img.pw, img.ph, tw, th, mode, ax, ay)
  local new = adimg.new(nw, nh, fill)
  for y = 0, th - 1 do
    local yy = y - oy
    if yy >= 0 and yy < dh then
      local sy = min(img.ph - 1, floor((yy + 0.5) * img.ph / dh))
      for x = 0, tw - 1 do
        local xx = x - ox
        if xx >= 0 and xx < dw then
          local sx = min(img.pw - 1, floor((xx + 0.5) * img.pw / dw))
          new.px[y * tw + x + 1] = img.px[sy * img.pw + sx + 1]
        end
      end
    end
  end
  new.palette = img.palette
  for cy = 0, nh - 1 do
    for cx = 0, nw - 1 do fixCell(new, cx, cy, nil) end
  end
  local text = adimg.copyText(img.text)
  for _, b in ipairs(text) do
    -- map the box's top-left pixel and round to the nearest cell
    local px = (b.x - 1) * 2 * dw / img.pw + ox
    local py = (b.y - 1) * 3 * dh / img.ph + oy
    b.x = max(1, min(nw, floor(px / 2 + 0.5) + 1))
    b.y = max(1, min(nh, floor(py / 3 + 0.5) + 1))
  end
  return new, text
end

---------------------------------------------------------------------------
-- Text layer geometry
---------------------------------------------------------------------------

-- Width of a text box in cells (its longest line, at least 1).
function M.boxWidth(b)
  local w = 1
  for _, l in ipairs(b.lines) do w = max(w, #l) end
  return w
end
local boxWidth = M.boxWidth

-- The topmost text box covering cell (cx, cy) (0-based), and its index.
function M.boxAt(img, cx, cy)
  local text = img.text
  for i = #text, 1, -1 do
    local b = text[i]
    if cx + 1 >= b.x and cx + 1 < b.x + boxWidth(b) and cy + 1 >= b.y and cy + 1 < b.y + #b.lines then
      return b, i
    end
  end
end

-- Cells covered by the text layer: map[cy * w + cx] (0-based) =
-- { char, fg, bg or nil (transparent) }.
function M.textMap(img)
  local map = {}
  for _, b in ipairs(img.text) do
    for j, line in ipairs(b.lines) do
      local cy = b.y + j - 2
      for k = 1, (b.bg and boxWidth(b) or #line) do
        local cx = b.x + k - 2
        local ch = line:sub(k, k)
        if ch == "" then ch = " " end
        if cx >= 0 and cy >= 0 and cx < img.w and cy < img.h and (ch ~= " " or b.bg) then
          map[cy * img.w + cx] = { ch, b.fg, b.bg }
        end
      end
    end
  end
  return map
end

return M
