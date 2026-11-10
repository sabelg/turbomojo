"""Menu bar definitions, command ids and drawing."""
from std.collections import List
from screen import Screen
from palette import Palette
from util import cp_len, decode

# ------------------------------------------------------------------ commands
comptime CM_NONE = 0
comptime CM_NEW = 1
comptime CM_OPEN = 2
comptime CM_SAVE = 3
comptime CM_SAVEAS = 4
comptime CM_SAVEALL = 5
comptime CM_CLOSE = 6
comptime CM_SHELL = 7
comptime CM_QUIT = 8
comptime CM_UNDO = 20
comptime CM_REDO = 21
comptime CM_CUT = 22
comptime CM_COPY = 23
comptime CM_PASTE = 24
comptime CM_CLEAR = 25
comptime CM_SELALL = 26
comptime CM_COMMENT = 27
comptime CM_DUPLINE = 28
comptime CM_DELLINE = 29
comptime CM_COMPLETE = 30
comptime CM_INDENT = 31
comptime CM_UNINDENT = 32
comptime CM_FIND = 40
comptime CM_REPLACE = 41
comptime CM_AGAIN = 42
comptime CM_GOTO = 43
comptime CM_SYMBOL = 44
comptime CM_MATCH = 45
comptime CM_PALETTE = 46
comptime CM_RUN = 60
comptime CM_USERSCREEN = 61
comptime CM_ARGS = 62
comptime CM_TEST = 63
comptime CM_BUILD = 70
comptime CM_FORMAT = 71
comptime CM_NEXTERR = 72
comptime CM_PREVERR = 73
comptime CM_COMPILER = 74
comptime CM_LINENUM = 80
comptime CM_AUTOINDENT = 81
comptime CM_HLLINE = 82
comptime CM_THEME0 = 84
comptime CM_THEME1 = 85
comptime CM_THEME2 = 86
comptime CM_CLOCK = 87
comptime CM_SHOWWS = 88
comptime CM_USETABS = 89
comptime CM_CRLF = 83
comptime CM_CANCEL = 75
comptime CM_ZOOM = 90
comptime CM_TILE = 91
comptime CM_CASCADE = 92
comptime CM_NEXTWIN = 93
comptime CM_PREVWIN = 94
comptime CM_MESSAGE = 95
comptime CM_WINLIST = 96
comptime CM_CLOSEALL = 97
comptime CM_HELP = 100
comptime CM_ABOUT = 101
comptime CM_REFRESH = 102


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


def hot_char(label: String) -> Int:
    var cps = decode(label)
    for i in range(len(cps) - 1):
        if cps[i] == 126:
            var c = cps[i + 1]
            if c >= 65 and c <= 90:
                c += 32
            return c
    return -1


