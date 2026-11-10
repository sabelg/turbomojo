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
from buffer import TextBuffer, Pos, ENC_UTF8, ENC_LATIN1
from window import Window, WK_EDITOR, WK_MESSAGE, WK_OUTLINE, ACT_OTHER, ACT_TYPE
from window_search import *
from window_multi import *
from window_lines import *
from search import Search, make_search
from window_draw import *
from menu import *
from commands import *
from dialog import *
from util import *
from signals import SignalFd, send_signal, own_pid
from config import *
from editorconfig import EcProps, ec_for_file
from watch import Watcher, FileSig, file_sig, WATCH_POLL_MS
from outline import OutlineItem
from symindex import SymbolIndex, IndexedSymbol
from lsp import LspClient, CompletionItem, SigInfo, WorkspaceEdit, CodeAction
from grep import FileSearch
from filestate import *
from markdown import MdLine
from toml import toml_set, toml_quote, toml_bool

comptime M_NORMAL = 0
comptime M_MENU = 1
comptime M_DIALOG = 2
comptime M_COMPLETE = 3
comptime M_HOVER = 4                    # a hover window is open over the editor

comptime VERSION = "1.0"

comptime COUNT_LINE_LIMIT = 50000     # matches are counted in at most this many lines
comptime PREVIEW_LINE_LIMIT = 50000   # no search-as-you-type in longer texts
comptime FSEARCH_SLICE_MS = 8          # work per loop pass while searching files
comptime FSEARCH_REDRAW_MS = 150       # how often new hits are shown while it runs
comptime EV_COMMAND = 100               # a macro step that runs a command (Event.key holds its id)
comptime MACRO_MAX = 100000            # recording stops by itself at this many steps
comptime LSP_MAX_RESTARTS = 3            # automatic restarts of a crashed language server...
comptime LSP_CRASH_WINDOW_S = 60         # ...within this many seconds; after that it stays off
comptime COMP_RETRY_MS = 150            # wait before asking again when the server is still analysing
comptime COMP_MAX_RETRIES = 12
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
struct JumpLoc(Copyable, Movable):
    """A place the cursor was before a jump (0-based row and column)."""
    var path: String
    var row: Int
    var col: Int


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
    var keymap: Int            # 0 modern, 1 turbo / WordStar, 2 emacs
    var macro: List[Event]     # the recorded macro: keys, pastes, and commands picked from menus
    var macro_rec: Bool        # recording now
    var macro_playing: Bool
    var macro_key_live: Bool   # the key being handled right now was recorded
    var macro_cmd_start: Int   # where the keys of the command being typed begin in `macro`
    var chord: Int             # first key of a two-key binding, waiting for the second
    var user_key_cmds: List[String]         # [keys] from the config files
    var user_key_names: List[List[String]]
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
    var find_word: Bool
    var find_regex: Bool
    var find_sig: String       # what the Find dialog last searched for (text and options)
    # where the editor was when the Find dialog opened (restored on Cancel)
    var fo_cr: Int
    var fo_cc: Int
    var fo_sel: Bool
    var fo_ar: Int
    var fo_ac: Int
    var fo_top: Int
    var run_args: String
    var compiler: String
    var lsp_server: String     # the language server program
    var include_paths: List[String]   # extra -I folders, already made absolute
    var project_dir: String    # folder of the project's .turbomojo.toml ('' if there is none)
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
    var comp_insert: List[String]    # what each item puts into the text
    var comp_kind: List[Int]         # LSP kind; -1 for a word found in the text
    var comp_detail: List[String]
    var comp_doc: List[String]
    var comp_raw: List[String]       # the server's item, for asking for its details
    var comp_srv: List[CompletionItem]   # the server's answer for the word being typed
    var comp_srv_have: Bool
    var comp_srv_incomplete: Bool
    var comp_srv_path: String
    var comp_srv_row: Int
    var comp_srv_start: Int
    var comp_req_id: Int             # completion request on its way (-1 none)
    var comp_req_path: String
    var comp_req_row: Int
    var comp_req_start: Int
    var comp_req_trigger: String     # the trigger character of that request ('' if asked by hand)
    var comp_retries: Int            # how often the server said "not yet" for this spot
    var comp_retry_due: Int          # when to ask again (0 = no retry pending)
    var comp_waiting: Bool           # nothing to show yet: the popup opens when the answer comes
    var comp_resolve_id: Int
    var hover_lines: List[MdLine]    # the open hover window's text
    var hover_scroll: Int
    var hover_req_id: Int
    var hover_req_path: String
    var hover_req_row: Int
    var hover_req_col: Int
    var hover_retries: Int
    var hover_retry_due: Int
    var jumps: List[JumpLoc]         # places left by jumps, oldest first
    var jump_at: Int                 # == len(jumps) unless going back through them
    var def_req_id: Int
    var def_req_path: String
    var def_req_row: Int
    var def_req_col: Int
    var def_retries: Int
    var def_retry_due: Int
    var ref_req_id: Int
    var ref_req_path: String
    var ref_req_row: Int
    var ref_req_col: Int
    var ref_retries: Int
    var ref_retry_due: Int
    var ren_stage: Int               # 0 idle, 1 asked whether it can be renamed, 2 asked for the edits
    var ren_req_id: Int
    var ren_path: String
    var ren_row: Int
    var ren_col: Int
    var ren_old: String
    var ren_new: String
    var ren_retries: Int
    var ren_retry_due: Int
    var ren_vpaths: List[String]     # the open files and their versions when the edits were asked for
    var ren_versions: List[Int]
    var ren_edit: WorkspaceEdit      # waiting for the user's go-ahead
    var edit_noun: String            # the operation whose edit is being offered ("Rename", "Quick fix")
    var edit_done: String
    var actions: List[CodeAction]    # what the open Quick Fix list offers
    var act_chosen: CodeAction
    var act_stage: Int               # 0 idle, 1 asked for the list, 2 asked for the chosen action's edit
    var act_req_id: Int
    var act_path: String
    var act_row: Int
    var act_col: Int
    var act_retries: Int
    var act_retry_due: Int
    var act_command_due: Bool        # the chosen action's command runs once its edit is applied
    var outline_items: List[OutlineItem]     # what the Outline window lists
    var outline_key: String          # the file it was made for (path, or title if unnamed)
    var outline_version: Int         # ... and the version of its text
    var outline_from_server: Bool
    var outline_asked_key: String    # what the server was last asked about
    var outline_asked_version: Int
    var outline_req_id: Int
    var outline_req_ns: Int
    var symidx: SymbolIndex          # symbols of the project's Mojo files
    var ws_list: List[IndexedSymbol] # what the open project-symbol dialog lists
    var ws_building: Bool            # the dialog shows a list made while the index was being built
    var sigtip: SigInfo                # the parameter tip shown above the cursor
    var sig_on: Bool
    var sig_asked: Bool              # asked for by command: say so if there is nothing
    var sig_req_id: Int
    var sig_path: String             # where the last question was asked
    var sig_row: Int
    var sig_col: Int
    var sig_version: Int
    var sig_retries: Int
    var sig_retry_due: Int
    var comp_resolve_label: String
    var st_x0: List[Int]
    var st_x1: List[Int]
    var st_cmd: List[Int]
    var last_click_item: Int
    var job: Job
    var sig: SignalFd
    var recovered: Int
    var recovery_dir: String   # where swap files live
    var history_dir: String    # where undo histories and cursor positions are kept ('' = nowhere)
    var persistent_undo: Bool  # the user's setting
    var swap_enabled: Bool     # off until the IDE really runs (tests opt in)
    var swap_due: Int          # time (ns) of the next swap write; 0 = nothing pending
    var pending_swaps: List[String]
    var tool_env: String       # environment prefix for Mojo tools ('' if none needed)
    var tool_env_known: Bool
    var lsp: LspClient
    var fsearch: FileSearch    # Find in files, advanced a little on every loop pass
    var fsearch_shown: Int     # how many hits the Message window shows
    var fsearch_draw_ns: Int   # when it was last refreshed
    var errs_from_search: Bool # the Message window lists search hits, not compiler messages
    var lsp_path: String       # file whose diagnostics are shown ('' = none)
    var lsp_uri: String
    var lsp_sent_ns: Int       # when the last change went to the server (0 = answered)
    var lsp_change_due: Int
    var lsp_last_latency_ms: Int
    var lsp_reported_failure: Bool
    var lsp_crashes: List[Int]       # when the server died unexpectedly (ns), most recent last
    var lsp_restart_due: Int         # when to start it again (0 = no restart pending)
    var lsp_restart_path: String     # the file to track again after the restart
    var lsp_restart_base_ms: Int     # first waiting time; doubles with every crash
    var lsp_announced: Bool          # "ready" has been said for this run of the server
    var watch: Watcher         # inotify on the directories of open files
    var watch_enabled: Bool    # periodic checking when inotify is unavailable (set by run())
    var watch_due: Int
    var watch_recheck: Bool    # a change was seen while a dialog was open: ask afterwards
    var tab_width: Int         # defaults for new buffers (user config)
    var indent_size: Int
    var large_file_bytes: Int  # files above this size open in large-file mode
    var config_path: String    # user config file; empty until load_config() (tests stay hermetic)
    var config_warnings: List[String]
    var log_path: String       # empty until run(): tests never write to the state dir
    var fault: String          # fault injection for crash tests (TURBOMOJO_FAULT)
    var show_ws: Bool
    var soft_wrap: Bool
    var semantic_on: Bool            # Options > Semantic colours
    var hints_on: Bool               # Options > Inlay hints
    var sem_req_id: Int              # the semantic tokens request under way
    var sem_req_path: String
    var sem_req_version: Int
    var sem_req_ns: Int
    var hint_req_id: Int
    var hint_req_path: String
    var hint_req_version: Int
    var hint_req_ns: Int
    var decor_wait_until: Int        # after a refusal: not before this time
    var auto_pairs: Bool
    var word_hl: Bool                # editor.highlight_word
    var trim_trailing: Bool
    var rulers: List[Int]

    def __init__(out self):
        self.term = Terminal()
        var sz = self.term.size()
        self.scr = Screen(sz[0], sz[1])
        self.theme_idx = 0
        self.pal = theme(0)
        self.hl = Highlighter()
        self.wins = List[Window]()
        self.reg = build_registry()
        self.keymap = 0
        self.macro = List[Event]()
        self.macro_rec = False
        self.macro_playing = False
        self.macro_cmd_start = 0
        self.macro_key_live = False
        self.chord = 0
        self.user_key_cmds = List[String]()
        self.user_key_names = List[List[String]]()
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
        self.find_word = False
        self.find_regex = False
        self.find_sig = ""
        self.fo_cr = 0
        self.fo_cc = 0
        self.fo_sel = False
        self.fo_ar = 0
        self.fo_ac = 0
        self.fo_top = 0
        self.run_args = ""
        self.compiler = env_or("TURBOMOJO_COMPILER", "mojo")
        self.lsp_server = env_or("TURBOMOJO_LSP", "mojo-lsp-server")
        self.include_paths = List[String]()
        self.project_dir = ""
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
        self.comp_insert = List[String]()
        self.comp_kind = List[Int]()
        self.comp_detail = List[String]()
        self.comp_doc = List[String]()
        self.comp_raw = List[String]()
        self.comp_srv = List[CompletionItem]()
        self.comp_srv_have = False
        self.comp_srv_incomplete = False
        self.comp_srv_path = ""
        self.comp_srv_row = -1
        self.comp_srv_start = -1
        self.comp_req_id = -1
        self.comp_req_path = ""
        self.comp_req_row = -1
        self.comp_req_start = -1
        self.comp_req_trigger = ""
        self.comp_retries = 0
        self.comp_retry_due = 0
        self.comp_waiting = False
        self.comp_resolve_id = -1
        self.hover_lines = List[MdLine]()
        self.hover_scroll = 0
        self.hover_req_id = -1
        self.hover_req_path = ""
        self.hover_req_row = -1
        self.hover_req_col = -1
        self.hover_retries = 0
        self.hover_retry_due = 0
        self.jumps = List[JumpLoc]()
        self.jump_at = 0
        self.def_req_id = -1
        self.def_req_path = ""
        self.def_req_row = -1
        self.def_req_col = -1
        self.def_retries = 0
        self.def_retry_due = 0
        self.ref_req_id = -1
        self.ref_req_path = ""
        self.ref_req_row = -1
        self.ref_req_col = -1
        self.ref_retries = 0
        self.ref_retry_due = 0
        self.ren_stage = 0
        self.ren_req_id = -1
        self.ren_path = ""
        self.ren_row = -1
        self.ren_col = -1
        self.ren_old = ""
        self.ren_new = ""
        self.ren_retries = 0
        self.ren_retry_due = 0
        self.ren_vpaths = List[String]()
        self.ren_versions = List[Int]()
        self.ren_edit = WorkspaceEdit()
        self.edit_noun = "Rename"
        self.edit_done = ""
        self.actions = List[CodeAction]()
        self.act_chosen = CodeAction()
        self.act_stage = 0
        self.act_req_id = -1
        self.act_path = ""
        self.act_row = -1
        self.act_col = -1
        self.act_retries = 0
        self.act_retry_due = 0
        self.act_command_due = False
        self.outline_items = List[OutlineItem]()
        self.outline_key = ""
        self.outline_version = -1
        self.outline_from_server = False
        self.outline_asked_key = ""
        self.outline_asked_version = -1
        self.outline_req_id = -1
        self.outline_req_ns = 0
        self.symidx = SymbolIndex()
        self.ws_list = List[IndexedSymbol]()
        self.ws_building = False
        self.sigtip = SigInfo()
        self.sig_on = False
        self.sig_asked = False
        self.sig_req_id = -1
        self.sig_path = ""
        self.sig_row = -1
        self.sig_col = -1
        self.sig_version = -1
        self.sig_retries = 0
        self.sig_retry_due = 0
        self.comp_resolve_label = ""
        self.st_x0 = List[Int]()
        self.st_x1 = List[Int]()
        self.st_cmd = List[Int]()
        self.last_click_item = -1
        self.job = Job()
        self.sig = SignalFd()
        self.recovered = 0
        self.recovery_dir = state_dir() + "/swap"
        self.history_dir = ""
        self.persistent_undo = True
        self.swap_enabled = False
        self.swap_due = 0
        self.pending_swaps = List[String]()
        self.tool_env = ""
        self.tool_env_known = False
        self.lsp = LspClient()
        self.fsearch = FileSearch()
        self.fsearch_shown = -1
        self.fsearch_draw_ns = 0
        self.errs_from_search = False
        self.lsp_path = ""
        self.lsp_uri = ""
        self.lsp_sent_ns = 0
        self.lsp_change_due = 0
        self.lsp_last_latency_ms = -1
        self.lsp_reported_failure = False
        self.lsp_crashes = List[Int]()
        self.lsp_restart_due = 0
        self.lsp_restart_path = ""
        self.lsp_restart_base_ms = 1000
        self.lsp_announced = False
        self.watch = Watcher()
        self.watch_enabled = False
        self.watch_due = 0
        self.watch_recheck = False
        self.log_path = ""
        self.config_path = ""
        self.tab_width = 4
        self.indent_size = 4
        self.large_file_bytes = 50 * 1024 * 1024
        self.config_warnings = List[String]()
        self.fault = env_or("TURBOMOJO_FAULT", "")
        self.show_ws = False
        self.soft_wrap = False
        self.semantic_on = True
        self.hints_on = True
        self.sem_req_id = -1
        self.sem_req_path = ""
        self.sem_req_version = -1
        self.sem_req_ns = 0
        self.hint_req_id = -1
        self.hint_req_path = ""
        self.hint_req_version = -1
        self.hint_req_ns = 0
        self.decor_wait_until = 0
        self.auto_pairs = True
        self.word_hl = True
        self.trim_trailing = False
        self.rulers = List[Int]()

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
        if self.symidx.building:
            t = min(t, 5)
        if self.fsearch.active:
            t = 1                   # keep searching; input is still handled between steps
        if input_pending:
            t = min(t, ESC_TIMEOUT_MS)
        if self.status_until > now:
            t = min(t, (self.status_until - now) // 1000000 + 1)
        if self.swap_due > now:
            t = min(t, (self.swap_due - now) // 1000000 + 1)
        if self.lsp_change_due > now:
            t = min(t, (self.lsp_change_due - now) // 1000000 + 1)
        if self.lsp_restart_due > 0:
            t = min(t, max(1, (self.lsp_restart_due - now) // 1000000 + 1))
        if self.comp_retry_due > 0:
            t = min(t, max(1, (self.comp_retry_due - now) // 1000000 + 1))
        if self.hover_retry_due > 0:
            t = min(t, max(1, (self.hover_retry_due - now) // 1000000 + 1))
        if self.sig_retry_due > 0:
            t = min(t, max(1, (self.sig_retry_due - now) // 1000000 + 1))
        if self.def_retry_due > 0:
            t = min(t, max(1, (self.def_retry_due - now) // 1000000 + 1))
        if self.ref_retry_due > 0:
            t = min(t, max(1, (self.ref_retry_due - now) // 1000000 + 1))
        if self.ren_retry_due > 0:
            t = min(t, max(1, (self.ren_retry_due - now) // 1000000 + 1))
        if self.act_retry_due > 0:
            t = min(t, max(1, (self.act_retry_due - now) // 1000000 + 1))
        if self.lsp.conn.wants_write():
            t = min(t, 10)
        if self.watch_enabled and not self.watch.active():
            t = min(t, max(1, (self.watch_due - now) // 1000000 + 1))
        if self.show_clock:
            t = min(t, secs_to_minute * 1000 + 50)
        return max(1, t)

    def tool(mut self, command: String) -> String:
        """A Mojo tool command with the environment it needs (see util.toolchain_env)."""
        if not self.tool_env_known:
            self.tool_env_known = True
            self.tool_env = toolchain_env(env_or("MODULAR_HOME", ""), which(self.compiler))
        return self.tool_env + command

    def include_flags(self) -> String:
        """" -I dir" for each configured include folder ('' if there are none)."""
        var out = String("")
        for ip in self.include_paths:
            out += " -I " + shell_quote(ip)
        return out

    def compiler_cmd(mut self) -> String:
        """The configured compiler command with the environment it needs."""
        var c = String(self.compiler)
        return self.tool(c)

    def apply_settings(mut self, s: Settings):
        """Take over loaded settings, including custom key bindings."""
        self.theme_idx = s.theme
        self.pal = theme(s.theme)
        self.line_numbers = s.line_numbers
        self.auto_indent = s.auto_indent
        self.hl_line = s.highlight_line
        self.show_clock = s.clock
        self.show_ws = s.show_whitespace
        self.soft_wrap = s.soft_wrap
        self.semantic_on = s.semantic_colors
        self.hints_on = s.inlay_hints
        self.auto_pairs = s.auto_pairs
        self.word_hl = s.highlight_word
        for i in range(len(self.wins)):
            self.wins[i].word_hl = self.word_hl
        self.persistent_undo = s.persistent_undo
        self.trim_trailing = s.trim_trailing
        self.rulers = s.rulers.copy()
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EDITOR and self.wins[i].wrap != self.soft_wrap:
                self.wins[i].set_wrap(self.soft_wrap)
        self.tab_width = s.tab_width
        self.indent_size = s.indent_size
        self.large_file_bytes = s.large_file_mb * 1024 * 1024
        # the environment variable still wins over the files for the compiler
        self.compiler = env_or("TURBOMOJO_COMPILER", s.compiler)
        self.lsp_server = env_or("TURBOMOJO_LSP", s.lsp_server)
        # relative include folders belong to the project file's folder (or where we run)
        self.include_paths = List[String]()
        var base = self.project_dir if self.project_dir.byte_length() > 0 else String(self.cwd)
        for ip in s.include_paths:
            if ip.byte_length() > 0:
                self.include_paths.append(abs_path(base, ip))
        self.config_warnings = s.warnings.copy()
        self.keymap = s.keymap
        self.user_key_cmds = s.key_commands.copy()
        self.user_key_names = List[List[String]]()
        for i in range(len(s.key_names)):
            self.user_key_names.append(s.key_names[i].copy())
        self.rebuild_keys(True)

    def rebuild_keys(mut self, warn: Bool):
        """Bindings from scratch: the defaults, then the chosen keymap, then the user's
        [keys] entries on top."""
        self.reg = build_registry()
        apply_keymap(self.reg, self.keymap)
        self.chord = 0
        for i in range(len(self.user_key_cmds)):
            var keys = List[Int]()
            var bad = False
            for name in self.user_key_names[i]:
                var k = parse_key(name)
                if k == 0:
                    if warn:
                        self.config_warnings.append("keys." + self.user_key_cmds[i] + ": unknown key \"" + name + "\"")
                    bad = True
                else:
                    keys.append(k)
            if bad:
                continue
            if not self.reg.rebind(self.user_key_cmds[i], keys^) and warn:
                self.config_warnings.append("keys: unknown command \"" + self.user_key_cmds[i] + "\"")
        self.menus = build_menus(self.reg)

    def load_config(mut self):
        """Read the user and project config files and apply them."""
        self.config_path = user_config_path()
        var project = find_project_config(self.cwd)
        self.project_dir = dirname(project) if project.byte_length() > 0 else String("")
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
        win.buf.tab_width = self.tab_width
        win.buf.indent_size = self.indent_size
        win.wrap = self.soft_wrap
        win.auto_pairs = self.auto_pairs
        win.word_hl = self.word_hl
        win.rulers = self.rulers.copy()
        var oi = self.outline_index()
        if oi >= 0 and win.x + win.w > self.wins[oi].x and self.wins[oi].x - win.x >= 20:
            win.w = self.wins[oi].x - win.x         # beside the outline, not over it
        self.wins.append(win^)
        return len(self.wins) - 1

    def outline_index(self) -> Int:
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_OUTLINE:
                return i
        return -1

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
