-- Editor state: documents (tabs), tool settings, colours, undo glue.
-- Every lib/editor module is installed into one shared table `ed`, which
-- holds the editor's state and the functions modules call on each other.
local adimg = require("lib.adimg")
local history = require("lib.history")

return function(ed)
  ed.docs, ed.cur = {}, 1
  ed.tool = "brush"
  ed.primary, ed.secondary = 15, 0 -- L / R colours (black / white)
  ed.brushSize, ed.dither = 1, 8   -- dither: 1..8 (8 = solid)
  ed.showText = true
  ed.running = true
  ed.status, ed.statusUntil = nil, 0
  ed.menuOpen = false
  ed.sel = nil       -- text selection {box=, line=, col=}
  ed.drag = nil      -- active mouse drag
  ed.op = nil        -- undo operation being recorded
  ed.touchSlot = 1   -- on monitors (taps only): 1 = palette taps set L/F, 2 = R/B
  ed.pendingFiles = {} -- files dropped while a prompt or an import was busy

  -- Zoom levels: chars per pixel (zw x zh). Level 1 is native teletext,
  -- level 2 turns each cell into 6x6 chars (3x2 chars per pixel = square).
  ed.ZOOMS = {
    { name = "1x" },
    { name = "6x", zw = 3, zh = 2 },
  }
  ed.NEW_W, ed.NEW_H = 18, 24 -- default size of a new canvas, in cells
  ed.TOOLS = { -- name, label, icon (CC font characters)
    { "brush", "Brush", "\7" }, { "fill", "Fill", "\21" }, { "text", "Text", "\20" },
    { "pick", "Pick", "\35" }, { "pan", "Pan", "\18" },
  }

  function ed.doc() return ed.docs[ed.cur] end

  function ed.palette(d)
    d = d or ed.doc()
    return d and d.img.palette or adimg.DEFAULT_PALETTE -- no tab yet: default
  end

  function ed.setStatus(msg, secs)
    ed.status = msg
    ed.statusUntil = os.clock() + (secs or 4)
  end

  -- Rows: 1 tabs, 2..H-3 canvas, H-2 tool settings, H-1 palette, H tools.
  function ed.viewH() return ed.H - 4 end

  -- `skip`: a palette slot the interface must not use (the one being edited).
  function ed.computeUi(skip) ed.U.pickColours(ed.palette(), skip) end

  -- A tab's first L/R colours: the darkest and the brightest palette colour
  -- (black / white with the default palette).
  local function resetColours()
    local pal = ed.palette()
    local dl, bl = math.huge, -1
    for i = 0, 15 do
      local r, g, b = adimg.rgb(pal[i])
      local l = r * 0.3 + g * 0.59 + b * 0.11
      if l < dl then ed.primary, dl = i, l end
      if l > bl then ed.secondary, bl = i, l end
    end
  end

  -- Every tab remembers its own L/R colours. `colourDoc` is the tab whose
  -- colours are currently loaded into primary/secondary.
  local colourDoc = nil

  -- Called whenever the current tab (or its palette) changes.
  function ed.applyPalette()
    adimg.applyPalette(ed.win, ed.palette())
    ed.computeUi()
    local d = ed.doc()
    if d ~= colourDoc then
      if colourDoc then colourDoc.primary, colourDoc.secondary = ed.primary, ed.secondary end
      colourDoc = d
      if d.primary then ed.primary, ed.secondary = d.primary, d.secondary else resetColours() end
    end
  end

  ---------------------------------------------------------------------------
  -- Documents
  ---------------------------------------------------------------------------
  function ed.newDoc(img, path)
    return history.attach({ img = img, path = path, dirty = false, zoom = 1, vx = 0, vy = 0 })
  end

  function ed.docName(d)
    return d.path and fs.getName(d.path) or "untitled"
  end

  function ed.addDoc(d)
    ed.docs[#ed.docs + 1] = d
    ed.cur = #ed.docs
    ed.sel = nil
    ed.applyPalette()
  end

  function ed.blankDoc(w, h)
    return ed.newDoc(adimg.new(w or ed.NEW_W, h or ed.NEW_H, 0))
  end

  ---------------------------------------------------------------------------
  -- Undo glue: one operation is recorded at a time (ed.op)
  ---------------------------------------------------------------------------
  function ed.beginOp(kind) ed.op = history.begin(ed.doc(), kind) end

  function ed.endOp()
    history.commit(ed.op)
    ed.op = nil
  end

  -- Pixel writer for lib/paint: records undo information in ed.op.
  function ed.setPx(img, i, c) history.set(ed.op, img, i, c) end

  function ed.textChanged() history.touch(ed.op) end

  function ed.undo(redo)
    local d = ed.doc()
    ed.deselect()
    ed.endOp()
    if not history.step(d, redo) then
      ed.setStatus(redo and "Nothing to redo" or "Nothing to undo")
      return
    end
    ed.applyPalette()
  end
end
