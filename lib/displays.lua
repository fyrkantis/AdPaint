-- displays: finding, numbering and drawing on monitors (and the terminal),
-- for programs that show .adi images: picking text scales, drawing an image
-- centred with bars in its edge colour, centred text, "No image".
--
--   local displays = require("lib.displays")
--   local list, err = displays.find({ names = { { name = "top", number = 2 } },
--                                      adjacent = true, network = true })
--   displays.number(list, { 1, 2, 3 })
--   for _, d in ipairs(list) do displays.measure(d); displays.drawImage(d, img, "bars") end
--
-- A display is { name, out (term-like object), isMonitor, number,
-- sizes (monitors: { {scale, w, h}, ... } after measure) }; the terminal is
-- the display named "terminal" ("term" is accepted when finding).
local adimg = require("lib.formats.adimg")

local M = {}
local floor, max, min = math.floor, math.max, math.min

-- Text scales a monitor supports.
M.SCALES = { 0.5, 1, 1.5, 2, 2.5, 3, 3.5, 4, 4.5, 5 }

function M.isMonitor(name)
  if peripheral.hasType then return peripheral.hasType(name, "monitor") == true end
  return peripheral.getType(name) == "monitor"
end

-- "monitor_2" before "monitor_10".
function M.naturalLess(a, b)
  local function pad(s) return (s:gsub("%d+", function(n) return ("%012d"):format(tonumber(n)) end)) end
  return pad(a) < pad(b)
end

