-- Small streaming DEFLATE / zlib decoder in pure Lua (Lua 5.1+, no bit ops).
-- inflate.zlib(data, sink, yield) decodes a zlib stream from the string
-- `data`. Decoded bytes are handed to sink(buf, n) in chunks: buf[1..n] are
-- byte values the sink must consume before returning (the buffer is reused).
-- `yield` (optional) is called every so often so long decodes don't trip
-- ComputerCraft's "too long without yielding" watchdog.

local M = {}

local floor, byte = math.floor, string.byte
local POW = {}
for i = 0, 31 do POW[i] = 2 ^ i end

local LEN_BASE = { 3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258 }
local LEN_EXTRA = { 0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0 }
local DIST_BASE = { 1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,
                    4097,6145,8193,12289,16385,24577 }
local DIST_EXTRA = { 0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13 }
local CL_ORDER = { 16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15 }

-- Builds a single-level lookup table indexed by the next `maxlen` input bits
-- (LSB first). Entries are symbol * 16 + code length.
local function buildTable(lengths, n)
  local maxlen, count = 0, {}
  for i = 0, 15 do count[i] = 0 end
  for s = 0, n - 1 do
    local l = lengths[s] or 0
    count[l] = count[l] + 1
    if l > maxlen then maxlen = l end
  end
  local t = { maxlen = maxlen }
  if maxlen == 0 then return t end
  local code, next = 0, {}
  count[0] = 0
  for l = 1, maxlen do
    code = (code + count[l - 1]) * 2
    next[l] = code
  end
  local size = POW[maxlen]
  for s = 0, n - 1 do
    local l = lengths[s] or 0
    if l > 0 then
      local c = next[l]; next[l] = c + 1
      -- reverse the l-bit code
      local r = 0
      for _ = 1, l do r = r * 2 + c % 2; c = floor(c / 2) end
      local v, step = s * 16 + l, POW[l]
      for j = r, size - 1, step do t[j] = v end
    end
  end
  return t
end

local FIXED_LIT, FIXED_DIST
local function fixedTables()
  if not FIXED_LIT then
    local l = {}
    for i = 0, 143 do l[i] = 8 end
    for i = 144, 255 do l[i] = 9 end
    for i = 256, 279 do l[i] = 7 end
    for i = 280, 287 do l[i] = 8 end
    FIXED_LIT = buildTable(l, 288)
    local d = {}
    for i = 0, 29 do d[i] = 5 end
    FIXED_DIST = buildTable(d, 30)
  end
  return FIXED_LIT, FIXED_DIST
end

-- Raw deflate decoder starting at byte position `pos` of `data`.
function M.inflate(data, pos, sink, yield)
  local acc, nbits = 0, 0
  local len = #data
  local WINDOW, FLUSH = 32768, 32768 + 65536
  local out, n = {}, 0
  local work = 0

  local function need(k)
    while nbits < k do
      local b = byte(data, pos) or 0
      pos = pos + 1
      acc = acc + b * POW[nbits]
      nbits = nbits + 8
    end
  end
  local function bits(k)
    if k == 0 then return 0 end
    if nbits < k then need(k) end
    local p = POW[k]
    local v = acc % p
    acc = (acc - v) / p
    nbits = nbits - k
    return v
  end
  local function decode(t)
    local m = t.maxlen
    if nbits < m then need(m) end
    local e = t[acc % POW[m]]
    if not e then error("inflate: bad huffman code") end
    local l = e % 16
    local p = POW[l]
    acc = floor(acc / p)
    nbits = nbits - l
    return (e - l) / 16
  end
  local function flush(final)
    local keep = final and 0 or WINDOW
    local cnt = n - keep
    if cnt <= 0 then return end
    sink(out, cnt)
    for i = 1, keep do out[i] = out[cnt + i] end
    n = keep
    if yield then yield() end
  end

  repeat
    local final = bits(1)
    local btype = bits(2)
    if btype == 0 then
      -- stored block: drop to byte boundary
      bits(nbits % 8)
      local l = bits(16)
      bits(16) -- nlen
      for _ = 1, l do
        n = n + 1; out[n] = bits(8)
        if n >= FLUSH then flush() end
      end
    elseif btype == 1 or btype == 2 then
      local lit, dist
      if btype == 1 then
        lit, dist = fixedTables()
      else
        local hlit, hdist, hclen = bits(5) + 257, bits(5) + 1, bits(4) + 4
        local cl = {}
        for i = 1, 19 do cl[CL_ORDER[i]] = 0 end
        for i = 1, hclen do cl[CL_ORDER[i]] = bits(3) end
        local clt = buildTable(cl, 19)
        local lens, i = {}, 0
        while i < hlit + hdist do
          local sym = decode(clt)
          if sym < 16 then
            lens[i] = sym; i = i + 1
          else
            local rep, val = 0, 0
            if sym == 16 then
              if i == 0 then error("inflate: bad repeat") end
              rep, val = 3 + bits(2), lens[i - 1]
            elseif sym == 17 then rep = 3 + bits(3)
            else rep = 11 + bits(7) end
            for _ = 1, rep do lens[i] = val; i = i + 1 end
          end
        end
        local ll, dl = {}, {}
        for j = 0, hlit - 1 do ll[j] = lens[j] end
        for j = 0, hdist - 1 do dl[j] = lens[hlit + j] end
        lit, dist = buildTable(ll, hlit), buildTable(dl, hdist)
      end
      while true do
        local sym = decode(lit)
        if sym < 256 then
          n = n + 1; out[n] = sym
        elseif sym == 256 then
          break
        else
          sym = sym - 256
          local l = LEN_BASE[sym] + bits(LEN_EXTRA[sym])
          local ds = decode(dist) + 1
          local d = DIST_BASE[ds] + bits(DIST_EXTRA[ds])
          local from = n - d
          if from < 0 then error("inflate: distance too far back") end
          for j = 1, l do out[n + j] = out[from + j] end
          n = n + l
        end
        if n >= FLUSH then
          flush()
        end
        work = work + 1
        if work > 20000 then work = 0; if yield then yield() end end
      end
    else
      error("inflate: bad block type")
    end
    if pos > len + 8 then error("inflate: unexpected end of data") end
  until final == 1
  flush(true)
  return pos
end

function M.zlib(data, sink, yield)
  local cmf, flg = byte(data, 1, 2)
  if not cmf or cmf % 16 ~= 8 or (cmf * 256 + flg) % 31 ~= 0 then
    error("zlib: bad header")
  end
  if floor(flg / 32) % 2 == 1 then error("zlib: preset dictionary not supported") end
  return M.inflate(data, 3, sink, yield)
end

-- Convenience: decode to a string (used for testing / small data).
function M.zlibString(data)
  local parts = {}
  M.zlib(data, function(buf, n)
    local t = {}
    for i = 1, n do t[i] = string.char(buf[i]) end
    parts[#parts + 1] = table.concat(t)
  end)
  return table.concat(parts)
end

return M
