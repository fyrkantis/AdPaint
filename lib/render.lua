-- render: draws a window onto an adimg image (one with .px, as editing
-- needs) into term.blit rows, either natively (one cell per character,
-- teletext characters) or zoomed (every pixel zw x zh solid characters),
-- panned to any position. Also the coordinate maths for such a view, so a
-- program can map clicks back onto the image. Used by the adpaint editor's
-- canvas; any zoomable/pannable image viewer can use it too.
--
-- A view is { vx, vy, zw, zh, w, h }: (vx, vy) is the image pixel at the
-- top-left corner (may be negative), zw/zh the characters per pixel (nil
-- for native), w x h the size in characters. In native views vx is a
-- multiple of 2 and vy of 3 (use M.clamp).
local adimg = require("lib.formats.adimg")
local paint = require("lib.paint")

local M = {}
local floor, max, min = math.floor, math.max, math.min
local HEX = adimg.IDX_TO_HEX
local CHARS = {}
for i = 0, 31 do CHARS[i] = string.char(128 + i) end

---------------------------------------------------------------------------
-- Coordinates
---------------------------------------------------------------------------
-- Character (col, row), 0-based from the view's top-left -> pixel x, pixel
-- y, cell x, cell y. Native views only address whole cells (their
-- top-left pixel).
function M.toImage(v, col, row)
  if not v.zw then
    local cx, cy = v.vx / 2 + col, v.vy / 3 + row
    return cx * 2, cy * 3, cx, cy
  end
  local px, py = v.vx + floor(col / v.zw), v.vy + floor(row / v.zh)
  return px, py, floor(px / 2), floor(py / 3)
end

-- Cell (cx, cy) -> character (col, row), 0-based (its middle character
-- when zoomed).
function M.cellToView(v, cx, cy)
  if v.zw then
    return (cx * 2 - v.vx) * v.zw + v.zw, (cy * 3 - v.vy) * v.zh + floor(3 * v.zh / 2)
  end
  return cx - v.vx / 2, cy - v.vy / 3
end

-- Keeps at least a little of the image in view and snaps native views to
-- whole cells.
function M.clamp(v, img)
  local vwPx = v.zw and floor(v.w / v.zw) or v.w * 2
  local vhPx = v.zh and floor(v.h / v.zh) or v.h * 3
  v.vx = max(-vwPx + 2, min(v.vx, img.pw - 2))
  v.vy = max(-vhPx + 3, min(v.vy, img.ph - 3))
  if not v.zw then
    v.vx = floor(v.vx / 2) * 2
    v.vy = floor(v.vy / 3) * 3
  end
  return v
end

-- Changes the zoom to zw x zh (nil = native) keeping the pixel under
-- character (col, row) in place.
function M.zoom(v, img, zw, zh, col, row)
  local px, py = M.toImage(v, col, row)
  v.zw, v.zh = zw, zh
  if zw then v.vx, v.vy = px - floor(col / zw), py - floor(row / zh)
  else v.vx, v.vy = px - col * 2, py - row * 3 end
  return M.clamp(v, img)
end

-- Moves the view by dx, dy characters.
function M.pan(v, img, dx, dy)
  if v.zw then
    v.vx = v.vx + dx * max(1, floor(4 / v.zw))
    v.vy = v.vy + dy * max(1, floor(3 / v.zh))
  else
    v.vx, v.vy = v.vx + dx * 2, v.vy + dy * 3
  end
  return M.clamp(v, img)
end

-- Scrolls so that pixel (px, py) is in the middle.
function M.centreOn(v, img, px, py)
  local midX, midY = floor(v.w / 2), floor(v.h / 2)
  if v.zw then v.vx, v.vy = px - floor(midX / v.zw), py - floor(midY / v.zh)
  else v.vx, v.vy = px - midX * 2, py - midY * 3 end
  return M.clamp(v, img)
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------
local function nativeRows(img, v, tmap, voidF, voidB)
  local rows = {}
  local cx0, cy0 = v.vx / 2, v.vy / 3
  for row = 0, v.h - 1 do
    local cy = cy0 + row
    local t, f, b = {}, {}, {}
    for c = 0, v.w - 1 do
      local cx = cx0 + c
      if cx >= 0 and cy >= 0 and cx < img.w and cy < img.h then
        local tm = tmap[cy * img.w + cx]
        if tm then
          t[c + 1] = tm[1]; f[c + 1] = HEX[tm[2]]
          b[c + 1] = HEX[tm[3] or paint.cellMajority(img, cx, cy)]
        else
          local bits, fg, bg = adimg.encodeCell(img.px, img.pw, cx, cy)
          t[c + 1] = CHARS[bits]; f[c + 1] = HEX[fg]; b[c + 1] = HEX[bg]
        end
      else
        t[c + 1] = "\127"; f[c + 1] = voidF; b[c + 1] = voidB
      end
    end
    rows[row] = { t, f, b }
  end
  return rows
