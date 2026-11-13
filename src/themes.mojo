"""Colour themes as TOML files: the built-in ones beside Turbo Classic, Midnight Neon and
Amber CRT (palette.mojo), and the user's own in $XDG_CONFIG_HOME/turbomojo/themes/.

A theme file:

    name = "Paper Light"        # shown in Options > Theme
    base = "classic"            # optional: start from this theme's colours
    dark = false                # for ui.theme = "auto": which kind of terminal it suits
    scanlines = false           # every other row a little darker (ui.scanlines overrides)
    monochrome = false          # one hue by design (the colour-vision check then skips it)
    [colors]
    ed_bg = "#FAFAF7"           # any palette field (see palette_keys), as #RRGGBB
    [syntax]
    keyword = "#7A3E9D"         # text keyword type comment string number decorator
                                # symbol builtin self def param property namespace

    [roles]                     # optional: a colour for each colour playing a part
    surface = "#FAFAF7"         # (role_keys: surface panel text text_muted ...)
    [colors256]                 # optional: as designed for 256 colours ("256:N" or #RRGGBB)
    menu_hot = "256:124"
    [colors16]                  # ... and for 16 ("ansi:N"); [syntax256], [syntax16] too
    cursor = "ansi:4"

Without the last sections a 256- or 16-colour terminal gets the nearest colours.
Unknown keys and bad colours are reported (and skipped), so a theme with a typo still
loads.
"""
from std.collections import List
from palette import Palette, theme, THEME_COUNT, ansi, COLOR_DEFAULT
from toml import TomlDoc, toml_parse, T_STR
from caps import COLOR_256, COLOR_16
from util import read_file, bytes_to_str, list_dir, path_exists


def palette_keys() -> List[String]:
    var out = List[String]()
    for k in ["desk_fg", "desk_bg", "menu_fg", "menu_bg", "menu_hot", "menu_sel_fg", "menu_sel_bg", "menu_dis", "status_fg", "status_bg", "status_hot", "ed_fg", "ed_bg", "frame_act", "frame_inact", "title_fg", "sel_fg", "sel_bg", "curline_bg", "gutter_fg", "gutter_bg", "bracket_fg", "bracket_bg", "match_fg", "match_bg", "doc_fg", "doc_bg", "doc_bold", "doc_code", "doc_dim", "diag_err", "diag_warn", "diag_note", "ruler_bg", "word_bg", "icon_fg", "scroll_fg", "scroll_bg", "msg_fg", "msg_bg", "msg_err", "msg_warn", "msg_note", "msg_ok", "git_add", "git_mod", "git_del", "msg_sel_fg", "msg_sel_bg", "msg_frame", "dlg_fg", "dlg_bg", "dlg_frame", "dlg_title", "dlg_hot", "in_fg", "in_bg", "btn_fg", "btn_bg", "btn_focus_fg", "btn_hot", "btn_shadow", "list_fg", "list_bg", "list_sel_fg", "list_sel_bg", "shadow_fg", "shadow_bg"]:
        out.append(String(k))
    return out^


def syntax_keys() -> List[String]:
    var out = List[String]()
    for k in ["text", "keyword", "type", "comment", "string", "number", "decorator", "symbol", "builtin", "self", "def", "param", "property", "namespace"]:
        out.append(String(k))
    return out^


comptime ROLE_NAMES = "surface panel text text_muted text_disabled border border_blurred cursor diag_error diag_warn"


def role_keys() -> List[String]:
    """The semantic colour roles a theme can set in [roles] (and in [colors256] and
    [colors16]); each stands for the palette colours that play that part."""
    var out = List[String]()
    for k in ROLE_NAMES.split(" "):
        out.append(String(k))
    return out^


def role_fields(role: String) -> List[String]:
    """The palette colours a role sets, the first being the one `role_color` reads
    ([] for no such role). cursor_blurred has none: an unfocused window shows its
    cursor and selection as the focused ones, muted (contrast.dimmed)."""
    var f: List[String]
    if role == "surface":
        f = ["ed_bg", "gutter_bg", "doc_bg", "msg_bg", "list_bg"]
    elif role == "panel":
        f = ["dlg_bg", "menu_bg", "status_bg"]
    elif role == "text":
        f = ["ed_fg", "doc_fg", "msg_fg", "list_fg", "dlg_fg", "menu_fg", "status_fg"]
    elif role == "text_muted":
        f = ["gutter_fg", "doc_dim", "scroll_fg"]
    elif role == "text_disabled":
        f = ["menu_dis"]
    elif role == "border":
        f = ["frame_act", "dlg_frame", "msg_frame"]
    elif role == "border_blurred":
        f = ["frame_inact"]
    elif role == "cursor":
        f = ["menu_sel_bg", "list_sel_bg", "msg_sel_bg"]
    elif role == "diag_error":
        f = ["diag_err", "msg_err"]
    elif role == "diag_warn":
        f = ["diag_warn", "msg_warn"]
    else:
        f = List[String]()
    return f^


def role_color(p: Palette, role: String) -> Int:
    """A role's colour in palette p (-1 for no such role)."""
    var f = role_fields(role)
    if len(f) == 0:
        return -1
    return palette_get(p, f[0])


def set_key(mut p: Palette, key: String, v: Int) -> Bool:
    """Set a palette colour or, for a role, all of its colours; False if `key` is
    neither."""
    var f = role_fields(key)
    if len(f) > 0:
        for k in f:
            _ = palette_set(p, k, v)
        return True
    return palette_set(p, key, v)


