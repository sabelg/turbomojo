"""TurboMojo's version: the one place it is written (the help book, the About box,
`tmide --version`, the What's new notice and the conda package all take it from here)."""

comptime TURBOMOJO_VERSION = "3.0.0"

from std.sys import get_defined_string

# what `mojo --version` said when this TurboMojo was built (the build passes it with
# -D TURBOMOJO_MOJO=...; "" when built without it)
comptime MOJO_BUILT_WITH = get_defined_string["TURBOMOJO_MOJO", ""]()
