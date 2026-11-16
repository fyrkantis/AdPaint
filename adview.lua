-- adview: shows .adi images on monitors and/or the terminal: a single image,
-- or a looping slideshow of files and folders on any number of numbered
-- displays. Run "adview help" for usage.
package.path = "/" .. fs.combine(fs.getDir(shell.getRunningProgram()), "?.lua") .. ";" .. package.path
local adimg = require("lib.adimg")
local cli = require("lib.cli")

local floor, max, min = math.floor, math.max, math.min

local USAGE = [[
Usage:
 adview <file|folder> ... [options]
Displays (default: this terminal):
 -m, --monitor <name>[=<n>]
                  a monitor ("term" = terminal),
                  optionally with its number;
                  repeat or separate with commas
 -a, --adjacent   add monitors next to the computer
 -n, --network    add monitors on wired modems
     --numbers <list>  numbers for the displays in
                  order, e.g. 1,2,3,1,2,3
     --identify   show each display's number
Showing:
     --mode <m>   compromise (default), bars, fill
 -t, --time <s>   seconds per ad (10)
 -o, --order <o>  random (default) or name
 adview setup     completion at every boot
 adview help      this text

Displays are numbered 1, 2, 3... in the order
-m, adjacent, network, unless a number is given
(-m top=2 or --numbers); one without gets the
next number after the highest so far. Displays
may share a number.
In a folder every .adi file is an ad and every
subfolder is one ad of several images: sorted by
name, image 1 goes to display(s) 1, image 2 to
display(s) 2, ... starting over when there are
more displays than images. The folder is
re-read after every ad, so files can be added,
changed or removed while adview runs.
Modes: bars shows the whole image (bars around
it), fill covers the monitor (crops the image),
compromise picks the scale with the least bars +
cropping (cropping counts double).
Ctrl+T stops (or Q on the terminal).]]

---------------------------------------------------------------------------
-- Shell integration
---------------------------------------------------------------------------
local VALUE_OPTS = { ["-t"] = true, ["--time"] = true, ["--numbers"] = true }
local OPTS = { "--monitor", "--adjacent", "--network", "--numbers", "--identify", "--mode", "--time", "--order" }