def palette_set(mut p: Palette, key: String, v: Int) -> Bool:
    """Set the colour `key` (a palette field name); False if there is no such field."""
    if key == "desk_fg":
        p.desk_fg = v
        return True
    if key == "desk_bg":
        p.desk_bg = v
        return True
    if key == "menu_fg":
        p.menu_fg = v
        return True
    if key == "menu_bg":
        p.menu_bg = v
        return True
    if key == "menu_hot":
        p.menu_hot = v
        return True
    if key == "menu_sel_fg":
        p.menu_sel_fg = v
        return True
    if key == "menu_sel_bg":
        p.menu_sel_bg = v
        return True
    if key == "menu_dis":
        p.menu_dis = v
        return True
    if key == "status_fg":
        p.status_fg = v
        return True
    if key == "status_bg":
        p.status_bg = v
        return True
    if key == "status_hot":
        p.status_hot = v
        return True
    if key == "ed_fg":
        p.ed_fg = v
        return True
    if key == "ed_bg":
        p.ed_bg = v
        return True
    if key == "frame_act":
        p.frame_act = v
        return True
    if key == "frame_inact":
        p.frame_inact = v
        return True
    if key == "title_fg":
        p.title_fg = v
        return True
    if key == "sel_fg":
        p.sel_fg = v
        return True
    if key == "sel_bg":
        p.sel_bg = v
        return True
    if key == "curline_bg":
        p.curline_bg = v
        return True
    if key == "gutter_fg":
        p.gutter_fg = v
        return True
    if key == "gutter_bg":
        p.gutter_bg = v
        return True
    if key == "bracket_fg":
        p.bracket_fg = v
        return True
    if key == "bracket_bg":
        p.bracket_bg = v
        return True
    if key == "match_fg":
        p.match_fg = v
        return True
    if key == "match_bg":
        p.match_bg = v
        return True
    if key == "doc_fg":
        p.doc_fg = v
        return True
    if key == "doc_bg":
        p.doc_bg = v
        return True
    if key == "doc_bold":
        p.doc_bold = v
        return True
    if key == "doc_code":
        p.doc_code = v
        return True
    if key == "doc_dim":
        p.doc_dim = v
        return True
    if key == "diag_err":
        p.diag_err = v
        return True
    if key == "diag_warn":
        p.diag_warn = v
        return True
    if key == "diag_note":
        p.diag_note = v
        return True
    if key == "ruler_bg":
        p.ruler_bg = v
        return True
    if key == "word_bg":
        p.word_bg = v
        return True
    if key == "icon_fg":
        p.icon_fg = v
        return True
    if key == "scroll_fg":
        p.scroll_fg = v
        return True
    if key == "scroll_bg":
        p.scroll_bg = v
        return True
    if key == "msg_fg":
        p.msg_fg = v
        return True
    if key == "msg_bg":
        p.msg_bg = v
        return True
    if key == "msg_err":
        p.msg_err = v
        return True
    if key == "msg_warn":
        p.msg_warn = v
        return True
    if key == "msg_note":
        p.msg_note = v
        return True
    if key == "msg_ok":
        p.msg_ok = v
        return True
    if key == "git_add":
        p.git_add = v
        return True
    if key == "git_mod":
        p.git_mod = v
        return True
    if key == "git_del":
        p.git_del = v
        return True
    if key == "msg_sel_fg":
        p.msg_sel_fg = v
        return True
    if key == "msg_sel_bg":
        p.msg_sel_bg = v
        return True
    if key == "msg_frame":
        p.msg_frame = v
        return True
    if key == "dlg_fg":
        p.dlg_fg = v
        return True
    if key == "dlg_bg":
        p.dlg_bg = v
        return True
    if key == "dlg_frame":
        p.dlg_frame = v
        return True
    if key == "dlg_title":
        p.dlg_title = v
        return True
    if key == "dlg_hot":
        p.dlg_hot = v
        return True
    if key == "in_fg":
        p.in_fg = v
        return True
    if key == "in_bg":
        p.in_bg = v
        return True
    if key == "btn_fg":
        p.btn_fg = v
        return True
    if key == "btn_bg":
        p.btn_bg = v
        return True
    if key == "btn_focus_fg":
        p.btn_focus_fg = v
        return True
    if key == "btn_hot":
        p.btn_hot = v
        return True
    if key == "btn_shadow":
        p.btn_shadow = v
        return True
    if key == "list_fg":
        p.list_fg = v
        return True
    if key == "list_bg":
        p.list_bg = v
        return True
    if key == "list_sel_fg":
        p.list_sel_fg = v
        return True
    if key == "list_sel_bg":
        p.list_sel_bg = v
        return True
    if key == "shadow_fg":
        p.shadow_fg = v
        return True
    if key == "shadow_bg":
        p.shadow_bg = v
        return True
    return False


def palette_get(p: Palette, key: String) -> Int:
    """The colour `key` (-1 if there is no such field)."""
    if key == "desk_fg":
        return p.desk_fg
    if key == "desk_bg":
        return p.desk_bg
    if key == "menu_fg":
        return p.menu_fg
    if key == "menu_bg":
        return p.menu_bg
    if key == "menu_hot":
        return p.menu_hot
    if key == "menu_sel_fg":
        return p.menu_sel_fg
    if key == "menu_sel_bg":
        return p.menu_sel_bg
    if key == "menu_dis":
        return p.menu_dis
    if key == "status_fg":
        return p.status_fg
    if key == "status_bg":
        return p.status_bg
    if key == "status_hot":
        return p.status_hot
    if key == "ed_fg":
        return p.ed_fg
    if key == "ed_bg":
        return p.ed_bg
    if key == "frame_act":
        return p.frame_act
    if key == "frame_inact":
        return p.frame_inact
    if key == "title_fg":
        return p.title_fg
    if key == "sel_fg":
        return p.sel_fg
    if key == "sel_bg":
        return p.sel_bg
    if key == "curline_bg":
        return p.curline_bg
    if key == "gutter_fg":
        return p.gutter_fg
    if key == "gutter_bg":
        return p.gutter_bg
    if key == "bracket_fg":
        return p.bracket_fg
    if key == "bracket_bg":
        return p.bracket_bg
    if key == "match_fg":
        return p.match_fg
    if key == "match_bg":
        return p.match_bg
    if key == "doc_fg":
        return p.doc_fg
    if key == "doc_bg":
        return p.doc_bg
    if key == "doc_bold":
        return p.doc_bold
    if key == "doc_code":
        return p.doc_code
    if key == "doc_dim":
        return p.doc_dim
    if key == "diag_err":
        return p.diag_err
    if key == "diag_warn":
        return p.diag_warn
    if key == "diag_note":
        return p.diag_note
    if key == "ruler_bg":
        return p.ruler_bg
    if key == "word_bg":
        return p.word_bg
    if key == "icon_fg":
        return p.icon_fg
    if key == "scroll_fg":
        return p.scroll_fg
    if key == "scroll_bg":
        return p.scroll_bg
    if key == "msg_fg":
        return p.msg_fg
    if key == "msg_bg":
        return p.msg_bg
    if key == "msg_err":
        return p.msg_err
    if key == "msg_warn":
        return p.msg_warn
    if key == "msg_note":
        return p.msg_note
    if key == "msg_ok":
        return p.msg_ok
    if key == "git_add":
        return p.git_add
    if key == "git_mod":
        return p.git_mod
    if key == "git_del":
        return p.git_del
    if key == "msg_sel_fg":
        return p.msg_sel_fg
    if key == "msg_sel_bg":
        return p.msg_sel_bg
    if key == "msg_frame":
        return p.msg_frame
    if key == "dlg_fg":
        return p.dlg_fg
    if key == "dlg_bg":
        return p.dlg_bg
    if key == "dlg_frame":
        return p.dlg_frame
    if key == "dlg_title":
        return p.dlg_title
    if key == "dlg_hot":
        return p.dlg_hot
    if key == "in_fg":
        return p.in_fg
    if key == "in_bg":
        return p.in_bg
    if key == "btn_fg":
        return p.btn_fg
    if key == "btn_bg":
        return p.btn_bg
    if key == "btn_focus_fg":
        return p.btn_focus_fg
    if key == "btn_hot":
        return p.btn_hot
    if key == "btn_shadow":
        return p.btn_shadow
    if key == "list_fg":
        return p.list_fg
    if key == "list_bg":
        return p.list_bg
    if key == "list_sel_fg":
        return p.list_sel_fg
    if key == "list_sel_bg":
        return p.list_sel_bg
    if key == "shadow_fg":
        return p.shadow_fg
    if key == "shadow_bg":
        return p.shadow_bg
    return -1


