-- adimg: the ".adi" advertisement image format for CC: Tweaked.
--
-- An image is W x H "cells". Every cell is one terminal character showing a
-- 2x3 grid of pixels using the teletext/drawing characters (128-159), so it
-- can only hold two colours: the character's foreground and background.
--
-- File layout (plain ASCII, one record per line, safe for pastebin/wget):
--
--   ADIMG 1
--   size <w> <h>
--   palette <16 x RRGGBB>           (optional; omitted = default CC palette)
--   text <x> <y> <fg> <bg> <n>      (one per text box; fg/bg are hex digits,
--   <line 1>                         bg "-" = transparent; followed by n lines)
--   ...
--   data
--   <chars> <fg> <bg>               (3 lines per cell row, see below)
--   ...
--
-- Each cell row is stored as three strings of exactly W characters which map
-- directly onto term.blit(): the pixel pattern (base32 digit 0-v = bits of the
-- top-left, top-right, mid-left, mid-right, bottom-left pixel being
-- foreground; the bottom-right pixel is always background), the foreground
-- hex colours and the background hex colours. Turning the pattern row into a
-- real blit string is a single string.gsub, so a player can display an image
-- with three string operations per row and no per-pixel Lua work.

local M = {}

M.VERSION = 1
M.HEX = "0123456789abcdef"
M.B32 = "0123456789abcdefghijklmnopqrstuv"

-- Default CC: Tweaked palette, indexed 0..15 (colour = 2^index).
M.DEFAULT_PALETTE = {
  [0] = 0xF0F0F0, 0xF2B233, 0xE57FD8, 0x99B2F2,
  0xDEDE6C, 0x7FCC19, 0xF2B2CC, 0x4C4C4C,
  0x999999, 0x4C99B2, 0xB266E5, 0x3366CC,
  0x7F664C, 0x57A64E, 0xCC4C4C, 0x111111,
}

local HEX, B32 = M.HEX, M.B32
local sub, char, byte, concat = string.sub, string.char, string.byte, table.concat
local floor = math.floor

-- lookup tables
local B32_TO_CHAR, B32_TO_BITS, BITS_TO_B32 = {}, {}, {}
local HEX_TO_IDX, IDX_TO_HEX = {}, {}
local POPCOUNT = {}
for i = 0, 31 do
  local c = sub(B32, i + 1, i + 1)
  B32_TO_CHAR[c] = char(128 + i)
  B32_TO_BITS[c] = i
  BITS_TO_B32[i] = c
  local n, v = 0, i
  while v > 0 do n = n + v % 2; v = floor(v / 2) end
  POPCOUNT[i] = n
end
for i = 0, 15 do
  local c = sub(HEX, i + 1, i + 1)
  HEX_TO_IDX[c] = i
  IDX_TO_HEX[i] = c
end
M.B32_TO_CHAR, M.B32_TO_BITS, M.BITS_TO_B32 = B32_TO_CHAR, B32_TO_BITS, BITS_TO_B32
M.HEX_TO_IDX, M.IDX_TO_HEX = HEX_TO_IDX, IDX_TO_HEX

---------------------------------------------------------------------------
-- Construction / pixel access
---------------------------------------------------------------------------

-- Pixels are stored in a flat 1-based array, pixel (x, y) (0-based, in
-- pixel coordinates) at px[y * pw + x + 1], values are colour indices 0..15.
function M.new(w, h, color)
  color = color or 0
  local img = { w = w, h = h, pw = w * 2, ph = h * 3, px = {}, text = {} }
  local px = img.px
  for i = 1, img.pw * img.ph do px[i] = color end
  return img
end

function M.get(img, x, y)
  if x < 0 or y < 0 or x >= img.pw or y >= img.ph then return nil end
  return img.px[y * img.pw + x + 1]
end

-- Returns pattern bits (0..31), fg index, bg index for one cell.
local function encodeCell(px, pw, cx, cy)
  local i = cy * 3 * pw + cx * 2 + 1
  local p1, p2 = px[i], px[i + 1]
  local p3, p4 = px[i + pw], px[i + pw + 1]
  local p5, p6 = px[i + 2 * pw], px[i + 2 * pw + 1]
  local bg, fg = p6, p6
  local bits = 0
  if p1 ~= bg then fg = p1; bits = bits + 1 end
  if p2 ~= bg then fg = p2; bits = bits + 2 end
  if p3 ~= bg then fg = p3; bits = bits + 4 end
  if p4 ~= bg then fg = p4; bits = bits + 8 end
  if p5 ~= bg then fg = p5; bits = bits + 16 end
  return bits, fg, bg
end
M.encodeCell = encodeCell

-- Builds the stored row representation from the pixel array.
function M.rowsFromPixels(img)
  local rows = {}
  local px, pw = img.px, img.pw
  for cy = 0, img.h - 1 do
    local b, f, g = {}, {}, {}
    for cx = 0, img.w - 1 do
      local bits, fg, bg = encodeCell(px, pw, cx, cy)
      b[cx + 1] = BITS_TO_B32[bits]; f[cx + 1] = IDX_TO_HEX[fg]; g[cx + 1] = IDX_TO_HEX[bg]
    end
    rows[cy + 1] = { concat(b), concat(f), concat(g) }
  end
  img.rows = rows
  return rows
