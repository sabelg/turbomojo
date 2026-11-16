"""Live non-invasive Omarchy Linux theme synchronization (`theme = "omarchy"`).

Reads `~/.config/omarchy/current/theme/colors.toml` (or `$OMARCHY_THEME_COLORS`) and maps
Omarchy's semantic color tokens into a full TurboMojo `Palette` without modifying any
system or user files outside TurboMojo. Combined with `Watcher` on the active theme
directory, switching themes via `omarchy theme set <name>` updates TurboMojo live.
"""
from std.collections import List
from palette import Palette, theme
from toml import toml_parse
from config import read_text
from util import env_or, path_exists, dirname, lower_str


def omarchy_colors_path() -> String:
    """Return path to Omarchy's active `colors.toml` (`$OMARCHY_THEME_COLORS` override supported)."""
    var custom = env_or("OMARCHY_THEME_COLORS", "")
    if custom.byte_length() > 0:
        return custom
    var cfg = env_or("XDG_CONFIG_HOME", "")
    if cfg.byte_length() == 0:
        cfg = env_or("HOME", "/tmp") + "/.config"
    return cfg + "/omarchy/current/theme/colors.toml"


def omarchy_watch_dirs() -> List[String]:
    """Directories to register with `Watcher` so `omarchy theme set` triggers a live reload."""
    var out = List[String]()
    var cp = omarchy_colors_path()
    var d1 = dirname(cp)
    var d2 = dirname(d1)
    if d1.byte_length() > 0 and path_exists(d1):
        out.append(d1)
    if d2.byte_length() > 0 and d2 != d1 and path_exists(d2):
        out.append(d2)
    return out^


def _parse_hex_rgb(raw: String, fallback: Int) -> Int:
    var s = String(raw.strip())
    if s.startswith("#"):
        var sub = String(s[byte=1:])
        s = sub
    elif s.startswith("0x") or s.startswith("0X"):
        var sub2 = String(s[byte=2:])
        s = sub2
    if s.byte_length() != 6:
        return fallback
    var val = 0
    for b in s.as_bytes():
        var c = Int(b)
        var d = -1
        if c >= 48 and c <= 57:
            d = c - 48
        elif c >= 97 and c <= 102:
            d = c - 87
        elif c >= 65 and c <= 70:
            d = c - 55
        if d < 0:
            return fallback
        val = (val << 4) | d
    return val


def _luma(rgb: Int) -> Int:
    var r = (rgb >> 16) & 0xFF
    var g = (rgb >> 8) & 0xFF
    var b = rgb & 0xFF
    return (299 * r + 587 * g + 114 * b) // 1000