# the shipped theme files (themes/*.toml), built in so that the binary needs no files;
# tests/test_themes.mojo checks that they are the same as the files
comptime TERMINAL_ANSI = "# Terminal ANSI: only your terminal's own 16 colours and its default foreground and\n# background, so its colour scheme, its high-contrast and minimum-contrast settings\n# decide how TurboMojo looks. Colours here are \"ansi:0\" to \"ansi:15\" or \"default\".\nname = \"Terminal ANSI\"\nbase = \"midnight\"\ndark = true\nscanlines = false\n\n[colors]\ndesk_fg = \"ansi:8\"\ndesk_bg = \"default\"\nmenu_fg = \"ansi:0\"\nmenu_bg = \"ansi:7\"\nmenu_hot = \"ansi:4\"\nmenu_sel_fg = \"ansi:15\"\nmenu_sel_bg = \"ansi:4\"\nmenu_dis = \"ansi:8\"\nstatus_fg = \"ansi:0\"\nstatus_bg = \"ansi:7\"\nstatus_hot = \"ansi:4\"\ned_fg = \"default\"\ned_bg = \"default\"\nframe_act = \"ansi:14\"\nframe_inact = \"ansi:8\"\ntitle_fg = \"ansi:15\"\nsel_fg = \"ansi:15\"\nsel_bg = \"ansi:4\"\ncurline_bg = \"default\"\ngutter_fg = \"ansi:8\"\ngutter_bg = \"default\"\nbracket_fg = \"ansi:0\"\nbracket_bg = \"ansi:3\"\nmatch_fg = \"ansi:0\"\nmatch_bg = \"ansi:11\"\ndoc_fg = \"default\"\ndoc_bg = \"default\"\ndoc_bold = \"ansi:15\"\ndoc_code = \"ansi:6\"\ndoc_dim = \"ansi:8\"\ndiag_err = \"ansi:9\"\ndiag_warn = \"ansi:11\"\ndiag_note = \"ansi:12\"\nruler_bg = \"default\"\nword_bg = \"default\"\nicon_fg = \"ansi:14\"\nscroll_fg = \"ansi:8\"\nscroll_bg = \"default\"\nmsg_fg = \"default\"\nmsg_bg = \"default\"\nmsg_err = \"ansi:9\"\nmsg_warn = \"ansi:11\"\nmsg_note = \"ansi:12\"\nmsg_ok = \"ansi:10\"\ngit_add = \"ansi:10\"\ngit_mod = \"ansi:12\"\ngit_del = \"ansi:9\"\nmsg_sel_fg = \"ansi:15\"\nmsg_sel_bg = \"ansi:4\"\nmsg_frame = \"ansi:14\"\ndlg_fg = \"default\"\ndlg_bg = \"default\"\ndlg_frame = \"ansi:14\"\ndlg_title = \"ansi:15\"\ndlg_hot = \"ansi:11\"\nin_fg = \"default\"\nin_bg = \"default\"\nbtn_fg = \"ansi:0\"\nbtn_bg = \"ansi:7\"\nbtn_focus_fg = \"ansi:4\"\nbtn_hot = \"ansi:4\"\nbtn_shadow = \"ansi:8\"\nlist_fg = \"default\"\nlist_bg = \"default\"\nlist_sel_fg = \"ansi:15\"\nlist_sel_bg = \"ansi:4\"\nshadow_fg = \"ansi:8\"\nshadow_bg = \"default\"\n\n[syntax]\ntext = \"default\"\nkeyword = \"ansi:13\"\ntype = \"ansi:6\"\ncomment = \"ansi:8\"\nstring = \"ansi:2\"\nnumber = \"ansi:3\"\ndecorator = \"ansi:5\"\nsymbol = \"default\"\nbuiltin = \"ansi:6\"\nself = \"ansi:5\"\ndef = \"ansi:12\"\nparam = \"default\"\nproperty = \"default\"\nnamespace = \"ansi:6\"\n"
comptime TERMINAL_MONO = "# Terminal Mono: the terminal's default colours only, with black on white (palette 0 on\n# 7) for what must stand out - the selection, the menu bar. TurboMojo uses it when\n# NO_COLOR is set (https://no-color.org) and no theme is chosen in the config file.\n# Problems are told apart by their letters (E W i) and underlines, not by colour.\nname = \"Terminal Mono\"\nbase = \"midnight\"\ndark = true\nscanlines = false\nmonochrome = true\n\n[colors]\ndesk_fg = \"default\"\ndesk_bg = \"default\"\nmenu_fg = \"ansi:0\"\nmenu_bg = \"ansi:7\"\nmenu_hot = \"ansi:0\"\nmenu_sel_fg = \"ansi:0\"\nmenu_sel_bg = \"ansi:7\"\nmenu_dis = \"default\"\nstatus_fg = \"ansi:0\"\nstatus_bg = \"ansi:7\"\nstatus_hot = \"ansi:0\"\ned_fg = \"default\"\ned_bg = \"default\"\nframe_act = \"default\"\nframe_inact = \"default\"\ntitle_fg = \"default\"\nsel_fg = \"ansi:0\"\nsel_bg = \"ansi:7\"\ncurline_bg = \"default\"\ngutter_fg = \"default\"\ngutter_bg = \"default\"\nbracket_fg = \"ansi:0\"\nbracket_bg = \"ansi:7\"\nmatch_fg = \"ansi:0\"\nmatch_bg = \"ansi:7\"\ndoc_fg = \"default\"\ndoc_bg = \"default\"\ndoc_bold = \"default\"\ndoc_code = \"default\"\ndoc_dim = \"default\"\ndiag_err = \"default\"\ndiag_warn = \"default\"\ndiag_note = \"default\"\nruler_bg = \"default\"\nword_bg = \"default\"\nicon_fg = \"default\"\nscroll_fg = \"default\"\nscroll_bg = \"default\"\nmsg_fg = \"default\"\nmsg_bg = \"default\"\nmsg_err = \"default\"\nmsg_warn = \"default\"\nmsg_note = \"default\"\nmsg_ok = \"default\"\ngit_add = \"default\"\ngit_mod = \"default\"\ngit_del = \"default\"\nmsg_sel_fg = \"ansi:0\"\nmsg_sel_bg = \"ansi:7\"\nmsg_frame = \"default\"\ndlg_fg = \"default\"\ndlg_bg = \"default\"\ndlg_frame = \"default\"\ndlg_title = \"default\"\ndlg_hot = \"default\"\nin_fg = \"default\"\nin_bg = \"default\"\nbtn_fg = \"ansi:0\"\nbtn_bg = \"ansi:7\"\nbtn_focus_fg = \"ansi:0\"\nbtn_hot = \"ansi:0\"\nbtn_shadow = \"default\"\nlist_fg = \"default\"\nlist_bg = \"default\"\nlist_sel_fg = \"ansi:0\"\nlist_sel_bg = \"ansi:7\"\nshadow_fg = \"default\"\nshadow_bg = \"default\"\n\n[syntax]\ntext = \"default\"\nkeyword = \"default\"\ntype = \"default\"\ncomment = \"default\"\nstring = \"default\"\nnumber = \"default\"\ndecorator = \"default\"\nsymbol = \"default\"\nbuiltin = \"default\"\nself = \"default\"\ndef = \"default\"\nparam = \"default\"\nproperty = \"default\"\nnamespace = \"default\"\n"
comptime PAPER_LIGHT = "# Paper Light: a light theme for terminals with a light background.\n# Copy this file to ~/.config/turbomojo/themes/ under another name to make your own.\n# Errors raspberry, warnings ochre, success and additions blue: they stay apart with\n# the common kinds of colour blindness (checked in the tests).\nname = \"Paper Light\"\nbase = \"midnight\"\ndark = false\n\n[colors]\ndesk_fg = \"#D8D8D0\"\ndesk_bg = \"#E8E8E2\"\nmenu_fg = \"#2B2B2B\"\nmenu_bg = \"#E0E0DA\"\nmenu_hot = \"#A74600\"\nmenu_sel_fg = \"#FFFFFF\"\nmenu_sel_bg = \"#3A6EA5\"\nmenu_dis = \"#8A8A84\"\nstatus_fg = \"#2B2B2B\"\nstatus_bg = \"#E0E0DA\"\nstatus_hot = \"#A74600\"\ned_fg = \"#1F1F1F\"\ned_bg = \"#FBFBF8\"\nframe_act = \"#3A6EA5\"\nframe_inact = \"#A8A8A0\"\ntitle_fg = \"#1F1F1F\"\nsel_fg = \"#1F1F1F\"\nsel_bg = \"#C9DDF2\"\ncurline_bg = \"#F1F1EC\"\ngutter_fg = \"#8A8A84\"\ngutter_bg = \"#FBFBF8\"\nbracket_fg = \"#1F1F1F\"\nbracket_bg = \"#E2D6A8\"\nmatch_fg = \"#1F1F1F\"\nmatch_bg = \"#F4E3A1\"\ndoc_fg = \"#1F1F1F\"\ndoc_bg = \"#F3F3EE\"\ndoc_bold = \"#000000\"\ndoc_code = \"#7A3E9D\"\ndoc_dim = \"#6E6E68\"\ndiag_err = \"#C00060\"\ndiag_warn = \"#906000\"\ndiag_note = \"#2E6DB4\"\nruler_bg = \"#F0F0EA\"\nword_bg = \"#E8EEF5\"\nicon_fg = \"#3A6EA5\"\nscroll_fg = \"#8A8A84\"\nscroll_bg = \"#ECECE6\"\nmsg_fg = \"#1F1F1F\"\nmsg_bg = \"#F3F3EE\"\nmsg_err = \"#C00060\"\nmsg_warn = \"#906000\"\nmsg_note = \"#2E6DB4\"\nmsg_ok = \"#0070E0\"\ngit_add = \"#0070E0\"\ngit_mod = \"#906000\"\ngit_del = \"#C00060\"\nmsg_sel_fg = \"#FFFFFF\"\nmsg_sel_bg = \"#3A6EA5\"\nmsg_frame = \"#3A6EA5\"\ndlg_fg = \"#1F1F1F\"\ndlg_bg = \"#ECECE6\"\ndlg_frame = \"#3A6EA5\"\ndlg_title = \"#1F1F1F\"\ndlg_hot = \"#A74600\"\nin_fg = \"#1F1F1F\"\nin_bg = \"#FFFFFF\"\nbtn_fg = \"#1F1F1F\"\nbtn_bg = \"#D6D6CF\"\nbtn_focus_fg = \"#1A4F8A\"\nbtn_hot = \"#A74600\"\nbtn_shadow = \"#B8B8B0\"\nlist_fg = \"#1F1F1F\"\nlist_bg = \"#FFFFFF\"\nlist_sel_fg = \"#FFFFFF\"\nlist_sel_bg = \"#3A6EA5\"\nshadow_fg = \"#9A9A94\"\nshadow_bg = \"#C8C8C0\"\n\n[syntax]\ntext = \"#1F1F1F\"\nkeyword = \"#7A3E9D\"\ntype = \"#00708A\"\ncomment = \"#6E6E68\"\nstring = \"#508030\"\nnumber = \"#A74600\"\ndecorator = \"#8A5700\"\nsymbol = \"#4A4A44\"\nbuiltin = \"#00708A\"\nself = \"#B03060\"\ndef = \"#1070E0\"\nparam = \"#5A4FA0\"\nproperty = \"#355E8C\"\nnamespace = \"#00708A\"\n\n# Designed for terminals with 256 or 16 colours (else the nearest colour is used):\n[colors256]\nmenu_hot = \"256:124\"\n\n[colors16]\ncursor = \"ansi:4\"\ngutter_fg = \"ansi:8\"\n\n[syntax16]\ntype = \"ansi:4\"\nbuiltin = \"ansi:4\"\nnamespace = \"ansi:4\"\ndef = \"ansi:12\"\nself = \"ansi:1\"\n\n[syntax256]\nstring = \"256:28\"\n"
comptime HACKER_MATRIX = "# Hacker Matrix: green phosphor like an old CRT, with four bright accents in the same\n# style: blue (types, built-ins, notes), yellow (definitions, numbers, warnings), red\n# (errors, decorators, self) and brown (strings). No scanlines of its own: set\n# scanlines = true here (or under [ui]) for them, or use a terminal's CRT shader.\nname = \"Hacker Matrix\"\nbase = \"amber\"\ndark = true\nscanlines = false\n\n[colors]\ndesk_fg = \"#0B2E13\"\ndesk_bg = \"#000000\"\nmenu_fg = \"#00D838\"\nmenu_bg = \"#031A08\"\nmenu_hot = \"#FFE45C\"\nmenu_sel_fg = \"#000000\"\nmenu_sel_bg = \"#00FF41\"\nmenu_dis = \"#1E8C3A\"\nstatus_fg = \"#00D838\"\nstatus_bg = \"#031A08\"\nstatus_hot = \"#FFE45C\"\ned_fg = \"#00D838\"\ned_bg = \"#031A08\"\nframe_act = \"#00FF41\"\nframe_inact = \"#1E8C3A\"\ntitle_fg = \"#00FF41\"\nsel_fg = \"#000000\"\nsel_bg = \"#00B32C\"\ncurline_bg = \"#06230C\"\ngutter_fg = \"#47AA5E\"\ngutter_bg = \"#031A08\"\nbracket_fg = \"#000000\"\nbracket_bg = \"#FFE45C\"\nmatch_fg = \"#000000\"\nmatch_bg = \"#3FA9F5\"\ndoc_fg = \"#00D838\"\ndoc_bg = \"#031A08\"\ndoc_bold = \"#00FF41\"\ndoc_code = \"#FFE45C\"\ndoc_dim = \"#47AA5E\"\ndiag_err = \"#FF6054\"\ndiag_warn = \"#FFE45C\"\ndiag_note = \"#3FA9F5\"\nruler_bg = \"#05220C\"\nword_bg = \"#0A2A12\"\nicon_fg = \"#00FF41\"\nscroll_fg = \"#00B32C\"\nscroll_bg = \"#041409\"\nmsg_fg = \"#00D838\"\nmsg_bg = \"#031A08\"\nmsg_err = \"#FF6054\"\nmsg_warn = \"#FFE45C\"\nmsg_note = \"#3FA9F5\"\nmsg_ok = \"#00FF41\"\ngit_add = \"#00FF41\"\ngit_mod = \"#3FA9F5\"\ngit_del = \"#FF6054\"\nmsg_sel_fg = \"#000000\"\nmsg_sel_bg = \"#00FF41\"\nmsg_frame = \"#00FF41\"\ndlg_fg = \"#00D838\"\ndlg_bg = \"#031A08\"\ndlg_frame = \"#00FF41\"\ndlg_title = \"#00FF41\"\ndlg_hot = \"#FFE45C\"\nin_fg = \"#00FF41\"\nin_bg = \"#000000\"\nbtn_fg = \"#00D838\"\nbtn_bg = \"#0E4D1F\"\nbtn_focus_fg = \"#FFE45C\"\nbtn_hot = \"#3FA9F5\"\nbtn_shadow = \"#000000\"\nlist_fg = \"#00D838\"\nlist_bg = \"#000000\"\nlist_sel_fg = \"#000000\"\nlist_sel_bg = \"#00FF41\"\nshadow_fg = \"#0B2E13\"\nshadow_bg = \"#000000\"\n\n[syntax]\ntext = \"#00D838\"\nkeyword = \"#00F0A0\"\ntype = \"#3FA9F5\"\ncomment = \"#3E9E4E\"\nstring = \"#C09020\"\nnumber = \"#FFE45C\"\ndecorator = \"#FF6054\"\nsymbol = \"#47AA5E\"\nbuiltin = \"#6CB8FF\"\nself = \"#FF6B5B\"\ndef = \"#FFE45C\"\nparam = \"#B6FFB6\"\nproperty = \"#00D838\"\nnamespace = \"#6CB8FF\"\n\n# Designed for terminals with 256 or 16 colours (else the nearest colour is used):\n[colors256]\nbtn_fg = \"256:46\"\n\n[syntax256]\nstring = \"256:178\"\n\n[colors16]\ngutter_fg = \"ansi:2\"\ndoc_dim = \"ansi:2\"\n\n[syntax16]\nstring = \"ansi:11\"\ntype = \"ansi:14\"\ncomment = \"ansi:2\"\nsymbol = \"ansi:2\"\n"
comptime HIGH_CONTRAST = "# High Contrast: white and bright colours on black, for low vision and bright rooms.\nname = \"High Contrast\"\nbase = \"midnight\"\ndark = true\n\n[colors]\ndesk_fg = \"#303030\"\ndesk_bg = \"#000000\"\nmenu_fg = \"#FFFFFF\"\nmenu_bg = \"#000000\"\nmenu_hot = \"#FFFF00\"\nmenu_sel_fg = \"#000000\"\nmenu_sel_bg = \"#FFFF00\"\nmenu_dis = \"#A0A0A0\"\nstatus_fg = \"#FFFFFF\"\nstatus_bg = \"#000000\"\nstatus_hot = \"#FFFF00\"\ned_fg = \"#FFFFFF\"\ned_bg = \"#000000\"\nframe_act = \"#FFFF00\"\nframe_inact = \"#C0C0C0\"\ntitle_fg = \"#FFFFFF\"\nsel_fg = \"#000000\"\nsel_bg = \"#00FFFF\"\ncurline_bg = \"#1A1A1A\"\ngutter_fg = \"#C0C0C0\"\ngutter_bg = \"#000000\"\nbracket_fg = \"#000000\"\nbracket_bg = \"#FFFF00\"\nmatch_fg = \"#000000\"\nmatch_bg = \"#FF80FF\"\ndoc_fg = \"#FFFFFF\"\ndoc_bg = \"#000000\"\ndoc_bold = \"#FFFF00\"\ndoc_code = \"#00FFFF\"\ndoc_dim = \"#C0C0C0\"\ndiag_err = \"#FF9494\"\ndiag_warn = \"#FFFF00\"\ndiag_note = \"#00FFFF\"\nruler_bg = \"#1A1A1A\"\nword_bg = \"#333333\"\nicon_fg = \"#FFFF00\"\nscroll_fg = \"#FFFFFF\"\nscroll_bg = \"#333333\"\nmsg_fg = \"#FFFFFF\"\nmsg_bg = \"#000000\"\nmsg_err = \"#FF9494\"\nmsg_warn = \"#FFFF00\"\nmsg_note = \"#00FFFF\"\nmsg_ok = \"#80FF80\"\ngit_add = \"#80FF80\"\ngit_mod = \"#FFFF00\"\ngit_del = \"#FF9494\"\nmsg_sel_fg = \"#000000\"\nmsg_sel_bg = \"#FFFF00\"\nmsg_frame = \"#FFFF00\"\ndlg_fg = \"#FFFFFF\"\ndlg_bg = \"#000000\"\ndlg_frame = \"#FFFF00\"\ndlg_title = \"#FFFF00\"\ndlg_hot = \"#00FFFF\"\nin_fg = \"#FFFFFF\"\nin_bg = \"#1A1A1A\"\nbtn_fg = \"#000000\"\nbtn_bg = \"#FFFFFF\"\nbtn_focus_fg = \"#0000C0\"\nbtn_hot = \"#C00000\"\nbtn_shadow = \"#606060\"\nlist_fg = \"#FFFFFF\"\nlist_bg = \"#000000\"\nlist_sel_fg = \"#000000\"\nlist_sel_bg = \"#FFFF00\"\nshadow_fg = \"#808080\"\nshadow_bg = \"#000000\"\n\n[syntax]\ntext = \"#FFFFFF\"\nkeyword = \"#FFFF00\"\ntype = \"#00FFFF\"\ncomment = \"#C0C0C0\"\nstring = \"#80FF80\"\nnumber = \"#FF80FF\"\ndecorator = \"#FFC040\"\nsymbol = \"#FFFFFF\"\nbuiltin = \"#00FFFF\"\nself = \"#FF80FF\"\ndef = \"#FFC040\"\nparam = \"#FFFFFF\"\nproperty = \"#FFFFFF\"\nnamespace = \"#00FFFF\"\n"
comptime CLASSIC_DEPTHS = "base = \"classic\"\ndark = true\n\n[colors256]\nmenu_hot = \"256:52\"\ndoc_dim = \"256:17\"\n\n[colors16]\nmenu_hot = \"ansi:4\"\ndiag_err = \"ansi:13\"\ndoc_dim = \"ansi:4\"\n"
comptime MIDNIGHT_DEPTHS = "base = \"midnight\"\ndark = true\n\n[colors256]\nsel_bg = \"256:24\"\nbtn_bg = \"256:24\"\n\n[colors16]\ncursor = \"ansi:4\"\nmenu_sel_fg = \"ansi:15\"\nlist_sel_fg = \"ansi:15\"\ngutter_fg = \"ansi:7\"\n\n[syntax16]\ndef = \"ansi:14\"\n"
comptime AMBER_DEPTHS = "base = \"amber\"\ndark = true\n\n[colors16]\ntext = \"ansi:11\"\nmenu_fg = \"ansi:0\"\nstatus_fg = \"ansi:0\"\npanel = \"ansi:0\"\nmenu_bg = \"ansi:11\"\nstatus_bg = \"ansi:11\"\nsel_bg = \"ansi:11\"\nmsg_sel_bg = \"ansi:11\"\nbtn_bg = \"ansi:11\"\nmsg_warn = \"ansi:15\"\n\n[syntax16]\ntext = \"ansi:11\"\nsymbol = \"ansi:11\"\nproperty = \"ansi:11\"\n"
comptime OKABE_ITO = "# Okabe-Ito: a dark theme for colour-blind eyes, from the eight colours of Okabe and\n# Ito's \"Color Universal Design\" (2002/2008), lightened where needed to reach the\n# contrast floors on the dark background. Errors are vermillion, warnings yellow,\n# notes sky blue, success bluish green; git additions are sky blue, changes orange,\n# deletions vermillion. The tests simulate protanopia, deuteranopia and tritanopia\n# (Machado, Oliveira and Fernandes 2009) and check that these stay apart.\nname = \"Okabe-Ito\"\nbase = \"midnight\"\ndark = true\nscanlines = false\n\n[colors]\ndesk_fg = \"#1C232B\"\ndesk_bg = \"#0B0E11\"\nmenu_fg = \"#E6E6E6\"\nmenu_bg = \"#1C232B\"\nmenu_hot = \"#F0E442\"\nmenu_sel_fg = \"#000000\"\nmenu_sel_bg = \"#56B4E9\"\nmenu_dis = \"#5E6873\"\nstatus_fg = \"#E6E6E6\"\nstatus_bg = \"#1C232B\"\nstatus_hot = \"#F0E442\"\ned_fg = \"#E6E6E6\"\ned_bg = \"#101418\"\nframe_act = \"#56B4E9\"\nframe_inact = \"#56616C\"\ntitle_fg = \"#FFFFFF\"\nsel_fg = \"#FFFFFF\"\nsel_bg = \"#0060A0\"\ncurline_bg = \"#171D23\"\ngutter_fg = \"#7F8994\"\ngutter_bg = \"#101418\"\nbracket_fg = \"#000000\"\nbracket_bg = \"#F0E442\"\nmatch_fg = \"#000000\"\nmatch_bg = \"#E69F00\"\ndoc_fg = \"#E6E6E6\"\ndoc_bg = \"#101418\"\ndoc_bold = \"#FFFFFF\"\ndoc_code = \"#56B4E9\"\ndoc_dim = \"#7F8994\"\ndiag_err = \"#F07A45\"\ndiag_warn = \"#F0E442\"\ndiag_note = \"#56B4E9\"\nruler_bg = \"#151A1F\"\nword_bg = \"#1E2830\"\nicon_fg = \"#56B4E9\"\nscroll_fg = \"#7F8994\"\nscroll_bg = \"#171D23\"\nmsg_fg = \"#E6E6E6\"\nmsg_bg = \"#101418\"\nmsg_err = \"#F07A45\"\nmsg_warn = \"#F0E442\"\nmsg_note = \"#56B4E9\"\nmsg_ok = \"#2EC08E\"\ngit_add = \"#56B4E9\"\ngit_mod = \"#E69F00\"\ngit_del = \"#F07A45\"\nmsg_sel_fg = \"#FFFFFF\"\nmsg_sel_bg = \"#0060A0\"\nmsg_frame = \"#56B4E9\"\ndlg_fg = \"#E6E6E6\"\ndlg_bg = \"#1C232B\"\ndlg_frame = \"#56B4E9\"\ndlg_title = \"#FFFFFF\"\ndlg_hot = \"#F0E442\"\nin_fg = \"#FFFFFF\"\nin_bg = \"#0B0E11\"\nbtn_fg = \"#000000\"\nbtn_bg = \"#B8C2CC\"\nbtn_focus_fg = \"#003F6B\"\nbtn_hot = \"#A04000\"\nbtn_shadow = \"#0B0E11\"\nlist_fg = \"#E6E6E6\"\nlist_bg = \"#101418\"\nlist_sel_fg = \"#000000\"\nlist_sel_bg = \"#56B4E9\"\nshadow_fg = \"#3A424A\"\nshadow_bg = \"#000000\"\n\n[syntax]\ntext = \"#E6E6E6\"\nkeyword = \"#56B4E9\"\ntype = \"#F0E442\"\ncomment = \"#76808A\"\nstring = \"#3CC79A\"\nnumber = \"#E69F00\"\ndecorator = \"#E69F00\"\nsymbol = \"#C8CDD2\"\nbuiltin = \"#56B4E9\"\nself = \"#E192C0\"\ndef = \"#E192C0\"\nparam = \"#E6E6E6\"\nproperty = \"#E6E6E6\"\nnamespace = \"#F0E442\"\n\n# Designed for terminals with 256 or 16 colours (else the nearest colour is used):\n[colors16]\nsel_bg = \"ansi:4\"\nmsg_sel_bg = \"ansi:4\"\n\n[syntax16]\nnumber = \"ansi:11\"\ndecorator = \"ansi:11\"\n"


