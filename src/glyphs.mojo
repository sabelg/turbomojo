"""Glyph tiers (`ui.glyphs`): which characters the IDE's own chrome is drawn with.

- `unicode` (the default): the Turbo look - double and single box drawing, shading,
  arrows, ✓ ✗, braille for the minimap and the spinner. Every one of them is one
  cell wide in a terminal that is not set to draw East Asian "ambiguous" characters
  wide, and none is an emoji or needs a variation selector.
- `ascii`: for fonts or terminals that lack them (the Linux console with a small
  font, some Windows and serial terminals, a CJK terminal that draws box drawing two
  cells wide): every character the screen sends is ASCII except letters of the text
  itself. The mapping is done when the screen is sent (Screen.render), so no part of
  the IDE can slip past it; each symbol becomes one ASCII character, so nothing moves.
  Symbols in your files are shown the same way - the file is not changed.
- `nerd`: `unicode` plus Nerd Font icons (Font Awesome and Devicons code points, in
  the Private Use Area - one cell) for files and folders in the explorer and for the
  notification levels. Only for a terminal whose font is a Nerd Font; elsewhere they
  show as boxes.
"""

comptime GLYPHS_ASCII = 0
comptime GLYPHS_UNICODE = 1
comptime GLYPHS_NERD = 2


def glyphs_of(name: String) -> Int:
    """The tier `ui.glyphs` names (-1 if it names none)."""
    if name == "ascii":
        return GLYPHS_ASCII
    if name == "unicode":
        return GLYPHS_UNICODE
    if name == "nerd":
        return GLYPHS_NERD
    return -1


def braille_dots(cp: Int) -> Int:
    var b = (cp - 0x2800) & 255
    var n = 0
    while b != 0:
        n += b & 1
        b >>= 1
    return n


def ascii_look(cp: Int) -> Int:
    """The ASCII character drawn for `cp` in the ascii tier: a look-alike for the
    symbols, frames and shading; `cp` itself for ASCII and for letters and the like."""
    if cp < 128:
        return cp
    # box drawing
    if cp >= 0x2500 and cp <= 0x257F:
        if cp == 0x2550:
            return 61                                   # = (a double line)
        if (
            cp == 0x2500 or cp == 0x2501 or cp == 0x2504 or cp == 0x2505 or cp == 0x2508
            or cp == 0x2509 or cp == 0x254C or cp == 0x254D or cp == 0x2574 or cp == 0x2576
            or cp == 0x2578 or cp == 0x257A or cp == 0x257C or cp == 0x257E
        ):
            return 45                                   # -
        if (
            cp == 0x2502 or cp == 0x2503 or cp == 0x2506 or cp == 0x2507 or cp == 0x250A
            or cp == 0x250B or cp == 0x254E or cp == 0x254F or cp == 0x2551 or cp == 0x2575
            or cp == 0x2577 or cp == 0x2579 or cp == 0x257B or cp == 0x257D or cp == 0x257F
        ):
            return 124                                  # |
        return 43                                       # + (corners, tees, crossings)
    # blocks and shading
    if cp >= 0x2580 and cp <= 0x259F:
        if cp == 0x2591:
            return 32                                   # the light desktop pattern: blank
        if cp == 0x2592:
            return 58                                   # : (a scroll bar's track)
        if cp == 0x2580 or cp == 0x2584:
            return 32                                   # a button's half-block shadow
        return 35                                       # #
    # braille (the minimap, the spinner): by how many dots
    if cp >= 0x2800 and cp <= 0x28FF:
        var n = braille_dots(cp)
        if n == 0:
            return 32
        if n <= 2:
            return 46                                   # .
        if n <= 5:
            return 58                                   # :
        return 35                                       # #
    # control pictures (control characters in a file)
    if cp >= 0x2400 and cp <= 0x2421:
        return 94                                       # ^
    if cp == 0x2190 or cp == 0x25C4 or cp == 0x25C2 or cp == 0x25C0 or cp == 0x2039 or cp == 0xAB:
        return 60                                       # <
    if cp == 0x2192 or cp == 0x25BA or cp == 0x25B8 or cp == 0x25B6 or cp == 0x203A or cp == 0xBB:
        return 62                                       # >
    if cp == 0x2191 or cp == 0x25B2 or cp == 0x25B4:
        return 94                                       # ^
    if cp == 0x2193 or cp == 0x25BC or cp == 0x25BE:
        return 118                                      # v
    if cp == 0x2195:
        return 124                                      # |
    if cp == 0x2026 or cp == 0x22EF or cp == 0xB7:
        return 46                                       # .
    if cp == 0x2022 or cp == 0x25CF or cp == 0x25C6 or cp == 0x263C or cp == 0x221A or cp == 0x27F3:
        return 42                                       # *
    if cp == 0x25CB or cp == 0x25CC or cp == 0x25C7:
        return 111                                      # o
    if cp == 0x25A0 or cp == 0x25AA or cp == 0x25A4 or cp == 0xA7:
        return 35                                       # #
    if cp == 0x2713 or cp == 0x2714:
        return 43                                       # + (passed, done)
    if cp == 0x2717 or cp == 0x2718 or cp == 0xD7:
        return 120                                      # x (failed)
    if cp == 0x2261:
        return 61                                       # =
    if cp == 0x2013 or cp == 0x2014 or cp == 0x203E or cp == 0x2212:
        return 45                                       # -
    if cp == 0x2018 or cp == 0x2019:
        return 39                                       # '
    if cp == 0x201C or cp == 0x201D:
        return 34                                       # "
    if cp == 0x192:
        return 102                                      # f (a function in the outline)
    if cp == 0xFFFD:
        return 63                                       # ?
    if cp >= 0xE000 and cp <= 0xF8FF:
        return 42                                       # (a Nerd Font icon) *
    return cp


