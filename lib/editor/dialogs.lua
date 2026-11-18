-- Editor dialogs: canvas size / image scale, colour editor, special
-- character picker, palette reset, text scale, new canvas, help.
local adimg = require("lib.formats.adimg")
local paint = require("lib.paint")
local displays = require("lib.displays")
local features = require("lib.features")

local floor, max, min = math.floor, math.max, math.min

local HELP = {
  "adpaint - .adi advertisement image editor",
  "",
  "Left click = primary colour, right = secondary.",
  "Middle drag / arrows / scroll (shift: sideways) pans.",
  features.import and "Drag image files onto the window to import them."
    or "Drag .adi files onto the window to open them.",
  "",
  "B brush  F fill  T text  I pick  P pan",
  "E (or Ctrl+E) edit colour L, with live preview",
  "[ ] brush size  , . brush dither  Z zoom  H text layer",
  "Ctrl: N new  O open  S save  W close tab  Q quit",
  "      Z undo  Y redo  E edit colour L  Tab next tab",
  "Arrows at the top right: undo / redo.",
  "",
  "Text tool: click to add/select a box, type to edit,",
  "drag or use the arrows to move. Palette L/R = text /",
  "background. Chars inserts special characters.",
  "Monitors: tap 'Sets L' to switch L/R; Pan: tap a spot.",
  "Click the size (bottom right) to resize or scale.",
  "Run 'adpaint help' in the shell for command usage.",
}

