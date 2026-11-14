"""Command registry: the single table of commands, their titles, hints and default keys.

Menus, keyboard shortcuts, the command palette and the keyboard reference are all generated
from this table, so they cannot drift apart."""
from std.collections import List
from term import (
    K_BASE, KEY_ESC, KEY_ENTER, KEY_TAB, KEY_BACKSPACE, KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT,
    KEY_HOME, KEY_END, KEY_PGUP, KEY_PGDN, KEY_INSERT, KEY_DELETE, KEY_F1, MOD_SHIFT, MOD_ALT,
    MOD_CTRL, KEY_MASK, fkey, ctrl, alt,
)
from util import decode, to_str, encode_cp, bytes_to_str, slice_str, fold_letter, char_width

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
comptime CM_LSP = 76
comptime CM_FINDFILES = 77
comptime CM_WRAP = 78
comptime CM_FOLD = 113
comptime CM_FOLDALL = 114
comptime CM_UNFOLDALL = 115
comptime CM_LINEUP = 116
comptime CM_LINEDOWN = 117
comptime CM_JOIN = 118
comptime CM_SORT = 119
comptime CM_UPPER = 120
comptime CM_LOWER = 121
comptime CM_MACRO_REC = 122
comptime CM_MACRO_PLAY = 123
comptime CM_KEYMAP0 = 124          # modern, turbo, emacs, vim: consecutive ids
comptime CM_KEYMAP1 = 125
comptime CM_KEYMAP2 = 126
comptime CM_KEYMAP3 = 127
comptime KEYMAP_COUNT = 4
# cursor commands: not in any menu, they exist so that keymaps can bind keys to them
comptime CM_CUR_LEFT = 130
comptime CM_CUR_RIGHT = 131
comptime CM_CUR_UP = 132
comptime CM_CUR_DOWN = 133
comptime CM_CUR_WORD_LEFT = 134
comptime CM_CUR_WORD_RIGHT = 135
comptime CM_CUR_LINE_START = 136
comptime CM_CUR_LINE_END = 137
comptime CM_CUR_PAGE_UP = 138
comptime CM_CUR_PAGE_DOWN = 139
comptime CM_CUR_TOP = 140
comptime CM_CUR_BOTTOM = 141
comptime CM_DEL_CHAR = 142
comptime CM_DEL_WORD = 143
comptime CM_KILL_LINE = 144
comptime CM_SCROLL_UP = 145
comptime CM_SCROLL_DOWN = 146
comptime CM_INSERT_MODE = 147
comptime CM_HOVER = 148
comptime CM_SIGNATURE = 149
comptime CM_DEFINITION = 150
comptime CM_BACK = 151
comptime CM_FORWARD = 152
comptime CM_REFERENCES = 153
comptime CM_RENAME = 154
comptime CM_ACTIONS = 155
comptime CM_SEMANTIC = 156
comptime CM_QUIET = 231          # Options > Quiet code colours
comptime CM_NEW_PROJECT = 232    # File > New project
comptime CM_SETUP = 233          # Help > Check setup
comptime CM_PRESETS = 234        # Options > Presets
comptime CM_REPORT = 235         # Help > Report a problem
comptime CM_GPU_STATUS = 236     # Options > GPU in the status line
comptime CM_RELNUM = 237         # Options > Relative numbers (vim's relativenumber)
comptime CM_AGENT_MODEL = 238    # System > Agent model...
comptime CM_AGENT_MODE = 239     # System > Agent mode...
comptime CM_AGENT_THINKING = 240 # System > Agent thinking...
comptime CM_AGENT_NEW = 241      # System > New agent session
comptime CM_AGENT_PROBLEMS = 242 # System > Send diagnostics to agent
comptime CM_REPLACEFILES = 243   # Search > Replace in files...
comptime CM_GIT_STATUS = 244     # File > Git status
comptime CM_GIT_STASH = 245      # Palette: Git stash
comptime CM_GIT_STASH_POP = 246  # Palette: Git pop stash
comptime CM_GIT_LINEBLAME = 247  # Options > Inline year/author blame
comptime CM_PIXI_ENV = 248       # Options > Pixi environment...
comptime CM_FORMAT_SAVE = 249    # Palette: Format on save
comptime CM_TYPEDEF = 250        # Search > Go to type definition
comptime CM_TEST_CURSOR = 251    # Run > Quick-run test at cursor
comptime CM_CODEGEN = 252        # Compile > Inspect generated code
comptime CM_GPU_PROFILE = 253    # Compile > Profile GPU kernels
comptime CM_GPU_WIN = 254        # Window > GPU queue & monitor
comptime CM_CLONE_VIEW = 255     # Window > Split joint view
comptime CM_AGENT_REVERT = 256   # ≡ > Revert last agent turn
comptime CM_DEBUG_GPU_LANE = 257 # Run > GPU thread / lane...
comptime CM_MAX_SERVE = 258      # Compile > MAX serve / benchmark...
comptime CM_EXPAND_SEL = 259     # Edit > Expand selection
comptime CM_SHRINK_SEL = 260     # Edit > Shrink selection
comptime CM_SKIPNEXT = 261       # Edit > Skip occurrence
comptime CM_INDENT_GUIDES = 262  # Palette: Indent guides
comptime CM_SELECT_ALL_OCC = 263 # Edit > Select every occurrence
comptime CM_CONFLICT_NEXT = 264  # File > Next merge conflict
comptime CM_CONFLICT_OURS = 265  # Palette: Git accept ours
comptime CM_CONFLICT_THEIRS = 266 # Palette: Git accept theirs
comptime CM_CONFLICT_BOTH = 267  # Palette: Git accept both
comptime CM_RUN_CELL = 268       # Compile > Run code cell (# %%)
comptime CM_RUN_CELL_NEXT = 269  # Palette / Ctrl-Shift-Enter: Run code cell & advance
comptime CM_HINTS = 157
comptime CM_OUTLINE = 158
comptime CM_WSYMBOL = 159
comptime CM_DOCS = 160
comptime CM_TILED = 161
comptime CM_SPLIT_RIGHT = 162
comptime CM_SPLIT_DOWN = 163
comptime CM_NEXT_PANE = 164
comptime CM_NEXT_TAB = 165
comptime CM_PREV_TAB = 166
comptime CM_MOVE_TAB = 167
comptime CM_PANE_GROW = 168
comptime CM_PANE_SHRINK = 169
comptime CM_PROBLEMS = 170
comptime CM_SEARCHRES = 171
comptime CM_EXPLORER = 172
comptime CM_QUICK = 173
comptime CM_TASKS = 174
comptime CM_TASK_AGAIN = 175
comptime CM_RUNCONFIGS = 176
comptime CM_TRUST = 177
comptime CM_MOJODOCS = 178
comptime CM_DOCFETCH = 179
comptime CM_DOCFIND = 180
comptime CM_DEBUG = 181
comptime CM_BP_TOGGLE = 182
comptime CM_BP_EDIT = 183
comptime CM_BP_FUNC = 184
comptime CM_BP_LIST = 185
comptime CM_BP_CLEAR = 186
comptime CM_STEP_INTO = 187
comptime CM_STEP_OVER = 188
comptime CM_STEP_OUT = 189
comptime CM_RUN_CURSOR = 190
comptime CM_PAUSE = 191
comptime CM_RESET = 192
comptime CM_DEBUGWIN = 193
comptime CM_WATCH_ADD = 194
comptime CM_EVALUATE = 195
comptime CM_CPUWIN = 196
comptime CM_TERMINAL = 197
comptime CM_REPL = 198
comptime CM_REPL_SEND = 199
comptime CM_TESTEXP = 200
comptime CM_TEST_RUN = 201
comptime CM_TEST_RUN_ALL = 202
comptime CM_TEST_LIST = 203
comptime CM_GIT_DIFF = 204          # the diff view of this file's changes
comptime CM_GIT_STAGE = 205         # stage the change at the cursor
comptime CM_GIT_REVERT = 206        # undo the change at the cursor (back to the index's text)
comptime CM_GIT_NEXT = 207          # to the next changed block
comptime CM_GIT_PREV = 208
comptime CM_GIT_STAGED = 209        # the diff view of what is staged
comptime CM_GIT_COMMIT = 210
comptime CM_GIT_BRANCH = 211
comptime CM_GIT_BLAME = 212
comptime CM_AGENT = 213             # the agent panel
comptime CM_AGENT_MENTION = 214     # mention the file or the selection in the prompt
comptime CM_AGENT_START = 215       # start the configured agent (needs folder trust)
comptime CM_THEME_PICK = 216        # Options > Colour theme...
comptime CM_NOTICES = 217           # Help > Notifications
comptime CM_HELP_GUIDE = 218
comptime CM_HELP_CHEAT = 219
comptime CM_HELP_TUTORIAL = 220
comptime CM_HELP_NEW = 221
comptime CM_SCREEN_READER = 222     # Options > Screen-reader mode
comptime CM_HELP_ERRORS = 223       # Help > Error messages
comptime CM_DOCS_PANE = 224         # Help > Docs pane
comptime CM_AGENT_EXPLAIN = 225     # Help > Ask agent about this error
comptime CM_AGENT_EXPLAIN_CODE = 226    # Help > Ask agent about this code
comptime CM_TIPS_OFF = 227          # Help > No more tips
comptime CM_EXERCISES = 228         # Help > Exercises
comptime CM_EX_CHECK = 229          # Help > Exercise done?
comptime CM_HELP_PYTHON = 230       # Help > Coming from Python
comptime CHORD_SHIFT = 32          # a two-key binding is (first key << 32) | second key
comptime CM_ADDNEXT = 110
comptime CM_CURABOVE = 111
comptime CM_CURBELOW = 112
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
    """The hot letter of a '~X~' label as a small letter (any script: "~Ö~ffnen" gives
    ö, "~Ф~айл" ф), or -1. Compare it with `hot_key` of what was typed."""
    var cps = decode(label)
    for i in range(len(cps) - 1):
        if cps[i] == 126:
            return fold_letter(cps[i + 1])
    return -1