# ------------------------------------------------------------ Nerd Font icons
comptime NF_FOLDER = 0xF07B          # nf-fa-folder
comptime NF_FOLDER_OPEN = 0xF07C     # nf-fa-folder_open
comptime NF_FILE = 0xF15B            # nf-fa-file
comptime NF_FILE_TEXT = 0xF15C       # nf-fa-file_text
comptime NF_FIRE = 0xF06D            # nf-fa-fire: Mojo
comptime NF_PYTHON = 0xE606          # nf-seti-python
comptime NF_MARKDOWN = 0xE609        # nf-seti-markdown
comptime NF_JSON = 0xE60B            # nf-seti-json
comptime NF_CONFIG = 0xE615          # nf-seti-config (TOML, YAML, INI)
comptime NF_SHELL = 0xF120           # nf-fa-terminal
comptime NF_GIT = 0xE702             # nf-dev-git
comptime NF_LOCK = 0xF023            # nf-fa-lock
comptime NF_CHECK = 0xF00C           # nf-fa-check
comptime NF_TIMES = 0xF00D           # nf-fa-times
comptime NF_WARN = 0xF071            # nf-fa-exclamation_triangle
comptime NF_INFO = 0xF05A            # nf-fa-info_circle


def nerd_file_icon(name: String, dir: Bool, open: Bool) -> Int:
    """The icon shown before a file or folder in the explorer (nerd tier)."""
    if dir:
        return NF_FOLDER_OPEN if open else NF_FOLDER
    if name.endswith(".mojo") or name.endswith(".🔥"):
        return NF_FIRE
    if name.endswith(".py") or name.endswith(".pyi"):
        return NF_PYTHON
    if name.endswith(".md"):
        return NF_MARKDOWN
    if name.endswith(".json"):
        return NF_JSON
    if name.endswith(".toml") or name.endswith(".yaml") or name.endswith(".yml") or name.endswith(".ini") or name.endswith(".cfg"):
        return NF_CONFIG
    if name.endswith(".sh") or name.endswith(".bash") or name.endswith(".zsh"):
        return NF_SHELL
    if name.startswith(".git"):
        return NF_GIT
    if name.endswith(".lock"):
        return NF_LOCK
    if name.endswith(".txt") or name.endswith(".rst") or name.endswith(".log"):
        return NF_FILE_TEXT
    return NF_FILE