-- Characters the CC font draws that can't be typed on a keyboard.
local SPECIAL_CHARS = {}
for _, r in ipairs({ { 0x01, 0x08 }, { 0x0B, 0x0C }, { 0x0E, 0x1F }, { 0x7F, 0x7F }, { 0xA6, 0xA6 },
                     { 0xA9, 0xB5 }, { 0xB7, 0xBF }, { 0xD7, 0xD7 }, { 0xF7, 0xF8 } }) do
  for c = r[1], r[2] do SPECIAL_CHARS[#SPECIAL_CHARS + 1] = c end
end

local CHANNELS = { "R", "G", "B" }

-- Parses "RRGGBB", "#RRGGBB", "RGB" or "#RGB" into 0xRRGGBB (or nil).
local function parseColour(t)
  t = t:gsub("^%s*#?", ""):gsub("%s+$", "")
  if t:match("^%x%x%x%x%x%x$") then return tonumber(t, 16) end
  if t:match("^%x%x%x$") then
    local r, g, b = t:sub(1, 1), t:sub(2, 2), t:sub(3, 3)
    return tonumber(r .. r .. g .. g .. b .. b, 16)
  end
end

-- A number prompt clamped to 1..512 cells; nil if cancelled.
local function cellsPrompt(U, label, default)
  local r = U.prompt(label, tostring(default))
  if not r then return nil end
  return max(1, min(512, floor(tonumber(r) or default)))
end

return function(ed)
  local U, col = ed.U, ed.U.col
  local blitAt = U.blitAt

  function ed.showHelp() U.message(HELP) end

  -- Asked when a new size has a different aspect ratio than the image.
  -- Returns mode ("fit"/"fill"/"stretch"), ax, ay, or nil if cancelled.
  function ed.chooseScaleMode()
    local mode = U.choose("New aspect ratio:",
      { { "Bars", "fit" }, { "Fill", "fill" }, { "Stretch", "stretch" }, { "Cancel", "c" } })
    if mode ~= "fit" and mode ~= "fill" and mode ~= "stretch" then return nil end
    if mode == "stretch" then return mode, 0.5, 0.5 end
    local ax, ay = U.chooseAnchor(mode == "fit" and "Place image at:" or "Keep this part:", 5)
    if not ax then return nil end
    return mode, ax, ay
  end

  ---------------------------------------------------------------------------
  -- Size
  ---------------------------------------------------------------------------
  -- Replaces the current image's pixels/size/text with what build(img)
  -- returns (a new pixel image and text layer), in one undo step.
  local function replaceImage(build)
    local d = ed.doc()
    ed.deselect()
    ed.beginOp("full")
    local img = d.img
    local new, text = build(img)
    img.px, img.w, img.h, img.pw, img.ph, img.text = new.px, new.w, new.h, new.pw, new.ph, text
    ed.endOp()
    ed.clampView(d)
  end

  function ed.resizeCanvas()
    local img = ed.doc().img
    local nw = cellsPrompt(U, "Canvas width (cells): ", img.w)
    if not nw then return end
    local nh = cellsPrompt(U, "Canvas height (cells): ", img.h)
    if not nh then return end
    if nw == img.w and nh == img.h then return end
    local ax, ay = U.chooseAnchor("Keep image at:")
    if not ax then return end
    replaceImage(function(i) return paint.resizeCanvas(i, nw, nh, ax, ay, ed.secondary) end)
    ed.setStatus(("Canvas is now %dx%d"):format(nw, nh))
  end

  -- Scales the image to exactly the entered size; if the aspect ratio
  -- changes, the image is fitted (bars in the R colour), filled (cropped)
  -- or stretched. Text boxes move along.
  function ed.scaleImage()
    local img = ed.doc().img
    local nw = cellsPrompt(U, "Image width (cells): ", img.w)
    if not nw then return end
    local keepH = max(1, floor(img.h * nw / img.w + 0.5))
    local r = U.prompt("Image height (cells): ", tostring(keepH))
    if not r then return end
    local nh = max(1, min(512, floor(tonumber(r) or img.h)))
    if nw == img.w and nh == img.h then return end
    local mode, ax, ay = "stretch", 0.5, 0.5
    if nh ~= keepH then
      mode, ax, ay = ed.chooseScaleMode()
      if not mode then return end
    end
    replaceImage(function(i) return paint.scale(i, nw, nh, mode, ax, ay, ed.secondary) end)
    ed.setStatus(("Image scaled to %dx%d"):format(nw, nh))
  end

  function ed.sizeMenu()
    local r = U.choose("Change size of:", { { "Canvas", "canvas" }, { "Image", "image" }, { "Cancel", "c" } })
    if r == "canvas" then ed.resizeCanvas() elseif r == "image" then ed.scaleImage() end
  end

  function ed.newCanvas()
    local r = U.prompt("Size WxH: ", ed.NEW_W .. "x" .. ed.NEW_H)
    if not r then return end
    local w, h = r:match("(%d+)%s*[xX, ]%s*(%d+)")
    ed.addDoc(ed.blankDoc(max(1, min(512, tonumber(w) or ed.NEW_W)), max(1, min(512, tonumber(h) or ed.NEW_H))))
  end

  ---------------------------------------------------------------------------
  -- Special characters
  ---------------------------------------------------------------------------
  -- Grid of special characters; tapping one inserts it into the selected
  -- text box. Stays open for several picks; Close (or Tab) closes it.
  -- Keyboard: arrows move, Enter inserts.
  function ed.charPicker()
    if not ed.sel then return end
    local pick = 1
    local hits, cells, cols
    U.modal(function()
      cells = {}
      cols = max(1, min(16, floor((ed.W - 4) / 3)))
      local rows = math.ceil(#SPECIAL_CHARS / cols)
      local pw = cols * 3 + 4
      local x0, y0, last = U.panel(pw, rows + 4)
      ed.win.setCursorPos(x0 + 2, y0 + 1)
      ed.win.setTextColour(2 ^ col.text)
      ed.win.write(("Insert character"):sub(1, pw - 4))
      for i, c in ipairs(SPECIAL_CHARS) do
        local gx = x0 + 2 + ((i - 1) % cols) * 3
        local gy = y0 + 3 + floor((i - 1) / cols)
        if gy <= last then
          blitAt(gx, gy, " " .. string.char(c) .. " ", i == pick and col.dark or col.text, i == pick and col.hi or col.dark)
          cells[i] = { gx, gy }
        end
      end
      hits = U.bottomBar(("Character %d (0x%02X)"):format(SPECIAL_CHARS[pick], SPECIAL_CHARS[pick]),
        { { "Close", "close" } })
      ed.win.setCursorBlink(false)
    end, function(ev, button, x, y)
      if ev[1] == "terminate" then return true
      elseif button then
        if y == ed.H then
          if U.hitButton(hits, x) == "close" then return true end
        else
          for i, c in pairs(cells) do
            if y == c[2] and x >= c[1] and x <= c[1] + 2 then
              pick = i
              ed.textInsert(string.char(SPECIAL_CHARS[i]))
            end
          end
        end
      elseif ev[1] == "key" then
        local k = ev[2]
        if k == keys.enter or k == keys.numPadEnter then ed.textInsert(string.char(SPECIAL_CHARS[pick]))
        elseif k == keys.tab then return true
        elseif k == keys.left then pick = max(1, pick - 1)
        elseif k == keys.right then pick = min(#SPECIAL_CHARS, pick + 1)
        elseif k == keys.up then pick = max(1, pick - cols)
        elseif k == keys.down then pick = min(#SPECIAL_CHARS, pick + cols) end
      end
    end)
  end

  ---------------------------------------------------------------------------
  -- Colours
  ---------------------------------------------------------------------------
  local function hexPrompt(idx, start, preview)
    local r = U.prompt(("Colour %d hex RRGGBB: "):format(idx), ("%06x"):format(start), nil, function(t)
      preview(parseColour(t) or start)
    end)
    return r and parseColour(r)
  end

  -- Stores a new palette (a copy of the current one with slot idx = c) in
  -- one undo step.
  local function setPaletteColour(idx, c)
    local pal = ed.palette()
    ed.beginOp("full")
    local np = {}
    for i = 0, 15 do np[i] = pal[i] end
    np[idx] = c
    ed.doc().img.palette = np
    ed.endOp()
    ed.applyPalette()
  end

  -- Edits palette slot L with separate R, G and B values (or hex). Changes
  -- are previewed live on the canvas; Cancel restores the original colour.
  -- Touch: << < > >> step by 16 / 1, tap a value to type it, "Hex..." for a
  -- hex code. Keyboard: Up/Down pick a channel, Left/Right step (Shift: 16),
  -- digits type a value, Enter = OK.
  function ed.editColour()
    local win = ed.win
    local idx = ed.primary
    local orig = ed.palette()[idx]
    local v = { adimg.rgb(orig) }
    local ch, typed = 1, nil
    local function value() return v[1] * 65536 + v[2] * 256 + v[3] end
    local function preview(c) win.setPaletteColour(2 ^ idx, c) end
    ed.computeUi(idx) -- keep the interface readable while this colour changes
    local hits, btns
    local function step(i, n) v[i] = max(0, min(255, v[i] + n)); ch = i; typed = nil end
    local function typeChannel(i)
      ch, typed = i, nil
      local r = U.prompt(CHANNELS[i] .. " (0-255): ", tostring(v[i]), nil, function(t)
        local n = tonumber(t)
        if n and n >= 0 and n <= 255 then
          local w = { v[1], v[2], v[3] }
          w[i] = floor(n)
          preview(w[1] * 65536 + w[2] * 256 + w[3])
        end
      end)
      local n = tonumber(r or "")
      if n then v[i] = max(0, min(255, floor(n))) end
    end
    local result
    repeat
      preview(value())
      result = U.modal(function()
        btns = {}
        local pw = 29
        local x0, y0 = U.panel(pw, 9)
        win.setCursorPos(x0 + 2, y0 + 1)
        win.setTextColour(2 ^ col.text)
        win.write(("Colour %d  #%06x"):format(idx, value()))
        blitAt(x0 + pw - 6, y0 + 1, "    ", col.text, idx)
        local function button(x, y, label, action, active)
          blitAt(x, y, label, active and col.dark or col.text, active and col.hi or col.dark)
          btns[#btns + 1] = { x, y, x + #label - 1, action }
        end
        for i = 1, 3 do
          local y = y0 + 2 + i
          blitAt(x0 + 2, y, CHANNELS[i], col.text, col.bar)
          button(x0 + 4, y, "<<", { i, -16 })
          button(x0 + 7, y, "<", { i, -1 })
          button(x0 + 9, y, (" %3d "):format(v[i]), { i, "type" }, i == ch)
          button(x0 + 15, y, ">", { i, 1 })
          button(x0 + 17, y, ">>", { i, 16 })
          -- a bar showing the channel's level
          local n = floor(v[i] / 255 * 7 + 0.5)
          blitAt(x0 + 20, y, string.rep("\127", n) .. string.rep(" ", 7 - n), col.text, col.dark)
        end
        button(x0 + 2, y0 + 7, " Hex... ", "hex")
        hits = U.bottomBar("Edit colour L", { { "OK", "ok" }, { "Cancel", "cancel" } })
      end, function(ev, button, x, y)
        -- every event ends a round so the preview is updated before redrawing
        if ev[1] == "terminate" then return true, false
        elseif button then
          if y == ed.H then
            local r = U.hitButton(hits, x)
            if r == "ok" then return true, true elseif r == "cancel" then return true, false end
          else
            for _, b in ipairs(btns) do
              if y == b[2] and x >= b[1] and x <= b[3] then
                local a = b[4]
                if a == "hex" then
                  local c = hexPrompt(idx, value(), preview)
                  if c then v = { adimg.rgb(c) } end
                elseif a[2] == "type" then typeChannel(a[1])
                else step(a[1], a[2]) end
              end
            end
          end
        elseif ev[1] == "char" and ev[2]:match("^%d$") then
          typed = (typed or "") .. ev[2]
          v[ch] = min(255, tonumber(typed))
          if #typed >= 3 then typed = nil end
        elseif ev[1] == "key" then
          local k = ev[2]
          if k == keys.enter or k == keys.numPadEnter then return true, true
          elseif k == keys.up then ch = (ch - 2) % 3 + 1; typed = nil
          elseif k == keys.down or k == keys.tab then ch = ch % 3 + 1; typed = nil
          elseif k == keys.left then step(ch, U.mods.shift and -16 or -1)
          elseif k == keys.right then step(ch, U.mods.shift and 16 or 1)
          elseif k == keys.backspace then
            typed = typed and typed:sub(1, -2) or tostring(v[ch]):sub(1, -2)
            v[ch] = tonumber(typed) or 0
          end
        end
        return true, nil
      end)
    until result ~= nil
    local c = value()
    if not result or c == orig then ed.applyPalette(); return end
    setPaletteColour(idx, c)
  end

  function ed.resetPalette()
    if not ed.doc().img.palette then return end
    ed.beginOp("full")
    ed.doc().img.palette = nil
    ed.endOp()
    ed.applyPalette()
  end

  -- Monitors: the screen must stay big enough for the tool settings bar.
  local MIN_ROWS = 6 -- tabs, 2 canvas rows, settings, palette, tools

  function ed.screenFits()
    local w, h = ed.display.getSize()
    return w >= ed.minScreenWidth() and h >= MIN_ROWS
  end

  -- Sets the largest text scale up to `want` (0.5-5, in steps of 0.5) at
  -- which the screen still fits; returns it.
  function ed.fitTextScale(want)
    local minW = ed.minScreenWidth()
    local sc = displays.fitScale(ed.display, want, function(w, h) return w >= minW and h >= MIN_ROWS end)
    ed.onResize()
    return sc
  end

  -- Monitors: changes the text scale and saves it as the default.
  function ed.textScaleDialog()
    local r = U.prompt("Text scale (0.5-5): ", tostring(ed.display.getTextScale()))
    local want = tonumber(r or "")
    if not want then return end
    want = max(0.5, min(5, floor(want * 2 + 0.5) / 2))
    local sc = ed.fitTextScale(want)
    settings.set("adpaint.text_scale", sc)
    settings.save()
    if sc < want then
      ed.setStatus("Text scale " .. sc .. " (max, saved)", 6)
    else
      ed.setStatus("Text scale " .. sc .. " (saved as default)")
    end
  end
end
