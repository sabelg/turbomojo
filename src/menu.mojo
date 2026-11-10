"""Menu bar structures and drawing. Menu contents come from commands.mojo."""
from std.collections import List
from screen import Screen
from palette import Palette
from util import cp_len, decode
from commands import Registry, CM_NONE

@fieldwise_init
struct MenuItem(Copyable, Movable):
    var label: String
    var key: String
    var cmd: Int
    var hint: String


struct Menu(Copyable, Movable):
    var title: String
    var items: List[MenuItem]
    var x: Int

    def __init__(out self, title: String):
        self.title = title
        self.items = List[MenuItem]()
        self.x = 0

    def add(mut self, label: String, key: String, cmd: Int, hint: String):
        self.items.append(MenuItem(label, key, cmd, hint))

    def sep(mut self):
        self.items.append(MenuItem("-", "", CM_NONE, ""))

    def width(self) -> Int:
        var w = 10
        for it in self.items:
            w = max(w, cp_len(it.label) - 2 + cp_len(it.key) + 6)
        return w


def build_menus(reg: Registry) -> List[Menu]:
    """Menus generated from the command registry's layout."""
    var ms = List[Menu]()
    for t in reg.menu_titles:
        ms.append(Menu(t))
    for p in reg.layout:
        if p.cmd == CM_NONE:
            ms[p.menu].sep()
            continue
        var i = reg.index_of(p.cmd)
        if i < 0:
            continue
        ms[p.menu].add(reg.cmds[i].title, reg.key_label(p.cmd), p.cmd, reg.cmds[i].hint)
    var x = 1
    for i in range(len(ms)):
        ms[i].x = x
        # titles sit two blanks apart, as in Turbo's menu bar; with nine menus a wider gap
        # would push Help off an 80-column screen's clock and off a 70-column screen
        x += cp_len(ms[i].title) - 2 + 2
    return ms^


def draw_menubar(mut scr: Screen, pal: Palette, menus: List[Menu], open_idx: Int, clock: String):
    scr.fill(0, 0, scr.w, 1, 32, pal.menu_fg, pal.menu_bg)
    for i in range(len(menus)):
        var sel = i == open_idx
        var fg = pal.menu_sel_fg if sel else pal.menu_fg
        var bg = pal.menu_sel_bg if sel else pal.menu_bg
        var w = cp_len(menus[i].title) - 2 + 2
        scr.fill(menus[i].x, 0, w, 1, 32, fg, bg)
        _ = scr.hot_text(menus[i].x + 1, 0, menus[i].title, fg, pal.menu_hot if not sel else fg, bg)
    if clock.byte_length() > 0 and len(menus) > 0:
        # only when it fits to the right of the last menu title
        var li = len(menus) - 1
        var menus_end = menus[li].x + cp_len(menus[li].title)
        var cx = scr.w - cp_len(clock) - 1
        if cx > menus_end:
            _ = scr.text(cx, 0, clock, pal.menu_fg, pal.menu_bg)


def draw_dropdown(mut scr: Screen, pal: Palette, m: Menu, sel: Int, checks: List[Int]):
    var w = m.width()
    var h = len(m.items) + 2
    var x = max(0, min(m.x - 1, scr.w - w - 2))
    var y = 1
    scr.fill(x, y, w, h, 32, pal.menu_fg, pal.menu_bg)
    scr.frame(x, y, w, h, False, pal.menu_fg, pal.menu_bg)
    for i in range(len(m.items)):
        var yy = y + 1 + i
        if m.items[i].label == "-":
            scr.put(x, yy, 0x251C, pal.menu_fg, pal.menu_bg)
            for xx in range(x + 1, x + w - 1):
                scr.put(xx, yy, 0x2500, pal.menu_fg, pal.menu_bg)
            scr.put(x + w - 1, yy, 0x2524, pal.menu_fg, pal.menu_bg)
            continue
        var s = i == sel
        var fg = pal.menu_sel_fg if s else pal.menu_fg
        var bg = pal.menu_sel_bg if s else pal.menu_bg
        scr.fill(x + 1, yy, w - 2, 1, 32, fg, bg)
        var cmd = m.items[i].cmd
        for c in checks:
            if c == cmd:
                scr.put(x + 1, yy, 0x221A, fg, bg)
        _ = scr.hot_text(x + 2, yy, m.items[i].label, fg, pal.menu_hot if not s else fg, bg)
        var k = m.items[i].key
        _ = scr.text(x + w - 2 - cp_len(k), yy, k, fg, bg)
    scr.shadow(x, y, w, h, pal.shadow_fg, pal.shadow_bg)


def dropdown_rect_x(scr_w: Int, m: Menu) -> Int:
    return max(0, min(m.x - 1, scr_w - m.width() - 2))