local function completeArgs(sh, index, text, previous)
  local c = cli.completion()
  if not c then return {} end
  local prev = previous[#previous]
  if VALUE_OPTS[prev] then return {} end
  if prev == "-m" or prev == "--monitor" then
    local out = c.peripheral(sh, text, previous, false)
    return cli.addChoices(out, c.choice(sh, text, previous, { "term" }, false))
  end
  if prev == "--mode" then return c.choice(sh, text, previous, { "compromise", "bars", "fill" }, true) end
  if prev == "-o" or prev == "--order" then return c.choice(sh, text, previous, { "random", "name" }, true) end
  if text:sub(1, 1) == "-" then return c.choice(sh, text, previous, OPTS, true) end
  local out = {}
  if index == 1 then cli.addChoices(out, c.choice(sh, text, previous, { "help", "setup" }, true)) end
  return cli.addChoices(out, c.dirOrFile(sh, text, previous, true))
end
cli.registerCompletion(completeArgs)

local function setup()
  cli.setup("-- adview: filename completion", "/startup/adview-complete.lua")
end

---------------------------------------------------------------------------
-- Arguments
---------------------------------------------------------------------------
local args = { ... }
if args[1] == "--register" then return end
if #args == 0 or cli.isHelp(args[1]) then
  textutils.pagedPrint(USAGE)
  return
end
if args[1] == "setup" then setup(); return end

local paths, specs, numberList = {}, {}, nil
local adjacent, network, identify = false, false, false
local mode, duration, order = "compromise", 10, "random"
do
  local i = 1
  while i <= #args do
    local a, v = args[i], args[i + 1]
    if a == "-m" or a == "--monitor" then
      if not v then printError(a .. " needs a monitor name"); return end
      for part in v:gmatch("[^,]+") do
        local name, num = part:match("^(.-)=(%d+)$")
        name = name or part
        num = tonumber(num)
        if num and num < 1 then printError("Display numbers start at 1"); return end
        specs[#specs + 1] = { name = name, number = num }
      end
      i = i + 2
    elseif a == "-a" or a == "--adjacent" then adjacent = true; i = i + 1
    elseif a == "-n" or a == "--network" then network = true; i = i + 1
    elseif a == "--identify" then identify = true; i = i + 1
    elseif a == "--numbers" then
      numberList = {}
      for n in (v or ""):gmatch("[^,%s]+") do
        local num = tonumber(n)
        if not num or num < 1 or num ~= floor(num) then
          printError("--numbers needs a list like 1,2,3,1,2,3"); return
        end
        numberList[#numberList + 1] = num
      end
      if #numberList == 0 then printError("--numbers needs a list like 1,2,3,1,2,3"); return end
      i = i + 2
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

local function isMonitorName(name)
  if peripheral.hasType then return peripheral.hasType(name, "monitor") == true end
  return peripheral.getType(name) == "monitor"
end

-- old style "adview <file> <monitor side>"
if #specs == 0 and #paths == 2 and not fs.exists(shell.resolve(paths[2])) and isMonitorName(paths[2]) then
  specs[1] = { name = table.remove(paths) }
end
if #paths == 0 and not identify then printError("No image given. See 'adview help'."); return end
for _, p in ipairs(paths) do
  if not fs.exists(shell.resolve(p)) then printError("Not found: " .. p); return end
end

---------------------------------------------------------------------------
-- Displays (found once, at start-up)
---------------------------------------------------------------------------
-- display: { name, out, isMonitor, number, sizes (monitors), current }
local displays, byName = {}, {}

local function addDisplay(name, number)
  local isTerm = name == "term" or name == "terminal"
  if isTerm then name = "terminal" end
  local d = byName[name]
  if d then
    if number then d.number = number end
    return true
  end
  if isTerm then
    d = { name = name, out = term.current(), isMonitor = false }
  elseif isMonitorName(name) then
    d = { name = name, out = peripheral.wrap(name), isMonitor = true }
  else
    return false
  end
  d.number = number
  displays[#displays + 1] = d
  byName[name] = d
  return true
end

-- "monitor_2" before "monitor_10"
local function naturalLess(a, b)
  local pa, pb = a:gsub("%d+", function(n) return ("%012d"):format(tonumber(n)) end),
                 b:gsub("%d+", function(n) return ("%012d"):format(tonumber(n)) end)
  return pa < pb
end

for _, s in ipairs(specs) do
  if not addDisplay(s.name, s.number) then printError("No monitor called " .. s.name); return end
end
local sides = {}
for _, side in ipairs(redstone.getSides()) do sides[side] = true end
if adjacent then
  for _, side in ipairs(redstone.getSides()) do
    if isMonitorName(side) then addDisplay(side) end
  end
end
if network then
  local names = {}
  for _, name in ipairs(peripheral.getNames()) do
    if not sides[name] and isMonitorName(name) then names[#names + 1] = name end
  end
  table.sort(names, naturalLess)
  for _, name in ipairs(names) do addDisplay(name) end
end
if #displays == 0 then
  if #specs > 0 or not (adjacent or network) then addDisplay("term")
  else printError("No monitors found."); return end
end

-- numbers: given ones are kept; the rest continue after the highest so far
if numberList then
  for i, d in ipairs(displays) do
    if numberList[i] and not d.number then d.number = numberList[i] end
  end
end
do
  local highest = 0
  for _, d in ipairs(displays) do
    if not d.number then d.number = highest + 1 end
    highest = max(highest, d.number)
  end
end

local termDisplay = byName.terminal

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------
-- Monitor size at every text scale (measured once; changing scale is slow).
local function measure(d)
  d.sizes = {}
  for scale = 0.5, 5, 0.5 do
    d.out.setTextScale(scale)
    local w, h = d.out.getSize()
    d.sizes[#d.sizes + 1] = { scale, w, h }
  end
end

-- Picks a text scale for an image of w x h cells according to `mode`.
local function chooseScale(d, w, h)
  local best, bestCost
  for k = #d.sizes, 1, -1 do -- largest scale first, so ties keep the bigger text
    local s = d.sizes[k]
    local mw, mh = s[2], s[3]
    local vis = min(w, mw) * min(h, mh)
    local crop, bars = 1 - vis / (w * h), 1 - vis / (mw * mh)
    local ok, cost
    if mode == "bars" then ok, cost = crop == 0, -s[1]      -- biggest scale that fits
    elseif mode == "fill" then ok, cost = bars == 0, s[1]   -- smallest that still covers
    else ok, cost = true, 2 * crop + bars end -- losing picture is worse than bars
    if ok and (not bestCost or cost < bestCost - 1e-9) then best, bestCost = s, cost end
  end
  if not best then -- nothing qualifies: get as close as possible
    best = mode == "bars" and d.sizes[1] or d.sizes[#d.sizes]
  end
  return best[1]
end

-- The largest text scale at which a w x h block of text fits on the display
-- with `room` times its size around it (falls back to the smallest scale).
local function textScale(d, w, h, room)
  for k = #d.sizes, 1, -1 do
    local s = d.sizes[k]
    if s[2] >= w * room and s[3] >= h + 2 then return s[1] end
  end
  return 0.5
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

local function drawImage(d, img)
  local out = d.out
  if d.isMonitor then out.setTextScale(chooseScale(d, img.w, img.h)) end
  local mw, mh = out.getSize()
  -- draw into a hidden window so the palette and picture switch at once
  local win = window.create(out, 1, 1, mw, mh, false)
  adimg.applyPalette(win, img.palette)
  win.setBackgroundColour(2 ^ adimg.HEX_TO_IDX[edgeColour(img)])
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

-- Centred lines of text on a plain background (default palette).
local function drawText(d, lines, fg)
  local out = d.out
  local w = 0
  for _, l in ipairs(lines) do w = max(w, #l) end
  if d.isMonitor then out.setTextScale(textScale(d, w, #lines, 2)) end
  adimg.applyPalette(out)
  out.setBackgroundColour(colours.black)
  out.clear()
  local mw, mh = out.getSize()
  local y0 = floor((mh - #lines) / 2) + 1
  for i, l in ipairs(lines) do
    out.setTextColour(i == 1 and fg or colors.lightGray)
    out.setCursorPos(floor((mw - #l) / 2) + 1, y0 + i - 1)
    out.write(l)
  end
end

-- d.current: an image, or false for "No image". A display that has gone
-- away (peripheral detached) must not stop the others.
local function redraw(d)
  local ok = pcall(function()
    if d.current then drawImage(d, d.current) else drawText(d, { "No image" }, colors.white) end
  end)
  return ok
end

local function restoreTerminal()
  local out = term.current()
  adimg.applyPalette(out)
  out.setBackgroundColour(colours.black)
  out.setTextColour(colours.white)
  out.clear()
  out.setCursorPos(1, 1)
end

for _, d in ipairs(displays) do
  if d.isMonitor then pcall(measure, d) end
  if d.isMonitor and not d.sizes[1] then d.sizes = { { 0.5, d.out.getSize() } } end
end

-- Waits `seconds` (nil = until a key), redrawing displays that change size.
-- Returns false when the user stops adview.
local function wait(seconds)
  local timer = seconds and os.startTimer(seconds)
  while true do
    local ev = { os.pullEventRaw() }
    local e = ev[1]
    if e == "timer" and ev[2] == timer then return true
    elseif e == "terminate" then return false
    elseif e == "key" and (termDisplay or not seconds) then
      if not seconds or ev[2] == keys.q then return false end
    elseif e == "monitor_resize" and byName[ev[2]] then
      local d = byName[ev[2]]
      pcall(measure, d)
      redraw(d)
    elseif e == "term_resize" and termDisplay then
      redraw(termDisplay)
    end
  end
end

local function describeDisplays()
  local parts = {}
  for _, d in ipairs(displays) do parts[#parts + 1] = d.number .. ": " .. d.name end
  return table.concat(parts, ", ")
end

---------------------------------------------------------------------------
-- --identify: every display shows its number and name
---------------------------------------------------------------------------
if identify then
  for _, d in ipairs(displays) do
    if d ~= termDisplay then pcall(drawText, d, { tostring(d.number), d.name }, colors.yellow) end
  end
  if not termDisplay then
    print("Displays: " .. describeDisplays())
    print("Press any key to clear them.")
  else
    local lines = { "Displays" }
    for _, d in ipairs(displays) do lines[#lines + 1] = d.number .. ": " .. d.name end
    drawText(termDisplay, lines, colors.yellow)
  end
  wait(nil)
  for _, d in ipairs(displays) do
    if d.isMonitor then
      pcall(function() adimg.applyPalette(d.out); d.out.setBackgroundColour(colours.black); d.out.clear() end)
    end
  end
  if termDisplay then restoreTerminal() end
  return
end

---------------------------------------------------------------------------
-- Ads
---------------------------------------------------------------------------
local function isAdi(name) return name:lower():match("%.adi$") ~= nil end

local function sortKey(path) return fs.getName(path):lower() .. "\0" .. path end
local function byKey(a, b) return a.key < b.key end

-- Lists a folder (it may change or vanish at any time).
local function list(dir)
  local ok, names = pcall(fs.list, dir)
  return ok and names or {}
end

-- The ads right now: every file given, and every .adi file / subfolder of
-- the folders given. ad = { path, key, group = true for folders }
local function listAds()
  local ads, seen = {}, {}
  local function add(path, group)
    if seen[path] then return end
    seen[path] = true
    ads[#ads + 1] = { path = path, key = sortKey(path), group = group }
  end
  for _, p in ipairs(paths) do
    local path = shell.resolve(p)
    if fs.isDir(path) then
      for _, name in ipairs(list(path)) do
        local f = fs.combine(path, name)
        if fs.isDir(f) then add(f, true) elseif isAdi(name) then add(f, false) end
      end
    elseif fs.exists(path) then
      add(path, false)
    end
  end
  table.sort(ads, byKey)
  return ads
end

-- The .adi files directly inside a group folder, sorted by name.
local function groupImages(dir)
  local files = {}
  for _, name in ipairs(list(dir)) do
    local f = fs.combine(dir, name)
    if isAdi(name) and not fs.isDir(f) then files[#files + 1] = f end
  end
  table.sort(files, function(a, b) return sortKey(a) < sortKey(b) end)
  return files
end

-- Loaded images, re-read when the file's size or modification time changes.
local cache = {}
local function loadImage(path)
  local okA, attr = pcall(fs.attributes, path)
  local stamp = okA and attr and (tostring(attr.modified or attr.modification) .. ":" .. tostring(attr.size))
  local c = cache[path]
  if c and stamp and c.stamp == stamp then c.used = true; return c.img end
  local ok, img = pcall(adimg.load, path)
  if ok and img and img.w and img.w > 0 and img.h > 0 then
    cache[path] = { stamp = stamp, img = img, used = true }
    return img
  end
  cache[path] = nil
end

-- Shows an ad on every display. Returns false (showing nothing) when none
-- of its images can be loaded.
local function showAd(ad)
  local pick = {}
  if ad.group then
    local files = groupImages(ad.path)
    if #files == 0 then return false end
    local loaded, any = {}, false
    for _, d in ipairs(displays) do
      local idx = (d.number - 1) % #files + 1
      if loaded[idx] == nil then loaded[idx] = loadImage(files[idx]) or false end
      pick[d] = loaded[idx]
      any = any or loaded[idx] ~= false
    end
    if not any then return false end
  else
    local img = loadImage(ad.path)
    if not img then return false end
    for _, d in ipairs(displays) do pick[d] = img end
  end
  for _, d in ipairs(displays) do
    d.current = pick[d]
    redraw(d)
  end
  return true
end

local function showNothing()
  for _, d in ipairs(displays) do
    d.current = false
    redraw(d)
  end
end

-- Picks the next ad from a fresh look at the folders. Returns ad, count.
local queue, lastKey = {}, nil
local function nextAd()
  local ads = listAds()
  -- forget cached images of files that are gone
  local keep = {}
  for path, c in pairs(cache) do if c.used and fs.exists(path) then keep[path] = c; c.used = false end end
  cache = keep
  if #ads == 0 then return nil, 0 end
  local ad
  if order == "name" then
    ad = ads[1]
    if lastKey then
      for _, a in ipairs(ads) do if a.key > lastKey then ad = a; break end end
    end
  else
    -- a shuffled queue of ads; refilled (reshuffled) when used up
    local byPath = {}
    for _, a in ipairs(ads) do byPath[a.path] = a end
    while #queue > 0 and not ad do ad = byPath[table.remove(queue, 1)] end
    if not ad then
      for i = #ads, 2, -1 do
        local j = math.random(i)
        ads[i], ads[j] = ads[j], ads[i]
      end
      -- don't show the same ad twice in a row across rounds
      if #ads > 1 and ads[1].key == lastKey then ads[1], ads[#ads] = ads[#ads], ads[1] end
      for i = 2, #ads do queue[#queue + 1] = ads[i].path end
      ad = ads[1]
    end
  end
  lastKey = ad.key
  return ad, #ads
end

---------------------------------------------------------------------------
-- Run
---------------------------------------------------------------------------
-- A single image file: show it once. Monitors keep it after adview exits.
if #paths == 1 and not fs.isDir(shell.resolve(paths[1])) then
  local img, err = adimg.load(shell.resolve(paths[1]))
  if not img then printError(err); return end
  for _, d in ipairs(displays) do d.current = img; redraw(d) end
  if termDisplay then
    wait(nil)
    restoreTerminal()
  end
  return
end

if not termDisplay then
  print(("adview on %d display(s): %s"):format(#displays, describeDisplays()))
  print("Ctrl+T stops.")
end

while true do
  local shown = false
  local ad, count = nextAd()
  local tries = 0
  while ad and tries < count do
    tries = tries + 1
    if showAd(ad) then shown = true; break end
    if tries < count then ad = nextAd() end
  end
  if not shown then showNothing() end
  if not wait(duration) then break end
end
if termDisplay then restoreTerminal() end
print("Stopped.")
