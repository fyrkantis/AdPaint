-- Editor commands: the menu, keyboard shortcuts and small setting changes.
-- Install after the modules whose functions the tables below refer to.
local max, min = math.max, math.min

return function(ed)
  function ed.brushSmaller() ed.brushSize = max(1, ed.brushSize - 1) end
  function ed.brushBigger() ed.brushSize = min(16, ed.brushSize + 1) end
  function ed.ditherLess() ed.dither = max(1, ed.dither - 1) end
  function ed.ditherMore() ed.dither = min(8, ed.dither + 1) end
  function ed.toggleText() ed.showText = not ed.showText end
  function ed.nextTab() ed.cur = ed.cur % #ed.docs + 1; ed.applyPalette() end

  -- { label, shortcut, action, icon (CC font character) }
  ed.menuItems = {
    { "New", "^N", ed.newCanvas, "\43" },
    { "Open...", "^O", ed.openDialog },
    { "Save", "^S", function() ed.saveDoc() end },
    { "Save as...", "", function() ed.saveDoc(nil, true) end },
    { "Import image...", "", ed.importDialog, "\6" },
    { "Resize canvas...", "", ed.resizeCanvas, "\172" },
    { "Scale image...", "", ed.scaleImage, "\3" },
    { "Edit colour L...", "^E", ed.editColour, "\127" },
    { "Reset colours", "", ed.resetPalette },
    { "Undo", "^Z", function() ed.undo() end, "\27" },
    { "Redo", "^Y", function() ed.undo(true) end, "\26" },
    { "Help", "", ed.showHelp, "\63" },
    { "Close tab", "^W", function() ed.closeDoc(ed.cur) end, "\215" },
    { "Quit", "^Q", ed.quit },
  }
  if ed.U.monitor then
    -- right under "Reset colours"
    local at = 1
    for i, it in ipairs(ed.menuItems) do if it[1] == "Reset colours" then at = i + 1 end end
    table.insert(ed.menuItems, at, { "Text scale...", "", ed.textScaleDialog })
  end

  local function shiftPan(dx, dy, bdx, bdy)
    return function()
      if ed.U.mods.shift then ed.pan(bdx, bdy) else ed.pan(dx, dy) end
    end
  end
  local function setTool(t) return function() ed.tool = t end end

  -- Plain keys (when no text box is being edited).
  ed.SHORTCUTS = {
    [keys.b] = setTool("brush"),
    [keys.f] = setTool("fill"),
    [keys.t] = setTool("text"),
    [keys.i] = setTool("pick"),
    [keys.p] = setTool("pan"),
    [keys.leftBracket] = ed.brushSmaller,
    [keys.rightBracket] = ed.brushBigger,
    [keys.comma] = ed.ditherLess,
    [keys.period] = ed.ditherMore,
    [keys.z] = ed.toggleZoom,
    [keys.h] = ed.toggleText,
    [keys.e] = ed.editColour,
    [keys.tab] = ed.nextTab,
    [keys.left] = shiftPan(-2, 0, -8, 0),
    [keys.right] = shiftPan(2, 0, 8, 0),
    [keys.up] = shiftPan(0, -2, 0, -6),
    [keys.down] = shiftPan(0, 2, 0, 6),
  }

  -- Ctrl + key.
  ed.CTRL = {
    [keys.n] = ed.newCanvas,
    [keys.o] = ed.openDialog,
    [keys.s] = function() ed.saveDoc() end,
    [keys.w] = function() ed.closeDoc(ed.cur) end,
    [keys.q] = ed.quit,
    [keys.z] = function() ed.undo() end,
    [keys.y] = function() ed.undo(true) end,
    [keys.e] = ed.editColour,
  }
end
