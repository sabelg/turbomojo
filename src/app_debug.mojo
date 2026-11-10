"""Debugging: building a program with debug information, running it under Mojo's
debug adapter and showing what happens (see dap.mojo)."""
from std.collections import List, Dict
from std.time import perf_counter_ns
from std.ffi import external_call
from term import (
    Terminal, Event, EV_KEY, EV_MOUSE, EV_PASTE, K_BASE, KEY_ESC, KEY_ENTER, KEY_TAB,
    KEY_BACKSPACE, KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_HOME, KEY_END, KEY_PGUP,
    KEY_PGDN, KEY_INSERT, KEY_DELETE, MOD_SHIFT, MOD_ALT, MOD_CTRL, KEY_MASK, fkey, ctrl, alt,
    MB_LEFT, MB_WHEEL_UP, MB_WHEEL_DOWN,
)
from screen import Screen
from palette import Palette, theme, THEME_COUNT
from highlight import Highlighter
from buffer import TextBuffer, Pos, ENC_UTF8, ENC_LATIN1
from window import Window, WK_EDITOR, WK_MESSAGE, WK_OUTLINE, WK_EXPLORER, ACT_OTHER, ACT_TYPE
from window_search import *
from window_multi import *
from window_lines import *
from window_draw import *
from menu import *
from commands import *
from dialog import *
from util import *
from appstate import *
from app_lsp import *
from lsp import *
from markdown import *
from app_watch import *
from watch import *
from app_swap import *
from swap import *
from app_files import *
from app_dialogs import *
from app_menus import *
from app_exec import *
from app_jobs import *
from app_pickers import *
from app_nav import *
from app_outline import *
from layout import *
from app_layout import *
from explorer import *
from app_explorer import *
from doclib import *
from stdref import *
from docfetch import FETCH_SCRIPT
from outline import *
from symindex import *
from docs import *
from watch import file_sig
from app_input import *
from app_mouse import *
from app_draw import *
from app_docs import *
from dap import *


