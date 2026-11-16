"""Application state: the App struct, its fields and small shared helpers.

Behaviour lives in the app_*.mojo modules, which extend App."""
from glyphs import glyphs_of
from kittygfx import GFX_FIRST_ID, wrap_for_tmux
from progress import QUIET_MS
from version import TURBOMOJO_VERSION
from vim import VimState, VM_NORMAL, VM_INSERT, VM_VISUAL, VM_VLINE, KEYMAP_VIM
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
from themes import ThemeSet, scheme_from, animations_off
from caps import OSC11_QUERY
from contrast import quiet_syntax
from strings import apply_strings, language_from
from notify import NotifyCenter, TYPING_PAUSE_MS, NL_INFO
from links import parse_ssh_host, format_ssh_pill, parse_port_forward, host_name
from tips import TipRules
from plugins import Plugin, PluginPanel, register_plugins
from lspextra import ExtraServer, configure_servers
from highlight import Highlighter
from buffer import TextBuffer, Pos, ENC_UTF8, ENC_LATIN1
from window import Window, WK_EDITOR, WK_MESSAGE, WK_OUTLINE, WK_EXPLORER, WK_DOCPANE, WK_GPU, WK_HEX, WK_MDPREVIEW, WK_GITLOG, ACT_OTHER, ACT_TYPE
from snippets import SnippetTemplate
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
from symindex import SymbolIndex, IndexedSymbol, FileIndex
from frecency import Frecency
from docs import DocEntry
from layout import Layout
from project import PixiTask, discover_mojo_project_root, discover_auto_include_dirs
from runconfig import RunConfig
from trust import TrustStore
from doclib import DocLibrary, DocIndex, Found, default_docs_home
from dap import DebugSession
from dbgview import DebugView
from cpuview import CpuView
from termsession import TermSession
from testexp import TestFile
from git import GitStatus, BlameLine, resolve_git_dir
from gitdiff import DiffRow
from problems import Problem, ProblemFilter
from acp import AcpClient
from agentchat import AgentChat
from agentsvc import AgentTerm, Proposal, RunAsk
from acp import AcpEvent
from markdown import MdLine
from linediff import Hunk
from proc import Proc
from breakpoints import Breakpoints
from explorer import ExplorerTree, default_trash_dir
from lsp import LspClient, CompletionItem, SigInfo, WorkspaceEdit, CodeAction
from grep import FileSearch
from filestate import *
from markdown import MdLine
from toml import toml_set, toml_quote, toml_bool
from setupcheck import SetupItem
from gpuinfo import GPU_QUERY, GPU_TELEMETRY_QUERY

comptime M_NORMAL = 0
comptime M_MENU = 1
comptime M_DIALOG = 2
comptime M_COMPLETE = 3
comptime PG_MESSAGE = 0                 # pages of the bottom panel: compiler and program output,
comptime PG_SEARCH = 1                  # search results and lists of places,
comptime KEY_BOX_MS = 200                # after a prefix key, the box of the next keys comes this late
                                        # (a typed sequence is quicker; a hesitation is about this long)
comptime PG_PROBLEMS = 2                # what the language server reports
comptime PG_COUNT = 3
comptime M_DOCS = 5                     # the documentation reader fills the screen
comptime M_HOVER = 4                    # a hover window is open over the editor
comptime M_PEEK = 6                     # inline PeekBox / hunk preview overlay over the editor

comptime VERSION = TURBOMOJO_VERSION       # (src/version.mojo)

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
comptime JOB_DOCS = 4                    # downloading the documentation
comptime JOB_DEBUG = 5                   # building a program to debug it
comptime JOB_TESTS = 6                   # running (or listing) tests for the test explorer
comptime JOB_CODEGEN = 7                 # emitting assembly / LLVM IR for the codegen inspector
comptime JOB_CELL = 8                    # running an interactive # %% code cell
comptime JOB_BENCH = 9                   # running Mojo std.benchmark with -O3
comptime JOB_ROOFLINE = 10               # profiling single-kernel GPU roofline (ncu / rocprofv3)
comptime JOB_MAX_BENCH = 11              # running structured max benchmark JSON capture
comptime JOB_TASK = 3                    # a pixi task of the project
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
    var cmd: String         # the shell command, as started
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
        self.cmd = ""
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



def osc52_seq(text: List[Int]) -> String:
    """The OSC 52 sequence that puts `text` on the clipboard (base64 of its UTF-8)."""
    var b = List[UInt8]()
    for c in text:
        encode_cp(c, b)
    return "\x1b]52;c;" + base64(b) + "\x07"

