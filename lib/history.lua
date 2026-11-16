-- history: undo/redo for adimg documents.
--
-- A document is any table with an `img` (adimg image) plus `undo` and
-- `redo` lists (history.attach adds them). An operation records the old
-- value of every pixel it changes (plus, optionally, the old text layer or
-- a snapshot of the whole image). Undoing swaps old and current state, so
-- applying an operation twice is a no-op and undo/redo are the same swap.
local adimg = require("lib.adimg")

local M = {}

M.LIMIT = 64 -- operations kept per document

function M.attach(doc)
  doc.undo, doc.redo = doc.undo or {}, doc.redo or {}
  return doc
end

local function snapshot(img)
  return { w = img.w, h = img.h, pw = img.pw, ph = img.ph, px = img.px, text = img.text, palette = img.palette }
end
local function restore(img, s)
  img.w, img.h, img.pw, img.ph, img.px, img.text, img.palette = s.w, s.h, s.pw, s.ph, s.px, s.text, s.palette
end

-- Starts an operation on `doc`. kind: nil (pixels only), "text" (also the
-- text layer) or "full" (the whole image: size, pixels, text, palette; use
-- it before replacing those tables).
function M.begin(doc, kind)
  local op = { pix = {}, doc = doc }
  if kind == "text" then op.text = adimg.copyText(doc.img.text) end
  if kind == "full" then op.full = snapshot(doc.img); op.changed = true end
  return op
end

-- Writes pixel i of img, recording the old value in `op` (may be nil).
function M.set(op, img, i, c)
  local old = img.px[i]
  if old ~= c then
    if op then
      if op.pix[i] == nil then op.pix[i] = old end
      op.changed = true
    end
    img.px[i] = c
  end
end

-- Marks an operation as having changed something (e.g. text edits).
function M.touch(op) if op then op.changed = true end end

-- Finishes an operation: if it changed anything it becomes undoable, the
-- redo list is cleared and the document is marked dirty. Returns true then.
function M.commit(op)
  if not (op and op.changed) then return false end
  local d = op.doc
  table.insert(d.undo, op)
  if #d.undo > M.LIMIT then table.remove(d.undo, 1) end
  d.redo = {}
  d.dirty = true
  return true
end

local function swap(o, d)
  local img = d.img
  if o.full then local s = snapshot(img); restore(img, o.full); o.full = s end
  local px = img.px
  for i, v in pairs(o.pix) do o.pix[i] = px[i]; px[i] = v end
  if o.text then local t = img.text; img.text = o.text; o.text = t end
end

-- Undoes (or with redo = true, redoes) the last operation of `doc`.
-- Returns false if there was nothing to undo/redo.
function M.step(doc, redo)
  local from, to = redo and doc.redo or doc.undo, redo and doc.undo or doc.redo
  local o = table.remove(from)
  if not o then return false end
  swap(o, doc)
  table.insert(to, o)
  doc.dirty = true
  return true
end

return M