__extension App:
    def debug_adapter_command(mut self) -> String:
        """How the debug adapter is started ('' if it is not installed). The setting
        names the program; a setting with arguments is a whole command, used as it is."""
        var a = String(self.debug_adapter.strip())
        if a.find(" ") >= 0:
            return a
        var path = a if a.find("/") >= 0 else which(a)
        if path.byte_length() == 0 or not path_exists(path):
            return ""
        return adapter_command(path)

    def debug_badge(self) -> String:
        if self.dbg.state == DS_STOPPED:
            return "DEBUG:stopped"
        if self.dbg.state == DS_RUNNING:
            return "DEBUG:running"
        return "DEBUG:starting"

    def debug_command(mut self) raises:
        """Run > Debug: build the current file with debug information and run it under
        the debugger. While a program is stopped, the same command lets it continue."""
        if self.dbg.active():
            if self.dbg.resume():
                self.say("Continuing " + basename(self.dbg_source))
            else:
                self.say("A program is being debugged - " + self.reg.key_label(CM_CANCEL) + " ends it")
            return
        if self.job_busy():
            return
        var i = self.top_editor()
        if i < 0:
            self.info("Debug", "No file to debug.")
            return
        if not self.ensure_saved(i):
            return
        if self.debug_adapter_command().byte_length() == 0:
            self.info("Debug", "The debug adapter was not found: " + self.debug_adapter + " (it comes with Mojo; tools.debug_adapter names it)")
            return
        var path = self.wins[i].path
        var dir = dirname(path)
        var exe = join_path(dir, "build/" + stem(path) + ".debug")
        var cmd = "cd " + shell_quote(dir) + " && mkdir -p build && exec " + self.compiler_cmd() + " build -g -O0" + self.include_flags() + " " + shell_quote(path) + " -o " + shell_quote(exe) + " 2>&1"
        if self.start_job(JOB_DEBUG, cmd, path, exe):
            self.panel_write(PG_MESSAGE)
            _ = self.fill_messages(self.job_header(), List[UInt8](), "Compiling...")
            self.say("Building " + basename(path) + " for debugging - keep editing, " + self.reg.key_label(CM_CANCEL) + " cancels")

    def finish_debug_build(mut self, status: Int, secs: Float64) raises:
        if status != 0 or self.job.cancelled:
            self.finish_build(status, secs)         # the messages, as for any build
            return
        self.panel_write(PG_MESSAGE)
        _ = self.fill_messages(self.job_header(), self.job.data.copy(), "Starting the debugger...")
        var exe = self.job.exe
        var source = self.job.path
        self.debug_launch(exe, source)

    def debug_launch(mut self, exe: String, source: String) raises:
        var log = (dirname(self.log_path) + "/dap.log") if self.log_path.byte_length() > 0 else String("/dev/null")
        self.dbg_source = source
        var cmd = self.debug_adapter_command()
        var args = split_arguments(self.run_args)
        if not self.dbg.begin(cmd, exe, dirname(source), args, log):
            var why = self.dbg.error
            self.info("Debug", why)
            return
        self.debug_show("Starting " + basename(exe) + " under the debugger...")
        self.say("Starting the debugger...")

    def debug_show(mut self, footer: String):
        """The program's output so far in the Message window, with the state below."""
        self.panel_write(PG_MESSAGE)
        var out = self.dbg.output.copy()
        self.msg_base = dirname(self.dbg_source)
        _ = self.fill_messages("Debugging " + self.dbg_source, out, footer)
        self.msg_base = ""
        # keep the newest output and the state in view, unless the window is being read
        var mi = self.msg_index()
        if mi >= 0 and mi != self.top():
            self.wins[mi].cr = max(0, self.wins[mi].buf.count() - 1)
            self.wins[mi].follow = True

    def debug_state_line(self) -> String:
        if self.dbg.state == DS_STOPPED:
            var s = "Stopped: " + self.dbg.stop_text
            if self.dbg.stop_file.byte_length() > 0:
                s += " at " + basename(self.dbg.stop_file) + ":" + String(self.dbg.stop_line)
            if self.dbg.stop_func.byte_length() > 0:
                s += " in " + self.dbg.stop_func
            return s + "  (" + self.reg.key_label(CM_DEBUG) + " continues, " + self.reg.key_label(CM_CANCEL) + " ends)"
        if self.dbg.state == DS_RUNNING:
            return "Running...  (" + self.reg.key_label(CM_CANCEL) + " ends the program)"
        return "Starting..."

    def debug_tick(mut self) raises:
        """Take what the debug adapter reported since the last look."""
        if not self.dbg.active():
            return
        var evs = self.dbg.pump()
        if len(evs) == 0:
            return
        var over = False
        for e in evs:
            if e == DE_RUNNING:
                self.say("Debugging " + basename(self.dbg_source) + " - " + self.reg.key_label(CM_CANCEL) + " ends it")
            elif e == DE_STOPPED:
                self.say("Stopped: " + self.dbg.stop_text)
            elif e == DE_LOCATED:
                self.debug_show_stop()
            elif e == DE_FAILED or e == DE_ENDED:
                over = True
        if over:
            self.debug_end(False)
        else:
            self.debug_show(self.debug_state_line())

    def debug_show_stop(mut self) raises:
        """The program stopped and the place is known: show the line."""
        var file = self.dbg.stop_file
        var line = self.dbg.stop_line
        if self.mode == M_NORMAL and file.byte_length() > 0 and path_exists(file) and line > 0:
            self.jump_mark()
            self.open_path(file)
            var t = self.top()
            self.wins[t].goto(line - 1, 0)
        self.say(self.debug_state_line())

    def debug_end(mut self, by_user: Bool):
        """The session is over (or the user ends it): stop the adapter and the program,
        and say how it ended."""
        var failed = self.dbg.error
        self.dbg.finish()
        var footer: String
        if failed.byte_length() > 0:
            footer = failed
        elif by_user:
            footer = "Debugging ended - the program was stopped"
        elif self.dbg.exited:
            footer = "Program exited with status " + String(self.dbg.exit_code)
        else:
            footer = "The debugger ended"
        self.debug_show(footer)
        self.say(footer)
        if failed.byte_length() > 0 and self.mode == M_NORMAL:
            # what the debugger said last usually explains it
            var tail = String("")
            if len(self.dbg.console) > 0:
                tail = " - " + String(self.dbg.console[len(self.dbg.console) - 1].strip())
            self.info("Debug", failed + tail)