def parse_color(s: String) -> Int:
    """#RRGGBB or #RGB -> 0xRRGGBB; "ansi:N" (0 to 15) -> the terminal's palette slot N;
    "256:N" (0 to 255) -> xterm-256 index N;
    "default" -> the terminal's default colour (-1 if it is none of these)."""
    var t = String(s.strip())
    if t == "default":
        return COLOR_DEFAULT
    if t.startswith("ansi:"):
        try:
            var n = atol(String(t[byte=5:]))
            return ansi(n) if n >= 0 and n <= 15 else -1
        except:
            return -1
    if t.startswith("256:"):
        try:
            var n = atol(String(t[byte=4:]))
            return ansi(n) if n >= 0 and n <= 255 else -1
        except:
            return -1
    if not t.startswith("#"):
        return -1
    var digits = List[Int]()
    for b in t.as_bytes()[1:]:
        var c = Int(b)
        if c >= 48 and c <= 57:
            digits.append(c - 48)
        elif c >= 97 and c <= 102:
            digits.append(c - 87)
        elif c >= 65 and c <= 70:
            digits.append(c - 55)
        else:
            return -1
    if len(digits) == 6:
        var v = 0
        for d in digits:
            v = v * 16 + d
        return v
    if len(digits) == 3:
        return (digits[0] * 17) << 16 | (digits[1] * 17) << 8 | (digits[2] * 17)
    return -1


