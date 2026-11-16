#!/usr/bin/env python3
"""Bundles each program and the lib/ modules it uses into one file, so a
single file can be dragged onto a computer (or put on pastebin).

    python3 build.py            dist/adpaint.lua, dist/adview.lua
    python3 build.py --minify   the same, plus minified copies in dist/min/
                                (comments/whitespace removed, locals renamed)

Modules are found automatically: every "lib.something" string in a program
or module that names a file lib/something.lua is bundled.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "tools"))
import luamin  # type: ignore

PROGRAMS = ["adpaint.lua", "adview.lua"]
MODULE_RE = re.compile(r"""["'](lib(?:\.[A-Za-z_][A-Za-z0-9_]*)+)["']""")


def read(path):
    with open(os.path.join(HERE, path)) as f:
        return f.read()


def module_path(name):
    return name.replace(".", "/") + ".lua"


def dependencies(src, found):
    """Adds every module referenced by src (recursively) to `found`, in a
    stable order."""
    for name in MODULE_RE.findall(src):
        if name not in found and os.path.exists(os.path.join(HERE, module_path(name))):
            found.append(name)
            dependencies(read(module_path(name)), found)
    return found


def bundle(prog):
    body = read(prog)
    out = ["-- %s, bundled by build.py from the adpaint sources. Edit the sources, not this.\n" % prog]
    for name in sorted(dependencies(body, [])):
        out.append('package.preload["%s"] = function(...)\n%s\nend\n' % (name, read(module_path(name))))
    out.append(body)
    return "".join(out)


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    print("%-28s %7d bytes" % (os.path.relpath(path, HERE), len(text.encode())))


def main():
    minify = "--minify" in sys.argv[1:]
    for prog in PROGRAMS:
        text = bundle(prog)
        write(os.path.join(HERE, "dist", prog), text)
        if minify:
            header = "-- %s (minified), built from the adpaint sources.\n" % prog
            write(os.path.join(HERE, "dist", "min", prog), header + luamin.minify(text))


if __name__ == "__main__":
    main()