def build_menus() -> List[Menu]:
    var ms = List[Menu]()
    var m0 = Menu("~≡~")
    m0.add("~A~bout...", "", CM_ABOUT, "Show version and credits")
    m0.add("~C~ommand palette...", "Ctrl-P", CM_PALETTE, "Fuzzy-search every IDE command")
    m0.sep()
    m0.add("~R~epaint desktop", "", CM_REFRESH, "Redraw the whole screen")
    ms.append(m0^)

    var f = Menu("~F~ile")
    f.add("~N~ew", "Ctrl-N", CM_NEW, "Create a new edit window")
    f.add("~O~pen...", "F3", CM_OPEN, "Locate and open a file in an edit window")
    f.add("~S~ave", "F2", CM_SAVE, "Save the file in the active edit window")
    f.add("Save ~a~s...", "", CM_SAVEAS, "Save the current file under a different name")
    f.add("Save a~l~l", "", CM_SAVEALL, "Save all modified files")
    f.sep()
    f.add("~C~lose", "Alt-F3", CM_CLOSE, "Close the active window")
    f.add("OS s~h~ell", "", CM_SHELL, "Temporarily exit to the shell (type exit to return)")
    f.add("~Q~uit", "Alt-X", CM_QUIT, "Exit TurboMojo")
    ms.append(f^)

    var e = Menu("~E~dit")
    e.add("~U~ndo", "Ctrl-Z", CM_UNDO, "Undo the previous editor operation")
    e.add("~R~edo", "Ctrl-Y", CM_REDO, "Redo the previously undone operation")
    e.sep()
    e.add("Cu~t~", "Ctrl-X", CM_CUT, "Remove the selection and put it in the clipboard")
    e.add("~C~opy", "Ctrl-C", CM_COPY, "Copy the selection to the clipboard (and system via OSC 52)")
    e.add("~P~aste", "Ctrl-V", CM_PASTE, "Insert the clipboard contents at the cursor")
    e.add("C~l~ear", "Ctrl-Del", CM_CLEAR, "Delete the selection")
    e.add("Select ~a~ll", "Ctrl-A", CM_SELALL, "Select the entire buffer")
    e.sep()
    e.add("Toggle co~m~ment", "Ctrl-/", CM_COMMENT, "Comment or uncomment the selected lines")
    e.add("~D~uplicate line", "Ctrl-D", CM_DUPLINE, "Duplicate the current line")
    e.add("Delete l~i~ne", "Ctrl-K", CM_DELLINE, "Delete the current line")
    e.add("Complete ~w~ord", "Ctrl-Space", CM_COMPLETE, "Complete the identifier under the cursor")
    ms.append(e^)

    var s = Menu("~S~earch")
    s.add("~F~ind...", "Ctrl-F", CM_FIND, "Search for text")
    s.add("~R~eplace...", "Ctrl-R", CM_REPLACE, "Search for text and replace it")
    s.add("~S~earch again", "Ctrl-L", CM_AGAIN, "Repeat the last Find or Replace")
    s.sep()
    s.add("~G~o to line number...", "Ctrl-G", CM_GOTO, "Move the cursor to a line number")
    s.add("Go to s~y~mbol...", "Ctrl-T", CM_SYMBOL, "Jump to a def / struct / trait in this file")
    s.add("~M~atch bracket", "Ctrl-]", CM_MATCH, "Jump to the matching bracket")
    s.sep()
    s.add("~P~revious error", "Alt-F7", CM_PREVERR, "Move to the previous compiler message")
    s.add("~N~ext error", "Alt-F8", CM_NEXTERR, "Move to the next compiler message")
    ms.append(s^)

    var r = Menu("~R~un")
    r.add("~R~un", "Ctrl-F9", CM_RUN, "Run the current program with `mojo run`")
    r.add("~T~est", "", CM_TEST, "Run this file's TestSuite (std.testing) with `mojo run`")
    r.add("~U~ser screen", "Alt-F5", CM_USERSCREEN, "View the program's output screen")
    r.add("~A~rguments...", "", CM_ARGS, "Set command-line arguments for Run")
    ms.append(r^)

    var c = Menu("~C~ompile")
    c.add("~B~uild", "F9", CM_BUILD, "Compile the current file to a native executable")
    c.add("~F~ormat source", "Alt-F9", CM_FORMAT, "Reformat the current file with `mojo format`")
    c.sep()
    c.add("~N~ext message", "Alt-F8", CM_NEXTERR, "Jump to the next compiler message")
    c.add("~P~revious message", "Alt-F7", CM_PREVERR, "Jump to the previous compiler message")
    c.add("C~a~ncel build", "Ctrl-F2", CM_CANCEL, "Stop the running build or format")
    c.add("~C~ompiler command...", "", CM_COMPILER, "Choose which mojo executable to use")
    ms.append(c^)

    var o = Menu("~O~ptions")
    o.add("~L~ine numbers", "", CM_LINENUM, "Toggle the line number gutter")
    o.add("~A~uto indent", "", CM_AUTOINDENT, "Toggle smart auto indentation")
    o.add("~H~ighlight line", "", CM_HLLINE, "Toggle current line highlighting")
    o.add("Cl~o~ck", "", CM_CLOCK, "Toggle the menu bar clock")
    o.add("Show ~w~hitespace", "", CM_SHOWWS, "Show tab characters as arrows")
    o.add("Indent with ~t~abs", "", CM_USETABS, "Tab key and auto-indent use tab characters (auto-detected)")
    o.add("CRLF line ~e~ndings", "", CM_CRLF, "Save the file with Windows line endings (auto-detected)")
    o.sep()
    o.add("Theme: Turbo ~C~lassic", "", CM_THEME0, "The 1992 CGA blue look")
    o.add("Theme: ~M~idnight Neon", "", CM_THEME1, "A modern dark truecolor theme")
    o.add("Theme: Am~b~er CRT", "", CM_THEME2, "Phosphor monochrome terminal")
    ms.append(o^)

    var w = Menu("~W~indow")
    w.add("~Z~oom", "F5", CM_ZOOM, "Enlarge or restore the active window")
    w.add("~T~ile", "", CM_TILE, "Arrange windows side by side")
    w.add("C~a~scade", "", CM_CASCADE, "Stack windows on top of each other")
    w.add("~N~ext", "F6", CM_NEXTWIN, "Make the next window active")
    w.add("~P~revious", "Shift-F6", CM_PREVWIN, "Make the previous window active")
    w.add("~C~lose", "Alt-F3", CM_CLOSE, "Close the active window")
    w.add("Close a~l~l", "", CM_CLOSEALL, "Close all windows")
    w.sep()
    w.add("~M~essage", "", CM_MESSAGE, "Open the compiler message window")
    w.add("~L~ist...", "Alt-0", CM_WINLIST, "Show a list of open windows")
    ms.append(w^)

    var h = Menu("~H~elp")
    h.add("~K~eyboard reference", "F1", CM_HELP, "Show the keyboard reference")
    h.add("~A~bout...", "", CM_ABOUT, "Show version and credits")
    ms.append(h^)

    var x = 1
    for i in range(len(ms)):
        ms[i].x = x
        x += cp_len(ms[i].title) - 2 + 2 + 1
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
    if clock.byte_length() > 0:
        _ = scr.text(scr.w - cp_len(clock) - 1, 0, clock, pal.menu_fg, pal.menu_bg)


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
