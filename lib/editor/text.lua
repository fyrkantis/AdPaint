-- Editor text layer: selecting, typing into, moving and deleting text boxes.
local max, min = math.max, math.min

return function(ed)
  -- Ends editing the selected box (an empty transparent box is removed) and
  -- commits the edit as one undo step.
  function ed.deselect()
    local sel = ed.sel
    if not sel then return end
    local text = ed.doc().img.text
    local empty = true
    for _, l in ipairs(sel.box.lines) do if l:find("%S") then empty = false end end
    if empty and not sel.box.bg then
      for i, b in ipairs(text) do if b == sel.box then table.remove(text, i); break end end
    end
    ed.sel = nil
    ed.endOp()
  end

  function ed.selectBox(b, line, col)
    local sel = ed.sel
    if sel and sel.box == b then sel.line, sel.col = line, col; return end
    ed.deselect()
    ed.beginOp("text")
    -- the op snapshot holds copies, so keep editing the live box
    ed.sel = { box = b, line = line, col = col }
  end

  -- Adds an empty box at cell (cx, cy) (0-based) and selects it.
  function ed.newBox(cx, cy)
    ed.deselect()
    local b = { x = cx + 1, y = cy + 1, fg = ed.primary, bg = nil, lines = { "" } }
    ed.beginOp("text")
    table.insert(ed.doc().img.text, b)
    ed.sel = { box = b, line = 1, col = 0 }
  end

  function ed.textInsert(s)
    local sel = ed.sel
    local b = sel.box
    local l = b.lines[sel.line]
    b.lines[sel.line] = l:sub(1, sel.col) .. s .. l:sub(sel.col + 1)
    sel.col = sel.col + #s
    ed.textChanged()
  end

  -- Handles editing keys; returns false for keys it doesn't use.
  function ed.textKey(k)
    local sel = ed.sel
    local lines = sel.box.lines
    local l = lines[sel.line]
    if k == keys.backspace then
      if sel.col > 0 then
        lines[sel.line] = l:sub(1, sel.col - 1) .. l:sub(sel.col + 1); sel.col = sel.col - 1
      elseif sel.line > 1 then
        local prev = lines[sel.line - 1]
        sel.col = #prev
        lines[sel.line - 1] = prev .. l
        table.remove(lines, sel.line); sel.line = sel.line - 1
      end
      ed.textChanged()
    elseif k == keys.delete then
      if sel.col < #l then lines[sel.line] = l:sub(1, sel.col) .. l:sub(sel.col + 2)
      elseif sel.line < #lines then
        lines[sel.line] = l .. lines[sel.line + 1]; table.remove(lines, sel.line + 1)
      end
      ed.textChanged()
    elseif k == keys.enter or k == keys.numPadEnter then
      lines[sel.line] = l:sub(1, sel.col)
      table.insert(lines, sel.line + 1, l:sub(sel.col + 1))
      sel.line, sel.col = sel.line + 1, 0
      ed.textChanged()
    elseif k == keys.left then sel.col = max(0, sel.col - 1)
    elseif k == keys.right then sel.col = min(#l, sel.col + 1)
    elseif k == keys.up and sel.line > 1 then sel.line = sel.line - 1; sel.col = min(sel.col, #lines[sel.line])
    elseif k == keys.down and sel.line < #lines then sel.line = sel.line + 1; sel.col = min(sel.col, #lines[sel.line])
    elseif k == keys.home then sel.col = 0
    elseif k == keys["end"] then sel.col = #l
    elseif k == keys.tab then ed.deselect()
    else return false end
    return true
  end

  function ed.deleteSelectedBox()
    if not ed.sel then return end
    local text = ed.doc().img.text
    for i, b in ipairs(text) do if b == ed.sel.box then table.remove(text, i); break end end
    ed.textChanged()
    ed.sel = nil
    ed.endOp()
  end

  -- Moves the selected box by (dx, dy) cells, staying inside the image.
  function ed.moveBox(dx, dy)
    local img = ed.doc().img
    local b = ed.sel.box
    b.x = max(1, min(img.w, b.x + dx))
    b.y = max(1, min(img.h, b.y + dy))
    ed.textChanged()
  end
end