end

-- Rebuilds the pixel array from stored rows.
function M.pixelsFromRows(img)
  local px, pw = {}, img.w * 2
  img.pw, img.ph, img.px = pw, img.h * 3, px
  for cy = 0, img.h - 1 do
    local row = img.rows[cy + 1]
    local bs, fs, gs = row[1], row[2], row[3]
    for cx = 0, img.w - 1 do
      local bits = B32_TO_BITS[sub(bs, cx + 1, cx + 1)] or 0
      local fg = HEX_TO_IDX[sub(fs, cx + 1, cx + 1)] or 0
      local bg = HEX_TO_IDX[sub(gs, cx + 1, cx + 1)] or 15
      local i = cy * 3 * pw + cx * 2 + 1
      px[i]            = bits % 2 >= 1 and fg or bg
      px[i + 1]        = bits % 4 >= 2 and fg or bg
      px[i + pw]       = bits % 8 >= 4 and fg or bg
      px[i + pw + 1]   = bits % 16 >= 8 and fg or bg
      px[i + 2 * pw]   = bits >= 16 and fg or bg
      px[i + 2*pw + 1] = bg
    end
  end
  return px
end

---------------------------------------------------------------------------
-- Serialisation
---------------------------------------------------------------------------

function M.serialize(img)
  local rows = M.rowsFromPixels(img)
  local out = { "ADIMG " .. M.VERSION, "size " .. img.w .. " " .. img.h }
  if img.palette then
    local p = {}
    for i = 0, 15 do p[#p + 1] = string.format("%06x", img.palette[i]) end
    out[#out + 1] = "palette " .. concat(p, " ")
  end
  for _, box in ipairs(img.text) do
    out[#out + 1] = string.format("text %d %d %s %s %d", box.x, box.y,
      IDX_TO_HEX[box.fg], box.bg and IDX_TO_HEX[box.bg] or "-", #box.lines)
    for _, l in ipairs(box.lines) do out[#out + 1] = l end
  end
  out[#out + 1] = "data"
  for _, r in ipairs(rows) do
    out[#out + 1] = r[1]; out[#out + 1] = r[2]; out[#out + 1] = r[3]
  end
  out[#out + 1] = ""
  return concat(out, "\n")
end

-- Parses a file's contents. Returns img (with .rows; pass wantPixels to also
-- build .px for editing) or nil, error.
function M.parse(s, wantPixels)
  local lines = {}
  for l in (s:gsub("\r", "") .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = l end
  if not lines[1] or not lines[1]:match("^ADIMG %d+") then return nil, "not an ADIMG file" end
  local img = { text = {}, rows = {} }
  local i = 2
  while i <= #lines do
    local l = lines[i]
    local key = l:match("^(%S+)")
    if key == "size" then
      local w, h = l:match("^size (%d+) (%d+)")
      img.w, img.h = tonumber(w), tonumber(h)
    elseif key == "palette" then
      local p, n = {}, 0
      for hx in l:gmatch("%x%x%x%x%x%x") do p[n] = tonumber(hx, 16); n = n + 1 end
      if n == 16 then img.palette = p end
    elseif key == "text" then
      local x, y, fg, bg, n = l:match("^text (%-?%d+) (%-?%d+) (%x) (%S) (%d+)")
      if not x then return nil, "bad text record on line " .. i end
      local box = { x = tonumber(x), y = tonumber(y), fg = HEX_TO_IDX[fg:lower()],
                    bg = HEX_TO_IDX[bg:lower()], lines = {} }
      for j = 1, tonumber(n) do box.lines[j] = lines[i + j] or "" end
      img.text[#img.text + 1] = box
      i = i + tonumber(n)
    elseif key == "data" then
      if not img.w then return nil, "missing size" end
      for cy = 1, img.h do
        local b, f, g = lines[i + 1] or "", lines[i + 2] or "", lines[i + 3] or ""
        -- pad short/corrupt rows so blit never errors
        if #b ~= img.w then b = (b .. ("0"):rep(img.w)):sub(1, img.w) end
        if #f ~= img.w then f = (f .. ("0"):rep(img.w)):sub(1, img.w) end
        if #g ~= img.w then g = (g .. ("f"):rep(img.w)):sub(1, img.w) end
        img.rows[cy] = { b, f, g }
        i = i + 3
      end
      break
    end
    i = i + 1
  end
  if not img.w then return nil, "missing size" end
  img.pw, img.ph = img.w * 2, img.h * 3
  if wantPixels then M.pixelsFromRows(img) end
  return img
end

function M.save(img, path)
  local data = M.serialize(img)
  local f, err = fs.open(path, "wb")
  if not f then return nil, err end
  f.write(data)
  f.close()
  return true
end

function M.load(path, wantPixels)
  local f, err = fs.open(path, "rb")
  if not f then return nil, err end
  local s = f.readAll() or ""
  f.close()
  return M.parse(s, wantPixels)
end

---------------------------------------------------------------------------
-- Display
---------------------------------------------------------------------------

local function textBg(box, bits, fgHex, bgHex)
  if box.bg then return IDX_TO_HEX[box.bg] end
  -- transparent: use whichever colour covers most of the cell
  return POPCOUNT[bits] > 3 and fgHex or bgHex
end

-- Returns a list of blit triples {text, fg, bg}, one per cell row, with the
-- text layer applied (unless showText == false). Requires img.rows.
function M.compose(img, showText)
  local out = {}
  local rows = img.rows
  for cy = 1, img.h do
    local r = rows[cy]
    out[cy] = { (r[1]:gsub(".", B32_TO_CHAR)), r[2], r[3] }
  end
  if showText == false or #img.text == 0 then return out end
  -- overlay text: work on per-row character arrays only for touched rows
  local touched = {}
  for _, box in ipairs(img.text) do
    local boxW = 1
    for _, l in ipairs(box.lines) do if #l > boxW then boxW = #l end end
    for j, line in ipairs(box.lines) do
      local cy = box.y + j - 1
      if cy >= 1 and cy <= img.h then
        local t = touched[cy]
        if not t then
          local r = rows[cy]
          t = { {}, {}, {}, bits = {} }
          for cx = 1, img.w do
            local bc = sub(r[1], cx, cx)
            t.bits[cx] = B32_TO_BITS[bc] or 0
            t[1][cx] = B32_TO_CHAR[bc] or " "
            t[2][cx] = sub(r[2], cx, cx); t[3][cx] = sub(r[3], cx, cx)
          end
          touched[cy] = t
        end
        for k = 1, box.bg and boxW or #line do
          local cx = box.x + k - 1
          local ch = sub(line, k, k)
          if ch == "" then ch = " " end
          if cx >= 1 and cx <= img.w and (ch ~= " " or box.bg) then
            local nb = textBg(box, t.bits[cx], t[2][cx], t[3][cx])
            t[1][cx] = ch; t[2][cx] = IDX_TO_HEX[box.fg]; t[3][cx] = nb
          end
        end
      end
    end
  end
  for cy, t in pairs(touched) do out[cy] = { concat(t[1]), concat(t[2]), concat(t[3]) } end
  return out
end

-- Draws an image at (x, y) on a terminal-like object (term, monitor, window).
-- Pass a precomposed list from M.compose() as `composed` to avoid rework.
function M.draw(img, target, x, y, composed)
  target = target or term
  x, y = x or 1, y or 1
  composed = composed or M.compose(img)
  for cy = 1, #composed do
    local r = composed[cy]
    target.setCursorPos(x, y + cy - 1)
    target.blit(r[1], r[2], r[3])
  end
end

function M.applyPalette(target, palette)
  palette = palette or M.DEFAULT_PALETTE
  for i = 0, 15 do target.setPaletteColour(2 ^ i, palette[i]) end
end

-- Colour helpers -----------------------------------------------------------

function M.rgb(c) return floor(c / 65536) % 256, floor(c / 256) % 256, c % 256 end

-- Perceptually weighted squared distance between two 0xRRGGBB colours.
function M.dist(a, b)
  local ar, ag, ab = M.rgb(a)
  local br, bg, bb = M.rgb(b)
  local dr, dg, db = ar - br, ag - bg, ab - bb
  local rm = (ar + br) / 2
  return (2 + rm / 256) * dr * dr + 4 * dg * dg + (2 + (255 - rm) / 256) * db * db
end

-- Where a sw x sh picture goes in a tw x th area (any units, e.g. pixels):
--   "stretch" fills the area exactly, "fit" keeps the aspect ratio and
--   leaves bars, "fill" keeps the aspect ratio and crops the overflow.
-- ax/ay (0, 0.5, 1) anchor the picture in the area. Returns integer
-- dw, dh (scaled size) and ox, oy (offset; negative when cropping).
function M.fitRect(sw, sh, tw, th, mode, ax, ay)
  if mode ~= "fit" and mode ~= "fill" then return tw, th, 0, 0 end
  local s = (mode == "fit" and math.min or math.max)(tw / sw, th / sh)
  local dw, dh = math.max(1, floor(sw * s + 0.5)), math.max(1, floor(sh * s + 0.5))
  if mode == "fit" then dw, dh = math.min(dw, tw), math.min(dh, th)
  else dw, dh = math.max(dw, tw), math.max(dh, th) end
  return dw, dh, floor((tw - dw) * (ax or 0.5) + 0.5), floor((th - dh) * (ay or 0.5) + 0.5)
end

-- Deep copy of a text layer (used for undo).
function M.copyText(text)
  local t = {}
  for i, b in ipairs(text) do
    local lines = {}
    for j, l in ipairs(b.lines) do lines[j] = l end
    t[i] = { x = b.x, y = b.y, fg = b.fg, bg = b.bg, lines = lines }
  end
  return t
end

return M
