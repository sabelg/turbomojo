"""Responsive layout, first part (P10-16a): what gives way when the terminal or a
window is small.

- Below MIN_COLS x MIN_ROWS the IDE cannot show a menu bar, a window with a few lines
  and a status line; it shows a "terminal too small" screen instead, and keys do
  nothing but quit until the terminal is large enough again (nothing is typed into a
  file nobody can see).
- In a narrow window, what crowds the text goes first: the minimap below
  MINIMAP_MIN_W columns, the breadcrumbs in the title below CRUMBS_MIN_W, the line
  numbers (and the git column) below GUTTER_MIN_W."""
from std.collections import List

comptime MIN_COLS = 40
comptime MIN_ROWS = 10
comptime MINIMAP_MIN_W = 60
comptime CRUMBS_MIN_W = 50
comptime GUTTER_MIN_W = 36


def too_small(w: Int, h: Int) -> Bool:
    return w < MIN_COLS or h < MIN_ROWS


def wrap_words(text: String, width: Int) -> List[String]:
    var out = List[String]()
    var line = String("")
    for word in text.split(" "):
        var wd = String(word)
        if line.byte_length() > 0 and line.byte_length() + 1 + wd.byte_length() > width:
            out.append(line)
            line = wd
        elif line.byte_length() > 0:
            line += " " + wd
        else:
            line = wd
    if line.byte_length() > 0:
        out.append(line)
    return out^


def too_small_lines(w: Int, h: Int, quit_key: String) -> List[String]:
    """What the "terminal too small" screen says, wrapped to `w` columns."""
    var text = (
        "Terminal too small: " + String(w) + "x" + String(h) + ". TurboMojo needs at least "
        + String(MIN_COLS) + "x" + String(MIN_ROWS) + ". Make the window larger or the font smaller."
    )
    if quit_key.byte_length() > 0:
        text += " " + quit_key + " quits."
    return wrap_words(text, max(8, w - 2))
