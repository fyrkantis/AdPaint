# adpaint: images for CC: Tweaked advertisement screens

```
adpaint.lua        image editor: command line (help/setup/convert), then lib/editor
adview.lua         shows .adi files on numbered monitors and/or the terminal (slideshows,
                   multi-image ads spread over several monitors)

lib/adimg.lua      .adi file format: load/save/compose/draw (all a player needs)
lib/convert.lua    PNG/JPEG/BMP -> .adi (resample, palette, 2-colour quantise, dither)
lib/png.lua  lib/inflate.lua  lib/jpeg.lua  lib/bmp.lua   decoders, pure Lua
lib/paint.lua      drawing on images without any UI: brush, fill, line, 2-colour cell
                   rule, canvas resize, scaling, text box geometry
lib/history.lua    undo/redo for any document holding an adimg image
lib/ui.lua         terminal UI toolkit: palette-proof colours, button rows, prompt,
                   multiple choice, anchor picker, message (mouse and touch)
lib/cli.lua        shell helpers: completion, "setup", yielding during long work

lib/editor/        the editor, split by concern; each module adds its functions to
                   one shared state table (see app.lua for the order):
  app.lua          display set-up and main loop
  state.lua        tabs/documents, tool settings, colours, undo glue
  view.lua         zoom, panning, coordinates, drawing the canvas
  text.lua         editing text boxes
  chrome.lua       tab bar, tool settings, palette row, tool bar, menu, draw()
  dialogs.lua      size/scale, colour editor, special characters, help
  files.lua        open, import, save, close, quit, dropped files
  commands.lua     menu entries and keyboard shortcuts
  input.lua        mouse/touch/keys and event dispatch

build.py           bundles each program + the modules it uses into dist/ (release files)
tools/luamin.py    Lua minifier used by build.py --minify
```

