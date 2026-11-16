-- ui: small terminal UI toolkit used by adpaint: colours that stay readable
-- under any palette, button rows, and modal dialogs (text prompt, multiple
-- choice, anchor picker, scrolling message) that work with a mouse as well as on
-- touch-only monitors (every dialog has tappable buttons on the bottom row).
--
--   local U = ui.new{
--     win = window,              -- where to draw
--     monitor = "monitor_0",     -- name of a touch monitor, or nil (mouse)
--     draw = function(overlay),  -- redraw the program's screen, then call
--                                -- overlay() (if given) to draw the dialog
--     area = function() return y0, h end, -- rows dialogs are centred in
--     onEvent = function(ev),    -- events a dialog doesn't use (files
--   }                            -- dropped, terminal resized)
local M = {}

local floor, max, min = math.floor, math.max, math.min
local HEX = "0123456789abcdef"

-- Perceptually weighted squared distance between two 0xRRGGBB colours.
local function dist(a, b)
  local ar, ag, ab = floor(a / 65536) % 256, floor(a / 256) % 256, a % 256
  local br, bg, bb = floor(b / 65536) % 256, floor(b / 256) % 256, b % 256
  local dr, dg, db = ar - br, ag - bg, ab - bb
  local rm = (ar + br) / 2
  return (2 + rm / 256) * dr * dr + 4 * dg * dg + (2 + (255 - rm) / 256) * db * db
end

