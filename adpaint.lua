-- adpaint: image editor for .adi advertisement images (CC: Tweaked).
-- Run "adpaint help" for usage.

local progDir = fs.getDir(shell.getRunningProgram())
package.path = "/" .. fs.combine(progDir, "?.lua") .. ";" .. package.path
local adimg = require("lib.adimg")
local convert -- loaded on first import (keeps start-up light)

local floor, max, min = math.floor, math.max, math.min
local HEX = adimg.IDX_TO_HEX

local USAGE = [[
Usage:
 adpaint [file ...]   open .adi files in tabs; PNG,
                      JPEG and BMP files are imported
 adpaint -m <side> [-s <scale>] [file ...]
                      paint on an advanced monitor
 adpaint convert <image> [out.adi] [options]
   -w, --width <n>    width in cells (default: fit
                      this terminal)
       --height <n>   height (default: keep aspect)
   -c, --colours <n>  colours to use, 2-16 (16)
   -p, --palette <p>  optimised (default) or default
   -n, --no-dither    don't dither
   -f, --force        overwrite out.adi
 adpaint setup        filename completion at boot
 adpaint help         this text

While adpaint runs, drag image files from your
computer onto its window to import them.]]

-- Files dropped onto the window while a prompt or an import was busy.
local pendingFiles = {}

