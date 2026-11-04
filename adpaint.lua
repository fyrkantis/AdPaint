-- adpaint: image editor for .adi advertisement images (CC: Tweaked).
--
-- Usage: adpaint [file ...] [-m <monitor side> [-s <text scale>]]
--   No files opens a blank canvas. PNG/JPEG/BMP files are imported.
--   Drag & drop image files onto the computer window to import them.
--   -m paints on an advanced monitor (touch) while you type on the computer.

local progDir = fs.getDir(shell.getRunningProgram())
package.path = "/" .. fs.combine(progDir, "?.lua") .. ";" .. package.path
local adimg = require("lib.adimg")
local convert -- loaded on first import (keeps start-up light)

local floor, max, min = math.floor, math.max, math.min
local HEX = adimg.IDX_TO_HEX

---------------------------------------------------------------------------
-- Arguments / display set-up
---------------------------------------------------------------------------
local args = { ... }
local files, monSide, monScale = {}, nil, 0.5
do
  local i = 1
  while i <= #args do
    if args[i] == "-m" then monSide = args[i + 1]; i = i + 2
    elseif args[i] == "-s" then monScale = tonumber(args[i + 1]) or 0.5; i = i + 2
    else files[#files + 1] = args[i]; i = i + 1 end
  end
end

local display = term.current()
if monSide then
  local mon = peripheral.wrap(monSide)
  if not (mon and mon.isColour and mon.isColour()) then
    printError("No advanced monitor on side '" .. tostring(monSide) .. "'"); return
  end
  mon.setTextScale(monScale)
  display = mon
elseif not term.isColour() then
  printError("adpaint needs an advanced computer (colour + mouse)"); return
end

local W, H = display.getSize()
local win = window.create(display, 1, 1, W, H, true)
local oldTerm = term.redirect(win)

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local docs, cur = {}, 1
local tool = "brush"
local primary, secondary = 15, 0 -- black / white
local brushSize, dither = 1, 8   -- dither: 1..8 (8 = solid)
local showText = true
local ctrl, shift = false, false
local running = true
local status, statusUntil = nil, 0
local menuOpen = false
local sel = nil   -- text selection {box=, line=, col=}
local drag = nil  -- active mouse drag
local op = nil    -- undo operation being recorded

-- Zoom levels: chars per pixel (zw x zh). Level 1 is native teletext.
local ZOOMS = {
  { name = "1x" },
  { name = "4x", zw = 2, zh = 2 }, -- a cell becomes 4x6 chars
  { name = "6x", zw = 3, zh = 2 }, -- a cell becomes 6x6 chars (square pixels)
}

local BAYER = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 }

local ui = {}
local CHARS = {}
for i = 0, 31 do CHARS[i] = string.char(128 + i) end

local function doc() return docs[cur] end
local function palette(d) return (d or doc()).img.palette or adimg.DEFAULT_PALETTE end

local function setStatus(msg, secs)
  status = msg
  statusUntil = os.clock() + (secs or 4)
end

---------------------------------------------------------------------------
-- UI colours: pick the palette entries closest to the colours we want so
-- the interface stays readable with custom image palettes.
---------------------------------------------------------------------------
local function computeUi()
  local pal = palette()
  local function nearest(rgb, avoid)
    local best, bd = 0, math.huge
    for i = 0, 15 do
      if i ~= avoid then
        local d = adimg.dist(pal[i], rgb)
        if d < bd then best, bd = i, d end
      end
    end
    return best
  end
  ui.dark = nearest(0x111111)
  ui.bar = nearest(0x3C3C3C, ui.dark)
  ui.text = nearest(0xF0F0F0, ui.bar)
  ui.dim = nearest(0x999999, ui.bar)
  ui.accent = nearest(0x3366CC, ui.bar)
  ui.hi = nearest(0xDEDE6C, ui.bar)
  ui.void = nearest(0x262626)
end

local function applyPalette()
  adimg.applyPalette(win, palette())
  computeUi()
end

---------------------------------------------------------------------------
-- Documents
---------------------------------------------------------------------------
local function viewH() return H - 3 end

local function newDoc(img, path)
  return { img = img, path = path, dirty = false, zoom = 1, vx = 0, vy = 0, undo = {}, redo = {} }
end

local function docName(d)
  return d.path and fs.getName(d.path) or "untitled"
end

