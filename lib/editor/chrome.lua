-- Editor screen layout: tab bar, tool settings bar, palette row, tool bar,
-- menu and status toast around the canvas, and the full-frame draw().
--
-- Rows: 1 tabs, 2..H-3 canvas, H-2 tool settings, H-1 palette, H tools.
-- Hit boxes of what was drawn are kept in ed.hits for the input code.
local adimg = require("lib.adimg")

local max, min = math.max, math.min

-- Moving things without dragging (touch monitors can only tap).
local ARROWS = { { "\27", -1, 0 }, { "\24", 0, -1 }, { "\25", 0, 1 }, { "\26", 1, 0 } }

local function concat(...)
  local out = {}
  for _, t in ipairs({ ... }) do for _, v in ipairs(t) do out[#out + 1] = v end end
  return out
end

return function(ed)
  local U, col = ed.U, ed.U.col
  local blitAt = U.blitAt
  ed.hits = { tabs = {}, tools = {}, settings = {} }

  -- Width of one palette swatch.
  function ed.swatchWidth() return ed.W >= 40 and 2 or 1 end

  local function drawTabs()
    local win, W = ed.win, ed.W
    win.setCursorPos(1, 1)
    win.setBackgroundColour(2 ^ col.dark); win.clearLine()
    local hits = {}
    blitAt(1, 1, " = ", col.text, ed.menuOpen and col.accent or col.bar)
    local x = 5
    for i, d in ipairs(ed.docs) do
      local label = " " .. ed.docName(d) .. (d.dirty and "*" or "") .. " "
      if x + #label + 1 > W - 8 then break end
      local bg = i == ed.cur and col.bar or col.dark
      blitAt(x, 1, label, i == ed.cur and col.text or col.dim, bg)
      blitAt(x + #label, 1, "\215", col.dim, bg)
      hits[#hits + 1] = { x, x + #label - 1, i, x + #label }
      x = x + #label + 2
    end
    blitAt(min(x, W - 7), 1, "+", col.text, col.dark)
    hits.plus = min(x, W - 7)
    -- undo / redo buttons (CC font chars 27 = left arrow, 26 = right arrow)
    local d = ed.doc()
    local canUndo = #d.undo > 0 or (ed.op ~= nil and ed.op.changed)
    blitAt(W - 5, 1, " \27 ", canUndo and col.text or col.dim, col.bar)
    blitAt(W - 2, 1, " \26 ", #d.redo > 0 and col.text or col.dim, col.bar)
    hits.undo, hits.redo = W - 5, W - 2
    ed.hits.tabs = hits
  end

  local function drawPalette()
    local win, W, sel = ed.win, ed.W, ed.sel
    local y = ed.H - 1
    win.setCursorPos(1, y)
    win.setBackgroundColour(2 ^ col.bar); win.clearLine()
    local sw = ed.swatchWidth()
    local pal = ed.palette()
    for c = 0, 15 do
      local mark = " "
      local fg = adimg.dist(pal[c], 0) > adimg.dist(pal[c], 0xFFFFFF) and 15 or 0
      if sel then
        if c == sel.box.fg then mark = "F" end
        if c == sel.box.bg then mark = mark == "F" and "*" or "B" end
      else
        if c == ed.primary then mark = "L" end
        if c == ed.secondary then mark = mark == "L" and "*" or "R" end
      end
      blitAt(1 + c * sw, y, (mark .. "  "):sub(1, sw), fg, c)
    end
    local x = 16 * sw + 2
    ed.hits.slot = nil
    if U.monitor then
      -- taps can't right-click, so a toggle decides which slot a tap sets
      local names = sel and { "F", "B" } or { "L", "R" }
      local label = " Sets " .. names[ed.touchSlot] .. " "
      if x + #label + 8 <= W then
        blitAt(x, y, label, col.dark, col.hi)
        ed.hits.slot = { x, x + #label - 1 }
        x = x + #label + 1
      end
    end
    local d = ed.doc()
    local size = " " .. d.img.w .. "x" .. d.img.h .. " "
    local sx = W - #size + 1
    if sx > x then
      blitAt(sx, y, size, col.text, col.dark)
      ed.hits.size = { sx, W }
    else
      ed.hits.size = nil
    end
  end

  -- Status messages show as a small toast at the bottom right of the canvas.
  local function drawStatus()
    if not (ed.status and os.clock() < ed.statusUntil) then return end
    local msg = " " .. ed.status:sub(1, ed.W - 2) .. " "
    blitAt(ed.W - #msg + 1, ed.viewH() + 1, msg, col.text, col.bar)
  end

  local function drawToolbar()
    local hits = {}
    local wide, narrow = {}, {}
    for _, t in ipairs(ed.TOOLS) do
      wide[#wide + 1] = { t[3] .. t[2], t[1], ed.tool == t[1] }
      narrow[#narrow + 1] = { " " .. t[3] .. " ", t[1], ed.tool == t[1], 0 }
    end
    narrow[#narrow][4] = 1
    for _, l in ipairs({ wide, narrow }) do
      l[#l + 1] = { "Zoom", ed.toggleZoom, ed.doc().zoom > 1 }
      l[#l + 1] = { ed.showText and "Txt" or "txt", ed.toggleText, ed.showText }
    end
    U.drawRow(ed.H, U.pickLayout(wide, narrow), hits)
    ed.hits.tools = hits
  end

  local function arrowItems(fn, padded)
    local items = {}
    for _, a in ipairs(ARROWS) do
      items[#items + 1] = { padded and (" " .. a[1] .. " ") or a[1], function() fn(a[2], a[3]) end, false, 0 }
    end
    items[#items][4] = 1
    return items
  end

  local function stepper(name, val, dec, inc, padded)
    if padded then
      return { { name }, { " - ", dec }, { ("%2d"):format(val) }, { " + ", inc, false, 2 } }
    end
    return { { name, nil, false, 0 }, { "-", dec, false, 0 }, { tostring(val), nil, false, 0 }, { "+", inc } }
  end

  -- The bar above the palette: settings for the current tool.
  local function drawSettings()
    local hits = {}
    local layout
    local sel = ed.sel
    if sel then
      local noBg = function() sel.box.bg = nil; ed.textChanged() end
      layout = U.pickLayout(
        concat({ { " No bg ", noBg, sel.box.bg == nil }, { " Chars ", ed.charPicker },
                 { " Delete ", ed.deleteSelectedBox }, { " Done ", ed.deselect, false, 2 }, { "Move" } },
               arrowItems(ed.moveBox, true)),
        concat({ { "No bg", noBg, sel.box.bg == nil }, { "Chars", ed.charPicker }, { "Del", ed.deleteSelectedBox },
                 { "Done", ed.deselect } }, arrowItems(ed.moveBox, false)))
    elseif ed.tool == "brush" then
      local size, dith = ed.brushSize, ed.dither
      layout = U.pickLayout(
        concat(stepper("Size", size, ed.brushSmaller, ed.brushBigger, true),
               stepper("Dither", dith, ed.ditherLess, ed.ditherMore, true)),
        concat(stepper("Size", size, ed.brushSmaller, ed.brushBigger),
               stepper("Dither", dith, ed.ditherLess, ed.ditherMore)))
    elseif ed.tool == "pan" then
      layout = U.pickLayout(
        concat({ { U.monitor and "Tap a spot to centre it, or" or "Drag, or use" } }, arrowItems(ed.panStep, true)),
        concat({ { "Pan" } }, arrowItems(ed.panStep, true)),
        arrowItems(ed.panStep, false))
    else
      local verb = U.monitor and "Tap" or "Click"
      local hint = ({ fill = verb .. " an area to fill it", pick = verb .. " to pick a colour",
                      text = verb .. " to add or select a text box" })[ed.tool] or ""
      layout = { { hint } }
    end
    U.drawRow(ed.H - 2, layout, hits)
    ed.hits.settings = hits
  end

  local function drawMenu()
    local items = ed.menuItems
    local W = ed.W
    local w = 0
    for _, it in ipairs(items) do w = max(w, #it[1] + #it[2] + 3) end
    local icons = w + 2 <= W -- room for an icon column?
    if icons then w = w + 2 end
    for i, it in ipairs(items) do
      local text = icons and ((it[4] or " ") .. " " .. it[1]) or it[1]
      local label = " " .. text .. string.rep(" ", w - #text - #it[2] - 2) .. it[2] .. " "
      blitAt(1, i + 1, label, col.text, col.bar)
    end
    ed.hits.menuWidth = w
  end

  -- Puts the blinking cursor in the selected text box.
  local function placeCursor()
    local sel = ed.sel
    local cx, cy = sel.box.x - 1 + sel.col, sel.box.y - 1 + sel.line - 1
    local sx, sy = ed.cellToScreen(cx, cy)
    if sx >= 1 and sx <= ed.W and sy >= 2 and sy <= ed.viewH() + 1 then
      ed.win.setCursorPos(sx, sy)
      ed.win.setTextColour(2 ^ sel.box.fg)
      ed.win.setCursorBlink(true)
    end
  end

  -- Redraws everything; overlay() (dialogs) is drawn on top.
  function ed.draw(overlay)
    local win = ed.win
    win.setVisible(false)
    if not ed.doc() then
      -- no tab yet (e.g. "adpaint image.png" asks its import questions first)
      win.setBackgroundColour(2 ^ col.dark)
      win.clear()
      win.setCursorBlink(false)
      drawStatus()
      if overlay then overlay() end
      win.setVisible(true)
      return
    end
    ed.drawCanvas()
    drawTabs()
    drawPalette()
    drawToolbar()
    drawSettings()
    drawStatus()
    if ed.menuOpen then drawMenu() end
    win.setCursorBlink(false)
    if ed.sel and not ed.menuOpen then placeCursor() end
    if overlay then overlay() end
    win.setVisible(true)
  end
end
