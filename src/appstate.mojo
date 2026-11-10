"""Application state: the App struct, its fields and small shared helpers.

Behaviour lives in the app_*.mojo modules, which extend App."""
from std.collections import List, Dict
from std.time import perf_counter_ns
from std.ffi import external_call
from term import (
    Terminal, wait_readable, ESC_TIMEOUT_MS, Event, EV_KEY, EV_MOUSE, EV_PASTE, K_BASE, KEY_ESC, KEY_ENTER, KEY_TAB,
    KEY_BACKSPACE, KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_HOME, KEY_END, KEY_PGUP,
    KEY_PGDN, KEY_INSERT, KEY_DELETE, MOD_SHIFT, MOD_ALT, MOD_CTRL, KEY_MASK, fkey, ctrl, alt,
    MB_LEFT, MB_WHEEL_UP, MB_WHEEL_DOWN,
)
from screen import Screen
from palette import Palette, theme, THEME_COUNT
from highlight import Highlighter
from buffer import TextBuffer, Pos
from window import Window, WK_EDITOR, WK_MESSAGE, ACT_OTHER, ACT_TYPE
from window_search import *
from window_draw import *
from menu import *
from commands import *
from dialog import *
from util import *
from signals import SignalFd, send_signal, own_pid
from config import *
from toml import toml_set, toml_quote, toml_bool

comptime M_NORMAL = 0
comptime M_MENU = 1
comptime M_DIALOG = 2
comptime M_COMPLETE = 3

comptime VERSION = "1.0"

comptime STATUS_MS = 4000        # how long a status-line message stays
comptime RESIZE_POLL_MS = 250    # until SIGWINCH handling lands (P0-11)
comptime SPINNER_MS = 100
comptime CAPS_TIMEOUT_MS = 150   # how long to wait for the terminal's capability replies


def now_ns() -> Int:
    return Int(perf_counter_ns())


comptime JOB_BUILD = 1
comptime JOB_FORMAT = 2
comptime SPINNER = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"


struct Job(Copyable, Movable):
    var active: Bool
    var kind: Int
    var fp: Int
    var fd: Int
    var pid: Int
    var data: List[UInt8]
    var t0: Int
    var path: String
    var exe: String
    var cancelled: Bool
    var version: Int

    def __init__(out self):
        self.active = False
        self.kind = 0
        self.fp = 0
        self.fd = -1
        self.pid = 0
        self.data = List[UInt8]()
        self.t0 = 0
        self.path = ""
        self.exe = ""
        self.cancelled = False
        self.version = -1


@fieldwise_init
struct ErrLoc(Copyable, Movable):
    var path: String
    var row: Int
    var col: Int
    var msg_line: Int


