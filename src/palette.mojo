"""Colour themes. Classic reproduces the 16-colour CGA look of the 1992 Borland IDEs."""
from std.collections import List

comptime THEME_COUNT = 3

# CGA palette
comptime BLACK = 0x000000
comptime BLUE = 0x0000AA
comptime GREEN = 0x00AA00
comptime CYAN = 0x00AAAA
comptime RED = 0xAA0000
comptime MAGENTA = 0xAA00AA
comptime BROWN = 0xAA5500
comptime LGRAY = 0xAAAAAA
comptime DGRAY = 0x555555
comptime LBLUE = 0x5555FF
comptime LGREEN = 0x55FF55
comptime LCYAN = 0x55FFFF
comptime LRED = 0xFF5555
comptime LMAGENTA = 0xFF55FF
comptime YELLOW = 0xFFFF55
comptime WHITE = 0xFFFFFF


struct Palette(Copyable, Movable):
    var name: String
    var desk_fg: Int
    var desk_bg: Int
    var desk_ch: Int
    var menu_fg: Int
    var menu_bg: Int
    var menu_hot: Int
    var menu_sel_fg: Int
    var menu_sel_bg: Int
    var menu_dis: Int
    var status_fg: Int
    var status_bg: Int
    var status_hot: Int
    var ed_fg: Int
    var ed_bg: Int
    var frame_act: Int
    var frame_inact: Int
    var title_fg: Int
    var sel_fg: Int
    var sel_bg: Int
    var curline_bg: Int
    var gutter_fg: Int
    var gutter_bg: Int
    var bracket_fg: Int
    var bracket_bg: Int
    var icon_fg: Int
    var scroll_fg: Int
    var scroll_bg: Int
    var syn: List[Int]
    var msg_fg: Int
    var msg_bg: Int
    var msg_err: Int
    var msg_warn: Int
    var msg_note: Int
    var msg_sel_fg: Int
    var msg_sel_bg: Int
    var msg_frame: Int
    var dlg_fg: Int
    var dlg_bg: Int
    var dlg_frame: Int
    var dlg_title: Int
    var dlg_hot: Int
    var in_fg: Int
    var in_bg: Int
    var btn_fg: Int
    var btn_bg: Int
    var btn_focus_fg: Int
    var btn_hot: Int
    var btn_shadow: Int
    var list_fg: Int
    var list_bg: Int
    var list_sel_fg: Int
    var list_sel_bg: Int
    var shadow_fg: Int
    var shadow_bg: Int

    def __init__(out self):
        """Turbo Classic."""
        self.name = "Turbo Classic"
        self.desk_fg = BLUE
        self.desk_bg = LGRAY
        self.desk_ch = 0x2591
        self.menu_fg = BLACK
        self.menu_bg = LGRAY
        self.menu_hot = RED
        self.menu_sel_fg = BLACK
        self.menu_sel_bg = GREEN
        self.menu_dis = DGRAY
        self.status_fg = BLACK
        self.status_bg = LGRAY
        self.status_hot = RED
        self.ed_fg = YELLOW
        self.ed_bg = BLUE
        self.frame_act = WHITE
        self.frame_inact = LGRAY
        self.title_fg = WHITE
        self.sel_fg = BLUE
        self.sel_bg = CYAN
        self.curline_bg = 0x0000C4
        self.gutter_fg = CYAN
        self.gutter_bg = 0x000088
        self.bracket_fg = WHITE
        self.bracket_bg = MAGENTA
        self.icon_fg = LGREEN
        self.scroll_fg = BLUE
        self.scroll_bg = CYAN
        self.syn = List[Int]()
        # text kw type cmt str num deco sym builtin self def
        for c in [YELLOW, WHITE, LGREEN, LGRAY, LCYAN, LMAGENTA, LGREEN, YELLOW, LCYAN, WHITE, WHITE]:
            self.syn.append(c)
        self.msg_fg = BLACK
        self.msg_bg = CYAN
        self.msg_err = RED
        self.msg_warn = BROWN
        self.msg_note = BLUE
        self.msg_sel_fg = WHITE
        self.msg_sel_bg = GREEN
        self.msg_frame = WHITE
        self.dlg_fg = BLACK
        self.dlg_bg = LGRAY
        self.dlg_frame = WHITE
        self.dlg_title = WHITE
        self.dlg_hot = YELLOW
        self.in_fg = WHITE
        self.in_bg = BLUE
        self.btn_fg = BLACK
        self.btn_bg = GREEN
        self.btn_focus_fg = WHITE
        self.btn_hot = YELLOW
        self.btn_shadow = BLACK
        self.list_fg = BLACK
        self.list_bg = CYAN
        self.list_sel_fg = WHITE
        self.list_sel_bg = GREEN
        self.shadow_fg = DGRAY
        self.shadow_bg = BLACK


