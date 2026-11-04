#!/usr/bin/env python3
"""Bundles a program and the lib/ modules it needs into one file in dist/,
so a single file can be dragged onto a computer (or pastebin'd)."""
import os, re
HERE = os.path.dirname(os.path.abspath(__file__))
MODS = {
    "adpaint.lua": ["adimg", "inflate", "png", "bmp", "jpeg", "convert"],
    "adview.lua": ["adimg"],
}
os.makedirs(os.path.join(HERE, "dist"), exist_ok=True)
for prog, mods in MODS.items():
    out = ["-- Bundled by build.py from adpaint sources. Do not edit; edit the sources.\n"]
    for m in mods:
        src = open(os.path.join(HERE, "lib", m + ".lua")).read()
        out.append(f'package.preload["lib.{m}"] = function(...)\n{src}\nend\n')
    body = open(os.path.join(HERE, prog)).read()
    out.append(body)
    path = os.path.join(HERE, "dist", prog)
    open(path, "w").write("".join(out))
    print(path, os.path.getsize(path), "bytes")