-- Monitors on the sides of this computer, in redstone.getSides() order.
function M.adjacentNames()
  local out = {}
  for _, side in ipairs(redstone.getSides()) do
    if M.isMonitor(side) then out[#out + 1] = side end
  end
  return out
end

-- Monitors reached through modems (not on a side), naturally sorted.
function M.networkNames()
  local sides, out = {}, {}
  for _, side in ipairs(redstone.getSides()) do sides[side] = true end
  for _, name in ipairs(peripheral.getNames()) do
    if not sides[name] and M.isMonitor(name) then out[#out + 1] = name end
  end
  table.sort(out, M.naturalLess)
  return out
end

-- Builds the display list, in this order: opts.names ({ name, number? }
-- entries; "term" is the terminal), then adjacent monitors (opts.adjacent),
-- then network monitors (opts.network). Duplicates are left out. With
-- nothing found and no names asked for, the terminal is used (unless
-- opts.noTerminal). Returns list, byName or nil, error.
function M.find(opts)
  local list, byName = {}, {}
  local function add(name, number)
    local isTerm = name == "term" or name == "terminal"
    if isTerm then name = "terminal" end
    local d = byName[name]
    if d then
      if number then d.number = number end
      return true
    end
    if isTerm then d = { name = name, out = term.current(), isMonitor = false }
    elseif M.isMonitor(name) then d = { name = name, out = peripheral.wrap(name), isMonitor = true }
    else return false end
    d.number = number
    list[#list + 1] = d
    byName[name] = d
    return true
  end
  for _, s in ipairs(opts.names or {}) do
    if not add(s.name, s.number) then return nil, "No monitor called " .. s.name end
  end
  if opts.adjacent then for _, n in ipairs(M.adjacentNames()) do add(n) end end
  if opts.network then for _, n in ipairs(M.networkNames()) do add(n) end end
  if #list == 0 then
    if (opts.adjacent or opts.network) and #(opts.names or {}) == 0 or opts.noTerminal then
      return nil, "No monitors found."
    end
    add("term")
  end
  return list, byName
end

-- Numbers the displays: numbers already set are kept, then `list` (if
-- given) numbers the rest in order, and any still without one get the next
-- number after the highest so far (so by default 1, 2, 3, ...).
function M.number(list, numbers)
  if numbers then
    for i, d in ipairs(list) do
      if numbers[i] and not d.number then d.number = numbers[i] end
    end
  end
  local highest = 0
  for _, d in ipairs(list) do
    if not d.number then d.number = highest + 1 end
    highest = max(highest, d.number)
  end
  return list
end

-- "1: left, 2: monitor_0, ..."
function M.describe(list)
  local parts = {}
  for _, d in ipairs(list) do parts[#parts + 1] = d.number .. ": " .. d.name end
  return table.concat(parts, ", ")
end

---------------------------------------------------------------------------
-- Text scales
---------------------------------------------------------------------------
-- Measures a monitor's size at every text scale (changing scale is slow, so
-- do it once, and again on monitor_resize). Safe on a detached monitor.
function M.measure(d)
  if not d.isMonitor then return end
  local sizes = {}
  pcall(function()
    for _, scale in ipairs(M.SCALES) do
      d.out.setTextScale(scale)
      local w, h = d.out.getSize()
      sizes[#sizes + 1] = { scale, w, h }
    end
  end)
  if #sizes == 0 then sizes[1] = { 0.5, 1, 1 } end
  d.sizes = sizes
end

-- Picks a text scale for an image of w x h cells. mode: "bars" (biggest
-- scale at which it all fits), "fill" (smallest that covers the monitor)
-- or "compromise" (least bars + cropping, cropping counting double).
function M.chooseScale(d, w, h, mode)
  local best, bestCost
  for k = #d.sizes, 1, -1 do -- largest scale first, so ties keep the bigger text
    local s = d.sizes[k]
    local mw, mh = s[2], s[3]
    local vis = min(w, mw) * min(h, mh)
    local crop, bars = 1 - vis / (w * h), 1 - vis / (mw * mh)
    local ok, cost
    if mode == "bars" then ok, cost = crop == 0, -s[1]
    elseif mode == "fill" then ok, cost = bars == 0, s[1]
    else ok, cost = true, 2 * crop + bars end
    if ok and (not bestCost or cost < bestCost - 1e-9) then best, bestCost = s, cost end
  end
  if not best then -- nothing qualifies: get as close as possible
    best = mode == "bars" and d.sizes[1] or d.sizes[#d.sizes]
  end
  return best[1]
end

-- The largest measured scale at which a w x h block of text fits with
-- `room` times its width and a free row above and below (else 0.5).
function M.textScale(d, w, h, room)
  for k = #d.sizes, 1, -1 do
    local s = d.sizes[k]
    if s[2] >= w * (room or 1) and s[3] >= h + 2 then return s[1] end
  end
  return 0.5
end

-- Sets the largest text scale up to `want` at which fits(w, h) is true
-- (trying scales downwards; 0.5 if none fits) and returns it. Only scales
-- that differ from the current one are set.
function M.fitScale(mon, want, fits)
  local sc = max(0.5, min(5, floor(want * 2 + 0.5) / 2))
  while true do
    if mon.getTextScale() ~= sc then mon.setTextScale(sc) end
    if sc <= 0.5 or fits(mon.getSize()) then return sc end
    sc = sc - 0.5
  end
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------
-- The most common colour (hex digit) along an image's edge, used for bars.
function M.edgeColour(img)
  local count, best, bc = {}, "f", -1
  local function add(c) count[c] = (count[c] or 0) + 1; if count[c] > bc then best, bc = c, count[c] end end
  for cy = 1, img.h do
    local bg = img.rows[cy][3]
    if cy == 1 or cy == img.h then
      for cx = 1, img.w do add(bg:sub(cx, cx)) end
    else
      add(bg:sub(1, 1)); add(bg:sub(-1))
    end
  end
  return best
end

-- Shows an image (loaded, or with .px only, e.g. from convert) centred on the
-- display, choosing the text scale by `mode` on monitors; bars around it
-- use its edge colour, and it is cropped when bigger. The palette and the
-- picture switch at once.
function M.drawImage(d, img, mode)
  local out = d.out
  if not img.rows then adimg.rowsFromPixels(img) end -- e.g. fresh from convert
  if d.isMonitor then
    if not d.sizes then M.measure(d) end
    out.setTextScale(M.chooseScale(d, img.w, img.h, mode or "compromise"))
  end
  local mw, mh = out.getSize()
  local win = window.create(out, 1, 1, mw, mh, false)
  adimg.applyPalette(win, img.palette)
  win.setBackgroundColour(2 ^ adimg.HEX_TO_IDX[M.edgeColour(img)])
  win.clear()
  local x0 = floor((mw - img.w) / 2) + 1
  local y0 = floor((mh - img.h) / 2) + 1
  local skip = x0 < 1 and 1 - x0 or 0 -- columns cropped on the left
  local rows = img.composed or adimg.compose(img)
  img.composed = rows
  for cy = 1, img.h do
    local y = y0 + cy - 1
    if y >= 1 and y <= mh then
      local r = rows[cy]
      local a, b = skip + 1, skip + mw
      win.setCursorPos(max(1, x0), y)
      win.blit(r[1]:sub(a, b), r[2]:sub(a, b), r[3]:sub(a, b))
    end
  end
  win.setVisible(true)
end

-- Centred lines of text on black (default palette): the first line in
-- colour `fg`, the rest light grey. Monitors get a scale at which the text
-- takes about half the width.
function M.drawText(d, lines, fg)
  local out = d.out
  local w = 0
  for _, l in ipairs(lines) do w = max(w, #l) end
  if d.isMonitor then
    if not d.sizes then M.measure(d) end
    out.setTextScale(M.textScale(d, w, #lines, 2))
  end
  adimg.applyPalette(out)
  out.setBackgroundColour(colors.black)
  out.clear()
  local mw, mh = out.getSize()
  local y0 = floor((mh - #lines) / 2) + 1
  for i, l in ipairs(lines) do
    out.setTextColour(i == 1 and (fg or colors.white) or colors.lightGray)
    out.setCursorPos(floor((mw - #l) / 2) + 1, y0 + i - 1)
    out.write(l)
  end
end

-- Default palette, black, cursor home.
function M.clear(d)
  adimg.applyPalette(d.out)
  d.out.setBackgroundColour(colors.black)
  d.out.setTextColour(colors.white)
  d.out.clear()
  d.out.setCursorPos(1, 1)
end

-- Runs fn(d) without letting one display (e.g. one that was unplugged)
-- stop the others. Returns whether it worked.
function M.try(fn, d, ...)
  return (pcall(fn, d, ...))
end

return M
