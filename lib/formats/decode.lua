-- decode: one entry point for the image file decoders in this folder
-- (PNG, JPEG, BMP), so programs need not know which module reads what.
--
--   local decode = require("lib.formats.decode")
--   local info = decode.info(data)          -- or nil, err
--   decode.rows(data, function(y, r, g, b, a) ... end, yield)
--
-- Rows arrive with 0-based y (not always in order: BMPs are bottom-up) and
-- 1-based arrays of 0..255 values. The arrays are reused between calls.
local M = {}
local byte = string.byte

-- format name -> decoder module. Each has info(data) -> w, h[, extra] and
-- decode(data, onRow, yield[, dcOnly]).
M.DECODERS = {
  png = "lib.formats.png", jpeg = "lib.formats.jpeg", bmp = "lib.formats.bmp",
}

-- Detects a file type from its first bytes: "png", "jpeg", "bmp", "adimg"
-- (our own .adi format), "webp" or "gif" (recognised, not decodable), or nil.
function M.detect(data)
  if data:sub(1, 8) == "\137PNG\r\n\26\n" then return "png" end
  if byte(data, 1) == 0xFF and byte(data, 2) == 0xD8 then return "jpeg" end
  if data:sub(1, 2) == "BM" then return "bmp" end
  if data:sub(1, 6) == "ADIMG " then return "adimg" end
  if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then return "webp" end
  if data:sub(1, 3) == "GIF" then return "gif" end
  return nil
end

-- The decoder module for a format name, or nil if it can't be decoded.
function M.decoder(fmt)
  local name = M.DECODERS[fmt]
  return name and require(name)
end

-- Returns { format, w, h, orientation (EXIF 1..8), indexed (few exact
-- colours, e.g. palette PNGs), dw, dh (size once rotated upright) }, or
-- nil, err.
function M.info(data)
  local fmt = M.detect(data)
  if not fmt then return nil, "unknown file format" end
  local dec = M.decoder(fmt)
  if not dec then return nil, fmt:upper() .. " files are not supported" end
  local w, h, extra = dec.info(data)
  if not w then return nil, h end
  local info = { format = fmt, w = w, h = h, orientation = extra and extra.orientation or 1,
                 indexed = extra and extra.indexed or false }
  if info.orientation >= 5 then info.dw, info.dh = h, w else info.dw, info.dh = w, h end
  return info
end

-- Decodes `data`, calling onRow(y, r, g, b, a) for every row. `yield`
-- (optional) is called now and then during long decodes. dcOnly (JPEG
-- only) decodes at 1/8 size. Returns the size of the rows delivered.
function M.rows(data, onRow, yield, dcOnly)
  local fmt = M.detect(data)
  local dec = fmt and M.decoder(fmt)
  if not dec then error(fmt and (fmt:upper() .. " files are not supported") or "unknown file format", 2) end
  return dec.decode(data, onRow, yield, dcOnly)
end

return M
