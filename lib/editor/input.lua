-- Editor input: mouse / touch on the canvas and the bars, keys, and the
-- dispatch of one event from the main loop.
local adimg = require("lib.formats.adimg")
local paint = require("lib.paint")

local floor, min = math.floor, math.min

return function(ed)
  local U = ed.U

  local function canvasDown(button, x, y)
    local d = ed.doc()
    local native = not ed.zoomInfo(d).zw
    local px, py, cx, cy = ed.screenToImage(x, y)
    if ed.tool == "pan" and U.monitor then
      -- touch: no dragging, so a tap scrolls that spot to the middle
      ed.centreOn(px, py)
      return
    end
    if button == 3 or ed.tool == "pan" then
      ed.drag = { kind = "pan", x = x, y = y }
      return
    end
    if U.monitor and ed.tool == "pick" then button = ed.touchSlot end
    local color = button == 1 and ed.primary or ed.secondary
    local img = d.img
    if ed.tool == "brush" then
      ed.deselect()
      ed.beginOp()
      local ux, uy = native and cx or px, native and cy or py
      paint.stamp(img, ux, uy, color, native, ed.brushSize, ed.dither, ed.setPx)
      ed.drag = { kind = "brush", ux = ux, uy = uy, color = color, native = native }
    elseif ed.tool == "fill" then
      ed.deselect()
      if px < 0 or py < 0 or px >= img.pw or py >= img.ph then return end
      if native then px, py = select(2, paint.cellMajority(img, cx, cy)) end
      ed.beginOp()
      paint.floodFill(img, px, py, color, ed.setPx)
      ed.endOp()
    elseif ed.tool == "pick" then
      local c = adimg.get(img, px, py)
      if c then
        if native then c = paint.cellMajority(img, cx, cy) end
        if button == 1 then ed.primary = c else ed.secondary = c end
      end
    elseif ed.tool == "text" then
      if cx < 0 or cy < 0 or cx >= img.w or cy >= img.h then ed.deselect(); return end
      local b = paint.boxAt(img, cx, cy)
      if b then
        local line = cy + 1 - b.y + 1
        ed.selectBox(b, line, min(#b.lines[line], cx + 1 - b.x))
      else
        ed.newBox(cx, cy)
      end
      ed.drag = { kind = "text", cx = cx, cy = cy }
    end
  end

  local function canvasDrag(x, y)
    local drag = ed.drag
    if not drag then return end
    if drag.kind == "pan" then
      ed.pan(drag.x - x, drag.y - y)
      drag.x, drag.y = x, y
      return
    end
    local px, py, cx, cy = ed.screenToImage(x, y)
    if drag.kind == "brush" then
      local ux, uy = drag.native and cx or px, drag.native and cy or py
      if ux ~= drag.ux or uy ~= drag.uy then
        local img = ed.doc().img
        paint.line(drag.ux, drag.uy, ux, uy, function(lx, ly)
          paint.stamp(img, lx, ly, drag.color, drag.native, ed.brushSize, ed.dither, ed.setPx)
        end)
        drag.ux, drag.uy = ux, uy
      end
    elseif drag.kind == "text" and ed.sel then
      local dx, dy = cx - drag.cx, cy - drag.cy
      if dx ~= 0 or dy ~= 0 then
        ed.moveBox(dx, dy)
        drag.cx, drag.cy = cx, cy
      end
    end
  end

  local function mouseUp()
    if ed.drag and ed.drag.kind == "brush" then ed.endOp() end
    ed.drag = nil
  end

  local function inside(hit, x) return hit and x >= hit[1] and x <= hit[2] end

  local function click(button, x, y)
    local hits, H = ed.hits, ed.H
    if ed.menuOpen then
      ed.menuOpen = false
      local it = ed.menuItems[y - 1]
      if it and x <= (hits.menuWidth or 0) then it[3]() end
      return
    end
    if y == 1 then
      local tabs = hits.tabs
      if x <= 3 then ed.menuOpen = true; return end
      if x >= tabs.undo and x <= tabs.undo + 2 then ed.undo(); return end
      if x >= tabs.redo and x <= tabs.redo + 2 then ed.undo(true); return end
      for _, t in ipairs(tabs) do
        if x >= t[1] and x <= t[2] then ed.deselect(); ed.cur = t[3]; ed.applyPalette(); return end
        if x == t[4] then ed.closeDoc(t[3]); return end
      end
      if x == tabs.plus then ed.addDoc(ed.blankDoc()) end
    elseif y == H - 2 then
      for _, t in ipairs(hits.settings) do
        if inside(t, x) then t[3](); return end
      end
    elseif y == H - 1 then
      if inside(hits.size, x) then ed.sizeMenu(); return end
      if inside(hits.slot, x) then ed.touchSlot = 3 - ed.touchSlot; return end
      if U.monitor then button = ed.touchSlot end
      local c = floor((x - 1) / ed.swatchWidth())
      if c >= 0 and c <= 15 then
        if ed.sel then
          if button == 1 then ed.sel.box.fg = c else ed.sel.box.bg = c end
          ed.textChanged()
        elseif button == 1 then ed.primary = c else ed.secondary = c end
      end
    elseif y == H then
      for _, t in ipairs(hits.tools) do
        if inside(t, x) then
          if type(t[3]) == "function" then t[3]() else ed.deselect(); ed.tool = t[3] end
          return
        end
      end
    else
      canvasDown(button, x, y)
    end
  end

  local function keyDown(k)
    local mods = U.mods
    if k == keys.leftCtrl or k == keys.rightCtrl then mods.ctrl = true; return end
    if k == keys.leftShift or k == keys.rightShift then mods.shift = true; return end
    if mods.ctrl then
      if ed.CTRL[k] then ed.deselect(); ed.CTRL[k]() end
      return
    end
    if ed.menuOpen then ed.menuOpen = false; return end
    if ed.sel then
      ed.textKey(k) -- letters arrive as char events
      return
    end
    if ed.SHORTCUTS[k] then ed.SHORTCUTS[k]() end
  end

  -- Handles one event of the main loop.
  function ed.handleEvent(ev)
    local e = ev[1]
    local mouse = not U.monitor
    if e == "terminate" then ed.quit()
    elseif e == "mouse_click" and mouse then click(ev[2], ev[3], ev[4])
    elseif e == "mouse_drag" and mouse then canvasDrag(ev[3], ev[4])
    elseif e == "mouse_up" and mouse then mouseUp()
    elseif e == "monitor_touch" and U.monitor and ev[2] == U.monitor then
      click(1, ev[3], ev[4]); mouseUp()
    elseif e == "mouse_scroll" and mouse then
      if ev[4] >= 2 and ev[4] <= ed.viewH() + 1 then
        if U.mods.shift then ed.pan(ev[2] * 3, 0) else ed.pan(0, ev[2] * 2) end
      end
    elseif e == "key" then keyDown(ev[2])
    elseif e == "key_up" then U.trackModifiers(ev)
    elseif e == "char" and ed.sel and not U.mods.ctrl then ed.textInsert(ev[2])
    elseif e == "paste" and ed.sel then ed.textInsert(ev[2])
    elseif e == "file_transfer" then ed.handleFiles(ev[2])
    elseif e == "term_resize" or e == "monitor_resize" then
      ed.onResize()
      -- monitor made smaller: lower the text scale until everything fits
      -- (only ever shrinks, so it can't loop on its own resize events)
      if U.monitor and e == "monitor_resize" and not ed.screenFits() and ed.display.getTextScale() > 0.5 then
        ed.fitTextScale(ed.display.getTextScale() - 0.5)
      end
    end
    while #ed.pendingFiles > 0 do ed.handleFiles(table.remove(ed.pendingFiles, 1)) end
  end
end