end

-- Thin frame around each text box for which frameColour(box) gives a
-- colour, drawn with drawing characters on the box's outermost characters.
local function drawFrames(img, v, rows, frameColour, contrast)
  local zw, zh = v.zw, v.zh
  for _, bx in ipairs(img.text) do
    local fcIdx = frameColour(bx)
    if fcIdx then
      local fc = HEX[fcIdx]
      local c0 = ((bx.x - 1) * 2 - v.vx) * zw
      local c1 = ((bx.x - 1 + paint.boxWidth(bx)) * 2 - v.vx) * zw - 1
      local r0 = ((bx.y - 1) * 3 - v.vy) * zh
      local r1 = ((bx.y - 1 + #bx.lines) * 3 - v.vy) * zh - 1
      for row = max(0, r0), min(v.h - 1, r1) do
        local r = rows[row]
        local T, B = row == r0, row == r1
        for c = max(0, c0), min(v.w - 1, c1) do
          local L, R = c == c0, c == c1
          if (L or R or T or B) and r[1][c + 1] == " " then
            local m = ((L or T) and 1 or 0) + ((R or T) and 2 or 0) + (L and 4 or 0)
              + (R and 8 or 0) + ((L or B) and 16 or 0) + ((R or B) and 32 or 0)
            local pix = r[3][c + 1]
            local f = fc == pix and HEX[contrast] or fc
            if m >= 32 then -- bottom-right sub-pixel is always background
              r[1][c + 1] = CHARS[63 - m]; r[2][c + 1] = pix; r[3][c + 1] = f
            else
              r[1][c + 1] = CHARS[m]; r[2][c + 1] = f
            end
          end
        end
      end
    end
  end
end

local function zoomedRows(img, v, tmap, voidF, voidB, opts)
  local zw, zh = v.zw, v.zh
  local rows = {}
  for row = 0, v.h - 1 do
    local py = v.vy + floor(row / zh)
    local t, f, b = {}, {}, {}
    for c = 0, v.w - 1 do
      local px = v.vx + floor(c / zw)
      if px >= 0 and py >= 0 and px < img.pw and py < img.ph then
        local cl = img.px[py * img.pw + px + 1]
        local tm = tmap[floor(py / 3) * img.w + floor(px / 2)]
        if tm and tm[3] then cl = tm[3] end
        t[c + 1] = " "; f[c + 1] = "0"; b[c + 1] = HEX[cl]
      else
        t[c + 1] = "\127"; f[c + 1] = voidF; b[c + 1] = voidB
      end
    end
    rows[row] = { t, f, b }
  end
  if opts.frameColour then drawFrames(img, v, rows, opts.frameColour, opts.contrast or 0) end
  -- letters: one character in the middle of each text cell
  for k, tm in pairs(tmap) do
    local cx, cy = k % img.w, floor(k / img.w)
    local c = (cx * 2 - v.vx) * zw + zw
    local row = (cy * 3 - v.vy) * zh + floor(3 * zh / 2)
    local r = rows[row]
    if r and c >= 0 and c < v.w then
      r[1][c + 1] = tm[1]; r[2][c + 1] = HEX[tm[2]]
    end
  end
  return rows
end

-- Renders the view. Returns rows[1..v.h] = { text, fg, bg } blit strings.
-- opts (all optional):
--   text         draw the text layer (default true)
--   void         { fg, bg } colour indices for the area outside the image
--                (drawn with character 127), default gray on black
--   frameColour  function(box) -> colour index or nil: frames around text
--                boxes in zoomed views; contrast = colour used instead
--                where the frame would vanish into the pixel under it
function M.rows(img, v, opts)
  opts = opts or {}
  local tmap = opts.text == false and {} or paint.textMap(img)
  local void = opts.void or { 7, 15 }
  local voidF, voidB = HEX[void[1]], HEX[void[2]]
  local rows = v.zw and zoomedRows(img, v, tmap, voidF, voidB, opts) or nativeRows(img, v, tmap, voidF, voidB)
  local out = {}
  for row = 0, v.h - 1 do
    local r = rows[row]
    out[row + 1] = { table.concat(r[1]), table.concat(r[2]), table.concat(r[3]) }
  end
  return out
end

-- Draws the view on `target` (a term-like object) with its top-left
-- corner at (x, y).
function M.draw(target, x, y, img, v, opts)
  for i, r in ipairs(M.rows(img, v, opts)) do
    target.setCursorPos(x, y + i - 1)
    target.blit(r[1], r[2], r[3])
  end
end

return M