struct App(Movable):
    var term: Terminal
    var scr: Screen
    var pal: Palette
    var theme_idx: Int
    var themes: ThemeSet        # every theme: built in and ~/.config/turbomojo/themes/*.toml
    var theme_id: String        # ui.theme as set ("auto": follow the terminal)
    var theme_dark_id: String
    var theme_light_id: String
    var scanlines_cfg: Int      # ui.scanlines: -1 the theme's, 0 off, 1 on
    var scheme_seen: Int        # the terminal's light/dark that the theme follows (0: none yet)
    var desktop_scheme: Int     # the desktop's (COLORFGBG, GNOME's setting) when the terminal is silent
    var desktop_checked_ns: Int
    var bg_asked_ns: Int             # when the terminal was last asked its background (OSC 11)
    var theme_before: String         # the theme while the Colour Theme dialog previews others ("": none open)
    var setup_offer: Bool             # the first run shows Check setup after its questions
    var setup_list: List[SetupItem]  # Check setup's lines
    var term_probed: Bool            # the terminal was asked what it can do (run())
    var gpu_status_on: Bool          # ui.gpu_status: the GPU on the status line
    var gpu_asked: Bool
    var gpu_query: String            # (gpuinfo.GPU_QUERY; tests give their own)
    var gpu_fp: Int
    var gpu_fd: Int
    var gpu_out: List[UInt8]
    var gpu_item: String             # "GPU GB10" once known
    var gpu_mon_query: String        # live telemetry query for WK_GPU
    var gpu_mon_fp: Int
    var gpu_mon_fd: Int
    var gpu_mon_out: List[UInt8]
    var gpu_mon_last_ns: Int
    var gpu_mon_hist: List[List[Int]]
    var codegen_mode: Int            # 0 asm, 1 llvm
    var codegen_path: String
    var codegen_out_file: String
    var codegen_filter: String
    var run_t0_ns: Int               # when the last Ctrl-F9 run started (0: none to report)
    var run_label: String
    var run_file: String             # the file the last Ctrl-F9 ran
    var run_wants_gpu: Bool          # its source uses the GPU
    var lsp_env: String              # the pixi.toml whose environment the server runs in ("" the IDE's own)
    var lsp_front: String            # the file in front when the server last looked (P11-16)
    var pkg_lsp_again: Bool          # the language server stopped for an install: start it again (P11-14)
    var pkg_asked: List[String]      # libraries offered this session ("kind:module")
    var pkg_kind: Int                # the one being offered or installed (pkginstall.PK_*)
    var pkg_module: String
    var pkg_package: String
    var pkg_dir: String              # the project's folder ('' = none yet)
    var pkg_file: String             # the program that needs it
    var pkg_after: Int               # then: 1 build, 2 run again
    var caps_lines: List[String]     # what the terminal said it can do (Report a problem)
    var report_path: String          # where the report goes ("": the state folder)
    var term_kitty_keys: Bool        # ... and it sends every key (kitty keyboard protocol)
    var np_offer: Bool                # the welcome offers a new project once its theme question is answered
    var theme_marker: String         # a file that says the first run asked for a theme ("": never ask)
    var notes: NotifyCenter     # toasts and the notification centre
    var toast_rows: List[Int]   # the toasts as drawn: which notice, top and bottom row
    var toast_y0: List[Int]
    var toast_y1: List[Int]
    var toast_x: Int
    var help_dir: String        # where the help pages are written ('' in tests: no help book)
    var reader: Bool            # screen-reader mode: plain drawing, the cursor on what has focus
    var breadcrumbs: Bool       # editor.breadcrumbs
    var sticky_scroll: Bool     # editor.sticky_scroll
    var minimap_on: Bool        # editor.minimap
    var minimap_blocks: Bool    # editor.minimap_style: half blocks instead of braille
    var focused: Bool           # the terminal has the focus (mode 1004 reports; true until told)
    var dim_unfocused: Bool     # ui.dim_unfocused
    var note_label: String      # what the notice being made is about (notify_as)
    var bells: Int              # bells rung (screen-reader mode)
    var scopes_stale: Bool      # a long file's scopes wait to be scanned again
    var language: String        # the UI's language (strings file); "en": built in
    var strings_dir: String     # where strings files are ('' in tests: English only)
    var key_hints: Bool         # ui.key_hints: "Next time: <key>" after a menu or the palette, the box after a prefix key
    var tips_on: Bool           # ui.tips
    var tip_rules: TipRules     # what the keys have been doing (src/tips.mojo)
    var tips_shown: List[String]  # the tips given already (never twice)
    var tips_file: String       # where those are kept ('' in tests: nowhere)
    var ex_home: String         # the exercises' copies (set by main; tests use their own)
    var plugins: List[Plugin]   # src/plugins.mojo
    var plugins_dir: String     # where they are (set by main: ~/.config/turbomojo/plugins)
    var plugins_log_dir: String # their stderr goes there ('' : nowhere)
    var plugins_on: Bool        # tools.plugins
    var plugin_warnings: List[String]   # what registering their commands could not do
    var panels: List[PluginPanel]       # the plugins' open panels
    var lsp_extra: List[ExtraServer]    # language servers for other languages ([lsp.<name>])
    var hover_srv: Int                  # who the hover question went to (-1: the Mojo server)
    var key_uses: Dict[String, Int]  # how often each command was run by its key
    var key_uses_path: String   # where those counts are kept ('' in tests)
    var reduce_motion: Bool     # no animation (the busy spinner stands still)
    var reduced_motion_cfg: Int # ui.reduced_motion: -1 auto, 0 off, 1 on
    var hl: Highlighter
    var wins: List[Window]
    var buffers: List[TextBuffer]
    var reg: Registry
    var vim: VimState          # the vim keymap's mode and what is being typed (Phase 12)
    var keymap: Int            # 0 modern, 1 turbo / WordStar, 2 emacs
    var macro: List[Event]     # the recorded macro: keys, pastes, and commands picked from menus
    var macro_rec: Bool        # recording now
    var macro_playing: Bool
    var macro_key_live: Bool   # the key being handled right now was recorded
    var macro_cmd_start: Int   # where the keys of the command being typed begin in `macro`
    var chord: Int             # first key of a two-key binding, waiting for the second
    var chord_since: Int       # when that key was pressed
    var typed_ns: Int          # the last key the editor had (toasts that come while typing wait)
    var link_format: String    # ui.hyperlink_format
    var link_host: String      # this machine's name, for file:// links
    var last_osc52: String
    var plugin_asked: Int      # the plugin whose command the user ran last, and when (its panel
    var plugin_asked_ns: Int   # may come to the front as the answer)
    var plugin_focused_path: String # last editor path announced to plugins via "focus"
    var chord_box: Bool        # the box of the keys that may follow is shown
    var user_key_cmds: List[String]         # [keys] from the config files
    var user_key_names: List[List[String]]
    var menus: List[Menu]
    var mode: Int
    var menu_idx: Int
    var menu_item: Int
    var dlg: Dialog
    var clipboard: List[Int]
    var line_numbers: Bool
    var rel_numbers: Bool       # editor.relative_numbers: the gutter counts from the cursor's line
    var auto_indent: Bool
    var hl_line: Bool
    var insert_mode: Bool
    var show_clock: Bool
    var clock_fixed: String     # shown instead of the time when set (screenshots)
    var mojo_checked: Bool      # the Mojo found compared with the one built with (P11-03)
    var mojo_warning: String    #   and what was found wrong ("" nothing)
    var running: Bool
    var find_text: List[Int]
    var replace_text: List[Int]
    var find_filter: String
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
    var debug_adapter: String  # the debug adapter program
    var dbg: DebugSession      # the program being debugged
    var dbg_source: String     # its main source file
    var bps: Breakpoints       # where the debugger is to stop
    var dbg_temp_path: String  # Run to cursor: the line to stop at once ('' = none)
    var dbg_temp_line: Int
    var dview: DebugView       # what the Debug window shows
    var dv_scope_seq: Int      # the scopes request of the frame shown (-1: none)
    var dv_var_seqs: List[Int] # variables requests, and the node each one is for
    var dv_var_paths: List[String]
    var dv_write_seq: Int      # a value being set
    var dv_set: Int            # the node the Set value dialog is for
    var dv_watch_seqs: List[Int]   # evaluate requests of the watches, and which watch
    var dv_watch_idx: List[Int]
    var dv_eval_seq: Int       # the Evaluate dialog's request
    var dv_eval_expr: String
    var dv_watch_edit: Int     # the watch the dialog edits (-1: a new one)
    var cpu: CpuView           # what the CPU window shows
    var tshell: TermSession    # Window > Terminal
    var trun: TermSession      # the program Run started
    var trepl: TermSession     # the Mojo REPL
    var test_files: List[TestFile]  # the test explorer's files and tests
    var git: GitStatus         # `git status` of the project's repository (explorer colours)
    var git_proc: Proc         # the git command running now (one at a time)
    var git_req: Int           # what it was asked: GQ_*
    var git_req_path: String   # for GQ_BASE: the file
    var git_out: List[UInt8]   # what it has printed so far
    var git_status_due: Bool   # status is to be asked again
    var git_status_ns: Int     # when it was last asked
    var git_index: FileSig     # the index file as it was when last looked at
    var git_checked_ns: Int    # when the index was last looked at
    var git_ok: Bool           # git may run for the project's repository (folder trust)
    var git_q_req: List[Int]   # git commands waiting for git_proc: GQ_*, the command, the file
    var git_q_cmd: List[String]
    var git_q_path: List[String]
    var git_stamp: Int         # counts what came from git (the diff view compares it)
    var gd_path: String        # the diff view's file ('' when it is not open)
    var gd_staged: Bool        # it shows the index against HEAD (else the buffer against the index)
    var gd_head: String        # the file as in HEAD (gd_head_state GB_KNOWN)
    var gd_head_state: Int     # GB_*: GB_NONE = not in HEAD (a new file)
    var gd_rows: List[DiffRow] # what the view shows, row by row
    var gd_hunks: List[Hunk]
    var gd_stamp: Int          # the state the rows were made for
    var git_tmp_n: Int         # numbers the files staged text is written to
    var git_branches: List[String]  # the branch dialog's branches
    var git_status_paths: List[String]
    var git_status_staged: List[Bool]
    var git_line_blame: Bool
    var git_inline_path: String
    var git_inline_ver: Int
    var git_inline_rows: List[BlameLine]
    var git_inline_asking: Bool
    var pixi_env: String
    var lsp_auto_start: Bool
    var format_on_save: Bool
    var blame_path: String     # the blame window's file
    var explain_path: String   # the editor an error explanation stands beside
    var docpane_key: String    # the file and name the docs pane was last asked about
    var docpane_due: Int       # when the docs pane looks up the name at the cursor (0: not waiting)
    var docpane_entry: Int     # the documentation index entry the pane shows (-1: none)
    var docpane_name: String   # the name it shows
    var docpane_md: String     # raw Markdown shown in the docs pane (for rich redraw & snippets)
    var docpane_lines: List[MdLine]
    var docpane_lines_w: Int
    var hover_pane: Bool       # the language server's answer goes to the docs pane
    var agent_explaining: Bool # the agent's turn answers an explain request (its imports get checked)
    var explain_rect: List[Int]  # that editor's place before it made room (x, y, w, h)
    var explain_md: String     # raw Markdown shown in the explanation window
    var explain_lines: List[MdLine]
    var explain_lines_w: Int
    var puzzle_env_dir: String # folder where D_PUZZLE_ENV runs `pixi install`
    var blame_rows: List[BlameLine]
    var prob_build: List[Problem]   # the last build's errors and warnings (Problems page)
    var prob_filter: ProblemFilter  # what the Problems page shows
    var prob_counts: Tuple[Int, Int, Int]   # errors, warnings, shown - for the page's tab
    var out_filter: String          # the Message page shows only lines with this
    var out_filtered: Bool
    var out_full: List[String]      # the Message page's lines before filtering
    var agent_command: String       # tools.agent: the ACP agent to run ('' = none)
    var agent_mode: String          # tools.agent_mode
    var mcp_names: List[String]
    var mcp_cmds: List[String]
    var mcp_args: List[List[String]]
    var mcp_env_keys: List[List[String]]
    var mcp_env_vals: List[List[String]]
    var agent: AcpClient            # the coding agent (File > Agent panel)
    var chat: AgentChat             # the conversation with it
    var agent_input: List[Int]      # the prompt being written
    var agent_cur: Int              # the cursor in it
    var agent_scroll: Int           # rows scrolled back from the end of the conversation
    var agent_lines: List[MdLine]   # the conversation rendered (for chat.version, width)
    var agent_lines_ver: Int
    var agent_lines_w: Int
    var agent_pending: String       # a prompt written before the session was open (JSON blocks)
    var agent_terms: List[AgentTerm]    # the agent's terminals (commands it runs)
    var agent_asks: List[RunAsk]    # commands waiting for the user's Y / N
    var agent_props: List[Proposal] # files the agent wants written, waiting for A / R
    var agent_term_n: Int
    var gd_proposal: Bool           # the diff view shows agent_props[0]
    var agent_perms: List[AcpEvent] # permission requests waiting for the user's answer
    var agent_allowed: List[String] # allowed for this session (agentsvc.allow_key)
    var agent_sessions_dir: String  # where per-project session ids are kept ('' in tests)
    var ide_state_path: String      # live IDE state & diagnostics JSON for MCP ('' in tests)
    var agent_history: List[String] # prompts sent in this session (Alt-Up / Alt-Down)
    var agent_hist_idx: Int         # index into agent_history (-1: editing current draft)
    var agent_draft: List[Int]      # unsent prompt kept while browsing agent_history
    var agent_at_start: Int         # index of '@' in agent_input while picking a file
    var agent_files: List[String]   # relative paths offered by D_AGENT_FILE
    var test_rows_file: List[Int]   # per line of its window: the file (-1: none)
    var test_rows_test: List[Int]   #   and the test (-1: the file's line, -2: a problem line)
    var test_target_file: Int
    var test_target_test: Int
    var dbg_override_on: Bool
    var dbg_override_args: String
    var test_list_only: Bool        # the running job only lists (--skip-all)
    var test_only_run: Bool         # ... or runs some tests (--only): the others keep their results
    var run_in_terminal: Bool  # Run uses the Run window (else the user screen, as before)
    var shell_program: String  # what Window > Terminal starts ($SHELL)
    var cpu_dis_seq: Int       # its requests: disassembly, register scopes, sets, values, memory
    var cpu_scope_seq: Int
    var cpu_set_seq: Int
    var cpu_reg_seq: Int
    var cpu_vreg_seq: Int
    var cpu_mem_seq: Int
    var cpu_addr_seq: Int      # Go to: a variable's address
    var bp_stamp: Int          # changes with every change of the list
    var bp_dir: String         # where the lists are kept, one file per project ('' = not kept)
    var bp_edit: Int           # the breakpoint the dialog edits (-1: a new one at bp_edit_path/line)
    var bp_edit_path: String
    var bp_edit_line: Int
    var include_paths: List[String]   # extra -I folders, already made absolute
    var docs_paths: List[String]     # folders of library sources to find documentation in
    var doc_idx: List[SymbolIndex]   # one index per docs folder
    var doc_files: List[String]      # files `mojo doc` has been run on ...
    var doc_sizes: List[Int]         # ... their size and time then ...
    var doc_times: List[Int]
    var doc_entries: List[List[DocEntry]]    # ... and what it said
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
    var comp_srv_idx: List[Int]      # index in comp_srv (-1 for text/keyword completions)
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
    var def_is_type: Bool
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
    var tiled: Bool                  # the tiled layout (panes with tabs) instead of overlapping windows
    var lay: Layout
    var next_wid: Int
    var tab_x0: List[Int]            # where tab labels were drawn (for the mouse): columns, row, window id
    var tab_x1: List[Int]
    var tab_y: List[Int]
    var tab_wid: List[Int]
    var msg_page: Int                # which page the bottom panel shows (PG_*)
    var pg_text: List[List[Int]]     # the pages that are not showing: their text ...
    var pg_errs: List[List[ErrLoc]]  # ... the places their lines stand for ...
    var pg_idx: List[Int]            # ... the place last gone to ...
    var pg_cr: List[Int]             # ... and the marked line
    var pg_search: List[Bool]
    var panel_pinned: Bool           # the user (or a build, a search) chose the page: problems update behind it
    var ex: ExplorerTree             # what the file explorer shows
    var ex_checked_ns: Int           # when the folders were last read again
    var ex_op: Int                   # the operation the open explorer dialog is for (EXOP_*)
    var ex_target: String            # ... and the file or folder it is about
    var trash_dir: String            # where deleted files go
    var fidx: FileIndex              # the project's files, for the palette
    var frec: Frecency               # which files were opened how often and when
    var cmd_rec: Frecency            # the commands chosen by name, used last first
    var cmd_rec_path: String         #   where that is kept ('' = not kept)
    var event_seq: Int               # events handled so far (F6's chain: presses in a row)
    var f6_seq: Int                  #   the event of the last Next / Previous window
    var f6_chain: List[Int]          #   the windows (wid), used last first, when the chain began
    var f6_at: Int                   #   where in it the chain is
    var frec_path: String            # where that is kept ('' = not kept)
    var quick_mode: Int              # what the open palette lists (QM_*)
    var quick_text: String           # its field when the list was last matched
    var quick_files: List[String]
    var quick_syms: List[OutlineItem]
    var quick_building: Bool
    var pixi_cmd: String             # how pixi is called
    var pixi_for: String             # the folder pixi_found was looked up for
    var pixi_found: String           # the folder with pixi.toml at or above it ('' if none)
    var tasks: List[PixiTask]        # what the open task list offers
    var last_task: String
    var msg_base: String             # relative paths in messages start here ('' = where the IDE runs)
    var run_cfgs: List[RunConfig]    # the project's run configurations (as last read)
    var run_active: String           # the one Run uses ('' = the file being edited)
    var run_edit_old: String         # the configuration the open edit dialog began with ('' = a new one)
    var restore_session: Bool        # ui.restore_session
    var explorer_at_start: Bool      # ui.explorer (opened once the screen size is known)
    var session_dir: String          # where sessions are kept ('' = they are not)
    var session_saved: String        # the session as last written
    var session_checked_ns: Int
    var restoring: Bool              # files are being opened for a session, not by the user
    var trust: TrustStore            # the folders the user trusts
    var trust_path: String           # where that list is kept
    var trust_enforced: Bool         # off in tests and wherever nobody could answer the question
    var trust_cmd: Int               # the command that waits for the answer (0 = none)
    var trust_held: Bool             # tool commands of the project file are not in use
    var doc_home: String             # where the downloaded documentation is
    var doc_lib: DocLibrary
    var doc_loaded: Bool
    var doc_rows: List[Int]          # the contents as shown: indexes into doc_lib.pages (hits first while searching)
    var doc_open_books: List[String] # titles of the books whose chapters are shown
    var doc_closed_heads: List[String] # collapsed chapter headings inside open books
    var doc_page_query: String       # last Ctrl-F query inside the documentation reader
    var doc_row: Int                 # the marked line of the contents
    var doc_toc_top: Int
    var doc_path: String             # the file the page pane shows ('' = the welcome page)
    var doc_lines: List[MdLine]
    var doc_links: List[String]
    var doc_images: List[String]     # the pictures the page shows (their files), by MdLine.img
    var doc_img_ids: List[Int]       # ...the id each has in the terminal (0: not sent yet)
    var doc_img_size: List[Int]      # ...cols << 16 | rows
    var images_mode: String          # ui.images: auto | kitty | off
    var gfx_on: Bool                 # pictures are shown (kitty graphics; decided at start)
    var gfx_tmux: Bool               # ...through tmux (commands passed through)
    var gfx_sixel: Bool              # ...as sixel (else kitty graphics)
    var gfx_cell_w: Int              # a cell in pixels (the terminal's, else 10 x 20)
    var gfx_cell_h: Int
    var gfx_emit: String             # sixel pictures to draw after the frame
    var gfx_page_bg: Int             # the page's background colour (cells under a sixel)
    var doc_img_sixel: List[String]  # each picture as sixel ('' with kitty graphics)
    var doc_img_at: List[Int]        # where its first row was drawn this frame (y << 16 | x, -1)
    var doc_img_vis: List[Int]       # how many of its rows were drawn this frame
    var doc_img_shown: List[Int]     # where it was last drawn as sixel (-1: not on screen)
    var gfx_out: String              # graphics commands to send before the next frame
    var gfx_next: Int                # the next image id to use
    var gfx_diac: List[Int]          # the row / column marks of the placeholder cells
    var doc_width: Int               # the width the page was laid out for
    var doc_scroll: Int
    var doc_link: Int                # the link under Enter (-1 = none)
    var doc_focus: Int               # 0 the contents, 1 the page
    var doc_back: List[String]       # pages gone through, "scroll<TAB>path"
    var doc_fwd: List[String]
    var doc_index: DocIndex          # every title, heading, declaration and line, for the finder
    var doc_found: List[Found]       # what the open finder lists
    var doc_find_text: String        # its field when the list was made
    var doc_find_back: Bool          # the finder was opened from the reader: closing it returns there
    var doc_mark: String             # what to highlight in the page (the word looked for)
    var sigtip: SigInfo                # the parameter tip shown above the cursor
    var sig_raw: String                # raw signatureHelp result JSON for overload cycling
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
    var aux_job: Job
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
    var lsp_pool: List[LspClient]
    var lsp_pool_keys: List[String]
    var lsp_auto_checked: Bool
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
    var quiet_on: Bool               # Options > Quiet code colours
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
    var indent_guides: Bool
    var rulers: List[Int]
    var next_clone_group: Int
    var ipc_dir: String
    var agent_snap_paths: List[String]
    var agent_snap_before: List[String]
    var agent_snap_existed: List[Bool]
    var agent_changed_files: List[String]
    var dbg_gpu_block: String
    var dbg_gpu_thread: String
    var max_model_args: String
    var max_presets: List[String]
    var max_cmds: List[String]
    var snip_wid: Int
    var snip_rows: List[Int]
    var snip_c1: List[Int]
    var snip_c2: List[Int]
    var snip_nums: List[Int]
    var snip_idx: Int
    var comp_srv_extra: Int
    var def_srv: Int
    var ref_srv: Int
    var ren_srv: Int
    var act_srv: Int
    var sig_srv: Int
    var ren_local: Bool
    var gd_side_by_side: Bool
    var cell_advance: Bool
    var cell_tmp_path: String
    var cell_line_map: List[Int]
    var cell_mojo_proc: Proc
    var cell_mojo_env: String
    var cell_mojo_preamble: String
    var cell_py_proc: Proc
    var cell_py_env: String
    var cell_py_preamble: String
    var cell_k_active: Bool
    var cell_k_is_py: Bool
    var cell_k_seq: Int
    var cell_k_t0: Int
    var cell_k_path: String
    var cell_k_title: String
    var cell_k_index: Int
    var cell_k_header_row: Int
    var cell_k_code_row: Int
    var cell_last_plots: List[String]
    var cell_k_buf: List[UInt8]
    var cell_k_interrupt_ns: Int
    var cell_queue_target: String
    var cell_queue_indices: List[Int]
    var cell_exec_counter: Int
    var codegen_line_map: List[Int]
    var codegen_base_marks: List[Int]
    var codegen_sync_row: Int
    var codegen_sync_cg_row: Int
    var bench_baseline_json: String
    var max_bench_out_file: String
    var max_baseline_json: String
    var test_watch_on: Bool
    var test_cache_dir: String
    var dbg_post_mortem: Bool
    var dbg_attached_pid: Int
    var dbg_core_entries: List[String]
    var peek_title: String
    var peek_lines: List[String]
    var peek_paths: List[String]
    var peek_rows: List[Int]
    var peek_cols: List[Int]
    var peek_idx: Int
    var peek_scroll: Int
    var peek_is_hunk: Bool
    var user_snippets: List[SnippetTemplate]
    var user_snippets_loaded: Bool
    var rainbow_brackets: Bool
    var drag_split_node: Int
    var drag_split_col: Bool
    var drag_scroll_wi: Int
    var drag_minimap_wi: Int
    var git_log_shas: List[String]
    var git_log_file: String
    var git_stash_refs: List[Int]
    var git_wt_paths: List[String]
    var mru_paths: List[String]
    var agent_slash_open: Bool
    var agent_slash_sel: Int
    var tshells: List[TermSession]
    var tshell_idx: Int
    var ssh_ports_toasted: List[Int]
    var hier_paths: List[String]
    var hier_rows: List[Int]
    var hier_cols: List[Int]
    var fmt_req_id: Int
    var fmt_req_srv: Int
    var fmt_req_path: String
    var reader_last_scope: String
    var reader_last_wid: Int
    var vim_zen: Bool          # chromeless full-screen Whole-Vim mode (`tmide vim`)

    def __init__(out self):
        self.term = Terminal()
        var sz = self.term.size()
        self.scr = Screen(sz[0], sz[1])
        self.theme_idx = 0
        self.themes = ThemeSet()
        self.theme_id = "classic"
        self.theme_dark_id = "midnight"
        self.theme_light_id = "light"
        self.scanlines_cfg = -1
        self.scheme_seen = 0
        self.desktop_scheme = 0
        self.desktop_checked_ns = 0
        self.bg_asked_ns = 0
        self.theme_before = ""
        self.theme_marker = ""
        self.np_offer = False
        self.setup_offer = False
        self.setup_list = List[SetupItem]()
        self.term_probed = False
        self.term_kitty_keys = False
        self.caps_lines = List[String]()
        self.gpu_status_on = False
        self.gpu_asked = False
        self.gpu_query = GPU_QUERY
        self.gpu_fp = 0
        self.gpu_fd = -1
        self.gpu_out = List[UInt8]()
        self.gpu_item = ""
        self.gpu_mon_query = GPU_TELEMETRY_QUERY
        self.gpu_mon_fp = 0
        self.gpu_mon_fd = -1
        self.gpu_mon_out = List[UInt8]()
        self.gpu_mon_last_ns = 0
        self.gpu_mon_hist = List[List[Int]]()
        self.codegen_mode = 0
        self.codegen_path = ""
        self.codegen_out_file = ""
        self.codegen_filter = ""
        self.run_t0_ns = 0
        self.run_label = ""
        self.run_file = ""
        self.run_wants_gpu = False
        self.lsp_env = ""
        self.lsp_front = ""
        self.pkg_lsp_again = False
        self.pkg_asked = List[String]()
        self.pkg_kind = 0
        self.pkg_module = ""
        self.pkg_package = ""
        self.pkg_dir = ""
        self.pkg_file = ""
        self.pkg_after = 0
        self.report_path = ""
        self.notes = NotifyCenter()
        self.toast_rows = List[Int]()
        self.toast_y0 = List[Int]()
        self.toast_y1 = List[Int]()
        self.toast_x = 1 << 30
        self.help_dir = ""
        self.reader = False
        self.breadcrumbs = True
        self.sticky_scroll = True
        self.minimap_on = False
        self.minimap_blocks = False
        self.focused = True
        self.dim_unfocused = True
        self.note_label = ""
        self.bells = 0
        self.scopes_stale = False
        self.language = "en"
        self.strings_dir = ""
        self.key_hints = True
        self.tips_on = True
        self.tip_rules = TipRules()
        self.tips_shown = List[String]()
        self.tips_file = ""
        self.ex_home = ""
        self.plugins = List[Plugin]()
        self.plugins_dir = ""
        self.plugins_log_dir = ""
        self.plugins_on = True
        self.plugin_warnings = List[String]()
        self.panels = List[PluginPanel]()
        self.lsp_extra = List[ExtraServer]()
        self.hover_srv = -1
        self.chord_since = 0
        self.typed_ns = 0
        self.plugin_asked = -1
        self.plugin_focused_path = ""
        self.link_format = "file://{host}{path}"
        self.link_host = ""
        self.last_osc52 = ""
        self.plugin_asked_ns = 0
        self.chord_box = False
        self.key_uses = Dict[String, Int]()
        self.key_uses_path = ""
        self.reduce_motion = False
        self.reduced_motion_cfg = -1
        self.pal = theme(0)
        self.hl = Highlighter()
        self.wins = List[Window]()
        self.buffers = List[TextBuffer]()
        self.reg = build_registry()
        self.vim = VimState()
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
        self.rel_numbers = False
        self.auto_indent = True
        self.hl_line = True
        self.insert_mode = True
        self.show_clock = True
        self.clock_fixed = ""
        self.mojo_checked = False
        self.mojo_warning = ""
        self.running = True
        self.find_text = List[Int]()
        self.replace_text = List[Int]()
        self.find_filter = ""
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
        self.debug_adapter = env_or("TURBOMOJO_DAP", "mojo-lldb-dap")
        self.dbg = DebugSession()
        self.dbg_source = ""
        self.bps = Breakpoints()
        self.dbg_temp_path = ""
        self.dbg_temp_line = 0
        self.dbg_override_on = False
        self.dbg_override_args = ""
        self.dview = DebugView()
        self.dv_scope_seq = -1
        self.dv_var_seqs = List[Int]()
        self.dv_var_paths = List[String]()
        self.dv_write_seq = -1
        self.dv_set = -1
        self.dv_watch_seqs = List[Int]()
        self.dv_watch_idx = List[Int]()
        self.dv_eval_seq = -1
        self.dv_eval_expr = ""
        self.dv_watch_edit = -1
        self.cpu = CpuView()
        self.tshell = TermSession()
        self.trun = TermSession()
        self.trepl = TermSession()
        self.test_files = List[TestFile]()
        self.git = GitStatus()
        self.git_proc = Proc()
        self.git_req = 0
        self.git_req_path = ""
        self.git_out = List[UInt8]()
        self.git_status_due = True
        self.git_status_ns = 0
        self.git_index = FileSig()
        self.git_checked_ns = 0
        self.git_ok = False
        self.git_q_req = List[Int]()
        self.git_q_cmd = List[String]()
        self.git_q_path = List[String]()
        self.git_stamp = 0
        self.gd_path = ""
        self.gd_staged = False
        self.gd_head = ""
        self.gd_head_state = 0
        self.gd_rows = List[DiffRow]()
        self.gd_hunks = List[Hunk]()
        self.gd_stamp = -1
        self.git_tmp_n = 0
        self.git_branches = List[String]()
        self.git_status_paths = List[String]()
        self.git_status_staged = List[Bool]()
        self.git_line_blame = False
        self.git_inline_path = ""
        self.git_inline_ver = -1
        self.git_inline_rows = List[BlameLine]()
        self.git_inline_asking = False
        self.pixi_env = "default"
        self.lsp_auto_start = False
        self.format_on_save = False
        self.blame_path = ""
        self.explain_path = ""
        self.docpane_key = ""
        self.docpane_due = 0
        self.docpane_entry = -1
        self.docpane_name = ""
        self.docpane_md = ""
        self.docpane_lines = List[MdLine]()
        self.docpane_lines_w = -1
        self.hover_pane = False
        self.agent_explaining = False
        self.explain_rect = List[Int]()
        self.explain_md = ""
        self.explain_lines = List[MdLine]()
        self.explain_lines_w = -1
        self.puzzle_env_dir = ""
        self.blame_rows = List[BlameLine]()
        self.prob_build = List[Problem]()
        self.prob_filter = ProblemFilter()
        self.prob_counts = (0, 0, -1)          # (-1: the filter hides none)
        self.out_filter = ""
        self.out_filtered = False
        self.out_full = List[String]()
        self.agent_command = env_or("TURBOMOJO_AGENT", "")
        self.agent_mode = "ask"
        self.mcp_names = List[String]()
        self.mcp_cmds = List[String]()
        self.mcp_args = List[List[String]]()
        self.mcp_env_keys = List[List[String]]()
        self.mcp_env_vals = List[List[String]]()
        self.agent = AcpClient()
        self.chat = AgentChat()
        self.agent_input = List[Int]()
        self.agent_cur = 0
        self.agent_scroll = 0
        self.agent_lines = List[MdLine]()
        self.agent_lines_ver = -1
        self.agent_lines_w = -1
        self.agent_pending = ""
        self.agent_terms = List[AgentTerm]()
        self.agent_asks = List[RunAsk]()
        self.agent_props = List[Proposal]()
        self.agent_term_n = 0
        self.gd_proposal = False
        self.agent_perms = List[AcpEvent]()
        self.agent_allowed = List[String]()
        self.agent_sessions_dir = ""
        self.ide_state_path = ""
        self.agent_history = List[String]()
        self.agent_hist_idx = -1
        self.agent_draft = List[Int]()
        self.agent_at_start = -1
        self.agent_files = List[String]()
        self.test_rows_file = List[Int]()
        self.test_rows_test = List[Int]()
        self.test_target_file = -1
        self.test_target_test = -1
        self.test_list_only = False
        self.test_only_run = False
        self.run_in_terminal = True
        self.shell_program = env_or("SHELL", "/bin/sh")
        self.cpu_dis_seq = -1
        self.cpu_scope_seq = -1
        self.cpu_set_seq = -1
        self.cpu_reg_seq = -1
        self.cpu_vreg_seq = -1
        self.cpu_mem_seq = -1
        self.cpu_addr_seq = -1
        self.bp_stamp = 0
        self.bp_dir = ""
        self.bp_edit = -1
        self.bp_edit_path = ""
        self.bp_edit_line = 0
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
        self.comp_srv_idx = List[Int]()
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
        self.def_is_type = False
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
        self.docs_paths = List[String]()
        self.doc_idx = List[SymbolIndex]()
        self.doc_files = List[String]()
        self.doc_sizes = List[Int]()
        self.doc_times = List[Int]()
        self.doc_entries = List[List[DocEntry]]()
        self.tiled = False
        self.lay = Layout()
        self.next_wid = 1
        self.tab_x0 = List[Int]()
        self.tab_x1 = List[Int]()
        self.tab_y = List[Int]()
        self.tab_wid = List[Int]()
        self.msg_page = PG_MESSAGE
        self.pg_text = List[List[Int]]()
        self.pg_errs = List[List[ErrLoc]]()
        self.pg_idx = List[Int]()
        self.pg_cr = List[Int]()
        self.pg_search = List[Bool]()
        for _ in range(PG_COUNT):
            self.pg_text.append(List[Int]())
            self.pg_errs.append(List[ErrLoc]())
            self.pg_idx.append(-1)
            self.pg_cr.append(0)
            self.pg_search.append(False)
        self.panel_pinned = False
        self.ex = ExplorerTree()
        self.ex_checked_ns = 0
        self.ex_op = 0
        self.ex_target = ""
        self.trash_dir = default_trash_dir()
        self.fidx = FileIndex()
        self.frec = Frecency()
        self.cmd_rec = Frecency()
        self.cmd_rec_path = ""
        self.event_seq = 0
        self.f6_seq = -5
        self.f6_chain = List[Int]()
        self.f6_at = 0
        self.frec_path = ""
        self.quick_mode = -1
        self.quick_text = ""
        self.quick_files = List[String]()
        self.quick_syms = List[OutlineItem]()
        self.quick_building = False
        self.pixi_cmd = "pixi"
        self.pixi_for = "\x01"
        self.pixi_found = ""
        self.tasks = List[PixiTask]()
        self.last_task = ""
        self.msg_base = ""
        self.run_cfgs = List[RunConfig]()
        self.run_active = ""
        self.run_edit_old = ""
        self.restore_session = True
        self.explorer_at_start = False
        self.session_dir = ""
        self.session_saved = ""
        self.session_checked_ns = 0
        self.restoring = False
        self.trust = TrustStore()
        self.trust_path = ""
        self.trust_enforced = False
        self.trust_cmd = 0
        self.trust_held = False
        self.doc_home = default_docs_home()
        self.doc_lib = DocLibrary()
        self.doc_loaded = False
        self.doc_rows = List[Int]()
        self.doc_open_books = List[String]()
        self.doc_closed_heads = List[String]()
        self.doc_page_query = ""
        self.doc_row = 0
        self.doc_toc_top = 0
        self.doc_path = ""
        self.doc_lines = List[MdLine]()
        self.doc_links = List[String]()
        self.doc_images = List[String]()
        self.doc_img_ids = List[Int]()
        self.doc_img_size = List[Int]()
        self.images_mode = "auto"
        self.gfx_on = False
        self.gfx_tmux = False
        self.gfx_sixel = False
        self.gfx_cell_w = 10
        self.gfx_cell_h = 20
        self.gfx_emit = ""
        self.gfx_page_bg = 0
        self.doc_img_sixel = List[String]()
        self.doc_img_at = List[Int]()
        self.doc_img_vis = List[Int]()
        self.doc_img_shown = List[Int]()
        self.gfx_out = ""
        self.gfx_next = GFX_FIRST_ID
        self.gfx_diac = List[Int]()
        self.doc_width = 0
        self.doc_scroll = 0
        self.doc_link = -1
        self.doc_focus = 0
        self.doc_back = List[String]()
        self.doc_fwd = List[String]()
        self.doc_index = DocIndex()
        self.doc_found = List[Found]()
        self.doc_find_text = ""
        self.doc_find_back = False
        self.doc_mark = ""
        self.sigtip = SigInfo()
        self.sig_raw = ""
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
        self.aux_job = Job()
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
        self.lsp_pool = List[LspClient]()
        self.lsp_pool_keys = List[String]()
        self.lsp_auto_checked = False
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
        self.quiet_on = False
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
        self.indent_guides = False
        self.rulers = List[Int]()
        self.next_clone_group = 1
        self.ipc_dir = ""
        self.agent_snap_paths = List[String]()
        self.agent_snap_before = List[String]()
        self.agent_snap_existed = List[Bool]()
        self.agent_changed_files = List[String]()
        self.dbg_gpu_block = "0,0,0"
        self.dbg_gpu_thread = "0,0,0"
        self.max_model_args = ""
        self.max_presets = List[String]()
        self.max_cmds = List[String]()
        self.snip_wid = -1
        self.snip_rows = List[Int]()
        self.snip_c1 = List[Int]()
        self.snip_c2 = List[Int]()
        self.snip_nums = List[Int]()
        self.snip_idx = 0
        self.comp_srv_extra = -1
        self.def_srv = -1
        self.ref_srv = -1
        self.ren_srv = -1
        self.act_srv = -1
        self.sig_srv = -1
        self.ren_local = False
        self.gd_side_by_side = False
        self.cell_advance = False
        self.cell_tmp_path = ""
        self.cell_line_map = List[Int]()
        self.cell_mojo_proc = Proc()
        self.cell_mojo_env = ""
        self.cell_mojo_preamble = ""
        self.cell_py_proc = Proc()
        self.cell_py_env = ""
        self.cell_py_preamble = ""
        self.cell_k_active = False
        self.cell_k_is_py = False
        self.cell_k_seq = 0
        self.cell_k_t0 = 0
        self.cell_k_path = ""
        self.cell_k_title = ""
        self.cell_k_index = -1
        self.cell_k_header_row = -1
        self.cell_k_code_row = 0
        self.cell_last_plots = List[String]()
        self.cell_k_buf = List[UInt8]()
        self.cell_k_interrupt_ns = 0
        self.cell_queue_target = ""
        self.cell_queue_indices = List[Int]()
        self.cell_exec_counter = 0
        self.codegen_line_map = List[Int]()
        self.codegen_base_marks = List[Int]()
        self.codegen_sync_row = -1
        self.codegen_sync_cg_row = -1
        self.bench_baseline_json = ""
        self.max_bench_out_file = ""
        self.max_baseline_json = ""
        self.test_watch_on = False
        self.test_cache_dir = ""
        self.dbg_post_mortem = False
        self.dbg_attached_pid = 0
        self.dbg_core_entries = List[String]()
        self.peek_title = ""
        self.peek_lines = List[String]()
        self.peek_paths = List[String]()
        self.peek_rows = List[Int]()
        self.peek_cols = List[Int]()
        self.peek_idx = 0
        self.peek_scroll = 0
        self.peek_is_hunk = False
        self.user_snippets = List[SnippetTemplate]()
        self.user_snippets_loaded = False
        self.rainbow_brackets = False
        self.drag_split_node = -1
        self.drag_split_col = False
        self.drag_scroll_wi = -1
        self.drag_minimap_wi = -1
        self.git_log_shas = List[String]()
        self.git_log_file = ""
        self.git_stash_refs = List[Int]()
        self.git_wt_paths = List[String]()
        self.mru_paths = List[String]()
        self.agent_slash_open = False
        self.agent_slash_sel = 0
        self.tshells = List[TermSession]()
        self.tshell_idx = -1
        self.ssh_ports_toasted = List[Int]()
        self.hier_paths = List[String]()
        self.hier_rows = List[Int]()
        self.hier_cols = List[Int]()
        self.fmt_req_id = -1
        self.fmt_req_srv = -1
        self.fmt_req_path = ""
        self.reader_last_scope = ""
        self.reader_last_wid = -1
        self.vim_zen = False

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

    def motion_apply(mut self):
        """Screen-reader mode and reduced motion as the settings (and, for "auto", the
        desktop) have them."""
        self.scr.plain = self.reader
        if self.reader or self.reduced_motion_cfg == 1:
            self.reduce_motion = True
        elif self.reduced_motion_cfg == 0:
            self.reduce_motion = False
        else:
            var g = String("")
            if which("gsettings").byte_length() > 0:
                g = bytes_to_str(run_capture("gsettings get org.gnome.desktop.interface enable-animations 2>/dev/null").out)
            self.reduce_motion = animations_off(g)

    def theme_apply(mut self):
        """Use the theme ui.theme names (for "auto": the dark or light one, as the
        terminal says; dark until it has said), in its colours for the terminal's
        colour depth."""
        var id = self.theme_id
        if id == "auto":
            # the terminal's word first (mode 2031); else its background's lightness
            # (OSC 11); else the desktop's (GNOME Terminal does not say)
            var scheme = self.term.scheme if self.term.scheme != 0 else (self.term.bg_scheme if self.term.bg_scheme != 0 else self.desktop_scheme)
            id = self.theme_light_id if scheme == 2 else self.theme_dark_id
            self.scheme_seen = scheme
        var k = self.themes.find(id)
        if k < 0:
            self.config_warnings.append("ui.theme: there is no theme \"" + id + "\" (themes: " + ", ".join(self.themes.ids) + ")")
            k = 0
        self.theme_idx = k
        self.pal = self.themes.for_depth(k, self.scr.color_mode)
        if self.scanlines_cfg >= 0:
            self.pal.scanlines = self.scanlines_cfg == 1
        if self.quiet_on:
            self.pal.syn = quiet_syntax(self.pal)

    def desktop_scheme_now(self) -> Int:
        var g = String("")
        if which("gsettings").byte_length() > 0:
            g = bytes_to_str(run_capture("gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null").out)
        return scheme_from(env_or("COLORFGBG", ""), g)

    def background_recheck(mut self, now_too: Bool):
        """Ask a terminal that reports its background colour (OSC 11) but not its light
        or dark (mode 2031) again: when it gets the focus back (`now_too`) and at most
        every half minute while the IDE is in use - so a change of its colour scheme is
        followed. The reply comes as input and changes the theme in theme_tick."""
        if self.theme_id != "auto" or self.term.scheme != 0 or self.term.caps.background < 0:
            return
        var now = Int(now_ns())
        if now_too or now - self.bg_asked_ns > 30 * 1000000000:
            self.bg_asked_ns = now
            append_str(self.term.out, OSC11_QUERY)

    def theme_tick(mut self):
        """Follow the terminal's light or dark (mode 2031; or its background colour,
        asked again now and then) - or, when it says neither, the desktop's, looked at
        every half minute."""
        if self.theme_id != "auto":
            return
        self.background_recheck(False)
        if self.term.scheme == 0 and self.term.bg_scheme == 0:
            var now = Int(now_ns())
            if self.desktop_checked_ns == 0 or now - self.desktop_checked_ns > 30 * 1000000000:
                self.desktop_checked_ns = now
                self.desktop_scheme = self.desktop_scheme_now()
        var scheme = self.term.scheme if self.term.scheme != 0 else (self.term.bg_scheme if self.term.bg_scheme != 0 else self.desktop_scheme)
        if scheme != self.scheme_seen:
            self.theme_apply()

    def git_watched(self) -> Bool:
        if not self.watch.active() or self.git.root.byte_length() == 0:
            return False
        var dirs = resolve_git_dir(self.git.root)
        var gdir = dirs[0]
        return gdir.byte_length() > 0 and (gdir in self.watch.dirs)

    def next_timeout_ms(self, now: Int, input_pending: Bool, secs_to_minute: Int) -> Int:
        """How long the event loop may sleep before something on screen must change."""
        # With signals on a descriptor a resize wakes the loop by itself; without it
        # (tests, or signalfd unavailable) fall back to checking the size periodically.
        var t = 3600000 if self.sig.active() else RESIZE_POLL_MS
        if self.job.active or self.agent.busy():
            # nothing is shown in the first second (src/progress.mojo): wake when it ends
            var t0 = self.job.t0 if self.job.active else self.agent.prompt_ns
            var ms = (now - t0) // 1000000
            if ms < QUIET_MS:
                t = min(t, QUIET_MS - ms + 1)
            else:
                t = min(t, 1000 if self.reduce_motion else SPINNER_MS)
        if self.symidx.building or self.fidx.building:
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
        if self.git.root.byte_length() > 0:
            if self.git_status_due or len(self.git_q_req) > 0:
                t = min(t, 20)
            elif not self.git_watched():
                t = min(t, 2000)        # look at git's index now and then when not watched by inotify
        if self.scopes_stale:
            t = min(t, 500)
        if self.chord != 0 and not self.chord_box and self.key_hints:
            t = min(t, max(1, (self.chord_since + KEY_BOX_MS * 1000000 - now) // 1000000 + 1))
        if self.docpane_due > 0:
            t = min(t, max(1, (self.docpane_due - now) // 1000000 + 1))
        if self.typed_ns > 0 and self.notes.held_count() > 0:
            t = min(t, max(1, (self.typed_ns + TYPING_PAUSE_MS * 1000000 - now) // 1000000 + 1))
        var tn = self.notes.next_change_ns(now)
        if tn > 0:
            t = min(t, max(1, (tn - now) // 1000000 + 1))     # a toast is due to go
        if self.agent.conn.wants_write():
            t = min(t, 10)
        if self.agent.state == 1:          # AS_STARTING: its time-out must be noticed
            t = min(t, 1000)
        if self.lsp.conn.wants_write():
            t = min(t, 10)
        if self.cell_mojo_proc.wants_write() or self.cell_py_proc.wants_write():
            t = min(t, 10)
        if self.cell_k_active:
            t = min(t, 40)
        if self.dbg.active() and self.dbg.conn.wants_write():
            t = min(t, 10)
        if self.tshell.pty.wants_write() or self.trun.pty.wants_write() or self.trepl.pty.wants_write():
            t = min(t, 10)
        if len(self.trepl.pending) > 0:
            t = min(t, 100)             # code waits for the REPL to be ready
        if self.watch_enabled and not self.watch.active():
            t = min(t, max(1, (self.watch_due - now) // 1000000 + 1))
        if self.ipc_dir.byte_length() > 0 and not (self.watch.active() and (self.ipc_dir in self.watch.dirs)):
            t = min(t, 250)
        for wi in range(len(self.wins)):
            if self.wins[wi].kind == WK_GPU:
                t = min(t, 1500)
                break
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

    def include_dirs_for(self, path: String) -> List[String]:
        """Configured `include_paths` plus zero-config auto-discovered project / `src/`
        include directories for `path` (deduplicated, preserving user priority)."""
        var out = List[String]()
        for ip in self.include_paths:
            if ip.byte_length() > 0:
                out.append(ip)
        if path.byte_length() == 0:
            return out^
        var root = discover_mojo_project_root(path)
        var norm_proj = normalize_path(self.project_dir) if self.project_dir.byte_length() > 0 else String("")
        if root.byte_length() > 0 and root != norm_proj:
            for cfg_name in [".turbomojo.toml", "turbomojo.toml"]:
                var cfg_p = join_path(root, String(cfg_name))
                if path_exists(cfg_p):
                    var sub_s = load_settings("", read_text(cfg_p))
                    for sub_ip in sub_s.include_paths:
                        if sub_ip.byte_length() > 0:
                            var resolved = abs_path(root, sub_ip)
                            var seen = False
                            for ex in out:
                                if ex == resolved:
                                    seen = True
                                    break
                            if not seen:
                                out.append(resolved)
                    break
        for ad in discover_auto_include_dirs(path):
            var seen = False
            for ex in out:
                if ex == ad:
                    seen = True
                    break
            if not seen:
                out.append(ad)
        return out^

    def include_flags_for(self, path: String) -> String:
        """" -I dir" for configured + auto-discovered per-file include folders
        (skipping `dirname(path)` itself, which `mojo` already searches, and skipping
        `<project_root>` when `<project_root>/src` exists so `src/`-layout builds stay minimal)."""
        if path.byte_length() == 0:
            return self.include_flags()
        var out = String("")
        var emitted = List[String]()
        for ip in self.include_paths:
            if ip.byte_length() > 0:
                out += " -I " + shell_quote(ip)
                emitted.append(normalize_path(abs_path(self.cwd, ip)))
        var file_dir = normalize_path(path if is_dir(path) else dirname(path))
        var root = discover_mojo_project_root(path)
        var has_root_src = root.byte_length() > 0 and is_dir(join_path(root, "src"))
        var norm_proj = normalize_path(self.project_dir) if self.project_dir.byte_length() > 0 else String("")
        if root.byte_length() > 0 and root != norm_proj:
            for cfg_name in [".turbomojo.toml", "turbomojo.toml"]:
                var cfg_p = join_path(root, String(cfg_name))
                if path_exists(cfg_p):
                    var sub_s = load_settings("", read_text(cfg_p))
                    for sub_ip in sub_s.include_paths:
                        if sub_ip.byte_length() > 0:
                            var resolved = normalize_path(abs_path(root, sub_ip))
                            if resolved != file_dir and not (resolved in emitted):
                                out += " -I " + shell_quote(resolved)
                                emitted.append(resolved)
                    break
        for ad in discover_auto_include_dirs(path):
            if ad == file_dir:
                continue
            if has_root_src and ad == root:
                continue
            if not (ad in emitted):
                out += " -I " + shell_quote(ad)
                emitted.append(ad)
        return out

    def mojo_repl_import_setup(self, mj_exe: String, dir: String, path: String) -> String:
        """Shell snippet exporting `MODULAR_MOJO_MAX_IMPORT_PATH` for `mojo repl`
        (since `mojo repl` delegates flags to LLDB and rejects `-I`)."""
        var dirs = self.include_dirs_for(path)
        if len(dirs) == 0:
            return ""
        var imps = List[String]()
        if dir.byte_length() > 0:
            imps.append(dir)
        for d in dirs:
            if d.byte_length() > 0:
                var full = abs_path(self.cwd, d)
                var seen = False
                for ex in imps:
                    if ex == full:
                        seen = True
                        break
                if not seen:
                    imps.append(full)
        if len(imps) == 0:
            return ""
        var joined_imps = ",".join(imps)
        return (
            "__tm_std=\"$(dirname \"$(dirname \"$(command -v "
            + mj_exe
            + ")\")\")/lib/mojo\"; [ -d \"$__tm_std\" ] && export MODULAR_MOJO_MAX_IMPORT_PATH="
            + shell_quote(joined_imps)
            + ",\"$__tm_std\"; "
        )

    def compiler_cmd(mut self) -> String:
        """The configured compiler command with the environment it needs."""
        var c = String(self.compiler)
        return self.tool(c)

    def apply_settings(mut self, s: Settings):
        """Take over loaded settings, including custom key bindings."""
        self.themes = ThemeSet()
        self.themes.add_folder(config_home() + "/themes")
        self.theme_id = s.theme
        if not s.theme_given and env_or("NO_COLOR", "").byte_length() > 0:
            self.theme_id = "mono"          # https://no-color.org: the terminal's own colours only
        self.theme_dark_id = s.theme_dark
        self.theme_light_id = s.theme_light
        self.scanlines_cfg = s.scanlines
        self.breadcrumbs = s.breadcrumbs
        self.key_hints = s.key_hints
        self.tips_on = s.tips
        self.plugins_on = s.plugins
        configure_servers(self.lsp_extra, s)
        self.sticky_scroll = s.sticky_scroll
        self.minimap_on = s.minimap
        self.minimap_blocks = s.minimap_style == "blocks" or (s.minimap_style == "auto" and env_or("TERM", "") == "linux")
        self.scr.glyphs = glyphs_of(s.glyphs)
        self.images_mode = s.images
        self.dim_unfocused = s.dim_unfocused
        self.reader = s.screen_reader or env_or("TURBOMOJO_SCREEN_READER", "") == "1" or env_or("TERM", "") == "dumb"
        self.reduced_motion_cfg = s.reduced_motion
        self.motion_apply()
        self.scheme_seen = 0
        self.line_numbers = s.line_numbers
        self.rel_numbers = s.relative_numbers
        self.indent_guides = s.indent_guides
        self.auto_indent = s.auto_indent
        self.hl_line = s.highlight_line
        self.show_clock = s.clock
        self.scr.hyperlinks = s.hyperlinks
        self.link_format = s.hyperlink_format
        self.run_in_terminal = s.run_in_terminal
        self.show_ws = s.show_whitespace
        self.soft_wrap = s.soft_wrap
        self.semantic_on = s.semantic_colors
        self.quiet_on = s.quiet_colors
        self.hints_on = s.inlay_hints
        self.auto_pairs = s.auto_pairs
        self.word_hl = s.highlight_word
        self.rainbow_brackets = s.rainbow_brackets
        self.test_watch_on = s.test_watch
        for i in range(len(self.wins)):
            self.wins[i].word_hl = self.word_hl
            self.wins[i].indent_guides = self.indent_guides
            self.wins[i].rainbow_brackets = self.rainbow_brackets
        self.persistent_undo = s.persistent_undo
        self.trim_trailing = s.trim_trailing
        self.format_on_save = s.format_on_save
        self.git_line_blame = s.line_blame
        self.pixi_env = s.pixi_env
        self.lsp_auto_start = s.lsp_auto_start
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
        self.debug_adapter = env_or("TURBOMOJO_DAP", s.debug_adapter)
        self.agent_command = env_or("TURBOMOJO_AGENT", s.agent)
        self.agent_mode = s.agent_mode
        self.mcp_names = s.mcp_names.copy()
        self.mcp_cmds = s.mcp_cmds.copy()
        var m_args = List[List[String]]()
        for a in s.mcp_args:
            m_args.append(a.copy())
        self.mcp_args = m_args^
        var m_ek = List[List[String]]()
        for ek in s.mcp_env_keys:
            m_ek.append(ek.copy())
        self.mcp_env_keys = m_ek^
        var m_ev = List[List[String]]()
        for ev in s.mcp_env_vals:
            m_ev.append(ev.copy())
        self.mcp_env_vals = m_ev^
        # relative include folders belong to the project file's folder (or where we run)
        self.docs_paths = List[String]()
        self.doc_idx = List[SymbolIndex]()
        for dp in s.docs_paths:
            if dp.byte_length() > 0:
                self.docs_paths.append(abs_path(self.project_dir if self.project_dir.byte_length() > 0 else String(self.cwd), dp))
                self.doc_idx.append(SymbolIndex())
        self.include_paths = List[String]()
        var base = self.project_dir if self.project_dir.byte_length() > 0 else String(self.cwd)
        for ip in s.include_paths:
            if ip.byte_length() > 0:
                self.include_paths.append(abs_path(base, ip))
        self.config_warnings = s.warnings.copy()
        for pr in self.themes.problems:
            self.config_warnings.append("theme " + pr)
        self.theme_apply()
        self.keymap = s.keymap
        self.language = language_from(s.language, env_or("LANG", ""))
        self.restore_session = s.restore_session
        self.explorer_at_start = s.explorer
        self.gpu_status_on = s.gpu_status
        if s.docs_home.byte_length() > 0 and s.docs_home != self.doc_home:
            self.doc_home = s.docs_home
            self.doc_loaded = False
        if s.tiled != self.tiled:
            self.tiled = s.tiled
            self.lay = Layout()
            for i in range(len(self.wins)):
                self.wins[i].hidden = False
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
        # the UI's words in the chosen language
        if self.language != "en" and self.strings_dir.byte_length() > 0:
            var sp = self.strings_dir + "/" + self.language + ".toml"
            if path_exists(sp):
                var w = apply_strings(self.reg, toml_parse(read_text(sp)), "strings/" + self.language + ".toml")
                if warn:
                    for x in w:
                        self.config_warnings.append(x)
        # the commands of the running plugins (in the ≡ menu)
        self.plugin_warnings = register_plugins(self.reg, self.plugins)
        self.menus = build_menus(self.reg)

    def load_config(mut self):
        """Read the user and project config files and apply them."""
        self.config_path = user_config_path()
        var project = find_project_config(self.cwd)
        self.project_dir = dirname(project) if project.byte_length() > 0 else String("")
        var settings = load_settings(read_text(self.config_path), read_text(project))
        self.trust_held = False
        if project.byte_length() > 0 and self.trust_enforced and not self.trust.is_trusted(self.project_dir):
            # a project file may name programs to run (compiler, language servers, debug
            # adapter, agent, plugins): from a folder that is not trusted those are held
            var own = load_settings(read_text(self.config_path), "")
            var lsp_diff = len(settings.lsp_names) != len(own.lsp_names)
            if not lsp_diff:
                for li in range(len(settings.lsp_names)):
                    if settings.lsp_names[li] != own.lsp_names[li] or settings.lsp_cmds[li] != own.lsp_cmds[li]:
                        lsp_diff = True
            var mcp_diff = len(settings.mcp_names) != len(own.mcp_names)
            if not mcp_diff:
                for mi in range(len(settings.mcp_names)):
                    if settings.mcp_names[mi] != own.mcp_names[mi] or settings.mcp_cmds[mi] != own.mcp_cmds[mi]:
                        mcp_diff = True
            if (
                settings.compiler != own.compiler
                or settings.lsp_server != own.lsp_server
                or settings.debug_adapter != own.debug_adapter
                or settings.agent != own.agent
                or settings.plugins != own.plugins
                or lsp_diff
                or mcp_diff
            ):
                settings.compiler = own.compiler
                settings.lsp_server = own.lsp_server
                settings.debug_adapter = own.debug_adapter
                settings.agent = own.agent
                settings.plugins = own.plugins
                settings.lsp_names = own.lsp_names.copy()
                settings.lsp_cmds = own.lsp_cmds.copy()
                var exts_copy = List[List[String]]()
                for ex in own.lsp_exts:
                    exts_copy.append(ex.copy())
                settings.lsp_exts = exts_copy^
                settings.lsp_langs = own.lsp_langs.copy()
                settings.mcp_names = own.mcp_names.copy()
                settings.mcp_cmds = own.mcp_cmds.copy()
                var m_args_c = List[List[String]]()
                for ma in own.mcp_args:
                    m_args_c.append(ma.copy())
                settings.mcp_args = m_args_c^
                var m_ek_c = List[List[String]]()
                for mek in own.mcp_env_keys:
                    m_ek_c.append(mek.copy())
                settings.mcp_env_keys = m_ek_c^
                var m_ev_c = List[List[String]]()
                for mev in own.mcp_env_vals:
                    m_ev_c.append(mev.copy())
                settings.mcp_env_vals = m_ev_c^
                settings.warnings.append("this folder is not trusted: its tool, agent and language server commands are not used (Options > Folder trust)")
                self.trust_held = True
        self.apply_settings(settings)

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
        win.wid = self.next_wid
        self.next_wid += 1
        win.buf.tab_width = self.tab_width
        win.buf.indent_size = self.indent_size
        win.buf_id = len(self.buffers)
        self.buffers.append(win.buf.copy())
        win.wrap = self.soft_wrap
        win.auto_pairs = self.auto_pairs
        win.word_hl = self.word_hl
        win.rulers = self.rulers.copy()
        var xi = self.explorer_index()
        if xi >= 0 and win.x < self.wins[xi].w and win.x + win.w - self.wins[xi].w >= 20:
            win.w -= self.wins[xi].w - win.x        # beside the explorer, not over it
            win.x = self.wins[xi].w
        var oi = self.outline_index()
        if oi >= 0 and win.x + win.w > self.wins[oi].x and self.wins[oi].x - win.x >= 20:
            win.w = self.wins[oi].x - win.x         # beside the outline, not over it
        self.wins.append(win^)
        return len(self.wins) - 1

    def explorer_index(self) -> Int:
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_EXPLORER:
                return i
        return -1

    def docpane_index(self) -> Int:
        for i in range(len(self.wins)):
            if self.wins[i].kind == WK_DOCPANE:
                return i
        return -1

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
        if len(self.pg_text[self.msg_page]) > 0:
            # closed and opened again: the page is as it was
            win.buf.load(self.pg_text[self.msg_page])
            win.buf.modified = False
            win.cr = self.pg_cr[self.msg_page]
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
            elif self.wins[i].half and not self.tiled:
                var hw = W // 2
                self.wins[i].x = W - hw if self.wins[i].half_right else 0
                self.wins[i].y = 1
                self.wins[i].w = hw if self.wins[i].half_right else W - hw
                self.wins[i].h = dh
            else:
                self.wins[i].w = max(16, min(self.wins[i].w, W))
                self.wins[i].h = max(4, min(self.wins[i].h, dh))
                self.wins[i].x = max(0, min(self.wins[i].x, W - self.wins[i].w))
                self.wins[i].y = max(1, min(self.wins[i].y, 1 + dh - self.wins[i].h))

    def osc52(mut self, text: List[Int]):
        """Copy to the terminal's clipboard with OSC 52, wrapped in DCS passthrough when inside tmux."""
        var raw = osc52_seq(text)
        if self.gfx_tmux or env_or("TMUX", "").byte_length() > 0:
            var wrapped = wrap_for_tmux(raw)
            self.last_osc52 = wrapped
            append_str(self.term.out, raw + wrapped)
        else:
            self.last_osc52 = raw
            append_str(self.term.out, raw)
        self.term.flush()

    def is_ssh(self) -> Bool:
        return (
            env_or("SSH_CONNECTION", "").byte_length() > 0
            or env_or("SSH_CLIENT", "").byte_length() > 0
            or env_or("SSH_TTY", "").byte_length() > 0
        )

    def ssh_host(self) -> String:
        var conn = env_or("SSH_CONNECTION", "")
        if conn.byte_length() > 0:
            return parse_ssh_host(conn)
        if self.is_ssh():
            return host_name()
        return ""

    def ssh_pill(self) -> String:
        var h = self.ssh_host()
        if h.byte_length() == 0:
            return ""
        return format_ssh_pill(h)

    def port_forward_toast(mut self, line: String) -> String:
        """Detects port binds from terminal output lines and triggers a toast when running over SSH."""
        var cmd = parse_port_forward(line, self.ssh_host(), self.is_ssh())
        if cmd.byte_length() > 0:
            var now = now_ns()
            self.notes.add_held(NL_INFO, "Port Forward", "Forward port with: " + cmd, now, clock_hm(), False, False)
        return cmd
