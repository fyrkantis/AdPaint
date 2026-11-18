-- features: which optional parts this copy of a program has. The source
-- layout has everything; build.py replaces this module in builds that leave
-- parts out (see TARGETS in build.py), e.g. adpaint-lite without image
-- import. Code that uses an optional part checks its flag first.
return {
  import = true, -- PNG/JPEG/BMP import and "adpaint convert" (lib/convert.lua, lib/formats/decode etc.)
}
