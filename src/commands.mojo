"""Command registry: the single table of commands, their titles, hints and default keys.

Menus, keyboard shortcuts, the command palette and the keyboard reference are all generated
from this table, so they cannot drift apart."""
from std.collections import List
from term import (
    K_BASE, KEY_ESC, KEY_ENTER, KEY_TAB, KEY_BACKSPACE, KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT,
    KEY_HOME, KEY_END, KEY_PGUP, KEY_PGDN, KEY_INSERT, KEY_DELETE, KEY_F1, MOD_SHIFT, MOD_ALT,
    MOD_CTRL, KEY_MASK, fkey, ctrl, alt,
)
from util import decode, to_str, encode_cp, bytes_to_str

# ------------------------------------------------------------------ command ids
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
comptime CM_CANCEL = 75
comptime CM_LINENUM = 80
comptime CM_AUTOINDENT = 81
comptime CM_HLLINE = 82
comptime CM_CRLF = 83
comptime CM_THEME0 = 84
comptime CM_THEME1 = 85
comptime CM_THEME2 = 86
comptime CM_CLOCK = 87
comptime CM_SHOWWS = 88
comptime CM_USETABS = 89
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


def plain(label: String) -> String:
    """A menu label without its '~' hot-letter markers."""
    var out = List[Int]()
    for c in decode(label):
        if c != 126:
            out.append(c)
    return to_str(out)


def hot_char(label: String) -> Int:
    """The (lower-cased) hot letter of a '~X~' label, or -1."""
    var cps = decode(label)
    for i in range(len(cps) - 1):
        if cps[i] == 126:
            var c = cps[i + 1]
            if c >= 65 and c <= 90:
                c += 32
            return c
    return -1


def key_name(k: Int) -> String:
    """Human-readable name of a key code, e.g. 'Ctrl-S', 'Alt-F3', 'Shift-Del'."""
    var s = String("")
    if (k & MOD_CTRL) != 0:
        s += "Ctrl-"
    if (k & MOD_ALT) != 0:
        s += "Alt-"
    if (k & MOD_SHIFT) != 0:
        s += "Shift-"
    var b = k & KEY_MASK
    if b >= KEY_F1 and b < KEY_F1 + 12:
        return s + "F" + String(b - KEY_F1 + 1)
    if b == KEY_ESC:
        return s + "Esc"
    if b == KEY_ENTER:
        return s + "Enter"
    if b == KEY_TAB:
        return s + "Tab"
    if b == KEY_BACKSPACE:
        return s + "Bksp"
    if b == KEY_UP:
        return s + "Up"
    if b == KEY_DOWN:
        return s + "Down"
    if b == KEY_LEFT:
        return s + "Left"
    if b == KEY_RIGHT:
        return s + "Right"
    if b == KEY_HOME:
        return s + "Home"
    if b == KEY_END:
        return s + "End"
    if b == KEY_PGUP:
        return s + "PgUp"
    if b == KEY_PGDN:
        return s + "PgDn"
    if b == KEY_INSERT:
        return s + "Ins"
    if b == KEY_DELETE:
        return s + "Del"
    if b == 32:
        return s + "Space"
    if b >= 97 and b <= 122:
        b -= 32
    var bytes = List[UInt8]()
    encode_cp(b, bytes)
    return s + bytes_to_str(bytes)


def strip_prefix_ci(cps: List[Int], start: Int, prefix: String) -> Int:
    """If cps[start:] begins with prefix (ignoring case) return the index after it, else -1."""
    var pc = decode(prefix)
    if start + len(pc) > len(cps):
        return -1
    for i in range(len(pc)):
        var a = cps[start + i]
        if a >= 65 and a <= 90:
            a += 32
        if a != pc[i]:
            return -1
    return start + len(pc)


