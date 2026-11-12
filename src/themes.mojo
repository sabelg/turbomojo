"""Colour themes as TOML files: the built-in ones beside Turbo Classic, Midnight Neon and
Amber CRT (palette.mojo), and the user's own in $XDG_CONFIG_HOME/turbomojo/themes/.

A theme file:

    name = "Paper Light"        # shown in Options > Theme
    base = "classic"            # optional: start from this theme's colours
    dark = false                # for ui.theme = "auto": which kind of terminal it suits
    [colors]
    ed_bg = "#FAFAF7"           # any palette field (see palette_keys), as #RRGGBB
    [syntax]
    keyword = "#7A3E9D"         # text keyword type comment string number decorator
                                # symbol builtin self def param property namespace

Unknown keys and bad colours are reported (and skipped), so a theme with a typo still
loads.
"""
from std.collections import List
from palette import Palette, theme, THEME_COUNT
from toml import TomlDoc, toml_parse, T_STR
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
comptime PAPER_LIGHT = "# Paper Light: a light theme for terminals with a light background.\n# Copy this file to ~/.config/turbomojo/themes/ under another name to make your own.\nname = \"Paper Light\"\nbase = \"midnight\"\ndark = false\n\n[colors]\ndesk_fg = \"#D8D8D0\"\ndesk_bg = \"#E8E8E2\"\nmenu_fg = \"#2B2B2B\"\nmenu_bg = \"#E0E0DA\"\nmenu_hot = \"#B04A00\"\nmenu_sel_fg = \"#FFFFFF\"\nmenu_sel_bg = \"#3A6EA5\"\nmenu_dis = \"#8A8A84\"\nstatus_fg = \"#2B2B2B\"\nstatus_bg = \"#E0E0DA\"\nstatus_hot = \"#B04A00\"\ned_fg = \"#1F1F1F\"\ned_bg = \"#FBFBF8\"\nframe_act = \"#3A6EA5\"\nframe_inact = \"#A8A8A0\"\ntitle_fg = \"#1F1F1F\"\nsel_fg = \"#1F1F1F\"\nsel_bg = \"#C9DDF2\"\ncurline_bg = \"#F1F1EC\"\ngutter_fg = \"#8A8A84\"\ngutter_bg = \"#FBFBF8\"\nbracket_fg = \"#1F1F1F\"\nbracket_bg = \"#E2D6A8\"\nmatch_fg = \"#1F1F1F\"\nmatch_bg = \"#F4E3A1\"\ndoc_fg = \"#1F1F1F\"\ndoc_bg = \"#F3F3EE\"\ndoc_bold = \"#000000\"\ndoc_code = \"#7A3E9D\"\ndoc_dim = \"#6E6E68\"\ndiag_err = \"#C62828\"\ndiag_warn = \"#8A5700\"\ndiag_note = \"#2E6DB4\"\nruler_bg = \"#F0F0EA\"\nword_bg = \"#E8EEF5\"\nicon_fg = \"#3A6EA5\"\nscroll_fg = \"#8A8A84\"\nscroll_bg = \"#ECECE6\"\nmsg_fg = \"#1F1F1F\"\nmsg_bg = \"#F3F3EE\"\nmsg_err = \"#C62828\"\nmsg_warn = \"#8A5700\"\nmsg_note = \"#2E6DB4\"\nmsg_ok = \"#2E7D32\"\ngit_add = \"#2E7D32\"\ngit_mod = \"#2E6DB4\"\ngit_del = \"#C62828\"\nmsg_sel_fg = \"#FFFFFF\"\nmsg_sel_bg = \"#3A6EA5\"\nmsg_frame = \"#3A6EA5\"\ndlg_fg = \"#1F1F1F\"\ndlg_bg = \"#ECECE6\"\ndlg_frame = \"#3A6EA5\"\ndlg_title = \"#1F1F1F\"\ndlg_hot = \"#B04A00\"\nin_fg = \"#1F1F1F\"\nin_bg = \"#FFFFFF\"\nbtn_fg = \"#1F1F1F\"\nbtn_bg = \"#D6D6CF\"\nbtn_focus_fg = \"#1A4F8A\"\nbtn_hot = \"#B04A00\"\nbtn_shadow = \"#B8B8B0\"\nlist_fg = \"#1F1F1F\"\nlist_bg = \"#FFFFFF\"\nlist_sel_fg = \"#FFFFFF\"\nlist_sel_bg = \"#3A6EA5\"\nshadow_fg = \"#9A9A94\"\nshadow_bg = \"#C8C8C0\"\n\n[syntax]\ntext = \"#1F1F1F\"\nkeyword = \"#7A3E9D\"\ntype = \"#00708A\"\ncomment = \"#6E6E68\"\nstring = \"#2E7D32\"\nnumber = \"#B04A00\"\ndecorator = \"#8A5700\"\nsymbol = \"#4A4A44\"\nbuiltin = \"#00708A\"\nself = \"#B03060\"\ndef = \"#2E6DB4\"\nparam = \"#5A4FA0\"\nproperty = \"#355E8C\"\nnamespace = \"#00708A\"\n"
comptime HACKER_MATRIX = "# Hacker Matrix: green phosphor on black, like an old CRT, with red, amber and blue\n# for what needs to stand out (errors, warnings and strings, types and notes).\nname = \"Hacker Matrix\"\nbase = \"amber\"\ndark = true\n\n[colors]\ndesk_fg = \"#0B2E13\"\ndesk_bg = \"#000000\"\nmenu_fg = \"#00D838\"\nmenu_bg = \"#031A08\"\nmenu_hot = \"#FFB000\"\nmenu_sel_fg = \"#000000\"\nmenu_sel_bg = \"#00FF41\"\nmenu_dis = \"#1E8C3A\"\nstatus_fg = \"#00D838\"\nstatus_bg = \"#031A08\"\nstatus_hot = \"#FFB000\"\ned_fg = \"#00D838\"\ned_bg = \"#020A04\"\nframe_act = \"#00FF41\"\nframe_inact = \"#1E8C3A\"\ntitle_fg = \"#00FF41\"\nsel_fg = \"#000000\"\nsel_bg = \"#00B32C\"\ncurline_bg = \"#06200D\"\ngutter_fg = \"#2E9E48\"\ngutter_bg = \"#020A04\"\nbracket_fg = \"#000000\"\nbracket_bg = \"#FFB000\"\nmatch_fg = \"#000000\"\nmatch_bg = \"#3FA9F5\"\ndoc_fg = \"#00D838\"\ndoc_bg = \"#031A08\"\ndoc_bold = \"#00FF41\"\ndoc_code = \"#FFB000\"\ndoc_dim = \"#2E9E48\"\ndiag_err = \"#FF3B3B\"\ndiag_warn = \"#FFB000\"\ndiag_note = \"#3FA9F5\"\nruler_bg = \"#041409\"\nword_bg = \"#0A2A12\"\nicon_fg = \"#00FF41\"\nscroll_fg = \"#00B32C\"\nscroll_bg = \"#041409\"\nmsg_fg = \"#00D838\"\nmsg_bg = \"#031A08\"\nmsg_err = \"#FF3B3B\"\nmsg_warn = \"#FFB000\"\nmsg_note = \"#3FA9F5\"\nmsg_ok = \"#00FF41\"\ngit_add = \"#00FF41\"\ngit_mod = \"#3FA9F5\"\ngit_del = \"#FF3B3B\"\nmsg_sel_fg = \"#000000\"\nmsg_sel_bg = \"#00FF41\"\nmsg_frame = \"#00FF41\"\ndlg_fg = \"#00D838\"\ndlg_bg = \"#031A08\"\ndlg_frame = \"#00FF41\"\ndlg_title = \"#00FF41\"\ndlg_hot = \"#FFB000\"\nin_fg = \"#00FF41\"\nin_bg = \"#000000\"\nbtn_fg = \"#00D838\"\nbtn_bg = \"#0E4D1F\"\nbtn_focus_fg = \"#FFB000\"\nbtn_hot = \"#3FA9F5\"\nbtn_shadow = \"#000000\"\nlist_fg = \"#00D838\"\nlist_bg = \"#000000\"\nlist_sel_fg = \"#000000\"\nlist_sel_bg = \"#00FF41\"\nshadow_fg = \"#0B2E13\"\nshadow_bg = \"#000000\"\n\n[syntax]\ntext = \"#00D838\"\nkeyword = \"#00FF41\"\ntype = \"#3FA9F5\"\ncomment = \"#3E9E4E\"\nstring = \"#FFB000\"\nnumber = \"#FFB000\"\ndecorator = \"#FF3B3B\"\nsymbol = \"#2E9E48\"\nbuiltin = \"#3FA9F5\"\nself = \"#66FFAA\"\ndef = \"#B6FFB6\"\nparam = \"#00D838\"\nproperty = \"#00D838\"\nnamespace = \"#3FA9F5\"\n"
comptime HIGH_CONTRAST = "# High Contrast: white and bright colours on black, for low vision and bright rooms.\nname = \"High Contrast\"\nbase = \"midnight\"\ndark = true\n\n[colors]\ndesk_fg = \"#303030\"\ndesk_bg = \"#000000\"\nmenu_fg = \"#FFFFFF\"\nmenu_bg = \"#000000\"\nmenu_hot = \"#FFFF00\"\nmenu_sel_fg = \"#000000\"\nmenu_sel_bg = \"#FFFF00\"\nmenu_dis = \"#A0A0A0\"\nstatus_fg = \"#FFFFFF\"\nstatus_bg = \"#000000\"\nstatus_hot = \"#FFFF00\"\ned_fg = \"#FFFFFF\"\ned_bg = \"#000000\"\nframe_act = \"#FFFF00\"\nframe_inact = \"#C0C0C0\"\ntitle_fg = \"#FFFFFF\"\nsel_fg = \"#000000\"\nsel_bg = \"#00FFFF\"\ncurline_bg = \"#1A1A1A\"\ngutter_fg = \"#C0C0C0\"\ngutter_bg = \"#000000\"\nbracket_fg = \"#000000\"\nbracket_bg = \"#FFFF00\"\nmatch_fg = \"#000000\"\nmatch_bg = \"#FF80FF\"\ndoc_fg = \"#FFFFFF\"\ndoc_bg = \"#000000\"\ndoc_bold = \"#FFFF00\"\ndoc_code = \"#00FFFF\"\ndoc_dim = \"#C0C0C0\"\ndiag_err = \"#FF6060\"\ndiag_warn = \"#FFFF00\"\ndiag_note = \"#00FFFF\"\nruler_bg = \"#1A1A1A\"\nword_bg = \"#333333\"\nicon_fg = \"#FFFF00\"\nscroll_fg = \"#FFFFFF\"\nscroll_bg = \"#333333\"\nmsg_fg = \"#FFFFFF\"\nmsg_bg = \"#000000\"\nmsg_err = \"#FF6060\"\nmsg_warn = \"#FFFF00\"\nmsg_note = \"#00FFFF\"\nmsg_ok = \"#80FF80\"\ngit_add = \"#80FF80\"\ngit_mod = \"#00FFFF\"\ngit_del = \"#FF6060\"\nmsg_sel_fg = \"#000000\"\nmsg_sel_bg = \"#FFFF00\"\nmsg_frame = \"#FFFF00\"\ndlg_fg = \"#FFFFFF\"\ndlg_bg = \"#000000\"\ndlg_frame = \"#FFFF00\"\ndlg_title = \"#FFFF00\"\ndlg_hot = \"#00FFFF\"\nin_fg = \"#FFFFFF\"\nin_bg = \"#1A1A1A\"\nbtn_fg = \"#000000\"\nbtn_bg = \"#FFFFFF\"\nbtn_focus_fg = \"#0000C0\"\nbtn_hot = \"#C00000\"\nbtn_shadow = \"#606060\"\nlist_fg = \"#FFFFFF\"\nlist_bg = \"#000000\"\nlist_sel_fg = \"#000000\"\nlist_sel_bg = \"#FFFF00\"\nshadow_fg = \"#808080\"\nshadow_bg = \"#000000\"\n\n[syntax]\ntext = \"#FFFFFF\"\nkeyword = \"#FFFF00\"\ntype = \"#00FFFF\"\ncomment = \"#C0C0C0\"\nstring = \"#80FF80\"\nnumber = \"#FF80FF\"\ndecorator = \"#FFC040\"\nsymbol = \"#FFFFFF\"\nbuiltin = \"#00FFFF\"\nself = \"#FF80FF\"\ndef = \"#80C0FF\"\nparam = \"#FFFFFF\"\nproperty = \"#FFFFFF\"\nnamespace = \"#00FFFF\"\n"