def theme(n: Int) -> Palette:
    var p = Palette()
    if n == 1:
        p.name = "Midnight Neon"
        p.desk_fg = 0x1F2335
        p.desk_bg = 0x16161E
        p.desk_ch = 0x2591
        p.menu_fg = 0xC0CAF5
        p.menu_bg = 0x1F2335
        p.menu_hot = 0xFF9E64
        p.menu_sel_fg = 0x1A1B26
        p.menu_sel_bg = 0x7AA2F7
        p.menu_dis = 0x565F89
        p.status_fg = 0xA9B1D6
        p.status_bg = 0x1F2335
        p.status_hot = 0xFF9E64
        p.ed_fg = 0xC0CAF5
        p.ed_bg = 0x1A1B26
        p.frame_act = 0x7AA2F7
        p.frame_inact = 0x3B4261
        p.title_fg = 0xC0CAF5
        p.sel_fg = 0xC0CAF5
        p.sel_bg = 0x33467C
        p.curline_bg = 0x222436
        p.gutter_fg = 0x3B4261
        p.gutter_bg = 0x1A1B26
        p.bracket_fg = 0xFFFFFF
        p.bracket_bg = 0x3D59A1
        p.icon_fg = 0xF7768E
        p.scroll_fg = 0x3B4261
        p.scroll_bg = 0x1A1B26
        p.syn.clear()
        for c in [0xC0CAF5, 0xBB9AF7, 0x2AC3DE, 0x565F89, 0x9ECE6A, 0xFF9E64, 0xE0AF68, 0x89DDFF, 0x7DCFFF, 0xF7768E, 0x7AA2F7]:
            p.syn.append(c)
        p.msg_fg = 0xA9B1D6
        p.msg_bg = 0x16161E
        p.msg_err = 0xF7768E
        p.msg_warn = 0xE0AF68
        p.msg_note = 0x7DCFFF
        p.msg_sel_fg = 0xC0CAF5
        p.msg_sel_bg = 0x283457
        p.msg_frame = 0x7AA2F7
        p.dlg_fg = 0xC0CAF5
        p.dlg_bg = 0x24283B
        p.dlg_frame = 0x7AA2F7
        p.dlg_title = 0x7AA2F7
        p.dlg_hot = 0xFF9E64
        p.in_fg = 0xC0CAF5
        p.in_bg = 0x1A1B26
        p.btn_fg = 0xC0CAF5
        p.btn_bg = 0x3D59A1
        p.btn_focus_fg = 0xFFFFFF
        p.btn_hot = 0xFF9E64
        p.btn_shadow = 0x16161E
        p.list_fg = 0xA9B1D6
        p.list_bg = 0x1A1B26
        p.list_sel_fg = 0x1A1B26
        p.list_sel_bg = 0x7AA2F7
        p.shadow_fg = 0x444B6A
        p.shadow_bg = 0x0B0B10
    elif n == 2:
        var hi = 0xFFB000
        var md = 0xCC8800
        var lo = 0x7A5200
        var bk = 0x0A0700
        var dim = 0x2A1C00
        p.name = "Amber CRT"
        p.desk_fg = dim
        p.desk_bg = bk
        p.desk_ch = 0x2591
        p.menu_fg = bk
        p.menu_bg = md
        p.menu_hot = 0x000000
        p.menu_sel_fg = hi
        p.menu_sel_bg = bk
        p.menu_dis = lo
        p.status_fg = bk
        p.status_bg = md
        p.status_hot = 0x000000
        p.ed_fg = md
        p.ed_bg = bk
        p.frame_act = hi
        p.frame_inact = lo
        p.title_fg = hi
        p.sel_fg = bk
        p.sel_bg = md
        p.curline_bg = 0x1A1100
        p.gutter_fg = lo
        p.gutter_bg = bk
        p.bracket_fg = bk
        p.bracket_bg = hi
        p.icon_fg = hi
        p.scroll_fg = lo
        p.scroll_bg = bk
        p.syn.clear()
        for c in [md, hi, hi, lo, 0xFFD27A, 0xFFD27A, hi, md, hi, hi, hi]:
            p.syn.append(c)
        p.msg_fg = md
        p.msg_bg = bk
        p.msg_err = hi
        p.msg_warn = md
        p.msg_note = lo
        p.msg_sel_fg = bk
        p.msg_sel_bg = md
        p.msg_frame = hi
        p.dlg_fg = md
        p.dlg_bg = 0x140E00
        p.dlg_frame = hi
        p.dlg_title = hi
        p.dlg_hot = hi
        p.in_fg = hi
        p.in_bg = dim
        p.btn_fg = bk
        p.btn_bg = md
        p.btn_focus_fg = 0x000000
        p.btn_hot = 0x000000
        p.btn_shadow = bk
        p.list_fg = md
        p.list_bg = dim
        p.list_sel_fg = bk
        p.list_sel_bg = hi
        p.shadow_fg = lo
        p.shadow_bg = 0x000000
    return p^
