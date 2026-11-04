-- adview: shows .adi images on a monitor or the terminal, either a single
-- image or a looping slideshow of several files / folders.
-- Run "adview help" for usage.
package.path = "/" .. fs.combine(fs.getDir(shell.getRunningProgram()), "?.lua") .. ";" .. package.path
local adimg = require("lib.adimg")

local floor = math.floor

local USAGE = [[
Usage:
 adview <file|folder> ... [options]
   -m, --monitor <side>  show on a monitor
       --mode <m>        compromise (default), bars
                         or fill (monitor text scale)
   -t, --time <s>        seconds per image (10)
   -o, --order <o>       random (default) or name
 adview setup            completion at every boot
 adview help             this text

Modes: bars shows the whole image (bars around it),
fill covers the monitor (crops the image), and
compromise picks the scale with the least bars +
cropping combined (cropping counts double).
Several images (or a folder) loop as a slideshow.
Files are re-read every round, so edits and new
files show up automatically. Ctrl+T stops it.]]

---------------------------------------------------------------------------
-- Shell integration
---------------------------------------------------------------------------
local VALUE_OPTS = { ["-t"] = true, ["--time"] = true }
local OPTS = { "--monitor", "--mode", "--time", "--order" }

local function completeArgs(sh, index, text, previous)
  local ok, c = pcall(require, "cc.shell.completion")
  if not ok then return {} end
  local prev = previous[#previous]
  if VALUE_OPTS[prev] then return {} end
  if prev == "-m" or prev == "--monitor" then return c.peripheral(sh, text, previous, true) end
  if prev == "--mode" then return c.choice(sh, text, previous, { "compromise", "bars", "fill" }, true) end
  if prev == "-o" or prev == "--order" then return c.choice(sh, text, previous, { "random", "name" }, true) end
  if text:sub(1, 1) == "-" then return c.choice(sh, text, previous, OPTS, true) end
  local out = {}
  if index == 1 then
    for _, v in ipairs(c.choice(sh, text, previous, { "help", "setup" }, true)) do out[#out + 1] = v end
  end
  for _, v in ipairs(c.dirOrFile(sh, text, previous, true)) do out[#out + 1] = v end
  return out
end

if shell.setCompletionFunction then
  shell.setCompletionFunction(shell.getRunningProgram(), completeArgs)
end

local SETUP_MARK = "-- adview: filename completion"
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
    target = "/startup/adview-complete.lua"
    local h = fs.open(target, "w")
    h.write(line .. "\n")
    h.close()
  end
  print("Added completion to " .. target .. ".")
end

---------------------------------------------------------------------------
-- Arguments
---------------------------------------------------------------------------
local args = { ... }
if args[1] == "--register" then return end
if #args == 0 or args[1] == "help" or args[1] == "-h" or args[1] == "--help" or args[1] == "-?" then
  textutils.pagedPrint(USAGE)
  return
end
if args[1] == "setup" then setup(); return end

local paths, monSide = {}, nil
local mode, duration, order = "compromise", 10, "random"
do
  local i = 1
  while i <= #args do
    local a, v = args[i], args[i + 1]
    if a == "-m" or a == "--monitor" then monSide = v; i = i + 2
    elseif a == "--mode" then
      mode = (v or ""):lower()
      if mode ~= "compromise" and mode ~= "bars" and mode ~= "fill" then
        printError("--mode must be compromise, bars or fill"); return
      end
      i = i + 2
    elseif a == "-t" or a == "--time" then
      duration = tonumber(v)
      if not duration or duration <= 0 then printError("--time needs a number of seconds"); return end
      i = i + 2
    elseif a == "-o" or a == "--order" then
      order = (v or ""):lower()
      if order ~= "random" and order ~= "name" then printError("--order must be random or name"); return end
      i = i + 2
    elseif a:sub(1, 1) == "-" then printError("Unknown option " .. a); return
    else paths[#paths + 1] = a; i = i + 1 end
  end
end
-- old style "adview <file> <monitor side>"
if not monSide and #paths == 2 and not fs.exists(shell.resolve(paths[2]))
  and peripheral.getType(paths[2]) == "monitor" then
  monSide = table.remove(paths)
end
if #paths == 0 then printError("No image given. See 'adview help'."); return end
for _, p in ipairs(paths) do
  if not fs.exists(shell.resolve(p)) then printError("Not found: " .. p); return end
end

local out = term.current()
local isMonitor = false
if monSide then
  out = peripheral.wrap(monSide)
  if not out or peripheral.getType(monSide) ~= "monitor" then printError("No monitor on " .. monSide); return end
  isMonitor = true
end

-- All .adi files named on the command line (folders are expanded).
local function gather()
  local list = {}
  for _, p in ipairs(paths) do
    local path = shell.resolve(p)
    if fs.isDir(path) then
      for _, name in ipairs(fs.list(path)) do
        local f = fs.combine(path, name)
        if not fs.isDir(f) and name:lower():match("%.adi$") then list[#list + 1] = f end
      end
    elseif fs.exists(path) then
      list[#list + 1] = path
    end
  end
  table.sort(list, function(a, b) return fs.getName(a):lower() < fs.getName(b):lower() end)
  return list
end

---------------------------------------------------------------------------
-- Display
---------------------------------------------------------------------------
-- Monitor size at every text scale (measured once; changing scale is slow).
local sizes
local function measure()
  sizes = {}
  for scale = 0.5, 5, 0.5 do
    out.setTextScale(scale)
    local w, h = out.getSize()
    sizes[#sizes + 1] = { scale, w, h }
  end
end

-- Picks a text scale for an image of w x h cells according to `mode`.
local function chooseScale(w, h)
  local best, bestCost
  for k = #sizes, 1, -1 do -- largest scale first, so ties keep the bigger text
    local s = sizes[k]
    local mw, mh = s[2], s[3]
    local vis = math.min(w, mw) * math.min(h, mh)
    local crop, bars = 1 - vis / (w * h), 1 - vis / (mw * mh)
    local ok, cost
    if mode == "bars" then ok, cost = crop == 0, -s[1]      -- biggest scale that fits
    elseif mode == "fill" then ok, cost = bars == 0, s[1]   -- smallest that still covers
    else ok, cost = true, 2 * crop + bars end -- losing picture is worse than bars
    if ok and (not bestCost or cost < bestCost - 1e-9) then best, bestCost = s, cost end
  end
  if not best then -- nothing qualifies: get as close as possible
    best = mode == "bars" and sizes[1] or sizes[#sizes]
  end
  return best[1]
end

-- The most common colour along the image's edge, used for the bars.
local function edgeColour(img)
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

local function show(img)
  if isMonitor then out.setTextScale(chooseScale(img.w, img.h)) end
  local mw, mh = out.getSize()
  -- draw into a hidden window so the palette and picture switch at once
  local win = window.create(out, 1, 1, mw, mh, false)
  adimg.applyPalette(win, img.palette)
  win.setBackgroundColour(2 ^ adimg.HEX_TO_IDX[edgeColour(img)])
  win.clear()
  local x0 = floor((mw - img.w) / 2) + 1
  local y0 = floor((mh - img.h) / 2) + 1
  local skip = x0 < 1 and 1 - x0 or 0 -- columns cropped on the left
  local rows = adimg.compose(img)
  for cy = 1, img.h do
    local y = y0 + cy - 1
    if y >= 1 and y <= mh then
      local r = rows[cy]
      local a, b = skip + 1, skip + mw
      win.setCursorPos(math.max(1, x0), y)
      win.blit(r[1]:sub(a, b), r[2]:sub(a, b), r[3]:sub(a, b))
    end
  end
  win.setVisible(true)
end

local function restoreTerminal()
  if not isMonitor then
    adimg.applyPalette(out)
    out.setBackgroundColour(colours.black)
    out.setTextColour(colours.white)
    out.clear()
    out.setCursorPos(1, 1)
  end
end

if isMonitor then measure() end

local list = gather()
if #list == 0 then printError("No .adi files found."); return end

-- A single image: show it. On a monitor it stays up after adview exits.
if #list == 1 and not fs.isDir(shell.resolve(paths[1])) then
  local img, err = adimg.load(list[1])
  if not img then printError(err); return end
  show(img)
  if not isMonitor then
    os.pullEvent("key")
    restoreTerminal()
  end
  return
end

-- Slideshow
if isMonitor then print(("Showing %d image(s) on %s. Ctrl+T to stop."):format(#list, monSide)) end
local last, current = nil, nil
while true do
  local round = gather()
  if order == "random" then
    for i = #round, 2, -1 do
      local j = math.random(i)
      round[i], round[j] = round[j], round[i]
    end
    -- don't show the same image twice in a row across rounds
    if #round > 1 and round[1] == last then round[1], round[#round] = round[#round], round[1] end
  end
  if #round == 0 then round = { false } end
  for _, path in ipairs(round) do
    local img = path and adimg.load(path)
    if img then current = img; show(img); last = path end
    local timer = os.startTimer(duration)
    while true do
      local ev = { os.pullEventRaw() }
      if ev[1] == "timer" and ev[2] == timer then break
      elseif ev[1] == "terminate" or (not isMonitor and ev[1] == "key" and ev[2] == keys.q) then
        restoreTerminal()
        print("Stopped.")
        return
      elseif (ev[1] == "monitor_resize" and isMonitor and ev[2] == monSide) or
             (ev[1] == "term_resize" and not isMonitor) then
        if isMonitor then measure() end
        if current then show(current) end
      end
    end
  end
end
