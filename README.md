# adpaint: images for CC: Tweaked advertisement screens

```
adpaint.lua        image editor (advanced computer, or -m <side> for a monitor)
adview.lua         shows an .adi on a monitor (picks the largest text scale that fits)
lib/adimg.lua      .adi file format: load/save/compose/draw (all a player needs)
lib/convert.lua    PNG/JPEG/BMP -> .adi (resample, palette, 2-colour quantise, dither)
lib/png.lua  lib/inflate.lua  lib/jpeg.lua  lib/bmp.lua   decoders, pure Lua
build.py           bundles each program + its libs into dist/ (release files)
```

## Install
Download `adpaint.lua` (and `adview.lua`) from the latest
[release](https://github.com/fyrkantis/adpaint/releases): each is a single file with the
libraries bundled in. Drag them onto the computer while it is running `import`.
Alternatively keep the source layout (`adpaint.lua` next to a `lib/` folder).

To make the bundles yourself, run `python3 build.py`; they are written to `dist/`
(which is not committed).

## Command line
```
adpaint [file ...]                 open .adi files in tabs (PNG/JPEG/BMP are imported)
adpaint -m <side> [-s <scale>] ... paint on an advanced monitor
adpaint convert <image> [out.adi] [-w <cells>] [--height <cells>] [-c <2-16>]
                [-p optimised|default] [--no-dither] [--force]
adpaint setup                      enable filename completion at every boot
adpaint help
```
`convert` turns an image into an .adi without opening the editor (by default it fits the
terminal, uses 16 colours, an optimised palette and dithering, and writes next to the input).
Tab completion for subcommands, options, files and monitor names is active after adpaint has
run once; `adpaint setup` adds one line to your startup so it's there after reboots too.

## Editor
* New canvases are 18x24 cells by default.
* Tabs: the top row. `=` opens the menu, `x` closes a tab, `+` adds a blank canvas.
  The two arrows at the top right are undo and redo (also Ctrl+Z / Ctrl+Y).
  Opening a PNG/JPEG/BMP imports it. Dragging image files onto the window imports them too.
* Left click paints with the **L** colour and right click with **R**; pick both in the palette row.
  Each tab remembers its own L/R; a new tab starts with the darkest and brightest colour
  (black / white with the default palette).
* Tools: **Brush** (size `S-+` and dither `D-+` 1..8, 8 = solid; only shown for the brush.
  With dithering, brushes bigger than 2 are soft: dense in the middle, fading towards the rim),
  **Fill** (always solid), **Text**, **Pick**, **Pan**.
* **Zoom** (`Z`) toggles between the real teletext view and a zoomed view where each cell is
  6x6 characters (3x2 per pixel, so pixels look square). At 1x the mouse can only aim at whole
  cells, so the brush paints whole cells there.
* The size at the bottom right is a button: change the **canvas** size (crop/extend) or
  **scale the image** (text boxes move along). Resizing the canvas asks which corner, side or
  the centre to keep the image at (tap a square twice, or use the arrows and Enter). Scaling asks
  whether the canvas should fit the new size or keep its size, with the image placed at an anchor.
* Every prompt and question on the bottom row has touch buttons (OK/Cancel, Save/Discard/Cancel...),
  so nothing gets stuck on a touch-only monitor. File prompts suggest completions (greyed out):
  Tab, Right or tapping the field accepts, Up/Down cycles.
* Panning: middle-drag, the arrow keys (hold Shift for bigger steps), the scroll wheel
  (hold Shift to scroll sideways), or the Pan tool.
* Text tool: click to add a box or select one, type to edit it (Enter adds a line), drag to move it.
  While a box is selected, L/R in the palette set the text and background colour, and "No bg" makes
  the background transparent. When zoomed in, text boxes get a thin frame (yellow when selected)
  so you can see how the letters line up with the image. `H` / `Txt` hides the text layer; the pixels under it are still there.
* Shortcuts: Ctrl+N/O/S/W/Q/Z/Y, Tab next tab, B F T I P tools, `[ ]` size, `, .` dither.
* When a paint would give a cell a third colour, the cell keeps the new colour plus its most
  common other colour, and any remaining pixels snap to whichever of those two is nearer.

## Import
Drag image files from your computer straight onto the adpaint window (no need for `import`),
use Import image in the menu, open them from the command line, or use `adpaint convert`.
Files dropped while a prompt is open are imported once it closes. CC: Tweaked limits how big a
dropped file can be (server config `upload_max_size`), so very large photos may need shrinking first.

You choose the size in cells (a cell is 2x3 pixels), dithering, an **optimised**
palette (median cut + k-means, stored in the file and applied to the monitor) or the
**default** CC palette, and how many **colours** (2-16) the image may use. With fewer
colours, the spare palette slots stay free for drawing on top later (with an optimised palette
they are filled with default colours that differ most from the image's). Transparent areas are
composited over the R colour.

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
