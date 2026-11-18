-- adpaint: image editor for .adi advertisement images (CC: Tweaked).
-- Run "adpaint help" for usage.
--
-- This file handles the command line (help, setup, convert) and starts the
-- editor, which lives in lib/editor/ (see lib/editor/app.lua).

local progDir = fs.getDir(shell.getRunningProgram())
package.path = "/" .. fs.combine(progDir, "?.lua") .. ";" .. package.path
local cli = require("lib.cli")
local features = require("lib.features")

local USAGE_OPEN = features.import and [[
Usage:
 adpaint [file ...]   open .adi files in tabs; PNG,
                      JPEG and BMP files are imported
]] or [[
Usage (adpaint lite: no image import):
 adpaint [file ...]   open .adi files in tabs
]]
local USAGE_MONITOR = [[
 adpaint -m <side> [-s <scale>] [file ...]
                      paint on an advanced monitor;
                      -s text scale 0.5-5 (default:
                      setting adpaint.text_scale)
]]
local USAGE_CONVERT = [[
 adpaint convert <image> [out.adi] [options]
   -w, --width <n>    width in cells (default: fit
                      this terminal)
       --height <n>   height (default: keep aspect)
   -c, --colours <n>  colours to use, 2-16 (16)
   -p, --palette <p>  optimised (default) or default
   -n, --no-dither    don't dither
       --mode <m>     bars (default)/fill/stretch
                      when the aspect ratio changes
   -f, --force        overwrite out.adi
]]
local USAGE_END = [[
 adpaint setup        filename completion at boot
 adpaint help         this text

While adpaint runs, drag ]] .. (features.import and [[image files from your
computer onto its window to import them.]] or [[.adi files from your
computer onto its window to open them.]])
local USAGE = USAGE_OPEN .. USAGE_MONITOR .. (features.import and USAGE_CONVERT or "") .. USAGE_END

---------------------------------------------------------------------------
-- Shell integration: argument completion, "setup", "convert"
---------------------------------------------------------------------------
local NUMBER_OPTS = { ["-w"] = true, ["--width"] = true, ["--height"] = true, ["-c"] = true,
                      ["--colours"] = true, ["--colors"] = true, ["-s"] = true }
local CONVERT_OPTS = { "--width", "--height", "--colours", "--palette", "--no-dither", "--mode", "--force" }

local function completeArgs(sh, index, text, previous)
  local c = cli.completion()
  if not c then return {} end
  local prev = previous[#previous]
  if NUMBER_OPTS[prev] then return {} end
  if prev == "-m" then return c.peripheral(sh, text, previous, true) end
  if prev == "--mode" then return c.choice(sh, text, previous, { "bars", "fill", "stretch" }, true) end
  if prev == "-p" or prev == "--palette" then
    return c.choice(sh, text, previous, { "optimised", "default" }, true)
  end
  local isConvert = previous[2] == "convert"
  if text:sub(1, 1) == "-" then
    return c.choice(sh, text, previous, isConvert and CONVERT_OPTS or { "-m", "-s" }, true)
  end
  local out = {}
  if index == 1 then
    cli.addChoices(out, c.choice(sh, text, previous,
      features.import and { "help", "convert", "setup" } or { "help", "setup" }, true))
  end
  return cli.addChoices(out, c.dirOrFile(sh, text, previous, true))
end
cli.registerCompletion(completeArgs)

local function setup()
  cli.setup("-- adpaint: filename completion", "/startup/adpaint.lua", "It is active now and after every reboot.")
end

local function cliConvert(argv)
  local opt = {}
  local input, output, force
  local i = 1
  while i <= #argv do
    local a = argv[i]
    local v = argv[i + 1]
    if a == "-w" or a == "--width" then opt.w = tonumber(v); i = i + 2
    elseif a == "--height" then opt.h = tonumber(v); i = i + 2
    elseif a == "-c" or a == "--colours" or a == "--colors" then opt.colours = tonumber(v); i = i + 2
    elseif a == "-p" or a == "--palette" then opt.optimise = (v or ""):sub(1, 1):lower() ~= "d"; i = i + 2
    elseif a == "-n" or a == "--no-dither" then opt.dither = false; i = i + 1
    elseif a == "--mode" then
      opt.mode = (v or ""):lower()
      if opt.mode == "bars" then opt.mode = "fit" end -- "fit" still accepted
      if opt.mode ~= "fit" and opt.mode ~= "fill" and opt.mode ~= "stretch" then
        printError("--mode must be bars, fill or stretch"); return
      end
      i = i + 2
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
  local convert = require("lib.convert")
  local adimg = require("lib.formats.adimg")
  opt.yield = cli.yielder()
  opt.status = print
  local img, err = convert.convertFile(inPath, opt)
  if not img then printError(input .. ": " .. tostring(err)); return end
  local sok, serr = adimg.save(img, output)
  if not sok then printError("Save failed: " .. tostring(serr)); return end
  print(("Saved %s (%dx%d cells)"):format(output, img.w, img.h))
end

---------------------------------------------------------------------------
-- Arguments
---------------------------------------------------------------------------
local args = { ... }
local command = args[1]
if command == "--register" then return end
if cli.isHelp(command) then
  textutils.pagedPrint(USAGE)
  return
end
if command == "setup" then setup(); return end
if command == "convert" then
  if not features.import then
    printError("This is adpaint lite, which can't convert images. Use the full adpaint for that.")
    return
  end
  cliConvert({ table.unpack(args, 2) })
  return
end

settings.define("adpaint.text_scale", {
  description = "Default text scale when adpaint runs on a monitor (-m).",
  default = 0.5, type = "number",
})
local files, monSide, monScale = {}, nil, settings.get("adpaint.text_scale") or 0.5
do
  local i = 1
  while i <= #args do
    if args[i] == "-m" then monSide = args[i + 1]; i = i + 2
    elseif args[i] == "-s" then monScale = tonumber(args[i + 1]) or monScale; i = i + 2
    else files[#files + 1] = args[i]; i = i + 1 end
  end
end

require("lib.editor.app").run(files, monSide, monScale)