function M.new(ctx)
  local U = {}
  local win = ctx.win
  local onEvent = ctx.onEvent or function() end

  -- U.monitor: name of the touch monitor in use (taps only), or nil.
  U.monitor = ctx.monitor

  -- Interface colours (palette indices), chosen by U.pickColours.
  -- dark/bar: backgrounds, text/dim: text, accent/hi: highlights,
  -- void: the area outside the image.
  local col = { dark = 15, bar = 7, text = 0, dim = 8, accent = 11, hi = 4, void = 7 }
  U.col = col

  -- Modifier keys (kept up to date by every dialog and by U.trackModifiers).
  U.mods = { ctrl = false, shift = false }

  -- Picks the palette entries closest to the colours the interface wants,
  -- so it stays readable with custom image palettes. `skip`: a slot not to
  -- use (e.g. the one being edited). The colour table is updated in place.
  function U.pickColours(pal, skip)
    local function nearest(rgb, avoid)
      local best, bd = 0, math.huge
      for i = 0, 15 do
        if i ~= avoid and i ~= skip then
          local d = dist(pal[i], rgb)
          if d < bd then best, bd = i, d end
        end
      end
      return best
    end
    col.dark = nearest(0x111111)
    col.bar = nearest(0x3C3C3C, col.dark)
    col.text = nearest(0xF0F0F0, col.bar)
    col.dim = nearest(0x999999, col.bar)
    col.accent = nearest(0x3366CC, col.bar)
    col.hi = nearest(0xDEDE6C, col.bar)
    col.void = nearest(0x262626)
  end

  ---------------------------------------------------------------------------
  -- Drawing helpers
  ---------------------------------------------------------------------------
  local function hex(c) return HEX:sub(c + 1, c + 1) end

  function U.blitAt(x, y, text, fg, bg)
    win.setCursorPos(x, y)
    win.blit(text, string.rep(hex(fg), #text), string.rep(hex(bg), #text))
  end
  local blitAt = U.blitAt

  -- A row of items { text, action, active, gap }: items with an action are
  -- buttons (active ones highlighted), `gap` is the space after (default 1).
  function U.rowWidth(items)
    local w = 0
    for _, it in ipairs(items) do w = w + #it[1] + (it[4] or 1) end
    return w
  end

  -- Draws a row of items at row y, appending button hit boxes
  -- { x1, x2, action } to `hits`.
  function U.drawRow(y, items, hits)
    local W = win.getSize()
    win.setCursorPos(1, y)
    win.setBackgroundColour(2 ^ col.bar); win.clearLine()
    local x = 1
    for _, it in ipairs(items) do
      local text = it[1]
      if x > W then break end
      text = text:sub(1, W - x + 1)
      if it[2] then
        blitAt(x, y, text, it[3] and col.dark or col.text, it[3] and col.hi or col.dark)
        hits[#hits + 1] = { x, x + #text - 1, it[2] }
      else
        blitAt(x, y, text, col.text, col.bar)
      end
      x = x + #text + (it[4] or 1)
    end
  end

  -- The first of several row layouts (widest first) that fits the screen.
  function U.pickLayout(...)
    local W = win.getSize()
    local layouts = { ... }
    for _, l in ipairs(layouts) do if U.rowWidth(l) - 1 <= W then return l end end
    return layouts[#layouts]
  end

  -- Draws buttons { label, value } right-aligned on the bottom row; returns
  -- hit boxes and the last column left free for other content.
  function U.bottomButtons(buttons)
    local W, H = win.getSize()
    local hits, x = {}, W + 1
    for i = #buttons, 1, -1 do
      local label = " " .. buttons[i][1] .. " "
      x = x - #label
      blitAt(x, H, label, col.text, col.bar)
      hits[#hits + 1] = { x, x + #label - 1, buttons[i][2] }
      x = x - 1
    end
    return hits, x - 1
  end

  -- The dialog bar on the bottom row: `label` on the left (cut to fit),
  -- buttons on the right. Returns hits and the last free column.
  function U.bottomBar(label, buttons)
    local _, H = win.getSize()
    win.setCursorPos(1, H)
    win.setBackgroundColour(2 ^ col.accent); win.setTextColour(2 ^ col.text)
    win.clearLine()
    local hits, free = U.bottomButtons(buttons)
    win.setCursorPos(1, H)
    win.setBackgroundColour(2 ^ col.accent)
    if label then win.write(label:sub(1, max(0, free))) end
    return hits, free
  end

  function U.hitButton(hits, x)
    for _, h in ipairs(hits) do if x >= h[1] and x <= h[2] then return h[3] end end
  end

  -- Draws an empty pw x ph panel centred in the dialog area; returns its
  -- top-left corner and the last row that may be drawn on.
  function U.panel(pw, ph)
    local W = win.getSize()
    local ay, ah = ctx.area()
    local x0 = max(1, floor((W - pw) / 2) + 1)
    local y0 = max(ay, floor((ah - ph) / 2) + ay)
    local last = ay + ah - 1
    win.setBackgroundColour(2 ^ col.bar)
    for y = y0, min(last, y0 + ph - 1) do win.setCursorPos(x0, y); win.write(string.rep(" ", pw)) end
    return x0, y0, last
  end

  ---------------------------------------------------------------------------
  -- Events
  ---------------------------------------------------------------------------
  -- Returns button, x, y if the event is a click/touch meant for us.
  function U.asClick(ev)
    if ev[1] == "mouse_click" and not U.monitor then return ev[2], ev[3], ev[4] end
    if ev[1] == "monitor_touch" and U.monitor and ev[2] == U.monitor then
      return 1, ev[3], ev[4]
    end
  end

  -- Keeps U.mods up to date from key / key_up events.
  function U.trackModifiers(ev)
    local k = ev[2]
    if k == keys.leftCtrl or k == keys.rightCtrl then U.mods.ctrl = ev[1] == "key" end
    if k == keys.leftShift or k == keys.rightShift then U.mods.shift = ev[1] == "key" end
  end

  -- Runs a modal dialog: redraws with `overlay` and hands every event to
  -- handle(ev, button, x, y) (button/x/y set for clicks/taps meant for us)
  -- until it returns true, value; then returns value. key_up, dropped files
  -- and resizes are dealt with here.
  function U.modal(overlay, handle)
    while true do
      ctx.draw(overlay)
      local ev = { os.pullEventRaw() }
      local e = ev[1]
      if e == "key_up" then U.trackModifiers(ev)
      elseif e == "file_transfer" or e == "term_resize" or e == "monitor_resize" then onEvent(ev)
      else
        if e == "key" then U.trackModifiers(ev) end
        local done, value = handle(ev, U.asClick(ev))
        if done then return value end
      end
    end
  end

  ---------------------------------------------------------------------------
  -- Dialogs
  ---------------------------------------------------------------------------

  -- Text input. Returns the entered string, or nil when cancelled.
  -- `complete(text)` may return a list of suffixes (like read()'s completion):
  -- the current one is shown greyed out after the text. Tab (or tapping the
  -- suggestion) accepts it, Up/Down cycle through the alternatives.
  -- onChange(text) is called whenever the text changes (for live previews).
  function U.prompt(label, default, complete, onChange)
    -- A key that opened this prompt (shortcut or a choose() answer) is
    -- followed by its char event: drop it so it doesn't end up in the text.
    os.queueEvent("adpaint_flush")
    while true do
      local ev = { os.pullEventRaw() }
      if ev[1] == "adpaint_flush" then break
      elseif ev[1] == "file_transfer" then onEvent(ev)
      elseif ev[1] == "key" or ev[1] == "key_up" then U.trackModifiers(ev) end
    end
    local text = tostring(default or "")
    local pos = #text
    local lastText = nil
    local comps, ci = nil, 1
    local function recomplete()
      comps, ci = nil, 1
      if complete and pos == #text then
        local ok, c = pcall(complete, text)
        if ok and type(c) == "table" and #c > 0 then comps = c end
      end
    end
    recomplete()
    local hits, fieldX, fieldEnd
    local function overlay()
      local _, H = win.getSize()
      local free
      hits, free = U.bottomBar(nil, { { "OK", "ok" }, { "Cancel", "cancel" } })
      local lab = label:sub(1, max(0, free - 8))
      win.write(lab)
      local fx = #lab + 1
      local fw = max(1, free - fx + 1)
      local scroll = max(0, pos - fw + 1)
      win.setBackgroundColour(2 ^ col.dark)
      win.write((text:sub(scroll + 1, scroll + fw) .. string.rep(" ", fw)):sub(1, fw))
      if comps then
        local gx = fx + #text - scroll
        local ghost = comps[ci]:sub(1, max(0, fx + fw - gx))
        win.setCursorPos(gx, H)
        win.setTextColour(2 ^ col.dim)
        win.write(ghost)
      end
      fieldX, fieldEnd = fx, fx + fw - 1
      win.setCursorPos(fx + pos - scroll, H)
      win.setTextColour(2 ^ col.text)
      win.setCursorBlink(true)
    end
    while true do
      if onChange and text ~= lastText then onChange(text); lastText = text end
      -- each event ends a round (returning false) so onChange sees the new
      -- text before the redraw; {text} or {nil} ends the prompt
      local result = U.modal(overlay, function(ev, button, x, y)
        local _, H = win.getSize()
        local e = ev[1]
        if e == "terminate" then return true, { nil }
        elseif button and y == H then
          local r = U.hitButton(hits, x)
          if r == "ok" then return true, { text } elseif r == "cancel" then return true, { nil }
          elseif comps and x >= fieldX and x <= fieldEnd then
            text = text .. comps[ci]; pos = #text; recomplete()
          end
        elseif e == "char" or e == "paste" then
          text = text:sub(1, pos) .. ev[2] .. text:sub(pos + 1)
          pos = pos + #ev[2]
          recomplete()
        elseif e == "key" then
          local k = ev[2]
          if k == keys.enter or k == keys.numPadEnter then return true, { text }
          elseif k == keys.backspace and pos > 0 then
            text = text:sub(1, pos - 1) .. text:sub(pos + 1); pos = pos - 1
          elseif k == keys.delete then text = text:sub(1, pos) .. text:sub(pos + 2)
          elseif k == keys.left then pos = max(0, pos - 1)
          elseif k == keys.right and comps and pos == #text then
            text = text .. comps[ci]; pos = #text
          elseif k == keys.right then pos = min(#text, pos + 1)
          elseif k == keys.home then pos = 0
          elseif k == keys["end"] then pos = #text
          elseif k == keys.tab and comps then text = text .. comps[ci]; pos = #text
          elseif k == keys.up and comps then ci = (ci - 2) % #comps + 1
          elseif k == keys.down and comps then ci = ci % #comps + 1
          end
          if k ~= keys.up and k ~= keys.down then recomplete() end
        end
        return true, false
      end)
      if result then return result[1] end
    end
  end

  -- Multiple choice with touch buttons. options = { {label, value}, ... }.
  -- A key press of an option's first letter also picks it; Enter picks the
  -- first option. Returns the value, or nil if cancelled/terminated.
  function U.choose(question, options)
    local hits
    return U.modal(function()
      hits = U.bottomBar(question, options)
    end, function(ev, button, x, y)
      local _, H = win.getSize()
      if ev[1] == "terminate" then return true, nil
      elseif button and y == H then
        local r = U.hitButton(hits, x)
        if r ~= nil then return true, r end
      elseif ev[1] == "key" then
        if ev[2] == keys.enter or ev[2] == keys.numPadEnter then return true, options[1][2] end
        local name = keys.getName(ev[2])
        for _, o in ipairs(options) do
          if name and #name == 1 and o[1]:sub(1, 1):lower() == name then return true, o[2] end
        end
      end
    end)
  end

  function U.confirm(question)
    return U.choose(question, { { "Yes", true }, { "No", false } }) == true
  end

  -- Picks one of 9 anchor points (corners, sides, centre) on a touchable
  -- 3x3 grid. Returns ax, ay in {0, 0.5, 1}, or nil if cancelled.
  local ANCHOR_NAMES = { "top left", "top", "top right", "left", "centre", "right",
                         "bottom left", "bottom", "bottom right" }
  function U.chooseAnchor(title, default)
    local pick = default or 1
    local hits, cells
    local done = U.modal(function()
      cells = {}
      local _, ah = ctx.area()
      local bw, bh = 5, ah >= 15 and 3 or 1
      local pw, ph = 3 * bw + 2 + 4, 3 * bh + 2 + 4
      local x0, y0, last = U.panel(pw, ph)
      win.setCursorPos(x0 + 2, y0 + 1)
      win.setTextColour(2 ^ col.text)
      win.write(title:sub(1, pw - 4))
      for i = 1, 9 do
        local gx = x0 + 2 + ((i - 1) % 3) * (bw + 1)
        local gy = y0 + 3 + floor((i - 1) / 3) * (bh + 1)
        local c = i == pick and col.hi or col.dark
        for y = gy, gy + bh - 1 do
          if y <= last then blitAt(gx, y, string.rep(" ", bw), col.text, c) end
        end
        cells[i] = { gx, gy, gx + bw - 1, gy + bh - 1 }
      end
      hits = U.bottomBar("Anchor: " .. ANCHOR_NAMES[pick], { { "OK", "ok" }, { "Cancel", "cancel" } })
    end, function(ev, button, x, y)
      local _, H = win.getSize()
      if ev[1] == "terminate" then return true, false
      elseif button then
        if y == H then
          local r = U.hitButton(hits, x)
          if r == "ok" then return true, true elseif r == "cancel" then return true, false end
        else
          local confirmed = false
          for i, c in ipairs(cells) do
            if x >= c[1] and x <= c[3] and y >= c[2] and y <= c[4] then
              if i == pick then confirmed = true end -- tapping the chosen one again confirms
              pick = i
            end
          end
          if confirmed then return true, true end
        end
      elseif ev[1] == "key" then
        local k = ev[2]
        if k == keys.enter or k == keys.numPadEnter then return true, true
        elseif k == keys.left and (pick - 1) % 3 > 0 then pick = pick - 1
        elseif k == keys.right and (pick - 1) % 3 < 2 then pick = pick + 1
        elseif k == keys.up and pick > 3 then pick = pick - 3
        elseif k == keys.down and pick < 7 then pick = pick + 3 end
      end
    end)
    if done then return ((pick - 1) % 3) / 2, floor((pick - 1) / 3) / 2 end
  end

  -- Word-wraps lines to `width` columns. A line's leading spaces are kept
  -- and continuation lines get the same indent; words longer than a line are
  -- split.
  function U.wrap(lines, width)
    local out = {}
    for _, l in ipairs(lines) do
      local indent = l:match("^ *")
      if #indent >= width then indent = "" end
      local cur = indent
      local empty = true
      for word in l:gmatch("%S+") do
        while #indent + #word > width do -- too long for any line: split it
          if not empty then out[#out + 1] = cur end
          local room = width - #indent
          out[#out + 1] = indent .. word:sub(1, room)
          word = word:sub(room + 1)
          cur, empty = indent, true
        end
        if empty then cur = indent .. word; empty = false
        elseif #cur + 1 + #word > width then out[#out + 1] = cur; cur = indent .. word
        else cur = cur .. " " .. word end
      end
      out[#out + 1] = empty and "" or cur
    end
    return out
  end

  -- Full-screen text that scrolls: More / Space (a third of a screen), Down,
  -- Page Down and the scroll wheel move it down; Up / Page Up move it back. It only closes on purpose
  -- (Close button, Enter, Q or Backspace), so a repeated key or tap can't
  -- skip past the end.
  function U.message(lines)
    local top = 1
    local hits, wrapped, rows
    local function layout()
      local W, H = win.getSize()
      wrapped = U.wrap(lines, max(1, W - 2))
      rows = max(1, H - 1)
      top = max(1, min(top, #wrapped - rows + 1))
      return W, H
    end
    local function scroll(n) top = top + n; layout() end
    local function step() return max(1, floor(rows / 3)) end
    return U.modal(function()
      local W, H = layout()
      win.setBackgroundColour(2 ^ col.dark); win.setTextColour(2 ^ col.text)
      for y = 1, rows do
        win.setCursorPos(1, y); win.clearLine()
        local l = wrapped[top + y - 1]
        if l then win.setCursorPos(2, y); win.write(l) end
      end
      local atEnd = top + rows - 1 >= #wrapped
      local buttons = W >= 26
        and { { "Up", "up" }, { atEnd and "End" or "More", "down" }, { "Close", "close" } }
        or { { "\30", "up" }, { "\31", "down" }, { "\215", "close" } }
      local where = #wrapped <= rows and "" or (" %d-%d/%d"):format(top, min(#wrapped, top + rows - 1), #wrapped)
      hits = U.bottomBar(where, buttons)
    end, function(ev, button, x, y)
      local _, H = win.getSize()
      local e = ev[1]
      if e == "terminate" then return true
      elseif button and y == H then
        local r = U.hitButton(hits, x)
        if r == "close" then return true
        elseif r == "down" then scroll(step())
        elseif r == "up" then scroll(-step()) end
      elseif e == "mouse_scroll" and not U.monitor then scroll(ev[2])
      elseif e == "key" then
        local k = ev[2]
        if k == keys.enter or k == keys.numPadEnter or k == keys.q or k == keys.backspace then
          if not ev[3] then return true end -- ignore auto-repeat
        elseif k == keys.down then scroll(1)
        elseif k == keys.up then scroll(-1)
        elseif k == keys.space then scroll(step())
        elseif k == keys.pageDown then scroll(rows - 1)
        elseif k == keys.pageUp then scroll(1 - rows)
        elseif k == keys.home then top = 1
        elseif k == keys["end"] then scroll(#wrapped) end
      end
    end)
  end

  return U
end

return M
