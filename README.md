# adpaint: images for CC: Tweaked advertisement screens

```
adpaint.lua        image editor (advanced computer, or -m <side> for a monitor)
adview.lua         shows an .adi on a monitor (picks the largest text scale that fits)
lib/adimg.lua      .adi file format: load/save/compose/draw (all a player needs)
lib/convert.lua    PNG/JPEG/BMP -> .adi (resample, palette, 2-colour quantise, dither)
lib/png.lua  lib/inflate.lua  lib/jpeg.lua  lib/bmp.lua   decoders, pure Lua
dist/              single-file bundles of adpaint/adview (made with build.py)
```

## Install
Drag `dist/adpaint.lua` (and `dist/adview.lua`) onto the computer while it is running
`import`, or keep the source layout (`adpaint.lua` next to a `lib/` folder).

## Editor
`adpaint [file ...] [-m <monitor side> [-s <text scale>]]`

* Tabs: the top row. `=` opens the menu, `x` closes a tab, `+` adds a blank canvas.
  Opening a PNG/JPEG/BMP imports it. Dragging image files onto the window imports them too.
* Left click paints with the **L** colour and right click with **R**; pick both in the palette row.
* Tools: **Brush** (size `S-+`, dither `D-+` 1..8, 8 = solid), **Fill**, **Text**, **Pick**, **Pan**.
* Zoom (`Z`): `1x` is the real teletext view, `4x` makes each cell 4x6 characters (2x2 per
  pixel), and `6x` makes each cell 6x6 characters (3x2 per pixel, so pixels look square).
  At 1x the mouse can only aim at whole cells, so the brush paints whole cells there.
* Panning: middle-drag, the arrow keys (hold Shift for bigger steps), the scroll wheel
  (hold Shift to scroll sideways), or the Pan tool.
* Text tool: click to add a box or select one, type to edit it (Enter adds a line), drag to move it.
  While a box is selected, L/R in the palette set the text and background colour, and "No bg" makes
  the background transparent. `H` / `Txt` hides the text layer; the pixels under it are still there.
* Shortcuts: Ctrl+N/O/S/W/Q/Z/Y, Tab next tab, B F T I P tools, `[ ]` size, `, .` dither.
* When a paint would give a cell a third colour, the cell keeps the new colour plus its most
  common other colour, and any remaining pixels snap to whichever of those two is nearer.

## Import
You choose the size in cells (a cell is 2x3 pixels), dithering, and an **optimised**
palette (median cut + k-means, stored in the file and applied to the monitor) or the
**default** CC palette. Transparent areas are composited over the R colour.

* PNG: every colour type, bit depths 1-16, Adam7 interlacing, tRNS transparency.
* JPEG: baseline and progressive, any chroma subsampling, greyscale/YCbCr/RGB/CMYK,
  restart markers, EXIF rotation. When the image is at least 8x bigger than the target, only
  the DC coefficients are decoded, which is much faster and uses far less memory.
* BMP: 1/4/8/16/24/32 bpp, uncompressed or bitfields. RLE is not supported.
* Not supported: WebP, GIF, arithmetic-coded or lossless JPEG.

## .adi format (version 1)
Plain ASCII lines, so files survive pastebin/wget:
```
ADIMG 1
size <w> <h>                      cells
palette <16 x RRGGBB>             optional, colour index 0..15
text <x> <y> <fg> <bg> <n>        1-based cell position, hex colours, bg "-" = transparent
<n lines of text>
data
<pattern row>  w chars, base32 0-v: bits 1,2,4,8,16 = TL,TR,ML,MR,BL pixel uses fg
<fg row>       w hex chars          (the bottom-right pixel is always bg)
<bg row>       w hex chars
...            (3 lines per cell row)
```
To display a row: `term.blit(pattern:gsub(".", B32_TO_CHAR), fg, bg)`, which is what
`adimg.compose` / `adimg.draw` do. Precompose once, and each frame is just blits.