-- Returns a function to call often during long work: it yields every ~2s
-- (avoiding "too long without yielding") and keeps dropped files.
local function yielder()
  local last = os.epoch("utc")
  return function()
    if os.epoch("utc") - last > 2000 then
      os.queueEvent("adpaint_yield")
      while true do
        local ev = { os.pullEventRaw() }
        if ev[1] == "adpaint_yield" then break
        elseif ev[1] == "file_transfer" then pendingFiles[#pendingFiles + 1] = ev[2]
        elseif ev[1] == "terminate" then error("Terminated", 0) end
      end
      last = os.epoch("utc")
    end
  end
end

---------------------------------------------------------------------------
-- Shell integration: argument completion, "setup", "convert"
---------------------------------------------------------------------------
local NUMBER_OPTS = { ["-w"] = true, ["--width"] = true, ["--height"] = true, ["-c"] = true,
                      ["--colours"] = true, ["--colors"] = true, ["-s"] = true }
local CONVERT_OPTS = { "--width", "--height", "--colours", "--palette", "--no-dither", "--force" }

local function completeArgs(sh, index, text, previous)
  local ok, c = pcall(require, "cc.shell.completion")
  if not ok then return {} end
  local prev = previous[#previous]
  if NUMBER_OPTS[prev] then return {} end
  if prev == "-m" then return c.peripheral(sh, text, previous, true) end
  if prev == "-p" or prev == "--palette" then
    return c.choice(sh, text, previous, { "optimised", "default" }, true)
  end
  local isConvert = previous[2] == "convert"
  if text:sub(1, 1) == "-" then
    return c.choice(sh, text, previous, isConvert and CONVERT_OPTS or { "-m", "-s" }, true)
  end
  local out = {}
  if index == 1 then
    for _, v in ipairs(c.choice(sh, text, previous, { "help", "convert", "setup" }, true)) do out[#out + 1] = v end
  end
  for _, v in ipairs(c.dirOrFile(sh, text, previous, true)) do out[#out + 1] = v end
  return out
end

if shell.setCompletionFunction then
  shell.setCompletionFunction(shell.getRunningProgram(), completeArgs)
end

local SETUP_MARK = "-- adpaint: filename completion"

local function setup()
  local line = ("shell.run(%q, \"--register\") %s"):format("/" .. shell.getRunningProgram(), SETUP_MARK)
  local target
  for _, f in ipairs({ "/startup.lua", "/startup" }) do
    if fs.exists(f) and not fs.isDir(f) then target = f; break end
  end
  if target then
    local h = fs.open(target, "r")
    local content = h.readAll() or ""
    h.close()
    if content:find(SETUP_MARK, 1, true) then print("Already set up in " .. target); return end
    h = fs.open(target, "a")
    h.write((content:sub(-1) == "\n" or content == "") and line .. "\n" or "\n" .. line .. "\n")
    h.close()
  else
    target = "/startup/adpaint.lua"
    local h = fs.open(target, "w")
    h.write(line .. "\n")
    h.close()
  end
  print("Added completion to " .. target .. ".")
  print("It is active now and after every reboot.")
end

local function cliConvert(argv)
  local opt = { colours = 16, optimise = true, dither = true }
  local input, output, force
  local i = 1
  while i <= #argv do
    local a = argv[i]
    local v = argv[i + 1]
    if a == "-w" or a == "--width" then opt.w = tonumber(v); i = i + 2
    elseif a == "--height" then opt.h = tonumber(v); i = i + 2
    elseif a == "-c" or a == "--colours" or a == "--colors" then opt.colours = tonumber(v) or 16; i = i + 2
    elseif a == "-p" or a == "--palette" then opt.optimise = (v or ""):sub(1, 1):lower() ~= "d"; i = i + 2
    elseif a == "-n" or a == "--no-dither" then opt.dither = false; i = i + 1
    elseif a == "-f" or a == "--force" then force = true; i = i + 1
    elseif a:sub(1, 1) == "-" then printError("Unknown option " .. a); return
    elseif not input then input = a; i = i + 1
    elseif not output then output = a; i = i + 1
    else printError("Too many arguments"); return end
  end
  if not input then print(USAGE); return end
  local inPath = shell.resolve(input)
  if not fs.exists(inPath) or fs.isDir(inPath) then printError("No such file: " .. input); return end
  output = output and shell.resolve(output) or (inPath:gsub("%.[^%./]*$", "") .. ".adi")
  if fs.exists(output) and not force then
    write(fs.getName(output) .. " exists. Overwrite? (y/n) ")
    local r = read()
    if not r or r:lower():sub(1, 1) ~= "y" then return end
  end
  local h = fs.open(inPath, "rb")
  local data = h.readAll() or ""
  h.close()
  convert = require("lib.convert")
  local info, err = convert.info(data)
  if not info then printError(input .. ": " .. tostring(err)); return end
  for _, k in ipairs({ "w", "h" }) do
    if opt[k] then opt[k] = math.max(1, math.min(512, math.floor(opt[k]))) end
  end
  if not opt.w and not opt.h then
    local tw, th = term.getSize()
    opt.w, opt.h = convert.fitCells(info, tw, th)
  elseif opt.h and not opt.w then
    opt.w = math.max(1, math.floor(opt.h * 3 * info.dw / info.dh / 2 + 0.5))
  end
  opt.colours = math.max(2, math.min(16, math.floor(opt.colours)))
  opt.yield = yielder()
  opt.status = print
  local ok, img, ierr = pcall(convert.import, data, opt)
  if not ok then ierr = img; img = nil end
  if not img then printError("Conversion failed: " .. tostring(ierr)); return end
  local sok, serr = adimg.save(img, output)
  if not sok then printError("Save failed: " .. tostring(serr)); return end
  print(("Saved %s (%dx%d cells)"):format(output, img.w, img.h))
end

---------------------------------------------------------------------------
-- Arguments / display set-up
---------------------------------------------------------------------------
local args = { ... }
local command = args[1]
if command == "--register" then return end
if command == "help" or command == "-h" or command == "--help" or command == "-?" then
  textutils.pagedPrint(USAGE)
  return
end
if command == "setup" then setup(); return end
if command == "convert" then cliConvert({ table.unpack(args, 2) }); return end

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

-- Zoom levels: chars per pixel (zw x zh). Level 1 is native teletext,
-- level 2 turns each cell into 6x6 chars (3x2 chars per pixel = square).
local ZOOMS = {
  { name = "1x" },
  { name = "6x", zw = 3, zh = 2 },
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

-- A tab's first L/R colours: the darkest and the brightest palette colour
-- (black / white with the default palette).
local function resetColours()
  local pal = palette()
  local dl, bl = math.huge, -1
  for i = 0, 15 do
    local r, g, b = adimg.rgb(pal[i])
    local l = r * 0.3 + g * 0.59 + b * 0.11
    if l < dl then primary, dl = i, l end
    if l > bl then secondary, bl = i, l end
  end
end

-- Every tab remembers its own L/R colours. `colourDoc` is the tab whose
-- colours are currently loaded into primary/secondary.
local colourDoc = nil

-- Called whenever the current tab (or its palette) changes.
local function applyPalette()
  adimg.applyPalette(win, palette())
  computeUi()
  local d = doc()
  if d ~= colourDoc then
    if colourDoc then colourDoc.primary, colourDoc.secondary = primary, secondary end
    colourDoc = d
    if d.primary then primary, secondary = d.primary, d.secondary else resetColours() end
  end
end

---------------------------------------------------------------------------
-- Documents
---------------------------------------------------------------------------
local function viewH() return H - 3 end

local NEW_W, NEW_H = 18, 24 -- default size of a new canvas, in cells

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
  return newDoc(adimg.new(w or NEW_W, h or NEW_H, 0))
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

-- `level` is the coverage out of 16 (defaults to the dither setting).
local function ditherOn(x, y, level)
  return BAYER[(y % 4) * 4 + x % 4 + 1] < (level or dither * 2)
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
  -- Soft brush: with dithering and a brush bigger than 2, coverage fades
  -- from the dither setting at the centre to almost nothing at the rim.
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
                  setPx(img, py * img.pw + pxx + 1, color)
                end
              end
            end
            touched[cy * img.w + cx] = true
          end
        else
          local x, y = ux + dx, uy + dy
          if x >= 0 and y >= 0 and x < img.pw and y < img.ph and ditherOn(x, y, level(x + 0.5, y + 0.5)) then
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
    setPx(img, p + 1, color)
    touched[floor(qy / 3) * img.w + floor(qx / 2)] = true
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
    -- thin frame around each text box (selected box highlighted), drawn
    -- with drawing characters on the box's outermost screen characters
    if showText then
      for _, bx in ipairs(img.text) do
        local fc = HEX[(sel and sel.box == bx) and ui.hi or ui.dim]
        local c0 = ((bx.x - 1) * 2 - d.vx) * zw
        local c1 = ((bx.x - 1 + boxWidth(bx)) * 2 - d.vx) * zw - 1
        local r0 = ((bx.y - 1) * 3 - d.vy) * zh
        local r1 = ((bx.y - 1 + #bx.lines) * 3 - d.vy) * zh - 1
        for row = max(0, r0), min(vh - 1, r1) do
          local r = rows[row]
          local T, B = row == r0, row == r1
          for col = max(0, c0), min(W - 1, c1) do
            local L, R = col == c0, col == c1
            if (L or R or T or B) and r[1][col + 1] == " " then
              local m = ((L or T) and 1 or 0) + ((R or T) and 2 or 0) + (L and 4 or 0)
                + (R and 8 or 0) + ((L or B) and 16 or 0) + ((R or B) and 32 or 0)
              local pix = r[3][col + 1]
              local f = fc == pix and HEX[ui.text] or fc
              if m >= 32 then -- bottom-right sub-pixel is always background
                r[1][col + 1] = CHARS[63 - m]; r[2][col + 1] = pix; r[3][col + 1] = f
              else
                r[1][col + 1] = CHARS[m]; r[2][col + 1] = f
              end
            end
          end
        end
      end
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

local tabHits, toolHits, sizeHit = {}, {}, nil

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
  win.setBackgroundColour(2 ^ ui.bar); win.clearLine()
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
  local d = doc()
  local size = " " .. d.img.w .. "x" .. d.img.h .. " "
  local sx = W - #size + 1
  if sx > x then
    blitAt(sx, y, size, ui.text, ui.dark)
    sizeHit = { sx, W }
  else
    sizeHit = nil
  end
end

-- Status messages show as a small toast at the bottom right of the canvas.
local function drawStatus()
  if not (status and os.clock() < statusUntil) then return end
  local msg = " " .. status:sub(1, W - 2) .. " "
  blitAt(W - #msg + 1, H - 2, msg, ui.text, ui.bar)
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
    btn("Zoom", function() setZoom(doc().zoom % #ZOOMS + 1) end, doc().zoom > 1)
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
  if tool == "brush" then
    stepper("S", brushSize, function() brushSize = max(1, brushSize - 1) end,
      function() brushSize = min(16, brushSize + 1) end)
    stepper("D", dither, function() dither = max(1, dither - 1) end,
      function() dither = min(8, dither + 1) end)
  end
  btn("Zoom", function() setZoom(doc().zoom % #ZOOMS + 1) end, doc().zoom > 1)
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

local function draw(overlay)
  win.setVisible(false)
  drawCanvas()
  drawTabs()
  drawPalette()
  drawToolbar()
  drawStatus()
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
  if overlay then overlay() end
  win.setVisible(true)
end

---------------------------------------------------------------------------
-- Prompts
---------------------------------------------------------------------------
-- Both prompt types live on the bottom row and have touch buttons, so they
-- can always be answered or cancelled from a monitor.

local function onResize()
  W, H = display.getSize()
  win.reposition(1, 1, W, H)
  for _, d in ipairs(docs) do clampView(d) end
end

-- Returns button, x, y if the event is a click/touch meant for us.
local function asClick(ev)
  if ev[1] == "mouse_click" and not monSide then return ev[2], ev[3], ev[4] end
  if ev[1] == "monitor_touch" and monSide and ev[2] == peripheral.getName(display) then
    return 1, ev[3], ev[4]
  end
end

-- Tracks modifier keys for events consumed inside modal prompts.
local function trackModifiers(ev)
  local k = ev[2]
  if k == keys.leftCtrl or k == keys.rightCtrl then ctrl = ev[1] == "key" end
  if k == keys.leftShift or k == keys.rightShift then shift = ev[1] == "key" end
end

-- Draws buttons right-aligned on the bottom row; returns hit boxes and the
-- last column left free for other content.
local function bottomButtons(buttons)
  local hits, x = {}, W + 1
  for i = #buttons, 1, -1 do
    local label = " " .. buttons[i][1] .. " "
    x = x - #label
    blitAt(x, H, label, ui.text, ui.bar)
    hits[#hits + 1] = { x, x + #label - 1, buttons[i][2] }
    x = x - 1
  end
  return hits, x - 1
end

local function hitButton(hits, x)
  for _, h in ipairs(hits) do if x >= h[1] and x <= h[2] then return h[3] end end
end

-- Text input. Returns the entered string, or nil when cancelled.
-- `complete(text)` may return a list of suffixes (like read()'s completion):
-- the current one is shown greyed out after the text. Tab (or tapping the
-- suggestion) accepts it, Up/Down cycle through the alternatives.
local function prompt(label, default, complete)
  local text = tostring(default or "")
  local pos = #text
  local comps, ci = nil, 1
  local function recomplete()
    comps, ci = nil, 1
    if complete and pos == #text then
      local ok, c = pcall(complete, text)
      if ok and type(c) == "table" and #c > 0 then comps = c end
    end
  end
  recomplete()
  while true do
    local hits, fieldX, fieldEnd
    draw(function()
      win.setCursorPos(1, H)
      win.setBackgroundColour(2 ^ ui.accent); win.setTextColour(2 ^ ui.text)
      win.clearLine()
      local free
      hits, free = bottomButtons({ { "OK", "ok" }, { "Cancel", "cancel" } })
      local lab = label:sub(1, max(0, free - 8))
      win.setCursorPos(1, H)
      win.setBackgroundColour(2 ^ ui.accent)
      win.write(lab)
      local fx = #lab + 1
      local fw = max(1, free - fx + 1)
      local scroll = max(0, pos - fw + 1)
      win.setBackgroundColour(2 ^ ui.dark)
      win.write((text:sub(scroll + 1, scroll + fw) .. string.rep(" ", fw)):sub(1, fw))
      if comps then
        local gx = fx + #text - scroll
        local ghost = comps[ci]:sub(1, max(0, fx + fw - gx))
        win.setCursorPos(gx, H)
        win.setTextColour(2 ^ ui.dim)
        win.write(ghost)
      end
      fieldX, fieldEnd = fx, fx + fw - 1
      win.setCursorPos(fx + pos - scroll, H)
      win.setTextColour(2 ^ ui.text)
      win.setCursorBlink(true)
    end)
    local ev = { os.pullEventRaw() }
    local e = ev[1]
    local button, x, y = asClick(ev)
    if e == "terminate" then return nil
    elseif button and y == H then
      local r = hitButton(hits, x)
      if r == "ok" then return text elseif r == "cancel" then return nil
      elseif comps and x >= fieldX and x <= fieldEnd then
        text = text .. comps[ci]; pos = #text; recomplete()
      end
    elseif e == "char" or e == "paste" then
      text = text:sub(1, pos) .. ev[2] .. text:sub(pos + 1)
      pos = pos + #ev[2]
      recomplete()
    elseif e == "key" then
      trackModifiers(ev)
      local k = ev[2]
      if k == keys.enter or k == keys.numPadEnter then return text
      elseif k == keys.backspace and pos > 0 then
        text = text:sub(1, pos - 1) .. text:sub(pos + 1); pos = pos - 1
      elseif k == keys.delete then text = text:sub(1, pos) .. text:sub(pos + 2)
      elseif k == keys.left then pos = max(0, pos - 1)
      elseif k == keys.right and comps and pos == #text then
        text = text .. comps[ci]; pos = #text
      elseif k == keys.right then pos = min(#text, pos + 1)
      elseif k == keys.home then pos = 0
      elseif k == keys["end"] then pos = #text
      elseif k == keys.tab and comps then text = text .. comps[ci]; pos = #text
      elseif k == keys.up and comps then ci = (ci - 2) % #comps + 1
      elseif k == keys.down and comps then ci = ci % #comps + 1
      end
      if k ~= keys.up and k ~= keys.down then recomplete() end
    elseif e == "key_up" then trackModifiers(ev)
    elseif e == "file_transfer" then pendingFiles[#pendingFiles + 1] = ev[2]
    elseif e == "term_resize" or e == "monitor_resize" then onResize()
    end
  end
end

-- Multiple choice with touch buttons. options = { {label, value}, ... }.
-- A key press of an option's first letter also picks it; Enter picks the
-- first option. Returns the value, or nil if cancelled/terminated.
local function choose(question, options)
  while true do
    local hits
    draw(function()
      win.setCursorPos(1, H)
      win.setBackgroundColour(2 ^ ui.accent); win.setTextColour(2 ^ ui.text)
      win.clearLine()
      local free
      hits, free = bottomButtons(options)
      win.setCursorPos(1, H)
      win.setBackgroundColour(2 ^ ui.accent)
      win.write(question:sub(1, max(0, free)))
    end)
    local ev = { os.pullEventRaw() }
    local button, x, y = asClick(ev)
    if ev[1] == "terminate" then return nil
    elseif button and y == H then
      local r = hitButton(hits, x)
      if r ~= nil then return r end
    elseif ev[1] == "key" then
      trackModifiers(ev)
      if ev[2] == keys.enter or ev[2] == keys.numPadEnter then return options[1][2] end
      local name = keys.getName(ev[2])
      for _, o in ipairs(options) do
        if name and #name == 1 and o[1]:sub(1, 1):lower() == name then return o[2] end
      end
    elseif ev[1] == "key_up" then trackModifiers(ev)
    elseif ev[1] == "file_transfer" then pendingFiles[#pendingFiles + 1] = ev[2]
    elseif ev[1] == "term_resize" or ev[1] == "monitor_resize" then onResize()
    end
  end
end

-- Picks one of 9 anchor points (corners, sides, centre) on a touchable
-- 3x3 grid. Returns ax, ay in {0, 0.5, 1}, or nil if cancelled.
local ANCHOR_NAMES = { "top left", "top", "top right", "left", "centre", "right",
                       "bottom left", "bottom", "bottom right" }
local function chooseAnchor(title)
  local pick = 1
  while true do
    local hits, cells = nil, {}
    draw(function()
      local bw, bh = 5, viewH() >= 15 and 3 or 1
      local pw, ph = 3 * bw + 2 + 4, 3 * bh + 2 + 4
      local x0 = max(1, floor((W - pw) / 2) + 1)
      local y0 = max(2, floor((viewH() - ph) / 2) + 2)
      win.setBackgroundColour(2 ^ ui.bar)
      for y = y0, min(H - 2, y0 + ph - 1) do
        win.setCursorPos(x0, y); win.write(string.rep(" ", pw))
      end
      win.setCursorPos(x0 + 2, y0 + 1)
      win.setTextColour(2 ^ ui.text)
      win.write(title:sub(1, pw - 4))
      for i = 1, 9 do
        local gx = x0 + 2 + ((i - 1) % 3) * (bw + 1)
        local gy = y0 + 3 + floor((i - 1) / 3) * (bh + 1)
        local c = i == pick and ui.hi or ui.dark
        for y = gy, gy + bh - 1 do
          if y <= H - 2 then blitAt(gx, y, string.rep(" ", bw), ui.text, c) end
        end
        cells[i] = { gx, gy, gx + bw - 1, gy + bh - 1 }
      end
      win.setCursorPos(1, H)
      win.setBackgroundColour(2 ^ ui.accent); win.setTextColour(2 ^ ui.text)
      win.clearLine()
      local free
      hits, free = bottomButtons({ { "OK", "ok" }, { "Cancel", "cancel" } })
      win.setCursorPos(1, H)
      win.setBackgroundColour(2 ^ ui.accent)
      win.write(("Anchor: " .. ANCHOR_NAMES[pick]):sub(1, max(0, free)))
    end)
    local ev = { os.pullEventRaw() }
    local button, x, y = asClick(ev)
    local done = false
    if ev[1] == "terminate" then return nil
    elseif button then
      if y == H then
        local r = hitButton(hits, x)
        if r == "ok" then done = true elseif r == "cancel" then return nil end
      else
        for i, c in ipairs(cells) do
          if x >= c[1] and x <= c[3] and y >= c[2] and y <= c[4] then
            if i == pick then done = true end -- tapping the chosen one again confirms
            pick = i
          end
        end
      end
    elseif ev[1] == "key" then
      trackModifiers(ev)
      local k = ev[2]
      if k == keys.enter or k == keys.numPadEnter then done = true
      elseif k == keys.left and (pick - 1) % 3 > 0 then pick = pick - 1
      elseif k == keys.right and (pick - 1) % 3 < 2 then pick = pick + 1
      elseif k == keys.up and pick > 3 then pick = pick - 3
      elseif k == keys.down and pick < 7 then pick = pick + 3 end
    elseif ev[1] == "key_up" then trackModifiers(ev)
    elseif ev[1] == "file_transfer" then pendingFiles[#pendingFiles + 1] = ev[2]
    elseif ev[1] == "term_resize" or ev[1] == "monitor_resize" then onResize()
    end
    if done then return ((pick - 1) % 3) / 2, floor((pick - 1) / 3) / 2 end
  end
end

local function completePath(text)
  return fs.complete(text, shell.dir(), true, true)
end

local function confirm(question)
  return choose(question, { { "Yes", true }, { "No", false } }) == true
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
  local dith = choose("Dithering:", { { "Dither", true }, { "None", false }, { "Cancel", "c" } })
  if dith == nil or dith == "c" then return end
  local opt = choose("Palette:", { { "Optimised", true }, { "Default", false }, { "Cancel", "c" } })
  if opt == nil or opt == "c" then return end
  r = prompt("Colours to use (2-16): ", "16")
  if not r then return end
  local ncol = max(2, min(16, floor(tonumber(r) or 16)))
  busy("Importing...")
  local ok, img, ierr = pcall(convert.import, data, {
    w = cw, h = ch, dither = dith, optimise = opt, colours = ncol,
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
    local r = choose("Save " .. docName(d) .. "?",
      { { "Save", "y" }, { "Discard", "n" }, { "Cancel", "c" } })
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

-- Copies src's pixels into a new w x h canvas filled with `fill`, with the
-- source's top-left at cell offset (ox, oy). Returns the pixel array.
local function placePixels(src, w, h, ox, oy, fill)
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

-- Cell offset that puts a `size` wide thing at anchor `a` (0/0.5/1) in `space`.
local function anchorOffset(space, size, a)
  return floor((space - size) * a + 0.5)
end

local function moveText(text, dx, dy, w, h)
  for _, b in ipairs(text) do
    b.x = max(1, min(w, b.x + dx))
    b.y = max(1, min(h, b.y + dy))
  end
end

local function resizeCanvas()
  local d = doc()
  local r = prompt("Canvas width (cells): ", tostring(d.img.w))
  if not r then return end
  local nw = max(1, min(512, floor(tonumber(r) or d.img.w)))
  r = prompt("Canvas height (cells): ", tostring(d.img.h))
  if not r then return end
  local nh = max(1, min(512, floor(tonumber(r) or d.img.h)))
  if nw == d.img.w and nh == d.img.h then return end
  local ax, ay = chooseAnchor("Keep image at:")
  if not ax then return end
  deselect()
  beginOp("full")
  local old = d.img
  local ox, oy = anchorOffset(nw, old.w, ax), anchorOffset(nh, old.h, ay)
  local new = placePixels(old, nw, nh, ox, oy, secondary)
  local text = adimg.copyText(old.text)
  moveText(text, ox, oy, nw, nh)
  old.px, old.w, old.h, old.pw, old.ph, old.text = new.px, nw, nh, new.pw, new.ph, text
  endOp()
  clampView(d)
  setStatus(("Canvas is now %dx%d"):format(nw, nh))
end

-- Scales the image (nearest neighbour), then makes every cell 2-colour
-- again. The canvas either follows the new size, or keeps its size with the
-- scaled image placed at a chosen anchor. Text boxes move along.
local function scaleImage()
  local d = doc()
  local img = d.img
  local r = prompt("Image width (cells): ", tostring(img.w))
  if not r then return end
  local nw = max(1, min(512, floor(tonumber(r) or img.w)))
  r = prompt("Image height (cells): ", tostring(max(1, floor(img.h * nw / img.w + 0.5))))
  if not r then return end
  local nh = max(1, min(512, floor(tonumber(r) or img.h)))
  if nw == img.w and nh == img.h then return end
  local mode = choose("Canvas:", { { "Fit image", "fit" }, { "Keep size", "keep" }, { "Cancel", "c" } })
  if mode ~= "fit" and mode ~= "keep" then return end
  local ax, ay = 0, 0
  if mode == "keep" then
    ax, ay = chooseAnchor("Place image at:")
    if not ax then return end
  end
  deselect()
  beginOp("full")
  local new = adimg.new(nw, nh, 0)
  for y = 0, new.ph - 1 do
    local sy = min(img.ph - 1, floor((y + 0.5) * img.ph / new.ph))
    for x = 0, new.pw - 1 do
      local sx = min(img.pw - 1, floor((x + 0.5) * img.pw / new.pw))
      new.px[y * new.pw + x + 1] = img.px[sy * img.pw + sx + 1]
    end
  end
  new.palette = img.palette
  local saved = op
  op = nil -- the full snapshot covers this; don't log pixels into it
  for cy = 0, nh - 1 do
    for cx = 0, nw - 1 do fixCell(new, cx, cy, nil) end
  end
  op = saved
  local text = adimg.copyText(img.text)
  for _, b in ipairs(text) do
    b.x = max(1, min(nw, floor((b.x - 1) * nw / img.w + 0.5) + 1))
    b.y = max(1, min(nh, floor((b.y - 1) * nh / img.h + 0.5) + 1))
  end
  local cw, ch = nw, nh
  if mode == "keep" then
    cw, ch = img.w, img.h
    local ox, oy = anchorOffset(cw, nw, ax), anchorOffset(ch, nh, ay)
    new = placePixels(new, cw, ch, ox, oy, secondary)
    moveText(text, ox, oy, cw, ch)
  end
  img.px, img.w, img.h, img.pw, img.ph, img.text = new.px, cw, ch, new.pw, new.ph, text
  endOp()
  clampView(d)
  setStatus(("Image scaled to %dx%d"):format(nw, nh))
end

local function sizeMenu()
  local r = choose("Change size of:", { { "Canvas", "canvas" }, { "Image", "image" }, { "Cancel", "c" } })
  if r == "canvas" then resizeCanvas() elseif r == "image" then scaleImage() end
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
  "[ ] brush size  , . brush dither  Z zoom  H text layer",
  "Ctrl: N new  O open  S save  W close tab  Q quit",
  "      Z undo  Y redo  Tab next tab",
  "",
  "Text tool: click to add/select a box, type to edit,",
  "drag to move. Palette L/R = text / background.",
  "Click the size (bottom right) to resize or scale.",
  "Run 'adpaint help' in the shell for command usage.",
  "",
  "Press any key.",
}

menuItems = {
  { "New", "^N", function() local r = prompt("Size WxH: ", NEW_W .. "x" .. NEW_H)
      if not r then return end
      local w, h = r:match("(%d+)%s*[xX, ]%s*(%d+)")
      addDoc(blankDoc(max(1, min(512, tonumber(w) or NEW_W)), max(1, min(512, tonumber(h) or NEW_H)))) end },
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
  { "Scale image...", "", scaleImage },
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
    if sizeHit and x >= sizeHit[1] and x <= sizeHit[2] then sizeMenu(); return end
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
  if #docs == 0 then
    addDoc(blankDoc())
    setStatus("Tip: drop image files here to import", 6)
  end
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
    elseif e == "paste" and sel then textInsert(ev[2])
    elseif e == "file_transfer" then handleFiles(ev[2])
    elseif e == "term_resize" or e == "monitor_resize" then onResize()
    end
    while #pendingFiles > 0 do handleFiles(table.remove(pendingFiles, 1)) end
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