## Install
Download `adpaint.lua` (and `adview.lua`) from the latest
[release](https://github.com/fyrkantis/adpaint/releases): each is a single file with the
libraries bundled in. Drag them onto the computer while it is running `import`.
Alternatively keep the source layout (`adpaint.lua` next to a `lib/` folder).

To make the bundles yourself, run `python3 build.py`; they are written to `dist/`
(which is not committed). Modules are found automatically (every `"lib.…"` string that names
a file in `lib/`), so new modules need no build changes.

`python3 build.py --minify` also writes minified bundles to `dist/min/` (about half the size:
comments and whitespace removed, local variables renamed to short names; globals, table fields
and strings are untouched, so they behave exactly like the normal bundles). Use the normal
bundles when you want readable error messages.

## Command line
```
adpaint [file ...]                 open .adi files in tabs (PNG/JPEG/BMP are imported)
adpaint -m <side> [-s <scale>] ... paint on an advanced monitor
adpaint convert <image> [out.adi] [-w <cells>] [--height <cells>] [-c <2-16>]
                [-p optimised|default] [--no-dither] [--mode bars|fill|stretch] [--force]
adpaint setup                      enable filename completion at every boot
adpaint help
```
`convert` turns an image into an .adi without opening the editor (by default it fits the
terminal, uses 16 colours, an optimised palette and dithering (`--no-dither` keeps logos and
pixel art crisp), uses white bars (`--mode bars`) when both
sizes are given, and writes next to the input).
Tab completion for subcommands, options, files and monitor names is active after adpaint has
run once; `adpaint setup` adds one line to your startup so it's there after reboots too.

## Viewer (adview)
```
adview <file|folder> ... [-m <name>[=<n>],...] [-a] [-n] [--numbers 1,2,3,...] [--identify]
                         [--mode compromise|bars|fill] [-t <seconds>] [-o random|name]
adview setup | help
```
* **Displays** (found once, at start-up; default: the terminal): `-m <name>` adds a monitor
  (`term` = the terminal), repeat it or separate names with commas. `-a` / `--adjacent` adds every
  monitor touching the computer, `-n` / `--network` every monitor on wired modems (sorted by name,
  so `monitor_2` comes before `monitor_10`). A display that is unplugged later is skipped.
* **Numbers**: displays are numbered 1, 2, 3... in the order `-m`, adjacent, network. Give a
  number with `-m top=2`, or number all of them in that order with `--numbers 1,2,3,1,2,3`
  (numbers given with `-m` win). A display without one gets the next number after the highest
  so far. Displays may share a number. `--identify` shows each display's number and name on
  it until a key is pressed, to check the set-up.
* **Ads**: every file given, and in every folder given each `.adi` file and each **subfolder**
  (a multi-image ad). A subfolder's images are sorted by name: image 1 goes to display(s) 1,
  image 2 to display(s) 2, and so on, starting over when there are more displays than images.
  A single image ad shows on every display. Example for a platform with two rows of three
  monitors that can't be seen at the same time:
  `adview ads -a -n --numbers 1,2,3,1,2,3`.
* Ads change every `-t` seconds (default 10), in random order (default, no repeats back to
  back) or by name. Right after each delay the folders are looked at again, so ads can be added,
  changed or removed by other programs while adview runs; unreadable files are skipped. With
  nothing to show, every display says "No image". Ctrl+T stops (Q too, on the terminal).
* Text scale per monitor: **bars** uses the biggest scale at which the whole image fits (bars in
  the image's edge colour around it), **fill** the smallest scale at which the image covers the
  monitor (cropped, centred), and **compromise** (default) whichever scale gives the least bars +
  cropping, with cropping counting double.
* A single image file just stays on the monitors after adview exits (on the terminal, a key
  closes it). Put the command in the computer's startup to run an ad board unattended.
* Tab completion for files, options, modes and monitors, like adpaint (`adview setup` makes it
  survive reboots). The old `adview <file> <monitor side>` form still works.

## Editor
* New canvases are 18x24 cells by default.
* Layout, top to bottom: tabs, canvas, a **settings bar** for the current tool, the palette, and
  the tool bar. Tools show as icon + name, or just icons on narrow screens (pocket computers).
* Tabs: the top row. `=` opens the menu, `×` closes a tab, `+` adds a blank canvas.
  The two arrows at the top right are undo and redo (also Ctrl+Z / Ctrl+Y).
  Opening a PNG/JPEG/BMP imports it. Dragging image files onto the window imports them too.
* Left click paints with the **L** colour and right click with **R**; pick both in the palette row.
  Each tab remembers its own L/R; a new tab starts with the darkest and brightest colour
  (black / white with the default palette).
* Tools: **Brush** (Size and Dither 1..8, 8 = solid, in the settings bar. With dithering,
  brushes bigger than 2 are soft: dense in the middle, fading towards the rim),
  **Fill** (always solid), **Text**, **Pick**, **Pan** (settings bar arrows scroll the view).
* **Zoom** (`Z`) toggles between the real teletext view and a zoomed view where each cell is
  6x6 characters (3x2 per pixel, so pixels look square). At 1x the mouse can only aim at whole
  cells, so the brush paints whole cells there.
* The size at the bottom right is a button: change the **canvas** size (crop/extend) or
  **scale the image** (text boxes move along). Resizing the canvas asks which corner, side or
  the centre to keep the image at (tap a square twice, or use the arrows and Enter). Scaling
  always gives exactly the size you enter; if that changes the aspect ratio you choose **Bars**
  (keep the ratio, bars in the R colour), **Fill** (keep the ratio, crop the overflow) or
  **Stretch**, and for Bars/Fill an anchor (centre by default).
* Every prompt and question on the bottom row has touch buttons (OK/Cancel, Save/Discard/Cancel...),
  so nothing gets stuck on a touch-only monitor. File prompts suggest completions (greyed out):
  Tab, Right or tapping the field accepts, Up/Down cycles.
* Panning: middle-drag, the arrow keys (hold Shift for bigger steps), the scroll wheel
  (hold Shift to scroll sideways), or the Pan tool.
* Text tool: click to add a box or select one, type to edit it (Enter adds a line), drag or use
  the settings bar's arrows to move it. While a box is selected, L/R in the palette set the text
  and background colour, "No bg" makes the background transparent, and **Chars** opens a grid of
  special characters the keyboard can't type (the CC font's symbols); tap one to insert it. When zoomed in, text boxes get a thin frame (yellow when selected)
  so you can see how the letters line up with the image. `H` / `Txt` hides the text layer; the pixels under it are still there.
* Shortcuts: Ctrl+N/O/S/W/Q/Z/Y/E, Tab next tab, B F T I P tools, `[ ]` size, `, .` dither.
  Ctrl+E (or just E) edits the L colour (also in the menu): separate R, G and B values with `<<` `<` `>` `>>`
  buttons (steps of 16 / 1), tap a value to type it, or `Hex...` for a hex code. Keyboard:
  Up/Down pick a channel, Left/Right step (Shift: 16), digits type a value. Every change is
  previewed live; Cancel restores the colour.
* **Touch monitors** (`-m`, taps only): the palette row gets a "Sets L / Sets R" toggle that
  decides which colour a tap picks (also for Pick), the Pan tool scrolls the tapped spot to the
  middle, and text boxes move with the arrows. The text scale comes from `-s <scale>`, else the
  setting `adpaint.text_scale` (default 0.5); "Text scale..." in the menu changes it and saves it
  as that setting (or run `set adpaint.text_scale 1` in the shell). A scale so big that the
  tool settings (Size / Dither) would be cut off is lowered to the largest that fits, also when
  the monitor is made smaller.
* **Help** (in the menu) scrolls: More / Space move a third of a screen, Up/Down a line, the
  scroll wheel and Page Up/Down work too. It closes with Close, Enter, Q or Backspace.
* When a paint would give a cell a third colour, the cell keeps the new colour plus its most
  common other colour, and any remaining pixels snap to whichever of those two is nearer.

## Import
Drag image files from your computer straight onto the adpaint window (no need for `import`),
use Import image in the menu, open them from the command line, or use `adpaint convert`.
Files dropped while a prompt is open are imported once it closes. CC: Tweaked limits how big a
dropped file can be (server config `upload_max_size`), so very large photos may need shrinking first.

You choose the size in cells (a cell is 2x3 pixels; if it changes the aspect ratio you get the
same Bars / Fill / Stretch choice as when scaling, with bars in the R colour), **dithering**
(palette PNGs offer "None" first), an **optimised** palette (stored in the file and applied to the
monitor) or the **default** CC palette, and how many **colours** (2-16) the image may use.

* Images with up to 4096 colours (logos, maps, pixel art) keep their **exact colours**. With more
  colours than allowed, they are picked by "pixel count x distance to the colours already
  chosen", so small but distinct colours (text, lines) survive. Without dithering, every shrunk
  pixel takes one real colour of its area (favouring thin details over the background), so the
  result stays crisp; with dithering, pixels are averaged and the exact colours dithered.
* Photos (more colours) get a fitted palette: a median cut that always splits the colour group
  with the largest error (so a big flat background can't use up the palette), plus k-means.

With fewer colours, the spare palette slots stay free for drawing on top later (with an optimised
palette they are filled with default colours that differ most from the image's). Transparent
areas are composited over the R colour.

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