def hot_key(k: Int) -> Int:
    """A typed key (Alt or not) as it is compared with `hot_char`."""
    return fold_letter(k & KEY_MASK)


def hot_letter_problem(label: String) -> String:
    """What is wrong with a label's hot letter for someone typing it ("" if nothing):
    none at all, or a letter followed by a combining mark (the key gives the
    precomposed letter, which would never match)."""
    var cps = decode(label)
    for i in range(len(cps) - 1):
        if cps[i] == 126:
            if cps[i + 1] == 126 or cps[i + 1] == 32:
                return "has an empty ~hot letter~"
            if i + 2 < len(cps) and char_width(cps[i + 2]) == 0:
                return "has a hot letter with a separate accent: write it as one character"
            return ""
    return "has no ~hot letter~"


def chord(first: Int, second: Int) -> Int:
    """A two-key binding such as Ctrl-K S: press `first`, then `second`."""
    return (first << CHORD_SHIFT) | second


def chord_first(k: Int) -> Int:
    """The prefix key of a two-key binding (0 for an ordinary key)."""
    return k >> CHORD_SHIFT


def keymap_name(i: Int) -> String:
    if i == 1:
        return "turbo"
    if i == 2:
        return "emacs"
    if i == 3:
        return "vim"
    return "modern"


def keymap_from_name(name: String) -> Int:
    """0 modern, 1 turbo (also "wordstar"), 2 emacs, 3 vim; -1 if unknown."""
    if name == "modern":
        return 0
    if name == "turbo" or name == "wordstar":
        return 1
    if name == "emacs":
        return 2
    if name == "vim":
        return 3
    return -1


def key_name(k: Int) -> String:
    """Human-readable name of a key code, e.g. 'Ctrl-S', 'Alt-F3', 'Shift-Del'; a
    two-key binding reads 'Ctrl-K S'."""
    if chord_first(k) != 0:
        return key_name(chord_first(k)) + " " + key_name(k & ((1 << CHORD_SHIFT) - 1))
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
    """Inverse of key_name(): 'Ctrl-Shift-F5' -> key code, 'Ctrl-K S' -> a two-key
    binding. Returns 0 if not understood."""
    var all = decode(name)
    var sp = -1
    for q in range(len(all)):
        if all[q] == 32:
            sp = q
            break
    if sp > 0 and sp + 1 < len(all):
        var a = parse_key(slice_str(all, 0, sp))
        var b = parse_key(slice_str(all, sp + 1, len(all)))
        if a == 0 or b == 0 or chord_first(a) != 0 or chord_first(b) != 0:
            return 0
        return chord(a, b)
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
    var hidden: List[Int]      # commands that are in no menu on purpose (palette and keys only)
    var ctx_ids: List[Int]     # keys that mean these commands only while a program is
    var ctx_keys: List[Int]    #   being debugged (F7, F8 are other commands otherwise)

    def __init__(out self):
        self.cmds = List[Command]()
        self.menu_titles = List[String]()
        self.layout = List[Placement]()
        self.hidden = List[Int]()
        self.ctx_ids = List[Int]()
        self.ctx_keys = List[Int]()

    def debug_key(mut self, id: Int, k: Int):
        self.ctx_ids.append(id)
        self.ctx_keys.append(k)

    def find_debug_key(self, k: Int) -> Int:
        """The command key k means while debugging (CM_NONE: none)."""
        for i in range(len(self.ctx_keys)):
            if self.ctx_keys[i] == k:
                return self.ctx_ids[i]
        return CM_NONE

    def hide(mut self, id: Int, name: String, title: String, hint: String):
        """A command without a menu entry."""
        self.cmds.append(Command(id, name, title, hint, List[Int]()))
        self.hidden.append(id)

    def is_hidden(self, id: Int) -> Bool:
        for h in self.hidden:
            if h == id:
                return True
        return False

    def is_prefix(self, k: Int) -> Bool:
        """Is k the first key of some two-key binding?"""
        for i in range(len(self.cmds)):
            for b in self.cmds[i].keys:
                if chord_first(b) == k:
                    return True
        return False

    def chord_seconds(self, first: Int) -> List[Int]:
        """The second keys of the two-key bindings that start with `first`, in the
        order of their names (each key once)."""
        var out = List[Int]()
        var names = List[String]()
        for i in range(len(self.cmds)):
            for b in self.cmds[i].keys:
                if chord_first(b) != first:
                    continue
                var s = b & ((1 << CHORD_SHIFT) - 1)
                if s in out:
                    continue
                var nm = key_name(s)
                var at = len(out)
                for j in range(len(out)):
                    if nm < names[j]:
                        at = j
                        break
                out.insert(at, s)
                names.insert(at, nm)
        return out^

    def find_chord(self, first: Int, second: Int) -> Int:
        """The command bound to the two keys. If there is no exact match the second key
        is tried without Ctrl and in lower case, so Ctrl-K Ctrl-S and Ctrl-K S are the
        same unless both are bound."""
        var cmd = self.find_key(chord(first, second))
        if cmd != CM_NONE:
            return cmd
        var base = second & KEY_MASK
        if base >= 65 and base <= 90:
            base += 32
        var plain = (second & ~(MOD_CTRL | KEY_MASK)) | base
        if plain != second:
            return self.find_key(chord(first, plain))
        return CM_NONE

    def bind(mut self, id: Int, k: Int):
        """Give key k to a command, taking it away from whichever command had it. A
        two-key binding also frees its first key, which now only starts the sequence."""
        var first = chord_first(k)
        for i in range(len(self.cmds)):
            var kept = List[Int]()
            for b in self.cmds[i].keys:
                if b == k or (first != 0 and b == first) or (first == 0 and chord_first(b) == k):
                    continue
                kept.append(b)
            self.cmds[i].keys = kept^
        var ci = self.index_of(id)
        if ci >= 0:
            self.cmds[ci].keys.append(k)

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
        if i >= 0 and len(self.cmds[i].keys) == 0:
            for j in range(len(self.ctx_ids)):
                if self.ctx_ids[j] == id:
                    return key_name(self.ctx_keys[j])
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


