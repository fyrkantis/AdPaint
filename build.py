#!/usr/bin/env python3
"""Bundles each program and the lib/ modules it uses into one file, so a
single file can be dragged onto a computer (or put on pastebin).

    python3 build.py            every target in TARGETS, into dist/
    python3 build.py --minify   the same, plus minified copies in dist/min/
                                (comments/whitespace removed, locals renamed)

Modules are found automatically: every "lib.something" string in a program
or module that names a file lib/something.lua is bundled.

A target can leave optional parts out: its `exclude` modules are not
bundled (nor what only they need) and get a stub that fails with a clear
message if anything still loads one, and `features` replaces the flags in
lib/features.lua that the programs check before using those parts.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "tools"))
import luamin  # type: ignore

# Image import: the converter and every decoder behind it.
IMPORT_MODULES = ["lib.convert", "lib.formats.decode", "lib.formats.png", "lib.formats.jpeg",
                  "lib.formats.bmp", "lib.formats.inflate"]

TARGETS = [
    {"out": "adpaint.lua", "program": "adpaint.lua"},
    {"out": "adview.lua", "program": "adview.lua"},
    # adpaint without image import (.adi files only): about a third smaller
    {"out": "adpaint-lite.lua", "program": "adpaint.lua",
     "exclude": IMPORT_MODULES, "features": {"import": False}},
]
MODULE_RE = re.compile(r"""["'](lib(?:\.[A-Za-z_][A-Za-z0-9_]*)+)["']""")


def read(path):
    with open(os.path.join(HERE, path)) as f:
        return f.read()


def module_path(name):
    return name.replace(".", "/") + ".lua"


def dependencies(src, found, exclude=()):
    """Adds every module referenced by src (recursively) to `found`, in a
    stable order, without following modules in `exclude`."""
    for name in MODULE_RE.findall(src):
        if name not in found and name not in exclude and os.path.exists(os.path.join(HERE, module_path(name))):
            found.append(name)
            dependencies(read(module_path(name)), found, exclude)
    return found


def lua_value(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    return '"%s"' % str(v).replace("\\", "\\\\").replace('"', '\\"')


def features_module(overrides):
    """lib/features.lua with some flags replaced."""
    src = read(module_path("lib.features"))
    for key, value in overrides.items():
        src, n = re.subn(r"(\b%s\s*=\s*)[^,\n]+" % re.escape(key), lambda m: m.group(1) + lua_value(value), src)
        if n != 1:
            sys.exit("build.py: lib/features.lua has no flag %r" % key)
    return src


def bundle(target):
    prog = target["program"]
    exclude = target.get("exclude", [])
    body = read(prog)
    out = ["-- %s, bundled by build.py from the adpaint sources. Edit the sources, not this.\n" % target["out"]]
    modules = dependencies(body, [], exclude)
    if target.get("features") and "lib.features" not in modules:
        sys.exit("build.py: %s doesn't use lib.features, so its features can't be set" % prog)
    for name in sorted(modules):
        src = read(module_path(name))
        if name == "lib.features" and target.get("features"):
            src = features_module(target["features"])
        out.append('package.preload["%s"] = function(...)\n%s\nend\n' % (name, src))
    for name in exclude:
        out.append('package.preload["%s"] = function() error("%s is not part of %s", 2) end\n'
                   % (name, name, target["out"]))
    out.append(body)
    return "".join(out)


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    print("%-28s %7d bytes" % (os.path.relpath(path, HERE), len(text.encode())))


def main():
    minify = "--minify" in sys.argv[1:]
    for target in TARGETS:
        text = bundle(target)
        write(os.path.join(HERE, "dist", target["out"]), text)
        if minify:
            header = "-- %s (minified), built from the adpaint sources.\n" % target["out"]
            write(os.path.join(HERE, "dist", "min", target["out"]), header + luamin.minify(text))


if __name__ == "__main__":
    main()