def parse_color(s: String) -> Int:
    """#RRGGBB or #RGB -> 0xRRGGBB (-1 if it is neither)."""
    var t = String(s.strip())
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
    """Every theme there is: ids ("classic", "light", a file's name), palettes, and
    whether each suits a dark terminal."""
    var ids: List[String]
    var pals: List[Palette]
    var dark: List[Bool]
    var problems: List[String]      # what was wrong in theme files ("file: line")

    def __init__(out self):
        self.ids = List[String]()
        self.pals = List[Palette]()
        self.dark = List[Bool]()
        self.problems = List[String]()
        var builtin = ["classic", "midnight", "amber"]
        for k in range(THEME_COUNT):
            self.ids.append(String(builtin[k]))
            self.pals.append(theme(k))
            self.dark.append(True)
        self.add_text("light", PAPER_LIGHT, "themes/paper-light.toml")
        self.add_text("contrast", HIGH_CONTRAST, "themes/high-contrast.toml")
        self.add_text("matrix", HACKER_MATRIX, "themes/hacker-matrix.toml")

    def find(self, id: String) -> Int:
        for k in range(len(self.ids)):
            if self.ids[k] == id:
                return k
        return -1

    def count(self) -> Int:
        return len(self.ids)

    def add_text(mut self, id: String, text: String, where: String):
        """A theme from TOML text (replaces one of the same id)."""
        var doc = toml_parse(text)
        for pr in doc.problems:
            self.problems.append(where + ": " + pr)
        var base_id = doc.get_str("base", "classic")
        var bi = self.find(base_id)
        if bi < 0:
            self.problems.append(where + ": no theme \"" + base_id + "\" to start from; classic used")
            bi = 0
        var p = self.pals[bi].copy()
        p.name = doc.get_str("name", id)
        var keys = palette_keys()
        for k in doc.keys_in("colors"):
            var v = parse_color(doc.get_str("colors." + k, ""))
            if v < 0:
                self.problems.append(where + ": colors." + k + " is not a colour like \"#1A2B3C\"")
            elif not palette_set(p, k, v):
                self.problems.append(where + ": there is no colour \"" + k + "\"")
        var sk = syntax_keys()
        for k in doc.keys_in("syntax"):
            var v = parse_color(doc.get_str("syntax." + k, ""))
            var at = -1
            for j in range(len(sk)):
                if sk[j] == k:
                    at = j
            if v < 0:
                self.problems.append(where + ": syntax." + k + " is not a colour like \"#1A2B3C\"")
            elif at < 0 or at >= len(p.syn):
                self.problems.append(where + ": there is no syntax colour \"" + k + "\"")
            else:
                p.syn[at] = v
        var dark = doc.get_bool("dark", True)
        var have = self.find(id)
        if have >= 0:
            self.pals[have] = p^
            self.dark[have] = dark
        else:
            self.ids.append(id)
            self.pals.append(p^)
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
