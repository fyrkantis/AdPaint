-- Editor canvas: zoom, panning, screen <-> image coordinates and drawing
-- the image (with its text layer) into the canvas area.
local adimg = require("lib.adimg")
local paint = require("lib.paint")

local floor, max, min = math.floor, math.max, math.min
local HEX = adimg.IDX_TO_HEX
local CHARS = {}
for i = 0, 31 do CHARS[i] = string.char(128 + i) end

return function(ed)
  local col = ed.U.col

  function ed.zoomInfo(d) return ed.ZOOMS[(d or ed.doc()).zoom] end

  -- Screen position -> (pixel x, pixel y, cell x, cell y); y=2 is the first
  -- canvas row.
  function ed.screenToImage(sx, sy)
    local d = ed.doc()
    local z = ed.zoomInfo(d)
    if not z.zw then
      local cx, cy = d.vx / 2 + sx - 1, d.vy / 3 + sy - 2
      return cx * 2, cy * 3, cx, cy
    end
    local px = d.vx + floor((sx - 1) / z.zw)
    local py = d.vy + floor((sy - 2) / z.zh)
    return px, py, floor(px / 2), floor(py / 3)
  end

  -- Screen position of image cell (cx, cy) (its middle character when zoomed).
  function ed.cellToScreen(cx, cy)
    local d = ed.doc()
    local z = ed.zoomInfo(d)
    if z.zw then
      return (cx * 2 - d.vx) * z.zw + z.zw + 1, (cy * 3 - d.vy) * z.zh + floor(3 * z.zh / 2) + 2
    end
    return cx - d.vx / 2 + 1, cy - d.vy / 3 + 2
  end

  function ed.clampView(d)
    local z = ed.zoomInfo(d)
    local W, vh = ed.W, ed.viewH()
    local vwPx = z.zw and floor(W / z.zw) or W * 2
    local vhPx = z.zh and floor(vh / z.zh) or vh * 3
    d.vx = max(-vwPx + 2, min(d.vx, d.img.pw - 2))
    d.vy = max(-vhPx + 3, min(d.vy, d.img.ph - 3))
    if not z.zw then
      d.vx = floor(d.vx / 2) * 2
      d.vy = floor(d.vy / 3) * 3
    end
  end

  function ed.setZoom(level, cxs, cys)
    local d = ed.doc()
    -- keep the pixel under (cxs, cys) (or the view centre) in place
    cxs, cys = cxs or floor(ed.W / 2), cys or floor(ed.viewH() / 2) + 2
    local px, py = ed.screenToImage(cxs, cys)
    d.zoom = level
    local z = ed.zoomInfo(d)
    if z.zw then
      d.vx = px - floor((cxs - 1) / z.zw)
      d.vy = py - floor((cys - 2) / z.zh)
    else
      d.vx = px - (cxs - 1) * 2
      d.vy = py - (cys - 2) * 3
    end
    ed.clampView(d)
  end

  function ed.toggleZoom() ed.setZoom(ed.doc().zoom % #ed.ZOOMS + 1) end

  function ed.pan(dx, dy) -- in screen characters
    local d = ed.doc()
    local z = ed.zoomInfo(d)
    if z.zw then
      d.vx = d.vx + dx * max(1, floor(4 / z.zw))
      d.vy = d.vy + dy * max(1, floor(3 / z.zh))
    else
      d.vx, d.vy = d.vx + dx * 2, d.vy + dy * 3
    end
    ed.clampView(d)
  end

  -- A quarter screen per step (the Pan tool's arrow buttons).
  function ed.panStep(dx, dy)
    ed.pan(dx * max(2, floor(ed.W / 4)), dy * max(2, floor(ed.viewH() / 4)))
  end

  -- Scrolls so that image pixel (px, py) is in the middle (touch panning).
  function ed.centreOn(px, py)
    local d = ed.doc()
    local z = ed.zoomInfo(d)
    local midX, midY = floor(ed.W / 2), floor(ed.viewH() / 2)
    if z.zw then d.vx, d.vy = px - floor(midX / z.zw), py - floor(midY / z.zh)
    else d.vx, d.vy = px - midX * 2, py - midY * 3 end
    ed.clampView(d)
  end

  ---------------------------------------------------------------------------
  -- Drawing
  ---------------------------------------------------------------------------
  local function drawNative(d, img, tmap, W, vh)
    local win = ed.win
    local voidC, voidB = HEX[col.bar], HEX[col.void]
    local cx0, cy0 = d.vx / 2, d.vy / 3
    for row = 0, vh - 1 do
      local cy = cy0 + row
      local t, f, b = {}, {}, {}
      for c = 0, W - 1 do
        local cx = cx0 + c
        if cx >= 0 and cy >= 0 and cx < img.w and cy < img.h then
          local tm = tmap[cy * img.w + cx]
          if tm then
            t[c + 1] = tm[1]; f[c + 1] = HEX[tm[2]]
            b[c + 1] = HEX[tm[3] or paint.cellMajority(img, cx, cy)]
          else
            local bits, fg, bg = adimg.encodeCell(img.px, img.pw, cx, cy)
            t[c + 1] = CHARS[bits]; f[c + 1] = HEX[fg]; b[c + 1] = HEX[bg]
          end
        else
          t[c + 1] = "\127"; f[c + 1] = voidC; b[c + 1] = voidB
        end
      end
      win.setCursorPos(1, row + 2)
      win.blit(table.concat(t), table.concat(f), table.concat(b))
    end
  end

  -- Thin frame around each text box (selected box highlighted), drawn with
  -- drawing characters on the box's outermost screen characters.
  local function drawFrames(d, img, rows, zw, zh, W, vh)
    for _, bx in ipairs(img.text) do
      local fc = HEX[(ed.sel and ed.sel.box == bx) and col.hi or col.dim]
      local c0 = ((bx.x - 1) * 2 - d.vx) * zw
      local c1 = ((bx.x - 1 + paint.boxWidth(bx)) * 2 - d.vx) * zw - 1
      local r0 = ((bx.y - 1) * 3 - d.vy) * zh
      local r1 = ((bx.y - 1 + #bx.lines) * 3 - d.vy) * zh - 1
      for row = max(0, r0), min(vh - 1, r1) do
        local r = rows[row]
        local T, B = row == r0, row == r1
        for c = max(0, c0), min(W - 1, c1) do
          local L, R = c == c0, c == c1
          if (L or R or T or B) and r[1][c + 1] == " " then
            local m = ((L or T) and 1 or 0) + ((R or T) and 2 or 0) + (L and 4 or 0)
              + (R and 8 or 0) + ((L or B) and 16 or 0) + ((R or B) and 32 or 0)
            local pix = r[3][c + 1]
            local f = fc == pix and HEX[col.text] or fc
            if m >= 32 then -- bottom-right sub-pixel is always background
              r[1][c + 1] = CHARS[63 - m]; r[2][c + 1] = pix; r[3][c + 1] = f
            else
              r[1][c + 1] = CHARS[m]; r[2][c + 1] = f
            end
          end
        end
      end
    end
  end

  local function drawZoomed(d, img, tmap, z, W, vh)
    local win = ed.win
    local voidC, voidB = HEX[col.bar], HEX[col.void]
    local zw, zh = z.zw, z.zh
    local rows = {}
    for row = 0, vh - 1 do
      local py = d.vy + floor(row / zh)
      local t, f, b = {}, {}, {}
      for c = 0, W - 1 do
        local px = d.vx + floor(c / zw)
        if px >= 0 and py >= 0 and px < img.pw and py < img.ph then
          local cl = img.px[py * img.pw + px + 1]
          local tm = tmap[floor(py / 3) * img.w + floor(px / 2)]
          if tm and tm[3] then cl = tm[3] end
          t[c + 1] = " "; f[c + 1] = "0"; b[c + 1] = HEX[cl]
        else
          t[c + 1] = "\127"; f[c + 1] = voidC; b[c + 1] = voidB
        end
      end
      rows[row] = { t, f, b }
    end
    if ed.showText then drawFrames(d, img, rows, zw, zh, W, vh) end
    -- letters: one character in the middle of each text cell
    for k, tm in pairs(tmap) do
      local cx, cy = k % img.w, floor(k / img.w)
      local c = (cx * 2 - d.vx) * zw + zw
      local row = (cy * 3 - d.vy) * zh + floor(3 * zh / 2)
      local r = rows[row]
      if r and c >= 0 and c < W then
        r[1][c + 1] = tm[1]; r[2][c + 1] = HEX[tm[2]]
      end
    end
    for row = 0, vh - 1 do
      local r = rows[row]
      win.setCursorPos(1, row + 2)
      win.blit(table.concat(r[1]), table.concat(r[2]), table.concat(r[3]))
    end
  end

  function ed.drawCanvas()
    local d = ed.doc()
    local img = d.img
    local z = ed.zoomInfo(d)
    local tmap = ed.showText and paint.textMap(img) or {}
    if z.zw then drawZoomed(d, img, tmap, z, ed.W, ed.viewH())
    else drawNative(d, img, tmap, ed.W, ed.viewH()) end
  end
end