local function addDoc(d)
  docs[#docs + 1] = d
  cur = #docs
  sel = nil
  applyPalette()
end

local function blankDoc(w, h)
  return newDoc(adimg.new(w or W, h or viewH(), secondary))
end

---------------------------------------------------------------------------
-- Undo / redo (operations swap old <-> current state, so applying an op
-- twice is a no-op; undo and redo are the same function)
---------------------------------------------------------------------------
local function snapshot(img)
  return { w = img.w, h = img.h, pw = img.pw, ph = img.ph, px = img.px, text = img.text, palette = img.palette }
end
local function restore(img, s)
  img.w, img.h, img.pw, img.ph, img.px, img.text, img.palette = s.w, s.h, s.pw, s.ph, s.px, s.text, s.palette
end

local function beginOp(kind)
  local d = doc()
  op = { pix = {}, doc = d }
  if kind == "text" then op.text = adimg.copyText(d.img.text) end
  if kind == "full" then op.full = snapshot(d.img); op.changed = true end
end

local function endOp()
  if op and op.changed then
    local d = op.doc
    table.insert(d.undo, op)
    if #d.undo > 64 then table.remove(d.undo, 1) end
    d.redo = {}
    d.dirty = true
  end
  op = nil
end

local function swapOp(o, d)
  local img = d.img
  if o.full then local s = snapshot(img); restore(img, o.full); o.full = s end
  local px = img.px
  for i, v in pairs(o.pix) do o.pix[i] = px[i]; px[i] = v end
  if o.text then local t = img.text; img.text = o.text; o.text = t end
end

local deselect -- defined with the text box code below

local function undo(redo)
  local d = doc()
  deselect()
  endOp()
  local from, to = redo and d.redo or d.undo, redo and d.undo or d.redo
  local o = table.remove(from)
  if not o then setStatus(redo and "Nothing to redo" or "Nothing to undo"); return end
  swapOp(o, d)
  table.insert(to, o)
  d.dirty = true
  applyPalette()
end

---------------------------------------------------------------------------
-- Painting
---------------------------------------------------------------------------
local function setPx(img, i, c)
  local old = img.px[i]
  if old ~= c then
    if op and op.pix[i] == nil then op.pix[i] = old end
    if op then op.changed = true end
    img.px[i] = c
  end
end

local function ditherOn(x, y)
  return BAYER[(y % 4) * 4 + x % 4 + 1] < dither * 2
end

-- Restores the "max 2 colours per cell" rule after painting `keep`.
local function fixCell(img, cx, cy, keep)
  if cx < 0 or cy < 0 or cx >= img.w or cy >= img.h then return end
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
      setPx(img, idx[k], nc)
    end
  end
end

-- Paints one brush stamp. In native (1x) view the mouse can only address
-- whole cells, so ux/uy are cells and the brush paints whole cells; in the
-- zoomed views ux/uy are pixels.
local function stamp(ux, uy, color, native)
  local img = doc().img
  local s = brushSize
  local lo, hi = -floor((s - 1) / 2), floor(s / 2)
  local c = (s % 2 == 0) and 0.5 or 0
  local r2 = (s / 2) ^ 2
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
                if ditherOn(pxx, py) then setPx(img, py * img.pw + pxx + 1, color) end
              end
            end
            touched[cy * img.w + cx] = true
          end
        else
          local x, y = ux + dx, uy + dy
          if x >= 0 and y >= 0 and x < img.pw and y < img.ph and ditherOn(x, y) then
            setPx(img, y * img.pw + x + 1, color)
            touched[floor(y / 3) * img.w + floor(x / 2)] = true
          end
        end
      end
    end
  end
  for k in pairs(touched) do fixCell(img, k % img.w, floor(k / img.w), color) end
end

local function strokeLine(x0, y0, x1, y1, color, native)
  local dx, dy = math.abs(x1 - x0), -math.abs(y1 - y0)
  local sx, sy = x0 < x1 and 1 or -1, y0 < y1 and 1 or -1
  local err = dx + dy
  while true do
    stamp(x0, y0, color, native)
    if x0 == x1 and y0 == y1 then break end
    local e2 = 2 * err
    if e2 >= dy then err = err + dy; x0 = x0 + sx end
    if e2 <= dx then err = err + dx; y0 = y0 + sy end
  end
end

local function floodFill(x, y, color)
  local img = doc().img
  local pw, ph, px = img.pw, img.ph, img.px
  local start = y * pw + x
  local target = px[start + 1]
  if target == color and dither == 8 then return end
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
    if ditherOn(qx, qy) then
      setPx(img, p + 1, color)
      touched[floor(qy / 3) * img.w + floor(qx / 2)] = true
    end
  end
  for k in pairs(touched) do fixCell(img, k % img.w, floor(k / img.w), color) end
end

-- The colour covering most of a cell, and one pixel of that colour.
local function cellMajority(img, cx, cy)
  local b = cy * 3 * img.pw + cx * 2
  local cnt, best, bc, bp = {}, nil, -1, nil
  for k, o in ipairs({ 0, 1, img.pw, img.pw + 1, 2 * img.pw, 2 * img.pw + 1 }) do
    local c = img.px[b + o + 1]
    cnt[c] = (cnt[c] or 0) + 1
    if cnt[c] > bc then best, bc, bp = c, cnt[c], b + o end
  end
  return best, bp % img.pw, floor(bp / img.pw)
end

---------------------------------------------------------------------------
-- View / coordinate mapping
---------------------------------------------------------------------------
local function zoomInfo(d) return ZOOMS[d.zoom] end

-- Screen position -> (pixel x, pixel y, cell x, cell y); y=2 is the first
-- canvas row.
local function screenToImage(sx, sy)
  local d = doc()
  local z = zoomInfo(d)
  if not z.zw then
    local cx, cy = d.vx / 2 + sx - 1, d.vy / 3 + sy - 2
    return cx * 2, cy * 3, cx, cy
  end
  local px = d.vx + floor((sx - 1) / z.zw)
  local py = d.vy + floor((sy - 2) / z.zh)
  return px, py, floor(px / 2), floor(py / 3)
end

local function clampView(d)
  local z = zoomInfo(d)
  local vwPx = z.zw and floor(W / z.zw) or W * 2
  local vhPx = z.zh and floor(viewH() / z.zh) or viewH() * 3
  d.vx = max(-vwPx + 2, min(d.vx, d.img.pw - 2))
  d.vy = max(-vhPx + 3, min(d.vy, d.img.ph - 3))
  if not z.zw then
    d.vx = floor(d.vx / 2) * 2
    d.vy = floor(d.vy / 3) * 3
  end
end

local function setZoom(level, cxs, cys)
  local d = doc()
  -- keep the pixel under (cxs, cys) (or the view centre) in place
  cxs, cys = cxs or floor(W / 2), cys or floor(viewH() / 2) + 2
  local px, py = screenToImage(cxs, cys)
  d.zoom = level
  local z = zoomInfo(d)
  if z.zw then
    d.vx = px - floor((cxs - 1) / z.zw)
    d.vy = py - floor((cys - 2) / z.zh)
  else
    d.vx = px - (cxs - 1) * 2
    d.vy = py - (cys - 2) * 3
  end
  clampView(d)
end

local function pan(dx, dy) -- in screen characters
  local d = doc()
  local z = zoomInfo(d)
  if z.zw then
    d.vx = d.vx + dx * max(1, floor(4 / z.zw))
    d.vy = d.vy + dy * max(1, floor(3 / z.zh))
  else
    d.vx, d.vy = d.vx + dx * 2, d.vy + dy * 3
  end
  clampView(d)
end

---------------------------------------------------------------------------
-- Text boxes
---------------------------------------------------------------------------
local function boxWidth(b)
  local w = 1
  for _, l in ipairs(b.lines) do w = max(w, #l) end
  return w
end

local function boxAt(cx, cy) -- cx, cy 0-based cells
  local text = doc().img.text
  for i = #text, 1, -1 do
    local b = text[i]
    if cx + 1 >= b.x and cx + 1 < b.x + boxWidth(b) and cy + 1 >= b.y and cy + 1 < b.y + #b.lines then
      return b, i
    end
  end
end

function deselect()
  if not sel then return end
  local text = doc().img.text
  local empty = true
  for _, l in ipairs(sel.box.lines) do if l:find("%S") then empty = false end end
  if empty and not sel.box.bg then
    for i, b in ipairs(text) do if b == sel.box then table.remove(text, i); break end end
  end
  sel = nil
  endOp()
end

local function selectBox(b, line, col)
  if sel and sel.box == b then sel.line, sel.col = line, col; return end
  deselect()
  beginOp("text")
  -- the op snapshot holds copies, so keep editing the live box
  sel = { box = b, line = line, col = col }
end

local function textChanged() if op then op.changed = true end end

local function textInsert(s)
  local b = sel.box
  local l = b.lines[sel.line]
  b.lines[sel.line] = l:sub(1, sel.col) .. s .. l:sub(sel.col + 1)
  sel.col = sel.col + #s
  textChanged()
end

local function textKey(k)
  local b = sel.box
  local lines = b.lines
  local l = lines[sel.line]
  if k == keys.backspace then
    if sel.col > 0 then
      lines[sel.line] = l:sub(1, sel.col - 1) .. l:sub(sel.col + 1); sel.col = sel.col - 1
    elseif sel.line > 1 then
      local prev = lines[sel.line - 1]
      sel.col = #prev
      lines[sel.line - 1] = prev .. l
      table.remove(lines, sel.line); sel.line = sel.line - 1
    end
    textChanged()
  elseif k == keys.delete then
    if sel.col < #l then lines[sel.line] = l:sub(1, sel.col) .. l:sub(sel.col + 2)
    elseif sel.line < #lines then
      lines[sel.line] = l .. lines[sel.line + 1]; table.remove(lines, sel.line + 1)
    end
    textChanged()
  elseif k == keys.enter or k == keys.numPadEnter then
    lines[sel.line] = l:sub(1, sel.col)
    table.insert(lines, sel.line + 1, l:sub(sel.col + 1))
    sel.line, sel.col = sel.line + 1, 0
    textChanged()
  elseif k == keys.left then sel.col = max(0, sel.col - 1)
  elseif k == keys.right then sel.col = min(#l, sel.col + 1)
  elseif k == keys.up and sel.line > 1 then sel.line = sel.line - 1; sel.col = min(sel.col, #lines[sel.line])
  elseif k == keys.down and sel.line < #lines then sel.line = sel.line + 1; sel.col = min(sel.col, #lines[sel.line])
  elseif k == keys.home then sel.col = 0
  elseif k == keys["end"] then sel.col = #l
  elseif k == keys.tab then deselect()
  else return false end
  return true
end

local function deleteSelectedBox()
  if not sel then return end
  local text = doc().img.text
  for i, b in ipairs(text) do if b == sel.box then table.remove(text, i); break end end
  textChanged()
  sel = nil
  endOp()
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------
local function fill(s, n) return string.rep(s, n) end

local function blitAt(x, y, text, fg, bg)
  win.setCursorPos(x, y)
  win.blit(text, fill(HEX[fg], #text), fill(HEX[bg], #text))
end

-- text layer lookup: key cy*w+cx (0-based) -> {ch, fg, bg|nil}
local function textMap(img)
  local map = {}
  if not showText then return map end
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

local function drawCanvas()
  local d = doc()
  local img = d.img
  local z = zoomInfo(d)
  local tmap = textMap(img)
  local voidC, voidB = HEX[ui.bar], HEX[ui.void]
  local vh = viewH()
  if not z.zw then
    local cx0, cy0 = d.vx / 2, d.vy / 3
    for row = 0, vh - 1 do
      local cy = cy0 + row
      local t, f, b = {}, {}, {}
      for col = 0, W - 1 do
        local cx = cx0 + col
        if cx >= 0 and cy >= 0 and cx < img.w and cy < img.h then
          local tm = tmap[cy * img.w + cx]
          if tm then
            t[col + 1] = tm[1]; f[col + 1] = HEX[tm[2]]
            b[col + 1] = HEX[tm[3] or cellMajority(img, cx, cy)]
          else
            local bits, fg, bg = adimg.encodeCell(img.px, img.pw, cx, cy)
            t[col + 1] = CHARS[bits]; f[col + 1] = HEX[fg]; b[col + 1] = HEX[bg]
          end
        else
          t[col + 1] = "\127"; f[col + 1] = voidC; b[col + 1] = voidB
        end
      end
      win.setCursorPos(1, row + 2)
      win.blit(table.concat(t), table.concat(f), table.concat(b))
    end
  else
    local zw, zh = z.zw, z.zh
    local rows = {}
    for row = 0, vh - 1 do
      local py = d.vy + floor(row / zh)
      local t, f, b = {}, {}, {}
      for col = 0, W - 1 do
        local px = d.vx + floor(col / zw)
        if px >= 0 and py >= 0 and px < img.pw and py < img.ph then
          local c = img.px[py * img.pw + px + 1]
          local tm = tmap[floor(py / 3) * img.w + floor(px / 2)]
          if tm and tm[3] then c = tm[3] end
          t[col + 1] = " "; f[col + 1] = "0"; b[col + 1] = HEX[c]
        else
          t[col + 1] = "\127"; f[col + 1] = voidC; b[col + 1] = voidB
        end
      end
      rows[row] = { t, f, b }
    end
    -- letters: one character in the middle of each text cell
    for k, tm in pairs(tmap) do
      local cx, cy = k % img.w, floor(k / img.w)
      local col = (cx * 2 - d.vx) * zw + zw
      local row = (cy * 3 - d.vy) * zh + floor(3 * zh / 2)
      local r = rows[row]
      if r and col >= 0 and col < W then
        r[1][col + 1] = tm[1]; r[2][col + 1] = HEX[tm[2]]
      end
    end
    for row = 0, vh - 1 do
      local r = rows[row]
      win.setCursorPos(1, row + 2)
      win.blit(table.concat(r[1]), table.concat(r[2]), table.concat(r[3]))
    end
  end
end

local tabHits, toolHits = {}, {}

local function drawTabs()
  win.setCursorPos(1, 1)
  win.setBackgroundColour(2 ^ ui.dark); win.clearLine()
  tabHits = {}
  blitAt(1, 1, " = ", ui.text, menuOpen and ui.accent or ui.bar)
  local x = 5
  for i, d in ipairs(docs) do
    local label = " " .. docName(d) .. (d.dirty and "*" or "") .. " "
    if x + #label + 1 > W - 2 then break end
    local bg = i == cur and ui.bar or ui.dark
    blitAt(x, 1, label, i == cur and ui.text or ui.dim, bg)
    blitAt(x + #label, 1, "x", ui.dim, bg)
    tabHits[#tabHits + 1] = { x, x + #label - 1, i, x + #label }
    x = x + #label + 2
  end
  blitAt(min(x, W - 1), 1, "+", ui.text, ui.dark)
  tabHits.plus = min(x, W - 1)
end

local function drawPalette()
  local y = H - 1
  win.setCursorPos(1, y)
  win.setBackgroundColour(2 ^ ui.dark); win.clearLine()
  local sw = W >= 40 and 2 or 1
  for c = 0, 15 do
    local mark = " "
    local fg = adimg.dist(palette()[c], 0) > adimg.dist(palette()[c], 0xFFFFFF) and 15 or 0
    if sel then
      if c == sel.box.fg then mark = "F" end
      if c == sel.box.bg then mark = mark == "F" and "*" or "B" end
    else
      if c == primary then mark = "L" end
      if c == secondary then mark = mark == "L" and "*" or "R" end
    end
    blitAt(1 + c * sw, y, (mark .. "  "):sub(1, sw), fg, c)
  end
  local x = 16 * sw + 2
  local info
  if status and os.clock() < statusUntil then info = status
  else
    local d = doc()
    info = ("%dx%d %s"):format(d.img.w, d.img.h, zoomInfo(d).name)
  end
  win.setCursorPos(x, y)
  win.setTextColour(2 ^ ui.text)
  win.write(info:sub(1, max(0, W - x + 1)))
end

local function drawToolbar()
  local y = H
  win.setCursorPos(1, y)
  win.setBackgroundColour(2 ^ ui.bar); win.clearLine()
  toolHits = {}
  local x = 1
  local function btn(label, action, active)
    if x + #label - 1 > W then return end
    blitAt(x, y, label, active and ui.dark or ui.text, active and ui.hi or ui.bar)
    toolHits[#toolHits + 1] = { x, x + #label - 1, action }
    x = x + #label + 1
  end
  if sel then
    btn("Text box:", function() end)
    btn("No bg", function() sel.box.bg = nil; textChanged() end, sel.box.bg == nil)
    btn("Delete", deleteSelectedBox)
    btn("Done", deselect)
    btn(showText and "Txt" or "txt", function() showText = not showText end, showText)
    return
  end
  local short = W < 47
  btn(short and "B" or "Brush", "brush", tool == "brush")
  btn(short and "F" or "Fill", "fill", tool == "fill")
  btn(short and "T" or "Text", "text", tool == "text")
  btn(short and "I" or "Pick", "pick", tool == "pick")
  btn(short and "P" or "Pan", "pan", tool == "pan")
  local function stepper(name, val, dec, inc)
    btn(name .. "-", dec); x = x - 1
    btn(tostring(val), function() end); x = x - 1
    btn("+", inc)
  end
  stepper("S", brushSize, function() brushSize = max(1, brushSize - 1) end,
    function() brushSize = min(16, brushSize + 1) end)
  stepper("D", dither, function() dither = max(1, dither - 1) end,
    function() dither = min(8, dither + 1) end)
  btn("Z" .. zoomInfo(doc()).name, function() setZoom(doc().zoom % #ZOOMS + 1) end)
  btn(showText and "Txt" or "txt", function() showText = not showText end, showText)
end

local menuItems -- defined below
local function drawMenu()
  local w = 0
  for _, it in ipairs(menuItems) do w = max(w, #it[1] + #it[2] + 3) end
  for i, it in ipairs(menuItems) do
    local label = " " .. it[1] .. string.rep(" ", w - #it[1] - #it[2] - 2) .. it[2] .. " "
    blitAt(1, i + 1, label, ui.text, ui.bar)
  end
  menuItems.width = w
end

local function draw()
  win.setVisible(false)
  drawCanvas()
  drawTabs()
  drawPalette()
  drawToolbar()
  if menuOpen then drawMenu() end
  win.setCursorBlink(false)
  if sel and not menuOpen then
    local d = doc()
    local z = zoomInfo(d)
    local cx, cy = sel.box.x - 1 + sel.col, sel.box.y - 1 + sel.line - 1
    local sx, sy
    if z.zw then
      sx = (cx * 2 - d.vx) * z.zw + z.zw + 1
      sy = (cy * 3 - d.vy) * z.zh + floor(3 * z.zh / 2) + 2
    else
      sx, sy = cx - d.vx / 2 + 1, cy - d.vy / 3 + 2
    end
    if sx >= 1 and sx <= W and sy >= 2 and sy <= H - 2 then
      win.setCursorPos(sx, sy)
      win.setTextColour(2 ^ sel.box.fg)
      win.setCursorBlink(true)
    end
  end
  win.setVisible(true)
end

---------------------------------------------------------------------------
-- Prompts
---------------------------------------------------------------------------
local function prompt(label, default, complete)
  draw()
  win.setCursorPos(1, H)
  win.setBackgroundColour(2 ^ ui.accent); win.setTextColour(2 ^ ui.text)
  win.clearLine()
  win.write(label)
  local ok, res = pcall(read, nil, nil, complete, default)
  win.setCursorBlink(false)
  if not ok or res == nil then return nil end
  return res
end

local function completePath(text)
  return fs.complete(text, shell.dir(), true, true)
end

local function confirm(question)
  local r = prompt(question .. " (y/n) ", "")
  return r and r:lower():sub(1, 1) == "y"
end

local function message(lines)
  win.setVisible(false)
  win.setBackgroundColour(2 ^ ui.dark); win.setTextColour(2 ^ ui.text)
  for y = 2, H do win.setCursorPos(1, y); win.clearLine() end
  for i, l in ipairs(lines) do
    win.setCursorPos(2, i + 1); win.write(l:sub(1, W - 2))
  end
  win.setVisible(true)
  repeat
    local e = os.pullEventRaw()
  until e == "terminate" or e == "key" or e == "mouse_click" or e == "monitor_touch"
end

local function yielder()
  local last = os.epoch("utc")
  return function()
    local now = os.epoch("utc")
    if now - last > 2000 then
      os.queueEvent("adpaint_yield")
      os.pullEvent("adpaint_yield")
      last = os.epoch("utc")
    end
  end
end

local function busy(msg)
  setStatus(msg, 60)
  draw()
end

---------------------------------------------------------------------------
-- File operations
---------------------------------------------------------------------------
local function readFile(path)
  local f = fs.open(path, "rb")
  if not f then return nil end
  local s = f.readAll() or ""
  f.close()
  return s
end

local function importData(name, data)
  convert = convert or require("lib.convert")
  local fmt = convert.detect(data)
  if fmt == "adimg" then
    local img, err = adimg.parse(data, true)
    if not img then setStatus(name .. ": " .. err); return end
    local d = newDoc(img, shell.resolve(fs.getName(name)))
    addDoc(d)
    return d
  end
  local info, err = convert.info(data)
  if not info then setStatus(name .. ": " .. tostring(err)); return end
  local dw = convert.fitCells(info, W, viewH())
  local r = prompt(("%s %dx%d. Width (cells): "):format(fs.getName(name), info.dw, info.dh), tostring(dw))
  if not r then return end
  local cw = max(1, min(512, tonumber(r) or dw))
  local _, dh = convert.fitCells(info, cw, math.huge)
  r = prompt("Height (cells): ", tostring(dh))
  if not r then return end
  local ch = max(1, min(512, tonumber(r) or dh))
  r = prompt("Dither? (y/n): ", "y")
  if not r then return end
  local dith = r:lower():sub(1, 1) ~= "n"
  r = prompt("Palette: (o)ptimised / (d)efault CC: ", "o")
  if not r then return end
  local opt = r:lower():sub(1, 1) ~= "d"
  busy("Importing...")
  local ok, img, ierr = pcall(convert.import, data, {
    w = cw, h = ch, dither = dith, optimise = opt,
    background = palette()[secondary],
    yield = yielder(),
    status = function(m) busy(m) end,
  })
  if not ok then ierr = img; img = nil end
  if not img then setStatus("Import failed: " .. tostring(ierr), 8); return end
  local base = fs.getName(name):gsub("%.[^%.]*$", "")
  local d = newDoc(img, shell.resolve(base .. ".adi"))
  d.dirty = true
  addDoc(d)
  setStatus("Imported " .. fs.getName(name))
  return d
end

local function openPath(path)
  path = shell.resolve(path)
  for i, d in ipairs(docs) do
    if d.path == path then cur = i; applyPalette(); return d end
  end
  if not fs.exists(path) or fs.isDir(path) then
    -- a new file: blank canvas that will be saved under this name
    local d = blankDoc()
    d.path = path
    addDoc(d)
    setStatus("New file " .. fs.getName(path))
    return d
  end
  local data = readFile(path)
  if not data then setStatus("Cannot read " .. path); return end
  if data:sub(1, 6) == "ADIMG " then
    local img, err = adimg.parse(data, true)
    if not img then setStatus(err); return end
    local d = newDoc(img, path)
    addDoc(d)
    return d
  end
  return importData(path, data)
end

local function saveDoc(d, as)
  d = d or doc()
  local path = d.path
  if as or not path then
    local r = prompt("Save as: ", path and ("/" .. path) or "untitled.adi", completePath)
    if not r or r == "" then return false end
    path = shell.resolve(r)
    if fs.isReadOnly(path) then setStatus("Read-only location"); return false end
    if fs.exists(path) and path ~= d.path and not confirm(fs.getName(path) .. " exists. Overwrite?") then
      return false
    end
  end
  if sel and docs[cur] == d then deselect() end
  local ok, err = adimg.save(d.img, path)
  if not ok then setStatus("Save failed: " .. tostring(err)); return false end
  d.path, d.dirty = path, false
  setStatus("Saved " .. fs.getName(path))
  return true
end

local function closeDoc(i)
  local d = docs[i]
  if i == cur then deselect() end
  if d.dirty then
    cur = i; applyPalette()
    local r = prompt("Save changes to " .. docName(d) .. "? (y/n/c) ", "")
    if not r then return false end
    r = r:lower():sub(1, 1)
    if r == "y" then if not saveDoc(d) then return false end
    elseif r ~= "n" then return false end
  end
  table.remove(docs, i)
  if #docs == 0 then
    if not running then return true end
    addDoc(blankDoc())
  end
  cur = min(cur, #docs)
  if i < cur then cur = cur - 1 end
  applyPalette()
  return true
end

local function quit()
  running = false
  while #docs > 0 do
    if not closeDoc(#docs) then running = true; return end
  end
end

local function resizeCanvas()
  local d = doc()
  local r = prompt("Canvas width (cells): ", tostring(d.img.w))
  if not r then return end
  local nw = max(1, min(512, tonumber(r) or d.img.w))
  r = prompt("Canvas height (cells): ", tostring(d.img.h))
  if not r then return end
  local nh = max(1, min(512, tonumber(r) or d.img.h))
  if nw == d.img.w and nh == d.img.h then return end
  deselect()
  beginOp("full")
  local old = d.img
  local new = adimg.new(nw, nh, secondary)
  for y = 0, min(old.ph, new.ph) - 1 do
    for x = 0, min(old.pw, new.pw) - 1 do
      new.px[y * new.pw + x + 1] = old.px[y * old.pw + x + 1]
    end
  end
  old.px, old.w, old.h, old.pw, old.ph = new.px, nw, nh, new.pw, new.ph
  old.text = adimg.copyText(old.text)
  endOp()
  clampView(d)
  setStatus(("Resized to %dx%d"):format(nw, nh))
end

local function editColour()
  local d = doc()
  local pal = palette()
  local r = prompt(("Colour %d hex RRGGBB: "):format(primary), ("%06x"):format(pal[primary]))
  if not r or not r:match("^#?%x%x%x%x%x%x$") then return end
  beginOp("full")
  local np = {}
  for i = 0, 15 do np[i] = pal[i] end
  np[primary] = tonumber(r:gsub("#", ""), 16)
  d.img.palette = np
  endOp()
  applyPalette()
end

local function resetPalette()
  if not doc().img.palette then return end
  beginOp("full")
  doc().img.palette = nil
  endOp()
  applyPalette()
end

local HELP = {
  "adpaint - .adi advertisement image editor",
  "",
  "Left click = primary colour, right = secondary.",
  "Middle drag / arrows / scroll (shift: sideways) pans.",
  "Drag image files onto the window to import them.",
  "",
  "B brush  F fill  T text  I pick  P pan",
  "[ ] brush size   , . dither   Z zoom   H text layer",
  "Ctrl: N new  O open  S save  W close tab  Q quit",
  "      Z undo  Y redo  Tab next tab",
  "",
  "Text tool: click to add/select a box, type to edit,",
  "drag to move. Palette L/R = text / background.",
  "",
  "Press any key.",
}

menuItems = {
  { "New", "^N", function() local r = prompt("Size WxH: ", W .. "x" .. viewH())
      if not r then return end
      local w, h = r:match("(%d+)%s*[xX, ]%s*(%d+)")
      addDoc(blankDoc(max(1, min(512, tonumber(w) or W)), max(1, min(512, tonumber(h) or viewH())))) end },
  { "Open...", "^O", function() local r = prompt("Open: ", "", completePath); if r and r ~= "" then openPath(r) end end },
  { "Save", "^S", function() saveDoc() end },
  { "Save as...", "", function() saveDoc(nil, true) end },
  { "Import image...", "", function()
      local r = prompt("Image file: ", "", completePath)
      if r and r ~= "" then
        local data = readFile(shell.resolve(r))
        if data then importData(r, data) else setStatus("Cannot read " .. r) end
      end end },
  { "Resize canvas...", "", resizeCanvas },
  { "Edit colour L...", "", editColour },
  { "Default palette", "", resetPalette },
  { "Undo", "^Z", function() undo() end },
  { "Redo", "^Y", function() undo(true) end },
  { "Close tab", "^W", function() closeDoc(cur) end },
  { "Help", "", function() message(HELP) end },
  { "Quit", "^Q", quit },
}

---------------------------------------------------------------------------
-- Input
---------------------------------------------------------------------------
local function canvasDown(button, x, y)
  local d = doc()
  local native = not zoomInfo(d).zw
  local px, py, cx, cy = screenToImage(x, y)
  if button == 3 or tool == "pan" then
    drag = { kind = "pan", x = x, y = y }
    return
  end
  local color = button == 1 and primary or secondary
  if tool == "brush" then
    deselect()
    beginOp()
    local ux, uy = native and cx or px, native and cy or py
    stamp(ux, uy, color, native)
    drag = { kind = "brush", ux = ux, uy = uy, color = color, native = native }
  elseif tool == "fill" then
    deselect()
    local img = d.img
    if px < 0 or py < 0 or px >= img.pw or py >= img.ph then return end
    if native then _, px, py = cellMajority(img, cx, cy) end
    beginOp()
    floodFill(px, py, color)
    endOp()
  elseif tool == "pick" then
    local c = adimg.get(d.img, px, py)
    if c then
      if native then c = cellMajority(d.img, cx, cy) end
      if button == 1 then primary = c else secondary = c end
    end
  elseif tool == "text" then
    local img = d.img
    if cx < 0 or cy < 0 or cx >= img.w or cy >= img.h then deselect(); return end
    local b = boxAt(cx, cy)
    if b then
      local line = cy + 1 - b.y + 1
      selectBox(b, line, min(#b.lines[line], cx + 1 - b.x))
    else
      deselect()
      b = { x = cx + 1, y = cy + 1, fg = primary, bg = nil, lines = { "" } }
      beginOp("text")
      table.insert(img.text, b)
      sel = { box = b, line = 1, col = 0 }
    end
    drag = { kind = "text", cx = cx, cy = cy }
  end
end

local function canvasDrag(x, y)
  if not drag then return end
  local d = doc()
  if drag.kind == "pan" then
    pan(drag.x - x, drag.y - y)
    drag.x, drag.y = x, y
    return
  end
  local px, py, cx, cy = screenToImage(x, y)
  if drag.kind == "brush" then
    local ux, uy = drag.native and cx or px, drag.native and cy or py
    if ux ~= drag.ux or uy ~= drag.uy then
      strokeLine(drag.ux, drag.uy, ux, uy, drag.color, drag.native)
      drag.ux, drag.uy = ux, uy
    end
  elseif drag.kind == "text" and sel then
    local dx, dy = cx - drag.cx, cy - drag.cy
    if dx ~= 0 or dy ~= 0 then
      sel.box.x = max(1, min(d.img.w, sel.box.x + dx))
      sel.box.y = max(1, min(d.img.h, sel.box.y + dy))
      drag.cx, drag.cy = cx, cy
      textChanged()
    end
  end
end

local function mouseUp()
  if drag and drag.kind == "brush" then endOp() end
  drag = nil
end

local function click(button, x, y)
  if menuOpen then
    menuOpen = false
    local it = menuItems[y - 1]
    if it and x <= (menuItems.width or 0) then it[3]() end
    return
  end
  if y == 1 then
    if x <= 3 then menuOpen = true; return end
    for _, t in ipairs(tabHits) do
      if x >= t[1] and x <= t[2] then deselect(); cur = t[3]; applyPalette(); return end
      if x == t[4] then closeDoc(t[3]); return end
    end
    if x == tabHits.plus then addDoc(blankDoc()) end
  elseif y == H - 1 then
    local sw = W >= 40 and 2 or 1
    local c = floor((x - 1) / sw)
    if c >= 0 and c <= 15 then
      if sel then
        if button == 1 then sel.box.fg = c else sel.box.bg = c end
        textChanged()
      elseif button == 1 then primary = c else secondary = c end
    end
  elseif y == H then
    for _, t in ipairs(toolHits) do
      if x >= t[1] and x <= t[2] then
        if type(t[3]) == "function" then t[3]() else deselect(); tool = t[3] end
        return
      end
    end
  else
    canvasDown(button, x, y)
  end
end

local SHORTCUTS = {
  [keys.b] = function() tool = "brush" end,
  [keys.f] = function() tool = "fill" end,
  [keys.t] = function() tool = "text" end,
  [keys.i] = function() tool = "pick" end,
  [keys.p] = function() tool = "pan" end,
  [keys.leftBracket] = function() brushSize = max(1, brushSize - 1) end,
  [keys.rightBracket] = function() brushSize = min(16, brushSize + 1) end,
  [keys.comma] = function() dither = max(1, dither - 1) end,
  [keys.period] = function() dither = min(8, dither + 1) end,
  [keys.z] = function() setZoom(doc().zoom % #ZOOMS + 1) end,
  [keys.h] = function() showText = not showText end,
  [keys.tab] = function() cur = cur % #docs + 1; applyPalette() end,
  [keys.left] = function() pan(shift and -8 or -2, 0) end,
  [keys.right] = function() pan(shift and 8 or 2, 0) end,
  [keys.up] = function() pan(0, shift and -6 or -2) end,
  [keys.down] = function() pan(0, shift and 6 or 2) end,
}
local CTRL = {
  [keys.n] = function() menuItems[1][3]() end,
  [keys.o] = function() menuItems[2][3]() end,
  [keys.s] = function() saveDoc() end,
  [keys.w] = function() closeDoc(cur) end,
  [keys.q] = quit,
  [keys.z] = function() undo() end,
  [keys.y] = function() undo(true) end,
}

local function keyDown(k)
  if k == keys.leftCtrl or k == keys.rightCtrl then ctrl = true; return end
  if k == keys.leftShift or k == keys.rightShift then shift = true; return end
  if ctrl then
    if CTRL[k] then deselect(); CTRL[k]() end
    return
  end
  if menuOpen then menuOpen = false; return end
  if sel then
    if textKey(k) then return end
    return -- letters arrive as char events
  end
  if SHORTCUTS[k] then SHORTCUTS[k]() end
end

local function handleFiles(transfer)
  local list = transfer.getFiles()
  for _, h in ipairs(list) do
    local name = h.getName()
    local data = h.readAll() or ""
    h.close()
    importData(name, data)
  end
end

---------------------------------------------------------------------------
-- Main
---------------------------------------------------------------------------
local function main()
  for _, f in ipairs(files) do openPath(f) end
  if #docs == 0 then addDoc(blankDoc()) end
  cur = 1
  applyPalette()
  clampView(doc())
  while running do
    draw()
    local ev = { os.pullEventRaw() }
    local e = ev[1]
    if e == "terminate" then quit()
    elseif e == "mouse_click" and not monSide then click(ev[2], ev[3], ev[4])
    elseif e == "mouse_drag" and not monSide then canvasDrag(ev[3], ev[4])
    elseif e == "mouse_up" and not monSide then mouseUp()
    elseif e == "monitor_touch" and monSide and ev[2] == peripheral.getName(display) then
      click(1, ev[3], ev[4]); mouseUp()
    elseif e == "mouse_scroll" and not monSide then
      if ev[4] >= 2 and ev[4] <= H - 2 then
        if shift then pan(ev[2] * 3, 0) else pan(0, ev[2] * 2) end
      end
    elseif e == "key" then keyDown(ev[2])
    elseif e == "key_up" then
      if ev[2] == keys.leftCtrl or ev[2] == keys.rightCtrl then ctrl = false end
      if ev[2] == keys.leftShift or ev[2] == keys.rightShift then shift = false end
    elseif e == "char" and sel and not ctrl then textInsert(ev[2])
    elseif e == "file_transfer" then handleFiles(ev[2])
    elseif e == "term_resize" or e == "monitor_resize" then
      W, H = display.getSize()
      win.reposition(1, 1, W, H)
      for _, d in ipairs(docs) do clampView(d) end
    end
  end
end

local ok, err = pcall(main)
term.redirect(oldTerm)
adimg.applyPalette(display, adimg.DEFAULT_PALETTE)
display.setBackgroundColour(colours.black)
display.setTextColour(colours.white)
display.clear()
display.setCursorPos(1, 1)
if not ok then printError(err) end