def apply_keymap(mut r: Registry, which: Int):
    """Change the default (modern) bindings into another classic set. Keys the map needs
    are taken from the commands that had them; those keep their other keys."""
    if which == 1:
        # Turbo / WordStar: the cursor diamond, and Ctrl-K / Ctrl-Q sequences
        r.bind(CM_CUR_LEFT, ctrl(115))
        r.bind(CM_CUR_RIGHT, ctrl(100))
        r.bind(CM_CUR_UP, ctrl(101))
        r.bind(CM_CUR_DOWN, ctrl(120))
        r.bind(CM_CUR_WORD_LEFT, ctrl(97))
        r.bind(CM_CUR_WORD_RIGHT, ctrl(102))
        r.bind(CM_CUR_PAGE_UP, ctrl(114))
        r.bind(CM_CUR_PAGE_DOWN, ctrl(99))
        r.bind(CM_DEL_CHAR, ctrl(103))
        r.bind(CM_DEL_WORD, ctrl(116))
        r.bind(CM_DELLINE, ctrl(121))
        r.bind(CM_SCROLL_UP, ctrl(119))
        r.bind(CM_SCROLL_DOWN, ctrl(122))
        r.bind(CM_INSERT_MODE, ctrl(118))
        r.bind(CM_REDO, KEY_BACKSPACE | MOD_ALT | MOD_SHIFT)
        var k = ctrl(107)
        r.bind(CM_SAVE, chord(k, 115))
        r.bind(CM_SAVE, chord(k, 100))
        r.bind(CM_QUIT, chord(k, 120))
        r.bind(CM_CLOSE, chord(k, 113))
        r.bind(CM_COPY, chord(k, 99))
        r.bind(CM_PASTE, chord(k, 118))
        r.bind(CM_CLEAR, chord(k, 121))
        r.bind(CM_INDENT, chord(k, 105))
        r.bind(CM_UNINDENT, chord(k, 117))
        r.bind(CM_OPEN, chord(k, 114))
        r.bind(CM_SAVEAS, chord(k, 119))
        r.bind(CM_ADDNEXT, chord(k, 116))
        var q = ctrl(113)
        r.bind(CM_FIND, chord(q, 102))
        r.bind(CM_REPLACE, chord(q, 97))
        r.bind(CM_CUR_TOP, chord(q, 114))
        r.bind(CM_CUR_BOTTOM, chord(q, 99))
        r.bind(CM_CUR_LINE_START, chord(q, 115))
        r.bind(CM_CUR_LINE_END, chord(q, 100))
        r.bind(CM_KILL_LINE, chord(q, 121))
        r.bind(CM_MATCH, chord(q, 91))
        r.bind(CM_MATCH, chord(q, 93))
        r.bind(CM_GOTO, chord(q, 103))
        r.bind(CM_SELALL, chord(q, 98))
        # Ctrl-O: the editor's options, as Turbo's (Ctrl-O I: auto-indent on / off)
        r.bind(CM_AUTOINDENT, chord(ctrl(111), 105))
    elif which == 2:
        # Emacs, the common subset
        r.bind(CM_CUR_LINE_START, ctrl(97))
        r.bind(CM_CUR_LINE_END, ctrl(101))
        r.bind(CM_CUR_RIGHT, ctrl(102))
        r.bind(CM_CUR_LEFT, ctrl(98))
        r.bind(CM_CUR_DOWN, ctrl(110))
        r.bind(CM_CUR_UP, ctrl(112))
        r.bind(CM_DEL_CHAR, ctrl(100))
        r.bind(CM_KILL_LINE, ctrl(107))
        r.bind(CM_PASTE, ctrl(121))
        r.bind(CM_CUT, ctrl(119))
        r.bind(CM_FIND, ctrl(115))
        r.bind(CM_CUR_PAGE_DOWN, ctrl(118))
        r.bind(CM_CUR_PAGE_UP, alt(118))
        r.bind(CM_UNDO, ctrl(47))
        r.bind(CM_CUR_TOP, alt(60))
        r.bind(CM_CUR_BOTTOM, alt(62))
        r.bind(CM_DEL_WORD, alt(100))
        r.bind(CM_PALETTE, alt(120))
        var x = ctrl(120)
        r.bind(CM_SAVE, chord(x, ctrl(115)))
        r.bind(CM_OPEN, chord(x, ctrl(102)))
        r.bind(CM_QUIT, chord(x, ctrl(99)))
        r.bind(CM_SAVEAS, chord(x, ctrl(119)))
        r.bind(CM_SAVEALL, chord(x, 115))
        r.bind(CM_CLOSE, chord(x, 107))
        r.bind(CM_UNDO, chord(x, 117))
        r.bind(CM_SELALL, chord(x, 104))
        r.bind(CM_NEXTWIN, chord(x, 111))
        r.bind(CM_WINLIST, chord(x, 98))