def parse_key(name: String) -> Int:
    """Inverse of key_name(): 'Ctrl-Shift-F5' -> key code. Returns 0 if not understood."""
    var cps = decode(name)
    var i = 0
    var mods = 0
    while True:
        var n = strip_prefix_ci(cps, i, "ctrl-")
        if n >= 0 and n < len(cps):
            mods |= MOD_CTRL
            i = n
            continue
        n = strip_prefix_ci(cps, i, "alt-")
        if n >= 0 and n < len(cps):
            mods |= MOD_ALT
            i = n
            continue
        n = strip_prefix_ci(cps, i, "shift-")
        if n >= 0 and n < len(cps):
            mods |= MOD_SHIFT
            i = n
            continue
        break
    var rest = List[Int]()
    for k in range(i, len(cps)):
        var c = cps[k]
        if c >= 65 and c <= 90:
            c += 32
        rest.append(c)
    var word = to_str(rest)
    if len(rest) == 0:
        return 0
    if len(rest) == 1:
        if rest[0] < 33 or rest[0] == 127:
            return 0
        return mods | rest[0]
    if rest[0] == 102:   # f1..f12
        var num = 0
        var ok = True
        for k in range(1, len(rest)):
            if rest[k] < 48 or rest[k] > 57:
                ok = False
                break
            num = num * 10 + rest[k] - 48
        if ok and num >= 1 and num <= 12:
            return mods | fkey(num)
    var names = List[String]()
    var codes = List[Int]()
    for nm in ["esc", "escape", "enter", "return", "tab", "bksp", "backspace", "up", "down", "left", "right", "home", "end", "pgup", "pageup", "pgdn", "pagedown", "ins", "insert", "del", "delete", "space"]:
        names.append(String(nm))
    for cd in [KEY_ESC, KEY_ESC, KEY_ENTER, KEY_ENTER, KEY_TAB, KEY_BACKSPACE, KEY_BACKSPACE, KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_HOME, KEY_END, KEY_PGUP, KEY_PGUP, KEY_PGDN, KEY_PGDN, KEY_INSERT, KEY_INSERT, KEY_DELETE, KEY_DELETE, 32]:
        codes.append(cd)
    for k in range(len(names)):
        if names[k] == word:
            return mods | codes[k]
    return 0


struct Command(Copyable, Movable):
    var id: Int
    var name: String     # stable identifier, e.g. "file.open" (for config and plugins)
    var title: String    # menu label with ~ hot letter
    var hint: String     # one-line description shown in the status bar
    var keys: List[Int]  # default bindings; the first one is shown in menus

    def __init__(out self, id: Int, name: String, title: String, hint: String, var keys: List[Int]):
        self.id = id
        self.name = name
        self.title = title
        self.hint = hint
        self.keys = keys^


@fieldwise_init
struct Placement(Copyable, Movable):
    var menu: Int   # index into Registry.menu_titles
    var cmd: Int    # command id, or CM_NONE for a separator


struct Registry(Copyable, Movable):
    var cmds: List[Command]
    var menu_titles: List[String]
    var layout: List[Placement]

    def __init__(out self):
        self.cmds = List[Command]()
        self.menu_titles = List[String]()
        self.layout = List[Placement]()

    # ------------------------------------------------------------ building
    def cmd(mut self, id: Int, name: String, title: String, hint: String, var keys: List[Int] = List[Int]()):
        self.cmds.append(Command(id, name, title, hint, keys^))

    def menu(mut self, title: String):
        self.menu_titles.append(title)

    def item(mut self, id: Int):
        self.layout.append(Placement(len(self.menu_titles) - 1, id))

    def sep(mut self):
        self.layout.append(Placement(len(self.menu_titles) - 1, CM_NONE))

    # ------------------------------------------------------------- queries
    def index_of(self, id: Int) -> Int:
        for i in range(len(self.cmds)):
            if self.cmds[i].id == id:
                return i
        return -1

    def index_of_name(self, name: String) -> Int:
        for i in range(len(self.cmds)):
            if self.cmds[i].name == name:
                return i
        return -1

    def find_key(self, k: Int) -> Int:
        """The command bound to key k, or CM_NONE."""
        for i in range(len(self.cmds)):
            for b in self.cmds[i].keys:
                if b == k:
                    return self.cmds[i].id
        return CM_NONE

    def key_label(self, id: Int) -> String:
        """Name of the primary binding ('' when the command has no key)."""
        var i = self.index_of(id)
        if i < 0 or len(self.cmds[i].keys) == 0:
            return ""
        return key_name(self.cmds[i].keys[0])

    def all_keys_label(self, id: Int) -> String:
        var i = self.index_of(id)
        var s = String("")
        if i < 0:
            return s
        for k in range(len(self.cmds[i].keys)):
            if k > 0:
                s += ", "
            s += key_name(self.cmds[i].keys[k])
        return s

    def rebind(mut self, name: String, var keys: List[Int]) -> Bool:
        """Replace a command's bindings (used by user configuration)."""
        var i = self.index_of_name(name)
        if i < 0:
            return False
        self.cmds[i].keys = keys^
        return True


