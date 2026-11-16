-- The adpaint editor: sets up the display, installs the editor modules into
-- one shared state table and runs the main loop.
local adimg = require("lib.formats.adimg")
local ui = require("lib.ui")

local M = {}

-- Modules installed into the editor, in order (later ones may refer to
-- functions of earlier ones when installed).
M.MODULES = {
  "lib.editor.state", "lib.editor.view", "lib.editor.text", "lib.editor.chrome",
  "lib.editor.dialogs", "lib.editor.files", "lib.editor.commands", "lib.editor.input",
}

-- Runs the editor. files: paths to open; monSide: monitor to paint on (or
-- nil for the terminal); monScale: its text scale.
function M.run(files, monSide, monScale)
  local display = term.current()
  if monSide then
    local mon = peripheral.wrap(monSide)
    if not (mon and mon.isColour and mon.isColour()) then
      printError("No advanced monitor on side '" .. tostring(monSide) .. "'"); return
    end
    mon.setTextScale(math.max(0.5, math.min(5, math.floor(monScale * 2 + 0.5) / 2)))
    display = mon
  elseif not term.isColour() then
    printError("adpaint needs an advanced computer (colour + mouse)"); return
  end

  local ed = { display = display }
  ed.W, ed.H = display.getSize()
  ed.win = window.create(display, 1, 1, ed.W, ed.H, true)
  local oldTerm = term.redirect(ed.win)

  function ed.onResize()
    ed.W, ed.H = display.getSize()
    ed.win.reposition(1, 1, ed.W, ed.H)
    for _, d in ipairs(ed.docs) do ed.clampView(d) end
  end

  ed.U = ui.new({
    win = ed.win,
    monitor = monSide and peripheral.getName(display) or nil,
    draw = function(overlay) ed.draw(overlay) end,
    area = function() return 2, ed.viewH() end,
    onEvent = function(ev)
      if ev[1] == "file_transfer" then ed.pendingFiles[#ed.pendingFiles + 1] = ev[2]
      else ed.onResize() end
    end,
  })
  for _, name in ipairs(M.MODULES) do require(name)(ed) end

  -- A text scale so big that the tool settings would be cut off is lowered.
  local scaleNote
  if monSide then
    local want = display.getTextScale()
    local sc = ed.fitTextScale(want)
    if sc < want then scaleNote = "Text scale " .. sc .. " (max)" end
  end

  local function main()
    ed.computeUi() -- prompts may be shown before the first tab exists
    for _, f in ipairs(files) do ed.openPath(f) end
    if #ed.docs == 0 then
      ed.addDoc(ed.blankDoc())
      ed.setStatus(ed.W >= 44 and "Tip: drop image files here (.jpg, .png, or .bmp)" or "Tip: drop images here", 6)
    end
    if scaleNote then ed.setStatus(scaleNote, 6) end
    ed.cur = 1
    ed.applyPalette()
    ed.clampView(ed.doc())
    while ed.running do
      ed.draw()
      ed.handleEvent({ os.pullEventRaw() })
    end
  end

  local ok, err = pcall(main)
  term.redirect(oldTerm)
  adimg.applyPalette(display, adimg.DEFAULT_PALETTE)
  display.setBackgroundColour(colours.black)
  display.setTextColour(colours.white)
  display.clear()
  display.setCursorPos(1, 1)
  if not ok then printError(err) end
end

return M