struct App(Movable):
    var term: Terminal
    var scr: Screen
    var pal: Palette
    var theme_idx: Int
    var hl: Highlighter
    var wins: List[Window]
    var reg: Registry
    var menus: List[Menu]
    var mode: Int
    var menu_idx: Int
    var menu_item: Int
    var dlg: Dialog
    var clipboard: List[Int]
    var line_numbers: Bool
    var auto_indent: Bool
    var hl_line: Bool
    var insert_mode: Bool
    var show_clock: Bool
    var running: Bool
    var find_text: List[Int]
    var replace_text: List[Int]
    var find_case: Bool
    var run_args: String
    var compiler: String
    var errs: List[ErrLoc]
    var err_idx: Int
    var status: String
    var status_until: Int
    var drag: Int
    var drag_dx: Int
    var drag_dy: Int
    var untitled_n: Int
    var cwd: String
    var comp_items: List[String]
    var comp_sel: Int
    var comp_start: Int
    var st_x0: List[Int]
    var st_x1: List[Int]
    var st_cmd: List[Int]
    var last_click_item: Int
    var job: Job
    var sig: SignalFd
    var recovered: Int
    var recovery_dir: String
    var config_path: String    # user config file; empty until load_config() (tests stay hermetic)
    var config_warnings: List[String]
    var log_path: String       # empty until run(): tests never write to the state dir
    var fault: String          # fault injection for crash tests (TURBOMOJO_FAULT)
    var show_ws: Bool

    def __init__(out self):
        self.term = Terminal()
        var sz = self.term.size()
        self.scr = Screen(sz[0], sz[1])
        self.theme_idx = 0
        self.pal = theme(0)
        self.hl = Highlighter()
        self.wins = List[Window]()
        self.reg = build_registry()
        self.menus = build_menus(self.reg)
        self.mode = M_NORMAL
        self.menu_idx = 0
        self.menu_item = 0
        self.dlg = Dialog(D_NONE, "", 10, 5)
        self.clipboard = List[Int]()
        self.line_numbers = True
        self.auto_indent = True
        self.hl_line = True
        self.insert_mode = True
        self.show_clock = True
        self.running = True
        self.find_text = List[Int]()
        self.replace_text = List[Int]()
        self.find_case = False
        self.run_args = ""
        self.compiler = env_or("TURBOMOJO_COMPILER", "mojo")
        self.errs = List[ErrLoc]()
        self.err_idx = -1
        self.status = ""
        self.status_until = 0
        self.drag = 0
        self.drag_dx = 0
        self.drag_dy = 0
        self.untitled_n = 0
        self.cwd = getcwd()
        self.comp_items = List[String]()
        self.comp_sel = 0
        self.comp_start = 0
        self.st_x0 = List[Int]()
        self.st_x1 = List[Int]()
        self.st_cmd = List[Int]()
        self.last_click_item = -1
        self.job = Job()
        self.sig = SignalFd()
        self.recovered = 0
        self.recovery_dir = state_dir() + "/recovered"
        self.log_path = ""
        self.config_path = ""
        self.config_warnings = List[String]()
        self.fault = env_or("TURBOMOJO_FAULT", "")
        self.show_ws = False

    # =================================================================== utils
    def desk_h(self) -> Int:
        return max(3, self.scr.h - 2)

    def top(self) -> Int:
        return len(self.wins) - 1

    def active_editor(self) -> Int:
        """Index of the active window if it is an editor, else -1."""
        var t = self.top()
        if t >= 0 and self.wins[t].kind == WK_EDITOR:
            return t
        return -1

    def top_editor(self) -> Int:
        var i = len(self.wins) - 1
        while i >= 0:
            if self.wins[i].kind == WK_EDITOR:
                return i
            i -= 1
        return -1

    def msg_index(self) -> Int:
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_MESSAGE:
                return i
        return -1

    def focus(mut self, i: Int):
        if i < 0 or i >= len(self.wins) or i == len(self.wins) - 1:
            return
        var w = self.wins.pop(i)
        self.wins.append(w^)

    def next_timeout_ms(self, now: Int, input_pending: Bool, secs_to_minute: Int) -> Int:
        """How long the event loop may sleep before something on screen must change."""
        # With signals on a descriptor a resize wakes the loop by itself; without it
        # (tests, or signalfd unavailable) fall back to checking the size periodically.
        var t = 3600000 if self.sig.active() else RESIZE_POLL_MS
        if self.job.active:
            t = min(t, SPINNER_MS)
        if input_pending:
            t = min(t, ESC_TIMEOUT_MS)
        if self.status_until > now:
            t = min(t, (self.status_until - now) // 1000000 + 1)
        if self.show_clock:
            t = min(t, secs_to_minute * 1000 + 50)
        return max(1, t)

    def apply_settings(mut self, s: Settings):
        """Take over loaded settings, including custom key bindings."""
        self.theme_idx = s.theme
        self.pal = theme(s.theme)
        self.line_numbers = s.line_numbers
        self.auto_indent = s.auto_indent
        self.hl_line = s.highlight_line
        self.show_clock = s.clock
        self.show_ws = s.show_whitespace
        # the environment variable still wins over the files for the compiler
        self.compiler = env_or("TURBOMOJO_COMPILER", s.compiler)
        self.config_warnings = s.warnings.copy()
        for i in range(len(s.key_commands)):
            var keys = List[Int]()
            var bad = False
            for name in s.key_names[i]:
                var k = parse_key(name)
                if k == 0:
                    self.config_warnings.append("keys." + s.key_commands[i] + ": unknown key \"" + name + "\"")
                    bad = True
                else:
                    keys.append(k)
            if bad:
                continue
            if not self.reg.rebind(s.key_commands[i], keys^):
                self.config_warnings.append("keys: unknown command \"" + s.key_commands[i] + "\"")
        self.menus = build_menus(self.reg)

    def load_config(mut self):
        """Read the user and project config files and apply them."""
        self.config_path = user_config_path()
        var project = find_project_config(self.cwd)
        self.apply_settings(load_settings(read_text(self.config_path), read_text(project)))

    def show_config_warnings(mut self):
        """Put the first config problem in the status line (all of them go to the log)."""
        if len(self.config_warnings) > 0:
            var more = len(self.config_warnings) - 1
            self.say("Config: " + self.config_warnings[0] + (" (+" + String(more) + " more, see crash.log)" if more > 0 else ""))

    def persist_option(mut self, table: String, key: String, literal: String):
        """Write one setting to the user config file, leaving the rest of it untouched.
        Only the changed option is written, so values that came from a project file or
        from the defaults are not copied into the user's file."""
        if self.config_path.byte_length() == 0:
            return
        var text = toml_set(read_text(self.config_path), table, key, literal)
        if not path_exists(dirname(self.config_path)):
            _ = run_system("mkdir -p " + shell_quote(dirname(self.config_path)))
        try:
            with open(self.config_path, "w") as f:
                f.write(text)
        except:
            self.say("Could not write " + self.config_path)

    def log_error(self, msg: String):
        """Record a problem in the crash log (only once the IDE is really running)."""
        if self.log_path.byte_length() > 0:
            _ = append_line(self.log_path, timestamp() + "  error: " + msg)

    def say(mut self, msg: String):
        self.status = msg
        self.status_until = now_ns() + STATUS_MS * 1000000

    def free_number(self) -> Int:
        for n in range(1, 10):
            var used = False
            for w in self.wins:
                if w.number == n:
                    used = True
            if not used:
                return n
        return 0

    def new_editor(mut self, title: String, path: String) -> Int:
        var k = 0
        for w in self.wins:
            if w.kind == WK_EDITOR:
                k += 1
        var off = k % 6
        var dh = self.desk_h()
        var mi = self.msg_index()
        if mi >= 0:
            dh = max(6, self.wins[mi].y - 1)
        var win = Window(WK_EDITOR, title, path, off, 1 + off, self.scr.w - off, dh - off, self.free_number())
        win.gut = win.gutter_for(self.line_numbers)
        self.wins.append(win^)
        return len(self.wins) - 1

    def ensure_msg(mut self) -> Int:
        var mi = self.msg_index()
        if mi >= 0:
            return mi
        var h = max(5, min(10, self.desk_h() // 3))
        var y = 1 + self.desk_h() - h
        var win = Window(WK_MESSAGE, "Message", "", 0, y, self.scr.w, h, self.free_number())
        # shrink full-height editors so the message window does not cover them
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EDITOR and self.wins[i].y + self.wins[i].h > y and y - self.wins[i].y >= 6:
                self.wins[i].h = y - self.wins[i].y
                if self.wins[i].zoomed:
                    self.wins[i].sh = self.wins[i].h
        self.wins.insert(0, win^)
        return 0

    def fit_windows(mut self):
        var W = self.scr.w
        var dh = self.desk_h()
        for i in range(len(self.wins)):
            if self.wins[i].zoomed:
                self.wins[i].x = 0
                self.wins[i].y = 1
                self.wins[i].w = W
                self.wins[i].h = dh
            else:
                self.wins[i].w = max(16, min(self.wins[i].w, W))
                self.wins[i].h = max(4, min(self.wins[i].h, dh))
                self.wins[i].x = max(0, min(self.wins[i].x, W - self.wins[i].w))
                self.wins[i].y = max(1, min(self.wins[i].y, 1 + dh - self.wins[i].h))

    def osc52(mut self, text: List[Int]):
        var b = List[UInt8]()
        for c in text:
            encode_cp(c, b)
        append_str(self.term.out, "\x1b]52;c;" + base64(b) + "\x07")
        self.term.flush()
