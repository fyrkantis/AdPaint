-- Editor canvas: zoom, panning, screen <-> image coordinates and drawing
-- the image (with its text layer) into the canvas area. The maths and the
-- drawing are in lib/render.lua; this keeps each document's view state
-- (d.vx, d.vy, d.zoom) and places the canvas on screen (rows 2..H-3).
local render = require("lib.render")

local floor, max = math.floor, math.max

return function(ed)
  local col = ed.U.col

  function ed.zoomInfo(d) return ed.ZOOMS[(d or ed.doc()).zoom] end

  -- The render view of a document's canvas.
  local function view(d)
    local z = ed.zoomInfo(d)
    return { vx = d.vx, vy = d.vy, zw = z.zw, zh = z.zh, w = ed.W, h = ed.viewH() }
  end
  local function store(d, v) d.vx, d.vy = v.vx, v.vy end

  -- Screen position -> (pixel x, pixel y, cell x, cell y); y=2 is the first
  -- canvas row.
  function ed.screenToImage(sx, sy)
    return render.toImage(view(ed.doc()), sx - 1, sy - 2)
  end

  -- Screen position of image cell (cx, cy) (its middle character when zoomed).
  function ed.cellToScreen(cx, cy)
    local c, r = render.cellToView(view(ed.doc()), cx, cy)
    return c + 1, r + 2
  end

  function ed.clampView(d) store(d, render.clamp(view(d), d.img)) end

  -- Keeps the pixel under (cxs, cys) (default: the view centre) in place.
  function ed.setZoom(level, cxs, cys)
    local d = ed.doc()
    cxs, cys = cxs or floor(ed.W / 2), cys or floor(ed.viewH() / 2) + 2
    local v = view(d)
    d.zoom = level
    local z = ed.zoomInfo(d)
    store(d, render.zoom(v, d.img, z.zw, z.zh, cxs - 1, cys - 2))
  end

  function ed.toggleZoom() ed.setZoom(ed.doc().zoom % #ed.ZOOMS + 1) end

  function ed.pan(dx, dy) -- in screen characters
    local d = ed.doc()
    store(d, render.pan(view(d), d.img, dx, dy))
  end

  -- A quarter screen per step (the Pan tool's arrow buttons).
  function ed.panStep(dx, dy)
    ed.pan(dx * max(2, floor(ed.W / 4)), dy * max(2, floor(ed.viewH() / 4)))
  end

  -- Scrolls so that image pixel (px, py) is in the middle (touch panning).
  function ed.centreOn(px, py)
    local d = ed.doc()
    store(d, render.centreOn(view(d), d.img, px, py))
  end

  function ed.drawCanvas()
    local d = ed.doc()
    render.draw(ed.win, 1, 2, d.img, view(d), {
      text = ed.showText,
      void = { col.bar, col.void },
      contrast = col.text,
      frameColour = ed.showText and function(box)
        return (ed.sel and ed.sel.box == box) and col.hi or col.dim
      end or nil,
    })
  end
end