def build_registry() -> Registry:
    var r = Registry()
    # ---- cursor commands (no menu entries; bound by the Turbo and Emacs keymaps)
    r.hide(CM_CUR_LEFT, "cursor.left", "Cursor left", "Move the cursor one character left")
    r.hide(CM_CUR_RIGHT, "cursor.right", "Cursor right", "Move the cursor one character right")
    r.hide(CM_CUR_UP, "cursor.up", "Cursor up", "Move the cursor one line up")
    r.hide(CM_CUR_DOWN, "cursor.down", "Cursor down", "Move the cursor one line down")
    r.hide(CM_CUR_WORD_LEFT, "cursor.wordLeft", "Cursor word left", "Move the cursor to the previous word")
    r.hide(CM_CUR_WORD_RIGHT, "cursor.wordRight", "Cursor word right", "Move the cursor to the next word")
    r.hide(CM_CUR_LINE_START, "cursor.lineStart", "Cursor to line start", "Move the cursor to the start of the line")
    r.hide(CM_CUR_LINE_END, "cursor.lineEnd", "Cursor to line end", "Move the cursor to the end of the line")
    r.hide(CM_CUR_PAGE_UP, "cursor.pageUp", "Cursor page up", "Move the cursor one page up")
    r.hide(CM_CUR_PAGE_DOWN, "cursor.pageDown", "Cursor page down", "Move the cursor one page down")
    r.hide(CM_CUR_TOP, "cursor.top", "Cursor to top", "Move the cursor to the start of the text")
    r.hide(CM_CUR_BOTTOM, "cursor.bottom", "Cursor to bottom", "Move the cursor to the end of the text")
    r.hide(CM_DEL_CHAR, "edit.deleteChar", "Delete character", "Delete the character under the cursor")
    r.hide(CM_DEL_WORD, "edit.deleteWordRight", "Delete word right", "Delete from the cursor to the start of the next word")
    r.hide(CM_KILL_LINE, "edit.killLine", "Cut to end of line", "Cut from the cursor to the end of the line")
    r.hide(CM_SCROLL_UP, "view.scrollUp", "Scroll up", "Scroll the text one line up")
    r.hide(CM_SCROLL_DOWN, "view.scrollDown", "Scroll down", "Scroll the text one line down")
    r.hide(CM_INSERT_MODE, "edit.toggleInsertMode", "Insert / overwrite", "Switch between insert and overwrite mode")
    # ---- File
    r.cmd(CM_NEW, "file.new", "~N~ew", "Create a new edit window", [ctrl(110)])
    r.cmd(CM_NEW_PROJECT, "file.newProject", "Ne~w~ project...", "Make a Mojo project: pixi.toml, hello.mojo and a test, then pixi install")
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
    r.cmd(CM_ADDNEXT, "edit.addNextOccurrence", "Add ~n~ext occurrence", "Select the word, then add a cursor at its next occurrence", [alt(100)])
    r.cmd(CM_SKIPNEXT, "edit.skipNextOccurrence", "S~k~ip occurrence", "Move the last multi-cursor match to the next occurrence", [alt(107)])
    r.cmd(CM_SELECT_ALL_OCC, "edit.selectAllOccurrences", "Select e~v~ery occurrence", "Select every occurrence of the word or selection across the buffer", [alt(100) | MOD_SHIFT])
    r.cmd(CM_EXPAND_SEL, "edit.expandSelection", "Expand ~s~election", "Expand selection outward: word, quotes/brackets, line, indented block", [KEY_RIGHT | MOD_ALT | MOD_SHIFT])
    r.cmd(CM_SHRINK_SEL, "edit.shrinkSelection", "S~h~rink selection", "Shrink selection back to the previous range", [KEY_LEFT | MOD_ALT | MOD_SHIFT])
    r.cmd(CM_CURABOVE, "edit.addCursorAbove", "Add cursor a~b~ove", "Add a cursor on the line above", [KEY_UP | MOD_CTRL | MOD_ALT, KEY_UP | MOD_SHIFT | MOD_ALT])
    r.cmd(CM_CURBELOW, "edit.addCursorBelow", "Add cursor b~e~low", "Add a cursor on the line below", [KEY_DOWN | MOD_CTRL | MOD_ALT, KEY_DOWN | MOD_SHIFT | MOD_ALT])
    r.cmd(CM_FOLD, "edit.toggleFold", "~F~old or unfold", "Hide or show the indented block at the cursor", [alt(45)])
    r.cmd(CM_FOLDALL, "edit.foldAll", "F~o~ld all", "Hide every indented block")
    r.cmd(CM_UNFOLDALL, "edit.unfoldAll", "E~x~pand all", "Show all folded blocks", [alt(61)])
    r.cmd(CM_INDENT, "text.indentLines", "~I~ndent lines", "Indent the current line or the selected lines one level")
    r.cmd(CM_UNINDENT, "text.unindentLines", "U~n~indent lines", "Remove one level of indentation from the current or selected lines")
    r.cmd(CM_MACRO_REC, "macro.record", "~R~ecord macro / stop", "Start recording keystrokes, or stop and keep them", [fkey(5) | MOD_CTRL])
    r.cmd(CM_MACRO_PLAY, "macro.play", "Pla~y~ macro", "Repeat the recorded keystrokes", [fkey(6) | MOD_CTRL])
    r.cmd(CM_LINEUP, "text.moveLineUp", "Move line ~u~p", "Move the current line or the selected lines up", [KEY_UP | MOD_ALT])
    r.cmd(CM_LINEDOWN, "text.moveLineDown", "Move line ~d~own", "Move the current line or the selected lines down", [KEY_DOWN | MOD_ALT])
    r.cmd(CM_JOIN, "text.joinLines", "~J~oin lines", "Join the next line (or the selected lines) onto this one", [alt(106)])
    r.cmd(CM_SORT, "text.sortLines", "~S~ort lines", "Sort the selected lines (or all lines) in ascending order")
    r.cmd(CM_UPPER, "text.upperCase", "U~p~per case", "Make the selection or the word at the cursor upper case", [alt(117)])
    r.cmd(CM_LOWER, "text.lowerCase", "~L~ower case", "Make the selection or the word at the cursor lower case", [alt(108)])
    r.cmd(CM_DELLINE, "edit.deleteLine", "Delete l~i~ne", "Delete the current line", [ctrl(107)])
    r.cmd(CM_COMPLETE, "edit.complete", "Complete ~w~ord", "Complete the identifier under the cursor", [ctrl(32)])
    # ---- Search
    r.cmd(CM_FIND, "search.find", "~F~ind...", "Search for text", [ctrl(102)])
    r.cmd(CM_REPLACE, "search.replace", "~R~eplace...", "Search for text and replace it", [ctrl(114)])
    r.cmd(CM_AGAIN, "search.again", "~S~earch again", "Repeat the last Find or Replace", [ctrl(108)])
    r.cmd(CM_FINDFILES, "search.findInFiles", "Find in f~i~les...", "Search every file of the project folder", [fkey(3) | MOD_SHIFT])
    r.cmd(CM_REPLACEFILES, "search.replaceInFiles", "Replace in fi~l~es...", "Search and replace across project files with diff preview and single-step Undo", [fkey(4) | MOD_SHIFT, ctrl(104) | MOD_SHIFT])
    r.cmd(CM_GOTO, "search.gotoLine", "~G~o to line number...", "Move the cursor to a line number", [ctrl(103)])
    r.cmd(CM_SYMBOL, "search.gotoSymbol", "Go to s~y~mbol...", "Jump to a def / struct / trait in this file", [ctrl(116)])
    r.cmd(CM_WSYMBOL, "search.gotoProjectSymbol", "Go to symbol in pro~j~ect...", "Jump to a def / struct / trait in any Mojo file of the project", [fkey(12) | MOD_ALT])
    r.cmd(CM_HOVER, "search.describeSymbol", "~D~escribe symbol", "Show what the language server knows about the symbol at the cursor", [alt(105)])
    r.cmd(CM_DEFINITION, "search.goToDefinition", "Go to d~e~finition", "Go to where the symbol at the cursor is defined", [fkey(12)])
    r.cmd(CM_TYPEDEF, "search.goToTypeDefinition", "Go to type definiti~o~n", "Jump to the definition of the type of the symbol at the cursor")
    r.cmd(CM_REFERENCES, "search.findReferences", "Find referen~c~es", "List every use of the symbol at the cursor", [fkey(12) | MOD_SHIFT])
    r.cmd(CM_RENAME, "edit.renameSymbol", "Ren~a~me symbol...", "Rename the symbol at the cursor everywhere it is used", [fkey(2) | MOD_SHIFT])
    r.cmd(CM_ACTIONS, "edit.quickFix", "Quick fi~x~...", "Fixes and changes the language server offers for this place", [KEY_ENTER | MOD_ALT])
    r.cmd(CM_BACK, "search.back", "~B~ack", "Return to where the cursor was before the last jump", [alt(44)])
    r.cmd(CM_FORWARD, "search.forward", "For~w~ard", "Go forward again after going back", [alt(46)])
    r.cmd(CM_SIGNATURE, "search.parameterInfo", "Parame~t~er info", "Show the parameters of the call the cursor is in", [alt(112)])
    r.cmd(CM_MATCH, "search.matchBracket", "~M~atch bracket", "Jump to the matching bracket", [ctrl(93)])
    r.cmd(CM_PALETTE, "view.commandPalette", "~C~ommand palette...", "Fuzzy-search every IDE command (the palette, starting with >)", [ctrl(112)])
    r.cmd(CM_QUICK, "file.quickOpen", "~G~o to file...", "The palette: files by name; > commands, @ symbols, # project symbols, : line", [alt(103)])
    # ---- Run
    r.cmd(CM_RUN, "run.run", "~R~un", "Run the current program with `mojo run`", [fkey(9) | MOD_CTRL, fkey(8)])
    r.cmd(CM_DEBUG, "run.debug", "~D~ebug", "Build with debug information and run under the debugger; continues a stopped program", [fkey(5) | MOD_SHIFT])
    r.cmd(CM_STEP_INTO, "debug.stepInto", "Trace ~i~nto", "While debugging: one line, into the functions it calls")
    r.cmd(CM_STEP_OVER, "debug.stepOver", "St~e~p over", "While debugging: one line, over the functions it calls")
    r.cmd(CM_STEP_OUT, "debug.stepOut", "~S~tep out", "While debugging: run to the end of this function", [fkey(8) | MOD_SHIFT])
    r.cmd(CM_RUN_CURSOR, "debug.runToCursor", "~G~o to cursor", "Run (or debug) until the program reaches the cursor's line", [fkey(4)])
    r.cmd(CM_PAUSE, "debug.pause", "Pause t~h~e program", "Stop the program being debugged where it is")
    r.cmd(CM_RESET, "debug.reset", "Reset progra~m~", "End the program being debugged")
    r.debug_key(CM_STEP_INTO, fkey(7))
    r.debug_key(CM_STEP_OVER, fkey(8))
    r.debug_key(CM_PAUSE, fkey(5) | MOD_SHIFT)
    r.debug_key(CM_RESET, fkey(2) | MOD_CTRL)
    r.cmd(CM_DEBUGWIN, "debug.window", "Call stac~k~ and variables", "Show or hide the Debug window: the call stack and the variables of the stopped program", [fkey(3) | MOD_CTRL])
    r.cmd(CM_WATCH_ADD, "debug.addWatch", "Add ~w~atch...", "Watch a variable or field (a, a.b): its value is shown at every stop", [fkey(7) | MOD_CTRL])
    r.cmd(CM_EVALUATE, "debug.evaluate", "E~v~aluate...", "Evaluate a name, or run a debugger command (a line starting with :), while the program is stopped", [fkey(4) | MOD_CTRL])
    r.cmd(CM_DEBUG_GPU_LANE, "debug.gpuLane", "GPU ~y~/x/z thread...", "Switch debugger focus to a GPU block (x,y,z) and thread/lane (x,y,z)")
    r.cmd(CM_CPUWIN, "debug.cpu", "CPU - mac~h~ine code, registers, memory", "Machine code, registers and memory of the stopped program; F7/F8 there step one instruction", [fkey(2) | MOD_ALT])
    r.cmd(CM_BP_TOGGLE, "debug.toggleBreakpoint", "Toggle ~b~reakpoint", "Set or remove a breakpoint on the cursor's line (also: click the line number)", [fkey(8) | MOD_CTRL])
    r.cmd(CM_BP_EDIT, "debug.editBreakpoint", "Breakpoint c~o~ndition...", "Condition, hit count and log message of the breakpoint on this line (sets one if there is none)")
    r.cmd(CM_BP_FUNC, "debug.functionBreakpoint", "~F~unction breakpoint...", "Stop when a function is entered, by its name")
    r.cmd(CM_BP_LIST, "debug.breakpoints", "Break~p~oints...", "All breakpoints: go to, edit, switch off, delete")
    r.cmd(CM_BP_CLEAR, "debug.removeAllBreakpoints", "Remove all breakpoi~n~ts", "Delete every breakpoint of the project")
    r.cmd(CM_REPL, "run.repl", "Mo~j~o REPL", "Start `mojo repl` in a window at the bottom (again: close the window); Ctrl-F10 in the editor sends the selection or line")
    r.hide(CM_REPL_SEND, "run.sendToRepl", "Send to REPL", "Send the selection or the line to the REPL (it is started if needed)")
    r.bind(CM_REPL_SEND, fkey(10) | MOD_CTRL)
    r.cmd(CM_TESTEXP, "run.testExplorer", "Test e~x~plorer", "The project's TestSuite files and their tests: run them, see what failed and where")
    r.hide(CM_TEST_RUN, "tests.run", "Run tests", "Run the test file or the test marked in the test explorer")
    r.hide(CM_TEST_RUN_ALL, "tests.runAll", "Run all tests", "Run every test file of the project")
    r.hide(CM_TEST_LIST, "tests.list", "List tests", "Ask the test programs for their tests (--skip-all)")
    r.cmd(CM_GIT_STATUS, "git.status", "Git stat~u~s", "Multi-file git status panel: stage, unstage, diff, commit, branch and stash")
    r.cmd(CM_GIT_DIFF, "git.diff", "~D~iff of this file", "This file's changes against git's index: stage, revert (and unstage, on the staged side) one change at a time")
    r.cmd(CM_GIT_STAGE, "git.stageChange", "S~t~age change", "Put the changed block at the cursor into git's index (git add, for just that block)")
    r.cmd(CM_GIT_REVERT, "git.revertChange", "~R~evert change", "Make the changed block at the cursor as it is in git's index again (Undo brings it back)")
    r.cmd(CM_GIT_NEXT, "git.nextChange", "Ne~x~t change", "To the next block that differs from git's index", [alt(110)])
    r.cmd(CM_GIT_PREV, "git.previousChange", "Pre~v~ious change", "To the previous block that differs from git's index", [alt(98)])
    r.hide(CM_GIT_STAGED, "git.diffStaged", "Diff of staged changes", "What is staged of this file: its index against HEAD")
    r.cmd(CM_AGENT, "agent.panel", "Agent ~p~anel", "Talk to a coding agent (ACP) at the right edge; again: back to the editor or close it", [fkey(11) | MOD_CTRL])
    r.hide(CM_AGENT_MENTION, "agent.mention", "Mention in agent prompt", "Put the selection (or this file) into the agent's prompt as @file:lines")
    r.bind(CM_AGENT_MENTION, fkey(11) | MOD_SHIFT)    # (not in a menu: no letter left in File)
    r.hide(CM_AGENT_START, "agent.start", "Start the agent", "Start the coding agent named by tools.agent")
    r.cmd(CM_AGENT_MODEL, "agent.model", "Agent ~m~odel...", "Choose which model the coding agent uses")
    r.cmd(CM_AGENT_MODE, "agent.mode", "Agent m~o~de...", "Choose whether the coding agent asks first, accepts edits, or runs automatically")
    r.cmd(CM_AGENT_THINKING, "agent.thinking", "Agent ~t~hinking...", "Choose the coding agent's thinking level")
    r.cmd(CM_AGENT_NEW, "agent.newSession", "~N~ew agent session", "Start a fresh coding agent conversation for this project")
    r.cmd(CM_AGENT_PROBLEMS, "agent.sendProblems", "Send ~d~iagnostics to agent", "Send all current language server, build, and test problems to the coding agent")
    r.cmd(CM_AGENT_REVERT, "agent.revertTurn", "Re~v~ert last agent turn", "Restore files modified or created by the last coding agent turn")
    r.cmd(CM_GIT_COMMIT, "git.commit", "Comm~i~t...", "Commit what is staged (or every change to tracked files) with a message")
    r.cmd(CM_GIT_BRANCH, "git.branch", "~B~ranch...", "Switch to another branch of the repository, or make a new one")
    r.cmd(CM_GIT_BLAME, "git.blame", "Blam~e~", "Who last changed each line of this file, when, and in which commit")
    r.hide(CM_GIT_STASH, "git.stash", "Git: Stash changes", "Save uncommitted changes (including untracked files) on git's stash stack")
    r.hide(CM_GIT_STASH_POP, "git.stashPop", "Git: Pop stash", "Apply and remove the latest git stash entry")
    r.cmd(CM_CONFLICT_NEXT, "git.nextConflict", "Next ~u~nresolved conflict", "Jump to the next <<<<<<< merge conflict marker in this file")
    r.hide(CM_CONFLICT_OURS, "git.acceptOurs", "Git: Accept current change (ours)", "Resolve the merge conflict at the cursor by keeping the current branch's lines")
    r.hide(CM_CONFLICT_THEIRS, "git.acceptTheirs", "Git: Accept incoming change (theirs)", "Resolve the merge conflict at the cursor by keeping the incoming branch's lines")
    r.hide(CM_CONFLICT_BOTH, "git.acceptBoth", "Git: Accept both changes", "Resolve the merge conflict at the cursor by keeping both branches' lines")
    r.cmd(CM_GIT_LINEBLAME, "git.lineBlame", "Inline ~y~ear/author blame", "Show dimmed git blame author, date and summary at the end of the cursor's line")
    r.cmd(CM_TEST, "run.test", "~T~est", "Run this file's TestSuite (std.testing) with `mojo run`")
    r.cmd(CM_TEST_CURSOR, "run.testAtCursor", "~Q~uick-run test at cursor", "Run the enclosing def test_* function at the cursor with --only")
    r.cmd(CM_USERSCREEN, "run.userScreen", "~U~ser screen", "View the program's output screen", [fkey(5) | MOD_ALT])
    r.cmd(CM_TASKS, "run.pixiTasks", "Pixi tas~k~s...", "Run a task of the project's pixi.toml", [fkey(9) | MOD_SHIFT])
    r.cmd(CM_TASK_AGAIN, "run.lastTask", "Run ~l~ast task", "Run the pixi task that was run last, again")
    r.cmd(CM_RUNCONFIGS, "run.configurations", "Run ~c~onfigurations...", "Named ways to run the project: file, arguments, environment, folder, build first")
    r.cmd(CM_ARGS, "run.arguments", "~A~rguments...", "Set command-line arguments for Run")
    # ---- Compile
    r.cmd(CM_BUILD, "compile.build", "~B~uild", "Compile the current file to a native executable", [fkey(9), ctrl(98)])
    r.cmd(CM_FORMAT, "compile.format", "~F~ormat source", "Reformat the current file with `mojo format`", [fkey(9) | MOD_ALT])
    r.cmd(CM_CODEGEN, "compile.inspectCodegen", "~I~nspect generated code", "Emit assembly or LLVM IR with SIMD vectorization and stack-spill badges")
    r.cmd(CM_GPU_PROFILE, "compile.profileGpu", "Profile ~G~PU kernels", "Profile GPU kernels with nsys or rocprofv3 into the Message window")
    r.cmd(CM_MAX_SERVE, "run.maxServe", "~M~AX serve / benchmark...", "Launch max serve or max benchmark for a MAX project or Hugging Face model")
    r.cmd(CM_RUN_CELL, "run.codeCell", "~R~un code cell (# %%)", "Execute the # %% interactive code cell at the cursor with prior definitions", [KEY_ENTER | MOD_CTRL])
    r.hide(CM_RUN_CELL_NEXT, "run.codeCellAndAdvance", "Run code cell and advance (# %%)", "Execute the # %% code cell at the cursor and jump to the next cell")
    r.bind(CM_RUN_CELL_NEXT, KEY_ENTER | MOD_CTRL | MOD_SHIFT)
    r.cmd(CM_NEXTERR, "compile.nextMessage", "~N~ext message", "Jump to the next compiler message", [fkey(8) | MOD_ALT])
    r.cmd(CM_PREVERR, "compile.previousMessage", "~P~revious message", "Jump to the previous compiler message", [fkey(7) | MOD_ALT])
    r.cmd(CM_CANCEL, "compile.cancel", "C~a~ncel build", "Stop the running build or format", [fkey(2) | MOD_CTRL])
    r.cmd(CM_LSP, "compile.languageServer", "Check with ~l~anguage server", "Live diagnostics from mojo-lsp-server for this file (again to stop)", [fkey(7)])
    r.cmd(CM_TRUST, "options.folderTrust", "~F~older trust...", "Say whether commands and code from this project folder may be run")
    r.cmd(CM_COMPILER, "compile.compilerCommand", "~C~ompiler command...", "Choose which mojo executable to use")
    # ---- Options
    r.cmd(CM_LINENUM, "options.lineNumbers", "~L~ine numbers", "Toggle the line number gutter")
    r.cmd(CM_RELNUM, "options.relativeNumbers", "Relative num~b~ers", "Number the lines from the cursor's (the vim preset has it)")
    r.cmd(CM_AUTOINDENT, "options.autoIndent", "~A~uto indent", "Toggle smart auto indentation")
    r.cmd(CM_HLLINE, "options.highlightLine", "~H~ighlight line", "Toggle current line highlighting")
    r.cmd(CM_GPU_STATUS, "options.gpuStatus", "~G~PU in the status line", "Show the GPU your programs run on (asked once, in the background)")
    r.cmd(CM_CLOCK, "options.clock", "Cl~o~ck", "Toggle the menu bar clock")
    r.cmd(CM_SHOWWS, "options.showWhitespace", "Show ~w~hitespace", "Show tab characters as arrows")
    r.cmd(CM_SEMANTIC, "options.semanticColours", "Semant~i~c colours", "Colour names by what the language server says they are")
    r.cmd(CM_QUIET, "options.quietColours", "~Q~uiet code colours", "Four code colours - text, comments, strings, definitions - so that errors, search hits and the current line stand out most")
    r.cmd(CM_HINTS, "options.inlayHints", "Inlay hi~n~ts", "Show the language server's notes (inferred types, parameter names) after each line")
    r.cmd(CM_WRAP, "options.softWrap", "Soft w~r~ap", "Continue long lines on the next screen row instead of scrolling sideways", [alt(122)])
    r.cmd(CM_USETABS, "options.indentWithTabs", "Indent with ~t~abs", "Tab key and auto-indent use tab characters (auto-detected)")
    r.cmd(CM_CRLF, "options.crlf", "CRLF line ~e~ndings", "Save the file with Windows line endings (auto-detected)")
    r.cmd(CM_KEYMAP0, "options.keymapModern", "Keys: Mo~d~ern", "Ctrl-S, Ctrl-C/V, Ctrl-F... as in current editors")
    r.cmd(CM_KEYMAP1, "options.keymapTurbo", "Keys: T~u~rbo / WordStar", "The cursor diamond and Ctrl-K / Ctrl-Q sequences of Turbo's editor")
    r.cmd(CM_KEYMAP2, "options.keymapEmacs", "Keys: Emac~s~", "Ctrl-A/E/F/B/N/P, Ctrl-K, Ctrl-Y and Ctrl-X sequences")
    r.cmd(CM_KEYMAP3, "options.keymapVim", "Keys: ~V~im", "Normal, Insert and Visual modes, as in vim; Ctrl, Alt and F-keys stay TurboMojo's")
    r.hide(CM_THEME0, "options.themeClassic", "Theme: Turbo Classic", "The 1992 CGA blue look")
    r.hide(CM_THEME1, "options.themeMidnight", "Theme: Midnight Neon", "A modern dark truecolor theme")
    r.hide(CM_THEME2, "options.themeAmber", "Theme: Amber CRT", "Phosphor monochrome terminal")
    r.cmd(CM_HELP_GUIDE, "help.guide", "TurboMojo ~g~uide", "How TurboMojo works: windows, editing, Mojo, git, agents, settings")
    r.cmd(CM_HELP_CHEAT, "help.cheatSheet", "~C~heat sheet", "The keys used most")
    r.cmd(CM_HELP_TUTORIAL, "help.tutorial", "T~u~torial", "A file to practise in: lessons on moving, selecting, finding, running and debugging")
    r.cmd(CM_HELP_ERRORS, "help.errors", "~E~rror messages", "What the Mojo compiler's frequent error messages mean and how to fix them (F1 on a problem explains it)")
    r.cmd(CM_EXERCISES, "help.exercises", "E~x~ercises...", "Practice: small Mojo programs that are wrong until you fix them (Rustlings style)")
    r.cmd(CM_EX_CHECK, "help.exerciseDone", "Exercise ~d~one?", "Run the exercise or GPU puzzle in front and say whether it is right now")
    r.cmd(CM_TIPS_OFF, "help.noMoreTips", "No more t~i~ps", "Stop the tips that name a quicker way after a slow one (ui.tips)")
    r.cmd(CM_HELP_PYTHON, "help.comingFromPython", "Coming from P~y~thon", "What is different in Mojo for a Python programmer, and the keys next to VS Code's")
    r.cmd(CM_HELP_NEW, "help.whatsNew", "W~h~at's new", "What changed in this version of TurboMojo")
    r.cmd(CM_NOTICES, "help.notifications", "~N~otifications...", "What is running now and the messages of this session (builds, tests, git, the agent)", [fkey(10) | MOD_SHIFT])
    r.cmd(CM_SCREEN_READER, "options.screenReader", "Screen-reader ~m~ode", "A plain, linear screen for screen readers: no frames or shading, the cursor on what has the focus, no animation")
    r.cmd(CM_PRESETS, "options.presets", "~P~resets...", "Turbo (the blue desktop, overlapping windows), Modern (terminal colours, panes, the explorer) or Vim (Modern with vim's keys) in one choice")
    r.cmd(CM_THEME_PICK, "options.theme", "~C~olour theme...", "Choose a colour theme (built in, or a file in ~/.config/turbomojo/themes), or follow the terminal's light / dark; each shows as you move through the list")
    r.cmd(CM_PIXI_ENV, "options.pixiEnvironment", "Pi~x~i environment...", "Select which Pixi environment builds, runs, tests, formatting, terminal, debugger and LSP use")
    r.hide(CM_FORMAT_SAVE, "options.formatOnSave", "Format on save", "Reformat Mojo files automatically with mojo format when saving")
    r.hide(CM_INDENT_GUIDES, "options.indentGuides", "Indent guides", "Show subtle vertical guides on indentation columns")
    # ---- Window
    r.cmd(CM_ZOOM, "window.zoom", "~Z~oom", "Enlarge the active window: half, full, back as it was", [fkey(5)])
    r.cmd(CM_TILE, "window.tile", "~T~ile", "Arrange windows side by side")
    r.cmd(CM_CASCADE, "window.cascade", "C~a~scade", "Stack windows on top of each other")
    r.cmd(CM_NEXTWIN, "window.next", "~N~ext", "Go to the window used last (again in a row: further back)", [fkey(6)])
    r.cmd(CM_PREVWIN, "window.previous", "~P~revious", "Back along the windows F6 went through; alone, the window used least lately", [fkey(6) | MOD_SHIFT])
    r.cmd(CM_CLOSEALL, "window.closeAll", "Clos~e~ all", "Close all windows")
    r.cmd(CM_MESSAGE, "window.message", "~M~essage", "Open the bottom panel on the compiler's and the program's output")
    r.cmd(CM_SEARCHRES, "window.searchResults", "Sea~r~ch results", "Open the bottom panel on the last search results or list of places")
    r.cmd(CM_PROBLEMS, "window.problems", "Problems l~i~st", "Open the bottom panel on the problems the language server reports")
    r.cmd(CM_TILED, "window.tiledLayout", "Tiled la~y~out", "Panes with tabs that share the screen, instead of overlapping windows")
    r.cmd(CM_SPLIT_RIGHT, "window.splitRight", "Split ri~g~ht", "Move this file into a new pane to the right", [alt(92)])
    r.cmd(CM_SPLIT_DOWN, "window.splitDown", "Split ~d~own", "Move this file into a new pane below", [alt(124)])
    r.cmd(CM_CLONE_VIEW, "window.cloneView", "Split ~j~oint view", "Open a second synchronized view of this file in a split pane")
    r.cmd(CM_NEXT_PANE, "window.nextPane", "Ne~x~t pane", "Go to the next pane", [fkey(6) | MOD_ALT])
    r.cmd(CM_NEXT_TAB, "window.nextTab", "Next ta~b~", "Show the next file of this pane", [KEY_PGDN | MOD_ALT])
    r.cmd(CM_PREV_TAB, "window.previousTab", "Previo~u~s tab", "Show the previous file of this pane", [KEY_PGUP | MOD_ALT])
    r.cmd(CM_MOVE_TAB, "window.moveTab", "Mo~v~e to next pane", "Move this file to the next pane")
    r.cmd(CM_PANE_GROW, "window.growPane", "Gro~w~ pane", "Make this pane larger", [alt(125)])
    r.cmd(CM_PANE_SHRINK, "window.shrinkPane", "~S~hrink pane", "Make this pane smaller", [alt(123)])
    r.cmd(CM_EXPLORER, "window.explorer", "~F~ile explorer", "Show the project's files as a tree at the left edge (again: close it)", [ctrl(101)])
    r.cmd(CM_TERMINAL, "window.terminal", "Ter~m~inal", "A shell in a window at the bottom (again: back to the editor or close it)", [fkey(11) | MOD_ALT])
    r.cmd(CM_OUTLINE, "window.outline", "~O~utline", "Show or hide the outline of the file: its functions, structs and traits", [fkey(12) | MOD_CTRL])
    r.cmd(CM_GPU_WIN, "window.gpuMonitor", "GPU ~q~ueue & monitor", "Show or hide live GPU compute/VRAM utilization, sensors and active processes")
    r.cmd(CM_WINLIST, "window.list", "~L~ist...", "Show a list of open windows", [alt(48)])
    # ---- Help / system
    r.cmd(CM_HELP, "help.keyboard", "~K~eyboard reference", "Show the keyboard reference", [fkey(1)])
    r.cmd(CM_DOCS, "help.topicSearch", "~T~opic search", "Show the documentation of the name at the cursor", [fkey(1) | MOD_CTRL])
    r.cmd(CM_DOCS_PANE, "help.docsPane", "Docs ~p~ane", "Show the documentation of the name at the cursor beside the code, following the cursor (again: close it)")
    r.cmd(CM_AGENT_EXPLAIN, "agent.explainError", "Ask agent about this e~r~ror", "Ask the coding agent about the problem here, with the code, the explanation and the documentation pages that fit")
    r.cmd(CM_AGENT_EXPLAIN_CODE, "agent.explainCode", "Ask agent about this c~o~de", "Ask the coding agent to explain the selection (or the function the cursor is in), with the documentation pages that fit")
    r.cmd(CM_MOJODOCS, "help.mojoDocs", "~M~ojo documentation", "Read the Mojo manual, reference, standard library, examples and courses", [fkey(1) | MOD_SHIFT])
    r.cmd(CM_DOCFIND, "help.findInDocs", "~F~ind in documentation...", "Search the Mojo documentation: words, phrases, standard library names, headings, code", [fkey(1) | MOD_ALT])
    r.cmd(CM_DOCFETCH, "help.downloadDocs", "Do~w~nload documentation...", "Download or update the Mojo documentation from Modular's public repositories")
    r.cmd(CM_SETUP, "help.checkSetup", "Check ~s~etup...", "Is everything TurboMojo uses there? Mojo, pixi, the language server, the debugger, docs, the terminal")
    r.cmd(CM_REPORT, "help.reportProblem", "Report a pro~b~lem...", "A ready-to-file issue text (versions, the terminal, the last crash, your settings without secrets) - nothing is sent")
    r.cmd(CM_ABOUT, "help.about", "~A~bout...", "Show version and credits")
    r.cmd(CM_REFRESH, "view.repaint", "~R~epaint desktop", "Redraw the whole screen")

    # ---- menu layout
    r.menu("~≡~")
    r.item(CM_ABOUT)
    r.item(CM_PALETTE)
    r.sep()
    r.item(CM_AGENT_MODEL)
    r.item(CM_AGENT_MODE)
    r.item(CM_AGENT_THINKING)
    r.item(CM_AGENT_NEW)
    r.item(CM_AGENT_PROBLEMS)
    r.item(CM_AGENT_REVERT)
    r.sep()
    r.item(CM_REFRESH)

    r.menu("~F~ile")
    r.item(CM_NEW)
    r.item(CM_NEW_PROJECT)
    r.item(CM_OPEN)
    r.item(CM_SAVE)
    r.item(CM_SAVEAS)
    r.item(CM_SAVEALL)
    r.sep()
    r.item(CM_QUICK)
    r.item(CM_CLOSE)
    r.item(CM_TERMINAL)
    r.item(CM_SHELL)
    r.sep()
    r.item(CM_GIT_STATUS)
    r.item(CM_GIT_DIFF)
    r.item(CM_GIT_STAGE)
    r.item(CM_GIT_REVERT)
    r.item(CM_GIT_NEXT)
    r.item(CM_GIT_PREV)
    r.item(CM_GIT_COMMIT)
    r.item(CM_GIT_BRANCH)
    r.item(CM_GIT_BLAME)
    r.sep()
    r.item(CM_AGENT)
    r.sep()
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
    r.sep()
    r.item(CM_ADDNEXT)
    r.item(CM_SKIPNEXT)
    r.item(CM_SELECT_ALL_OCC)
    r.item(CM_EXPAND_SEL)
    r.item(CM_SHRINK_SEL)
    r.item(CM_CURABOVE)
    r.item(CM_CURBELOW)
    r.sep()
    r.item(CM_FOLD)
    r.item(CM_FOLDALL)
    r.item(CM_UNFOLDALL)

    r.menu("~T~ext")
    r.item(CM_LINEUP)
    r.item(CM_LINEDOWN)
    r.item(CM_JOIN)
    r.item(CM_SORT)
    r.sep()
    r.item(CM_INDENT)
    r.item(CM_UNINDENT)
    r.sep()
    r.item(CM_UPPER)
    r.item(CM_LOWER)
    r.sep()
    r.item(CM_MACRO_REC)
    r.item(CM_MACRO_PLAY)

    r.menu("~S~earch")
    r.item(CM_FIND)
    r.item(CM_REPLACE)
    r.item(CM_AGAIN)
    r.item(CM_FINDFILES)
    r.item(CM_REPLACEFILES)
    r.sep()
    r.item(CM_GOTO)
    r.item(CM_SYMBOL)
    r.item(CM_WSYMBOL)
    r.item(CM_MATCH)
    r.item(CM_HOVER)
    r.item(CM_SIGNATURE)
    r.item(CM_DEFINITION)
    r.item(CM_TYPEDEF)
    r.item(CM_REFERENCES)
    r.item(CM_RENAME)
    r.item(CM_ACTIONS)
    r.item(CM_BACK)
    r.item(CM_FORWARD)
    r.sep()
    r.item(CM_PREVERR)
    r.item(CM_NEXTERR)
    r.item(CM_CONFLICT_NEXT)

    r.menu("~R~un")
    r.item(CM_RUN)
    r.item(CM_DEBUG)
    r.item(CM_STEP_INTO)
    r.item(CM_STEP_OVER)
    r.item(CM_STEP_OUT)
    r.item(CM_RUN_CURSOR)
    r.item(CM_PAUSE)
    r.item(CM_RESET)
    r.item(CM_WATCH_ADD)
    r.item(CM_EVALUATE)
    r.item(CM_DEBUG_GPU_LANE)
    r.item(CM_TEST)
    r.item(CM_TEST_CURSOR)
    r.item(CM_TESTEXP)
    r.item(CM_REPL)
    r.item(CM_USERSCREEN)
    r.item(CM_ARGS)
    r.item(CM_RUNCONFIGS)
    r.sep()
    r.item(CM_BP_TOGGLE)
    r.item(CM_BP_EDIT)
    r.item(CM_BP_FUNC)
    r.item(CM_BP_LIST)
    r.item(CM_BP_CLEAR)
    r.sep()
    r.item(CM_TASKS)
    r.item(CM_TASK_AGAIN)

    r.menu("~C~ompile")
    r.item(CM_BUILD)
    r.item(CM_FORMAT)
    r.item(CM_CODEGEN)
    r.item(CM_GPU_PROFILE)
    r.item(CM_MAX_SERVE)
    r.item(CM_RUN_CELL)
    r.sep()
    r.item(CM_NEXTERR)
    r.item(CM_PREVERR)
    r.item(CM_CANCEL)
    r.sep()
    r.item(CM_LSP)
    r.item(CM_COMPILER)

    r.menu("~O~ptions")
    r.item(CM_LINENUM)
    r.item(CM_RELNUM)
    r.item(CM_AUTOINDENT)
    r.item(CM_HLLINE)
    r.item(CM_CLOCK)
    r.item(CM_GPU_STATUS)
    r.item(CM_GIT_LINEBLAME)
    r.item(CM_SHOWWS)
    r.item(CM_WRAP)
    r.item(CM_SEMANTIC)
    r.item(CM_QUIET)
    r.item(CM_HINTS)
    r.item(CM_USETABS)
    r.item(CM_CRLF)
    r.sep()
    r.item(CM_KEYMAP0)
    r.item(CM_KEYMAP1)
    r.item(CM_KEYMAP2)
    r.item(CM_KEYMAP3)
    r.sep()
    r.item(CM_PRESETS)
    r.item(CM_THEME_PICK)
    r.item(CM_SCREEN_READER)
    r.sep()
    r.item(CM_PIXI_ENV)
    r.item(CM_TRUST)

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
    r.item(CM_SEARCHRES)
    r.item(CM_PROBLEMS)
    r.sep()
    r.item(CM_TILED)
    r.item(CM_SPLIT_RIGHT)
    r.item(CM_SPLIT_DOWN)
    r.item(CM_CLONE_VIEW)
    r.item(CM_NEXT_PANE)
    r.item(CM_NEXT_TAB)
    r.item(CM_PREV_TAB)
    r.item(CM_MOVE_TAB)
    r.item(CM_PANE_GROW)
    r.item(CM_PANE_SHRINK)
    r.sep()
    r.item(CM_EXPLORER)
    r.item(CM_OUTLINE)
    r.item(CM_DEBUGWIN)
    r.item(CM_CPUWIN)
    r.item(CM_GPU_WIN)
    r.item(CM_WINLIST)

    r.menu("~H~elp")
    r.item(CM_HELP)
    r.item(CM_HELP_GUIDE)
    r.item(CM_HELP_CHEAT)
    r.item(CM_HELP_TUTORIAL)
    r.item(CM_EXERCISES)
    r.item(CM_EX_CHECK)
    r.item(CM_HELP_ERRORS)
    r.item(CM_HELP_PYTHON)
    r.item(CM_HELP_NEW)
    r.item(CM_TIPS_OFF)
    r.item(CM_NOTICES)
    r.item(CM_DOCS)
    r.item(CM_DOCS_PANE)
    r.item(CM_AGENT_EXPLAIN)
    r.item(CM_AGENT_EXPLAIN_CODE)
    r.item(CM_MOJODOCS)
    r.item(CM_DOCFIND)
    r.item(CM_DOCFETCH)
    r.item(CM_SETUP)
    r.item(CM_REPORT)
    r.item(CM_ABOUT)
    return r^