def parse_omarchy_colors_toml(toml_text: String, label: String = "Omarchy Live") -> Tuple[Bool, Palette]:
    """Parse an Omarchy `colors.toml` document into a complete `Palette`."""
    if String(toml_text.strip()).byte_length() == 0:
        return (False, theme(1))
    var doc = toml_parse(toml_text)
    var bg_str = doc.get_str("background", "")
    var fg_str = doc.get_str("foreground", "")
    if bg_str.byte_length() == 0 and fg_str.byte_length() == 0:
        return (False, theme(1))

    var mode = lower_str(doc.get_str("mode", "dark"))
    var is_light = mode == "light"
    var p = theme(1)
    p.name = label
    p.scanlines = False
    p.monochrome = False

    var def_bg = 0xFAFAF7 if is_light else 0x1E1E2E
    var def_fg = 0x1E1E2E if is_light else 0xCDD6F4
    var bg = _parse_hex_rgb(bg_str, def_bg)
    var fg = _parse_hex_rgb(fg_str, def_fg)
    var dark_bg = _parse_hex_rgb(doc.get_str("dark_background", ""), 0xEFEFE8 if is_light else 0x161622)
    var darker_bg = _parse_hex_rgb(doc.get_str("darker_background", ""), 0xE5E5DC if is_light else 0x101019)
    var lighter_bg = _parse_hex_rgb(doc.get_str("lighter_background", ""), 0xEAEAE2 if is_light else 0x313244)
    var dark_fg = _parse_hex_rgb(doc.get_str("dark_foreground", ""), 0x6C7086)
    var light_fg = _parse_hex_rgb(doc.get_str("light_foreground", ""), fg)
    var bright_fg = _parse_hex_rgb(doc.get_str("bright_foreground", ""), fg)
    var muted = _parse_hex_rgb(doc.get_str("muted", ""), dark_fg)
    var sel_bg = _parse_hex_rgb(doc.get_str("selection", ""), lighter_bg)
    var accent = _parse_hex_rgb(doc.get_str("accent", ""), _parse_hex_rgb(doc.get_str("blue", ""), 0x89B4FA))

    var red = _parse_hex_rgb(doc.get_str("red", ""), 0xF38BA8)
    var yellow = _parse_hex_rgb(doc.get_str("yellow", ""), 0xF9E2AF)
    var orange = _parse_hex_rgb(doc.get_str("orange", ""), yellow)
    var green = _parse_hex_rgb(doc.get_str("green", ""), 0xA6E3A1)
    var cyan = _parse_hex_rgb(doc.get_str("cyan", ""), 0x94E2D5)
    var blue = _parse_hex_rgb(doc.get_str("blue", ""), accent)
    var magenta = _parse_hex_rgb(doc.get_str("magenta", ""), 0xF5C2E7)
    var br_cyan = _parse_hex_rgb(doc.get_str("bright_cyan", ""), cyan)
    var br_blue = _parse_hex_rgb(doc.get_str("bright_blue", ""), blue)
    var br_magenta = _parse_hex_rgb(doc.get_str("bright_magenta", ""), magenta)

    var on_accent = 0x101019 if _luma(accent) >= 140 else 0xFFFFFF
    var on_sel = bright_fg if _luma(sel_bg) < 140 else 0x101019

    p.desk_fg = muted
    p.desk_bg = darker_bg
    p.menu_fg = fg
    p.menu_bg = dark_bg
    p.menu_hot = accent
    p.menu_sel_fg = on_accent
    p.menu_sel_bg = accent
    p.menu_dis = muted
    p.status_fg = fg
    p.status_bg = dark_bg
    p.status_hot = accent
    p.ed_fg = fg
    p.ed_bg = bg
    p.frame_act = accent
    p.frame_inact = muted
    p.title_fg = bright_fg
    p.sel_fg = on_sel
    p.sel_bg = sel_bg
    p.curline_bg = lighter_bg
    p.gutter_fg = dark_fg
    p.gutter_bg = bg
    p.bracket_fg = 0x101019 if _luma(yellow) >= 140 else 0xFFFFFF
    p.bracket_bg = yellow
    p.match_fg = 0x101019 if _luma(orange) >= 140 else 0xFFFFFF
    p.match_bg = orange
    p.doc_fg = fg
    p.doc_bg = dark_bg
    p.doc_bold = bright_fg
    p.doc_code = cyan
    p.doc_dim = dark_fg
    p.diag_err = red
    p.diag_warn = yellow
    p.diag_note = cyan
    p.ruler_bg = lighter_bg
    p.word_bg = lighter_bg
    p.icon_fg = accent
    p.scroll_fg = muted
    p.scroll_bg = dark_bg

    p.msg_fg = fg
    p.msg_bg = dark_bg
    p.msg_err = red
    p.msg_warn = yellow
    p.msg_note = cyan
    p.msg_ok = green
    p.git_add = green
    p.git_mod = yellow
    p.git_del = red
    p.msg_sel_fg = on_sel
    p.msg_sel_bg = sel_bg
    p.msg_frame = accent

    p.dlg_fg = fg
    p.dlg_bg = dark_bg
    p.dlg_frame = accent
    p.dlg_title = bright_fg
    p.dlg_hot = yellow
    p.in_fg = bright_fg
    p.in_bg = bg
    p.btn_fg = on_accent
    p.btn_bg = accent
    p.btn_focus_fg = on_accent
    p.btn_hot = yellow
    p.btn_shadow = darker_bg
    p.list_fg = fg
    p.list_bg = bg
    p.list_sel_fg = on_sel
    p.list_sel_bg = sel_bg
    p.shadow_fg = muted
    p.shadow_bg = darker_bg

    # 14 syntax slots: text, keyword, type, comment, string, number, decorator,
    # symbol, builtin, self, def, param, property, namespace
    var syn = List[Int]()
    syn.append(fg)          # 0 text
    syn.append(magenta)     # 1 keyword
    syn.append(cyan)        # 2 type
    syn.append(dark_fg)     # 3 comment
    syn.append(green)       # 4 string
    syn.append(orange)      # 5 number
    syn.append(yellow)      # 6 decorator
    syn.append(light_fg)    # 7 symbol
    syn.append(br_cyan)     # 8 builtin
    syn.append(red)         # 9 self
    syn.append(blue)        # 10 def
    syn.append(br_magenta)  # 11 param
    syn.append(br_blue)     # 12 property
    syn.append(cyan)        # 13 namespace
    p.syn = syn^
    return (True, p^)


def load_omarchy_palette(custom_path: String = "") -> Tuple[Bool, Palette]:
    """Load the active Omarchy theme palette from disk (`custom_path` or `omarchy_colors_path()`)."""
    var p = custom_path if custom_path.byte_length() > 0 else omarchy_colors_path()
    if not path_exists(p):
        return (False, theme(1))
    return parse_omarchy_colors_toml(read_text(p), "Omarchy Live")