struct ThemeSet(Copyable, Movable):
    """Every theme there is: ids ("classic", "light", a file's name), palettes - for
    truecolor, and as designed for 256 and for 16 colours - and whether each suits a
    dark terminal."""
    var ids: List[String]
    var pals: List[Palette]
    var pals256: List[Palette]      # with the theme's [colors256]
    var pals16: List[Palette]       # with the theme's [colors16]
    var dark: List[Bool]
    var problems: List[String]      # what was wrong in theme files ("file: line")

    def __init__(out self):
        self.ids = List[String]()
        self.pals = List[Palette]()
        self.pals256 = List[Palette]()
        self.pals16 = List[Palette]()
        self.dark = List[Bool]()
        self.problems = List[String]()
        var builtin = ["classic", "midnight", "amber"]
        for k in range(THEME_COUNT):
            self.ids.append(String(builtin[k]))
            self.pals.append(theme(k))
            self.pals256.append(theme(k))
            self.pals16.append(theme(k))
            self.dark.append(True)
        self.add_text("classic", CLASSIC_DEPTHS, "palette.mojo (classic)")
        self.add_text("midnight", MIDNIGHT_DEPTHS, "palette.mojo (midnight)")
        self.add_text("amber", AMBER_DEPTHS, "palette.mojo (amber)")
        self.add_text("light", PAPER_LIGHT, "themes/paper-light.toml")
        self.add_text("contrast", HIGH_CONTRAST, "themes/high-contrast.toml")
        self.add_text("matrix", HACKER_MATRIX, "themes/hacker-matrix.toml")
        self.add_text("okabe", OKABE_ITO, "themes/okabe-ito.toml")
        self.add_text("ansi", TERMINAL_ANSI, "themes/terminal-ansi.toml")
        self.add_text("mono", TERMINAL_MONO, "themes/terminal-mono.toml")

    def find(self, id: String) -> Int:
        for k in range(len(self.ids)):
            if self.ids[k] == id:
                return k
        return -1

    def count(self) -> Int:
        return len(self.ids)

    def for_depth(self, k: Int, mode: Int) -> Palette:
        """Theme k's palette for a terminal of colour depth `mode` (caps.COLOR_*)."""
        if mode == COLOR_256:
            return self.pals256[k].copy()
        if mode == COLOR_16:
            return self.pals16[k].copy()
        return self.pals[k].copy()

    def apply(mut self, mut p: Palette, doc: TomlDoc, section: String, where: String):
        """The colours of one section ([roles], [colors], [colors256], [colors16]) put
        into p; a role sets each of its colours."""
        for k in doc.keys_in(section):
            var v = parse_color(doc.get_str(section + "." + k, ""))
            if v < 0:
                self.problems.append(where + ": " + section + "." + k + " is not a colour like \"#1A2B3C\"")
            elif section == "roles":
                if len(role_fields(k)) == 0:
                    self.problems.append(where + ": there is no role \"" + k + "\" (roles: " + ROLE_NAMES + ")")
                else:
                    _ = set_key(p, k, v)
            elif not set_key(p, k, v):
                self.problems.append(where + ": there is no colour \"" + k + "\"")

    def apply_syntax(mut self, mut p: Palette, doc: TomlDoc, section: String, where: String):
        """The syntax colours of one section ([syntax], [syntax256], [syntax16])."""
        var sk = syntax_keys()
        for k in doc.keys_in(section):
            var v = parse_color(doc.get_str(section + "." + k, ""))
            var at = -1
            for j in range(len(sk)):
                if sk[j] == k:
                    at = j
            if v < 0:
                self.problems.append(where + ": " + section + "." + k + " is not a colour like \"#1A2B3C\"")
            elif at < 0 or at >= len(p.syn):
                self.problems.append(where + ": there is no syntax colour \"" + k + "\"")
            else:
                p.syn[at] = v

    def add_text(mut self, id: String, text: String, where: String):
        """A theme from TOML text (replaces one of the same id). Each depth starts from
        the base theme's palette for that depth; then come [roles], [colors] and
        [syntax], and for 256 and 16 colours their own sections last ([colors256] and
        [syntax256], [colors16] and [syntax16]; roles may be named there too)."""
        var doc = toml_parse(text)
        for pr in doc.problems:
            self.problems.append(where + ": " + pr)
        var base_id = doc.get_str("base", "classic")
        var bi = self.find(base_id)
        if bi < 0:
            self.problems.append(where + ": no theme \"" + base_id + "\" to start from; classic used")
            bi = 0
        var out = List[Palette]()
        for depth in range(3):
            var p = self.pals[bi].copy() if depth == 0 else (self.pals256[bi].copy() if depth == 1 else self.pals16[bi].copy())
            var quiet = depth > 0           # (problems once, not for each depth)
            var n_before = len(self.problems)
            p.name = doc.get_str("name", self.pals[bi].name if base_id == id else id)
            self.apply(p, doc, "roles", where)
            self.apply(p, doc, "colors", where)
            self.apply_syntax(p, doc, "syntax", where)
            if quiet:
                while len(self.problems) > n_before:
                    _ = self.problems.pop()
            if depth == 1:
                self.apply(p, doc, "colors256", where)
                self.apply_syntax(p, doc, "syntax256", where)
            elif depth == 2:
                self.apply(p, doc, "colors16", where)
                self.apply_syntax(p, doc, "syntax16", where)
            p.scanlines = doc.get_bool("scanlines", p.scanlines)
            p.monochrome = doc.get_bool("monochrome", p.monochrome)
            out.append(p^)
        var dark = doc.get_bool("dark", True)
        var have = self.find(id)
        if have >= 0:
            self.pals[have] = out[0].copy()
            self.pals256[have] = out[1].copy()
            self.pals16[have] = out[2].copy()
            self.dark[have] = dark
        else:
            self.ids.append(id)
            self.pals.append(out[0].copy())
            self.pals256.append(out[1].copy())
            self.pals16.append(out[2].copy())
            self.dark.append(dark)

    def add_folder(mut self, dir: String):
        """Every *.toml in `dir`: a theme named after the file."""
        if not path_exists(dir):
            return
        for name in list_dir(dir):
            if not name.endswith(".toml"):
                continue
            var id = String(name[byte=0:name.byte_length() - 5])
            self.add_text(id, bytes_to_str(read_file(dir + "/" + name)), name)


def scheme_from(colorfgbg: String, gnome: String) -> Int:
    """The desktop's light or dark when the terminal does not say (1 dark, 2 light, 0
    unknown): COLORFGBG ("fg;bg", set by rxvt, Konsole and others: background 0-6 or 8
    is dark), else GNOME's color-scheme setting ('prefer-dark', 'prefer-light', or
    'default', which GNOME shows light)."""
    var c = String(colorfgbg.strip())
    if c.byte_length() > 0:
        var parts = c.split(";")
        try:
            var bg = atol(String(parts[len(parts) - 1]))
            if bg >= 0 and bg <= 15:
                return 1 if (bg <= 6 or bg == 8) else 2
        except:
            pass
    var g = String(gnome.strip())
    if g.find("prefer-dark") >= 0:
        return 1
    if g.find("prefer-light") >= 0 or g.find("default") >= 0:
        return 2
    return 0


def animations_off(gnome: String) -> Bool:
    """GNOME's org.gnome.desktop.interface enable-animations is false: the user asked
    the desktop for less motion."""
    return String(gnome.strip()) == "false"