def build_registry() -> Registry:
    var r = Registry()
    # ---- File
    r.cmd(CM_NEW, "file.new", "~N~ew", "Create a new edit window", [ctrl(110)])
    r.cmd(CM_OPEN, "file.open", "~O~pen...", "Locate and open a file in an edit window", [fkey(3), ctrl(111)])
    r.cmd(CM_SAVE, "file.save", "~S~ave", "Save the file in the active edit window", [fkey(2), ctrl(115)])
    r.cmd(CM_SAVEAS, "file.saveAs", "Save ~a~s...", "Save the current file under a different name")
    r.cmd(CM_SAVEALL, "file.saveAll", "Save a~l~l", "Save all modified files")
    r.cmd(CM_CLOSE, "window.close", "~C~lose", "Close the active window", [fkey(3) | MOD_ALT, ctrl(119)])
    r.cmd(CM_SHELL, "file.shell", "OS s~h~ell", "Temporarily exit to the shell (type exit to return)")
    r.cmd(CM_QUIT, "file.quit", "~Q~uit", "Exit TurboMojo", [alt(120), ctrl(113)])
    # ---- Edit
    r.cmd(CM_UNDO, "edit.undo", "~U~ndo", "Undo the previous editor operation", [ctrl(122), KEY_BACKSPACE | MOD_ALT])
    r.cmd(CM_REDO, "edit.redo", "~R~edo", "Redo the previously undone operation", [ctrl(121)])
    r.cmd(CM_CUT, "edit.cut", "Cu~t~", "Remove the selection and put it in the clipboard", [ctrl(120), KEY_DELETE | MOD_SHIFT])
    r.cmd(CM_COPY, "edit.copy", "~C~opy", "Copy the selection to the clipboard (and system via OSC 52)", [ctrl(99), KEY_INSERT | MOD_CTRL])
    r.cmd(CM_PASTE, "edit.paste", "~P~aste", "Insert the clipboard contents at the cursor", [ctrl(118), KEY_INSERT | MOD_SHIFT])
    r.cmd(CM_CLEAR, "edit.clear", "C~l~ear", "Delete the selection", [KEY_DELETE | MOD_CTRL])
    r.cmd(CM_SELALL, "edit.selectAll", "Select ~a~ll", "Select the entire buffer", [ctrl(97)])
    r.cmd(CM_COMMENT, "edit.toggleComment", "Toggle co~m~ment", "Comment or uncomment the selected lines", [ctrl(47)])
    r.cmd(CM_DUPLINE, "edit.duplicateLine", "~D~uplicate line", "Duplicate the current line", [ctrl(100)])
    r.cmd(CM_DELLINE, "edit.deleteLine", "Delete l~i~ne", "Delete the current line", [ctrl(107)])
    r.cmd(CM_COMPLETE, "edit.complete", "Complete ~w~ord", "Complete the identifier under the cursor", [ctrl(32)])
    # ---- Search
    r.cmd(CM_FIND, "search.find", "~F~ind...", "Search for text", [ctrl(102)])
    r.cmd(CM_REPLACE, "search.replace", "~R~eplace...", "Search for text and replace it", [ctrl(114)])
    r.cmd(CM_AGAIN, "search.again", "~S~earch again", "Repeat the last Find or Replace", [ctrl(108)])
    r.cmd(CM_GOTO, "search.gotoLine", "~G~o to line number...", "Move the cursor to a line number", [ctrl(103)])
    r.cmd(CM_SYMBOL, "search.gotoSymbol", "Go to s~y~mbol...", "Jump to a def / struct / trait in this file", [ctrl(116)])
    r.cmd(CM_MATCH, "search.matchBracket", "~M~atch bracket", "Jump to the matching bracket", [ctrl(93)])
    r.cmd(CM_PALETTE, "view.commandPalette", "~C~ommand palette...", "Fuzzy-search every IDE command", [ctrl(112)])
    # ---- Run
    r.cmd(CM_RUN, "run.run", "~R~un", "Run the current program with `mojo run`", [fkey(9) | MOD_CTRL, fkey(8)])
    r.cmd(CM_TEST, "run.test", "~T~est", "Run this file's TestSuite (std.testing) with `mojo run`")
    r.cmd(CM_USERSCREEN, "run.userScreen", "~U~ser screen", "View the program's output screen", [fkey(5) | MOD_ALT])
    r.cmd(CM_ARGS, "run.arguments", "~A~rguments...", "Set command-line arguments for Run")
    # ---- Compile
    r.cmd(CM_BUILD, "compile.build", "~B~uild", "Compile the current file to a native executable", [fkey(9), ctrl(98)])
    r.cmd(CM_FORMAT, "compile.format", "~F~ormat source", "Reformat the current file with `mojo format`", [fkey(9) | MOD_ALT])
    r.cmd(CM_NEXTERR, "compile.nextMessage", "~N~ext message", "Jump to the next compiler message", [fkey(8) | MOD_ALT])
    r.cmd(CM_PREVERR, "compile.previousMessage", "~P~revious message", "Jump to the previous compiler message", [fkey(7) | MOD_ALT])
    r.cmd(CM_CANCEL, "compile.cancel", "C~a~ncel build", "Stop the running build or format", [fkey(2) | MOD_CTRL])
    r.cmd(CM_COMPILER, "compile.compilerCommand", "~C~ompiler command...", "Choose which mojo executable to use")
    # ---- Options
    r.cmd(CM_LINENUM, "options.lineNumbers", "~L~ine numbers", "Toggle the line number gutter")
    r.cmd(CM_AUTOINDENT, "options.autoIndent", "~A~uto indent", "Toggle smart auto indentation")
    r.cmd(CM_HLLINE, "options.highlightLine", "~H~ighlight line", "Toggle current line highlighting")
    r.cmd(CM_CLOCK, "options.clock", "Cl~o~ck", "Toggle the menu bar clock")
    r.cmd(CM_SHOWWS, "options.showWhitespace", "Show ~w~hitespace", "Show tab characters as arrows")
    r.cmd(CM_USETABS, "options.indentWithTabs", "Indent with ~t~abs", "Tab key and auto-indent use tab characters (auto-detected)")
    r.cmd(CM_CRLF, "options.crlf", "CRLF line ~e~ndings", "Save the file with Windows line endings (auto-detected)")
    r.cmd(CM_THEME0, "options.themeClassic", "Theme: Turbo ~C~lassic", "The 1992 CGA blue look")
    r.cmd(CM_THEME1, "options.themeMidnight", "Theme: ~M~idnight Neon", "A modern dark truecolor theme")
    r.cmd(CM_THEME2, "options.themeAmber", "Theme: Am~b~er CRT", "Phosphor monochrome terminal")
    # ---- Window
    r.cmd(CM_ZOOM, "window.zoom", "~Z~oom", "Enlarge or restore the active window", [fkey(5)])
    r.cmd(CM_TILE, "window.tile", "~T~ile", "Arrange windows side by side")
    r.cmd(CM_CASCADE, "window.cascade", "C~a~scade", "Stack windows on top of each other")
    r.cmd(CM_NEXTWIN, "window.next", "~N~ext", "Make the next window active", [fkey(6)])
    r.cmd(CM_PREVWIN, "window.previous", "~P~revious", "Make the previous window active", [fkey(6) | MOD_SHIFT])
    r.cmd(CM_CLOSEALL, "window.closeAll", "Clos~e~ all", "Close all windows")
    r.cmd(CM_MESSAGE, "window.message", "~M~essage", "Open the compiler message window")
    r.cmd(CM_WINLIST, "window.list", "~L~ist...", "Show a list of open windows", [alt(48)])
    # ---- Help / system
    r.cmd(CM_HELP, "help.keyboard", "~K~eyboard reference", "Show the keyboard reference", [fkey(1)])
    r.cmd(CM_ABOUT, "help.about", "~A~bout...", "Show version and credits")
    r.cmd(CM_REFRESH, "view.repaint", "~R~epaint desktop", "Redraw the whole screen")

    # ---- menu layout
    r.menu("~≡~")
    r.item(CM_ABOUT)
    r.item(CM_PALETTE)
    r.sep()
    r.item(CM_REFRESH)

    r.menu("~F~ile")
    r.item(CM_NEW)
    r.item(CM_OPEN)
    r.item(CM_SAVE)
    r.item(CM_SAVEAS)
    r.item(CM_SAVEALL)
    r.sep()
    r.item(CM_CLOSE)
    r.item(CM_SHELL)
    r.item(CM_QUIT)

    r.menu("~E~dit")
    r.item(CM_UNDO)
    r.item(CM_REDO)
    r.sep()
    r.item(CM_CUT)
    r.item(CM_COPY)
    r.item(CM_PASTE)
    r.item(CM_CLEAR)
    r.item(CM_SELALL)
    r.sep()
    r.item(CM_COMMENT)
    r.item(CM_DUPLINE)
    r.item(CM_DELLINE)
    r.item(CM_COMPLETE)

    r.menu("~S~earch")
    r.item(CM_FIND)
    r.item(CM_REPLACE)
    r.item(CM_AGAIN)
    r.sep()
    r.item(CM_GOTO)
    r.item(CM_SYMBOL)
    r.item(CM_MATCH)
    r.sep()
    r.item(CM_PREVERR)
    r.item(CM_NEXTERR)

    r.menu("~R~un")
    r.item(CM_RUN)
    r.item(CM_TEST)
    r.item(CM_USERSCREEN)
    r.item(CM_ARGS)

    r.menu("~C~ompile")
    r.item(CM_BUILD)
    r.item(CM_FORMAT)
    r.sep()
    r.item(CM_NEXTERR)
    r.item(CM_PREVERR)
    r.item(CM_CANCEL)
    r.item(CM_COMPILER)

    r.menu("~O~ptions")
    r.item(CM_LINENUM)
    r.item(CM_AUTOINDENT)
    r.item(CM_HLLINE)
    r.item(CM_CLOCK)
    r.item(CM_SHOWWS)
    r.item(CM_USETABS)
    r.item(CM_CRLF)
    r.sep()
    r.item(CM_THEME0)
    r.item(CM_THEME1)
    r.item(CM_THEME2)

    r.menu("~W~indow")
    r.item(CM_ZOOM)
    r.item(CM_TILE)
    r.item(CM_CASCADE)
    r.item(CM_NEXTWIN)
    r.item(CM_PREVWIN)
    r.item(CM_CLOSE)
    r.item(CM_CLOSEALL)
    r.sep()
    r.item(CM_MESSAGE)
    r.item(CM_WINLIST)

    r.menu("~H~elp")
    r.item(CM_HELP)
    r.item(CM_ABOUT)
    return r^
