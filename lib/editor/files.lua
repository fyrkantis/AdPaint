-- Editor file handling: open, import (with its questions), save, close
-- tabs, quit, and files dropped onto the window.
local adimg = require("lib.formats.adimg")
local cli = require("lib.cli")
local features = require("lib.features")

local floor, max, min = math.floor, math.max, math.min

return function(ed)
  local U = ed.U
  local convert -- loaded on first import (keeps start-up light)

  function ed.completePath(text)
    return fs.complete(text, shell.dir(), true, true)
  end

  local function busy(msg)
    ed.setStatus(msg, 60)
    ed.draw()
  end

  -- Yield helper for long work that keeps files dropped meanwhile.
  function ed.yielder()
    return cli.yielder(function(ev)
      if ev[1] == "file_transfer" then ed.pendingFiles[#ed.pendingFiles + 1] = ev[2] end
    end)
  end

  -- Opens file contents `data` (named `name`) in a new tab: .adi files
  -- directly, images after asking how to import them.
  function ed.importData(name, data)
    if data:sub(1, 6) == "ADIMG " then
      local img, err = adimg.parse(data, true)
      if not img then ed.setStatus(name .. ": " .. err); return end
      local d = ed.newDoc(img, shell.resolve(fs.getName(name)))
      ed.addDoc(d)
      return d
    end
    if not features.import then
      ed.setStatus(fs.getName(name) .. ": only .adi files in adpaint lite", 8)
      return
    end
    convert = convert or require("lib.convert")
    local info, err = convert.info(data)
    if not info then ed.setStatus(name .. ": " .. tostring(err)); return end
    local dw = convert.fitCells(info, ed.W, ed.viewH())
    ed.setStatus(("%s: %dx%d %s"):format(fs.getName(name), info.dw, info.dh, info.format:upper()), 30)
    local r = U.prompt("Width (cells): ", tostring(dw))
    if not r then return end
    local cw = max(1, min(512, tonumber(r) or dw))
    local _, dh = convert.fitCells(info, cw, math.huge)
    r = U.prompt("Height (cells): ", tostring(dh))
    if not r then return end
    local ch = max(1, min(512, tonumber(r) or dh))
    local mode, ax, ay = "stretch", 0.5, 0.5
    if ch ~= dh then
      mode, ax, ay = ed.chooseScaleMode()
      if not mode then return end
    end
    -- Palette PNGs are usually pixel art / logos, which tend to look best
    -- undithered, so "None" is offered first there (Enter picks it).
    local opts = { { "Dither", true }, { "None", false } }
    if info.indexed then opts[1], opts[2] = opts[2], opts[1] end
    opts[3] = { "Cancel", "c" }
    local dith = U.choose("Dithering:", opts)
    if dith == nil or dith == "c" then return end
    local opt = U.choose("Palette:", { { "Optimised", true }, { "Default", false }, { "Cancel", "c" } })
    if opt == nil or opt == "c" then return end
    r = U.prompt("Colours to use (2-16): ", "16")
    if not r then return end
    local ncol = max(2, min(16, floor(tonumber(r) or 16)))
    busy("Importing...")
    local ok, img, ierr = pcall(convert.import, data, {
      w = cw, h = ch, dither = dith, optimise = opt, colours = ncol,
      mode = mode, ax = ax, ay = ay,
      background = ed.palette()[ed.secondary],
      yield = ed.yielder(),
      status = function(m) busy(m) end,
    })
    if not ok then ierr = img; img = nil end
    if not img then ed.setStatus("Import failed: " .. tostring(ierr), 8); return end
    local base = fs.getName(name):gsub("%.[^%.]*$", "")
    local d = ed.newDoc(img, shell.resolve(base .. ".adi"))
    d.dirty = true
    ed.addDoc(d)
    ed.setStatus("Imported " .. fs.getName(name))
    return d
  end

  function ed.openPath(path)
    path = shell.resolve(path)
    for i, d in ipairs(ed.docs) do
      if d.path == path then ed.cur = i; ed.applyPalette(); return d end
    end
    if not fs.exists(path) or fs.isDir(path) then
      -- a new file: blank canvas that will be saved under this name
      local d = ed.blankDoc()
      d.path = path
      ed.addDoc(d)
      ed.setStatus("New file " .. fs.getName(path))
      return d
    end
    local data = cli.readFile(path)
    if not data then ed.setStatus("Cannot read " .. path); return end
    if data:sub(1, 6) == "ADIMG " then
      local img, err = adimg.parse(data, true)
      if not img then ed.setStatus(err); return end
      local d = ed.newDoc(img, path)
      ed.addDoc(d)
      return d
    end
    return ed.importData(path, data)
  end

  function ed.openDialog()
    local r = U.prompt("Open: ", "", ed.completePath)
    if r and r ~= "" then ed.openPath(r) end
  end

  function ed.importDialog() -- only in the menu when features.import
    local r = U.prompt("Image file: ", "", ed.completePath)
    if r and r ~= "" then
      local data = cli.readFile(shell.resolve(r))
      if data then ed.importData(r, data) else ed.setStatus("Cannot read " .. r) end
    end
  end

  -- Saves a tab (asking for a name if it has none, or if `as`). Returns true
  -- if it was saved.
  function ed.saveDoc(d, as)
    d = d or ed.doc()
    local path = d.path
    if as or not path then
      local r = U.prompt("Save as: ", path and ("/" .. path) or "untitled.adi", ed.completePath)
      if not r or r == "" then return false end
      path = shell.resolve(r)
      if fs.isReadOnly(path) then ed.setStatus("Read-only location"); return false end
      if fs.exists(path) and path ~= d.path and not U.confirm(fs.getName(path) .. " exists. Overwrite?") then
        return false
      end
    end
    if ed.sel and ed.docs[ed.cur] == d then ed.deselect() end
    local ok, err = adimg.save(d.img, path)
    if not ok then ed.setStatus("Save failed: " .. tostring(err)); return false end
    d.path, d.dirty = path, false
    ed.setStatus("Saved " .. fs.getName(path))
    return true
  end

  -- Closes tab i (asking to save changes). Returns false if cancelled.
  function ed.closeDoc(i)
    local d = ed.docs[i]
    if i == ed.cur then ed.deselect() end
    if d.dirty then
      ed.cur = i; ed.applyPalette()
      local r = U.choose("Save " .. ed.docName(d) .. "?",
        { { "Save", "y" }, { "Discard", "n" }, { "Cancel", "c" } })
      if r == "y" then if not ed.saveDoc(d) then return false end
      elseif r ~= "n" then return false end
    end
    table.remove(ed.docs, i)
    if #ed.docs == 0 then
      if not ed.running then return true end
      ed.addDoc(ed.blankDoc())
    end
    ed.cur = min(ed.cur, #ed.docs)
    if i < ed.cur then ed.cur = ed.cur - 1 end
    ed.applyPalette()
    return true
  end

  function ed.quit()
    ed.running = false
    while #ed.docs > 0 do
      if not ed.closeDoc(#ed.docs) then ed.running = true; return end
    end
  end

  -- Imports every file of a file_transfer event (files dropped on the window).
  function ed.handleFiles(transfer)
    for _, h in ipairs(transfer.getFiles()) do
      local name = h.getName()
      local data = h.readAll() or ""
      h.close()
      ed.importData(name, data)
    end
  end
end
