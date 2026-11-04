-- adview: shows an .adi image on a monitor (or the terminal).
-- Usage: adview <file.adi> [monitor side]
-- Picks the largest text scale at which the whole image fits, and centres it.
package.path = "/" .. fs.combine(fs.getDir(shell.getRunningProgram()), "?.lua") .. ";" .. package.path
local adimg = require("lib.adimg")

local args = { ... }
if not args[1] then print("Usage: adview <file.adi> [monitor side]"); return end
local img, err = adimg.load(shell.resolve(args[1]))
if not img then printError(err); return end

local out = term.current()
if args[2] then
  out = peripheral.wrap(args[2])
  if not out then printError("No monitor on " .. args[2]); return end
  for scale = 5, 0.5, -0.5 do
    out.setTextScale(scale)
    local w, h = out.getSize()
    if w >= img.w and h >= img.h then break end
  end
end

local w, h = out.getSize()
adimg.applyPalette(out, img.palette)
out.setBackgroundColour(colours.black)
out.clear()
adimg.draw(img, out, math.floor((w - img.w) / 2) + 1, math.floor((h - img.h) / 2) + 1)
if out == term.current() then
  os.pullEvent("key")
  adimg.applyPalette(out)
  out.clear(); out.setCursorPos(1, 1)
end
